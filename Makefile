TARGET := iphone:clang:15.6:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamPlus libuigest

# 发布构建(FINALPACKAGE=1)从 obfsrc/ 编译: 字符串全量加密 + 类运行时改名
# (gen_obf_src.py 生成, CI 在 make 前运行); 本地开发构建用明文源码
ifeq ($(FINALPACKAGE),1)
VCamPlus_FILES = obfsrc/Tweak.m \
	obfsrc/VCamCore.m \
	obfsrc/GPUImageProcessor.m \
	obfsrc/LocalVideoPlayer.m \
	obfsrc/NSQueue.m \
	obfsrc/VCamNotify.m \
	obfsrc/VCamFloatingBall.m \
	obfsrc/ObfStrData.m
else
VCamPlus_FILES = Tweak.m \
	VCamCore.m \
	GPUImageProcessor.m \
	LocalVideoPlayer.m \
	NSQueue.m \
	VCamNotify.m \
	VCamFloatingBall.m
endif

# libuigest(1.3.95): App 进程取色采样器 —— 独立纯 C dylib, 零 ObjC 类定义
# (runtime 零注册, 类名扫描探测落空), 中性字符串(无 vcam 特征), 不参与
# 混淆体系(明文两模式同源)。注入所有 UIKit App(libuigest.plist bundle 过滤),
# 构造器内排除 SpringBoard(桌面采样由悬浮球负责, 防同进程双写者)。
libuigest_FILES = ugest.m
libuigest_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
libuigest_LDFLAGS = -Wl,-platform_version,ios,15.0,15.6
libuigest_FRAMEWORKS = CoreGraphics

VCamPlus_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-incompatible-pointer-types-discards-qualifiers -Wno-incompatible-function-pointer-types -Wno-unused-but-set-variable
# 混淆构建(obfsrc): 格式串是运行时解密常量, clang -Wformat-security 误报(原字面量无参调用)
VCamPlus_CFLAGS += -Wno-format-security
VCamPlus_LDFLAGS = -Wl,-platform_version,ios,15.0,15.6 -Wl,-undefined,dynamic_lookup -Wl,-weak_framework,UIKit -Wl,-weak_framework,PhotosUI -Wl,-weak_framework,Metal
VCamPlus_FRAMEWORKS = AVFoundation CoreMedia CoreVideo VideoToolbox CoreImage ImageIO Foundation
# 不链接 CydiaSubstrate（RootHide/ElleKit 不提供）；MSHookMessageEx 用 extern 动态查找
# -undefined dynamic_lookup: MSHookMessageEx 运行时由 ElleKit libinjector.dylib 解析
# UIKit 弱链接（mediaserverd 没有 UIKit，SpringBoard 有）

include $(THEOS_MAKE_PATH)/tweak.mk
