# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## dock-code とは

VS Code をフォークしたデスクトップアプリ。1つの OS ウィンドウ内で複数プロジェクト（各々が独立した workbench/リモート接続/拡張ホスト）を管理し、即座に切り替えられる。Electron の `WebContentsView` を使い、各プロジェクトは独立した renderer プロセスで動作する。

## ビルドと開発

```bash
# 型チェック（src/ 配下の変更後、必須）
npm run compile-check-ts-native

# 開発用トランスパイル（esbuild ベース、高速）
NODE_OPTIONS="--experimental-strip-types" node build/next/index.ts transpile

# 起動（開発モード）
./scripts/code.sh

# レイヤー依存チェック
npm run valid-layers-check

# ユニットテスト
./scripts/test.sh --grep <pattern>

# 統合テスト
./scripts/test-integration.sh
```

**注意事項:**
- `npm run compile` は使わない（Node 22 で .ts ファイルの直接実行が必要なため失敗する）
- esbuild の transpile-only モードでは `const enum` がインライン展開されない。renderer 側コードでは `import type` を使い、`const enum` の代わりに `enum` を使うこと
- 既存インスタンスが残っていると新規起動が即終了する（single-instance lock）。起動しない場合は既存プロセスを kill し `/tmp/vscode-*` と `1.11-main.sock` を削除

## dock-code 固有のアーキテクチャ

### プロジェクトシステム

```
Single BrowserWindow
├── Main webContents (Project 1 = 最初のプロジェクト)
├── WebContentsView (Project 2 = 独立した renderer)
├── WebContentsView (Project 3 = 独立した renderer)
└── 切り替え: view.setVisible(true/false) + webContents.focus()
```

**プラットフォーム層** (`src/vs/platform/projects/`):
- `common/projects.ts` — `IProjectMainService` インターフェース、`IProject`、`ProjectStatus`
- `electron-main/projectMainService.ts` — WebContentsView の作成・管理・切り替え・フォルダルーティング・復元
- `electron-main/projectIpc.ts` — IPC チャネル
- `common/projectIpcClient.ts` — renderer 側 IPC クライアント

**ワークベンチ層**:
- `workbench/browser/parts/projectbar/projectBarPart.ts` — ProjectBar UI（左サイドバー）
- `workbench/contrib/projects/` — プロジェクト関連コントリビューション
- `workbench/services/projects/electron-browser/` — renderer 側サービス登録

### ProjectBar

`Parts.PROJECTBAR_PART` として登録。折りたたみ(48px)/展開(200px)の2状態を持つ左端の縦バー。プロジェクト一覧・追加・切り替え・右クリックメニュー(リネーム・削除)を提供。

### フォルダオープンのルーティング

WebContentsView プロジェクトからのフォルダオープンは `NativeHostMainService.doOpenPicked()` / `doOpenWindow()` でインターセプトされ、`ProjectMainService.openFolderInProject()` にルーティングされる。`getSingleFolderWorkspaceIdentifier` を呼ぶ際は `fs.statSync` で stat を渡す必要がある（渡さないと workspace が undefined になる）。

### プロジェクト永続化

`projects.json`（`userDataPath` 内）にプロジェクト一覧と activeProjectId を保存。起動時に `afterWindowOpen()` → `restoreProjects()` で WebContentsView を再作成。

### vscode-file:// セキュリティフィルター

`app.ts` の `isAllowedVsCodeFileRequest()` が WebContentsView の `frame.processId` も許可する必要がある。`ProjectMainService.getProjectWebContents()` で全 WebContentsView の webContents を返す。

## VS Code 上流のコーディングガイドライン

### 基本ルール
- インデントはタブ
- PascalCase: 型名、enum 値 / camelCase: 関数、プロパティ、変数
- ユーザー向け文字列は `nls.localize()` でローカライズ、ダブルクォート使用
- それ以外はシングルクォート
- `async/await` を `Promise.then` より優先
- Disposable は作成直後に登録（`DisposableStore`, `MutableDisposable`）
- サービス依存はコンストラクタで宣言、`IInstantiationService` 経由で後から取得しない

### TypeScript
- 型チェックは変更後に必ず実行してからテスト
- `any` / `unknown` は最小限に
- `export` は他コンポーネントと共有する場合のみ
- アロー関数を匿名関数より優先、ただしトップレベルは `export function` を使用

### レイヤー構造
`base` → `platform` → `editor` → `workbench` の順。上位から下位への import は禁止。`npm run valid-layers-check` で検証可能。
