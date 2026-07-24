import Foundation
import UserNotifications

struct AgentNotification: Identifiable {
	let id: UUID
	let projectId: UUID
	let paneId: String
	let projectName: String
	let status: AgentStatus
	let message: String
	let timestamp: Date
}

/// デスクトップ通知と未読通知リスト (`unreadNotifications`) だけを責務とするストア。
/// エージェントセッションの identity / 状態は `AgentSessionStore` が唯一所有し、
/// このストアは所有しない。
class NotificationStore: ObservableObject {
	@Published var unreadNotifications: [AgentNotification] = []

	// Mapping: paneId → projectId (通知の projectId / projectName 解決に必要)
	var paneToProject: [String: UUID] = [:]

	var projectNameResolver: ((UUID) -> String)?

	func pushNotification(projectId: UUID, paneId: String, projectName: String, status: AgentStatus, message: String) {
		// 同じ pane の古い通知を消して最新だけ残す
		unreadNotifications.removeAll { $0.paneId == paneId }
		let notif = AgentNotification(
			id: UUID(), projectId: projectId, paneId: paneId,
			projectName: projectName, status: status, message: message,
			timestamp: Date()
		)
		unreadNotifications.insert(notif, at: 0)
		if unreadNotifications.count > 20 {
			unreadNotifications = Array(unreadNotifications.prefix(20))
		}
	}

	func dismissNotification(_ id: UUID) {
		unreadNotifications.removeAll { $0.id == id }
	}

	func dismissAllNotifications() {
		unreadNotifications.removeAll()
	}

	func registerPane(paneId: String, projectId: UUID) {
		paneToProject[paneId] = projectId
	}

	/// `(paneId, sessionId)` あたり「初回観測した sessionId = primary」を記録。
	/// Stop hook 等で spawn された別 claude (= 別 session_id) からの通知を抑制
	/// するために使う。`session_end` で entry を消すので、parent claude が
	/// 完全終了した後に new claude を立ち上げると新 primary が記録される。
	private var primarySessionPerPane: [String: String] = [:]

	/// `sessionId` がこの pane の primary かどうか判定する。空 sessionId (=
	/// 旧 BELVE 形式の event 等) は常に true (= filter なし)。
	private func isPrimarySession(paneId: String, sessionId: String) -> Bool {
		if sessionId.isEmpty { return true }
		guard let primary = primarySessionPerPane[paneId] else { return true }
		return primary == sessionId
	}

	/// OSC payload を表示可能テキストに整形する。実体は `AgentMessageSanitizer` に
	/// 抽出済み (AgentSessionStore と共有)。
	private static func sanitizeMessage(_ raw: String) -> String {
		AgentMessageSanitizer.sanitize(raw)
	}

	/// OSC 由来の agent status を **通知だけ** に反映する。session identity / 状態は
	/// `AgentSessionStore` が所有するのでここでは触らない。
	func updateAgentStatus(paneId: String, sessionId: String, status: String, messageRaw: String) {
		// belve hook script は OSC payload に literal \n を入れずに "\\n" (= 2 chars)
		// で escape する (= ターミナル emulator が OSC を生改行で切る回避)。Mac 側で復元。
		// 同時に ANSI escape codes (= claude UI rendering 由来の制御文字) を strip。
		let message = Self.sanitizeMessage(messageRaw)
		guard let projectId = paneToProject[paneId],
			  let agentStatus = AgentStatus(rawValue: status) else { return }

		// Primary session の更新ルール:
		//   - sessionStart で primary 未設定なら新規 primary に。
		//   - 既存 primary がある場合は **上書きしない** (= Stop hook spawn の
		//     別 claude が sessionStart を出しても original を保護)。
		//   - sessionEnd で primary が一致したら entry 削除 → 次の sessionStart で
		//     新 primary 受け入れ可能になる。
		if !sessionId.isEmpty {
			if agentStatus == .sessionStart && primarySessionPerPane[paneId] == nil {
				primarySessionPerPane[paneId] = sessionId
			} else if agentStatus == .sessionEnd && primarySessionPerPane[paneId] == sessionId {
				primarySessionPerPane.removeValue(forKey: paneId)
			}
		}

		NSLog("[Belve] Agent status: %@ - %@ (pane: %@ sid: %@)", status, message, paneId, sessionId)

		switch agentStatus {
		case .working:
			// session が動き出したら通知は不要（ユーザーが対応した or 自動進行）。
			// subagent / background イベントは親 session の resume ではないので消さない。
			let isSubagentEvent = message.hasPrefix("subagent:") || message.hasPrefix("subagent-done:")
			let isBackgroundEvent = message.hasPrefix("background:")
			if !isSubagentEvent && !isBackgroundEvent {
				unreadNotifications.removeAll { $0.paneId == paneId }
			}

		case .blocked:
			if isPrimarySession(paneId: paneId, sessionId: sessionId) {
				let projName = projectNameResolver?(projectId) ?? "?"
				pushNotification(projectId: projectId, paneId: paneId, projectName: projName, status: .blocked, message: message)
				sendDesktopNotification(title: "Claude Code", body: message, projectId: projectId, paneId: paneId)
			} else {
				NSLog("[Belve][notif] suppress (non-primary session) pane=%@ sid=%@", paneId, sessionId)
			}

		case .done:
			// macOS 通知: belve hook の stop は (1) "Done" placeholder を即時送って
			// sidebar dot を緑化、(2) transcript 抽出して実テキストを送る、の 2 段構え。
			// 通知は **(2) 実テキストの時だけ** 出す。"Done" はただの即応用 placeholder
			// で情報量ゼロなので通知して通信スパムにする価値がない。
			// 抽出失敗時は (2) が来ないので通知も無し (= 体感の害はほぼ無い、UI 側
			// の sidebar dot は (1) で既に更新されてる)。
			if !message.isEmpty && message != "Done" {
				if isPrimarySession(paneId: paneId, sessionId: sessionId) {
					let projName = projectNameResolver?(projectId) ?? "?"
					pushNotification(projectId: projectId, paneId: paneId, projectName: projName, status: .done, message: message)
					sendDesktopNotification(title: "Claude Code — Done", body: message, projectId: projectId, paneId: paneId)
				} else {
					NSLog("[Belve][notif] suppress (non-primary session) pane=%@ sid=%@", paneId, sessionId)
				}
			}

		case .sessionStart, .sessionEnd, .idle, .runningSubagent:
			// session 状態は AgentSessionStore が所有。通知としての副作用は無い。
			break
		}
	}

	func requestNotificationPermission() {
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
	}

	/// 「この paneId は現在 sidebar (= live view 群) に出ているか」の判定 closure。
	/// MainWindow が起動時に stateManager 経由でセットする。nil ならフィルタ
	/// 無効 (= 全て通知)。
	///
	/// 用途: program code から呼ばれた claude (= 親 view の pane に紐付かない
	/// session) の通知を抑止するため。
	var isPaneLive: ((String) -> Bool)?

	/// Pane ごとの通知抑制 deadline。terminal reload 直後に belve-persist が
	/// 過去の出力を replay する際、含まれてた OSC イベントが再 dispatch されて
	/// 通知が flooded になる。reload 側 (XTermTerminalView.startPTY) が
	/// `suppressNotifications(for:seconds:)` で warm-up window を設定すれば、
	/// その期間の通知は drop する。
	private var notificationSuppressedUntil: [String: Date] = [:]

	func suppressNotifications(for paneId: String, seconds: TimeInterval) {
		notificationSuppressedUntil[paneId] = Date().addingTimeInterval(seconds)
	}

	/// 現在 reload warm-up window 内かどうか。AgentCompanionStore 等が
	/// 「replay 由来の event を bubble 履歴に積まない」判定に使う。
	func isInReloadWarmup(for paneId: String) -> Bool {
		guard let until = notificationSuppressedUntil[paneId] else { return false }
		return Date() < until
	}

	func sendDesktopNotification(title: String, body: String, projectId: UUID? = nil, paneId: String? = nil) {
		if let paneId {
			// reload warm-up 中なら drop。
			if let until = notificationSuppressedUntil[paneId], Date() < until {
				NSLog("[Belve][notif] suppress (reload warm-up) pane=%@", paneId)
				return
			}
			// sidebar に居ない pane (= program 経由 claude 等) は drop。
			if let isLive = isPaneLive, !isLive(paneId) {
				NSLog("[Belve][notif] suppress (not live) pane=%@", paneId)
				return
			}
		}
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
