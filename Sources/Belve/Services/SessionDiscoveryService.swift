import Foundation

/// discovered セッション = tuple(SessionKey, 粗い導出 status)。
/// `SessionDiscoveryService.discover` の返り値であり、`AgentSessionStore.mergeDiscovered`
/// の入力。SessionKey = tmux セッション名。
typealias DiscoveredSession = (sessionKey: String, coarseStatus: AgentStatus, message: String)

/// Belve が起動していない (= OSC hook を張っていない) tmux セッションのうち、
/// **agent ツールが検出されたもの** を `tmux ls` 発見＋ pane プロセス観測で導出するサービス。
///
/// 新ワークフロー (生 SSH → tmux → claude) では Belve の OSC hook が無く OSC event が
/// 出ない。よって状態はプロセス観測から **導出** する。これは「主経路 (OSC) 失敗 →
/// 旧経路」の fallback ではなく、**独立ソースからの導出**である
/// (`docs/notes/2026-07-23-unified-agent-session.md` §3 "discovered セッション")。
///
/// **昇格ゲート (§8.2)**: tmux セッション/pane が存在するだけでは session ではない。
/// 素の端末は端末のまま。`agentCommands` のいずれかが pane の foreground プロセスとして
/// 走っている時に初めて `AgentSession` として surface する。これは Claude 専用だった OSC
/// 経路 (belve hook は Claude が走った時だけ発火) の agent-gated 表示を discovery にも揃え、
/// マルチ agent に拡張したもの。補助 shell だけの idle セッションは **一切返さない**。
///
/// **重要な制限 (blocked は導出不可)**: OSC hook が無いと、agent が入力待ち
/// (blocked / waiting-for-input) かどうかは信頼できる形で判定できない。pane の
/// foreground プロセスは blocked でも agent コマンド名のままであり、blocked を偽装しない。
/// よって discovered セッションが surface された時点の status は **常に `.working`**
/// (agent が現在走っている)。その後 agent が終了して pane が shell に戻ると discover() の
/// 結果から落ち、`mergeDiscovered` が `.sessionEnd` にする (blocked は OSC 経路を持つ
/// `.launched` セッションだけが持てる)。
///
/// **検出方式の限界 (要実機検証)**: 検出は pane の foreground `#{pane_current_command}`
/// の **コマンド名** による。ある環境が Claude/Codex を `node`/`python` 等のラッパー配下で
/// 起動していて foreground のコマンド名が `agentCommands` に含まれない場合、その名前を
/// `agentCommands` に追加する (あるいは pane pid を辿って argv を検査する follow-up を実装する)
/// まで検出漏れする。このサンドボックスでは実 tmux/VM を用意できないため、実機 (tmux/VM) での
/// 検証が別途必要。
///
/// DI: command runner を closure で注入する (provider への hard 依存を持たない)。
/// production では `project.provider.run` を配線し、unit test では canned string を返す
/// closure を渡す。parsing は与えられた runner に対して純粋であり、完全に unit-testable。
final class SessionDiscoveryService {
	/// 昇格ゲートに使う agent CLI コマンド名の集合。
	/// pane の `#{pane_current_command}` と完全一致で照合する。
	/// **拡張ポイント**: 新しい agent CLI が現れたらここに名前を足すだけで surface 対象になる。
	/// 注意: `node` / `python` のような汎用ランタイム名は入れない (任意の Node/Python プロセスに
	/// マッチして誤検出するため)。ラッパー配下で名前が化ける環境は上記 class doc の
	/// 「検出方式の限界」を参照。
	static let agentCommands: Set<String> = ["claude", "codex"]

	/// shell コマンドを実行し stdout を返す (非 0 終了 / tmux 未起動などは nil)。
	/// production では `project.provider.run`、test では canned closure。
	var runCommand: (String) -> String?

	init(runCommand: @escaping (String) -> String?) {
		self.runCommand = runCommand
	}

	/// tmux セッションを列挙し、`filterPrefix` に一致し **かつ agent ツールが検出されたもの**
	/// だけを discovered セッションとして返す。各セッションの pane foreground プロセスを観測し、
	/// `agentCommands` のいずれかが走っていなければそのセッションは **返さない**。
	///
	/// - Parameters:
	///   - projectId: 呼び出し側が発見結果を紐付ける project (`mergeDiscovered` に渡す)。
	///     parse 自体には使わないが、呼び出しの文脈を明示するため受け取る。
	///   - filterPrefix: このプレフィックスで始まるセッション名だけを対象にする。
	/// - Returns: 発見できなければ空配列 (tmux 未起動 = runner が nil を返すケース、および
	///   prefix 一致セッションが全て bare shell で agent 未検出のケースを含む)。返される各
	///   エントリの coarseStatus は常に `.working`。
	func discover(projectId: UUID, filterPrefix: String = "belve-") -> [DiscoveredSession] {
		// 1 回の list-sessions で名前 + belve フックが書いた状態 (@belve_state / @belve_msg)
		// を取る。フックが状態を書いていれば **名前を問わず** agent セッションとして surface
		// し、fine な状態を反映する (clay-seto 等の非 belve- 名も拾える)。フック未装着でも
		// belve- セッションで agent プロセスが走っていれば従来どおり粗く .working で surface。
		guard let raw = runCommand("tmux list-sessions -F '#{session_name}\t#{@belve_state}\t#{@belve_msg}'") else {
			// runner が nil = tmux 未起動 / セッション無し。明示的に「セッション無し」を返す
			// (silent fallback ではなく、単に発見対象が存在しない状態)。
			return []
		}
		var out: [DiscoveredSession] = []
		for line in raw.split(whereSeparator: { $0.isNewline }) {
			let parts = String(line).components(separatedBy: "\t")
			let name = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
			guard !name.isEmpty else { continue }
			let belveState = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
			let belveMsg = parts.count > 2 ? parts[2] : ""
			if !belveState.isEmpty {
				// フックが状態を書いている = agent セッション (昇格ゲート成立)。
				let status = AgentStatus(rawValue: belveState) ?? .working
				out.append((sessionKey: name, coarseStatus: status, message: belveMsg))
			} else if name.hasPrefix(filterPrefix), hasAgent(inSession: name) {
				// フック未装着だが agent プロセスが走る belve- セッション → 粗く working。
				out.append((sessionKey: name, coarseStatus: .working, message: ""))
			}
		}
		return out
	}

	/// 指定セッションの pane foreground プロセスを列挙し、いずれかが `agentCommands` に
	/// 含まれるか判定する。agent が走っていれば true (= surface 対象・`.working`)、
	/// bare shell だけなら false (= surface しない)。
	private func hasAgent(inSession name: String) -> Bool {
		let quoted = Self.shellQuote(name)
		guard let raw = runCommand("tmux list-panes -t \(quoted) -F '#{pane_current_command}'") else {
			// pane 情報が取れない (セッションが直後に消えた等) → agent 未検出扱い。
			return false
		}
		let commands = raw
			.split(whereSeparator: { $0.isNewline })
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
		return commands.contains { Self.agentCommands.contains($0) }
	}

	/// single-quote で安全に囲む (セッション名は任意文字を含み得るので shell injection を防ぐ)。
	private static func shellQuote(_ value: String) -> String {
		"'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}
}
