//
//  VCamTextSig.h
//  VCamPlus
//
//  __TEXT 完整性签名洞(1.3.70 防破解加强: dylib 自校验)
//
//  布局: 40 字节 = 8B 魔数 'VCTXSIG1'(定位标记) + 32B SHA256 占位(构建期注入)
//  const 数组落 __TEXT,__const 段 —— inject_text_sig.py 在 CI 的
//  strip 之后 / ldid 签名之前定位魔数, 对本 slice 的 __TEXT 段跳过这
//  40 字节计算 SHA256, 写入洞的后 32 字节。
//
//  运行时 vcamSelfTextOK()(VCamCore.m) 用完全相同的口径重算比对:
//  任何对 __TEXT 的字节级修改(改跳转指令/NOP 门禁/patch 常量)都会让
//  哈希失配 → licMark 门禁关闭 → 替换/打光静默失效。
//  重打包者若同时改洞内哈希使其自洽 → 必须先理解整个校验链才能伪造,
//  且 md/SB 两侧独立计算, 单侧 patch 无效。
//
#ifndef VCAM_TEXT_SIG_H
#define VCAM_TEXT_SIG_H

// 禁止混淆器处理本文件(COPY_FILES): 魔数字节序列必须原样进二进制,
// inject_text_sig.py 才能定位洞; 哈希区运行时按字节数组读取。
static const uint8_t vcamTextSig[40] = {
    0x56, 0x43, 0x54, 0x58, 0x53, 0x49, 0x47, 0x31,  // "VCTXSIG1"
    // 32 字节 SHA256 占位(inject_text_sig.py 写入; 本地构建保持全 0 =
    // 自校验跳过语义, 不影响开发构建)
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};

#endif
