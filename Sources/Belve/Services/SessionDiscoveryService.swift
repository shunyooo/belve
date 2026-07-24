import Foundation

/// discovered セッション = tuple(SessionKey, 粗い導出 status)。
/// `SessionDiscoveryService.discover` の返り値であり、`AgentSessionStore.mergeDiscovered`
/// の入力。SessionKey = tmux セッション名。
typealias DiscoveredSession = (sessionKey: String, coarseStatus: AgentStatus)

/// Belve が起動していない (= OSC hook を張っていない) tmux エージェントセッションを
/// `tmux ls` 発見＋ pane プロセス観測で導出するサービス。
///
/// 新ワークフロー (生 SSH → tmux → claude) では Belve の OSC hook が無く OSC event が
/// 出ない。よって状態はプロセス観測から **導出** する。これは「主経路 (OSC) 失敗 →
/// 旧経路」の fallback ではなく、**独立ソースからの導出**である
/// (`docs/notes/2026-07-23-unified-agent-session.md` §3 "discovered セッション")。
///
/// **重要な制限 (blocked は導出不可)**: OSC hook が無いと、claude が入力待ち
/// (blocked / waiting-for-input) かどうかは信頼できる形で判定できない。pane の
/// foreground プロセスは blocked でも `claude` のままであり、blocked を偽装しない。
/// よって discovered セッションが取り得る status は **`.working` / `.idle` /
/// `.sessionEnd` のみ** (blocked は OSC 経路を持つ `.launched` セッションだけが持てる)。
///
/// DI: command runner を closure で注入する (provider への hard 依存を持たない)。
/// production では `project.provider.run` を配線し、unit test では canned string を返す
/// closure を渡す。parsing は与えられた runner に対して純粋であり、完全に unit-testable。
final class SessionDiscoveryService {
	/// shell コマンドを実行し stdout を返す (非 0 終了 / tmux 未起動などは nil)。
	/// production では `project.provider.run`、test では canned closure。
	var runCommand: (String) -> String?

	init(runCommand: @escaping (String) -> String?) {
		self.runCommand = runCommand
	}

	/// tmux セッションを列挙し、`filterPrefix` に一致するものを discovered セッションとして
	/// 返す。各セッションの pane foreground プロセスを観測して粗い status を導出する。
	///
	/// - Parameters:
	///   - projectId: 呼び出し側が発見結果を紐付ける project (`mergeDiscovered` に渡す)。
	///     parse 自体には使わないが、呼び出しの文脈を明示するため受け取る。
	///   - filterPrefix: このプレフィックスで始まるセッション名だけを対象にする。
	/// - Returns: 発見できなければ空配列 (tmux 未起動 = runner が nil を返すケースを含む)。
	func discover(projectId: UUID, filterPrefix: String = "belve-") -> [DiscoveredSession] {
		guard let raw = runCommand("tmux list-sessions -F '#{session_name}'") else {
			// runner が nil = tmux 未起動 / セッション無し。明示的に「セッション無し」を返す
			// (silent fallback ではなく、単に発見対象が存在しない状態)。
			return []
		}
		let names = raw
			.split(whereSeparator: { $0.isNewline })
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty && $0.hasPrefix(filterPrefix) }

		return names.map { name in
			(sessionKey: name, coarseStatus: coarseStatus(forSession: name))
		}
	}

	/// 指定セッションの pane foreground プロセスを列挙し、粗い status を導出する。
	/// pane のいずれかが `claude` / `node` を走らせていれば `.working`、それ以外 (bare shell)
	/// は `.idle`。blocked は導出しない (上記 class doc の制限を参照)。
	private func coarseStatus(forSession name: String) -> AgentStatus {
		let quoted = Self.shellQuote(name)
		guard let raw = runCommand("tmux list-panes -t \(quoted) -F '#{pane_current_command}'") else {
			// pane 情報が取れない (セッションが直後に消えた等) → bare とみなす。
			return .idle
		}
		let commands = raw
			.split(whereSeparator: { $0.isNewline })
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
		let isWorking = commands.contains { $0 == "claude" || $0 == "node" }
		return isWorking ? .working : .idle
	}

	/// single-quote で安全に囲む (セッション名は任意文字を含み得るので shell injection を防ぐ)。
	private static func shellQuote(_ value: String) -> String {
		"'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}
}
