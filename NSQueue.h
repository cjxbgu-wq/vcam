#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

// 线安全的双模式队列（PixelBuffer / SampleBuffer）
// 解码线程 → 预渲染线程 / hook 函数之间的帧传递
@interface NSQueue : NSObject

- (instancetype)initWithCapacity:(NSUInteger)capacity;

// PixelBuffer 模式
- (void)enqueuePixelBuffer:(CVPixelBufferRef)buffer;
- (CVPixelBufferRef)dequeuePixelBuffer;
- (CVPixelBufferRef)peekPixelBuffer; // 查看最新帧（retained，不出队）
- (CVPixelBufferRef)copyCurrentFrame; // 同 peekPixelBuffer

// SampleBuffer 模式
- (void)enqueueSampleBuffer:(CMSampleBufferRef)buffer;
- (CMSampleBufferRef)dequeueSampleBuffer;

// 通用
- (void)clear;
@property (nonatomic, readonly) NSUInteger count;

@end
