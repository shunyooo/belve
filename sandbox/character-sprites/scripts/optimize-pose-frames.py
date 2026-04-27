"""Optimize per-pose frame sequences:
1. Detect minimum loop period
2. Extract loop frames
3. Crop to union bbox + small pad
4. Downscale to TARGET_PX on long side
5. Quantize to 16 colors (pngquant) + recompress (oxipng)

Output:
  source-videos/<pose>-loop16/frame_NNN.png  ← final 16-color optimized sequence
  Prints loop period & sizes.
"""
import subprocess
import sys
from pathlib import Path
from PIL import Image
import numpy as np

REPO = Path(__file__).resolve().parents[3]
SRC_DIR = REPO / "sandbox/character-sprites/source"
TARGET_PX = 240
PAD = 8


def mse(a, b):
    return float(np.mean((a.astype(np.float32) - b.astype(np.float32)) ** 2))


def detect_loop_period(frames):
    """Find shortest natural loop sub-period.

    Strategy: find all local minima in the per-period MSE curve, then return the smallest P
    whose MSE is within 20x the global min (i.e., a clear dip, not random noise). This favors
    the natural walking/running sub-cycle over the trivially-perfect full-length loop.
    """
    N = len(frames)
    candidates = []
    for P in range(2, N):
        diffs = [mse(frames[i], frames[i + P]) for i in range(N - P)]
        avg = sum(diffs) / len(diffs)
        candidates.append((P, avg))

    avgs = [c[1] for c in candidates]
    global_min = min(avgs)
    median = sorted(avgs)[len(avgs) // 2]
    # A real sub-cycle should be both: clearly better than the noise floor (≪ median)
    # and within ~20× the global perfect loop. Take the stricter of the two.
    threshold = min(global_min * 20, median / 5)

    # Find local minima: avg strictly < both neighbors AND below threshold
    for i in range(1, len(candidates) - 1):
        P, avg = candidates[i]
        if avg < candidates[i - 1][1] and avg < candidates[i + 1][1] and avg < threshold:
            return P, avg, candidates

    # Fallback: global min (no clean sub-cycle)
    best = min(candidates, key=lambda c: c[1])
    return best[0], best[1], candidates


def union_bbox(frames):
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
    return tuple(union)


def process_pose(pose_name):
    # Auto-detect prefix: try halloween-cat-<name> first, then bare <name>
    if (SRC_DIR / f"halloween-cat-{pose_name}-frames").exists():
        src = SRC_DIR / f"halloween-cat-{pose_name}-frames"
        out = SRC_DIR / f"halloween-cat-{pose_name}-loop16"
    else:
        src = SRC_DIR / f"{pose_name}-frames"
        out = SRC_DIR / f"{pose_name}-loop16"
    out.mkdir(exist_ok=True)
    for old in out.glob("*.png"):
        old.unlink()

    paths = sorted(src.glob("frame_*.png"))
    if not paths:
        print(f"[{pose_name}] no frames found in {src}")
        return
    print(f"[{pose_name}] loaded {len(paths)} frames from {src.name}")

    arrs = [np.array(Image.open(p)) for p in paths]
    period, score, _ = detect_loop_period(arrs)
    print(f"[{pose_name}] loop period: P={period} (avg MSE={score:.1f})")

    # Take first `period` frames
    frames = [Image.open(p) for p in paths[:period]]
    bbox = union_bbox(frames)
    W, H = frames[0].size
    x0, y0, x1, y1 = bbox
    x0 = max(0, x0 - PAD)
    y0 = max(0, y0 - PAD)
    x1 = min(W, x1 + PAD)
    y1 = min(H, y1 + PAD)
    crop = (x0, y0, x1, y1)
    cw, ch = x1 - x0, y1 - y0
    scale = TARGET_PX / max(cw, ch)
    new_size = (int(cw * scale), int(ch * scale))
    print(f"[{pose_name}] crop {cw}x{ch} → resize {new_size[0]}x{new_size[1]}")

    # write resized PNGs
    tmp_dir = out.with_name(out.name + "-tmp")
    tmp_dir.mkdir(exist_ok=True)
    for old in tmp_dir.glob("*.png"):
        old.unlink()
    for i, f in enumerate(frames, 1):
        cropped = f.crop(crop).resize(new_size, Image.LANCZOS)
        cropped.save(tmp_dir / f"frame_{i:03d}.png")

    # pngquant 16 colors → out, then oxipng
    for src_png in sorted(tmp_dir.glob("*.png")):
        dst_png = out / src_png.name
        subprocess.run(
            ["pngquant", "16", "--force", "--output", str(dst_png), str(src_png)],
            check=True,
        )
    subprocess.run(
        ["oxipng", "-o", "max", "--quiet"] + [str(p) for p in sorted(out.glob("*.png"))],
        check=True,
    )
    # cleanup tmp
    for p in tmp_dir.glob("*.png"):
        p.unlink()
    tmp_dir.rmdir()

    total = sum(p.stat().st_size for p in out.glob("*.png"))
    print(f"[{pose_name}] final: {len(list(out.glob('*.png')))} PNGs, {total/1024:.1f} KB total → {out}")


def main():
    poses = sys.argv[1:] or ["walking", "running"]
    for p in poses:
        process_pose(p)
        print()


if __name__ == "__main__":
    main()
