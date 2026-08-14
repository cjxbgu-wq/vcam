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
// 会话（VT session 非线程安全且内部缓存 pipeline 状态, 必须按用途隔离）
@property (nonatomic, assign) VTPixelTransferSessionRef pixelTransferSession;      // render: 标准格式目标(BGRA/420v/420f)
@property (nonatomic, assign) VTPixelTransferSessionRef renderPrivateSession;      // render: 私有格式目标(-8v0/|xv0 等), 与标准 session 隔离防止状态污染导致几何抖动
@property (nonatomic, assign) VTPixelTransferSessionRef prerenderTransferSession;  // 预渲染线程专用
@property (nonatomic, assign) VTPixelRotationSessionRef pixelRotationSession;

// 私有 API 函数指针
@property (nonatomic, assign) VTPixelRotationSessionCreateFunc createRotationSession;
@property (nonatomic, assign) VTPixelRotationSessionTransferImageFunc transferRotationImage;
@property (nonatomic, assign) CFStringRef rotationKeyInDegrees;
@property (nonatomic, assign) CFStringRef flipHorizontalKey;

// CIContext（软件渲染，mediaserverd 没有 GPU 上下文）
// 两个独立 CIContext: 预渲染线程用 preprocessContext, render 线程回退用 renderContext（CIContext 非线程安全）
@property (nonatomic, strong) CIContext *preprocessContext;
@property (nonatomic, strong) CIContext *renderContext;

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
        _renderPrivateSession = NULL;
        _prerenderTransferSession = NULL;
        _pixelRotationSession = NULL;
        _bgraBufferPoolMap = [[NSMutableDictionary alloc] init];

        // 软件渲染 CIContext（mediaserverd 没有 GPU 上下文）
        @try {
            _preprocessContext = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @YES
            }];
            _renderContext = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @YES
            }];
        } @catch (NSException *e) {
            _preprocessContext = nil;
            _renderContext = nil;
        }

        [self setupPixelTransferSession];
        [self setupPrerenderTransferSession];
        [self setupPixelRotationSession];
        vcam_gpu_log(@"[vcam] GPUImageProcessor initialized");
    }
    return self;
}

- (void)dealloc {
    typedef void (*InvalidateFunc)(VTPixelTransferSessionRef);
    if (_pixelTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_pixelTransferSession);
    }
    if (_prerenderTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_prerenderTransferSession);
    }
    if (_renderPrivateSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_renderPrivateSession);
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
        // 对齐逆向 vcameracrack.dylib: RealTime + CropSourceToCleanAperture
        // VT transfer 支持任意尺寸+格式组合, CropSourceToCleanAperture 自动做 crop fill 缩放
        // (源缩放到完全填充目标, 超出部分裁剪, 无黑边, 硬件优化质量好)
        VTSessionSetProperty(_pixelTransferSession, CFSTR("RealTime"), kCFBooleanTrue);
        VTSessionSetProperty(_pixelTransferSession, CFSTR("ScalingMode"), CFSTR("CropSourceToCleanAperture"));
        vcam_gpu_log(@"[vcam] VTPixelTransferSession created (RealTime + CropSourceToCleanAperture)");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create VTPixelTransferSession: %d", (int)status]);
    }
}

- (void)setupPrerenderTransferSession {
    if (_prerenderTransferSession) return;
    // 预渲染线程专用 session（与 render 的 session 分离, 避免并发调用崩溃）
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_prerenderTransferSession);
    if (status == noErr) {
        VTSessionSetProperty(_prerenderTransferSession, CFSTR("RealTime"), kCFBooleanTrue);
        VTSessionSetProperty(_prerenderTransferSession, CFSTR("ScalingMode"), CFSTR("CropSourceToCleanAperture"));
        vcam_gpu_log(@"[vcam] Prerender VTPixelTransferSession created");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create prerender session: %d", (int)status]);
    }
}

- (void)setupRenderPrivateSession {
    if (_renderPrivateSession) return;
    // render 私有格式专用 session: 私有格式转换与标准格式共用 session 会污染 VT 内部
    // pipeline 缓存, 导致标准格式流(照片 420f)几何在正确/错误间交替(反复拉伸)
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_renderPrivateSession);
    if (status == noErr) {
        VTSessionSetProperty(_renderPrivateSession, CFSTR("RealTime"), kCFBooleanTrue);
        VTSessionSetProperty(_renderPrivateSession, CFSTR("ScalingMode"), CFSTR("CropSourceToCleanAperture"));
        vcam_gpu_log(@"[vcam] Render-private VTPixelTransferSession created");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create render-private session: %d", (int)status]);
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

// 预渲染用: 需要旋转/镜像时做变换(输出 BGRA), 否则原帧 retain 返回
- (CVPixelBufferRef)rotateAndMirrorIfNeeded:(CVPixelBufferRef)input CF_RETURNS_RETAINED {
    if (!input) return NULL;
    if (_rotationAngle == 0 && !_mirrored) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }
    if (!_rotationApiAvailable || !_pixelRotationSession) {
        // 旋转 API 不可用, 回退原帧（不旋转）
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }
    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    size_t rotW = (_rotationAngle == 90 || _rotationAngle == 270) ? inH : inW;
    size_t rotH = (_rotationAngle == 90 || _rotationAngle == 270) ? inW : inH;
    CVPixelBufferRef r = [self rotateAndMirror:input width:rotW height:rotH];
    if (!r) {
        // 旋转失败, 回退原帧
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }
    return r;
}

// 预渲染用: 同尺寸格式转换(如 BGRA -> 420f), VT 主路径 + CoreImage 回退
// 注意: 用预渲染专用 session（避免与 render 线程的 session 并发调用崩溃）
- (CVPixelBufferRef)convertFormat:(CVPixelBufferRef)input toFormat:(OSType)format CF_RETURNS_RETAINED {
    if (!input) return NULL;
    if (CVPixelBufferGetPixelFormatType(input) == format) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }
    size_t w = CVPixelBufferGetWidth(input);
    size_t h = CVPixelBufferGetHeight(input);

    // VT transfer 同尺寸格式转换（预渲染专用 session）
    CVPixelBufferRef out = [self createBufferWithWidth:w height:h format:format];
    if (out) {
        if (!_prerenderTransferSession) {
            [self setupPrerenderTransferSession];
        }
        if (_prerenderTransferSession &&
            VTPixelTransferSessionTransferImage(_prerenderTransferSession, input, out) == noErr) {
            return out;
        }
        CVPixelBufferRelease(out);
    }

    // CoreImage 回退
    return [self convertWithCoreImage:input toFormat:format width:w height:h];
}

// writeFrame 回退路径: crop fill 渲染到任意格式目标 buffer（保持宽高比填满, 居中裁剪）
// 注意: 用 render 线程专用 CIContext（避免与预渲染线程的 context 并发崩溃）
- (BOOL)renderCropFill:(CVPixelBufferRef)input toPixelBuffer:(CVPixelBufferRef)dst {
    if (!input || !dst || !_renderContext) return NO;

    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    size_t w = CVPixelBufferGetWidth(dst);
    size_t h = CVPixelBufferGetHeight(dst);
    if (inW == 0 || inH == 0 || w == 0 || h == 0) return NO;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NO;

    CGFloat scale = MAX((CGFloat)w / (CGFloat)inW, (CGFloat)h / (CGFloat)inH);
    CGFloat offsetX = ((CGFloat)w - (CGFloat)inW * scale) / 2.0;
    CGFloat offsetY = ((CGFloat)h - (CGFloat)inH * scale) / 2.0;
    CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
    t = CGAffineTransformTranslate(t, offsetX / scale, offsetY / scale);
    CIImage *scaled = [image imageByApplyingTransform:t];

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    [_renderContext render:scaled toCVPixelBuffer:dst
                    bounds:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)
                colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);
    return YES;
}

// CoreImage 回退: CI 只渲染到 BGRA(软件渲染器对 planar YUV 支持不可靠, 渲染失败会留下未初始化 buffer → 黑屏/绿屏)
// 目标是 YUV 时再用 VT transfer 转换, VT 失败返回 NULL(绝不返回未初始化的 YUV buffer)
- (CVPixelBufferRef)convertWithCoreImage:(CVPixelBufferRef)input
                                toFormat:(OSType)format
                                  width:(size_t)width
                                 height:(size_t)height CF_RETURNS_RETAINED {
    if (!input || !_preprocessContext) return NULL;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NULL;

    // 1. CI 渲染到 BGRA（bounds + sRGB, 软件渲染器对 BGRA 支持可靠）
    CVPixelBufferRef bgra = [self getOrCreateBGRABufferWithWidth:width height:height];
    if (!bgra) return NULL;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    [_preprocessContext render:image toCVPixelBuffer:bgra
                        bounds:CGRectMake(0, 0, (CGFloat)width, (CGFloat)height)
                    colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);

    // 2. 目标就是 BGRA: 直接返回
    if (format == kCVPixelFormatType_32BGRA) {
        return bgra;
    }

    // 3. BGRA -> YUV 用 VT 转换（预渲染专用 session）; 失败返回 NULL
    CVPixelBufferRef output = [self createBufferWithWidth:width height:height format:format];
    if (!output) {
        CVPixelBufferRelease(bgra);
        return NULL;
    }
    if (!_prerenderTransferSession) {
        [self setupPrerenderTransferSession];
    }
    if (!_prerenderTransferSession ||
        VTPixelTransferSessionTransferImage(_prerenderTransferSession, bgra, output) != noErr) {
        CVPixelBufferRelease(output);
        CVPixelBufferRelease(bgra);
        vcam_gpu_log(@"[vcam] convertWithCoreImage: VT BGRA->YUV failed, return NULL (no uninitialized buffer)");
        return NULL;
    }
    CVPixelBufferRelease(bgra);
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
    if (!src || !dst) return NO;

    // 按目标格式选 session: 私有格式转换用独立 session,
    // 防止其 pipeline 状态污染标准格式流(照片 420f 几何反复抖动)
    OSType dstFmt = CVPixelBufferGetPixelFormatType(dst);
    BOOL privateTarget = !(dstFmt == kCVPixelFormatType_32BGRA || dstFmt == '420v' || dstFmt == '420f');
    VTPixelTransferSessionRef session = privateTarget ? _renderPrivateSession : _pixelTransferSession;
    if (!session) {
        if (privateTarget) {
            [self setupRenderPrivateSession];
            session = _renderPrivateSession;
        } else {
            [self setupPixelTransferSession];
            session = _pixelTransferSession;
        }
    }
    if (!session) return NO;

    // 等比裁剪填充: VT 'CropSourceToCleanAperture' 语义是"源 CA 区域拉伸到目标全帧"(非等比!)
    // 通过把源的 clean aperture 设为"等比居中裁剪出的子区域"(与目标等比),
    // VT 只取该子区域缩放 → 等比 crop fill, 无拉伸、无黑边
    size_t srcW = CVPixelBufferGetWidth(src);
    size_t srcH = CVPixelBufferGetHeight(src);
    size_t dstW = CVPixelBufferGetWidth(dst);
    size_t dstH = CVPixelBufferGetHeight(dst);
    if (srcW > 1 && srcH > 1 && dstW > 1 && dstH > 1 &&
        (srcW != dstW || srcH != dstH)) {
        CGFloat caW = (CGFloat)srcW, caH = (CGFloat)srcH;
        CGFloat srcAR = (CGFloat)srcW / (CGFloat)srcH;
        CGFloat dstAR = (CGFloat)dstW / (CGFloat)dstH;
        if (srcAR > dstAR) {
            caW = floor((CGFloat)srcH * dstAR);       // 源更宽: 左右裁剪
        } else if (srcAR < dstAR) {
            caH = floor((CGFloat)srcW / dstAR);       // 源更高: 上下裁剪
        }
        caW = floor(caW / 2.0) * 2.0;                  // 偶数对齐(YUV 采样)
        caH = floor(caH / 2.0) * 2.0;
        if (caW >= 2 && caH >= 2 && (caW != (CGFloat)srcW || caH != (CGFloat)srcH)) {
            NSDictionary *ca = @{
                (id)kCVImageBufferCleanApertureWidthKey: @(caW),
                (id)kCVImageBufferCleanApertureHeightKey: @(caH),
                (id)kCVImageBufferCleanApertureHorizontalOffsetKey: @0,
                (id)kCVImageBufferCleanApertureVerticalOffsetKey: @0,
            };
            CVBufferSetAttachment(src, kCVImageBufferCleanApertureKey,
                                  (__bridge CFDictionaryRef)ca,
                                  kCVAttachmentMode_ShouldPropagate);
        }
    }

    OSStatus status = VTPixelTransferSessionTransferImage(session, src, dst);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] VTPixelTransferSession failed: %d, format: %@",
                      (int)status, [self stringForFormat:dstFmt]]);
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
