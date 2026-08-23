# -*- coding: utf-8 -*-
"""gen_btn_icons.py: 按钮图标(播/镜/替/复)统一转 PNG + XOR 加密生成 btn_icons.h
- 源文件在 图标/ 目录(复/播/替 实为 WebP, 镜为 PNG)
- 统一缩放 90x90, 单色化(灰白染色保留 alpha 形状) + 线条加粗(形态学膨胀)
  (1.3.24 实测教训: 源图标为细线条设计, 播图标仅 7% 像素覆盖在按钮上几乎不可见;
   UIButtonTypeSystem 还会把图像 tint 染成系统蓝 —— 运行时用 AlwaysOriginal 免染色)
- 每图标独立 8 字节 rolling key XOR, 二进制内无 PNG 魔数, 防提取
- VCamFloatingBall.m 运行时解码 imageWithData
"""
import os, io
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "图标")
OUT = os.path.join(ROOT, "btn_icons.h")

ICONS = [
    # (源文件, 数组前缀, key)
    ("播.jpeg", "vcam_btn_play",    [0xC3, 0x5A, 0xE1, 0x7C, 0x0F, 0x94, 0x62, 0xD8]),
    ("镜.jpeg", "vcam_btn_mirror",  [0x71, 0xBD, 0x36, 0xC9, 0x50, 0xE8, 0x1A, 0xA4]),
    ("替.jpeg", "vcam_btn_replace", [0x2E, 0xF7, 0x83, 0x1C, 0xAA, 0x45, 0xD0, 0x69]),
    ("复.jpeg", "vcam_btn_restore", [0x96, 0x03, 0xCC, 0x58, 0xE2, 0x77, 0x0B, 0x31]),
]

SIZE = 90   # 输出图标边长(按钮内显示 ~30pt, 3x retina 90px 足够)
ICON_RGB = (235, 235, 238)  # 灰白(深灰按钮背景上清晰, 贴合灰色主题)

lines = []
lines.append("// 按钮图标(播/镜/替/复), gen_btn_icons.py 生成")
lines.append("// 源图统一 90x90 单色化(灰白染 alpha 形状)+线条加粗后 PNG,")
lines.append("// XOR 8字节 rolling key 加密, 二进制内无 PNG 魔数, 运行时解码 imageWithData")
lines.append("#ifndef BTN_ICONS_H")
lines.append("#define BTN_ICONS_H")
lines.append("")

for fname, prefix, key in ICONS:
    src_path = os.path.join(SRC, fname)
    img = Image.open(src_path)
    # 统一 RGBA(保留透明度; 不透明图补满 alpha)
    if img.mode != "RGBA":
        img = img.convert("RGBA")
    img = img.resize((SIZE, SIZE), Image.LANCZOS)

    # 单色化: 只保留 alpha 形状, RGB 全部替换为灰白 —— 消除源图配色,
    # 统一灰色主题; 线条型图标染色无层次损失
    r, g, b, a = img.split()
    solid = Image.new("RGB", img.size, ICON_RGB)
    mono = Image.merge("RGBA", (*solid.split(), a))

    # 线条加粗: alpha 通道 3x3 最大值滤波(形态学膨胀), 细线条(1px)加粗到 ~3px
    a_thick = a.filter(ImageFilter.MaxFilter(3))
    # 膨胀后 alpha 略降边界平滑, 直接复用原 alpha 二值化结果
    mono = Image.merge("RGBA", (*solid.split(), a_thick))

    buf = io.BytesIO()
    mono.save(buf, format="PNG", optimize=True)
    data = buf.getvalue()
    enc = bytes(bb ^ key[i & 7] for i, bb in enumerate(data))
    assert enc[:4] != b"\x89PNG", f"{fname} 加密后仍是 PNG 魔数?"

    # key 宏
    for i, k in enumerate(key):
        lines.append(f"#define VCS_BTN_{prefix.upper()}_KEY{i} 0x{k:02X}")
    lines.append("")
    lines.append(f"#define {prefix}_len {len(enc)}")
    lines.append("")
    lines.append(f"static const unsigned char {prefix}_enc[] = {{")
    row = []
    for i, bb in enumerate(enc):
        row.append(f"0x{bb:02X}")
        if len(row) == 16:
            lines.append(", ".join(row) + ",")
            row = []
    if row:
        lines.append(", ".join(row) + ",")
    lines.append("};")
    lines.append("")
    print(f"{fname}: {img.size} {len(data)}B PNG -> {len(enc)}B enc")

lines.append("#endif // BTN_ICONS_H")
lines.append("")

with open(OUT, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(lines))
print(f"\nbtn_icons.h 生成完毕: {os.path.getsize(OUT)} bytes")
