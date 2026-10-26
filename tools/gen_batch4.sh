#!/usr/bin/env bash
# 4版目（マインスイーパー型に作り直し）：強さ4〜8の敵と、最後の海竜
cd ~/Projects/canopus-dive
P="16-bit retro pixel art game sprite, crisp hard-edged pixels, no anti-aliasing, limited palette, dark 1-pixel outline, cute chibi style, all-ages."
E="Exactly 4 frames of the SAME creature in one horizontal row, evenly spaced with wide gaps, same size and same design in every frame, facing left. Frame 1: idle. Frame 2: idle with a slight bob (animation frame). Frame 3: hurt, flashing, eyes as X. Frame 4: attacking. Plain flat pure green (#00FF00) background with nothing else, no text, no grid."
gen(){ tools/gen_image.sh "$@" & }
gen art/raw/px_tako.png "$P $E Creature: a grumpy round red octopus with curly tentacles. Frame 4: squirting a cloud of black ink."
gen art/raw/px_ankou.png "$P $E Creature: a deep-sea anglerfish, dark purple-brown, huge toothy grin, a glowing yellow lure lamp on its head. Frame 4: lunging with jaws open, lure blazing."
gen art/raw/px_same.png "$P $E Creature: a sturdy gray shark with a white belly and a scar on its nose, smug face. Frame 4: biting with jaws wide open."
wait
gen art/raw/px_kani.png "$P $E Creature: a big armored spider crab, orange-red with long spiky legs and huge claws. Frame 4: snapping both claws raised."
gen art/raw/px_ika.png "$P $E Creature: a giant white-pink squid with big round eyes and long arms, a little silly. Frame 4: grabbing forward with all arms spread."
gen art/raw/px_ryu.png "$P $E Creature: the final boss, a majestic but cute deep-sea serpent dragon, deep indigo scales with glowing cyan fins and whiskers, coiled around a small glowing star. Frame 4: roaring with cyan light breath."
wait
