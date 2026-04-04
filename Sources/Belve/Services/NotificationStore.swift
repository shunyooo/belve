import Foundation

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
