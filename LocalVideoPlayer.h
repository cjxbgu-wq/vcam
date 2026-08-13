//
//  LocalVideoPlayer.h
//  VCamPlus
//
//  视频播放器（对标 vcameracrack.dylib 的 LocalVideoPlayer 类）
//
//  逆向特征：
//    - "LocalVideoPlayer initialized with frame queue (capacity: %ld) and preprocess pipeline"
//    - dispatch_queue: com.vcam.videoreader / com.vcam.decoder
//    - 属性: videoOutput (AVAssetReaderTrackOutput), videoTrack, frameQueue (NSQueue)
//    - "Fast-path (preloaded): %@ (%.0fx%.0f @ %.1ffps)"
//    - "Prefilling frame queue..." / "Frame queue prefilled with %lu frames"
//    - "Looping video from beginning"
//    - "Started watching file: %@"
//    - "Reloading media[gen=%ld]: %@ (type: %@)"
//    - "Discard stale reload gen=%ld (current=%ld) %@"
//    - 支持 activePlaybackPath（从 plist 读取活动源）
//    - 支持 inode/size/mtime 文件变化检测
//    - 支持图片和视频两种媒体类型
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import "NSQueue.h"
#import "GPUImageProcessor.h"

typedef NS_ENUM(NSInteger, VCamMediaType) {
    VCamMediaTypeUnknown = 0,
    VCamMediaTypeVideo   = 1,
    VCamMediaTypeImage   = 2,
};

@interface LocalVideoPlayer : NSObject

// AVAssetReader 相关
@property (nonatomic, strong) AVAssetReaderTrackOutput *videoOutput;
@property (nonatomic, strong) AVAssetTrack *videoTrack;
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, copy) NSString *currentVideoPath;

// 帧队列
@property (nonatomic, strong) NSQueue *frameQueue;

// dispatch_queue（逆向特征: com.vcam.videoreader / com.vcam.decoder）
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, strong) dispatch_queue_t processingQueue;

// 状态
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) BOOL preprocessEnabled;
@property (nonatomic, assign) BOOL isDecoding;

// 输出尺寸/格式
@property (nonatomic, assign) size_t outputWidth;
@property (nonatomic, assign) size_t outputHeight;
@property (nonatomic, assign) OSType outputFormat;

// 缓存
@property (nonatomic, assign) size_t cachedBGRAWidth;
@property (nonatomic, assign) size_t cachedBGRAHeight;
@property (nonatomic, assign) size_t lastRenderedWidth;
@property (nonatomic, assign) size_t lastRenderedHeight;
@property (nonatomic, assign) uint64_t lastProcessedBufferID;
@property (nonatomic, assign) uint64_t lastProcessTime;
@property (nonatomic, assign) uint64_t frameCount;

// 帧定时器
@property (nonatomic, strong) dispatch_source_t frameTimer;

// 预处理
@property (nonatomic, strong) CIContext *preprocessContext;
@property (nonatomic, strong) GPUImageProcessor *gpuProcessor;

// 视频信息
@property (nonatomic, assign) CGFloat videoFps;
@property (nonatomic, assign) CGFloat videoDuration;
@property (nonatomic, assign) size_t videoWidth;
@property (nonatomic, assign) size_t videoHeight;
@property (nonatomic, assign) VCamMediaType mediaType;

// 图片缓存（图片模式时重复使用）
@property (nonatomic, assign) CVPixelBufferRef cachedImageBuffer;

// 初始化
- (instancetype)initWithCapacity:(NSUInteger)capacity;

// 视频加载（自动检测视频/图片）
- (void)loadVideoAtPath:(NSString *)path completion:(void(^)(BOOL success, NSError *error))completion;

// 解码控制
- (void)startDecodingThread;
- (void)stopDecodingThread;
- (void)prefillFrameQueue;

// 帧获取
- (CVPixelBufferRef)getCurrentFrame;
- (CVPixelBufferRef)copyCurrentFrame CF_RETURNS_RETAINED;

// 帧队列管理
- (void)clearFrameQueue;

// 文件监听
- (void)startWatchingFile:(NSString *)path;
- (void)stopWatchingFile;

// 媒体类型检测
+ (VCamMediaType)detectMediaType:(NSString *)path;

@end
