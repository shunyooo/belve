import Foundation

/// git worktree 1 件分。`git worktree list --porcelain` の 1 レコードに対応する。
struct Worktree: Identifiable, Equatable {
	/// worktree の絶対パス (git が返す値をそのまま保持)。SessionKey 同様の一意識別子。
	let path: String
	/// チェックアウト中のブランチ名 (refs/heads/ を除いたもの)。detached / bare なら nil。
	let branch: String?
	/// HEAD の commit sha (短縮せず生値)。取れなければ nil。
	let head: String?
	/// リスト先頭 = メインの作業ツリー。タブでは「main」として扱い、選択時は
	/// selectedWorktreePath を nil に戻す (= project.effectivePath の正規経路)。
	let isMain: Bool
	/// パスが `/.claude/worktrees/` 配下 = Claude Code が作った worktree。タブでマークする。
	let isClaudeCreated: Bool
	let isDetached: Bool
	let isBare: Bool
	let isLocked: Bool

	var id: String { path }

	/// タブ表示ラベル。ブランチ名優先、detached/bare 等でブランチが無ければパス末尾。
	var displayLabel: String {
		if let branch, !branch.isEmpty { return branch }
		if isBare { return "(bare)" }
		let comps = path.split(separator: "/").map(String.init)
		if comps.count >= 2 { return comps.suffix(2).joined(separator: "/") }
		return comps.last ?? path
	}
}

/// `git worktree list --porcelain` を実行・parse して `Worktree` 一覧を返すサービス。
///
/// DI: command runner を closure で注入する (`SessionDiscoveryService` と同じ設計)。
/// production では `project.provider.run` を配線し、unit test では canned string を返す
/// closure を渡す。parse は純粋・完全に unit-testable。
///
/// **昇集方針**: worktree はエフェメラル (Claude が作る/消す) なので polling せず、
/// preview の appear / project 切替 / 明示リフレッシュ時にだけ列挙する (SSH の
/// executeSSH は 3 スロット semaphore なので周期実行は避ける)。
final class WorktreeService {
	/// shell コマンドを実行し stdout を返す (非 0 終了 / git 無しなどは nil)。
	var runCommand: (String) -> String?

	init(runCommand: @escaping (String) -> String?) {
		self.runCommand = runCommand
	}

	/// `effectivePath` を repo root として worktree 一覧を返す。
	/// runner が nil (= git 未導入 / repo でない / 接続前) の時は空配列。
	/// silent fallback ではなく「列挙対象なし」を明示的に空で返す。
	func list(effectivePath: String) -> [Worktree] {
		let quoted = Self.shellQuote(effectivePath)
		guard let raw = runCommand("git -C \(quoted) worktree list --porcelain 2>/dev/null") else {
			return []
		}
		return Self.parse(raw)
	}

	/// `--porcelain` 出力を parse する純粋関数 (unit-test 面)。
	/// レコードは空行区切り。`worktree <abs>` / `HEAD <sha>` / `branch refs/heads/<name>` /
	/// 単独行 `detached` `bare` `locked` `prunable` を解釈する。先頭レコード = main。
	static func parse(_ porcelain: String) -> [Worktree] {
		var out: [Worktree] = []
		// 現在組み立て中のレコード。
		var path: String?
		var branch: String?
		var head: String?
		var detached = false
		var bare = false
		var locked = false

		func flush() {
			guard let p = path else { return }
			out.append(Worktree(
				path: p,
				branch: branch,
				head: head,
				isMain: out.isEmpty,
				isClaudeCreated: p.contains("/.claude/worktrees/"),
				isDetached: detached,
				isBare: bare,
				isLocked: locked
			))
			path = nil; branch = nil; head = nil
			detached = false; bare = false; locked = false
		}

		for rawLine in porcelain.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
			let line = String(rawLine)
			if line.isEmpty { continue }
			if let value = Self.field(line, "worktree ") {
				// 新レコード開始。直前のを確定してから始める。
				flush()
				path = value
			} else if let value = Self.field(line, "branch ") {
				branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
			} else if let value = Self.field(line, "HEAD ") {
				head = value
			} else if line == "detached" {
				detached = true
			} else if line == "bare" {
				bare = true
			} else if line == "locked" || line.hasPrefix("locked ") {
				locked = true
			}
			// prunable 等その他行は無視。
		}
		flush()
		return out
	}

	/// `prefix` で始まる行から prefix を除いた残りを返す (前後空白 trim)。不一致なら nil。
	private static func field(_ line: String, _ prefix: String) -> String? {
		guard line.hasPrefix(prefix) else { return nil }
		return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
	}

	/// single-quote で安全に囲む (パスに空白等が含まれても壊れないように)。
	private static func shellQuote(_ value: String) -> String {
		"'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}
}
