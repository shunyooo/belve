import SwiftUI

struct AgentNotificationStack: View {
	@EnvironmentObject var notificationStore: NotificationStore
	let onFocus: (UUID, String) -> Void
	@State private var isCollapsed: Bool = false

	var body: some View {
		let notifications = deduplicatedNotifications()
		VStack(spacing: 0) {
			// 上端の divider は ProjectListView 側の notificationDivider が描画する
			// (= リサイズ hover 領域も兼ねる)。ここで重ねて描かない。
			// ヘッダー（常に表示、クリックで収納トグル）
			HStack {
				Button(action: {
					withAnimation(.easeOut(duration: 0.15)) { isCollapsed.toggle() }
				}) {
					HStack(spacing: 4) {
						Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
							.font(.system(size: 8, weight: .semibold))
							.foregroundStyle(Theme.textTertiary)
						Text("Notifications")
							.font(.system(size: 10, weight: .semibold))
							.foregroundStyle(Theme.textSecondary)
						if !notifications.isEmpty {
							Text("\(notifications.count)")
								.font(.system(size: 9, weight: .bold))
								.foregroundStyle(Theme.accent)
								.padding(.horizontal, 4)
								.padding(.vertical, 1)
								.background(Capsule().fill(Theme.accent.opacity(0.15)))
						}
					}
				}
				.buttonStyle(.plain)
				Spacer()
				if !notifications.isEmpty && !isCollapsed {
					Button("Clear") {
						withAnimation(.easeOut(duration: 0.2)) {
							notificationStore.dismissAllNotifications()
						}
					}
					.buttonStyle(.plain)
					.font(.system(size: 9))
					.foregroundStyle(Theme.textTertiary)
				}
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 5)

			if !isCollapsed {
				if notifications.isEmpty {
					Text("No new notifications")
						.font(.system(size: 10))
						.foregroundStyle(Theme.textTertiary)
						.frame(maxWidth: .infinity)
						.padding(.vertical, 12)
				} else {
					ScrollView {
						VStack(spacing: 2) {
							ForEach(notifications) { notif in
								notificationRow(notif)
							}
						}
						.padding(.horizontal, 8)
						.padding(.bottom, 4)
					}
				}
			}
		}
		.background(Theme.bg.opacity(0.5))
	}

	private func deduplicatedNotifications() -> [AgentNotification] {
		var seen = Set<String>()
		var result: [AgentNotification] = []
		for notif in notificationStore.unreadNotifications {
			if seen.contains(notif.paneId) { continue }
			seen.insert(notif.paneId)
			result.append(notif)
		}
		return result
	}

	private func notificationRow(_ notif: AgentNotification) -> some View {
		HStack(alignment: .top, spacing: 8) {
			Circle()
				.fill(statusColor(notif.status))
				.frame(width: 6, height: 6)
				.padding(.top, 5)

			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 4) {
					Text(notif.projectName)
						.font(.system(size: 10, weight: .semibold))
						.foregroundStyle(statusColor(notif.status))
					Text(statusEmoji(notif.status))
						.font(.system(size: 9))
					Spacer()
					Text(relativeTime(notif.timestamp))
						.font(.system(size: 8))
						.foregroundStyle(Theme.textTertiary)
				}
				Text(notif.message)
					.font(.system(size: 10))
					.foregroundStyle(Theme.textPrimary)
					.lineLimit(2)
			}

			Button(action: {
				withAnimation(.easeOut(duration: 0.2)) {
					notificationStore.dismissNotification(notif.id)
				}
			}) {
				Image(systemName: "xmark")
					.font(.system(size: 8))
					.foregroundStyle(Theme.textTertiary)
			}
			.buttonStyle(.plain)
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 6)
		.background(
			RoundedRectangle(cornerRadius: 6)
				.fill(statusColor(notif.status).opacity(0.06))
		)
		.contentShape(Rectangle())
		.onTapGesture {
			// プロジェクト選択 + ペイン activate
			NotificationCenter.default.post(
				name: .belveFocusProject,
				object: nil,
				userInfo: ["projectId": notif.projectId]
			)
			NotificationCenter.default.post(
				name: .belveTileActivatePane,
				object: nil,
				userInfo: ["projectId": notif.projectId, "paneId": notif.paneId]
			)
			withAnimation(.easeOut(duration: 0.2)) {
				notificationStore.dismissNotification(notif.id)
			}
		}
	}

	private func statusColor(_ status: AgentStatus) -> Color {
		switch status {
		case .blocked: return Theme.yellow
		case .done: return Theme.green
		case .working, .runningSubagent: return Theme.accent
		default: return Theme.textSecondary
		}
	}

	private func statusEmoji(_ status: AgentStatus) -> String {
		switch status {
		case .blocked: return "⏸"
		case .done: return "✓"
		case .working: return "▶"
		default: return ""
		}
	}

	private func relativeTime(_ date: Date) -> String {
		let seconds = Int(Date().timeIntervalSince(date))
		if seconds < 60 { return "\(seconds)s" }
		if seconds < 3600 { return "\(seconds / 60)m" }
		return "\(seconds / 3600)h"
	}
}
