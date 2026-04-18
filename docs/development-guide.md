# Belve Development Guide

UI 自動テスト (ビルド・起動・スクショ・osascript 操作) の手順は [CLAUDE.md](../CLAUDE.md#ui-自動テスト) に集約しているのでそちらを参照。

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
Theme.titlebarHeight       // サイドバー上部行 & メインヘッダーの高さ
Theme.sidebarWidth         // サイドバーの幅
Theme.trafficLightLeading  // トラフィックライトの右端位置
```

複数のビューで同じ値を参照する場合に不整合を防ぐため。

## キーボードショートカット

| ショートカット | 機能 |
|---|---|
| Cmd+Shift+P | コマンドパレット |
| Cmd+P | ファイル検索 |
| Cmd+O | フォルダブラウザ |
| Cmd+S | ファイル保存 |
| Cmd+D | ペイン縦分割 |
| Cmd+Shift+D | ペイン横分割 |
| Cmd+W | ペインを閉じる |
| Cmd+1〜9 | プロジェクト切替 (番号指定) |
| Cmd+[ / Cmd+] | プロジェクト切替 (前後) |
| Cmd+' / Cmd+; | ペインフォーカス前後 |
| Cmd+Shift+\ | セッションバー開閉 |
| Cmd+\ | プロジェクトサイドバー開閉 |
| Cmd+E | エディタ開閉 |
| Cmd+Shift+E | ファイルツリー開閉 |
| Cmd+' (グローバル) | Belve アプリ表示/非表示 |

## Claude Code Hook 連携の既知の制約

### ラッパー (Resources/bin/claude)
- `BELVE_SESSION` 環境変数がない場合はパススルー（Belve 外では無害）
- `BELVE_BIN` は `$(dirname "$0")/belve` で相対解決するため環境依存なし
- `--settings` でインラインに hooks JSON を注入。ユーザーの `~/.claude/settings.json` とは Claude Code 側で自動マージ (配列は concat + dedup、オブジェクトは deep merge) されるので、ユーザー側の hook もそのまま動く

### belve CLI (Resources/bin/belve)
- **`node` 依存**: `notification` hook で stdin JSON をパースするために使用。`node` がなければ `"input needed"` 固定でフォールバック
- **`/tmp/belve-agent-events` ハードコード**: ファイル監視はローカル専用。SSH/DevContainer ではこのファイルに書いても Belve アプリ側で読めない
- **OSC (`/dev/tty`) はリモートでも動く**: SSH/DevContainer では OSC 経由が唯一の通信手段。ファイル監視はローカルのフォールバック

### シェル関数注入

統一ランチャー (`/tmp/belve-shell/belve-launcher.sh`) がシェルを検出して `claude()` 関数を注入:

- **bash**: `export -f claude` — bash はエクスポートされた関数を子プロセスに引き継ぐ
- **zsh**: ZDOTDIR の `.zshrc` で `.zshrc` source 後に関数定義
- **fish**: `--init-command` でインライン関数定義
- **その他**: PATH のみ（関数なし、ラッパーが PATH で見つかれば動く）

**なぜ PATH だけでは不十分か**: nvm, pyenv 等のツールがシェル初期化時に PATH を再構成し、Belve bin より前に自身の bin を配置する。シェル関数は PATH 順序に関係なく優先されるため確実。

### SSH/DevContainer 対応状況
- ローカル: ✅ ファイル監視 + OSC 両方で動作
- SSH / DevContainer: ✅ OSC のみ。ラッパーは `LauncherScriptGenerator` が生成するシェル起動スクリプトが `$HOME/.belve/bin` にデプロイし、`BELVE_PANE_ID` などの環境変数は belve-persist の TCP ハンドシェイクで注入
