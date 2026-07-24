import Foundation

/// 統合エージェントセッション実体 (cockpit) の型群。
///
/// `docs/notes/2026-07-23-unified-agent-session.md` の契約に基づくカノニカルモデル。
/// 旧 `NotificationStore` が持っていた legacy 型は撤去済みで、ここが唯一の定義。

/// セッション状態。cockpit 語彙 (working/blocked/done/idle) をカノニカルとし、
/// 旧 hook 語彙 (running/waiting/completed/…) も受理する。
enum AgentStatus: String, Codable, Equatable {
	case idle
	case sessionStart
	case working
	case blocked
	case done
	case sessionEnd
	case runningSubagent

	/// カノニカル rawValue に加えて **legacy hook 文字列**も受理する。
	/// OSC 経路 (hook が旧語彙を出す) の parse を壊さないため。
	init?(rawValue: String) {
		if let s = AgentStatus.canonical(rawValue) {
			self = s
		} else if let s = AgentStatus.from(hookStatus: rawValue) {
			self = s
		} else {
			return nil
		}
	}

	private static func canonical(_ raw: String) -> AgentStatus? {
		switch raw {
		case "idle": return .idle
		case "sessionStart": return .sessionStart
		case "working": return .working
		case "blocked": return .blocked
		case "done": return .done
		case "sessionEnd": return .sessionEnd
		case "runningSubagent": return .runningSubagent
		default: return nil
		}
	}

	/// 旧 hook 語彙 → cockpit 語彙。
	static func from(hookStatus: String) -> AgentStatus? {
		switch hookStatus {
		case "running": return .working
		case "waiting": return .blocked
		case "completed": return .done
		case "session_start": return .sessionStart
		case "session_end": return .sessionEnd
		case "running_subagent": return .runningSubagent
		case "idle": return .idle
		default: return nil
		}
	}
}

/// セッションの可変状態。
struct AgentState: Codable, Equatable {
	var status: AgentStatus
	var message: String
	var lastActivity: String?
	var currentTool: String?
	var lastUserPrompt: String?
	var subagentCount: Int

	init(
		status: AgentStatus = .idle,
		message: String = "",
		lastActivity: String? = nil,
		currentTool: String? = nil,
		lastUserPrompt: String? = nil,
		subagentCount: Int = 0
	) {
		self.status = status
		self.message = message
		self.lastActivity = lastActivity
		self.currentTool = currentTool
		self.lastUserPrompt = lastUserPrompt
		self.subagentCount = subagentCount
	}
}

/// セッションの発生源。`.launched` = Belve 起動、`.discovered` = 素の tmux 発見。
enum SessionOrigin: Codable, Equatable {
	case launched
	case discovered
}

/// 永続・一級のセッション実体。identity は SessionKey (= tmux セッション名) のみ。
struct AgentSession: Identifiable, Codable, Equatable {
	/// SessionKey = 実際の tmux セッション名。唯一の識別軸 (UUID ではなく String)。
	let id: String
	let projectId: UUID
	var name: String
	var state: AgentState
	var origin: SessionOrigin
	let startedAt: Date
	var updatedAt: Date
	var isArchived: Bool = false

	init(
		id: String,
		projectId: UUID,
		name: String = "",
		state: AgentState = AgentState(),
		origin: SessionOrigin = .launched,
		startedAt: Date = Date(),
		updatedAt: Date = Date(),
		isArchived: Bool = false
	) {
		self.id = id
		self.projectId = projectId
		self.name = name
		self.state = state
		self.origin = origin
		self.startedAt = startedAt
		self.updatedAt = updatedAt
		self.isArchived = isArchived
	}
}
