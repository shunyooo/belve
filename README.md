# Belve

macOS ネイティブ (Swift / SwiftUI) のマルチプロジェクト開発環境。
複数のプロジェクトを 1 ウィンドウで束ね、SSH / DevContainer / ローカルを横断して、**ターミナル・エディタ・ファイルツリー・Markdown WYSIWYG** を 1 つのアプリで扱います。

## 特徴

- **マルチプロジェクト**: サイドバーで複数プロジェクトを切り替え、各プロジェクトに独立した状態 (ターミナル、エディタ、ファイルツリー) を保持
- **リモート接続**: SSH ホスト / DevContainer / ローカルを同じ UI で扱う。SSH は ControlMaster + port forward で単一セッションに多重化 (sshd `MaxSessions` を消費しない)
- **セッション永続化**: `belve-persist` (Go) がリモート側で PTY を保持。アプリ再起動・再接続でターミナルセッションを復元
- **ターミナル**: xterm.js (WKWebView) による高速描画、ANSI カラー、リンク検出、ペイン分割
- **コードエディタ**: CodeMirror 6 (WKWebView) による軽量エディタ、シンタックスハイライト、diff gutter、ファイル検索
- **Markdown WYSIWYG**: Milkdown Crepe による `.md` の直感編集
- **エージェントセッション監視**: Claude Code / Codex の hook を全イベント捕捉、サイドバーでリアルタイム表示
- **ネイティブ**: Electron なし、1 ウィンドウ / 1 プロセス。macOS 14+ 専用

## ビルド

```bash
# 依存 (初回のみ)
npm install

# .app ビルド
./scripts/build-app.sh

# 起動 (必ず .app 経由 — 生バイナリは macOS がアプリとして認識しない)
open Belve.app
```

クリーンビルドが必要な場合:

```bash
swift package clean && ./scripts/build-app.sh
```

## ドキュメント

- [CLAUDE.md](CLAUDE.md) — プロジェクトガイド (ビルド / テスト / 規約)
- [docs/architecture.md](docs/architecture.md) — アーキテクチャ設計
- [docs/DESIGN.md](docs/DESIGN.md) — デザイン方針
- [docs/development-guide.md](docs/development-guide.md) — 開発ガイド

## 技術スタック

- SwiftUI (macOS 14+)
- xterm.js / CodeMirror 6 / Milkdown (WKWebView)
- Go (belve-persist — dtach ライクな PTY 永続化)
- system `ssh` + `devcontainer` CLI

## バージョン

- **v1.x** — VS Code fork (Electron) 時代のアーカイブ
- **v2.0+** — 現在の Swift ネイティブ実装 (ゼロから書き直し)

## License

See [LICENSE](LICENSE).
