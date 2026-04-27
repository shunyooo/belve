"""HTML report builder — reads _report.json from latest run."""
import json
import html
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SANDBOX = REPO / "sandbox/character-sprites"
JSON_PATH = SANDBOX / "variants/halloween-poses-verified/_report.json"
OUT = SANDBOX / "reports/halloween-poses-verified.html"

data = json.loads(JSON_PATH.read_text())
ref_image_rel = data["ref_image"]
poses = data["poses"]
expected = data["expected"]
results = data["results"]
gemini_model = data["gemini_model"]


def score_color(s):
    if s is None: return "#888"
    if s >= 9: return "#a6e3a1"
    if s >= 7: return "#94e2d5"
    if s >= 5: return "#f9e2af"
    return "#f38ba8"


def issues_html(items, ok_label="No issues"):
    if not items:
        return f"<li class='ok'>{ok_label}</li>"
    return "".join(f"<li>{html.escape(str(i))}</li>" for i in items)


def attempt_html(name, h):
    img_path = f"../variants/halloween-poses-verified/{name}_attempt{h['attempt']}.png"
    if "error" in h:
        return f"<div class='attempt err'>attempt {h['attempt']} ERROR: {html.escape(str(h['error']))}</div>"
    v = h["verdict"]
    cf = v.get("character_features")
    bp = v.get("body_proportion")
    pa = v.get("pose_appropriateness")
    verdict = v.get("verdict", "?")
    badge_color = "#a6e3a1" if verdict == "PASS" else "#f38ba8"
    return f"""
<div class='attempt'>
  <div class='att-head'>
    <strong>Attempt {h['attempt']}</strong>
    <span class='verdict-badge' style='background:{badge_color}'>{verdict}</span>
  </div>
  <div class='att-body'>
    <div class='att-img'>
      <img src='{img_path}' width='120'>
    </div>
    <div class='att-detail'>
      <div class='att-scores'>
        <div class='ascore'><span class='lbl'>character</span><span class='num' style='color:{score_color(cf)}'>{cf}/10</span></div>
        <div class='ascore'><span class='lbl'>body</span><span class='num' style='color:{score_color(bp)}'>{bp}/10</span></div>
        <div class='ascore'><span class='lbl'>pose</span><span class='num' style='color:{score_color(pa)}'>{pa}/10</span></div>
      </div>
      <div class='att-issues'>
        <div><strong>character:</strong><ul>{issues_html(v.get('character_issues', []))}</ul></div>
        <div><strong>body proportion:</strong><ul>{issues_html(v.get('proportion_issues', []))}</ul></div>
        <div><strong>pose:</strong><ul>{issues_html(v.get('pose_issues', []))}</ul></div>
      </div>
      {f"<div class='hint'>💡 hint: {html.escape(v.get('improvement_hint',''))}</div>" if v.get('improvement_hint') else ''}
    </div>
  </div>
</div>"""


VERIFY_PROMPT_TPL = """You are strictly reviewing a generated pixel-art / sticker-style cat illustration.

I will provide:
1. REFERENCE image — the canonical character we want to maintain.
2. GENERATED image — a new pose generated from the reference.

Target pose for the generated image: "{pose_name}"
Expected pose description: "{expected_pose}"

Evaluate THREE axes INDEPENDENTLY. Be strict about body proportions.

A) CHARACTER FEATURES (0-10):
   - Body color: solid black silhouette
   - Outline: vibrant orange glow outline
   - Eyes: two simple round yellow circles (CLOSED OK if sleeping)
   - Nose: tiny pink triangle
   - No mouth, no whiskers
   - Minimal flat sticker style

B) BODY PROPORTIONS (0-10):
   Same chubbiness / roundness / size as reference?
   Reference is VERY CHUBBY, plump, fat, round, chunky.
   Score LOW if generated cat looks slimmer/taller/more realistic/less chibi.

C) POSE APPROPRIATENESS (0-10):
   Matches target pose description (including direction).

Return JSON:
{{character_features, character_issues[], body_proportion, proportion_issues[],
  pose_appropriateness, pose_issues[], verdict, improvement_hint}}

PASS if ALL THREE >= 7."""


def render_pose_card(r):
    name = r["name"]
    img = f"../variants/halloween-poses-verified/{name}.png"
    final_history = r["history"][-1] if r["history"] else None
    final_v = final_history.get("verdict") if final_history and "verdict" in final_history else None
    badge_color = "#a6e3a1" if r["passed"] else "#f38ba8"
    badge_text = f"✅ PASS in {r['attempts']} attempt(s)" if r["passed"] else f"❌ FAIL after {r['attempts']} attempts"

    attempts_html = "".join(attempt_html(name, h) for h in r["history"])
    gen_prompt = poses.get(name, "")
    expected_pose = expected.get(name, "")

    return f"""
<div class='card' style='border-left: 4px solid {badge_color}'>
  <div class='card-head'>
    <h2>{name}</h2>
    <span class='verdict' style='background:{badge_color}'>{badge_text}</span>
  </div>
  <div class='row'>
    <div class='img-cell'>
      <img src='{img}' width='220'>
      <div class='thumb-row'>
        <img src='{img}' width='48'><img src='{img}' width='24'><img src='{img}' width='14'>
      </div>
    </div>
    <div class='info'>
      <h3>Attempts</h3>
      {attempts_html}
      <details>
        <summary>Generation prompt</summary>
        <pre>{html.escape(gen_prompt)}</pre>
      </details>
      <details>
        <summary>Expected pose (Gemini に渡した正解)</summary>
        <pre>{html.escape(expected_pose)}</pre>
      </details>
    </div>
  </div>
</div>"""


cards_html = "".join(render_pose_card(r) for r in results)
verify_prompt_display = VERIFY_PROMPT_TPL  # already escaped-looking, just display

html_doc = f"""<!DOCTYPE html>
<html lang="ja"><head><meta charset="UTF-8">
<title>Halloween Poses — VLM Verified Report</title>
<style>
:root {{ --bg:#1e1e2e; --surface:#2a2a3a; --border:#3a3a4a; --text:#cdd6f4; --dim:#8a8aa8; --accent:#74c0fc; }}
* {{ box-sizing:border-box; }}
body {{ background:var(--bg); color:var(--text); font-family:-apple-system,sans-serif; padding:24px; font-size:13px; margin:0; }}
h1 {{ font-size:20px; margin:0 0 8px; }}
h2 {{ font-size:15px; margin:0; color:var(--accent); }}
h3 {{ font-size:11px; margin:8px 0 6px; color:var(--dim); text-transform:uppercase; letter-spacing:0.5px; }}
.note {{ color:var(--dim); margin-bottom:24px; line-height:1.6; }}
.note code {{ background:rgba(255,255,255,0.05); padding:1px 5px; border-radius:3px; }}

.card {{ background:var(--surface); border:1px solid var(--border); border-radius:8px; padding:16px; margin-bottom:16px; }}
.card-head {{ display:flex; justify-content:space-between; align-items:center; margin-bottom:14px; }}
.verdict {{ padding:3px 10px; border-radius:3px; color:black; font-size:11px; font-weight:600; font-family:monospace; }}

.row {{ display:flex; gap:20px; align-items:flex-start; }}
.img-cell {{ flex-shrink:0; }}
.img-cell img {{ display:block; border:1px solid var(--border); border-radius:4px; image-rendering:pixelated; background:#00aa00; }}
.thumb-row {{ display:flex; gap:6px; margin-top:6px; }}
.info {{ flex:1; min-width:0; }}

.attempt {{ background:rgba(0,0,0,0.25); border-radius:6px; padding:10px 14px; margin-bottom:8px; }}
.att-body {{ display:flex; gap:14px; align-items:flex-start; }}
.att-img img {{ display:block; border:1px solid var(--border); border-radius:4px; image-rendering:pixelated; background:#00aa00; }}
.att-detail {{ flex:1; min-width:0; }}
.attempt.err {{ background:rgba(243,139,168,0.2); }}
.att-head {{ display:flex; justify-content:space-between; align-items:center; margin-bottom:8px; }}
.verdict-badge {{ padding:2px 8px; border-radius:3px; color:black; font-size:10px; font-weight:600; font-family:monospace; }}
.att-scores {{ display:flex; gap:16px; margin-bottom:10px; }}
.ascore {{ flex:1; }}
.ascore .lbl {{ display:block; font-size:9px; color:var(--dim); text-transform:uppercase; letter-spacing:0.5px; }}
.ascore .num {{ font-size:20px; font-weight:600; font-family:monospace; }}
.att-issues {{ display:grid; grid-template-columns:1fr 1fr 1fr; gap:12px; font-size:10px; color:var(--dim); }}
.att-issues ul {{ margin:2px 0 0 0; padding-left:14px; }}
.att-issues li.ok {{ color:#a6e3a1; list-style:none; margin-left:-14px; }}
.att-issues li.ok:before {{ content:"✓ "; }}
.hint {{ margin-top:8px; padding:6px 10px; background:rgba(116,192,252,0.15); border-radius:4px; font-size:11px; color:#94d8ff; }}

details {{ background:rgba(0,0,0,0.3); border-radius:4px; padding:8px 12px; margin-top:8px; }}
details summary {{ font-size:11px; color:var(--accent); cursor:pointer; }}
details pre {{ font-size:10px; color:var(--dim); margin:8px 0 0 0; white-space:pre-wrap; line-height:1.5; }}

.section {{ background:var(--surface); border:1px solid var(--border); border-radius:8px; padding:16px; margin-bottom:16px; }}
</style></head><body>

<h1>🎃 Halloween Poses — VLM Verified Report</h1>
<div class="note">
全 pose を <code>gpt-image-2</code> で生成 → <code>{html.escape(gemini_model)}</code> で 3 軸 (character / body proportion / pose) 一貫性をチェック。<br>
PASS = 3 軸すべて ≥ 7。FAIL なら improvement hint を加えて max 3 attempts まで再生成。<br>
合計 {sum(r['attempts'] for r in results)} attempts ({len(results)} poses)。
</div>

<div class="section">
  <h2>📍 Reference 画像</h2>
  <p style="color:var(--dim); margin:0 0 8px 0;">全 pose の transform 元 (style + body proportions の基準):</p>
  <img src="../{ref_image_rel}" width="220" style="border:1px solid var(--border); border-radius:4px; image-rendering:pixelated; background:#00aa00;">
</div>

{cards_html}

<div class="section">
  <h2>🔍 Gemini 検証 prompt (template)</h2>
  <details open>
    <summary>クリックで展開/折りたたみ</summary>
    <pre>{html.escape(verify_prompt_display)}</pre>
  </details>
</div>

</body></html>"""

OUT.write_text(html_doc)
print(f"saved: {OUT}")
