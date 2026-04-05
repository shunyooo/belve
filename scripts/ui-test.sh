#!/bin/bash
# Belve UI 回帰テスト
# Usage:
#   ./scripts/ui-test.sh              # ベースラインと比較
#   ./scripts/ui-test.sh --update     # ベースラインを更新
#   ./scripts/ui-test.sh --check-only # ビルドせず起動中のアプリをチェック
set -e
cd "$(dirname "$0")/.."

BASELINE_DIR="tests/ui-baselines"
SNAPSHOT_DIR="/tmp/belve-ui-test"
UPDATE_MODE=false
CHECK_ONLY=false

for arg in "$@"; do
	case $arg in
		--update) UPDATE_MODE=true ;;
		--check-only) CHECK_ONLY=true ;;
	esac
done

mkdir -p "$SNAPSHOT_DIR"
mkdir -p "$BASELINE_DIR"

# --- Helpers ---

get_window_id() {
	swift -e '
import CoreGraphics
let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
	if let o = w[kCGWindowOwnerName as String] as? String, o == "Belve",
	   let id = w[kCGWindowNumber as String] as? Int {
		print(id); break
	}
}
'
}

capture_window() {
	local name=$1
	local winid
	winid=$(get_window_id)
	if [ -z "$winid" ]; then
		echo "FAIL: Belve window not found"
		return 1
	fi
	screencapture -l"$winid" -x "$SNAPSHOT_DIR/${name}.png"
	echo "Captured: ${name}.png"
}

compare_snapshot() {
	local name=$1
	local baseline="$BASELINE_DIR/${name}.png"
	local snapshot="$SNAPSHOT_DIR/${name}.png"

	if [ ! -f "$baseline" ]; then
		echo "WARN: No baseline for ${name} — skipping comparison"
		return 0
	fi

	if [ ! -f "$snapshot" ]; then
		echo "FAIL: No snapshot for ${name}"
		return 1
	fi

	# sips で画像サイズ比較（ピクセル単位のレイアウト崩れ検出）
	local base_size snap_size
	base_size=$(sips -g pixelWidth -g pixelHeight "$baseline" 2>/dev/null | tail -2 | awk '{print $2}' | tr '\n' 'x')
	snap_size=$(sips -g pixelWidth -g pixelHeight "$snapshot" 2>/dev/null | tail -2 | awk '{print $2}' | tr '\n' 'x')

	if [ "$base_size" != "$snap_size" ]; then
		echo "WARN: Size changed for ${name}: ${base_size} -> ${snap_size}"
	fi

	# ピクセル差分チェック（macOS 標準ツールのみ — ImageMagick 不要）
	# Python で PIL が使えれば差分率を計算、なければサイズ比較のみ
	if python3 -c "from PIL import Image" 2>/dev/null; then
		local diff_pct
		diff_pct=$(python3 - "$baseline" "$snapshot" << 'PYEOF'
import sys
from PIL import Image
img1 = Image.open(sys.argv[1]).convert("RGB")
img2 = Image.open(sys.argv[2]).convert("RGB")
if img1.size != img2.size:
    print("SIZE_MISMATCH")
    sys.exit(0)
px1, px2 = list(img1.getdata()), list(img2.getdata())
diff = sum(1 for a, b in zip(px1, px2) if a != b)
pct = diff / len(px1) * 100
print(f"{pct:.2f}")
PYEOF
)
		if [ "$diff_pct" = "SIZE_MISMATCH" ]; then
			echo "WARN: ${name} — size mismatch, cannot compare pixels"
		elif (( $(echo "$diff_pct > 5.0" | bc -l) )); then
			echo "FAIL: ${name} — ${diff_pct}% pixels differ (threshold: 5%)"
			return 1
		else
			echo "PASS: ${name} — ${diff_pct}% diff"
		fi
	else
		echo "INFO: ${name} — PIL not available, size-only comparison (${base_size})"
	fi
}

check_ui_elements() {
	echo ""
	echo "=== UI Element Checks ==="

	# ウィンドウが存在するか
	local window_count
	window_count=$(osascript -e 'tell app "System Events" to tell process "Belve" to count of windows' 2>/dev/null || echo "0")
	if [ "$window_count" -ge 1 ]; then
		echo "PASS: Window exists (count: ${window_count})"
	else
		echo "FAIL: No Belve window found"
		return 1
	fi

	# UI 要素の列挙を取得
	local elements
	elements=$(osascript -e 'tell app "System Events" to tell process "Belve" to get entire contents of window 1' 2>/dev/null || echo "")

	# サイドバーの存在チェック
	if echo "$elements" | grep -q "group"; then
		echo "PASS: UI groups detected"
	else
		echo "WARN: No UI groups found"
	fi

	# メニューバーの存在チェック
	local menu_count
	menu_count=$(osascript -e 'tell app "System Events" to tell process "Belve" to count of menu items of menu 1 of menu bar 1' 2>/dev/null || echo "0")
	if [ "$menu_count" -ge 1 ]; then
		echo "PASS: Menu bar present (${menu_count} items)"
	else
		echo "WARN: Menu bar check failed"
	fi

	echo ""
}

# --- Main ---

echo "=== Belve UI Regression Test ==="
echo ""

if [ "$CHECK_ONLY" = false ]; then
	# ビルド & 起動
	echo "Building..."
	./scripts/build-app.sh

	echo "Launching Belve.app..."
	kill $(pgrep -f Belve) 2>/dev/null || true
	sleep 1
	open Belve.app
	sleep 3

	# 前面化 & ウィンドウサイズ固定（再現性のため）
	osascript -e 'tell app "System Events" to tell process "Belve" to set frontmost to true'
	osascript -e 'tell app "System Events" to tell process "Belve" to set position of window 1 to {100, 100}'
	osascript -e 'tell app "System Events" to tell process "Belve" to set size of window 1 to {1200, 700}'
	sleep 1
fi

# スナップショット撮影
echo ""
echo "=== Capturing Snapshots ==="
capture_window "main-window"

# UI 要素チェック
check_ui_elements

# ベースライン更新モード
if [ "$UPDATE_MODE" = true ]; then
	echo "=== Updating Baselines ==="
	cp "$SNAPSHOT_DIR"/*.png "$BASELINE_DIR/"
	echo "Baselines updated in ${BASELINE_DIR}/"
	exit 0
fi

# ベースライン比較
echo "=== Comparing with Baselines ==="
FAILURES=0
for snapshot in "$SNAPSHOT_DIR"/*.png; do
	name=$(basename "$snapshot" .png)
	if ! compare_snapshot "$name"; then
		FAILURES=$((FAILURES + 1))
	fi
done

# 結果サマリー
echo ""
echo "=== Summary ==="
if [ "$FAILURES" -gt 0 ]; then
	echo "RESULT: FAIL (${FAILURES} failure(s))"
	echo "Snapshots saved in: ${SNAPSHOT_DIR}/"
	echo "Run with --update to accept current state as new baseline"
	exit 1
else
	echo "RESULT: PASS"
	exit 0
fi
