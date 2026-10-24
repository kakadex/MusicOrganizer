# -*- coding: utf-8 -*-
"""生成启动图标（纯标准库，不依赖 Pillow）。

输出到 app/src/main/res/mipmap-*/ic_launcher.png 与 ic_launcher_round.png。
运行：python tools/make_icon.py
"""
import math
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DENSITIES = [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]
SS = 3  # 超采样倍数


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    return tuple(int(round(lerp(c1[i], c2[i], t))) for i in range(3))


def write_png(path, width, height, pixels):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw.extend(pixels[y * width * 4:(y + 1) * width * 4])
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


def in_round_rect(x, y, r):
    w = 1.0
    cx = min(max(x, r), w - r)
    cy = min(max(y, r), w - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r + 1e-9 or (r <= x <= 1 - r) or (r <= y <= 1 - r)


def note_alpha(x, y):
    """白色音符的覆盖率（0~1）。"""
    # 符头：椭圆
    ex, ey, erx, ery = 0.375, 0.685, 0.115, 0.088
    if ((x - ex) / erx) ** 2 + ((y - ey) / ery) ** 2 <= 1.0:
        return 1.0
    # 符干
    if 0.455 <= x <= 0.500 and 0.300 <= y <= 0.690:
        return 1.0
    # 符尾：沿三次贝塞尔采样成带状
    p0, p1, p2, p3 = (0.478, 0.302), (0.560, 0.300), (0.660, 0.330), (0.690, 0.470)
    for i in range(0, 60):
        t = i / 59.0
        mt = 1 - t
        bx = (mt ** 3) * p0[0] + 3 * (mt ** 2) * t * p1[0] + 3 * mt * (t ** 2) * p2[0] + (t ** 3) * p3[0]
        by = (mt ** 3) * p0[1] + 3 * (mt ** 2) * t * p1[1] + 3 * mt * (t ** 2) * p2[1] + (t ** 3) * p3[1]
        if (x - bx) ** 2 + (y - by) ** 2 <= 0.030 ** 2:
            return 1.0
    return 0.0


def render(size, round_icon):
    w = size * SS
    buf = bytearray(w * w * 4)
    c1, c2 = (0x5B, 0x8CFF & 0xFF, 0xFF), (0x1C, 0x45, 0xB8)
    c1 = (0x3C, 0x76, 0xFF)
    c2 = (0x1B, 0x41, 0xAE)
    radius = 0.5 if round_icon else 0.22
    for py in range(w):
        y = (py + 0.5) / w
        for px in range(w):
            x = (px + 0.5) / w
            dx, dy = x - 0.5, y - 0.5
            if round_icon:
                inside = (dx * dx + dy * dy) <= 0.5 * 0.5
            else:
                inside = in_round_rect(x, y, radius)
            if not inside:
                continue
            base = mix(c1, c2, min(1.0, max(0.0, (x * 0.45 + y * 0.75))))
            a = note_alpha(x, y)
            r = int(round(lerp(base[0], 255, a)))
            g = int(round(lerp(base[1], 255, a)))
            b = int(round(lerp(base[2], 255, a)))
            i = (py * w + px) * 4
            buf[i] = r
            buf[i + 1] = g
            buf[i + 2] = b
            buf[i + 3] = 255
    # 降采样
    out = bytearray(size * size * 4)
    for y in range(size):
        for x in range(size):
            tr = tg = tb = ta = 0
            for sy in range(SS):
                for sx in range(SS):
                    i = ((y * SS + sy) * w + (x * SS + sx)) * 4
                    a = buf[i + 3]
                    tr += buf[i] * a
                    tg += buf[i + 1] * a
                    tb += buf[i + 2] * a
                    ta += a
            o = (y * size + x) * 4
            if ta == 0:
                out[o:o + 4] = b"\x00\x00\x00\x00"
            else:
                out[o] = min(255, tr // ta)
                out[o + 1] = min(255, tg // ta)
                out[o + 2] = min(255, tb // ta)
                out[o + 3] = ta // (SS * SS)
    return out


def main():
    for name, size in DENSITIES:
        folder = os.path.join(ROOT, "app", "src", "main", "res", "mipmap-" + name)
        os.makedirs(folder, exist_ok=True)
        write_png(os.path.join(folder, "ic_launcher.png"), size, size, render(size, False))
        write_png(os.path.join(folder, "ic_launcher_round.png"), size, size, render(size, True))
        print("icon:", name, size)


if __name__ == "__main__":
    main()
