//
//  GPUImageProcessor.h
//  VCamPlus
//
//  图像处理器（对标 vcameracrack.dylib 的 GPUImageProcessor 类）
//
//  逆向特征：
//    - "GPUImageProcessor initialized" / "GPUImageProcessor deallocated"
//    - "VTPixelTransferSession created successfully" / "Failed to create VTPixelTransferSession: %d"
//    - "VTPixelRotationSession created successfully" / "Failed to create VTPixelRotationSession: %d"
//    - "GPUImageProcessor configured: %zux%zu format: %@"
//    - "VTPixelTransferSession failed: %d, format: %@"
//    - "Failed to create preprocess buffer pool: %d" / "Created preprocess buffer pool: %zux%zu"
//    - "Failed to get buffer from pool: %d"
//    - "Preprocess target changed: %zux%zu"
//    - 属性: bgraBufferPool, preprocessContext (CIContext), preprocessWidth/Height, preprocessPoolHeight
//
//  关键约束（记忆）：
//    1. CVPixelBufferCreate/Pool 绝对不能使用 kCVPixelBufferIOSurfacePropertiesKey（mediaserverd 立即崩溃）
//    2. CIContext 使用软件渲染（kCIContextUseSoftwareRenderer）
//    3. VTPixelRotationSession 是私有 API，通过 dlsym 动态加载
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@interface GPUImageProcessor : NSObject

// 旋转/镜像状态
@property (nonatomic, assign) int rotationAngle;  // 0/90/180/270 (用户手动, 悬浮球"转")
@property (nonatomic, assign) int sourceRotation; // 视频自带旋转(0/90/180/270, preferredTransform;
                                                  // AVAssetReader 解码帧不应用它, 不补偿会导致
                                                  // 换视频后画面 180°/90° 翻转)
@property (nonatomic, assign) BOOL mirrored;
@property (nonatomic, readonly) BOOL rotationApiAvailable;

// 当前源帧代数(VCamCore 每帧设置, 单调递增): 私有格式两步法的 staging BGRA
// 按 (代数, 目标尺寸) 复用 —— 同一源帧被相机多条流重复渲染时缩放只做一次,
// 第二条流起只做格式转换, render CPU 减半(管线饱和 → 卡顿/黑屏优化)
@property (nonatomic, assign) uint64_t frameToken;

// 核心处理方法
- (CVPixelBufferRef)processPixelBuffer:(CVPixelBufferRef)input
                                toWidth:(size_t)width
                                height:(size_t)height
                                format:(OSType)format CF_RETURNS_RETAINED;

// 缩放到目标尺寸的 BGRA（预渲染用）
- (CVPixelBufferRef)scaleToBGRA:(CVPixelBufferRef)input
                          width:(size_t)width
                         height:(size_t)height CF_RETURNS_RETAINED;

// 预渲染用: 需要旋转/镜像时做变换(输出 BGRA), 否则原帧 retain 返回
- (CVPixelBufferRef)rotateAndMirrorIfNeeded:(CVPixelBufferRef)input CF_RETURNS_RETAINED;

// 预渲染用: 同尺寸格式转换(如 BGRA -> 420f), VT 主路径 + CoreImage 回退
- (CVPixelBufferRef)convertFormat:(CVPixelBufferRef)input toFormat:(OSType)format CF_RETURNS_RETAINED;

// writeFrame 回退路径: crop fill 渲染到任意格式目标 buffer
- (BOOL)renderCropFill:(CVPixelBufferRef)input toPixelBuffer:(CVPixelBufferRef)dst;

// render 路径用: 自适应正交旋转 —— 源/目标宽高比正交(一横一竖)时 CCW90 旋转
// (宽高互换, 保持源格式); 用户已手动旋转(rotationAngle!=0)时不自适应。
// token = 帧代数: 同一帧被相机多条流渲染时只旋转一次, 后续流直接复用缓存
// (每流省一次 VT rotate ~2-4ms)。传 0 = 不缓存(fallback 路径)。
- (CVPixelBufferRef)adaptiveRotateIfNeeded:(CVPixelBufferRef)src
                               targetWidth:(size_t)targetW
                              targetHeight:(size_t)targetH
                                     token:(uint64_t)token CF_RETURNS_RETAINED;

// 格式转换（BGRA -> YUV 等）
- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst;
// 带帧代数版本: token 用于两步法 per-key staging 缩放复用判断(线程安全,
// 不再改全局 frameToken 属性 —— 多流并发写全局属性会互相覆盖导致 staging 误用别帧)
- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst token:(uint64_t)token;

// BGRA 缓冲区管理（从池中获取，减少分配开销）
- (CVPixelBufferRef)getOrCreateBGRABufferWithWidth:(size_t)width height:(size_t)height CF_RETURNS_RETAINED;

// 配置预处理目标尺寸/格式
- (void)configureWithWidth:(size_t)width height:(size_t)height format:(OSType)format;

// 当前活跃流 key 数(LRU 上限管理, 资源探针诊断用)
- (NSUInteger)activeStreamKeyCount;

// 按流渲染统计(诊断): 每 30s 窗口输出 "w_h_fmt:次数/总MB" 并清零重计
- (NSString *)takeStreamStats;

// 空闲内存释放(2026-08-17 偶发全黑优化): 清空 LRU 全部流资源 + 组 staging 池
// (~45MB+ 组缓冲 + per-key session/staging/cache)。熔断标记保留(语义永久)。
// mediaserverd inactive jetsam 硬限 75MB, 渲染期 footprint 120-480MB ——
// 相机长时间空闲时 footprint 不降会被杀 → 用户下次开相机黑屏 2-3s。
// 恢复渲染时惰性重建(首帧多付一次 session/staging 创建, ~10-20ms 一次性)
- (void)releaseIdleMemory;

// 预渲染重缓冲释放(2026-08-18 云闪付崩溃循环): 旋转 3 槽池 + 镜像 3 槽池 +
// 自适应旋转缓存 + BGRA 缓冲池。相机 idle 2s 暂停时与 videoPlayer unloadForIdle
// 配套调用, 压 footprint 过 inactive jetsam 75MB 线。恢复首帧惰性重建。
- (void)releaseHeavyBuffersForIdle;

@end
