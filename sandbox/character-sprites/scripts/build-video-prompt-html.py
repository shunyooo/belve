"""Halloween Cat の各ポーズ用に動画生成プロンプト + PNG パスを HTML にまとめる。
Viggle / Seedance / Kling 等で使う subject 画像 と、loop 用 prompt をまとめて出す。
"""
import json
import html
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SANDBOX = REPO / "sandbox/character-sprites"
SPRITES = SANDBOX / "source"  # frames / mov はここ
OUT = SANDBOX / "reports/video-prompts.html"

# 共通の loop & 静止指示 (任意の image-to-video model 向け)
COMMON_RULES = """static camera with completely fixed framing,
solid green background remains unchanged,
no camera movement, no zoom, no pan, no cuts, no scene change,
no motion lines, no speed lines, no extra visual effects,
the cat's facial features must remain absolutely identical to the reference image at all times:
eyes are simple flat yellow circles that NEVER blink, NEVER change shape, NEVER open or close, NEVER show pupils or eyelids,
the mouth area stays completely empty as in the reference (NO mouth ever appears, no opening, no closing),
no whiskers appear, no new facial features are added that are not visible in the reference image,
the silhouette outline color and thickness stay exactly the same,
seamless loop where the final frame matches the starting frame"""

NEGATIVE = """camera movement, zoom, pan, scene transition, cut, motion lines, speed lines,
sparkles, particles, color shift, character pose change, background change,
multiple cats, text, watermark,
blinking, eyes opening, eyes closing, eye shape change, pupils, eyelids,
mouth, mouth appearing, mouth opening, mouth closing, teeth, tongue, yawning,
whiskers appearing, new facial features, added details not in reference"""

# Pose 別 prompt — 動かす内容のみ簡潔に
POSES = {
    "running": {
        "image": "halloween-poses-verified/running.png",
        "abs_path": "sandbox/character-sprites/variants/halloween-poses-verified/running.png",
        "video_done": "halloween-cat-running.mov",  # MOV = ProRes 4444 alpha (確実に透過)
        "frames_dir": "halloween-cat-running-frames",
        "frames_count": 49,
        "loop_dir": "halloween-cat-running-loop16",
        "loop_count": 48,  # full sequence (no clean sub-cycle)
        "motion": "the chibi black cat trots in place with a gentle four-legged step cycle, only the legs move",
        "expected": "走ってる感、その場 leg cycle、loop",
    },
    "walking": {
        "image": "halloween-poses-verified/walking.png",
        "abs_path": "sandbox/character-sprites/variants/halloween-poses-verified/walking.png",
        "video_done": "halloween-cat-walking.mov",
        "frames_dir": "halloween-cat-walking-frames",
        "frames_count": 49,
        "loop_dir": "halloween-cat-walking-loop16",
        "loop_count": 12,  # detected sub-cycle
        "motion": "the chibi black cat takes slow gentle walking steps in place, calm trotting motion, only legs move slightly",
        "expected": "ゆっくり歩く、subagent 待ちのイメージ",
    },
    "waiting-look": {
        "image": "halloween-poses-verified/waiting-look.png",
        "abs_path": "sandbox/character-sprites/variants/halloween-poses-verified/waiting-look.png",
        "video_done": "halloween-cat-waiting-look.mov",
        "frames_dir": "halloween-cat-waiting-look-frames",
        "frames_count": 49,
        "loop_dir": "halloween-cat-waiting-look-loop16",
        "loop_count": 48,
        "motion": "the chibi black cat slowly turns its head a few degrees to the left then back to center then a few degrees to the right and back, gazing toward the viewer the entire time, ears tilt very slightly with the head motion; the two yellow circle eyes remain perfectly identical and unchanged in shape, size, and position relative to the head — they do NOT blink, do NOT open, do NOT close; only head rotation, nothing else moves",
        "expected": "user 入力待ち、首をゆっくり左右に振ってこっちを凝視 (まばたき禁止)",
    },
    "sleeping-curled": {
        "image": "halloween-poses-verified/sleeping-curled.png",
        "abs_path": "sandbox/character-sprites/variants/halloween-poses-verified/sleeping-curled.png",
        "video_done": "halloween-cat-sleeping-curled.mov",
        "frames_dir": "halloween-cat-sleeping-curled-frames",
        "frames_count": 49,
        "loop_dir": "halloween-cat-sleeping-curled-loop16",
        "loop_count": 48,
        "motion": "the curled-up chibi black cat's silhouette gently scales vertically by a tiny amount (about 2 percent), as if quietly inhaling and exhaling — the whole body shape rises and falls together as a single soft pulse; the closed-eye dashes stay exactly as drawn, no mouth ever appears (the reference has no mouth), no facial features animate, only the overall silhouette breathes",
        "expected": "寝息、シルエット全体が上下に微膨張するだけ (口は出さない)",
    },
}


def _build_anim_block(anim_id, dir_path, count, duration_sec, label_prefix, total_kb=None):
    """Build a CSS-animation block showing transparent + checker BG variants.
    HTML lives in reports/, source frames in ../source/ → prepend that prefix."""
    keyframes = "".join(
        f"{int(i / count * 100)}% {{ background-image: url('../source/{dir_path}/frame_{i+1:03d}.png'); }}\n"
        for i in range(count)
    )
    size_label = f", {total_kb:.1f} KB total" if total_kb is not None else ""
    return f"""
<div style="margin-top:10px;">
  <div style="font-size:11px; color:var(--dim); margin-bottom:6px;">{label_prefix} — {count} frames @ 12fps{size_label}</div>
  <div style="display:flex; gap:16px; align-items:flex-start;">
    <div>
      <div class="anim-play {anim_id}" style="
        width:200px; height:160px;
        background-size:contain; background-repeat:no-repeat; background-position:center;
        background-color:transparent;
        image-rendering:auto;
        border:1px solid var(--border); border-radius:4px;
        "></div>
      <p style="font-size:9px; color:var(--dim); margin:4px 0 0 0;">transparent BG</p>
    </div>
    <div>
      <div class="anim-play {anim_id}" style="
        width:200px; height:160px;
        background-size:contain; background-repeat:no-repeat; background-position:center;
        background:repeating-conic-gradient(#3a3a4a 0% 25%, #2a2a3a 0% 50%) 0 0 / 14px 14px;
        border:1px solid var(--border); border-radius:4px;
        "></div>
      <p style="font-size:9px; color:var(--dim); margin:4px 0 0 0;">checker BG (透過確認)</p>
    </div>
  </div>
  <style>
  @keyframes {anim_id}_kf {{
  {keyframes}}}
  .{anim_id} {{ animation: {anim_id}_kf {duration_sec}s steps(1) infinite; }}
  </style>
</div>"""


def _dir_total_kb(rel_dir):
    d = SPRITES / rel_dir
    if not d.exists():
        return None
    return sum(f.stat().st_size for f in d.glob("*.png")) / 1024


# Pre-rendered animations (no prompt — single asset, state via speed/frame range)
EXTRA_ANIMATIONS = [
    {
        "name": "rainbow-cat",
        "title": "🌈 Rainbow Cat",
        "source": "/Users/s07309/Downloads/black rainbow cat.json (Lottie, 33 frames @ 50fps)",
        "raw_dir": "rainbow-cat-frames",
        "raw_count": 33,
        "loop_dir": "rainbow-cat-loop16",
        "loop_count": 32,
        "fps_native": 50,
        "note": "1 つの動画素材のみ。state は <strong>再生速度 + frame range</strong> で表現する想定 (例: running=2x speed, walking=1x, waiting-look=0.5x + 半周だけ, sleeping-curled=フレーム固定で微 pulse)。",
    },
]


def render_extra_animations():
    if not EXTRA_ANIMATIONS:
        return ""
    blocks = []
    for ea in EXTRA_ANIMATIONS:
        raw_kb = _dir_total_kb(ea["raw_dir"])
        opt_kb = _dir_total_kb(ea["loop_dir"])
        raw_id = f"anim_raw_{ea['name']}".replace("-", "_")
        opt_id = f"anim_opt_{ea['name']}".replace("-", "_")
        # Use native fps for accurate playback feel; fallback to 12fps for optimized
        raw_dur = ea["raw_count"] / ea["fps_native"]
        opt_dur = ea["loop_count"] / 12  # optimized at 12fps like the others
        raw_block = _build_anim_block(
            raw_id, ea["raw_dir"], ea["raw_count"],
            duration_sec=raw_dur,
            label_prefix=f"Raw ({ea['raw_count']} frames @ {ea['fps_native']}fps)",
            total_kb=raw_kb,
        )
        opt_block = _build_anim_block(
            opt_id, ea["loop_dir"], ea["loop_count"],
            duration_sec=opt_dur,
            label_prefix="Optimized (240px crop, pngquant 16c + oxipng)",
            total_kb=opt_kb,
        )
        reduction = ""
        if raw_kb and opt_kb:
            pct = 100 * (1 - opt_kb / raw_kb)
            reduction = f"<p style='font-size:10px; color:#a6e3a1; margin:8px 0 0 0;'>削減: {raw_kb:.0f} KB → {opt_kb:.1f} KB ({pct:.1f}% 減)</p>"
        blocks.append(f"""
<div class="card">
  <div class="card-head">
    <h2>{ea['title']}</h2>
    <span class="exp">単一アニメ — state は速度/frame range で表現</span>
  </div>
  <div class="info">
    <p style="font-size:11px; color:var(--dim); margin:0 0 8px 0;">Source: <code>{html.escape(ea['source'])}</code></p>
    <p style="font-size:11px; color:var(--dim); margin:0 0 12px 0; line-height:1.6;">{ea['note']}</p>
    {raw_block}
    {opt_block}
    {reduction}
    <p style="font-size:10px; color:var(--dim); margin:8px 0 0 0;">
      Raw: <code>{ea['raw_dir']}/</code><br>
      Optimized: <code>{ea['loop_dir']}/</code>
    </p>
  </div>
</div>""")
    return "\n".join(blocks)


def render():
    cards = []
    for name, p in POSES.items():
        full_prompt = f"{p['motion']},\n{COMMON_RULES}"
        video_html = ""
        if p.get("frames_dir"):
            raw_count = p["frames_count"]
            raw_kb = _dir_total_kb(p["frames_dir"])
            raw_id = f"anim_raw_{name}".replace("-", "_")
            raw_block = _build_anim_block(
                raw_id, p["frames_dir"], raw_count,
                duration_sec=raw_count / 12,
                label_prefix="Raw (1112×834 RGBA, full sequence)",
                total_kb=raw_kb,
            )

            opt_block = ""
            if p.get("loop_dir"):
                opt_count = p["loop_count"]
                opt_kb = _dir_total_kb(p["loop_dir"])
                opt_id = f"anim_opt_{name}".replace("-", "_")
                opt_block = _build_anim_block(
                    opt_id, p["loop_dir"], opt_count,
                    duration_sec=opt_count / 12,
                    label_prefix=f"Optimized (240px crop, loop detected, pngquant 16c + oxipng)",
                    total_kb=opt_kb,
                )

            reduction = ""
            if raw_kb and p.get("loop_dir") and _dir_total_kb(p["loop_dir"]):
                opt_kb_v = _dir_total_kb(p["loop_dir"])
                pct = 100 * (1 - opt_kb_v / raw_kb)
                reduction = f"<p style='font-size:10px; color:#a6e3a1; margin:8px 0 0 0;'>削減: {raw_kb:.0f} KB → {opt_kb_v:.1f} KB ({pct:.1f}% 減)</p>"

            video_html = f"""
<details open><summary>✅ Generated video frames (raw + optimized)</summary>
{raw_block}
{opt_block}
{reduction}
<p style="font-size:10px; color:var(--dim); margin:8px 0 0 0;">
  Raw: <code>{p['frames_dir']}/</code><br>
  Optimized: <code>{p.get('loop_dir', '(なし)')}/</code><br>
  MOV (ProRes 4444 alpha): <code>{p['video_done']}</code>
</p>
</details>"""

        cards.append(f"""
<div class="card">
  <div class="card-head">
    <h2>{name}</h2>
    <span class="exp">{p['expected']}</span>
  </div>
  <div class="row">
    <div class="img-cell">
      <img src="../variants/{p['image']}" width="220">
      <div class="path-box">
        <div class="lbl">PNG path (Viggle/Seedance に upload):</div>
        <code class="path">{REPO}/{p['abs_path']}</code>
      </div>
    </div>
    <div class="info">
      <h3>動かす指示 (motion)</h3>
      <pre class="motion">{html.escape(p['motion'])}</pre>
      <h3>共通 loop ルール (動かさない指示)</h3>
      <pre class="rules">{html.escape(COMMON_RULES)}</pre>
      <details>
        <summary>📋 フルプロンプト (コピーして使う)</summary>
        <pre class="full">{html.escape(full_prompt)}</pre>
      </details>
      {video_html}
    </div>
  </div>
</div>""")

    full_negative = NEGATIVE
    html_doc = f"""<!DOCTYPE html>
<html lang="ja"><head><meta charset="UTF-8">
<title>Halloween Cat — 動画生成プロンプト</title>
<style>
:root {{ --bg:#1e1e2e; --surface:#2a2a3a; --border:#3a3a4a; --text:#cdd6f4; --dim:#8a8aa8; --accent:#74c0fc; }}
* {{ box-sizing:border-box; }}
body {{ background:var(--bg); color:var(--text); font-family:-apple-system,sans-serif; padding:24px; font-size:13px; margin:0; }}
h1 {{ font-size:20px; margin:0 0 8px; }}
h2 {{ font-size:15px; margin:0; color:var(--accent); }}
h3 {{ font-size:11px; margin:14px 0 6px; color:var(--dim); text-transform:uppercase; letter-spacing:0.5px; }}
.note {{ color:var(--dim); margin-bottom:24px; line-height:1.6; }}
.note code {{ background:rgba(255,255,255,0.05); padding:1px 5px; border-radius:3px; }}

.section {{ background:var(--surface); border:1px solid var(--border); border-radius:8px; padding:16px; margin-bottom:16px; }}
.card {{ background:var(--surface); border:1px solid var(--border); border-radius:8px; padding:16px; margin-bottom:16px; }}
.card-head {{ display:flex; justify-content:space-between; align-items:center; margin-bottom:14px; gap:14px; }}
.exp {{ color:var(--dim); font-size:11px; }}

.row {{ display:flex; gap:20px; align-items:flex-start; }}
.img-cell {{ flex-shrink:0; width:240px; }}
.img-cell img {{ display:block; border:1px solid var(--border); border-radius:4px; image-rendering:pixelated; background:#00aa00; }}
.path-box {{ margin-top:10px; padding:8px 10px; background:rgba(0,0,0,0.3); border-radius:4px; }}
.path-box .lbl {{ font-size:9px; color:var(--dim); text-transform:uppercase; letter-spacing:0.5px; margin-bottom:4px; }}
.path-box .path {{ font-size:10px; word-break:break-all; color:#a6e3a1; }}

.info {{ flex:1; min-width:0; }}
pre {{ background:rgba(0,0,0,0.3); padding:10px 14px; border-radius:4px; font-size:10px; color:var(--dim); white-space:pre-wrap; line-height:1.5; margin:0; user-select:all; }}
pre.motion {{ color:#94d8ff; }}
pre.rules {{ color:#a6e3a1; }}
pre.full {{ color:var(--text); }}

details {{ background:rgba(0,0,0,0.3); border-radius:4px; padding:8px 12px; margin-top:8px; }}
details summary {{ font-size:11px; color:var(--accent); cursor:pointer; }}
details pre {{ margin-top:8px; }}

.shared-rules {{ background:rgba(116,192,252,0.08); border:1px solid rgba(116,192,252,0.2); border-radius:6px; padding:12px 14px; }}
.shared-rules pre {{ background:rgba(0,0,0,0.4); }}
</style></head><body>

<h1>🎃 Halloween Cat — 動画生成プロンプト集</h1>
<div class="note">
  各 pose の subject PNG + 動画生成用 prompt セット。Viggle / Seedance 2.0 / Kling / Pika 等で使用。<br>
  全 prompt は <strong>loop & 静止カメラ</strong> 前提で組んでます (= UI overlay で繰り返し再生する用途)。
</div>

<div class="section shared-rules">
  <h2>🔁 共通ルール (どの pose でも入れる)</h2>
  <h3>動かさない指示 (positive prompt 末尾)</h3>
  <pre>{html.escape(COMMON_RULES)}</pre>
  <h3>Negative prompt (Seedance / Kling 等で対応)</h3>
  <pre>{html.escape(full_negative)}</pre>
  <h3>推奨パラメータ</h3>
  <ul style="margin:0; padding-left:18px; color:var(--dim); line-height:1.7;">
    <li>duration: <code>3 sec</code> (5 sec 以上は drift しやすい)</li>
    <li>aspect_ratio: <code>1:1</code> (入力と同じ)</li>
    <li>seed: 固定で再現性確保</li>
    <li>解像度: 720p 以上 (UI 用は 512 でも可)</li>
    <li>motion_strength: 中〜弱 (高いと scene change しやすい)</li>
  </ul>
</div>

{''.join(cards)}

{render_extra_animations()}

<div class="section">
  <h2>🎞 動画生成後の処理</h2>
  <p style="color:var(--dim); margin:0 0 8px 0;">完成した mp4 を <code>sandbox/character-sprites/source/</code> に置く。chroma green 透過化:</p>
  <pre>cd sandbox/character-sprites/source
ffmpeg -y -i INPUT.mp4 \\
  -vf "colorkey=0x04D810:0.30:0.10,format=yuva444p" \\
  -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le \\
  OUTPUT.mov</pre>
</div>

</body></html>"""
    OUT.write_text(html_doc)
    print(f"saved: {OUT}")


if __name__ == "__main__":
    render()
