# ターミナル描画パフォーマンスの現状と選択肢

**更新**: 2026-04-19
**ステータス**: 保留 (受け入れ + hide UI で当面運用)

## 背景

Belve のターミナルで **Claude Code 等のリッチ TUI** を走らせた状態でウィンドウ/ペインをリサイズすると、「読み込みスクロール」が数百 ms 見えて体感が悪い。

普通の shell (bash/zsh + 短いプロンプト) では発生しない。Terminal.app / iTerm2 / Ghostty で同じ Claude Code を動かしても発生しない。

## 原因

1. SIGWINCH で Claude Code が **フレーム全体を再描画** (Ink / React for CLI)
2. 出力量が 50〜100 KB の ANSI ストリーム (カーソル移動・色変更・ボックス罫線混在)
3. **xterm.js (JavaScript) の ANSI パーサーが律速**

ANSI 解析は仕様上バイト単位のステートマシンが必須。言語による速度差がそのまま効く:

| 実装 | スループット (概算) |
|---|---|
| Terminal.app (C/ObjC) | 10〜30 MB/sec |
| Ghostty (Zig) | 20〜50 MB/sec |
| Alacritty (Rust) | 10〜20 MB/sec |
| **xterm.js (JS)** | **0.5〜1 MB/sec** |

Claude Code の 100 KB ÷ 0.8 MB/sec ≈ 125 ms が xterm.js での実測に近い。

## 現状の対処

`scripts/terminal-entry.js` の `window.terminalSetResizing` でリサイズ中は `.xterm-screen` の `opacity: 0` にして reflow を見せない。完了後に 150 ms fade で戻す。根本解決ではないが体感は大きく改善。

WebGL renderer (`@xterm/addon-webgl`) は入れ済み。ただしレンダリング側の高速化であって、parse 側の律速は残る。

## ネイティブ実装に移行した場合の期待値

| 実装 | 想定スループット | Claude Code リサイズ時 |
|---|---|---|
| xterm.js (現状) | 0.5〜1 MB/sec | ~125 ms |
| Pure Swift パーサー (SwiftTerm 系) | 3〜10 MB/sec | ~15〜30 ms |
| 最適化 Swift (UnsafeBuffer + POD) | 10〜25 MB/sec | ~5 ms |
| GhosttyKit (Zig) | 20〜50 MB/sec | ~3 ms |

## 選択肢

### A. SwiftTerm 採用
- OSS (https://github.com/migueldeicaza/SwiftTerm)
- 工数: 数日〜1 週間
- 純 Swift、メンテ楽
- 速度は中程度だが現状比は 5〜10 倍改善

### B. 自前 Swift + Metal
- フルスクラッチ、工数数週間
- 柔軟性・速度最大
- 過剰投資の可能性

### C. GhosttyKit 組み込み
- 以前検討、Zig ビルド環境の複雑さで断念
- バイナリサイズ増 (xcframework ~500 MB)
- 速度は最強

### D. 受け入れ (現状)
- hide で UX を補正
- Claude Code 側の改善 (Anthropic 依存) を待つ
- 工数 0

## 決定

**保留 (D)**。当面は hide + WebGL で運用。リサイズ体感が耐えられない or ネイティブ感を追求したくなったら A から再検討。

## 関連

- `scripts/terminal-entry.js` — xterm.js 設定 + WebGL addon + resize hide
- `Sources/Belve/Terminal/XTermTerminalView.swift` — Swift 側の resize フロー
