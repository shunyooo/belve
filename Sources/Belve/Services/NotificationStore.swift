import Foundation
import UserNotifications

enum AgentStatus: String {
	case idle
	case sessionStart = "session_start"
	case running
	case waiting
	case completed
	case sessionEnd = "session_end"
}

struct AgentState {
	var status: AgentStatus
	var message: String
}

/// One record per agent session. Status updates in-place.
struct AgentSession: Identifiable {
	let id = UUID()
	let projectId: UUID
	var paneId: String?
	var status: AgentStatus
	var message: String
	var label: String?
	var lastUserPrompt: String?
	var lastAgentActivity: String?
	var currentTool: String?
	let startedAt: Date
	var updatedAt: Date
	var isRead: Bool = false
}

class NotificationStore: ObservableObject {
	@Published var sessions: [AgentSession] = []
	@Published var agentStatus: [UUID: AgentState] = [:] // keyed by projectId
	@Published var agentPaneId: [UUID: String] = [:] // projectId → active paneId
	@Published var sessionLabels: [UUID: String] = [:] // keyed by projectId

	// Mapping: paneId → projectId
	var paneToProject: [String: UUID] = [:]
	// Active session index per project (for in-place updates)
	private var activeSessionIndex: [UUID: Int] = [:]

	func registerPane(paneId: String, projectId: UUID) {
		paneToProject[paneId] = projectId
	}

	func updateAgentStatus(paneId: String, status: String, message: String) {
		guard let projectId = paneToProject[paneId],
			  let agentStatus = AgentStatus(rawValue: status) else { return }

		self.agentStatus[projectId] = AgentState(status: agentStatus, message: message)
		self.agentPaneId[projectId] = paneId

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
			activeSessionIndex[projectId] = 0
			// Shift other indices
			for (key, idx) in activeSessionIndex where key != projectId {
				activeSessionIndex[key] = idx + 1
			}

		case .running:
			updateActiveSession(projectId: projectId) { session in
				session.status = .running
				session.message = message
				// Capture first prompt as label
				if session.label == nil && message != "Generating" {
					session.label = message
					self.sessionLabels[projectId] = message
				}
				// Track agent activity and tool usage
				if message.hasPrefix("tool:") {
					session.currentTool = String(message.dropFirst(5))
				} else if message != "Generating" {
					session.lastUserPrompt = message
					session.currentTool = nil
				}
			}

		case .waiting:
			updateActiveSession(projectId: projectId) { session in
				session.status = .waiting
				session.message = message
				session.currentTool = nil
				session.isRead = false
			}
			sendDesktopNotification(title: "Claude Code", body: message, projectId: projectId)

		case .completed:
			updateActiveSession(projectId: projectId) { session in
				session.status = .completed
				session.message = message
				session.currentTool = nil
			}

		case .sessionEnd:
			updateActiveSession(projectId: projectId) { session in
				session.status = .sessionEnd
			}
			activeSessionIndex.removeValue(forKey: projectId)

		case .idle:
			break
		}
	}

	private func updateActiveSession(projectId: UUID, update: (inout AgentSession) -> Void) {
		if let idx = activeSessionIndex[projectId], idx < sessions.count,
		   sessions[idx].projectId == projectId {
			update(&sessions[idx])
			sessions[idx].updatedAt = Date()
		}
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
