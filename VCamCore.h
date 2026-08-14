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
//    - 方法: cacheLastRenderedFrame:width:height:
//    - 属性: liveBGRAPixelBuffer, liveYUVPixelBuffer, gpuProcessor
//
//  关键约束（记忆）：
//    1. 无格式白名单(千面 render 逆向 0xb0f8-0xb154): 所有格式都 VT transfer,
//       按目标格式分三套隔离 session(BGRA/YUV/私有) —— 私有格式 |8v0/-8f0 也处理,
//       这是千面能替换视频模式预览和拍照保存的原因
//    2. 同帧去重: 同一物理 buffer 连续经过多消费者, 首次已改写, 后续跳过
//    3. 无帧回退: 用上一帧缓存(目标尺寸匹配)填充, 不闪回相机画面
//    4. 双格式预渲染：同时维护 BGRA 和 YUV 缓冲区
//    5. mediaserverd 不能重启，避免重复 stopDecoding+cleanup+reload
//    6. 状态转换：disable→enable(load), enable→enable(no reload), enable→disable(stop), disable→disable(no action)
//    7. 转换失败时保持原始相机帧，不显示黑屏
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

// 双格式预渲染缓冲区（对齐逆向: 视频原尺寸的 BGRA + YUV(420f), render 时 VT transfer crop fill 到相机帧）
@property (nonatomic, assign) CVPixelBufferRef liveBGRAPixelBuffer;
@property (nonatomic, assign) CVPixelBufferRef liveYUVPixelBuffer;

// 格式状态（诊断用）
@property (nonatomic, assign) BOOL targetSizeKnown;
@property (nonatomic, assign) size_t targetWidth;
@property (nonatomic, assign) size_t targetHeight;
@property (nonatomic, assign) OSType targetFormat;

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
- (BOOL)isPrivateFormat:(OSType)format;

#pragma mark - 状态控制
- (void)setEnabled:(BOOL)enabled;
- (void)startStatePolling;
- (void)stopStatePolling;

#pragma mark - 初始化
- (void)initializeInMediaserverd;
- (void)initializeInSpringBoard;

@end
