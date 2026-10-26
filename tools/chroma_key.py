#!/usr/bin/env python3
"""緑背景(#00FF00)の画像を透過PNGにする。

使い方:
  tools/chroma_key.py <入力> <出力png> [--max 512]            # 1枚にして余白を切り詰める
  tools/chroma_key.py <入力> <出力ディレクトリ> --split [--max 256] [--names a,b,c]
      # 塊ごとに切り出す（左上から行ごとの順）
"""
import argparse
import os

import numpy as np
from PIL import Image
from scipy import ndimage


def key(img: Image.Image) -> Image.Image:
    a = np.asarray(img.convert("RGB")).astype(np.float32)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    # 緑の強さ = g が r,b をどれだけ上回るか
    green = g - np.maximum(r, b)
    alpha = np.clip(1.0 - (green - 40.0) / 80.0, 0.0, 1.0)
    # 縁に残る緑かぶりを抑える
    spill = np.maximum(r, b)
    g2 = np.where(green > 0, np.minimum(g, spill + 10), g)
    out = np.dstack([r, g2, b, alpha * 255.0]).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def crop(img: Image.Image, pad: int = 4) -> Image.Image:
    bbox = img.getchannel("A").point(lambda v: 255 if v > 16 else 0).getbbox()
    if not bbox:
        return img
    l, t, r, b = bbox
    return img.crop((max(l - pad, 0), max(t - pad, 0), min(r + pad, img.width), min(b + pad, img.height)))


def fit(img: Image.Image, max_side: int) -> Image.Image:
    s = max_side / max(img.size)
    if s < 1:
        img = img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
    return img


def split(img: Image.Image):
    a = np.asarray(img.getchannel("A")) > 16
    # 細かい破片をまとめるため少し太らせてからラベリング
    big = ndimage.binary_dilation(a, iterations=12)
    labels, n = ndimage.label(big)
    boxes = []
    for sl in ndimage.find_objects(labels):
        h = sl[0].stop - sl[0].start
        w = sl[1].stop - sl[1].start
        if h * w < (img.width * img.height) * 0.005:
            continue
        boxes.append((sl[1].start, sl[0].start, sl[1].stop, sl[0].stop))
    # 中心の高さが大きく離れたところで行を区切り、行ごとに左→右に並べる
    boxes.sort(key=lambda bx: (bx[1] + bx[3]) / 2)
    rows, last_cy = [], None
    for bx in boxes:
        cy = (bx[1] + bx[3]) / 2
        if last_cy is None or cy - last_cy > img.height * 0.2:
            rows.append([])
        rows[-1].append(bx)
        last_cy = cy
    ordered = [bx for row in rows for bx in sorted(row, key=lambda bx: bx[0])]
    return [crop(img.crop(bx)) for bx in ordered]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--split", action="store_true")
    ap.add_argument("--max", type=int, default=512)
    ap.add_argument("--names", default="")
    args = ap.parse_args()
    img = key(Image.open(args.src))
    if not args.split:
        fit(crop(img), args.max).save(args.dst)
        print("saved", args.dst)
        return
    os.makedirs(args.dst, exist_ok=True)
    names = args.names.split(",") if args.names else []
    for i, part in enumerate(split(img)):
        name = names[i] if i < len(names) else f"part{i}"
        path = os.path.join(args.dst, name + ".png")
        fit(part, args.max).save(path)
        print("saved", path, part.size)


if __name__ == "__main__":
    main()
