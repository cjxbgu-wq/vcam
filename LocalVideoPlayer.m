#import "LocalVideoPlayer.h"
#import "NSQueue.h"

// 文件日志（mediaserverd 中 NSLog 不可见）
static void lvp_log(NSString *msg) {
    static volatile int32_t logCount = 0;
    int32_t n = __sync_add_and_fetch(&logCount, 1);
    if (n > 100) return;
    FILE *f = fopen("/tmp/vcam_player_log.txt", "a");
    if (f) {
        fprintf(f, "[%s] %s\n", [[NSDate date].description UTF8String], [msg UTF8String]);
        fflush(f);
        fclose(f);
    }
}

@interface LocalVideoPlayer ()
@property (nonatomic, strong) NSQueue *frameQueue;
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, strong) AVAsset *asset;
@property (nonatomic, strong) AVAssetTrack *videoTrack;
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *videoOutput;
@property (nonatomic, assign) BOOL decoding;
@property (nonatomic, assign) BOOL videoLoaded;
@property (nonatomic, assign) size_t videoW;
@property (nonatomic, assign) size_t videoH;
@property (nonatomic, assign) Float64 fps;
@property (nonatomic, assign) CMTime videoDuration;
@property (nonatomic, strong) NSString *videoPath;
@property (nonatomic, assign) BOOL loop;
@end

@implementation LocalVideoPlayer

+ (instancetype)sharedInstance {
    static LocalVideoPlayer *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LocalVideoPlayer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _frameQueue = [[NSQueue alloc] initWithCapacity:5];
        _decodeQueue = dispatch_queue_create("com.vcam.videoreader", DISPATCH_QUEUE_SERIAL);
        _decoding = NO;
        _videoLoaded = NO;
        _loop = YES;
        lvp_log(@"[LocalVideoPlayer] initialized with frame queue (capacity: 5)");
    }
    return self;
}

#pragma mark - 加载视频

- (BOOL)loadVideoAtPath:(NSString *)path {
    lvp_log([NSString stringWithFormat:@"[LocalVideoPlayer] Loading video: %@", path]);

    // 清理旧状态
    [self stopDecodingThread];
    [self clearFrameQueue];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        lvp_log([NSString stringWithFormat:@"[LocalVideoPlayer] Video file not found: %@", path]);
        return NO;
    }

    _videoPath = [path copy];

    NSURL *url = [NSURL fileURLWithPath:path];
    AVAsset *asset = [AVAsset assetWithURL:url];

    // 异步加载 tracks
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL loadOK = NO;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
        NSError *err = nil;
        AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&err];
        if (status == AVKeyValueStatusLoaded) {
            AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
            if (track) {
                self.asset = asset;
                self.videoTrack = track;
                self.videoW = (size_t)track.naturalSize.width;
                self.videoH = (size_t)track.naturalSize.height;
                self.fps = track.nominalFrameRate > 0 ? track.nominalFrameRate : 30.0;
                self.videoDuration = asset.duration;
                loadOK = YES;
                lvp_log([NSString stringWithFormat:@"[LocalVideoPlayer] Video loaded: %@ (%.0fx%.0f @ %.1ffps, %.1fs)",
                         path, track.naturalSize.width, track.naturalSize.height,
                         track.nominalFrameRate, CMTimeGetSeconds(asset.duration)]);
            } else {
                lvp_log(@"[LocalVideoPlayer] No video track found");
            }
        } else {
            lvp_log([NSString stringWithFormat:@"[LocalVideoPlayer] Failed to load tracks: %@", err]);
        }
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));

    if (!loadOK) {
        lvp_log(@"[LocalVideoPlayer] Failed to load video");
        return NO;
    }

    // 创建 AVAssetReader
    NSError *readerErr = nil;
    _assetReader = [[AVAssetReader alloc] initWithAsset:_asset error:&readerErr];
    if (readerErr || !_assetReader) {
        lvp_log([NSString stringWithFormat:@"[LocalVideoPlayer] Failed to create asset reader: %@", readerErr]);
        return NO;
    }

    // 创建 video output（BGRA 格式）
    // CRITICAL: 不使用 IOSurface 属性（mediaserverd 会崩溃）
    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    _videoOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:_videoTrack outputSettings:outputSettings];
    _videoOutput.alwaysCopiesSampleData = NO;
    if (![_assetReader canAddOutput:_videoOutput]) {
        lvp_log(@"[LocalVideoPlayer] Cannot add video output");
        return NO;
    }
    [_assetReader addOutput:_videoOutput];

    if (![_assetReader startReading]) {
        lvp_log([NSString stringWithFormat:@"[LocalVideoPlayer] Failed to start reading: %@", _assetReader.error]);
        return NO;
    }

    _videoLoaded = YES;
    lvp_log(@"[LocalVideoPlayer] Video loaded successfully, reader started");
    return YES;
}

#pragma mark - 解码线程

- (void)startDecodingThread {
    if (_decoding) return;
    if (!_videoLoaded || !_assetReader) {
        lvp_log(@"[LocalVideoPlayer] Cannot start decoding: not loaded");
        return;
    }
    _decoding = YES;
    lvp_log(@"[LocalVideoPlayer] Decoding thread started");

    __weak typeof(self) weakSelf = self;
    dispatch_async(_decodeQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        while (strongSelf.decoding) {
            @autoreleasepool {
                CMSampleBufferRef sampleBuffer = [strongSelf.videoOutput copyNextSampleBuffer];
                if (sampleBuffer) {
                    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                    if (pixelBuffer) {
                        [strongSelf.frameQueue enqueuePixelBuffer:pixelBuffer];
                    }
                    CFRelease(sampleBuffer);
                } else {
                    // 读取完毕
                    if (strongSelf.assetReader.status == AVAssetReaderStatusCompleted) {
                        if (strongSelf.loop) {
                            // 循环播放：重新创建 reader
                            lvp_log(@"[LocalVideoPlayer] Looping video from beginning");
                            [strongSelf resetReader];
                        } else {
                            lvp_log(@"[LocalVideoPlayer] Decoding loop exited");
                            break;
                        }
                    } else if (strongSelf.assetReader.status == AVAssetReaderStatusFailed) {
                        lvp_log([NSString stringWithFormat:@"[LocalVideoPlayer] Reader failed: %@", strongSelf.assetReader.error]);
                        break;
                    }
                    // 等待下一帧
                    [NSThread sleepForTimeInterval:0.005];
                }
            }
            // 按帧率控制解码速度
            if (strongSelf.fps > 0) {
                [NSThread sleepForTimeInterval:1.0 / strongSelf.fps];
            }
        }
        strongSelf.decoding = NO;
        lvp_log(@"[LocalVideoPlayer] Decoding thread stopped");
    });
}

- (void)resetReader {
    if (!_asset || !_videoTrack) return;

    // 重新创建 reader
    NSError *err = nil;
    AVAssetReader *newReader = [[AVAssetReader alloc] initWithAsset:_asset error:&err];
    if (err || !newReader) return;

    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    AVAssetReaderTrackOutput *newOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:_videoTrack outputSettings:outputSettings];
    newOutput.alwaysCopiesSampleData = NO;
    if ([newReader canAddOutput:newOutput]) {
        [newReader addOutput:newOutput];
        if ([newReader startReading]) {
            _assetReader = newReader;
            _videoOutput = newOutput;
        }
    }
}

- (void)stopDecodingThread {
    _decoding = NO;
    // dispatch_async 是异步的，这里不能等待线程退出
    // 清理 reader
    if (_assetReader) {
        @try {
            [_assetReader cancelReading];
        } @catch (NSException *e) {}
    }
    [self clearFrameQueue];
    lvp_log(@"[LocalVideoPlayer] Decoding stopped");
}

- (void)clearFrameQueue {
    [_frameQueue clear];
}

- (void)prefillFrameQueue {
    if (!_videoLoaded || !_assetReader) return;
    lvp_log(@"[LocalVideoPlayer] Prefilling frame queue...");
    NSUInteger count = 0;
    for (int i = 0; i < 3; i++) { // 预填充3帧
        @autoreleasepool {
            CMSampleBufferRef sampleBuffer = [_videoOutput copyNextSampleBuffer];
            if (sampleBuffer) {
                CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                if (pixelBuffer) {
                    [_frameQueue enqueuePixelBuffer:pixelBuffer];
                    count++;
                }
                CFRelease(sampleBuffer);
            } else {
                break;
            }
        }
    }
    lvp_log([NSString stringWithFormat:@"[LocalVideoPlayer] Frame queue prefilled with %lu frames", (unsigned long)count]);
}

#pragma mark - 帧获取

- (CVPixelBufferRef)copyCurrentFrame {
    return [_frameQueue dequeuePixelBuffer];
}

- (CVPixelBufferRef)peekPixelBuffer {
    return [_frameQueue peekPixelBuffer];
}

- (BOOL)hasValidFrame {
    return _frameQueue.count > 0;
}

- (void)dealloc {
    [self stopDecodingThread];
}

@end
