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

// 日志总开关(2026-08-16, diskwrites 崩溃循环止血): 默认静默, vc.plist "logEnabled=YES" 打开
static BOOL vcam_log_enabled(void) {
    static int cached = -1;
    if (cached < 0) {
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
            cached = (d && d[@"logEnabled"]) ? [d[@"logEnabled"] boolValue] : 0;
        } @catch (NSException *e) { cached = 0; }
    }
    return cached == 1;
}

static void vcam_player_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
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

// PTS 实测有效帧率(支撑 effectiveFps readonly)
@property (nonatomic, assign) CGFloat effectiveFpsInternal;
@property (nonatomic, assign) BOOL hasLastPTS;
@property (nonatomic, assign) double lastPTS;

// AVURLAsset/track 按路径复用(2026-08-15, mediaserverd watchdog 根因修复):
// 每次重载(重启后 enable/重播/切源)新建 AVURLAsset + 同步 tracksWithMediaType
// 会向 AVFoundation 的 CommonURLAsset* 通知队列派发任务, mediaserverd 中该队列
// 卡住 60s → WATCHDOG 杀进程 → 所有相机(系统+App)断连黑屏。
// 同路径复用已解析的 asset/track, 不再重复触发队列
@property (nonatomic, copy) NSString *assetPath;
@property (nonatomic, strong) AVURLAsset *reusableAsset;
@property (nonatomic, strong) AVAssetTrack *reusableTrack;

// 加载请求串行化(2026-08-16, mediaserverd SIGSEGV 崩溃循环根因修复):
// 旧实现 loadVideoFile 在 processingQueue 上 stopDecodingThread 只等 1s 即放弃,
// 解码线程可能仍阻塞在 copyNextSampleBuffer 内, 随后 _assetReader 被替换 →
// 旧 reader 被 ARC 释放(仍被解码线程使用) → use-after-free → SIGSEGV →
// mediaserverd 反复崩溃 → AVFoundation 内部状态损坏(CommonURLAsset 队列永久卡死)
// → watchdog 60s kill → 180s userspace panic。
// 修复: AVAssetReader/TrackOutput 的 create/read/cancel/release 全部归解码线程,
// 外部线程只投递"待加载路径 + 代数", 解码线程检测代数变化后自行重建 reader。
@property (nonatomic, assign) volatile int64_t requestedLoadGen;
@property (nonatomic, assign) volatile int64_t appliedLoadGen;
@property (nonatomic, copy) NSString *pendingPath;

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
        // gpuProcessor/preprocessContext 不再本地创建(2026-08-16): 从未使用,
        // 每进程白创建 4 transfer + 2 rotation session 和 CIContext(VCamCore 会注入自己的实例)
        _preloadCache = [[NSMutableArray alloc] init];
        _preloadInfo = [[NSMutableDictionary alloc] init];
        _stateLock = [[NSLock alloc] init];
        _reloadGeneration = 0;
        _currentGeneration = 0;
        _effectiveFpsInternal = 0;
        _hasLastPTS = NO;
        _lastPTS = 0;
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

// effectiveFps: PTS 实测优先, 回退标称帧率, 再回退 30
- (CGFloat)effectiveFps {
    if (_effectiveFpsInternal > 1.0) return _effectiveFpsInternal;
    if (_videoFps > 1.0) return _videoFps;
    return 30.0;
}

// 解码分辨率上限(2026-08-16 发热优化): kCVPixelBufferWidth/HeightKey 直接指定解码
// 输出尺寸, AVAssetReader 底层走 VT 缩放解码 —— 超上限的源(如 4K)按上限降采样解码,
// SW 解码 CPU 随像素数线性下降(4K→2048 长边 ≈ 3.5x)。预览流 ≤1080p 无画质损失,
// 拍照流放大略柔(可接受, 换取整机不发热不卡顿)。
// vc.plist "decodeMaxEdge": 0=不限制(原始分辨率), 默认 2048
static size_t vcam_decode_max_edge(void) {
    static int cached = -1;
    if (cached < 0) {
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
            NSInteger v = d ? [d[@"decodeMaxEdge"] integerValue] : 2048;
            cached = (int)(v > 0 ? v : (v == 0 ? 0 : 2048));
        } @catch (NSException *e) { cached = 2048; }
    }
    return (size_t)cached;
}

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

    NSURL *url = [NSURL fileURLWithPath:path];
    _currentVideoPath = path;
    _mediaType = VCamMediaTypeVideo;
    // 重置 PTS 实测状态(新视频从第一帧重新采样)
    _hasLastPTS = NO;
    _lastPTS = 0;
    _effectiveFpsInternal = 0;

    // asset/track 复用: 同路径重载(重播/重启后 enable/文件 watcher)不重建,
    // 避免重复触发 CommonURLAsset* 队列(mediaserverd watchdog 根因)
    if (![_assetPath isEqualToString:path] || !_reusableAsset) {
        // 新路径: 重建 asset + 解析 track(仅此一次走同步 track 加载)
        NSDictionary *opts = @{AVURLAssetPreferPreciseDurationAndTimingKey: @NO};
        _reusableAsset = [AVURLAsset URLAssetWithURL:url options:opts];
        _reusableTrack = nil;
        _assetPath = [path copy];
        vcam_player_log([NSString stringWithFormat:@"[vcam] New AVURLAsset created for %@", path]);
    }
    _urlAsset = _reusableAsset;

    if (!_reusableTrack) {
        NSArray *tracks = [_urlAsset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count == 0) {
            vcam_player_log(@"No video track found");
            if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:4 userInfo:@{NSLocalizedDescriptionKey:@"No video track"}]);
            return;
        }
        _reusableTrack = tracks[0];
    }
    _videoTrack = _reusableTrack;

    // 获取视频信息
    _videoWidth = (size_t)_videoTrack.naturalSize.width;
    _videoHeight = (size_t)_videoTrack.naturalSize.height;
    _videoFps = _videoTrack.nominalFrameRate;
    _videoDuration = CMTimeGetSeconds(_urlAsset.duration);

    // 解码降采样(2026-08-16 发热优化): 超上限源按上限等比缩放解码输出尺寸(偶数对齐,
    // YUV 平面要求)。1080p 及以下源不受影响。
    size_t maxEdge = vcam_decode_max_edge();
    if (maxEdge > 0) {
        size_t longEdge = MAX(_videoWidth, _videoHeight);
        if (longEdge > maxEdge) {
            double scale = (double)maxEdge / (double)longEdge;
            size_t nw = ((size_t)((double)_videoWidth * scale)) & ~1u;
            size_t nh = ((size_t)((double)_videoHeight * scale)) & ~1u;
            if (nw >= 2 && nh >= 2) {
                vcam_player_log([NSString stringWithFormat:
                    @"[vcam] decode downscale: %zux%zu -> %zux%zu (maxEdge=%zu, CPU ~%.1fx down)",
                    _videoWidth, _videoHeight, nw, nh, maxEdge,
                    (double)(_videoWidth * _videoHeight) / (double)(nw * nh)]);
                _videoWidth = nw;
                _videoHeight = nh;
            }
        }
    }

    // 视频自带旋转(preferredTransform): AVAssetReader 解码帧不应用它,
    // 记录下来由预渲染补偿(否则换视频后画面 180°/90° 翻转)
    CGAffineTransform pt = _videoTrack.preferredTransform;
    if (pt.a == 0 && pt.b == 1 && pt.c == -1 && pt.d == 0) {
        _preferredRotation = 90;
    } else if (pt.a == -1 && pt.b == 0 && pt.c == 0 && pt.d == -1) {
        _preferredRotation = 180;
    } else if (pt.a == 0 && pt.b == -1 && pt.c == 1 && pt.d == 0) {
        _preferredRotation = 270;
    } else {
        _preferredRotation = 0;
    }

    vcam_player_log([NSString stringWithFormat:@"[vcam] Video loaded: %@ (%.0fx%.0f @ %.1ffps, %.1fs, preferredRot=%d)",
                     path, (double)_videoWidth, (double)_videoHeight, _videoFps, _videoDuration, _preferredRotation]);

    // reader 重建投递解码线程(2026-08-16 线程安全修复): 本线程不触碰
    // _assetReader/_videoOutput(解码线程可能正阻塞在 copyNextSampleBuffer 内,
    // 此处替换会 free 正在使用的 reader → SIGSEGV)。参数(width/height/track/asset)
    // 已在代数自增前全部写完, 解码线程检测代数变化后用新参数自行重建。
    _pendingPath = [path copy];
    __sync_add_and_fetch(&_requestedLoadGen, 1);

    // 确保解码线程在跑(已在跑则 no-op), 连点合并: 代数只增, 解码线程只应用最新
    [self startDecodingThread];

    if (completion) completion(YES, nil);
}

// 解码线程内重建 reader(仅 decodeLoop 调用 —— reader 生命周期单线程持有,
// create/read/cancel/release 全在此线程, 无 use-after-free 可能)
- (void)rebuildReaderOnDecodeThread {
    if (!_urlAsset || !_videoTrack) return;

    // 释放旧 reader(同线程, 安全)
    if (_assetReader) {
        [_assetReader cancelReading];
        _assetReader = nil;
    }
    _videoOutput = nil;
    [self clearFrameQueue];

    NSError *readerErr = nil;
    _assetReader = [[AVAssetReader alloc] initWithAsset:_urlAsset error:&readerErr];
    if (readerErr || !_assetReader) {
        vcam_player_log([NSString stringWithFormat:@"[vcam] Failed to create asset reader: %@", readerErr]);
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
        _assetReader = nil;
        _videoOutput = nil;
        return;
    }
    [_assetReader addOutput:_videoOutput];

    if (![_assetReader startReading]) {
        vcam_player_log([NSString stringWithFormat:@"[vcam] Failed to start reading: %@", _assetReader.error]);
        [_assetReader cancelReading];
        _assetReader = nil;
        _videoOutput = nil;
        return;
    }

    // 预填几帧(等价旧 prefillFrameQueue, 但在解码线程 —— reader 单线程持有)
    NSUInteger prefilled = 0;
    while (prefilled < 5 && prefilled < _frameQueue.capacity) {
        CVPixelBufferRef b = [self readNextFrame];
        if (!b) break;
        [_frameQueue enqueuePixelBuffer:b];
        CVPixelBufferRelease(b);
        prefilled++;
    }
    vcam_player_log([NSString stringWithFormat:@"[vcam] Reader rebuilt on decode thread: %@ (prefilled %lu frames, gen=%lld)",
                     _pendingPath.lastPathComponent, (unsigned long)prefilled, (long long)_appliedLoadGen]);
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

#pragma mark - 帧读取（仅解码线程调用）

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
        // PTS 实测帧率校准: nominalFrameRate 是采样近似(VFR/转码视频常低估, 如 30fps
        // 报 14.6), 节拍按标称跑会导致慢放→卡顿观感。用相邻帧 PTS 差实测校准
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        double ptsSec = CMTimeGetSeconds(pts);
        if (CMTIME_IS_VALID(pts) && !isnan(ptsSec)) {
            if (_hasLastPTS && ptsSec > _lastPTS) {
                double interval = ptsSec - _lastPTS;
                if (interval >= 0.005 && interval <= 0.2) {  // 5~200ms 有效帧间隔(5~200fps)
                    double inst = 1.0 / interval;
                    // EMA 平滑: 快速收敛 + 抗单帧抖动; 循环重读(PTS 回绕递减)不更新间隔
                    _effectiveFpsInternal = (_effectiveFpsInternal > 1.0)
                        ? (_effectiveFpsInternal * 0.8 + inst * 0.2) : inst;
                }
            }
            _lastPTS = ptsSec;
            _hasLastPTS = YES;
        }
    }
    CFRelease(sampleBuffer);
    return pixelBuffer;
}

- (void)resetReaderForLoop {
    // 限流(2026-08-16): 每 12 次循环记 1 条(5s 视频 ~1 分钟 1 条, disk writes 限额保护)
    static int loopLogCounter = 0;
    if (loopLogCounter++ % 12 == 0) {
        vcam_player_log(@"[vcam] Looping video from beginning");
    }

    // 显式释放旧 reader/output 后再新建(2026-08-15): 避免新旧 reader 并存瞬间
    // 对同一 asset 双重持有/派发通知, 加重 CommonURLAsset* 队列负担(watchdog 根因)
    [_assetReader cancelReading];
    _assetReader = nil;
    _videoOutput = nil;

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
    // 常驻线程(2026-08-16): 只创建一次, 不再启停 —— stop/start 交替存在竞争窗口
    // (stop 1s 超时放弃后旧线程可能仍在 copyNextSampleBuffer 内, 此时 start 新线程
    // → 双 decodeLoop 并发触碰 reader)。disable 仅置 _shouldDecode=NO 空转睡眠。
    if (_decodeThread && _isDecoding) {
        // 线程仍在(空转睡眠): 恢复解码标志即可(修复 2026-08-16 恢复 bug ——
        // 旧版此处直接 return, disable→enable 后 _shouldDecode 恒为 NO, 画面冻结)
        _shouldDecode = YES;
        return;
    }
    _shouldDecode = YES;
    _isDecoding = YES;

    _decodeThread = [[NSThread alloc] initWithTarget:self selector:@selector(decodeLoop) object:nil];
    _decodeThread.name = @"vcam.decoder";
    // Default 优先级(2026-08-16 卡顿修复): Utility 下解码线程被相机多流 render/系统
    // RPC 饿死, 跟不上源帧率 → 帧队列断供 → 预渲染重复帧 → 替换画面卡顿掉帧。
    // 升 Default 与服务线程同级竞争(8-15 降 Utility 时 render 还是全局锁串行的大负载,
    // 现在 per-stream 并行+微型流跳过+空闲门控后我们负载已大降, Default 安全)
    _decodeThread.qualityOfService = NSQualityOfServiceDefault;
    [_decodeThread start];
    vcam_player_log(@"[vcam] Decoding thread started (persistent)");
}

- (void)stopDecodingThread {
    // 常驻线程配套(2026-08-16): 不 cancel/join 线程, 只置停止位。
    // decodeLoop 空转 0.1s 睡眠; reader 不在此动(归解码线程, 由下次 enable 的
    // gen 变化或线程退出统一清理), 消除跨线程触碰 reader 的一切路径
    _shouldDecode = NO;
    vcam_player_log(@"[vcam] Decoding paused (thread persistent)");
}

- (void)decodeLoop {
    @autoreleasepool {
        // 绝对时间节拍器(与预渲染线程一致): nextTick += interval 累计节拍,
        // 消除"解码耗时+sleep"逐帧累加导致的实际帧率偏低 → 预渲染队列断供 → 卡顿掉帧
        CFAbsoluteTime nextTick = CFAbsoluteTimeGetCurrent();
        while (YES) {
            @autoreleasepool {
                if (!_shouldDecode) {
                    // disable: 空转等待(常驻线程约定, 不退出)
                    [NSThread sleepForTimeInterval:0.1];
                    continue;
                }

                // 加载代数变化 → 在本线程重建 reader(2026-08-16 线程安全修复:
                // reader 的 create/read/cancel/release 全部归解码线程,
                // 外部线程只投递代数, 消除切源/重播/enable 时的 use-after-free)
                if (_requestedLoadGen != _appliedLoadGen) {
                    _appliedLoadGen = _requestedLoadGen;
                    if (_mediaType == VCamMediaTypeVideo) {
                        [self rebuildReaderOnDecodeThread];
                    }
                }

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
                    // effectiveFps = PTS 实测(校准 nominalFrameRate 低估导致的慢放卡顿)
                    double frameInterval = 1.0 / [self effectiveFps];
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

    __weak typeof(self) weakSelf = self;
    // 注册 Darwin 通知监听（reload-media, 仅一次: registerForNotification 非幂等,
    // 重复注册会累积回调 → reload 通知触发 N 次 reloadMedia)
    static BOOL reloadListenerRegistered = NO;
    if (!reloadListenerRegistered) {
        reloadListenerRegistered = YES;
        [[VCamNotify sharedInstance] registerForNotification:VCamNotifyReloadMedia callback:^(NSString *name) {
            [weakSelf reloadMedia];
        }];
        vcam_player_log([NSString stringWithFormat:@"[vcam] Registered VCamNotify listener for reload-media"]);
    }

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

    // 文件内容已变化(inode/size/mtime): 复用的 asset 指向旧文件数据, 必须丢弃重建
    _reusableAsset = nil;
    _reusableTrack = nil;
    _assetPath = nil;

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
