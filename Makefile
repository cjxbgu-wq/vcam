TARGET := iphone:clang:15.6:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamPlus

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

VCamPlus_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-incompatible-pointer-types-discards-qualifiers -Wno-incompatible-function-pointer-types -Wno-unused-but-set-variable
# 混淆构建(obfsrc): 格式串是运行时解密常量, clang -Wformat-security 误报(原字面量无参调用)
VCamPlus_CFLAGS += -Wno-format-security
VCamPlus_LDFLAGS = -Wl,-platform_version,ios,15.0,15.6 -Wl,-undefined,dynamic_lookup -Wl,-weak_framework,UIKit -Wl,-weak_framework,PhotosUI -Wl,-weak_framework,Metal
VCamPlus_FRAMEWORKS = AVFoundation CoreMedia CoreVideo VideoToolbox CoreImage ImageIO Foundation
# 不链接 CydiaSubstrate（RootHide/ElleKit 不提供）；MSHookMessageEx 用 extern 动态查找
# -undefined dynamic_lookup: MSHookMessageEx 运行时由 ElleKit libinjector.dylib 解析
# UIKit 弱链接（mediaserverd 没有 UIKit，SpringBoard 有）

include $(THEOS_MAKE_PATH)/tweak.mk
