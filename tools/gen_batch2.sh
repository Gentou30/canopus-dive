#!/usr/bin/env bash
# 2版目：敵のドット絵、マップの物、カードの絵、背景、タイトル
cd ~/Projects/canopus-dive
P="16-bit retro pixel art game sprite, crisp hard-edged pixels, no anti-aliasing, limited palette, dark 1-pixel outline, cute chibi style, all-ages."
E="Exactly 4 frames of the SAME creature in one horizontal row, evenly spaced with wide gaps, same size and same design in every frame, side view facing left. Frame 1: idle. Frame 2: idle with a slight bob (animation frame). Frame 3: hurt, flashing, eyes as X. Frame 4: attacking. Plain flat pure green (#00FF00) background with nothing else, no text, no grid."
BG="Background illustration for a game, no characters, no text. Painterly anime underwater scene, vertical 2:3 composition. Keep the middle area calm, darker and low-detail so a game board on top stays readable."
gen(){ tools/gen_image.sh "$@" & }
gen art/raw/px_fugu.png "$P $E Creature: a grumpy round yellow-and-white pufferfish with small spikes and stubby fins. Frame 4: fully puffed up into a spiky ball, biting."
gen art/raw/px_kurage.png "$P $E Creature: a cute pale pink-violet glowing jellyfish with a dome bell and long wavy tentacles. Frame 4: crackling with bright yellow electricity all around."
gen art/raw/px_utsubo.png "$P $E Creature: a long green moray eel poking out of a rock hole, big jaw, mean eyes. Frame 4: lunging forward with jaws wide open."
wait
gen art/raw/objs.png "$P A sprite sheet of 8 separate game map objects for an underwater dungeon, arranged in 2 rows of 4 with wide gaps, each about the same size, top-down three-quarter view: 1 a closed wooden treasure chest with gold trim, 2 a pile of gold coins, 3 a big white pearl in an open clam shell, 4 a large sparkling blue gemstone, 5 a bubbling air vent on the sea floor releasing bubbles, 6 a dark round hole in the sand leading downward with a faint blue glow, 7 a mossy gray sea rock boulder, 8 a pink branching coral. Plain flat pure green (#00FF00) background, no text, no grid."
gen art/raw/icons.png "$P A sprite sheet of 12 separate square game card icons for an underwater adventure, arranged in 3 rows of 4 with wide gaps, each icon a simple bold symbol on its own: 1 swirling water swimming arrows, 2 a fast downward dive arrow with bubbles, 3 concentric sonar sound rings, 4 a black-and-white orca tail fin slapping, 5 a stream of blue bubbles breath, 6 big air bubbles with a plus sign, 7 a charging orca head with speed lines, 8 a whirlpool, 9 three small orcas in a row, 10 a pink bat-like dragon wing, 11 a yellow lightning bolt, 12 an upward arrow toward a bright surface. Plain flat pure green (#00FF00) background, no text, no grid."
gen art/raw/bg_shallow.png "$BG Shallow sunlit tropical sea floor: turquoise water, god rays from the surface, white sand, coral reefs and seaweed at the edges, small fish silhouettes, a sunken old wooden ship mast at a side."
wait
gen art/raw/bg_mid.png "$BG Twilight zone of the deep sea: deep blue water, sunken ancient stone ruins with pillars at the edges, kelp forests, faint rays fading, glowing particles drifting."
gen art/raw/bg_deep.png "$BG Abyss of the deep sea: near-black indigo water, bioluminescent glowing plankton and jellyfish lights, strange crystal formations at the edges, a faint mysterious star-shaped glow far below."
wait
