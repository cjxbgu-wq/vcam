#import "GPUImageProcessor.h"
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>

// 手动声明 VideoToolbox 类型和函数（不依赖 SDK 头文件，避免类型冲突）
typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
typedef struct OpaqueVTPixelRotationSession *VTPixelRotationSessionRef;
OSStatus VTPixelTransferSessionCreate(CFAllocatorRef, VTPixelTransferSessionRef *);
OSStatus VTPixelTransferSessionTransferImage(VTPixelTransferSessionRef, CVPixelBufferRef, CVPixelBufferRef);

// VTPixelRotationSession 私有 API 类型定义
typedef OSStatus (*VTPixelRotationSessionCreateFunc)(CFAllocatorRef, VTPixelRotationSessionRef *);
typedef OSStatus (*VTPixelRotationSessionTransferImageFunc)(VTPixelRotationSessionRef, CVPixelBufferRef, CVPixelBufferRef);

@interface GPUImageProcessor ()
@property (nonatomic, assign) CFTypeRef pixelTransferSession;
@property (nonatomic, assign) CFTypeRef pixelRotationSession;
@property (nonatomic, strong) CIContext *preprocessContext;
@property (nonatomic, assign) CVPixelBufferPoolRef bgraBufferPool;
@property (nonatomic, assign) size_t preprocessWidth;
@property (nonatomic, assign) size_t preprocessHeight;

// VTPixelRotationSession 私有 API
@property (nonatomic, assign) VTPixelRotationSessionCreateFunc createRotationSession;
@property (nonatomic, assign) VTPixelRotationSessionTransferImageFunc transferRotationImage;
@property (nonatomic, assign) CFStringRef rotationKeyInDegrees;
@property (nonatomic, assign) CFStringRef flipHorizontalKey;
@property (nonatomic, assign) BOOL rotationApiAvailable;
@end

@implementation GPUImageProcessor

- (instancetype)init {
    self = [super init];
    if (self) {
        _rotationAngle = 0;
        _mirrored = NO;
        // 软件渲染（mediaserverd 没有 GPU 上下文）
        _preprocessContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @YES
        }];
        [self setupPixelTransferSession];
        [self setupPixelRotationSession];
    }
    return self;
}

#pragma mark - Session 初始化

- (void)setupPixelTransferSession {
    if (_pixelTransferSession) return;
    VTPixelTransferSessionRef session = NULL;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &session);
    _pixelTransferSession = session;
    if (status == noErr) {
        NSLog(@"[vcam] VTPixelTransferSession created successfully");
    } else {
        NSLog(@"[vcam] Failed to create VTPixelTransferSession: %d", (int)status);
    }
}

- (void)setupPixelRotationSession {
    if (_pixelRotationSession) return;

    _createRotationSession = (VTPixelRotationSessionCreateFunc)dlsym(RTLD_DEFAULT, "VTPixelRotationSessionCreate");
    _transferRotationImage = (VTPixelRotationSessionTransferImageFunc)dlsym(RTLD_DEFAULT, "VTPixelRotationSessionTransferImage");
    _rotationKeyInDegrees = (CFStringRef)dlsym(RTLD_DEFAULT, "kVTPixelRotationPropertyKey_RotationInDegrees");
    _flipHorizontalKey = (CFStringRef)dlsym(RTLD_DEFAULT, "kVTPixelRotationPropertyKey_FlipHorizontalOrientation");

    if (!_createRotationSession || !_transferRotationImage || !_rotationKeyInDegrees || !_flipHorizontalKey) {
        _rotationApiAvailable = NO;
        return;
    }

    VTPixelRotationSessionRef rotSession = NULL;
    OSStatus status = _createRotationSession(kCFAllocatorDefault, &rotSession);
    _pixelRotationSession = rotSession;
    if (status == noErr) {
        _rotationApiAvailable = YES;
        NSLog(@"[vcam] VTPixelRotationSession created successfully");
    } else {
        _rotationApiAvailable = NO;
        NSLog(@"[vcam] Failed to create VTPixelRotationSession: %d", (int)status);
    }
}

#pragma mark - 缓冲池

- (void)setPreprocessTargetWidth:(size_t)width height:(size_t)height {
    if (_preprocessWidth == width && _preprocessHeight == height) return;
    _preprocessWidth = width;
    _preprocessHeight = height;

    // 重建 BGRA 缓冲池
    if (_bgraBufferPool) {
        CVPixelBufferPoolRelease(_bgraBufferPool);
        _bgraBufferPool = NULL;
    }

    // CRITICAL: 不使用 IOSurface 属性
    NSDictionary *poolAttributes = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @2
    };
    NSDictionary *bufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height)
    };

    OSStatus status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
        (__bridge CFDictionaryRef)poolAttributes,
        (__bridge CFDictionaryRef)bufferAttributes,
        &_bgraBufferPool);

    if (status == noErr) {
        NSLog(@"[vcam] Created preprocess buffer pool: %zux%zu", width, height);
    } else {
        NSLog(@"[vcam] Failed to create preprocess buffer pool: %d", (int)status);
    }
}

- (CVPixelBufferRef)getOrCreateBGRABufferWithWidth:(size_t)width height:(size_t)height {
    // 优先从缓冲池获取
    if (_bgraBufferPool && _preprocessWidth == width && _preprocessHeight == height) {
        CVPixelBufferRef buf = NULL;
        OSStatus status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _bgraBufferPool, &buf);
        if (status == noErr && buf) return buf;
    }

    // 回退：直接创建
    CVPixelBufferRef buf = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, NULL, &buf);
    return buf;
}

#pragma mark - 图像处理

- (void)processPixelBuffer:(CVPixelBufferRef)srcBuffer
                  toBuffer:(CVPixelBufferRef)dstBuffer
                    toWidth:(size_t)width
                   toHeight:(size_t)height
                     format:(OSType)format {
    if (!srcBuffer || !dstBuffer) return;

    size_t srcWidth = CVPixelBufferGetWidth(srcBuffer);
    size_t srcHeight = CVPixelBufferGetHeight(srcBuffer);

    // 快速路径：同尺寸、无变换 → 直接拷贝
    BOOL sameSize = (srcWidth == width && srcHeight == height);
    BOOL noTransform = (_rotationAngle == 0 && !_mirrored);

    if (sameSize && noTransform) {
        [self transferPixelBuffer:srcBuffer toPixelBuffer:dstBuffer];
        return;
    }

    // 慢速路径：CoreImage 处理（缩放/旋转/镜像）
    CIImage *image = [CIImage imageWithCVPixelBuffer:srcBuffer];
    if (!image) {
        [self transferPixelBuffer:srcBuffer toPixelBuffer:dstBuffer];
        return;
    }

    CGAffineTransform t = CGAffineTransformIdentity;
    CGFloat srcW = image.extent.size.width;
    CGFloat srcH = image.extent.size.height;

    // 1. 缩放
    if (srcWidth != width || srcHeight != height) {
        CGFloat scaleX = (CGFloat)width / srcW;
        CGFloat scaleY = (CGFloat)height / srcH;
        t = CGAffineTransformScale(t, scaleX, scaleY);
    }

    // 2. 旋转（顺时针）
    int angle = (int)_rotationAngle;
    if (angle % 90 != 0) angle = 0;
    switch (angle) {
        case 90:
            t = CGAffineTransformRotate(t, M_PI_2);
            t = CGAffineTransformTranslate(t, -height, 0);
            break;
        case 180:
            t = CGAffineTransformRotate(t, M_PI);
            t = CGAffineTransformTranslate(t, -width, -height);
            break;
        case 270:
            t = CGAffineTransformRotate(t, -M_PI_2);
            t = CGAffineTransformTranslate(t, 0, -width);
            break;
    }

    // 3. 镜像
    if (_mirrored) {
        CGAffineTransform m = CGAffineTransformMakeScale(-1, 1);
        m = CGAffineTransformTranslate(m, width, 0);
        t = CGAffineTransformConcat(t, m);
    }

    CIImage *transformed = [image imageByApplyingTransform:t highQualityDownsample:YES];
    CGRect dstRect = CGRectMake(0, 0, width, height);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    [_preprocessContext render:transformed
                 toCVPixelBuffer:dstBuffer
                         bounds:dstRect
                     colorSpace:cs];
    CGColorSpaceRelease(cs);
}

- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst {
    if (!src || !dst) return NO;

    if (_pixelTransferSession) {
        OSStatus status = VTPixelTransferSessionTransferImage((VTPixelTransferSessionRef)_pixelTransferSession, src, dst);
        if (status == noErr) return YES;
    }

    // 回退：memcpy
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);

    void *srcBase = CVPixelBufferGetBaseAddress(src);
    void *dstBase = CVPixelBufferGetBaseAddress(dst);
    if (srcBase && dstBase) {
        size_t srcBPR = CVPixelBufferGetBytesPerRow(src);
        size_t dstBPR = CVPixelBufferGetBytesPerRow(dst);
        size_t srcH = CVPixelBufferGetHeight(src);
        size_t dstH = CVPixelBufferGetHeight(dst);
        size_t minH = MIN(srcH, dstH);
        size_t minBPR = MIN(srcBPR, dstBPR);
        for (size_t y = 0; y < minH; y++) {
            memcpy((uint8_t *)dstBase + y * dstBPR,
                   (uint8_t *)srcBase + y * srcBPR, minBPR);
        }
    }

    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return YES;
}

- (void)dealloc {
    if (_pixelTransferSession) CFRelease(_pixelTransferSession);
    if (_pixelRotationSession) CFRelease(_pixelRotationSession);
    if (_bgraBufferPool) CVPixelBufferPoolRelease(_bgraBufferPool);
}

@end
