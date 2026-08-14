//
//  GPUImageProcessor.m
//  VCamPlus
//
//  对标 vcameracrack.dylib 的 GPUImageProcessor 实现
//

#import "GPUImageProcessor.h"
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

// 手动声明 VideoToolbox 类型和函数（不依赖 SDK 头文件，避免类型冲突）
typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
typedef struct OpaqueVTPixelRotationSession *VTPixelRotationSessionRef;
OSStatus VTPixelTransferSessionCreate(CFAllocatorRef, VTPixelTransferSessionRef *);
OSStatus VTPixelTransferSessionTransferImage(VTPixelTransferSessionRef, CVPixelBufferRef, CVPixelBufferRef);
OSStatus VTSessionSetProperty(CFTypeRef session, CFStringRef propertyKey, CFTypeRef propertyValue);

// VTPixelRotationSession 私有 API 函数指针类型
typedef OSStatus (*VTPixelRotationSessionCreateFunc)(CFAllocatorRef, VTPixelRotationSessionRef *);
typedef OSStatus (*VTPixelRotationSessionTransferImageFunc)(VTPixelRotationSessionRef, CVPixelBufferRef, CVPixelBufferRef);

static void vcam_gpu_log(NSString *msg) {
    @try {
        NSString *logPath = @"/tmp/vcam_gpu_log.txt";
        NSString *ts = [NSDate date].description;
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", ts, msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!fh) {
            [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

@interface GPUImageProcessor ()
// 会话
@property (nonatomic, assign) VTPixelTransferSessionRef pixelTransferSession;
@property (nonatomic, assign) VTPixelRotationSessionRef pixelRotationSession;

// 私有 API 函数指针
@property (nonatomic, assign) VTPixelRotationSessionCreateFunc createRotationSession;
@property (nonatomic, assign) VTPixelRotationSessionTransferImageFunc transferRotationImage;
@property (nonatomic, assign) CFStringRef rotationKeyInDegrees;
@property (nonatomic, assign) CFStringRef flipHorizontalKey;

// CIContext（软件渲染，mediaserverd 没有 GPU 上下文）
@property (nonatomic, strong) CIContext *preprocessContext;

// 缓冲池字典（key="w_h", value=CVPixelBufferPoolRef）—— 每个尺寸独立池，避免频繁重建
@property (nonatomic, strong) NSMutableDictionary *bgraBufferPoolMap;

// 内部方法（前向声明，让 ARC 正确处理 CF_RETURNS_RETAINED）
- (CVPixelBufferRef)scaleToBGRA:(CVPixelBufferRef)input width:(size_t)width height:(size_t)height CF_RETURNS_RETAINED;
@end

@implementation GPUImageProcessor

- (instancetype)init {
    self = [super init];
    if (self) {
        _rotationAngle = 0;
        _mirrored = NO;
        _rotationApiAvailable = NO;
        _pixelTransferSession = NULL;
        _pixelRotationSession = NULL;
        _bgraBufferPoolMap = [[NSMutableDictionary alloc] init];

        // 软件渲染 CIContext（mediaserverd 没有 GPU 上下文）
        @try {
            _preprocessContext = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @YES
            }];
        } @catch (NSException *e) {
            _preprocessContext = nil;
        }

        [self setupPixelTransferSession];
        [self setupPixelRotationSession];
        vcam_gpu_log(@"[vcam] GPUImageProcessor initialized");
    }
    return self;
}

- (void)dealloc {
    if (_pixelTransferSession) {
        typedef void (*InvalidateFunc)(VTPixelTransferSessionRef);
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_pixelTransferSession);
    }
    // 释放所有缓冲池
    for (id key in _bgraBufferPoolMap) {
        CVPixelBufferPoolRef pool = (__bridge CVPixelBufferPoolRef)_bgraBufferPoolMap[key];
        CVPixelBufferPoolRelease(pool);
    }
    [_bgraBufferPoolMap removeAllObjects];
    vcam_gpu_log(@"[vcam] GPUImageProcessor deallocated");
}

#pragma mark - Session 初始化

- (void)setupPixelTransferSession {
    if (_pixelTransferSession) return;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_pixelTransferSession);
    if (status == noErr) {
        // 只设 RealTime（降低延迟）。不设 ScalingMode —— 预渲染已 crop fill 到目标尺寸，
        // 同尺寸转换不需要额外缩放，CropSourceToCleanAperture 会导致画面位置偏移
        VTSessionSetProperty(_pixelTransferSession, CFSTR("RealTime"), kCFBooleanTrue);
        vcam_gpu_log(@"[vcam] VTPixelTransferSession created (RealTime only, no ScalingMode)");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create VTPixelTransferSession: %d", (int)status]);
    }
}

- (void)setupPixelRotationSession {
    if (_pixelRotationSession) return;

    // 通过 dlsym 加载私有 API
    _createRotationSession = (VTPixelRotationSessionCreateFunc)dlsym(RTLD_DEFAULT, "VTPixelRotationSessionCreate");
    _transferRotationImage = (VTPixelRotationSessionTransferImageFunc)dlsym(RTLD_DEFAULT, "VTPixelRotationSessionTransferImage");
    _rotationKeyInDegrees = (CFStringRef)dlsym(RTLD_DEFAULT, "kVTPixelRotationPropertyKey_RotationInDegrees");
    _flipHorizontalKey = (CFStringRef)dlsym(RTLD_DEFAULT, "kVTPixelRotationPropertyKey_FlipHorizontalOrientation");

    if (!_createRotationSession || !_transferRotationImage || !_rotationKeyInDegrees || !_flipHorizontalKey) {
        _rotationApiAvailable = NO;
        return;
    }

    OSStatus status = _createRotationSession(kCFAllocatorDefault, &_pixelRotationSession);
    if (status == noErr) {
        _rotationApiAvailable = YES;
        vcam_gpu_log(@"[vcam] VTPixelRotationSession created successfully");
    } else {
        _rotationApiAvailable = NO;
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create VTPixelRotationSession: %d", (int)status]);
    }
}

#pragma mark - 缓冲池（多池字典，每个尺寸独立池，避免频繁重建）

- (CVPixelBufferPoolRef)getOrCreatePoolForWidth:(size_t)width height:(size_t)height format:(OSType)format {
    if (width == 0 || height == 0) return NULL;

    NSString *key = [NSString stringWithFormat:@"%zu_%zu_%u", width, height, (unsigned)format];
    id existing = _bgraBufferPoolMap[key];
    if (existing) {
        return (__bridge CVPixelBufferPoolRef)existing;
    }

    // 创建新池（关键约束：不能用 kCVPixelBufferIOSurfacePropertiesKey）
    NSDictionary *poolAttributes = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @2,
    };
    NSDictionary *pixelBufferAttributes = @{
        (id)kCVPixelBufferWidthKey:  @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(format),
    };

    CVPixelBufferPoolRef pool = NULL;
    OSStatus status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        (__bridge CFDictionaryRef)poolAttributes,
        (__bridge CFDictionaryRef)pixelBufferAttributes,
        &pool
    );

    if (status != noErr) {
        // 回退：NULL pool attributes
        status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            NULL,
            (__bridge CFDictionaryRef)pixelBufferAttributes,
            &pool
        );
    }

    if (status == noErr && pool) {
        _bgraBufferPoolMap[key] = (__bridge id)pool;
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Created buffer pool: %zux%zu fmt=%u (key=%@)", width, height, (unsigned)format, key]);
        return pool;
    }

    vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create buffer pool: %d, %zux%zu", (int)status, width, height]);
    return NULL;
}

- (CVPixelBufferRef)getOrCreateBGRABufferWithWidth:(size_t)width height:(size_t)height CF_RETURNS_RETAINED {
    CVPixelBufferPoolRef pool = [self getOrCreatePoolForWidth:width height:height format:kCVPixelFormatType_32BGRA];

    CVPixelBufferRef buffer = NULL;
    if (pool) {
        OSStatus status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer);
        if (status == noErr && buffer) {
            return buffer;
        }
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to get buffer from pool: %d", (int)status]);
    }

    // 回退：直接创建（不带 IOSurface 属性）
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, NULL, &buffer);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create pixel buffer: %d, %zux%zu BGRA", (int)status, width, height]);
        return NULL;
    }
    return buffer;
}

- (void)configureWithWidth:(size_t)width height:(size_t)height format:(OSType)format {
    [self getOrCreatePoolForWidth:width height:height format:format];
    NSString *fmtStr = [self stringForFormat:format];
    vcam_gpu_log([NSString stringWithFormat:@"[vcam] GPUImageProcessor configured: %zux%zu format: %@", width, height, fmtStr]);
}

#pragma mark - 核心处理

- (CVPixelBufferRef)processPixelBuffer:(CVPixelBufferRef)input
                                toWidth:(size_t)width
                                height:(size_t)height
                                format:(OSType)format CF_RETURNS_RETAINED {
    if (!input) return NULL;

    @try {
        size_t inW = CVPixelBufferGetWidth(input);
        size_t inH = CVPixelBufferGetHeight(input);

        // 旋转后的尺寸
        size_t rotW = inW, rotH = inH;
        if (_rotationAngle == 90 || _rotationAngle == 270) {
            rotW = inH;
            rotH = inW;
        }

        // 1. 旋转/镜像（如果需要）→ BGRA
        CVPixelBufferRef processedBuffer = NULL;
        if ((_rotationAngle != 0 || _mirrored) && _rotationApiAvailable && _pixelRotationSession) {
            processedBuffer = [self rotateAndMirror:input width:rotW height:rotH];
        }
        // 如果旋转失败或不需要旋转，直接用输入
        if (!processedBuffer) {
            processedBuffer = input;
            CVPixelBufferRetain(processedBuffer);
        }

        // 2. 缩放到目标尺寸的 BGRA（CoreImage 擅长 BGRA→BGRA 缩放）
        //    VTPixelTransferSession 不支持缩放，必须先缩放到目标尺寸再做格式转换
        size_t curW = CVPixelBufferGetWidth(processedBuffer);
        size_t curH = CVPixelBufferGetHeight(processedBuffer);
        if (curW != width || curH != height) {
            CVPixelBufferRef scaledBGRA = [self scaleToBGRA:processedBuffer width:width height:height];
            CVPixelBufferRelease(processedBuffer);
            processedBuffer = scaledBGRA;  // scaledBGRA 已 retain (CF_RETURNS_RETAINED)
            if (!processedBuffer) {
                return NULL;
            }
        }

        // 3. 格式转换（BGRA → 目标格式，同尺寸）
        CVPixelBufferRef outputBuffer = NULL;
        if (format == kCVPixelFormatType_32BGRA) {
            // 目标格式是 BGRA，直接返回缩放后的缓冲区
            outputBuffer = processedBuffer;
        } else {
            // 用 VTPixelTransferSession 转换格式（同尺寸 BGRA→YUV）
            outputBuffer = [self createBufferWithWidth:width height:height format:format];
            if (outputBuffer) {
                OSStatus status = VTPixelTransferSessionTransferImage(_pixelTransferSession, processedBuffer, outputBuffer);
                if (status != noErr) {
                    NSString *fmtStr = [self stringForFormat:format];
                    vcam_gpu_log([NSString stringWithFormat:@"[vcam] VTPixelTransferSession failed: %d, format: %@", (int)status, fmtStr]);
                    // 回退到 CoreImage（同尺寸 BGRA→YUV）
                    CVPixelBufferRelease(outputBuffer);
                    outputBuffer = [self convertWithCoreImage:processedBuffer toFormat:format width:width height:height];
                }
            }
            CVPixelBufferRelease(processedBuffer);
        }

        return outputBuffer;
    } @catch (NSException *e) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Exception in processPixelBuffer: %@", e]);
        return NULL;
    }
}

// crop fill: 保持宽高比, 填充整个目标, 裁剪超出部分（无黑边, 居中）
- (CVPixelBufferRef)scaleToBGRA:(CVPixelBufferRef)input
                          width:(size_t)width
                         height:(size_t)height CF_RETURNS_RETAINED {
    if (!input || !_preprocessContext) return NULL;

    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    if (inW == 0 || inH == 0 || width == 0 || height == 0) return NULL;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NULL;

    CVPixelBufferRef output = [self getOrCreateBGRABufferWithWidth:width height:height];
    if (!output) return NULL;

    // crop fill: 取较大缩放比填充整个目标, 超出部分裁剪（无黑边）
    CGFloat scale = MAX((CGFloat)width / (CGFloat)inW, (CGFloat)height / (CGFloat)inH);
    CGFloat scaledW = (CGFloat)inW * scale;
    CGFloat scaledH = (CGFloat)inH * scale;
    // 居中偏移（负值 = 图像超出目标边界, 被 bounds 裁剪）
    CGFloat offsetX = ((CGFloat)width - scaledW) / 2.0;
    CGFloat offsetY = ((CGFloat)height - scaledH) / 2.0;

    // 变换: 缩放后平移到居中位置
    CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
    t = CGAffineTransformTranslate(t, offsetX / scale, offsetY / scale);
    CIImage *scaled = [image imageByApplyingTransform:t];

    // 用 sRGB colorSpace 渲染（nil 会导致颜色不正确）
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    [_preprocessContext render:scaled toCVPixelBuffer:output
                        bounds:CGRectMake(0, 0, (CGFloat)width, (CGFloat)height)
                    colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);
    return output;
}

- (CVPixelBufferRef)rotateAndMirror:(CVPixelBufferRef)input width:(size_t)width height:(size_t)height CF_RETURNS_RETAINED {
    if (!input || !_pixelRotationSession) return NULL;

    // 创建目标缓冲区（BGRA 格式，不带 IOSurface 属性）
    CVPixelBufferRef dst = NULL;
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, NULL, &dst);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create rotation buffer: %d", (int)status]);
        return NULL;
    }

    // 设置旋转角度
    if (_rotationAngle != 0) {
        VTSessionSetProperty(_pixelRotationSession, _rotationKeyInDegrees, (__bridge CFTypeRef)@(_rotationAngle));
    }
    // 设置镜像
    VTSessionSetProperty(_pixelRotationSession, _flipHorizontalKey, _mirrored ? kCFBooleanTrue : kCFBooleanFalse);

    status = _transferRotationImage(_pixelRotationSession, input, dst);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] VTPixelRotationSession failed: %d", (int)status]);
        CVPixelBufferRelease(dst);
        return NULL;
    }

    return dst;
}

- (CVPixelBufferRef)convertWithCoreImage:(CVPixelBufferRef)input
                                toFormat:(OSType)format
                                  width:(size_t)width
                                 height:(size_t)height CF_RETURNS_RETAINED {
    if (!input || !_preprocessContext) return NULL;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NULL;

    // 创建目标缓冲区（不带 IOSurface 属性）
    CVPixelBufferRef output = NULL;
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, NULL, &output);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create pixel buffer: %d, size: %zux%zu, format: %@",
                      (int)status, width, height, [self stringForFormat:format]]);
        return NULL;
    }

    // 渲染到目标缓冲区
    [_preprocessContext render:image toCVPixelBuffer:output];
    return output;
}

- (CVPixelBufferRef)createBufferWithWidth:(size_t)width height:(size_t)height format:(OSType)format CF_RETURNS_RETAINED {
    CVPixelBufferRef buffer = NULL;
    // 不带 IOSurface 属性（mediaserverd 安全）
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, NULL, &buffer);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create pixel buffer: %d, size: %zux%zu, format: %@",
                      (int)status, width, height, [self stringForFormat:format]]);
        return NULL;
    }
    return buffer;
}

- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst {
    if (!src || !dst || !_pixelTransferSession) return NO;
    OSStatus status = VTPixelTransferSessionTransferImage(_pixelTransferSession, src, dst);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] VTPixelTransferSession failed: %d, format: %@",
                      (int)status, [self stringForFormat:CVPixelBufferGetPixelFormatType(dst)]]);
        return NO;
    }
    return YES;
}

#pragma mark - 工具

- (NSString *)stringForFormat:(OSType)format {
    char fstr[5] = {0};
    fstr[0] = (char)(format >> 24);
    fstr[1] = (char)(format >> 16);
    fstr[2] = (char)(format >> 8);
    fstr[3] = (char)format;
    return [NSString stringWithUTF8String:fstr];
}

@end
