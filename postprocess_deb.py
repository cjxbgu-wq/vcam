#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""deb 后处理: 剥离 data.tar 目录条目 + 维护脚本注释剥离
用法: python3 postprocess_deb.py <in.deb> <out.deb>
背景1(2026-08-18 设备实证): RootHide 环境 /var/jb 是 com.roothide.patchloader
拥有的符号链接, data.tar 带 var/jb/ 目录条目 → dpkg 报
"trying to overwrite '/var/jb', which is also in package com.roothide.patchloader"
纯文件条目解包时 dpkg 自动 mkdir -p 父目录, 无冲突。
背景2(2026-08-20 防逆向): 仓库内 preinst/postinst/postrm 带大量工程注释
(根因分析/踩坑记录), 随 deb 发布等于泄露实现细节 —— 打包时剥离整行注释
(保留 shebang, 不碰行内内容, 避免误伤 ${x#y} 等 shell 语法)。
"""
import io, sys, tarfile, gzip

SCRIPT_MEMBERS = {"preinst", "postinst", "postrm"}

def parse_ar(data: bytes):
    members, off = {}, 8
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        name = hdr[0:16].decode().strip()
        size = int(hdr[48:58].decode().strip())
        members[name.rstrip("/")] = data[off + 60:off + 60 + size]
        off += 60 + size + (size & 1)
    return members

def ar_member(name: str, body: bytes) -> bytes:
    hdr = name.ljust(16).encode() + b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6) + b"100644".ljust(8) + str(len(body)).encode().ljust(10) + b"`\n"
    out = hdr + body
    return out + (b"\n" if len(body) & 1 else b"")

def strip_sh_comments(text: str) -> str:
    """剥离 shell 整行注释(保 shebang), 压缩连续空行; 不碰行内 #"""
    out = []
    for idx, ln in enumerate(text.split("\n")):
        if idx == 0 and ln.startswith("#!"):
            out.append(ln.rstrip())
            continue
        if ln.lstrip().startswith("#"):
            continue
        out.append(ln.rstrip())
    res, blank = [], False
    for ln in out:
        if ln == "":
            if blank:
                continue
            blank = True
        else:
            blank = False
        res.append(ln)
    return "\n".join(res)

def strip_dir_entries(tar_bytes: bytes, comp: str, strip_scripts: bool = False) -> bytes:
    # 剥离全部目录条目(2026-08-21, 1.3.17 SE2 升级失败教训):
    # 1.3.16 保留深层目录条目(./var/jb/usr/...)全新安装成功, 但 1.3.17 新增
    # ./var/jb/Library/MobileSubstrate/DynamicLibraries 目录条目后 SE2 升级
    # 失败(unable to open .dpkg-new: ENOENT) —— bootstrap 内部符号链接结构
    # 与目录条目冲突面不可预知。千面带全目录条目能装是因其走 rootless-compat
    # 重定向(./Library 前缀), 我们混合布局不具该条件。
    # 纯文件+symlink 条目 + preinst mkdir 兜底 = 无论磁盘符号链接结构如何
    # 都不会触发目录条目冲突(Sileo 内容树少目录节点是纯显示问题)。
    # symlink 条目(.roothidepatch 标记, 千面同款)必须原样保留 —— 空文件标记
    # 是 1.3.17 的自创写法, 千面实证是符号链接 -> AutoPatches.dylib。
    entries = []
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as tf:
        for m in tf.getmembers():
            if m.isdir():
                continue  # 全部目录条目剥离
            if m.issym() or m.islnk():
                entries.append((m, None))  # symlink: 无内容, linkname 在 member 里
                continue
            content = tf.extractfile(m).read()
            if strip_scripts and m.name.rsplit("/", 1)[-1] in SCRIPT_MEMBERS:
                content = strip_sh_comments(content.decode("utf-8")).encode("utf-8")
            entries.append((m, content))
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:" + comp, format=tarfile.GNU_FORMAT) as tf:
        for m, content in entries:
            m.mtime = 0
            if content is None:
                m.size = 0
                tf.addfile(m)  # symlink 条目: 只写 header(linkname 已在 member)
            else:
                m.size = len(content)  # 注释剥离后长度变化, 必须同步 tar size
                tf.addfile(m, io.BytesIO(content))
    return buf.getvalue()

def main():
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as f:
        members = parse_ar(f.read())

    def comp_of(key):
        return {"zst": "", "gz": "gz", "xz": "xz", "bz2": "bz2"}.get(key.rsplit(".", 1)[-1], "")

    # data.tar 必须可被标准库解(要求 CI 用 -Zgzip 打包)
    dkey = next(k for k in members if k.startswith("data.tar"))
    comp = comp_of(dkey)
    assert comp == "gz", f"CI 打包请用 dpkg-deb -Zgzip, 当前: {dkey}"
    data = strip_dir_entries(gzip.decompress(members[dkey]), "gz")

    ckey = next(k for k in members if k.startswith("control.tar"))
    ccomp = comp_of(ckey)
    control = (strip_dir_entries(gzip.decompress(members[ckey]), "gz", strip_scripts=True)
               if ccomp == "gz" else members[ckey])

    deb = b"!<arch>\n" + ar_member("debian-binary", b"2.0\n")
    deb += ar_member("control.tar.gz", control)
    deb += ar_member("data.tar.gz", data)
    with open(dst, "wb") as f:
        f.write(deb)
    print(f"OK {dst} ({len(deb)} bytes), data 目录条目已剥离, 维护脚本注释已剥离")

if __name__ == "__main__":
    main()
