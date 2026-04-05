import Foundation

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

struct TerminalNotification: Identifiable {
	let id = UUID()
	let projectId: UUID
	let title: String
	let body: String
	let timestamp: Date
	var isRead: Bool = false
}

class NotificationStore: ObservableObject {
	@Published var notifications: [TerminalNotification] = []
	@Published var agentStatus: [UUID: AgentState] = [:] // keyed by projectId

	// Mapping: paneId → projectId (set by TerminalPaneView)
	var paneToProject: [String: UUID] = [:]

	func registerPane(paneId: String, projectId: UUID) {
		paneToProject[paneId] = projectId
	}

	func updateAgentStatus(paneId: String, status: String, message: String) {
		guard let projectId = paneToProject[paneId],
			  let agentStatus = AgentStatus(rawValue: status) else {
			NSLog("[Belve] Agent status ignored: pane \(paneId) not mapped or unknown status \(status)")
			return
		}

		self.agentStatus[projectId] = AgentState(status: agentStatus, message: message)
		NSLog("[Belve] Agent status: \(status) - \(message) (project: \(projectId))")

		// Add notification for waiting state
		if agentStatus == .waiting {
			add(projectId: projectId, title: "Claude Code", body: message)
		}
	}

	func add(projectId: UUID, title: String, body: String) {
		let notification = TerminalNotification(
			projectId: projectId,
			title: title,
			body: body,
			timestamp: Date()
		)
		notifications.insert(notification, at: 0)
		NSLog("[Belve] Notification: \(title) - \(body)")
	}

	func unreadCount(for projectId: UUID) -> Int {
		notifications.filter { $0.projectId == projectId && !$0.isRead }.count
	}

	func totalUnreadCount() -> Int {
		notifications.filter { !$0.isRead }.count
	}

	func markAllRead(for projectId: UUID) {
		for i in notifications.indices {
			if notifications[i].projectId == projectId {
				notifications[i].isRead = true
			}
		}
	}

	func latestNotification(for projectId: UUID) -> TerminalNotification? {
		notifications.first { $0.projectId == projectId }
	}
}
