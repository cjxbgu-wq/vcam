#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""deb 后处理: 剥离 data.tar 中的目录条目(防 /var/jb 符号链接冲突)
用法: python3 postprocess_deb.py <in.deb> <out.deb>
背景(2026-08-18 设备实证): RootHide 环境 /var/jb 是 com.roothide.patchloader
拥有的符号链接, data.tar 带 var/jb/ 目录条目 → dpkg 报
"trying to overwrite '/var/jb', which is also in package com.roothide.patchloader"
纯文件条目解包时 dpkg 自动 mkdir -p 父目录, 无冲突。
"""
import io, sys, tarfile, gzip

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

def strip_dir_entries(tar_bytes: bytes, comp: str) -> bytes:
    entries = []
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as tf:
        for m in tf.getmembers():
            if m.isdir() or not m.name.split("/")[-1]:
                continue  # 跳过目录条目
            entries.append((m, tf.extractfile(m).read()))
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:" + comp, format=tarfile.GNU_FORMAT) as tf:
        for m, content in entries:
            m.mtime = 0
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
    control = strip_dir_entries(gzip.decompress(members[ckey]), "gz") if ccomp == "gz" else members[ckey]

    deb = b"!<arch>\n" + ar_member("debian-binary", b"2.0\n")
    deb += ar_member("control.tar.gz", control)
    deb += ar_member("data.tar.gz", data)
    with open(dst, "wb") as f:
        f.write(deb)
    print(f"OK {dst} ({len(deb)} bytes), data 目录条目已剥离")

if __name__ == "__main__":
    main()
