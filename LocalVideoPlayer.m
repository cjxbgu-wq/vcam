//
//  LocalVideoPlayer.m
//  VCamPlus
//
//  对标 vcameracrack.dylib 的 LocalVideoPlayer 实现
//  核心功能：
//    1. AVAssetReader 视频解码（BGRA 输出）
//    2. 帧队列管理（NSQueue）
//    3. 预填充帧队列（prefillFrameQueue）
//    4. 循环播放（AVAssetReader 读取完毕后重置）
//    5. 文件监听（inode/size/mtime 变化检测）
//    6. reload generation 机制（防止过期重载）
//    7. 图片支持（ImageIO 加载）
//    8. activePlaybackPath 管理（从 plist 读取活动源）
//

#import "LocalVideoPlayer.h"
#import "VCamNotify.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <AVFoundation/AVFoundation.h>

static void vcam_player_log(NSString *msg) {
    @try {
        NSString *logPath = @"/tmp/vcam_player_log.txt";
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

@interface LocalVideoPlayer ()
// AVAssetReader 内部状态
@property (nonatomic, strong) AVURLAsset *urlAsset;
@property (nonatomic, strong) NSMutableArray *preloadCache;  // 预加载缓存
@property (nonatomic, strong) NSMutableDictionary *preloadInfo; // 预加载信息

// 文件监听
@property (nonatomic, strong) dispatch_source_t watchTimer;
@property (nonatomic, copy) NSString *watchPath;
@property (nonatomic, assign) unsigned long long lastFileSize;
@property (nonatomic, assign) unsigned long long lastInode;
@property (nonatomic, assign) double lastMtime;

// reload generation（防止过期重载）
@property (nonatomic, assign) int64_t reloadGeneration;
@property (nonatomic, assign) int64_t currentGeneration;

// 解码线程控制
@property (nonatomic, assign) BOOL shouldDecode;
@property (nonatomic, strong) NSThread *decodeThread;

// 锁
@property (nonatomic, strong) NSLock *stateLock;
@end

@implementation LocalVideoPlayer

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    self = [super init];
    if (self) {
        _frameQueue = [[NSQueue alloc] initWithCapacity:capacity pixelBufferMode:YES];
        _decodeQueue = dispatch_queue_create("com.vcam.videoreader", DISPATCH_QUEUE_SERIAL);
        _processingQueue = dispatch_queue_create("com.vcam.decoder", DISPATCH_QUEUE_SERIAL);
        _preprocessContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
        _gpuProcessor = [[GPUImageProcessor alloc] init];
        _preloadCache = [[NSMutableArray alloc] init];
        _preloadInfo = [[NSMutableDictionary alloc] init];
        _stateLock = [[NSLock alloc] init];
        _reloadGeneration = 0;
        _currentGeneration = 0;
        _shouldDecode = NO;
        _enabled = NO;
        _isEnabled = NO;
        _preprocessEnabled = YES;
        _mediaType = VCamMediaTypeUnknown;
        _cachedImageBuffer = NULL;
        vcam_player_log([NSString stringWithFormat:@"[vcam] LocalVideoPlayer initialized with frame queue (capacity: %ld) and preprocess pipeline", (long)capacity]);
    }
    return self;
}

- (void)dealloc {
    [self stopDecodingThread];
    [self stopWatchingFile];
    [self clearFrameQueue];
    if (_cachedImageBuffer) {
        CVPixelBufferRelease(_cachedImageBuffer);
        _cachedImageBuffer = NULL;
    }
    vcam_player_log(@"[vcam] LocalVideoPlayer deallocated");
}

#pragma mark - 媒体类型检测

+ (VCamMediaType)detectMediaType:(NSString *)path {
    if (!path || path.length == 0) return VCamMediaTypeUnknown;
    NSString *ext = path.pathExtension.lowercaseString;
    // 视频格式
    NSArray *videoExts = @[@"mp4", @"mov", @"m4v", @"3gp", @"avi", @"mkv"];
    if ([videoExts containsObject:ext]) return VCamMediaTypeVideo;
    // 图片格式
    NSArray *imageExts = @[@"jpg", @"jpeg", @"png", @"heic", @"heif", @"bmp", @"gif"];
    if ([imageExts containsObject:ext]) return VCamMediaTypeImage;
    return VCamMediaTypeUnknown;
}

#pragma mark - 视频加载

- (void)loadVideoAtPath:(NSString *)path completion:(void(^)(BOOL success, NSError *error))completion {
    if (!path || path.length == 0) {
        vcam_player_log(@"Video file not found");
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:1 userInfo:@{NSLocalizedDescriptionKey:@"No path"}]);
        return;
    }

    // 检查文件是否存在
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        vcam_player_log([NSString stringWithFormat:@"[vcam] activePlaybackPath in plist but file missing: %@", path]);
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:2 userInfo:@{NSLocalizedDescriptionKey:@"File not found"}]);
        return;
    }

    // 检测媒体类型
    VCamMediaType type = [LocalVideoPlayer detectMediaType:path];
    if (type == VCamMediaTypeVideo) {
        vcam_player_log([NSString stringWithFormat:@"[vcam] Detected video file: %@", path]);
        [self loadVideoFile:path completion:completion];
    } else if (type == VCamMediaTypeImage) {
        vcam_player_log([NSString stringWithFormat:@"[vcam] Detected image file: %@", path]);
        [self loadImageFile:path completion:completion];
    } else {
        vcam_player_log([NSString stringWithFormat:@"[vcam] Unsupported or missing media file: %@", path]);
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Unsupported format"}]);
    }
}

- (void)loadVideoFile:(NSString *)path completion:(void(^)(BOOL success, NSError *error))completion {
    vcam_player_log([NSString stringWithFormat:@"[vcam] Loading video: %@", path]);

    // 停止之前的解码
    [self stopDecodingThread];
    [self clearFrameQueue];

    NSURL *url = [NSURL fileURLWithPath:path];
    _urlAsset = [AVURLAsset assetWithURL:url];
    _currentVideoPath = path;
    _mediaType = VCamMediaTypeVideo;

    // 获取视频轨道
    NSArray *tracks = [_urlAsset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) {
        vcam_player_log(@"No video track found");
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:4 userInfo:@{NSLocalizedDescriptionKey:@"No video track"}]);
        return;
    }
    _videoTrack = tracks[0];

    // 获取视频信息
    _videoWidth = (size_t)_videoTrack.naturalSize.width;
    _videoHeight = (size_t)_videoTrack.naturalSize.height;
    _videoFps = _videoTrack.nominalFrameRate;
    _videoDuration = CMTimeGetSeconds(_urlAsset.duration);

    vcam_player_log([NSString stringWithFormat:@"[vcam] Video loaded: %@ (%.0fx%.0f @ %.1ffps, %.1fs)",
                     path, (double)_videoWidth, (double)_videoHeight, _videoFps, _videoDuration]);

    // 创建 AVAssetReader
    NSError *readerErr = nil;
    _assetReader = [[AVAssetReader alloc] initWithAsset:_urlAsset error:&readerErr];
    if (readerErr || !_assetReader) {
        vcam_player_log([NSString stringWithFormat:@"[vcam] Failed to create asset reader: %@", readerErr]);
        if (completion) completion(NO, readerErr);
        return;
    }

    // 创建输出（420f 双平面 full-range: 静止照片流(420f)原格式直通颜色正确(用户已验证),
    // 私有格式目标走两步法(先缩放后转格式)修复黑帧过曝
    // render 源用 YUV 转私有格式时 range 保持）
    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @((OSType)'420f'),
        (id)kCVPixelBufferWidthKey:  @(_videoWidth),
        (id)kCVPixelBufferHeightKey: @(_videoHeight),
    };
    _videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:_videoTrack outputSettings:outputSettings];
    _videoOutput.alwaysCopiesSampleData = NO;

    if (![_assetReader canAddOutput:_videoOutput]) {
        vcam_player_log(@"[vcam] Cannot add video output");
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:5 userInfo:@{NSLocalizedDescriptionKey:@"Cannot add output"}]);
        return;
    }
    [_assetReader addOutput:_videoOutput];

    if (![_assetReader startReading]) {
        vcam_player_log([NSString stringWithFormat:@"[vcam] Failed to start reading: %@", _assetReader.error]);
        if (completion) completion(NO, _assetReader.error);
        return;
    }

    // 预填充帧队列
    [self prefillFrameQueue];

    // 启动解码线程
    [self startDecodingThread];

    if (completion) completion(YES, nil);
}

- (void)loadImageFile:(NSString *)path completion:(void(^)(BOOL success, NSError *error))completion {
    vcam_player_log([NSString stringWithFormat:@"[vcam] Loading image: %@", path]);

    [self stopDecodingThread];
    [self clearFrameQueue];

    _currentVideoPath = path;
    _mediaType = VCamMediaTypeImage;

    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nil);
    if (!source) {
        vcam_player_log(@"[vcam] Image file not found");
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:6 userInfo:@{NSLocalizedDescriptionKey:@"Image not found"}]);
        return;
    }

    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil);
    CFRelease(source);
    if (!cgImage) {
        vcam_player_log(@"Failed to decode image");
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:7 userInfo:@{NSLocalizedDescriptionKey:@"Decode failed"}]);
        return;
    }

    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);

    // 创建 CVPixelBuffer（不带 IOSurface 属性）
    CVPixelBufferRef pixelBuffer = NULL;
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, NULL, &pixelBuffer);
    if (status != noErr || !pixelBuffer) {
        vcam_player_log([NSString stringWithFormat:@"[vcam] CVPixelBufferCreate failed: %d", (int)status]);
        CGImageRelease(cgImage);
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:8 userInfo:@{NSLocalizedDescriptionKey:@"Buffer create failed"}]);
        return;
    }

    // 渲染图片到 pixelBuffer
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    CGContextRef ctx = CGBitmapContextCreate(
        CVPixelBufferGetBaseAddress(pixelBuffer),
        width, height, 8, CVPixelBufferGetBytesPerRow(pixelBuffer),
        CGColorSpaceCreateDeviceRGB(),
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
    );
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    CGImageRelease(cgImage);

    // 缓存图片帧
    if (_cachedImageBuffer) {
        CVPixelBufferRelease(_cachedImageBuffer);
    }
    _cachedImageBuffer = pixelBuffer;
    CVPixelBufferRetain(_cachedImageBuffer);

    // 放入帧队列
    [_frameQueue enqueuePixelBuffer:pixelBuffer];

    _videoWidth = width;
    _videoHeight = height;
    vcam_player_log([NSString stringWithFormat:@"[vcam] Image loaded: %@ (%zux%zu)", path, width, height]);

    if (completion) completion(YES, nil);
}

#pragma mark - 预填充帧队列

- (void)prefillFrameQueue {
    if (_mediaType != VCamMediaTypeVideo) return;

    vcam_player_log(@"[vcam] Prefilling frame queue...");
    NSUInteger count = 0;
    NSUInteger targetCount = MIN(5, _frameQueue.capacity);

    for (NSUInteger i = 0; i < targetCount; i++) {
        CVPixelBufferRef buffer = [self readNextFrame];
        if (!buffer) break;
        [_frameQueue enqueuePixelBuffer:buffer];
        CVPixelBufferRelease(buffer);  // 队列已 retain
        count++;
    }

    vcam_player_log([NSString stringWithFormat:@"[vcam] Frame queue prefilled with %lu frames", (unsigned long)count]);
}

- (CVPixelBufferRef)readNextFrame CF_RETURNS_RETAINED {
    if (!_videoOutput || _assetReader.status != AVAssetReaderStatusReading) {
        return NULL;
    }

    CMSampleBufferRef sampleBuffer = [_videoOutput copyNextSampleBuffer];
    if (!sampleBuffer) {
        // 读取完毕，需要循环
        if (_assetReader.status == AVAssetReaderStatusCompleted) {
            [self resetReaderForLoop];
        }
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer) {
        CVPixelBufferRetain(pixelBuffer);
    }
    CFRelease(sampleBuffer);
    return pixelBuffer;
}

- (void)resetReaderForLoop {
    vcam_player_log(@"[vcam] Looping video from beginning");

    // 重新创建 reader
    [_assetReader cancelReading];
    NSError *err = nil;
    _assetReader = [[AVAssetReader alloc] initWithAsset:_urlAsset error:&err];
    if (err || !_assetReader) {
        vcam_player_log([NSString stringWithFormat:@"[vcam] Failed to create asset reader for loop: %@", err]);
        return;
    }

    // 重新创建输出（420f, 同上）
    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @((OSType)'420f'),
        (id)kCVPixelBufferWidthKey:  @(_videoWidth),
        (id)kCVPixelBufferHeightKey: @(_videoHeight),
    };
    _videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:_videoTrack outputSettings:outputSettings];
    _videoOutput.alwaysCopiesSampleData = NO;
    [_assetReader addOutput:_videoOutput];
    [_assetReader startReading];
}

#pragma mark - 解码线程

- (void)startDecodingThread {
    if (_isDecoding) return;
    _shouldDecode = YES;
    _isDecoding = YES;

    _decodeThread = [[NSThread alloc] initWithTarget:self selector:@selector(decodeLoop) object:nil];
    _decodeThread.name = @"vcam.decoder";
    [_decodeThread start];
    vcam_player_log(@"[vcam] Decoding thread started");
}

- (void)stopDecodingThread {
    _shouldDecode = NO;
    if (_decodeThread) {
        [_decodeThread cancel];
        // 等待线程退出（最多 1 秒）
        NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:1.0];
        while (_decodeThread.isExecuting && [timeout timeIntervalSinceNow] > 0) {
            [NSThread sleepForTimeInterval:0.01];
        }
        _decodeThread = nil;
    }
    _isDecoding = NO;
    vcam_player_log(@"[vcam] Decoding thread stopped");
}

- (void)decodeLoop {
    @autoreleasepool {
        // 绝对时间节拍器(与预渲染线程一致): nextTick += interval 累计节拍,
        // 消除"解码耗时+sleep"逐帧累加导致的实际帧率偏低 → 预渲染队列断供 → 卡顿掉帧
        CFAbsoluteTime nextTick = CFAbsoluteTimeGetCurrent();
        while (_shouldDecode && !_decodeThread.cancelled) {
            @autoreleasepool {
                if (_mediaType == VCamMediaTypeImage) {
                    // 图片模式：不需要持续解码，只保持缓存帧
                    [NSThread sleepForTimeInterval:0.1];
                    continue;
                }

                // 暂停: 停止取新帧, 帧队列不再进帧, 预渲染回退 copyCurrentFrame 冻结画面;
                // 同时重置节拍基线, 恢复播放时不追帧(不快进)
                if (_paused) {
                    [NSThread sleepForTimeInterval:0.05];
                    nextTick = CFAbsoluteTimeGetCurrent();
                    continue;
                }

                // 视频模式：持续解码
                CVPixelBufferRef buffer = [self readNextFrame];
                if (buffer) {
                    [_frameQueue enqueuePixelBuffer:buffer];
                    CVPixelBufferRelease(buffer);  // 队列已 retain
                    _frameCount++;
                    // 按视频帧率绝对节拍输出(参考逆向: 按时间戳输出帧)
                    double frameInterval = (_videoFps > 1.0) ? (1.0 / _videoFps) : (1.0 / 30.0);
                    nextTick += frameInterval;
                    double wait = nextTick - CFAbsoluteTimeGetCurrent();
                    if (wait > 0.001) {
                        [NSThread sleepForTimeInterval:wait];
                    } else {
                        nextTick = CFAbsoluteTimeGetCurrent();  // 解码耗时超帧间隔, 重置基线防追帧爆发
                    }
                } else {
                    // 没有读到帧，短暂休眠避免忙等; 重置基线避免恢复后爆发
                    [NSThread sleepForTimeInterval:0.005];
                    nextTick = CFAbsoluteTimeGetCurrent();
                }

                // 控制队列大小，避免内存占用过高
                if (_frameQueue.count > _frameQueue.capacity) {
                    [NSThread sleepForTimeInterval:0.01];
                    nextTick = CFAbsoluteTimeGetCurrent();
                }
            }
        }
    }
    vcam_player_log(@"[vcam] Decoding loop exited");
}

#pragma mark - 帧获取

- (CVPixelBufferRef)getCurrentFrame {
    return [_frameQueue getCurrentFrame];
}

- (CVPixelBufferRef)copyCurrentFrame CF_RETURNS_RETAINED {
    return [_frameQueue copyCurrentFrame];
}

#pragma mark - 帧队列管理

- (void)clearFrameQueue {
    [_frameQueue clearFrameQueue];
    vcam_player_log(@"[vcam] Frame queue cleared");
}

#pragma mark - 文件监听

- (void)startWatchingFile:(NSString *)path {
    if (!path || path.length == 0) {
        vcam_player_log(@"[vcam] Cannot watch: invalid path");
        return;
    }

    [self stopWatchingFile];
    _watchPath = [path copy];

    // 初始文件信息
    [self updateFileInfo];

    // 注册 Darwin 通知监听（reload-media）
    __weak typeof(self) weakSelf = self;
    [[VCamNotify sharedInstance] registerForNotification:VCamNotifyReloadMedia callback:^(NSString *name) {
        [weakSelf reloadMedia];
    }];
    vcam_player_log([NSString stringWithFormat:@"[vcam] Registered VCamNotify listener for reload-media"]);

    // 定时检查文件变化（每 2 秒）
    dispatch_queue_t watchQueue = dispatch_queue_create("com.vcam.filewatch", DISPATCH_QUEUE_SERIAL);
    _watchTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, watchQueue);
    dispatch_source_set_timer(_watchTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(_watchTimer, ^{
        [weakSelf checkFileChanges];
    });
    dispatch_resume(_watchTimer);

    vcam_player_log([NSString stringWithFormat:@"[vcam] Started watching file: %@", path]);
}

- (void)stopWatchingFile {
    if (_watchTimer) {
        dispatch_source_cancel(_watchTimer);
        _watchTimer = nil;
    }
    _watchPath = nil;
    if (_watchPath) {
        vcam_player_log(@"[vcam] Stopped watching file");
    }
}

- (void)updateFileInfo {
    if (!_watchPath) return;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:_watchPath error:nil];
    if (attrs) {
        _lastFileSize = [attrs fileSize];
        _lastMtime = [attrs.fileModificationDate timeIntervalSince1970];
        NSNumber *inode = attrs[NSFileSystemFileNumber];
        _lastInode = inode ? [inode unsignedLongLongValue] : 0;
        vcam_player_log([NSString stringWithFormat:@"[vcam] File info - size: %llu, inode: %llu, mtime: %.0f",
                         _lastFileSize, _lastInode, _lastMtime]);
    }
}

- (void)checkFileChanges {
    if (!_watchPath) return;

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:_watchPath error:nil];
    if (!attrs) {
        // 文件被删除
        vcam_player_log([NSString stringWithFormat:@"[vcam] Active source missing, clearing: %@", _watchPath]);
        [self stopDecodingThread];
        [self clearFrameQueue];
        return;
    }

    unsigned long long newSize = [attrs fileSize];
    double newMtime = [attrs.fileModificationDate timeIntervalSince1970];
    NSNumber *inode = attrs[NSFileSystemFileNumber];
    unsigned long long newInode = inode ? [inode unsignedLongLongValue] : 0;

    BOOL changed = NO;
    if (newInode != _lastInode) {
        vcam_player_log([NSString stringWithFormat:@"[vcam] Inode changed: %llu -> %llu", _lastInode, newInode]);
        changed = YES;
    }
    if (newSize != _lastFileSize) {
        vcam_player_log([NSString stringWithFormat:@"[vcam] Size changed: %llu -> %llu", _lastFileSize, newSize]);
        changed = YES;
    }
    if (fabs(newMtime - _lastMtime) > 1.0) {
        vcam_player_log([NSString stringWithFormat:@"[vcam] Modification time changed: %.0f -> %.0f", _lastMtime, newMtime]);
        changed = YES;
    }

    if (changed) {
        _lastFileSize = newSize;
        _lastInode = newInode;
        _lastMtime = newMtime;
        vcam_player_log([NSString stringWithFormat:@"[vcam] Media changed: %@, reloading...", _watchPath]);
        [self reloadMedia];
    }
}

- (void)reloadMedia {
    // reload generation 机制（防止过期重载）
    int64_t gen = __sync_add_and_fetch(&_reloadGeneration, 1);
    __weak typeof(self) weakSelf = self;
    NSString *path = _currentVideoPath;

    vcam_player_log([NSString stringWithFormat:@"[vcam] Reloading media[gen=%ld]: %@ (type: %@)",
                     (long)gen, path, _mediaType == VCamMediaTypeVideo ? @"video" : @"image"]);

    dispatch_async(_processingQueue, ^{
        LocalVideoPlayer *strongSelf = weakSelf;
        if (!strongSelf) return;

        // 检查 generation 是否过期
        if (gen != strongSelf.reloadGeneration) {
            vcam_player_log([NSString stringWithFormat:@"[vcam] Discard stale reload gen=%ld (current=%ld) %@",
                             (long)gen, (long)strongSelf.reloadGeneration, path]);
            return;
        }

        [strongSelf loadVideoAtPath:path completion:^(BOOL success, NSError *error) {
            if (success) {
                if (strongSelf.mediaType == VCamMediaTypeVideo) {
                    vcam_player_log([NSString stringWithFormat:@"[vcam] Video reloaded OK[gen=%ld]: %@", (long)gen, path]);
                } else {
                    vcam_player_log([NSString stringWithFormat:@"[vcam] Image reloaded OK[gen=%ld]", (long)gen]);
                }
            } else {
                if (strongSelf.mediaType == VCamMediaTypeVideo) {
                    vcam_player_log([NSString stringWithFormat:@"[vcam] Failed to reload video[gen=%ld]: %@", (long)gen, error]);
                } else {
                    vcam_player_log([NSString stringWithFormat:@"[vcam] Failed to reload image[gen=%ld]: %@", (long)gen, error]);
                }
            }
        }];
    });
}

@end
