# -*- coding: utf-8 -*-
"""check_leak.py — dylib 防泄露验证 gate(CI 构建后强制运行)

扫描 fat/thin Mach-O 的可读字符串(UTF-8 + UTF-16LE), 命中关键字即失败。
保证 gen_obf_src.py 的混淆无回归: 类名/Hook 目标/日志前缀/路径/队列名
不得以明文出现在二进制中。

用法: python3 check_leak.py <dylib>
"""
import re
import struct
import sys

KEYWORDS = [
    # 自有类名(应为运行时改名后的 Qz1/Wv2/...)
    'VCamCore', 'LocalVideoPlayer', 'GPUImageProcessor', 'NSQueue',
    'VCamNotify', 'VCamFloatingBall',
    # Hook 目标(核心机制)
    'BWNodeOutput', 'BWStillImageScalerNode', 'BWPhotoEncoderNode',
    'emitSampleBuffer', 'renderSampleBuffer',
    # 进程判定/过滤
    'mediaserverd', 'SpringBoard',
    # 配置契约与路径
    'vc.plist', 'vcam.mp4', 'logEnabled', 'activePlaybackPath',
    'decodeMaxEdge', 'restartToken', 'manualRotation',
    # 队列/通知名
    'com.vcam',
    # VT 属性与符号(应全部运行时解密; 用完整符号名, 避免误伤编译器
    # 生成的属性类型编码 T^{OpaqueVTPixelRotationSession=} —— 那是
    # @property 声明 C 指针类型的必然产物, 不属于字符串泄露)
    'ScalingMode', 'FlipHorizontalOrientation', 'kVTRotation',
    'kVTPixelRotationPropertyKey', 'VTPixelRotationSessionCreate',
    'VTPixelRotationSessionRotateImage', 'VTPixelRotationSessionInvalidate',
    'MTLCreateSystemDefaultDevice',
    # 日志前缀
    '[vcam]',
]


def slices(data):
    magic = struct.unpack('>I', data[:4])[0]
    if magic in (0xcafebabe, 0xcafebabf):
        nfat = struct.unpack('>I', data[4:8])[0]
        for i in range(nfat):
            off = struct.unpack('>I', data[8 + 20 * i + 8:8 + 20 * i + 12])[0]
            size = struct.unpack('>I', data[8 + 20 * i + 12:8 + 20 * i + 16])[0]
            yield data[off:off + size]
    elif magic in (0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe):
        yield data
    else:
        raise SystemExit('不是 Mach-O: magic=0x%x' % magic)


def find_leaks(data):
    hits = []
    for blob in slices(data):
        texts = [blob.decode('latin1')]
        try:
            texts.append(blob.decode('utf-16-le'))
        except UnicodeDecodeError:
            pass
        for txt in texts:
            for kw in KEYWORDS:
                for m in re.finditer(re.escape(kw), txt):
                    ctx = txt[max(0, m.start() - 20):m.end() + 20]
                    ctx = ''.join(c if 32 <= ord(c) < 127 else '.' for c in ctx)
                    hits.append((kw, ctx))
                    break  # 每关键字每编码报一次
    return hits


def main():
    path = sys.argv[1]
    data = open(path, 'rb').read()
    hits = find_leaks(data)
    if hits:
        print('泄露检测失败: %d 处明文命中!' % len(hits))
        for kw, ctx in hits:
            print('  [%s] ...%s...' % (kw, ctx))
        sys.exit(1)
    print('泄露检测通过: %d 个关键字零命中 (%d bytes)' % (len(KEYWORDS), len(data)))


if __name__ == '__main__':
    main()
