#!/usr/bin/env python3
"""緑背景のアイコン一覧（格子に並んだ絵）を、192px のマスが4列に並んだ透過PNGにする。

使い方: python3 tools/make_icons.py <入力> <出力> <列> <行>
  例: tools/make_icons.py art/raw/icons3.png assets/images/ui/icons3.png 4 2
入力を列×行の格子で切り、それぞれ緑を抜いて余白を詰め、マスの真ん中に置く。
"""
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
from chroma_key import crop, key  # noqa: E402

CELL = 192


def main():
    src, dst, cols, rows = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    img = key(Image.open(src))
    cw, ch = img.width / cols, img.height / rows
    out = Image.new("RGBA", (CELL * 4, CELL * ((cols * rows + 3) // 4)))
    for i in range(cols * rows):
        c, r = i % cols, i // cols
        tile = crop(img.crop((round(c * cw), round(r * ch), round((c + 1) * cw), round((r + 1) * ch))))
        s = (CELL - 8) / max(tile.size)
        tile = tile.resize((max(1, round(tile.width * s)), max(1, round(tile.height * s))), Image.LANCZOS)
        x, y = (i % 4) * CELL, (i // 4) * CELL
        out.paste(tile, (x + (CELL - tile.width) // 2, y + (CELL - tile.height) // 2), tile)
    out.save(dst)
    print(dst, out.size)


if __name__ == "__main__":
    main()
