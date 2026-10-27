#!/usr/bin/env bash
# 3版目（カードで潜入する型に作り直し）：足りないカードの絵、海藻
cd ~/Projects/canopus-dive
P="16-bit retro pixel art game sprite, crisp hard-edged pixels, no anti-aliasing, limited palette, dark 1-pixel outline, cute chibi style, all-ages."
gen(){ tools/gen_image.sh "$@" & }
gen art/raw/icons2.png "$P A sprite sheet of 4 separate square game card icons for an underwater adventure, matching the style of the reference icons, in 1 row of 4 with wide gaps, each icon a simple bold symbol on its own: 1 a clump of tall swaying seaweed with two shy eyes peeking out between the leaves (hiding), 2 pink sound waves and a musical note bursting from a small pink-and-blue axolotl dragon mouth (a loud cute cry), 3 a big pink heart with small pink bat-like wings hugging it (healing), 4 an open treasure chest glowing with a playing card floating out. Plain flat pure green (#00FF00) background, no text, no grid. Keep the seaweed dark teal-blue so it is not the same green as the background." assets/images/ui/icons.png
wait
