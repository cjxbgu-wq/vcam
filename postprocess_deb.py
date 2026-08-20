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
    # 仅剥离会冲突的目录条目: 根 "." 与 "./var/jb"(RootHide 上是 patchloader
    # 拥有的符号链接, 目录条目触发 overwrite 冲突 —— 2026-08-18 设备实证)。
    # 深层目录(var/jb/usr/... 等)保留: dpkg 目录共享无冲突(磁盘上是真实目录),
    # 且 Sileo"软件包内容"树靠目录条目构建(千面对比: 全目录条目 → 完整路径树;
    # 旧版全剥离 → 只剩 jbroot 根节点, 纯显示问题)。
    CONFLICT_DIRS = {".", "./var/jb", "var/jb"}
    entries = []
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as tf:
        for m in tf.getmembers():
            if m.isdir():
                if m.name.rstrip("/") in CONFLICT_DIRS or not m.name.split("/")[-1]:
                    continue  # 仅跳过冲突目录条目
                entries.append((m, b""))
                continue
            content = tf.extractfile(m).read()
            if strip_scripts and m.name.rsplit("/", 1)[-1] in SCRIPT_MEMBERS:
                content = strip_sh_comments(content.decode("utf-8")).encode("utf-8")
            entries.append((m, content))
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:" + comp, format=tarfile.GNU_FORMAT) as tf:
        for m, content in entries:
            m.mtime = 0
            if m.isdir():
                tf.addfile(m)
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
