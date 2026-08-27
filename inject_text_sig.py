# -*- coding: utf-8 -*-
"""inject_text_sig.py — __TEXT 完整性签名注入(CI 构建后运行)

对 fat dylib 的每个 slice:
  1. 在 slice 全文搜索 8B 魔数 "VCTXSIG1"(唯一性断言)定位签名洞
     (洞在 __DATA,__vcsig section, VCamTextSig.h 显式指定)
  2. 计算 __TEXT 段【全段】SHA256(洞不在 __TEXT → 无自引用, 全覆盖)
  3. 哈希写入洞的后 32 字节
顺序约束: 必须在 strip 之后(lipo create → strip → 本脚本 → ldid -S 重签名)
—— ldid 签名覆盖修改后的字节, trustcache CD hash 才正确。

运行时配套: VCamCore.m vcamSelfTextOK() 同口径重算比对(licMark 门禁)。

输出: artifact/sigmeta.txt(供 postinst 防重打包注入期望值)
  行1: fat 文件内 arm64e slice 洞的绝对偏移(hex)
  行2: 洞内期望 32B 哈希(hex)
用法: python3 inject_text_sig.py <fat.dylib> <sigmeta_out>
"""
import hashlib
import struct
import sys

MAGIC8 = b"VCTXSIG1"
HOLE = 40


def process_slice(data):
    """thin slice: 解析 __TEXT 的 section 表定位 __vcsig 洞 → 跳洞哈希 → 写洞。
    返回 (hole_off_in_slice, hash32)。
    注意: Mach-O load commands 是小端(iOS dylib 实际字节序); fat 头是大端。
    洞必须在 __TEXT 内(设备实锤: __DATA 洞被 dyld chained fixups 清零)。
    定位方式: section 表(运行时代码内联魔数常量会让全文搜索命中多次,
    改从 __TEXT 段的 nsects 个 section_64 头找 __vcsig 的 offset)。"""
    magic = struct.unpack("<I", data[:4])[0]
    assert magic == 0xFEEDFACF, "not little-endian arm64 Mach-O: 0x%x" % magic
    ncmds = struct.unpack("<I", data[16:20])[0]
    p = 32
    text_len = 0
    hole = -1
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[p:p + 8])
        if cmd == 0x19:  # LC_SEGMENT_64
            segname = data[p + 8:p + 24].rstrip(b"\x00").decode()
            if segname == "__TEXT":
                vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", data[p + 24:p + 56])
                nsects = struct.unpack("<I", data[p + 64:p + 68])[0]
                assert fileoff == 0, "__TEXT fileoff != 0, 口径破坏"
                text_len = min(vmsize, filesize)
                # section_64 表(紧跟 segment 命令): 每项 80B
                # sectname(16) segname(16) addr(8) size(8) offset(4) ...
                sp = p + 72
                for s in range(nsects):
                    sect = data[sp + 80 * s: sp + 80 * (s + 1)]
                    sectname = sect[:16].rstrip(b"\x00").decode()
                    if sectname == "__vcsig":
                        saddr, ssize = struct.unpack("<QQ", sect[32:48])
                        soff = struct.unpack("<I", sect[48:52])[0]
                        assert ssize == 40, "__vcsig size != 40: %d" % ssize
                        hole = soff
                        break
                break
        p += cmdsize
    assert text_len > 0, "__TEXT segment not found"
    assert hole >= 0, "__vcsig section not found in __TEXT"
    assert hole + HOLE <= text_len, "sig hole outside __TEXT: 0x%x > 0x%x" % (hole + HOLE, text_len)
    assert data[hole:hole + 8] == MAGIC8, "__vcsig magic mismatch(口径破坏)"
    # 哈希: __TEXT 跳洞(自引用消解 —— 与运行时 vcamSelfTextOK 口径一致)
    h = hashlib.sha256()
    h.update(data[:hole])
    h.update(data[hole + HOLE:text_len])
    digest = h.digest()
    # 写洞(魔数 8B 保持, 后 32B 写哈希)
    out = bytearray(data)
    out[hole + 8:hole + HOLE] = digest
    return bytes(out), hole, digest


def main():
    dylib_path, meta_path = sys.argv[1], sys.argv[2]
    data = open(dylib_path, "rb").read()
    magic = struct.unpack(">I", data[:4])[0]

    if magic in (0xCAFEBABE, 0xCAFEBABF):
        # fat: 逐 slice 处理
        nfat = struct.unpack(">I", data[4:8])[0]
        out = bytearray(data)
        slices = []
        for i in range(nfat):
            cputype, cpusub, off, size, align = struct.unpack(">IIIII", data[8 + 20 * i:8 + 20 * i + 20])
            sl = data[off:off + size]
            sl2, hole, digest = process_slice(sl)
            out[off:off + size] = sl2
            # 记录 (cputype, cpusub, hole_fat_off, digest)
            slices.append((cputype, cpusub, off + hole, digest))
            print("slice cputype=0x%x sub=0x%x hole@fat+0x%x sha256=%s"
                  % (cputype, cpusub, off + hole, digest.hex()))
        open(dylib_path, "wb").write(bytes(out))
        # 元数据: 取 arm64e slice(cputype 同 arm64=0x0100000C, cpusubtype 2 区分)
        arm64e = [s for s in slices if s[0] == 0x0100000C and (s[1] & 0x00FFFFFF) == 2]
        if not arm64e:
            # 兜底: 无 arm64e(本地测试等) → 用最后一个 slice
            arm64e = [slices[-1]]
            print("warn: no arm64e slice, using last")
        _, _, hole_fat, digest = arm64e[0]
    else:
        # thin
        out, hole, digest = process_slice(data)
        open(dylib_path, "wb").write(out)
        hole_fat = hole
        print("thin slice hole@0x%x sha256=%s" % (hole, digest.hex()))

    with open(meta_path, "w") as f:
        f.write("%x\n%s\n" % (hole_fat, digest.hex()))
    print("sigmeta written: %s" % meta_path)


if __name__ == "__main__":
    main()
