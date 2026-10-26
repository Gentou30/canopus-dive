#!/usr/bin/env python3
"""ドット絵のミニキャラ（横に4コマ並んだ緑背景の画像）を、同じ大きさのマス4つの透過PNGにする。

使い方: python3 tools/make_sprites.py  （art/raw/px_*.png → assets/images/px/*.png）
コマの並び: 0 待機 / 1 喜ぶ / 2 あせる / 3 そのキャラの決めポーズ。足元をマスの下にそろえる。
"""
import glob
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
from chroma_key import crop, key  # noqa: E402

ROOT = os.path.join(os.path.dirname(__file__), "..")
CELL = 192


def cut_columns(img: Image.Image, n: int = 4):
    """透明な列のすき間で n コマに切る。すき間はだいたい等分の位置の近くから探す"""
    a = np.asarray(img.getchannel("A")).astype(np.float32).sum(axis=0)
    w = img.width
    cuts = [0]
    for k in range(1, n):
        lo, hi = int(w * (k / n - 0.1)), int(w * (k / n + 0.1))
        seg = a[lo:hi]
        best = seg.min()
        # 一番空いている列が続いている所の真ん中
        idx = np.where(seg <= best + 1e-3)[0]
        cuts.append(lo + int(idx[len(idx) // 2]))
    cuts.append(w)
    return [crop(img.crop((cuts[i], 0, cuts[i + 1], img.height))) for i in range(n)]


def main():
    out_dir = os.path.join(ROOT, "assets", "images", "px")
    os.makedirs(out_dir, exist_ok=True)
    for src in sorted(glob.glob(os.path.join(ROOT, "art", "raw", "px_*.png"))):
        name = os.path.basename(src)[3:-4]
        frames = cut_columns(key(Image.open(src)))
        s = min(CELL / max(f.height for f in frames), CELL / max(f.width for f in frames))
        sheet = Image.new("RGBA", (CELL * len(frames), CELL))
        for i, f in enumerate(frames):
            f = f.resize((max(1, round(f.width * s)), max(1, round(f.height * s))), Image.BOX)
            sheet.paste(f, (i * CELL + (CELL - f.width) // 2, CELL - f.height), f)
        sheet.save(os.path.join(out_dir, name + ".png"))
        print(name, [fr.size for fr in frames], f"scale {s:.3f}")


if __name__ == "__main__":
    main()
