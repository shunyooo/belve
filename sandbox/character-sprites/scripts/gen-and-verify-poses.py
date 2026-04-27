#!/usr/bin/env python3
"""
Halloween Cat の status 別ポーズを gpt-image-2 で生成し、
Gemini 3.1 Pro Vision で character / pose の一貫性をチェック → 失敗なら regenerate。

要件:
  pip install openai google-genai

env:
  OPENAI_API_KEY     ... gpt-image-2 用
  GOOGLE_API_KEY     ... Gemini Vision 判定用

Gemini モデル (順に fallback):
  gemini-3.1-pro-preview → gemini-3-flash-preview → gemini-2.5-pro

Output:
  variants/halloween-poses-verified/<name>.png
  variants/halloween-poses-verified/_report.md
"""
import os
import sys
import base64
import json
import time
import argparse
from pathlib import Path
from openai import OpenAI

REPO = Path(__file__).resolve().parents[3]
ENV_PATH = REPO / ".env"
SANDBOX = REPO / "sandbox/character-sprites"
REF_PATH = SANDBOX / "variants/halloween-cat-eyes-v3.png"
OUT_DIR = SANDBOX / "variants/halloween-poses-verified"

GREEN_BG = ("on a solid pure chroma green background (RGB 0,255,0), "
            "background fills entire image edge to edge, no shadow, no border, no text")

RIGHT = "facing right with head on the right side of the image and body extending to the left"

# Body proportion を強く維持する共通 suffix (キャラ汎用、reference 画像から推論させる)
KEEP_BODY = (
    "CRITICAL: maintain the EXACT SAME body proportions, silhouette, plumpness, "
    "limb thickness, head-to-body ratio, and overall character size as the reference image. "
    "Do not slim down, stretch, elongate, or change the body shape in any way — "
    "match the reference's proportions precisely"
)

POSES = {
    "running": (
        f"transform this exact same chibi black cat character into a running pose, "
        f"{RIGHT}, mid-stride trot with legs SHORT and STUBBY (chibi style), "
        f"front legs SLIGHTLY forward and back legs SLIGHTLY back — small leg movement only, "
        f"NOT long stretched extended legs, NOT a long-limbed sprint, "
        f"the legs should look like the chibi reference's stubby short legs but in motion, "
        f"the BODY/TORSO stays exactly chubby round plump compact like the reference, "
        f"slight forward lean, ears alert, cute trotting motion, "
        f"keep exactly the same colors / outline / eyes / nose / body proportions / leg length"
    ),
    "walking": (
        f"transform this exact same chibi black cat character into a walking pose, "
        f"{RIGHT}, one front paw lifted forward in mid-step, calm steady stride, "
        f"ears up alert, keep exactly the same style colors eyes nose. {KEEP_BODY}"
    ),
    "waiting-look": (
        f"transform this exact same chibi black cat character into a sitting pose, "
        f"body in a 3/4 angled view (NOT directly facing camera, body tilted to slight side angle), "
        f"head turned to look directly at the viewer (face toward camera), ears perked up attentive, "
        f"tail wrapped around feet, keep exactly the same style colors eyes nose. {KEEP_BODY}"
    ),
    "sleeping-curled": (
        f"transform this exact same chibi black cat character into a sleeping curled-up pose, "
        f"eyes closed shown as TWO HORIZONTAL straight short lines/dashes "
        f"(NOT upturned slanted curves, NOT angry-looking, just gentle peaceful horizontal lines), "
        f"tail wrapped around body, very compact round ball shape, peaceful expression, "
        f"keep exactly the same style colors body fur outline nose. {KEEP_BODY}"
    ),
}

# Pose 別の「期待される pose 内容」 (Gemini の判定用、人間語の説明)
# body proportion check に対する pose 別注釈も含む
POSE_EXPECTED = {
    "running": (
        "The cat is in a chibi running / trotting pose. Legs should be SHORT and STUBBY like the reference "
        "(do NOT accept long stretched extended legs — penalize if legs look too long or sprint-like). "
        "Front legs slightly forward, back legs slightly back, small motion. "
        "BODY/TORSO must stay chubby, plump, compact, and blob-like just like the reference. "
        "Body slightly tilted forward, facing right."
    ),
    "walking": (
        "The cat is walking calmly, one paw lifted, body level, facing right (head on right side of image). "
        "Body proportions should still feel chunky like reference."
    ),
    "waiting-look": (
        "The cat is sitting in a 3/4 angled view (body slightly turned to the side, NOT directly facing camera), "
        "head turned to look directly at the viewer. Attentive / curious."
    ),
    "sleeping-curled": (
        "The cat is curled up sleeping. Eyes are closed shown as TWO HORIZONTAL short straight lines / dashes "
        "(NOT upturned slanted curves that could look angry — peaceful flat horizontal lines). "
        "Body in a compact round shape."
    ),
}


def load_env():
    if ENV_PATH.exists():
        for line in ENV_PATH.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                os.environ[k.strip()] = v.strip().strip('"').strip("'")


def generate_pose(name: str, prompt: str, attempt: int) -> bytes:
    """gpt-image-2 で reference image をベースに pose 画像を生成。"""
    full_prompt = f"{prompt}, {GREEN_BG}"
    if attempt > 0:
        full_prompt = f"[ATTEMPT {attempt+1}, IMPROVE BASED ON FEEDBACK] {full_prompt}"
    client = OpenAI()
    with open(REF_PATH, "rb") as img:
        result = client.images.edit(
            model="gpt-image-2",
            image=img,
            prompt=full_prompt,
            size="1024x1024",
            quality="high",
            background="opaque",
            output_format="png",
            n=1,
        )
    return base64.b64decode(result.data[0].b64_json)


GEMINI_MODEL = "gemini-3.1-pro-preview"


def get_gemini_client():
    """Gemini Vision client を取得 (google-genai SDK、gemini-3.1-pro-preview 固定)。"""
    from google import genai
    client = genai.Client(api_key=os.environ["GOOGLE_API_KEY"])
    return client, GEMINI_MODEL


def verify_with_gemini(gemini, ref_bytes: bytes, gen_bytes: bytes,
                       pose_name: str, expected_pose: str) -> dict:
    """Gemini に character + pose 一貫性を判定させる。"""
    client, model_name = gemini
    from google.genai import types
    prompt = f"""You are strictly reviewing a generated pixel-art / sticker-style cat illustration.

I will provide:
1. REFERENCE image — the canonical character we want to maintain.
2. GENERATED image — a new pose generated from the reference.

Target pose for the generated image: "{pose_name}"
Expected pose description: "{expected_pose}"

Evaluate THREE axes INDEPENDENTLY. Be strict about body proportions.

First, OBSERVE the REFERENCE image carefully and form a mental description of its character traits:
   - Color palette (body, outline, eyes, nose, etc.)
   - Style (sticker, pixel-art, cell-shaded, etc.)
   - Distinctive features (mouth/whiskers presence, specific markings)
Use this REFERENCE-derived description as the criterion. Do NOT assume any specific traits.

A) CHARACTER FEATURES (0-10):
   Does the GENERATED character have the same colors, outline, eye style, nose style,
   and overall artistic style as you observed in the REFERENCE?
   Score LOW if any feature visibly drifts (color shift, lost outline, added whiskers, etc.).

B) BODY PROPORTIONS (0-10):
   Compare body shape between REFERENCE and GENERATED:
   - Overall plumpness / slimness ratio
   - Body length-to-width ratio
   - Head-to-body size ratio
   - Limb thickness
   - Chibi-ness vs realistic-ness
   Score LOW if the generated cat's silhouette / proportions visibly differ from the
   reference (even if colors and features match). This is the most common drift.

C) POSE APPROPRIATENESS (0-10):
   Does the GENERATED match the target pose description?
   Check direction (right-facing = head on RIGHT side of image).

Return ONLY a JSON object (no markdown fences, no commentary):
{{
  "character_features": <int 0-10>,
  "character_issues": [<short string>],
  "body_proportion": <int 0-10>,
  "proportion_issues": [<short string, e.g. 'too slim', 'too tall', 'less chubby than ref'>],
  "pose_appropriateness": <int 0-10>,
  "pose_issues": [<short string>],
  "verdict": "PASS" | "FAIL",
  "improvement_hint": "<short prompt-fix suggestion specific to weakest axis>"
}}

PASS if ALL THREE scores >= 7. FAIL if any is < 7.
"""
    contents = [
        prompt,
        types.Part.from_bytes(data=ref_bytes, mime_type="image/png"),
        types.Part.from_bytes(data=gen_bytes, mime_type="image/png"),
    ]
    resp = client.models.generate_content(model=model_name, contents=contents)
    text = resp.text.strip()
    # Strip markdown fences if present
    if text.startswith("```"):
        text = "\n".join(text.split("\n")[1:-1])
    return json.loads(text)


def process_pose(name: str, prompt: str, gemini_model, max_attempts: int = 3):
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    ref_bytes = REF_PATH.read_bytes()
    expected = POSE_EXPECTED[name]
    history = []

    current_prompt = prompt
    for attempt in range(max_attempts):
        print(f"\n=== {name} attempt {attempt+1}/{max_attempts} ===", file=sys.stderr)
        try:
            gen_bytes = generate_pose(name, current_prompt, attempt)
        except Exception as e:
            history.append({"attempt": attempt+1, "error": f"generate: {e}"})
            continue

        # 中間ファイル (デバッグ用)
        debug_path = OUT_DIR / f"{name}_attempt{attempt+1}.png"
        debug_path.write_bytes(gen_bytes)
        print(f"   saved attempt: {debug_path}", file=sys.stderr)

        try:
            verdict = verify_with_gemini(gemini_model, ref_bytes, gen_bytes, name, expected)
        except Exception as e:
            history.append({"attempt": attempt+1, "error": f"verify: {e}"})
            continue

        history.append({"attempt": attempt+1, "verdict": verdict})
        print(f"   char={verdict.get('character_features')} body={verdict.get('body_proportion')} pose={verdict.get('pose_appropriateness')} -> {verdict['verdict']}", file=sys.stderr)
        print(f"   issues: char={verdict.get('character_issues')} prop={verdict.get('proportion_issues')} pose={verdict.get('pose_issues')}", file=sys.stderr)

        if verdict["verdict"] == "PASS":
            final_path = OUT_DIR / f"{name}.png"
            final_path.write_bytes(gen_bytes)
            print(f"   ✅ PASSED — saved to {final_path}", file=sys.stderr)
            return {"name": name, "passed": True, "attempts": attempt+1, "history": history, "final_score": verdict}

        # Failed → adjust prompt with hint, retry
        hint = verdict.get("improvement_hint", "")
        if hint:
            current_prompt = f"{prompt} | EXTRA GUIDANCE FROM REVIEWER: {hint}"

    print(f"   ⚠️  max attempts reached, using last attempt", file=sys.stderr)
    final_path = OUT_DIR / f"{name}.png"
    final_path.write_bytes(gen_bytes)
    return {"name": name, "passed": False, "attempts": max_attempts, "history": history}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pose", help="Generate single pose only (default: all)")
    parser.add_argument("--max-attempts", type=int, default=3)
    args = parser.parse_args()

    load_env()
    if not os.environ.get("OPENAI_API_KEY"):
        sys.exit("OPENAI_API_KEY not set")
    if not os.environ.get("GOOGLE_API_KEY"):
        sys.exit("GOOGLE_API_KEY not set in .env (needed for Gemini Vision verification)")

    gemini = get_gemini_client()

    targets = {args.pose: POSES[args.pose]} if args.pose else POSES

    # Pose 間は独立なので並列化 (within pose の attempt 連鎖は逐次)。
    # OpenAI / Gemini 両方とも rate limit ある程度の並列に耐えるので 6 並列。
    import concurrent.futures
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(6, len(targets))) as ex:
        future_map = {
            ex.submit(process_pose, name, prompt, gemini, args.max_attempts): name
            for name, prompt in targets.items()
        }
        for f in concurrent.futures.as_completed(future_map):
            results.append(f.result())

    # Report
    report_lines = ["# Halloween Pose Generation Report", ""]
    for r in results:
        status = "✅ PASS" if r["passed"] else "❌ FAIL"
        report_lines.append(f"## {r['name']} — {status} ({r['attempts']} attempts)")
        for h in r["history"]:
            if "error" in h:
                report_lines.append(f"- attempt {h['attempt']}: ERROR {h['error']}")
            else:
                v = h["verdict"]
                report_lines.append(
                    f"- attempt {h['attempt']}: char={v.get('character_features')} "
                    f"body={v.get('body_proportion')} pose={v.get('pose_appropriateness')} → {v['verdict']}"
                )
                if v.get("character_issues"):
                    report_lines.append(f"  - char issues: {v['character_issues']}")
                if v.get("proportion_issues"):
                    report_lines.append(f"  - proportion issues: {v['proportion_issues']}")
                if v.get("pose_issues"):
                    report_lines.append(f"  - pose issues: {v['pose_issues']}")
                if v.get("improvement_hint"):
                    report_lines.append(f"  - hint: {v['improvement_hint']}")
        report_lines.append("")

    report_path = OUT_DIR / "_report.md"
    report_path.write_text("\n".join(report_lines))
    # JSON も保存 (HTML レポート用)
    json_path = OUT_DIR / "_report.json"
    json_path.write_text(json.dumps({
        "ref_image": str(REF_PATH.relative_to(SANDBOX)),
        "poses": POSES,
        "expected": POSE_EXPECTED,
        "results": results,
        "gemini_model": GEMINI_MODEL,
    }, indent=2, default=str))
    print(f"\nReport: {report_path}", file=sys.stderr)
    print(f"JSON:   {json_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
