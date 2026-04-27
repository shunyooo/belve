"""Export per-pose loop16 frames as small Belve indicator sprites.

For each pose:
  1. Load all frames from `source-videos/<character>-<pose>-loop16/`
  2. Align cat centroid across frames (= cancel source body drift —
     critical for tiny indicator size where ±1px shifts look like jitter)
  3. Re-crop to union bbox, resize to TARGET_PX on long side
  4. pngquant 16 colors + oxipng → write to
     `Resources/sprites/<prefix>-<action>-<N>.png`

Indicator displays at 14×14 pt (28×28 retina), so 48 px source is enough
(~1.7× retina oversampling). All frames in a pose share the same canvas
size so Swift `aspectRatio(.fit)` keeps scale identical → no jitter.

Usage:
  python3 scripts/export-sprites-for-indicator.py \\
    --prefix hallocat \\
    --pose run:halloween-cat-running-loop16 \\
    --pose walk:halloween-cat-walking-loop16 \\
    --pose wait:halloween-cat-waiting-look-loop16 \\
    --pose sleep:halloween-cat-sleeping-curled-loop16 \\
    --rest hallocat-wait-1.png

Notes:
- Source dirs must already be union-cropped + loop-detected
  (run scripts/optimize-pose-frames.py first).
- Wait/sleep poses with very subtle motion get near-zero shift correction.
- Run pose typically gets ~3 px shift correction (body bobs while running).
"""
import argparse
import shutil
import subprocess
from pathlib import Path
from PIL import Image
import numpy as np

REPO = Path(__file__).resolve().parents[3]
SPRITES = REPO / "Sources/Belve/Resources/sprites"  # 最終 sprite 出力先 (bundle される)
SRC_DIR = REPO / "sandbox/character-sprites/source"  # 中間 loop16 frames の置き場 (bundle 外)
TARGET_PX = 48


def centroid_align(frames):
    """Shift each frame so its cat centroid lands at the average centroid.

    Returns a new list of RGBA frames, all enlarged with transparent padding
    to fit the worst-case shift.
    """
    n = len(frames)
    W, H = frames[0].size

    centroids = []
    for f in frames:
        arr = np.array(f)
        a = arr[:, :, 3]
        ys, xs = np.where(a > 50)
        if len(xs) == 0:
            centroids.append((W / 2, H / 2))
        else:
            centroids.append((float(xs.mean()), float(ys.mean())))

    tx = sum(c[0] for c in centroids) / n
    ty = sum(c[1] for c in centroids) / n

    max_shift = max(
        max(abs(c[0] - tx) for c in centroids),
        max(abs(c[1] - ty) for c in centroids),
    )
    pad = int(np.ceil(max_shift)) + 2
    new_W, new_H = W + 2 * pad, H + 2 * pad

    aligned = []
    for f, (cx, cy) in zip(frames, centroids):
        canvas = Image.new("RGBA", (new_W, new_H), (0, 0, 0, 0))
        ox = int(round(pad + tx - cx))
        oy = int(round(pad + ty - cy))
        canvas.paste(f, (ox, oy), f)
        aligned.append(canvas)
    return aligned, max_shift


def union_crop(frames):
    union = None
    for f in frames:
        bb = f.getbbox()
        if bb is None:
            continue
        if union is None:
            union = list(bb)
        else:
            union[0] = min(union[0], bb[0])
            union[1] = min(union[1], bb[1])
            union[2] = max(union[2], bb[2])
            union[3] = max(union[3], bb[3])
    return [f.crop(tuple(union)) for f in frames]


def process_pose(prefix, action, src_subdir):
    src = SRC_DIR / src_subdir
    paths = sorted(src.glob("frame_*.png"))
    if not paths:
        print(f"[{action}] no frames found in {src}")
        return []
    frames = [Image.open(p).convert("RGBA") for p in paths]

    aligned, shift = centroid_align(frames)
    cropped = union_crop(aligned)
    cw, ch = cropped[0].size
    scale = TARGET_PX / max(cw, ch)
    new_size = (max(1, int(cw * scale)), max(1, int(ch * scale)))

    out_paths = []
    for i, f in enumerate(cropped):
        out = SPRITES / f"{prefix}-{action}-{i}.png"
        f.resize(new_size, Image.LANCZOS).save(out)
        out_paths.append(out)
    print(f"  {action}: {len(frames)}f, max shift={shift:.1f}px, final {new_size[0]}x{new_size[1]}")
    return out_paths


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", required=True, help="Sprite filename prefix (e.g. 'hallocat')")
    ap.add_argument(
        "--pose",
        action="append",
        required=True,
        help="action:src_subdir mapping (e.g. 'run:halloween-cat-running-loop16'). Repeatable.",
    )
    ap.add_argument(
        "--rest",
        help="Existing exported PNG (under Resources/sprites/) to copy as <prefix>-rest.png",
    )
    ap.add_argument(
        "--desaturate-rest",
        action="store_true",
        help="Desaturate the rest frame (RGB → max channel grayscale). Used for rainbow cat where "
             "the static frame would otherwise be alarmingly saturated red.",
    )
    args = ap.parse_args()

    # Clear old prefix-*.png
    for old in SPRITES.glob(f"{args.prefix}-*.png"):
        old.unlink()

    out_paths = []
    for spec in args.pose:
        action, src_subdir = spec.split(":", 1)
        out_paths.extend(process_pose(args.prefix, action, src_subdir))

    if args.rest:
        rest_src = SPRITES / args.rest
        if not rest_src.exists():
            raise SystemExit(f"--rest source not found: {rest_src}")
        rest_out = SPRITES / f"{args.prefix}-rest.png"
        shutil.copy(rest_src, rest_out)
        if args.desaturate_rest:
            im = Image.open(rest_out).convert("RGBA")
            arr = np.array(im).astype(np.float32)
            r, g, b, a = arr[:, :, 0], arr[:, :, 1], arr[:, :, 2], arr[:, :, 3]
            mx = np.maximum(np.maximum(r, g), b)
            out = np.stack([mx, mx, mx, a], axis=-1).astype(np.uint8)
            Image.fromarray(out, "RGBA").save(rest_out)
            print(f"  rest: copy of {args.rest} (desaturated)")
        else:
            print(f"  rest: copy of {args.rest}")
        out_paths.append(rest_out)

    for p in out_paths:
        subprocess.run(["pngquant", "16", "--force", "--output", str(p), str(p)], check=True)
    subprocess.run(
        ["oxipng", "-o", "max", "--quiet"] + [str(p) for p in out_paths], check=True
    )

    total_kb = sum(p.stat().st_size for p in out_paths) / 1024
    print(f"\nTotal: {len(out_paths)} files, {total_kb:.1f} KB")


if __name__ == "__main__":
    main()
