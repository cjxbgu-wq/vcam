//
//  VCamStr.h - 自动生成(gen_vcamstr.py), 勿手改
//  悬浮窗 UI 字符串混淆: 编译期 XOR 加密, 运行时解码,
//  二进制内无明文(防 strings/class-dump 直接提取修改)
//
#ifndef VCAM_STR_H
#define VCAM_STR_H

#import <Foundation/Foundation.h>

// 解码: 数组首字节为 key, 其余为密文
NS_INLINE NSString *vcStrX(const unsigned char *v) {
    unsigned char key = v[0];
    unsigned char buf[64];
    NSUInteger n = 0;
    while (v[n + 1] && n < sizeof(buf) - 1) { buf[n] = v[n + 1] ^ key; n++; }
    buf[n] = 0;
    return [NSString stringWithUTF8String:(const char *)buf];
}

#define VCS(n) vcStrX(_vcs_##n)

static const unsigned char _vcs_qisheng[] = { 0x75, 0x90, 0xC7, 0xE5, 0x92, 0xEE, 0xEE, 0x92, 0xEE, 0xCD, 0x93, 0xE9, 0xCF };
static const unsigned char _vcs_mark[] = { 0x3B, 0x7B, 0x6A, 0x4E, 0x7C, 0x5E, 0x55, 0x4F, 0x4F, 0x43 };
static const unsigned char _vcs_tglink[] = { 0xBD, 0xD5, 0xC9, 0xC9, 0xCD, 0xCE, 0x87, 0x92, 0x92, 0xC9, 0x93, 0xD0, 0xD8, 0x92, 0xE5, 0xFB, 0xCF, 0xD8, 0xDC, 0xD1, 0xC9, 0xD4, 0xD0, 0xD8, 0x8F };

#endif // VCAM_STR_H
