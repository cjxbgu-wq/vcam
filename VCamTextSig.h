//
//  VCamTextSig.h
//  VCamPlus
//
//  __TEXT 完整性签名洞(1.3.70 防破解: dylib 自校验)
//
//  布局: 40 字节 = 8B 魔数 'VCTXSIG1'(定位标记) + 32B SHA256(构建期注入)。
//  显式放 __TEXT,__vcsig section(used 防优化丢弃)。
//  【必须 __TEXT】设备实锤(1.3.70): 洞放 __DATA 时哈希区被 dyld 的
//  chained fixups 改写清零(内存 m=VCTX e=0000, 磁盘 fat 有哈希)——
//  __DATA/__DATA_CONST 加载时 fixup 重写, __TEXT 段原样只读映射。
//
//  inject_text_sig.py 在 CI 的 strip 之后 / ldid 签名之前:
//  1. 在 slice 全文搜索魔数(唯一性断言)定位洞(洞在 __TEXT 内)
//  2. 对 __TEXT 段跳过 40B 洞计算 SHA256(自引用消解)
//  3. 哈希写入洞的后 32 字节
//
//  运行时 vcamSelfTextOK()(VCamCore.m) 同口径(跳洞)重算比对。任何对
//  __TEXT 的字节修改(改跳转/NOP 门禁/patch 常量)→ 哈希失配 → licMark
//  关门禁 → 替换/打光静默失效。绕过需同时改洞内哈希并重算 —— md/SB
//  两侧独立计算, 单侧 patch 无效。
//
#ifndef VCAM_TEXT_SIG_H
#define VCAM_TEXT_SIG_H

// 禁止混淆器处理本文件(COPY_FILES): 魔数字节序列必须原样进二进制,
// inject_text_sig.py 才能定位洞。
__attribute__((used, section("__TEXT,__vcsig")))
static const uint8_t vcamTextSig[40] = {
    0x56, 0x43, 0x54, 0x58, 0x53, 0x49, 0x47, 0x31,  // "VCTXSIG1"
    // 32 字节 SHA256 占位(inject_text_sig.py 写入; 全 0 = 本地构建未注入
    // → 运行时跳过校验, 不影响开发构建)
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};

#endif
