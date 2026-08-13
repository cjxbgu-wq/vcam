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
@property (nonatomic, assign) int rotationAngle;  // 0/90/180/270
@property (nonatomic, assign) BOOL mirrored;
@property (nonatomic, readonly) BOOL rotationApiAvailable;

// 核心处理方法
- (CVPixelBufferRef)processPixelBuffer:(CVPixelBufferRef)input
                                toWidth:(size_t)width
                                height:(size_t)height
                                format:(OSType)format CF_RETURNS_RETAINED;

// 格式转换（BGRA -> YUV 等）
- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst;

// BGRA 缓冲区管理（从池中获取，减少分配开销）
- (CVPixelBufferRef)getOrCreateBGRABufferWithWidth:(size_t)width height:(size_t)height CF_RETURNS_RETAINED;

// 配置预处理目标尺寸/格式
- (void)configureWithWidth:(size_t)width height:(size_t)height format:(OSType)format;

@end
