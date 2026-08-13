TARGET := iphone:clang:15.6:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamPlus

VCamPlus_FILES = Tweak.m \
	VCamCore.m \
	GPUImageProcessor.m \
	LocalVideoPlayer.m \
	NSQueue.m \
	VCamNotify.m \
	VCamFloatingBall.m

VCamPlus_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-incompatible-pointer-types-discards-qualifiers -Wno-unused-but-set-variable
VCamPlus_LDFLAGS = -Wl,-platform_version,ios,15.0,15.6 -Wl,-undefined,dynamic_lookup -Wl,-weak_framework,UIKit
VCamPlus_FRAMEWORKS = AVFoundation CoreMedia CoreVideo VideoToolbox CoreImage ImageIO Foundation
# 不链接 CydiaSubstrate（RootHide/ElleKit 不提供）；MSHookMessageEx 用 extern 动态查找
# -undefined dynamic_lookup: MSHookMessageEx 运行时由 ElleKit libinjector.dylib 解析
# UIKit 弱链接（mediaserverd 没有 UIKit，SpringBoard 有）

include $(THEOS_MAKE_PATH)/tweak.mk
