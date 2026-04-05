---
name: review-rules
description: プロジェクトルール（CLAUDE.md / architecture.md）に対する違反をチェックするスキル
---

# Project Rules Review

変更されたファイルおよび関連ファイルがプロジェクトルールに準拠しているかチェックする。

## レビュー手順

1. **変更ファイルの特定**: `git diff --name-only` で変更対象を取得
2. **各ファイルを読み込み**: 変更ファイルの全文を読む
3. **ルール照合**: 以下のルールに対して違反がないか検査する

## チェックルール

### 凝縮度・構造ルール
- [ ] **単一責務**: ファイル内の全パブリックメンバーが同一の責務に属しているか。異なる責務が混在していれば分割を提案する（行数の多寡は問わない）
- [ ] **レイヤー漏洩がないか**: View にデータ加工ロジック、Service に UI 知識が混ざっていないか
- [ ] **命名規則**: View は `*View`、Service は `*Service`、Model はドメイン名
- [ ] **ディレクトリ配置**: Views/ Services/ Models/ の正しい場所にあるか

### 設計ルール
- [ ] **Protocol 駆動**: Service 層に Protocol 定義があるか（新規 Service の場合）
- [ ] **DI はイニシャライザ注入**: グローバル状態やシングルトン直参照がないか
- [ ] **明示的な依存**: 暗黙の依存関係がないか

### コーディング規約
- [ ] **インデント**: タブを使用しているか（スペースインデントは NG）
- [ ] **Swift naming**: PascalCase（型）、camelCase（変数/関数）
- [ ] **デバッグログ**: `NSLog("[Belve] ...")` 形式か

### スレッド・パフォーマンス
- [ ] **メインスレッド保護**: 高頻度パス（PTY データ受信、ターミナル描画コールバック等）で `DispatchQueue.main.sync` を使っていないか。UI 更新は最小限の `.main.async` で行うこと
- [ ] **ホットパス保護**: SwiftTerm 描画パス、PTYService のデータ受信ループにアロケーション、ファイル I/O、文字列フォーマットを入れていないか
- [ ] **フォーカス窃取禁止**: Agent 通知・CLI コマンド・バックグラウンド処理がアプリやペインのフォーカスを奪っていないか。フォーカス変更はユーザーの明示的操作のみ

### 環境汎用性
- [ ] **シェル非依存**: zsh, bash, fish 等の特定シェルに依存していないか。シェル固有の機能を使う場合は全主要シェルに対応するか、フォールバックがあること
- [ ] **OS 非依存（該当する場合）**: macOS 固有の API を使う場合は意図的であること。リモート実行されるスクリプト（hooks, CLI ツール等）は Linux でも動作すること
- [ ] **PATH 非依存**: 特定のインストールパス（`/usr/local/bin`, `~/.npm-global/bin` 等）をハードコードしていないか
- [ ] **環境変数の伝搬**: SSH, Docker, tmux 等の多段接続で環境変数が正しく伝搬されるか。login shell の rc ファイルによる上書きを考慮しているか

### 安全性
- [ ] **OWASP Top 10**: コマンドインジェクション、XSS 等の脆弱性がないか
- [ ] **ハードコードされた秘密情報**: API キー、パスワード等が埋め込まれていないか
- [ ] **エラーハンドリング**: クラッシュしうる force unwrap (`!`) が不必要に使われていないか

### テスト品質
- [ ] **振る舞いテスト**: テストはソースコードのテキスト・メソッドシグネチャ・AST を grep するだけのものではなく、実行時の振る舞いを検証しているか
- [ ] **テストが書かれているか**: 振る舞いが変わる変更にテストが伴っているか。意味のあるテストが書けない場合はその理由を明示すること

### ビルド確認
- [ ] **コンパイル可能**: `swift build` が通るか（実行はしない、構文レベルの確認）
- [ ] **未使用 import**: 不要な import がないか

## 出力フォーマット

```
## Rules Review Result

### Status: PASS / FAIL / WARN

### Violations
- **[STRUCTURE]** FooService.swift — View 描画ロジックと API 通信が混在。API 部分を FooAPIClient に分離すべき
- **[NAMING]** bar_handler.swift:1 — ファイル名が PascalCase でない → BarHandler.swift
- **[DI]** BazView.swift:30 — ServiceLocator.shared 直参照 → イニシャライザ注入に変更
- **[THREAD]** QuxService.swift:42 — PTY コールバック内で DispatchQueue.main.sync → .main.async に変更
- **[FOCUS]** AgentNotificationTransport.swift:55 — 通知受信時に NSApp.activate() → 削除（フォーカス窃取）
- **[SAFETY]** QuxService.swift:55 — force unwrap `data!` → guard let に変更
- **[TEST]** FooService の新規メソッド addBar() にテストがない

### Warnings
- **[CONVENTION]** FooView.swift:12 — スペースインデント検出（タブに統一）
- **[HOTPATH]** TerminalPaneView.swift:88 — 描画コールバック内で String interpolation → 事前計算に変更推奨

### Summary
violations: N, warnings: M
```
