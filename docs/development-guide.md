# Belve Development Guide

## UI スクショ確認

### ウィンドウ単体キャプチャ

他アプリが映り込まない方法:

```bash
WINID=$(swift -e '
import CoreGraphics
let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
for w in list { if let o = w[kCGWindowOwnerName as String] as? String, o == "Belve", let id = w[kCGWindowNumber as String] as? Int { print(id); break } }
')
screencapture -l$WINID -x /tmp/belve-win.png
```

### 部分クロップ

Swift の NSImage で左上 NxM px を切り出し:

```bash
swift -e '
import AppKit
guard let img = NSImage(contentsOfFile: "/tmp/belve-win.png") else { exit(1) }
let rep = img.representations.first!
let w = 600; let h = 200
let cropRect = NSRect(x: 0, y: rep.pixelsHigh - h, width: w, height: h)
let bitmapRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
img.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: cropRect, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
try! bitmapRep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/belve-crop.png"))
'
```

### 注意

- `screencapture -x` は全画面キャプチャ → 他アプリが映る。使わない
- `screencapture -R` は画面座標 → 他アプリが映る。使わない
- `screencapture -l$WINID` でウィンドウ単体
- NSImage の座標は左下原点。クロップ時 `y: pixelsHigh - h` で上端を指定
- Retina ディスプレイなので画像サイズは論理サイズの2倍

## 開発ワークフロー

### クリーンアップの流れ

実装の区切りごとに無駄実装のクリーンアップを行う。

```
機能実装 → 動作確認 → コミット → クリーンアップ → コミット
```

チェック項目:
1. 使われていない import / ファイル / 関数
2. デバッグ用の NSLog（必要なもの以外）
3. コメントアウトされたコード
4. 探索で試して使わなかったアプローチの残骸
5. TODO コメントで完了済みのもの
6. ハードコードされたテスト値（テスト用パス等）

### レイアウト定数

依存関係のあるレイアウト値は `Theme.swift` に定数として定義する。ハードコードしない。

```swift
Theme.titlebarHeight   // サイドバー上部行 & メインヘッダーの高さ
Theme.sidebarWidth     // サイドバーの幅
Theme.trafficLightLeading  // トラフィックライトの右端位置
```

複数のビューで同じ値を参照する場合に不整合を防ぐため。

## キーボードショートカット

| ショートカット | 機能 |
|---|---|
| Cmd+Shift+P | コマンドパレット |
| Cmd+O | フォルダブラウザ |
| Cmd+S | ファイル保存 |
| Cmd+D | ペイン縦分割 |
| Cmd+Shift+D | ペイン横分割 |
| Cmd+1-9 | プロジェクト切替 |
| Cmd+' | アプリ表示/非表示（グローバル） |

## Claude Code Hook 連携の既知の制約

### ラッパー (Resources/bin/claude)
- `BELVE_SESSION` 環境変数がない場合はパススルー（Belve 外では無害）
- `BELVE_BIN` は `$(dirname "$0")/belve` で相対解決するため環境依存なし
- `--settings` でインラインに hooks JSON を注入。ユーザーの `~/.claude/settings.json` には触らない

### belve CLI (Resources/bin/belve)
- **`node` 依存**: `notification` hook で stdin JSON をパースするために使用。`node` がなければ `"input needed"` 固定でフォールバック
- **`/tmp/belve-agent-events` ハードコード**: ファイル監視はローカル専用。SSH/DevContainer ではこのファイルに書いても Belve アプリ側で読めない
- **OSC (`/dev/tty`) はリモートでも動く**: SSH/DevContainer では OSC 経由が唯一の通信手段。ファイル監視はローカルのフォールバック

### シェル関数注入
統一ランチャー (`/tmp/belve-shell/belve-launcher.sh`) がシェルを検出して適切に `claude()` 関数を注入:
- **bash**: `export -f claude` — bash はエクスポートされた関数を子プロセスに引き継ぐ
- **zsh**: ZDOTDIR の `.zshrc` で `.zshrc` source 後に関数定義
- **fish**: `--init-command` でインライン関数定義
- **その他**: PATH のみ（関数なし、ラッパーが PATH で見つかれば動く）

**なぜ PATH だけでは不十分か**: nvm, pyenv 等のツールがシェル初期化時に PATH を再構成し、Belve bin より前に自身の bin を配置する。シェル関数は PATH 順序に関係なく優先されるため確実。

### SSH/DevContainer 対応状況
- ローカル: ✅ ファイル監視 + OSC 両方で動作
- SSH: ⚠️ OSC のみ。`BelveRemoteInstaller` でラッパーをデプロイ + `sendRemoteBelveEnv` で環境変数注入が必要（SwiftTerm ベースの TerminalPaneView でのみ実装済み。Ghostty ベースでは未対応）
- DevContainer: ⚠️ 同上
