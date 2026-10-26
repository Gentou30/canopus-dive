# カノープスの深海たからさがし

スマホで遊べる、カードで動く潜水ローグライク。前作「こんこん花札道中」（~/Projects/konkon-hanafuda）とは別リポジトリ・別URL。

## キャラクター（ユーザーの持ちキャラ）
- **カノープス**（主人公）：シャチ×ドラゴン。黒と白の体に黄色の三日月模様・腕の帯、銀の髪、白い小さな角、黄色ふちの大きな耳、青いマフラー、茶色の肩かけかばん。
  元気で中性的な女の子、一人称「ボク」。自信満々のボケ役。基準画像 `art/raw/canopus_base.png`
- **ミラ**（相方）：ウーパールーパー×ドラゴン。青い体、ピンクの縞のエラ、大きな黒い目、ピンクのコウモリ羽、胸にハート。
  **しゃべらない**。鳴き声（きゅっ／きゅ？／きゅ……）と動き（跳ねる・首を振る・羽ではたく等）で気持ちを出すツッコミ役。基準画像 `art/raw/mira_base.png`
- 元の写真（`art/raw/ref_*.jpg`）はスーツの写真なので、生き物のキャラとして描き直す。全年齢向け・頭身低めのマスコット体型で、体の凹凸は描かない

## ルール（`scripts/dive.gd`。画面と切り離してあり、sim からも使う）
- 7×9 マスの海底。カードをタップ → 光ったマスをタップで使う。1ターンに元気3、手札5枚
- ターン終了で敵が予告どおりに動き、空気が1減る。空気0だと毎ターン体力-1。泡の出る所で空気+4
- 拾った宝は**カードとして山札に入る**（使えない＝手札がふさがる）。1階に1回、宝をミラにあずけて手札から消せる
- 敵は次の行動を予告する（赤＝噛む、黄＝電撃）。フグ（追ってくる）/ クラゲ（2ターンに1回まわりに電撃）/ ウツボ（口の前2マス）
- 出口の穴 → 空気だまり（カード1枚もらう）→「浮上して持ち帰る」か「もっと潜る（空気+5）」。気絶するとミラの分＋残りの半分だけ持ち帰る
- 9階（浅瀬・中層・深海 各3階）の底で星のかけら（クリア）
- 行動の結果は events（辞書の配列）で返し、`game.gd` の `_run_events` が順に演出する

## ファイル
- `scripts/game.gd`: 画面の流れ（TITLE → おはなし → PLAY → REST → RESULT）、会話、演出、HUD
- `scripts/board.gd`: 盤の描画（マス・霧・予告・選べるマス）。キャラは `actor.gd`（192px×4コマのドット絵）
- `scripts/card_view.gd` / `cards.gd`: カードの見た目と定義 / `scenario.gd`: セリフ / `ocean_fx.gd`: 光の筋と泡
- `scripts/mini_char.gd` / `screen.gd` / `audio.gd`: 前作から流用（ミニキャラ・縦横切り替え・音）
- デバッグビルドのみ：F1 出口へ / F2 空気1 / F3 体力1 / F4 一番深い所へ泳ぐ / F5 1枚目を選ぶ / F6 気絶 / F7 最下層クリア / Space ターン終了

## 素材
- 画像は `tools/gen_image.sh`（Codex で生成）→ `tools/make_sprites.py`（px_*.png を4コマに）/ `tools/chroma_key.py`（緑抜き）
  生成スクリプトは `tools/gen_batch*.sh`。カードの絵は `assets/images/ui/icons.png`（192px の4×3）
- 音は `tools/make_music.py`（BGM・ジングル）と `tools/make_audio.py`（効果音・ミラの鳴き声）で合成。
  BGM の `.wav.import` は `edit/loop_mode=2`
- 生成AI素材であることはタイトルに明記している

## 確認
- バランス: `godot --headless -s res://tools/balance_sim.gd -- 100 [log]`（欲張り具合ごとに到達階・気絶率・平均点）
- 書き出しは構文エラーがあっても成功するので、公開前に sim か `godot --headless --quit-after 60` を1回流す

## コマンド・公開
- Godot 4.7.2（`godot`）、GDScript、Compatibility。基準解像度は縦 720x1280 / 横 1280x720（Screen が切り替える）
- Web: `godot --headless --export-release "Web" build/web/index.html`
- main に push すると GitHub Pages にデプロイ（`.github/workflows/pages.yml`）
