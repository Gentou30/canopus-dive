#!/usr/bin/env bash
# Codex の画像生成で1枚作り、指定パスにコピーする。
# 使い方: tools/gen_image.sh <出力png> "<プロンプト>" [参照画像...]
# この環境では Codex のサンドボックスがファイルを書けないため、
# ~/.codex/generated_images/<session-id>/ に出力された画像を回収する。
set -euo pipefail
out="$1"; prompt="$2"; shift 2
refs=()
for r in "$@"; do refs+=(-i "$r"); done
log="$(mktemp)"
# -i は複数の値を取るので、プロンプトより後ろに置く
codex exec --skip-git-repo-check -s read-only \
  "画像生成ツールで画像を1枚だけ生成してください。ファイルの保存や他の作業は不要です。生成後は何もせず終了してください。
$prompt" "${refs[@]}" </dev/null >"$log" 2>&1 || true
sid="$( (grep -m1 -oE 'session id: [0-9a-f-]+' "$log" || true) | awk '{print $3}')"
img="$(ls -t "$HOME/.codex/generated_images/$sid"/*.png 2>/dev/null | head -1 || true)"
if [[ -z "$img" ]]; then
  echo "FAILED: $out (session $sid)"; tail -5 "$log"; rm -f "$log"; exit 1
fi
mkdir -p "$(dirname "$out")"
cp "$img" "$out"
rm -f "$log"
echo "OK: $out ($(python3 -c "from PIL import Image; im=Image.open('$out'); print(im.size, im.mode)"))"
