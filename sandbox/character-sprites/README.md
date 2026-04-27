# Animated character indicator pipeline

Belve の Status indicator (sidebar の状態 sprite) 用キャラを作って入れる時のフル workflow メモ。Halloween cat (= chibi cat) / Rainbow cat / Party Parrot の 3 体はこの流れで投入済。次に別キャラを入れる時はこの順で作業する。

## ディレクトリ構成

```
sandbox/character-sprites/
  README.md                 ← このファイル
  scripts/                  ← 全 Python スクリプト
  source/                   ← mp4/mov/frame 連番/loop16 (= 中間動画素材、gitignore)
  variants/                 ← AI 生成 reference / 各 pose PNG (= 中間画像素材、gitignore)
  reports/                  ← 生成 HTML プレビュー (gitignore)
  raw/                      ← .lottie / .json 元素材 (size 次第で track してよい)
```

bundle される最終 PNG だけ `Sources/Belve/Resources/sprites/` に置く (= chibicat-*.png, rainbocat-*.png, parrot-*.png)。

## 全体フロー

```
[1] reference 画像 1 枚生成 (gpt-image-1, chroma green BG)
        ↓
[2] pose 別 PNG を gpt-image-2 image-edit + Gemini VLM で生成 (verified PASS まで自動 retry)
        ↓
[3] pose PNG を Viggle / Seedance に投げて短い loop 動画 (mp4) を生成
        ↓
[4] mp4 → chroma key → ProRes 4444 alpha → PNG 連番 (12fps)
        ↓
[5] Loop 検出 + union bbox crop + pngquant 16c + oxipng (= optimize-pose-frames.py)
        ↓
[6] Centroid alignment + 48px resize + Resources/sprites/ に展開 (= export-sprites-for-indicator.py)
        ↓
[7] StatusIndicator.swift に case 追加
```

## 1. Reference 画像

OpenAI `gpt-image-1` (raw generation)。**solid chroma green BG** が後段の透過化前提なので必須。

ハロウィン猫の例 (sprites/halloween-poses.html 内に prompt 残してある):
```
chibi loaf cat, black silhouette body with vibrant orange outline glow,
chubby round crouching shape, two small pointed ears,
two simple yellow round eyes only (small filled circles),
tiny pink triangle nose, no mouth, no whiskers, no detail,
sticker style flat design, halloween,
on a solid pure chroma green background (RGB 0,255,0)
```

候補を 3-5 枚生成して 1 つ選ぶ → `sandbox/character-sprites/variants/<character>.png` に保存。

## 2. Pose 別 PNG (verified)

`sandbox/character-sprites/scripts/gen-and-verify-poses.py` を使う。

中身:
- gpt-image-2 の `images.edit` で reference を渡しつつ pose 別 prompt を投げる
- Gemini 3.1 Pro Vision で 3 軸 (character_features / body_proportion / pose_appropriateness) 各 0-10 採点
- 全軸 ≥ 7 で PASS、未満なら improvement_hint を加えて max 3 attempts
- ThreadPoolExecutor で全 pose 並列生成

POSES dict を編集してから:
```bash
python3 sandbox/character-sprites/scripts/gen-and-verify-poses.py
python3 sandbox/character-sprites/scripts/build-pose-report-html.py   # 検証レポート HTML 生成
```

出力: `sandbox/character-sprites/variants/<character>-poses-verified/<pose>.png`

## 3. 動画化 prompt

`sandbox/character-sprites/scripts/build-video-prompt-html.py` の `POSES` dict と `COMMON_RULES` / `NEGATIVE` を確認 / 編集して:

```bash
python3 sandbox/character-sprites/scripts/build-video-prompt-html.py
open sandbox/character-sprites/reports/video-prompts.html
```

各 pose ごとに subject PNG path + フルプロンプト (motion + COMMON_RULES) が表示されるので、コピーして Viggle V4 / Seedance 2.0 Fast / Kling 等に投げる。

**重要 — generation 時の注意点** (Halloween cat で踏んだ罠):
- `blink once` 系の動詞は使わない → 目を閉じる動きが入って「描かれてない目」を勝手に作り出す
- `breathes` も「口で息する」と解釈されて口を出してくる → `silhouette gently scales vertically` 等、構造的な指示にする
- `the reference has no mouth` のように **絶対出さない要素を明示的に negative-by-presence** で書く
- COMMON_RULES に `eyes are simple flat yellow circles that NEVER blink/change shape/open/close` 等を入れる

推奨パラメータ:
- duration: 3 sec (5 sec 以上は drift しやすい)
- aspect_ratio: 1:1
- seed: 固定で再現性確保
- motion_strength: 中〜弱

完成 mp4 を `~/Downloads/` から `sandbox/character-sprites/source/<character>-<pose>.mp4` にリネームして配置。

## 4 (alt). Lottie (.json / .lottie) → PNG 連番

LottieFiles 等から取得した vector アニメは Viggle 経由不要。直接 frame 化:

```bash
# .lottie は zip。.json (Lottie JSON) を取り出す
mkdir -p /tmp/lottie-extract
unzip -o "<source>.lottie" -d /tmp/lottie-extract
# → animations/<id>.json
```

```python
# rlottie-python で render
from rlottie_python import LottieAnimation
from pathlib import Path

with open("/tmp/lottie-extract/animations/12345.json") as f:
    json_data = f.read()
anim = LottieAnimation.from_data(json_data)
n = anim.lottie_animation_get_totalframe()
out = Path("sandbox/character-sprites/source/<name>-frames")
out.mkdir(exist_ok=True)
W, H = 256, 256   # source resolution (indicator は 14×14 表示なので 256 でも余裕)
for i in range(n):
    anim.render_pillow_frame(frame_num=i, width=W, height=H).save(out / f"frame_{i+1:03d}.png")
```

frame 化したら **5 (loop 検出)** から先は同じパイプライン。

埋め込み画像 (lfvideo2lottie 等で video → Lottie 変換した assets が data:image/webp で入ってる) の場合は、layers をプレイバック順 (`ip` 昇順) に並べて assets[refId] の base64 をデコードするだけで OK。

## 4. mp4 → 透過 PNG 連番

Viggle / Seedance 出力の chroma green は **pure 0x00FF00 ではない** (圧縮で `#04D810` 等にズレる)。
ffprobe で 1 frame 取って色サンプリングしてから `colorkey` (RGB 距離) を使う。

**chromakey vs colorkey**:
- `chromakey` (YUV 距離): 黒い体が green と U/V 距離近くて食われがち
- `colorkey` (RGB 距離): 黒 ↔ 緑は RGB 距離十分遠いので安全

```bash
cd sandbox/character-sprites/source

# 1. green 色をサンプリング
ffmpeg -y -ss 0.5 -i <char>-<pose>.mp4 -vframes 1 \
    -vf "crop=20:20:10:10" /tmp/sample.png
python3 -c "from PIL import Image; im=Image.open('/tmp/sample.png').convert('RGB');\
px=list(im.getdata()); print('hex:', '#%02X%02X%02X' % tuple(sum(c)//len(px) for c in zip(*px)))"

# 2. chroma key + ProRes 4444 alpha .mov に変換 (= 確実に透過保持)
ffmpeg -y -i <char>-<pose>.mp4 \
    -vf "colorkey=0xXXXXXX:0.30:0.10,format=yuva444p" \
    -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le \
    <char>-<pose>.mov

# 3. PNG 連番に展開 (12fps = ~49 frames for 4 sec)
mkdir -p <char>-<pose>-frames
ffmpeg -y -i <char>-<pose>.mov -vf "fps=12" \
    <char>-<pose>-frames/frame_%03d.png
```

**alpha 健全性チェック** (体中央が 255、コーナーが 0 か):
```python
from PIL import Image
im = Image.open('<char>-<pose>-frames/frame_010.png')
r,g,b,a = im.split()
print('corner:', a.getpixel((0,0)))            # 0 期待
print('center:', a.getpixel((im.size[0]//2, im.size[1]//2)))  # 255 期待
```

WebM (VP9 alpha) は libvpx の bug で alpha 落ちるので使わない。MOV (ProRes 4444) + PNG 連番が正解。

## 5. Loop 検出 + 第一段最適化

```bash
python3 sandbox/character-sprites/scripts/optimize-pose-frames.py <pose1> <pose2> ...
# 内部で `halloween-cat-<pose>-frames` を見て `halloween-cat-<pose>-loop16` を出力
```

仕組み:
- 全 frame ペアの MSE を計算して最小 sub-period を検出 (= 走り 1 cycle が短ければそれだけで十分)
- 閾値: `min(global_min × 20, median / 5)` で「明確な dip」だけを sub-cycle として認める
- 検出した P frames を抽出 → union bbox で crop → 240px に downscale → pngquant 16c + oxipng

**他キャラ用途の prefix 変更**: スクリプトは `halloween-cat-<pose>-frames` または `<pose>-frames` を auto-detect。新キャラで命名規約を変える時はこの分岐を更新。

出力: `halloween-cat-<pose>-loop16/frame_NNN.png`
HTML プレビュー (raw vs optimized 並列、checker BG 透過確認):
```bash
python3 sandbox/character-sprites/scripts/build-video-prompt-html.py
open sandbox/character-sprites/reports/video-prompts.html
```

## 6. Indicator 用 export

```bash
python3 sandbox/character-sprites/scripts/export-sprites-for-indicator.py \
  --prefix hallocat \
  --pose run:halloween-cat-running-loop16 \
  --pose walk:halloween-cat-walking-loop16 \
  --pose wait:halloween-cat-waiting-look-loop16 \
  --pose sleep:halloween-cat-sleeping-curled-loop16 \
  --rest hallocat-wait-1.png
```

このスクリプトの 3 つの仕事:

1. **Centroid alignment**: 各 frame の cat 重心を計算 → 全 frame で同じ位置になるよう shift。
   - 14×14 表示では source 1px = 0.3 表示 px、≥1px のドリフトが jitter に見える
   - 走り pose で `~3px` の補正が入る (体が走りながら上下する分)
   - 待ち / 寝のような static pose は `<1px` 補正で済む
2. **Resize to 48px** (long side): indicator 14×14 (28×28 retina) の ~1.7× oversampling
3. **pngquant 16c + oxipng**: 全 frame 合計 ~80 KB、メモリ ~1 MB

出力: `Resources/sprites/<prefix>-<action>-<N>.png`

## 7. Belve に組み込み

`Sources/Belve/Views/StatusIndicator.swift` を編集:

### 7-1. enum に case 追加

```swift
enum SpinnerStyle: String, CaseIterable, Codable {
    case pulse, invader, ghost, halloweenCat, partyParrot, /* ... */
    case <newCharacter>

    var displayName: String {
        switch self {
        // ...
        case .<newCharacter>: return "<Display Name>"
        }
    }
}
```

### 7-2. switch case 追加 (StatusIndicator body 内)

```swift
case .<newCharacter>:
    PNGSpriteIndicator(
        status: status,
        runFrames: (0...<runCount-1>).map { "<prefix>-run-\($0)" },
        restFrame: "<prefix>-rest",
        runInterval: 0.083,                                   // 12fps native
        subagentFrames: (0...<walkCount-1>).map { "<prefix>-walk-\($0)" },
        subagentInterval: 0.083,
        waitingFrames: (0...<waitCount-1>).map { "<prefix>-wait-\($0)" },
        waitingInterval: 0.083,
        completedFrames: (0...<sleepCount-1>).map { "<prefix>-sleep-\($0)" },
        completedInterval: 0.083,
        idleFrames: (0...<sleepCount-1>).map { "<prefix>-sleep-\($0)" },
        idleInterval: 0.083,
        interpolation: .high,    // anti-aliased illustration なら .high、pixel art なら .none
        trimPadding: false,      // 既に union bbox で揃え済み
        enableBob: false         // 源動画に bob 入ってるなら false (= 二重モーション抑制)
    )
```

**parameter 選択基準**:
- `interpolation: .high` ← Viggle 等 illustration 系 (anti-aliased outline 持ち)
  `.none` ← pixel art (固いエッジ維持)
- `trimPadding: false` ← export-sprites-for-indicator.py 通した frames (canvas が揃ってる)
  `true` ← PixelLab 等 frame ごとに padding バラバラなやつ
- `enableBob: false` ← 源動画に既に体の上下動きがある (Viggle 走り等)
  `true` ← 静止 pose pixel sprite に追加 bounce が欲しい時

### 7-3. State → pose のマッピング指針

| AgentStatus | Halloween cat の例 | 一般則 |
|---|---|---|
| `.running` | running (48f) | 主作業中。最も active な動き |
| `.runningSubagent` | walking (12f) | 子 task 待ち。少しゆっくり |
| `.waiting` | waiting-look (48f) | user 入力待ち。こっち向いてアピール |
| `.completed` / `.sessionEnd` | sleeping-curled | 完了 = 寝/一息 (active 系から距離) |
| `.sessionStart` / `.idle` | sleeping-curled | 何もしてない時 |

## バリエーション: 単一アニメ × speed で state 表現 (Rainbow Cat 方式)

pose 別に動画を作らず **1 つのアニメだけ** (Lottie / 既存 GIF など) しか手元にないキャラの場合は、interval を state ごとに変えるだけで動きの速度差で意味を伝える。

Rainbow cat の例:
- source: Lottie JSON 1 個 (33 frames @ 50fps、虹色 outline cycle、わずかな body roll)
- 中身: 32f を centroid-align + 48px export → `rainbocat-cycle-0..31.png` + `rainbocat-rest.png`
- Switch case では同じ frame 配列を全 state に渡し、interval だけ変える:

```swift
case .rainbowCat:
    let cycle = (0...31).map { "rainbocat-cycle-\($0)" }
    PNGSpriteIndicator(
        status: status,
        runFrames: cycle,           runInterval: 0.05,   // 1.6s/cycle 派手
        subagentFrames: cycle,      subagentInterval: 0.08,
        waitingFrames: cycle,       waitingInterval: 0.12,
        completedFrames: cycle,     completedInterval: 0.18,
        idleFrames: cycle,          idleInterval: 0.25,  // 8s/cycle ほぼ静止
        restFrame: "rainbocat-rest",
        interpolation: .high,
        trimPadding: false,
        enableBob: false
    )
```

応用案 (まだ未実装):
- frame range を切る: `idleFrames: Array((0...3).map { ... })` で「1 色だけゆっくり呼吸」みたいな静的扱い
- 逆再生: 完了時だけ `cycle.reversed()` を渡して反対方向に色流す

### Done = 完全静止、Idle = 静止 + ふわふわ float

`PNGSpriteIndicator` の `idleFloat: true` で 1 frame を sin curve で y 方向 ±0.6pt、2.5s 周期で揺らす。
"動いてないけど生きてる" 表現で、completed (完全静止) との対比で使う。

```swift
completedFrames: ["<prefix>-...-0"], completedInterval: 1.0,  // 1 枚 → 静止
idleFrames: ["<prefix>-...-0"],      idleInterval: 1.0,
idleFloat: true,                                               // sin float on
```

halloween cat (sleep frame 0 を完全静止 / float)、rainbow cat (cycle frame 0)、party parrot (cycle frame 0) で採用。

## 容量・メモリの目安

Halloween cat 実測 (157 PNG, 48px source):
- バンドル増分: **~80 KB** (pngquant 16c + oxipng 後)
- 実行時メモリ: **~1 MB** (全 frame decoded 状態)

ヒント:
- 表示が 14×14 でも retina で 28×28、48px source は 1.7× 余裕。減らすほど猫の目 (黄丸) のディテール消える
- pngquant 16 colors はキャラの主要色 (黒, orange, yellow, pink, transparent) で必要十分。**32c に増やしても見た目変わらず容量増えるだけ**
- JPG は alpha なしなので indicator には不可

## ハマりやすいポイント (= debug 起点)

1. **frame ごとに表示サイズが微妙に違う / 揃わない**: Swift `SpriteImageCache.trimTransparentPadding` が frame 個別に bbox 計算してる。
   `trimPadding: false` で skip、source 側で union bbox 揃えてあれば OK。
2. **走り pose だけブレる**: 源動画に体の上下動きあり + Swift `bob` (±0.4pt) で二重モーション。
   `enableBob: false` で Swift 側 bounce off。それでもダメなら centroid alignment で源側を揃える。
3. **目が開いたり口が出たりする (動画生成段階)**: prompt が「ない要素を作り出す」傾向。
   - COMMON_RULES に「eyes never change shape」「mouth area stays empty as in reference」を入れる
   - NEGATIVE に `blinking, mouth opening, eye state change, new facial features` を追加
4. **chroma key で体の黒部分が透ける**: `chromakey` (YUV) → `colorkey` (RGB) に変える。
5. **WebM 出力が透明にならない**: libvpx VP9 alpha bug。**MOV (ProRes 4444) + PNG 連番** で固定。
6. **pose の expected pose が PixelLab/gpt の生成と全然違う**: gen-and-verify-poses.py の `expected` 文を見直す → Gemini 採点が改善 → retry ループで補正される。
