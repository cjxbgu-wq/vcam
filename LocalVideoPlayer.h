#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>

// 视频播放器：使用 AVAssetReader 解码视频
// 对标 vcameracrack 的 LocalVideoPlayer：AVAssetReader + copyNextSampleBuffer
@interface LocalVideoPlayer : NSObject

+ (instancetype)sharedInstance;

// 加载视频文件
- (BOOL)loadVideoAtPath:(NSString *)path;

// 启动/停止解码线程
- (void)startDecodingThread;
- (void)stopDecodingThread;

// 获取最新解码帧（retained，调用者负责 release）
- (CVPixelBufferRef)copyCurrentFrame;
- (CVPixelBufferRef)peekPixelBuffer;

// 是否有可用帧
- (BOOL)hasValidFrame;

// 清空帧队列
- (void)clearFrameQueue;

// 预填充帧队列
- (void)prefillFrameQueue;

@property (nonatomic, readonly) BOOL isDecoding;
@property (nonatomic, readonly) size_t videoWidth;
@property (nonatomic, readonly) size_t videoHeight;
@property (nonatomic, readonly) Float64 frameRate;
@property (nonatomic, readonly) CMTime duration;
@property (nonatomic, readonly) NSString *currentVideoPath;

@end
