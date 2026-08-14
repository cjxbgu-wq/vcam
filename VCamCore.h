//
//  VCamCore.h
//  VCamPlus
//
//  核心渲染逻辑（对标 vcameracrack.dylib 的 VCamCore 类）
//
//  逆向特征：
//    - "VCamCore initialized with multi-format buffer pools (vcamplus style)"
//    - "VCamCore deallocated"
//    - "Replacement frame cleared, real camera restored"
//    - "Live state set to: %@"
//    - "Live state changed to: %@"
//    - "State polling timer started"
//    - dispatch_queue: com.vcam.processing
//    - 方法: renderReplacementToPixelBuffer:, hasReplacementFrame, clearReplacementFrame
//    - 方法: cacheLastRenderedFrame:width:height:, isSupportedVideoFormat:
//    - 属性: liveBGRAPixelBuffer, liveYUVPixelBuffer, gpuProcessor
//
//  关键约束（记忆）：
//    1. 格式锁定：只处理第一个遇到的相机帧格式，跳过后续不同格式
//    2. 格式白名单：BGRA, 420v, 420f（不处理 -8f0, |xv0, |8f0 私有格式）
//    3. 双格式预渲染：同时维护 BGRA 和 YUV 缓冲区
//    4. mediaserverd 不能重启，避免重复 stopDecoding+cleanup+reload
//    5. 状态转换：disable→enable(load), enable→enable(no reload), enable→disable(stop), disable→disable(no action)
//    6. 转换失败时保持原始相机帧，不显示黑屏
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "LocalVideoPlayer.h"
#import "GPUImageProcessor.h"
#import "VCamNotify.h"

@interface VCamCore : NSObject

// 组件
@property (nonatomic, strong) LocalVideoPlayer *videoPlayer;
@property (nonatomic, strong) GPUImageProcessor *gpuProcessor;
@property (nonatomic, strong) NSQueue *frameQueue;

// 双格式预渲染缓冲区（逆向特征: 同时维护 BGRA 和 YUV）
@property (nonatomic, assign) CVPixelBufferRef liveBGRAPixelBuffer;
@property (nonatomic, assign) CVPixelBufferRef liveYUVPixelBuffer;

// 格式锁定状态(多格式: 每种格式独立锁尺寸, 允许 420f/|xv0/p420 同时处理)
@property (nonatomic, assign) BOOL targetSizeKnown;
@property (nonatomic, assign) size_t targetWidth;
@property (nonatomic, assign) size_t targetHeight;
@property (nonatomic, assign) OSType targetFormat;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *formatLockMap;  // key=FourCC(NSNumber) value="w,h"

// 缓存
@property (nonatomic, assign) size_t lastRenderedWidth;
@property (nonatomic, assign) size_t lastRenderedHeight;
@property (nonatomic, assign) uint64_t frameCount;

// 状态
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, strong) dispatch_queue_t prerenderQueue;
@property (nonatomic, strong) dispatch_queue_t processingQueue;
@property (nonatomic, strong) NSLock *processLock;
@property (nonatomic, strong) CIContext *ciContext;

// 预处理
@property (nonatomic, assign) BOOL isPixelBufferMode;
@property (nonatomic, assign) BOOL preprocessEnabled;

+ (instancetype)sharedInstance;

#pragma mark - 核心方法（hook 函数调用）
- (void)renderReplacementToPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (BOOL)hasReplacementFrame;
- (void)clearReplacementFrame;
- (void)cacheLastRenderedFrame:(CVPixelBufferRef)buffer width:(size_t)width height:(size_t)height;
- (BOOL)isSupportedVideoFormat:(CVPixelBufferRef)buffer;

#pragma mark - 状态控制
- (void)setEnabled:(BOOL)enabled;
- (void)startStatePolling;
- (void)stopStatePolling;

#pragma mark - 初始化
- (void)initializeInMediaserverd;
- (void)initializeInSpringBoard;

@end
