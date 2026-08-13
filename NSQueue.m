#import "NSQueue.h"
#import <CoreMedia/CoreMedia.h>

@interface NSQueue ()
@property (nonatomic, strong) NSRecursiveLock *lock;
@property (nonatomic, strong) NSMutableArray *pixelBuffers;
@property (nonatomic, strong) NSMutableArray *sampleBuffers;
@property (nonatomic, assign) NSUInteger capacity;
@end

@implementation NSQueue

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    self = [super init];
    if (self) {
        _capacity = capacity > 0 ? capacity : 5;
        _lock = [[NSRecursiveLock alloc] init];
        _pixelBuffers = [[NSMutableArray alloc] initWithCapacity:_capacity];
        _sampleBuffers = [[NSMutableArray alloc] initWithCapacity:_capacity];
    }
    return self;
}

#pragma mark - PixelBuffer 模式

- (void)enqueuePixelBuffer:(CVPixelBufferRef)buffer {
    if (!buffer) return;
    CVPixelBufferRetain(buffer);
    [_lock lock];
    [_pixelBuffers addObject:(__bridge id)buffer];
    // 超容量则丢弃最旧帧
    while (_pixelBuffers.count > _capacity) {
        [_pixelBuffers removeObjectAtIndex:0];
    }
    [_lock unlock];
    CVPixelBufferRelease(buffer);
}

- (CVPixelBufferRef)dequeuePixelBuffer {
    [_lock lock];
    if (_pixelBuffers.count == 0) {
        [_lock unlock];
        return NULL;
    }
    // 取最新帧
    CVPixelBufferRef buf = (CVPixelBufferRef)CFBridgingRetain([_pixelBuffers lastObject]);
    [_pixelBuffers removeAllObjects];
    [_lock unlock];
    return buf;
}

- (CVPixelBufferRef)peekPixelBuffer {
    [_lock lock];
    if (_pixelBuffers.count == 0) {
        [_lock unlock];
        return NULL;
    }
    CVPixelBufferRef buf = (__bridge CVPixelBufferRef)[_pixelBuffers lastObject];
    if (buf) CVPixelBufferRetain(buf);
    [_lock unlock];
    return buf;
}

- (CVPixelBufferRef)copyCurrentFrame {
    return [self peekPixelBuffer];
}

#pragma mark - SampleBuffer 模式

- (void)enqueueSampleBuffer:(CMSampleBufferRef)buffer {
    if (!buffer) return;
    CFRetain(buffer);
    [_lock lock];
    [_sampleBuffers addObject:(__bridge id)buffer];
    while (_sampleBuffers.count > _capacity) {
        [_sampleBuffers removeObjectAtIndex:0];
    }
    [_lock unlock];
    CFRelease(buffer);
}

- (CMSampleBufferRef)dequeueSampleBuffer {
    [_lock lock];
    if (_sampleBuffers.count == 0) {
        [_lock unlock];
        return NULL;
    }
    CMSampleBufferRef buf = (CMSampleBufferRef)CFBridgingRetain([_sampleBuffers lastObject]);
    [_sampleBuffers removeAllObjects];
    [_lock unlock];
    return buf;
}

#pragma mark - 通用

- (void)clear {
    [_lock lock];
    [_pixelBuffers removeAllObjects];
    [_sampleBuffers removeAllObjects];
    [_lock unlock];
}

- (NSUInteger)count {
    [_lock lock];
    NSUInteger c = _pixelBuffers.count + _sampleBuffers.count;
    [_lock unlock];
    return c;
}

- (void)dealloc {
    [self clear];
}

@end
