# -*- coding: utf-8 -*-
"""inject_text_sig.py — __TEXT 完整性签名注入(CI 构建后运行)

对 fat dylib 的每个 slice:
  1. 搜索 40 字节签名洞的 8B 魔数 "VCTXSIG1"(唯一性断言)
  2. 计算 __TEXT 段(跳过 40B 洞)的 SHA256
  3. 写入洞的后 32 字节
顺序约束: 必须在 strip 之后(lipo create → strip → 本脚本 → ldid -S 重签名)
—— ldid 签名覆盖修改后的字节, trustcache CD hash 才正确。

运行时配套: VCamCore.m vcamSelfTextOK() 同口径重算比对(licMark 门禁)。
口径: __TEXT segment, len = min(filesize, vmsize), 跳 [hole, hole+40)。

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
    """thin slice: 找洞 → 算哈希 → 写洞。返回 (hole_off_in_slice, hash32)"""
    magic = struct.unpack(">I", data[:4])[0]
    assert magic in (0xFEEDFACF, 0xCFFAEDFE), "not arm64 Mach-O: 0x%x" % magic
    # __TEXT segment
    ncmds = struct.unpack(">I", data[16:20])[0]
    p = 32
    text_len = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack(">II", data[p:p + 8])
        if cmd == 0x19:  # LC_SEGMENT_64
            segname = data[p + 8:p + 24].rstrip(b"\x00").decode()
            if segname == "__TEXT":
                vmaddr, vmsize, fileoff, filesize = struct.unpack(">QQQQ", data[p + 24:p + 56])
                assert fileoff == 0, "__TEXT fileoff != 0, 口径破坏"
                text_len = min(vmsize, filesize)
                break
        p += cmdsize
    assert text_len > 0, "__TEXT segment not found"
    # 洞定位(唯一性)
    hole = data.find(MAGIC8)
    assert hole != -1, "sig hole magic not found"
    assert data.find(MAGIC8, hole + 1) == -1, "sig hole magic not unique"
    assert hole + HOLE <= text_len, "sig hole outside __TEXT (0x%x > 0x%x)" % (hole, text_len)
    # 哈希: 跳洞
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
