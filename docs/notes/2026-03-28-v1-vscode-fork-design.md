# dock-code 設計ドキュメント

## 概要

dock-code は、マルチ devcontainer ワークフローと Coding Agent との協業に最適化した VS Code fork。

コアアイデア: **1ウィンドウで複数のプロジェクト（devcontainer）を扱い、それぞれが独立したワークスペース状態を持つ**。

## 背景

現在の IDE は、ウィンドウとリモート接続が 1:1 で紐づいている。複数の devcontainer を同時に扱う場合（マイクロサービスやマルチリポ構成ではよくある）、ウィンドウが乱立し、統一的な俯瞰ができない。

一方、Claude Code のような Coding Agent は開発フローの中心になりつつあるが、IDE 上での扱いはターミナルタブ程度に留まっている。

dock-code が目指すもの:
- 複数の devcontainer を1ウィンドウ内で共存させる
- Coding Agent を第一級市民として扱う専用 UI
- プロジェクト切り替えが tmux のウィンドウ切り替え並みに速い

## コアコンセプト

### Project

**Project** = 1つの作業コンテキスト。以下を持つ:

- devcontainer への接続（複数の Project が同じコンテナを共有可能）
- 独立したペインレイアウト
- 独立した Agent セッション（例: Claude Code の会話）
- 独立したファイル/エディタの状態

Project は左サイドバーにフラットなリストとして表示。階層なし。

```
┌───────────────┬────────────────────────────┐
│ Projects      │                            │
│               │  選択中 Project の           │
│ ● flamel/     │  ペインレイアウト             │
│   コピー言換え │                            │
│ ○ flamel/     │  ┌──────────┬─────────┐   │
│   バグ修正#123│  │ Claude   │ editor  │   │
│ ○ report/     │  │ Code     │         │   │
│   週報        │  │ terminal │         │   │
│               │  ├──────────┴─────────┤   │
│ Status:       │  │ terminal / preview │   │
│ 1 running     │  └────────────────────┘   │
│ 2 idle        │                            │
└───────────────┴────────────────────────────┘
```

### Pane

**Pane** = Project 内の分割領域。以下を配置可能:

- ターミナル（Claude Code 等の Agent を含む）
- コードエディタ
- Markdown プレビュー
- Webview（HTML プレビュー、グラフ等）

Pane は自由に配置可能。ペイン操作のキーボードショートカットは tmux 風。

## ユースケース

### UC1: マルチプロジェクトの俯瞰
3つの devcontainer（flamel, report, polaris）が稼働中。サイドバーから全プロジェクトと各 Agent のステータス（running/idle/error）を一覧で確認できる。プロジェクトをクリックすると、そのプロジェクトのレイアウトに切り替わる。

### UC2: 同一コンテナでの並行タスク
同じコードベースで2つのタスク（機能開発 + バグ修正）を並行作業。同じ devcontainer を指す2つの Project を作成し、それぞれ独立した Claude Code セッション、開いているファイル、ペインレイアウトを持つ。

### UC3: Agent 連携開発
Claude Code がバックグラウンドでファイルを編集。エディタが変更されたファイルを自動的に開いて表示。手動でファイルを開く手間なく、リアルタイムで変更をレビューできる。

### UC4: リッチコンテンツ表示
Agent の出力（Markdown レポート、HTML グラフ、データ可視化）を Webview ペインでコードエディタと並べて表示。ターミナルのみの出力よりリッチな体験。

### UC5: キーボード駆動ワークフロー
プロジェクト切り替え、ペイン移動をすべてキーボードショートカットで操作。tmux のウィンドウ/ペイン操作に近い体験。マウス不要。

## アーキテクチャ: VS Code の変更箇所

### コア変更（fork でのみ可能）

| 領域 | 現在の VS Code | dock-code の目標 |
|------|---------------|-----------------|
| リモート接続 | 1ウィンドウ = 1接続 | 1ウィンドウ = N接続（Project ごと） |
| ワークスペース状態 | ウィンドウに1つ | Project ごとに独立（エディタ、ターミナル、レイアウト） |
| サイドバー | Explorer, Search, Git 等 | Project リストをプライマリナビゲーションとして追加 |

最も重要な変更は **マルチリモート接続のサポート**。VS Code の `RemoteAuthority` は現在ウィンドウスコープ。dock-code ではこれを Project スコープにする必要がある。

### 拡張機能で対応可能（コア変更不要）

| 機能 | 実装方法 |
|------|---------|
| Agent ステータス表示 | ステータスファイル/API を読み取りサイドバーに表示 |
| Agent 編集ファイルの自動表示 | File watcher + エディタ自動オープン |
| tmux 風キーバインド | keybindings 設定 |
| リッチなレポーティング | Webview パネル拡張 |

### 変更不要

- テキストエディタ（Monaco）
- LSP 連携（コンテナごと、既に動作）
- Markdown プレビュー
- Webview API
- 拡張機能エコシステム
- ターミナルエミュレータ

## 開発ロードマップ

### Phase 0: 基盤（現在）
- [x] VS Code を fork
- [x] Linux でビルド成功
- [ ] macOS でビルド・動作確認
- [ ] 最小限のブランディング変更（タイトル: "dock-code"）
- [ ] Agent による upstream マージワークフローの検証

### Phase 1: Project サイドバー
- [ ] Project リストサイドバーの実装
- [ ] Project の CRUD（作成、リネーム、削除）
- [ ] Project 切り替え（ペインレイアウトの保存/復元）
- [ ] Project ごとのターミナルセッション

### Phase 2: マルチ Devcontainer
- [ ] RemoteAuthority を Project スコープにリファクタ
- [ ] Project ごとの LSP 接続
- [ ] Project ごとのファイルエクスプローラースコープ
- [ ] devcontainer の自動検出

### Phase 3: Agent 連携
- [ ] Project リストに Agent ステータス表示
- [ ] Agent が編集したファイルの自動表示
- [ ] Agent 出力用 Webview パネル
- [ ] tmux 風ペインキーバインド

### Phase 4: 仕上げ
- [ ] リッチなレポーティング（グラフ、構造化出力）
- [ ] モバイル対応のリモートアクセス
- [ ] Project テンプレート
- [ ] 再起動時のセッション永続化

## Upstream マージ戦略

dock-code は `microsoft/vscode` の upstream を追跡する。月次で Coding Agent の支援を受けてマージを実施。

方針:
- **コア変更を最小限に**: fork の diff をできるだけ小さく保つ
- **拡張機能を優先**: VS Code API で実現できる機能は拡張として実装
- **変更を分離**: dock-code 固有のコードは明確に分離されたモジュールに配置
- **Agent によるマージ**: upstream 同期時のコンフリクト解消に Claude Code を活用

## 技術スタック

- **ベース**: VS Code (Electron + TypeScript)
- **ビルド**: Node.js 22, npm, gulp
- **ターゲット**: macOS（メイン）, Linux
- **必須**: fnm/nvm（Node バージョン管理）

## 開発の始め方

```bash
# Clone
git clone https://github.com/shunyooo/dock-code.git
cd dock-code

# Node 22
fnm install 22.22.1 && fnm use 22.22.1

# ビルド依存（Linux）
sudo apt-get install -y make g++ pkg-config libx11-dev libxkbfile-dev libsecret-1-dev libkrb5-dev

# インストール & コンパイル
npm install
npm run compile

# 起動（macOS / ディスプレイのある Linux）
./scripts/code.sh

# Watch モード（開発用）
npm run watch
# 別ターミナルで:
./scripts/code.sh
```
