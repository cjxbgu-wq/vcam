#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@class GPUImageProcessor;

// 核心渲染控制器
// 对标 vcameracrack 的 VCamCore
// 职责：状态管理、预渲染线程、格式白名单、实时帧替换
@interface VCamCore : NSObject

+ (instancetype)sharedInstance;

// hook 函数调用的核心方法：替换相机帧
- (void)renderReplacementToPixelBuffer:(CVPixelBufferRef)origPixelBuffer;

// 是否有可用的替换帧
- (BOOL)hasReplacementFrame;

// 清除替换帧，恢复原相机
- (void)clearReplacementFrame;

// 重新加载配置
- (void)reloadMediaFromConfig;

// 格式白名单检查
- (BOOL)isSupportedVideoFormat:(CVPixelBufferRef)pixelBuffer;

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL isPixelBufferMode;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, strong) GPUImageProcessor *gpuProcessor;
@property (nonatomic, assign) BOOL targetSizeKnown;
@property (nonatomic, assign) size_t targetWidth;
@property (nonatomic, assign) size_t targetHeight;
@property (nonatomic, assign) OSType targetFormat;
@property (nonatomic, strong) NSString *currentVideoPath;

@end
