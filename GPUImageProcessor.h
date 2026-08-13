#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

// 图像处理器：旋转、镜像、缩放、格式转换
// 对标 vcameracrack 的 GPUImageProcessor
// 在 mediaserverd 中使用软件渲染（CIContext UseSoftwareRenderer）
@interface GPUImageProcessor : NSObject

// 处理源帧到目标缓冲区（旋转/镜像/缩放）
- (void)processPixelBuffer:(CVPixelBufferRef)srcBuffer
                  toBuffer:(CVPixelBufferRef)dstBuffer
                    toWidth:(size_t)width
                   toHeight:(size_t)height
                     format:(OSType)format;

// VTPixelTransferSession 格式转换（BGRA→YUV 等）
- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src
             toPixelBuffer:(CVPixelBufferRef)dst;

// 配置预处理目标尺寸
- (void)setPreprocessTargetWidth:(size_t)width height:(size_t)height;

// 获取或创建 BGRA 缓冲区
- (CVPixelBufferRef)getOrCreateBGRABufferWithWidth:(size_t)width height:(size_t)height;

@property (nonatomic, assign) NSInteger rotationAngle; // 0/90/180/270
@property (nonatomic, assign) BOOL mirrored;
@property (nonatomic, readonly) VTPixelTransferSessionRef pixelTransferSession;
@property (nonatomic, readonly) VTPixelRotationSessionRef pixelRotationSession;

@end
