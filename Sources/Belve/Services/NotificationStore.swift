import Foundation
import UserNotifications

enum AgentStatus: String, Codable {
	case idle
	case sessionStart = "session_start"
	case running
	case runningSubagent = "running_subagent"  // 親 claude が subagent 完了待ち
	case waiting
	case completed
	case sessionEnd = "session_end"
}

struct AgentState {
	var status: AgentStatus
	var message: String
}

/// One record per agent session. Status updates in-place.
struct AgentSession: Identifiable, Codable {
	let id: UUID
	let projectId: UUID
	var paneId: String?
	var status: AgentStatus
	var message: String
	var label: String?
	var lastUserPrompt: String?
	var lastAgentActivity: String?
	var currentTool: String?
	/// 走ってる subagent (Task tool) の数。0 < count なら表示上 .runningSubagent 優先。
	/// session.status とは独立に管理し、subagent 終了時に親 status に戻る。
	var subagentCount: Int = 0
	let startedAt: Date
	var updatedAt: Date
	var isRead: Bool = false
	var isArchived: Bool = false

	init(projectId: UUID, paneId: String? = nil, status: AgentStatus, message: String, startedAt: Date = Date(), updatedAt: Date = Date()) {
		self.id = UUID()
		self.projectId = projectId
		self.paneId = paneId
		self.status = status
		self.message = message
		self.startedAt = startedAt
		self.updatedAt = updatedAt
	}
}

class NotificationStore: ObservableObject {
	@Published var sessions: [AgentSession] = []
	@Published var agentStatus: [UUID: AgentState] = [:] // keyed by projectId

	// Mapping: paneId → projectId
	var paneToProject: [String: UUID] = [:]
	// Active session index per pane (for in-place updates)
	private var activeSessionIndex: [String: Int] = [:]  // keyed by paneId

	func registerPane(paneId: String, projectId: UUID) {
		paneToProject[paneId] = projectId
	}

	/// Latest non-archived session for a pane. UI が pane 単位の status / activity を
	/// 表示する時に使う (project-keyed `agentStatus` だと pane 間で混ざるため)。
	func currentSession(forPaneId paneId: String) -> AgentSession? {
		sessions
			.filter { $0.paneId == paneId && !$0.isArchived }
			.max(by: { $0.updatedAt < $1.updatedAt })
	}

	func updateAgentStatus(paneId: String, status: String, message: String) {
		guard let projectId = paneToProject[paneId],
			  let agentStatus = AgentStatus(rawValue: status) else { return }

		self.agentStatus[projectId] = AgentState(status: agentStatus, message: message)
		NSLog("[Belve] Agent status: %@ - %@ (pane: %@)", status, message, paneId)

		switch agentStatus {
		case .sessionStart:
			// Remove existing session for same pane (reload case)
			if let existingIdx = sessions.firstIndex(where: { $0.paneId == paneId }) {
				sessions.remove(at: existingIdx)
				// Fix active indices after removal
				for (key, idx) in activeSessionIndex {
					if idx > existingIdx { activeSessionIndex[key] = idx - 1 }
					else if idx == existingIdx { activeSessionIndex.removeValue(forKey: key) }
				}
			}
			// New session record
			let session = AgentSession(
				projectId: projectId,
				paneId: paneId,
				status: .sessionStart,
				message: message,
				startedAt: Date(),
				updatedAt: Date()
			)
			sessions.insert(session, at: 0)
			activeSessionIndex[paneId] = 0
			// Shift other indices
			for (key, idx) in activeSessionIndex where key != paneId {
				activeSessionIndex[key] = idx + 1
			}
			saveSessions()

		case .running:
			updateActiveSession(paneId: paneId) { session in
				// Subagent events describe child-agent lifecycle. They must not
				// drive the parent session's status — otherwise a stray
				// SubagentStop can flip a .waiting / .completed pane back to
				// .running and leave it stuck (no follow-up Stop hook arrives).
				let isSubagentEvent = message.hasPrefix("subagent:") || message.hasPrefix("subagent-done:")
				if !isSubagentEvent {
					session.status = .running
					session.message = message
				}
				// Capture first prompt as label
				if session.label == nil && !message.hasPrefix("tool:") && !message.hasPrefix("result:") && !message.hasPrefix("subagent") && message != "Generating" {
					session.label = message
				}
				// Parse structured messages
				if message.hasPrefix("tool:") {
					let detail = String(message.dropFirst(5))
					let parts = detail.split(separator: ":", maxSplits: 1)
					session.currentTool = String(parts.first ?? "")
					session.lastAgentActivity = parts.count > 1 ? String(parts[1]) : nil
				} else if message.hasPrefix("result:") {
					let detail = String(message.dropFirst(7))
					let parts = detail.split(separator: ":", maxSplits: 1)
					session.lastAgentActivity = parts.count > 1 ? String(parts[1]).prefix(80).description : "done"
					// Keep currentTool visible until next tool or completion
				} else if message.hasPrefix("subagent:") {
					session.currentTool = "Agent"
					session.lastAgentActivity = String(message.dropFirst(9))
					session.subagentCount += 1
				} else if message.hasPrefix("subagent-done:") {
					session.subagentCount = max(0, session.subagentCount - 1)
					// Only clear tool if the parent session is actively running.
					// Otherwise leave prior terminal state intact.
					if session.status == .running || session.status == .sessionStart {
						session.currentTool = nil
					}
				} else if message != "Generating" {
					session.lastUserPrompt = message
					session.currentTool = nil
					session.lastAgentActivity = nil
				}
			}

		case .waiting:
			updateActiveSession(paneId: paneId) { session in
				session.status = .waiting
				session.message = message
				session.currentTool = nil
				session.isRead = false
			}
			sendDesktopNotification(title: "Claude Code", body: message, projectId: projectId)

		case .completed:
			// Find session by active index first, fallback to latest for this pane
			// (sessionEnd may have already cleared the active index)
			let idx = activeSessionIndex[paneId] ?? sessions.firstIndex(where: { $0.paneId == paneId })
			if let idx, idx < sessions.count, sessions[idx].paneId == paneId {
				sessions[idx].status = .completed
				sessions[idx].message = message
				if message != "Done" {
					sessions[idx].lastAgentActivity = message
				}
				sessions[idx].currentTool = nil
				sessions[idx].updatedAt = Date()
				saveSessions()
			}
			// macOS 通知: belve hook の stop は (1) "Done" placeholder を即時送って
			// sidebar dot を緑化、(2) transcript 抽出して実テキストを送る、の 2 段構え。
			// 通知は **(2) 実テキストの時だけ** 出す。"Done" はただの即応用 placeholder
			// で情報量ゼロなので通知して通信スパムにする価値がない。
			// 抽出失敗時は (2) が来ないので通知も無し (= 体感の害はほぼ無い、UI 側
			// の sidebar dot は (1) で既に更新されてる)。
			if !message.isEmpty && message != "Done" {
				sendDesktopNotification(title: "Claude Code — Done", body: message, projectId: projectId)
			}

		case .sessionEnd:
			updateActiveSession(paneId: paneId) { session in
				// If completed event was missed, mark as completed before ending
				if session.status == .running || session.status == .waiting || session.status == .sessionStart {
					session.status = .completed
					if session.lastAgentActivity == nil {
						session.message = "Done"
					}
				}
				session.status = .sessionEnd
				session.currentTool = nil
			}
			activeSessionIndex.removeValue(forKey: paneId)
			// Clear project-level agent status so sidebar dot resets
			self.agentStatus[projectId] = AgentState(status: .idle, message: "")

		case .idle:
			break
		case .runningSubagent:
			// hook event 由来では来ない (派生表示状態)。switch 網羅性のための case。
			break
		}
	}

	private func updateActiveSession(paneId: String, update: (inout AgentSession) -> Void) {
		if let idx = activeSessionIndex[paneId], idx < sessions.count,
		   sessions[idx].paneId == paneId {
			update(&sessions[idx])
			sessions[idx].updatedAt = Date()
			saveSessions()
		}
	}

	// MARK: - Persistence

	private static var saveURL: URL {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let belveDir = appSupport.appendingPathComponent("Belve")
		try? FileManager.default.createDirectory(at: belveDir, withIntermediateDirectories: true)
		return belveDir.appendingPathComponent("agent-sessions.json")
	}

	func loadSessions() {
		guard let data = try? Data(contentsOf: Self.saveURL),
			  var decoded = try? JSONDecoder().decode([AgentSession].self, from: data) else { return }
		// On restart we don't know whether the agent process is still alive
		// (the container broker often is). Fall back to `.sessionStart` so the
		// row renders as "Ready" — visually distinct from the terminal
		// `.completed`/`.sessionEnd` states while we wait for the next hook.
		for i in decoded.indices {
			if decoded[i].status == .running || decoded[i].status == .waiting || decoded[i].status == .sessionStart {
				decoded[i].status = .sessionStart
				decoded[i].currentTool = nil
			}
		}
		// Keep only last 50 sessions
		sessions = Array(decoded.prefix(50))
	}

	private func saveSessions() {
		// Keep only last 50 sessions
		let toSave = Array(sessions.prefix(50))
		if let data = try? JSONEncoder().encode(toSave) {
			try? data.write(to: Self.saveURL)
		}
	}

	func archiveSessionsForPane(_ paneId: String) {
		for i in sessions.indices where sessions[i].paneId == paneId {
			sessions[i].isArchived = true
		}
		activeSessionIndex.removeValue(forKey: paneId)
		saveSessions()
	}

	/// Archive a single session by id — used for manual dismissal from the sidebar.
	func archiveSession(_ id: UUID) {
		guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
		sessions[idx].isArchived = true
		if let paneId = sessions[idx].paneId,
		   activeSessionIndex[paneId] == idx {
			activeSessionIndex.removeValue(forKey: paneId)
		}
		saveSessions()
	}

	func requestNotificationPermission() {
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
	}

	func sendDesktopNotification(title: String, body: String, projectId: UUID? = nil) {
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		if let projectId {
			content.userInfo = ["projectId": projectId.uuidString]
		}
		let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
		UNUserNotificationCenter.current().add(request)
	}
}
