//
//  NSQueue.h
//  VCamPlus
//
//  线程安全双模式队列（PixelBuffer / SampleBuffer）
//  对标 vcameracrack.dylib 的 NSQueue 类
//
//  逆向特征：
//    - "NSQueue initialized with capacity: %lu (SampleBuffer mode)"
//    - bufferLock 使用 NSRecursiveLock（不是 NSLock）
//    - 支持 PixelBuffer 和 SampleBuffer 双模式
//    - peekPixelBuffer / copyCurrentFrame / getCurrentFrame 三种读取方式
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

@interface NSQueue : NSObject

// 模式标记（YES=PixelBuffer, NO=SampleBuffer）
@property (nonatomic, assign) BOOL isPixelBufferMode;
@property (nonatomic, readonly) NSUInteger count;
@property (nonatomic, readonly) NSUInteger capacity;

// 初始化
- (instancetype)initWithCapacity:(NSUInteger)capacity pixelBufferMode:(BOOL)pixelBufferMode;

// PixelBuffer 模式
- (void)enqueuePixelBuffer:(CVPixelBufferRef)buffer;
- (CVPixelBufferRef)dequeuePixelBuffer CF_RETURNS_RETAINED;
- (CVPixelBufferRef)peekPixelBuffer;                    // 不 retain，不移除
- (CVPixelBufferRef)copyCurrentFrame CF_RETURNS_RETAINED; // retain 当前帧
- (CVPixelBufferRef)getCurrentFrame;                    // 无锁快速访问（不 retain）

// SampleBuffer 模式
- (void)enqueueSampleBuffer:(CMSampleBufferRef)buffer;
- (CMSampleBufferRef)dequeueSampleBuffer CF_RETURNS_RETAINED;

// 清空
- (void)clearFrameQueue;

@end
