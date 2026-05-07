import AppKit
import Combine
import SwiftUI

/// Belve のセッションごとに常駐させる「キャラクター・コンパニオン」の状態管理。
/// 1 AgentSession = 1 AgentCompanion (= 画面上の floating panel)。
/// NotificationStore.sessions を観測し、active 化で自動生成、終了で自動 dismiss。
///
/// Phase 1 MVP:
///   - 自動 lifecycle (active 化で出現、completed で消える)
///   - 画面右上 stack 配置 (offset で重ならない)
///   - 各 companion の avatar = random SpinnerStyle
///   - Click で view jump
///
/// Phase 2 以降: drag 配置永続化、avatar picker、context menu 等。
@MainActor
final class AgentCompanionStore: ObservableObject {
	static let shared = AgentCompanionStore()

	/// `paneId` をキーに companion を追跡。NotificationStore.sessions と
	/// 対応するが、companion 自身は AgentSession の subset (= 表示用 snapshot)。
	@Published private(set) var companions: [String: AgentCompanion] = [:]

	/// 現在選択中の paneId 集合。Cmd-click で toggle、選択された companion は
	/// border 強調 + 任意の選択 companion を drag すると全選択分が同時 move する。
	@Published private(set) var selectedPaneIds: Set<String> = []

	func toggleSelection(_ paneId: String) {
		if selectedPaneIds.contains(paneId) {
			selectedPaneIds.remove(paneId)
		} else {
			selectedPaneIds.insert(paneId)
		}
	}

	func clearSelection() {
		selectedPaneIds.removeAll()
	}

	func isSelected(_ paneId: String) -> Bool {
		selectedPaneIds.contains(paneId)
	}

	/// Sidebar context menu → "Show Companion" で呼ぶ。
	func enableCompanion(for paneId: String) {
		enabledPaneIds.insert(paneId)
		manuallyDismissed.remove(paneId)
		if let store = notificationStore {
			reconcile(sessions: store.sessions)
		}
	}

	/// Sidebar context menu → "Hide Companion" / companion 右クリック → Dismiss で呼ぶ。
	func disableCompanion(for paneId: String) {
		enabledPaneIds.remove(paneId)
		companions.removeValue(forKey: paneId)
		AgentCompanionWindowManager.shared.dismiss(paneId: paneId)
		selectedPaneIds.remove(paneId)
	}

	/// paneId の companion が有効化されてるか。Sidebar の context menu 表示用。
	func isCompanionEnabled(for paneId: String) -> Bool {
		enabledPaneIds.contains(paneId)
	}

	/// Avatar を次の style に cycle (= right-click > Change Avatar)。
	func cycleAvatar(_ paneId: String) {
		let pool: [SpinnerStyle] = [.invader, .ghost, .chibiCat, .rainbowCat, .partyParrot]
		let current = avatarStyles[paneId] ?? .partyParrot
		let idx = pool.firstIndex(of: current) ?? 0
		let next = pool[(idx + 1) % pool.count]
		avatarStyles[paneId] = next
		UserDefaults.standard.set(next.rawValue, forKey: "Belve.companionAvatar.\(paneId)")
		// Force reconcile to pick up new style
		if let store = notificationStore {
			reconcile(sessions: store.sessions)
		}
	}

	/// ユーザー手動 dismiss (= companion 右クリック → Dismiss)。
	/// enabled 状態も解除するので、再表示するには sidebar から再度有効化。
	func dismissManually(_ paneId: String) {
		disableCompanion(for: paneId)
	}

	private var cancellables = Set<AnyCancellable>()
	private weak var notificationStore: NotificationStore?
	private weak var projectStore: ProjectStore?
	/// paneId → avatar style。UserDefaults に永続化 + ユーザー選択上書き対応。
	private var avatarStyles: [String: SpinnerStyle] = [:]
	/// ユーザーが手動 dismiss した paneId。session が active でも companion 出さない。
	/// session 終了 (= reconcile から消える) でリセット → 次回 session 開始で再出現。
	private var manuallyDismissed = Set<String>()
	/// Companion を表示する paneId 集合。sidebar の context menu から明示的に
	/// 有効化したもののみ表示 (= デフォルト非表示)。UserDefaults に永続化。
	private var enabledPaneIds: Set<String> {
		didSet { persistEnabledPaneIds() }
	}

	private static let enabledPaneIdsKey = "Belve.companionEnabledPaneIds"

	private func loadEnabledPaneIds() -> Set<String> {
		let arr = UserDefaults.standard.stringArray(forKey: Self.enabledPaneIdsKey) ?? []
		return Set(arr)
	}

	private func persistEnabledPaneIds() {
		UserDefaults.standard.set(Array(enabledPaneIds), forKey: Self.enabledPaneIdsKey)
	}
	/// Per-pane message history。最新 3 件を保持。「前回と同じ text なら追加しない」
	/// でデデュプ。session 終了でクリア。
	private var messageHistory: [String: [CompanionMessage]] = [:]
	/// 前回の message text (デデュプ判定用)。
	private var lastMessageText: [String: String] = [:]
	private let maxMessages = 3

	private init() {
		self.enabledPaneIds = Set(UserDefaults.standard.stringArray(forKey: Self.enabledPaneIdsKey) ?? [])
	}

	/// AppDelegate.didFinishLaunching から呼ぶ。NotificationStore の sessions を
	/// 観測して companion lifecycle を駆動する。
	func attach(notificationStore: NotificationStore, projectStore: ProjectStore) {
		self.notificationStore = notificationStore
		self.projectStore = projectStore
		notificationStore.$sessions
			.receive(on: DispatchQueue.main)
			.sink { [weak self] sessions in
				self?.reconcile(sessions: sessions)
			}
			.store(in: &cancellables)
	}

	/// Sessions のスナップショットから companions を再構成。
	/// active な session は companion を持ち、active でない session は除外。
	private func reconcile(sessions: [AgentSession]) {
		let activeSessions = sessions.filter { isActive($0) }
		let activePaneIds = Set(activeSessions.compactMap(\.paneId))

		// 既存 companion のうち、対応 session が active でなくなったら削除
		for paneId in companions.keys where !activePaneIds.contains(paneId) {
			companions.removeValue(forKey: paneId)
			AgentCompanionWindowManager.shared.dismiss(paneId: paneId)
			selectedPaneIds.remove(paneId)
			manuallyDismissed.remove(paneId)
			messageHistory.removeValue(forKey: paneId)
			lastMessageText.removeValue(forKey: paneId)
		}

		// active session に対応する companion が無ければ追加 / 既存は更新
		for session in activeSessions {
			guard let paneId = session.paneId else { continue }
			// 明示的に有効化されたもののみ表示 (= デフォルト非表示)
			if !enabledPaneIds.contains(paneId) { continue }
			if manuallyDismissed.contains(paneId) { continue }
			let saved = UserDefaults.standard.string(forKey: "Belve.companionAvatar.\(paneId)")
				.flatMap { SpinnerStyle(rawValue: $0) }
			let style: SpinnerStyle
			if let cached = avatarStyles[paneId] {
				style = cached
			} else if let persisted = saved {
				style = persisted
			} else {
				let picked = randomAvatar(seed: paneId)
				// 初回 pick を即 persist (= 次回起動で同じキャラが出るように)
				UserDefaults.standard.set(picked.rawValue, forKey: "Belve.companionAvatar.\(paneId)")
				style = picked
			}
			avatarStyles[paneId] = style
			let projectName = projectStore?.projects.first(where: { $0.id == session.projectId })?.name ?? "?"

			// Bubble-worthy message: tool / result / subagent 以外 (= agent の思考、
			// user prompt、waiting 等)。tool 系は currentTool として小さくインライン表示。
			let bubbleText = bubbleWorthyText(for: session)
			if let text = bubbleText, text != lastMessageText[paneId] {
				lastMessageText[paneId] = text
				let msg = CompanionMessage(id: UUID(), text: text, timestamp: Date())
				var history = messageHistory[paneId] ?? []
				history.append(msg)
				if history.count > maxMessages {
					history = Array(history.suffix(maxMessages))
				}
				messageHistory[paneId] = history
			}

			let snapshot = AgentCompanion(
				paneId: paneId,
				projectId: session.projectId,
				projectName: projectName,
				status: session.status,
				avatarStyle: style,
				userPrompt: session.lastUserPrompt ?? session.label ?? "",
				messages: messageHistory[paneId] ?? [],
				currentTool: currentToolText(for: session)
			)
			companions[paneId] = snapshot
			AgentCompanionWindowManager.shared.upsert(companion: snapshot)
		}
	}

	/// Sidebar の session row と同じ表示条件。archived / sessionEnd / idle は非表示。
	/// completed / waiting / running / sessionStart は表示 (= sidebar と揃える)。
	private static let inactiveStatuses: Set<AgentStatus> = [.sessionEnd, .idle]

	private func isActive(_ session: AgentSession) -> Bool {
		!session.isArchived && !Self.inactiveStatuses.contains(session.status)
	}

	/// Bubble として追加すべきテキスト。Agent の「発話」に相当するもの:
	/// - waiting message (= ユーザーへの問いかけ)
	/// - result summary (= 何をやったか)
	/// - status 変化テキスト
	/// User prompt は header 固定表示なので bubble には出さない。
	/// Tool call は inline 表示なので bubble には出さない。
	private func bubbleWorthyText(for session: AgentSession) -> String? {
		// Waiting (= agent がユーザーに聞いてる) → 最も重要な bubble
		if session.status == .waiting { return session.message }
		// Tool 実行中の result summary (= "agent がやったこと" の報告)
		let msg = session.message
		if msg.hasPrefix("result:") {
			if let activity = session.lastAgentActivity, !activity.isEmpty {
				return activity
			}
		}
		// User prompt / label と同じテキストは bubble に出さない (= header で既に表示)
		if msg == session.lastUserPrompt || msg == session.label { return nil }
		// Tool prefix / lifecycle / Generating / 空は skip
		if msg.hasPrefix("tool:") || msg.hasPrefix("subagent") { return nil }
		if ["Generating", "started", "ended", "Done", "Ready"].contains(msg) { return nil }
		if msg.isEmpty { return nil }
		// それ以外 (= agent の思考テキスト等) → bubble
		return msg
	}

	/// 現在実行中の tool を小さいインライン表示用テキストにする。
	private func currentToolText(for session: AgentSession) -> String? {
		guard let tool = session.currentTool, !tool.isEmpty else { return nil }
		if let activity = session.lastAgentActivity, !activity.isEmpty {
			return "\(tool): \(activity)"
		}
		return tool
	}

	private func detailText(for session: AgentSession) -> String? {
		if let tool = session.currentTool, !tool.isEmpty {
			if let activity = session.lastAgentActivity, !activity.isEmpty {
				return "\(tool): \(activity)"
			}
			return tool
		}
		switch session.status {
		case .waiting: return session.message
		case .running, .runningSubagent: return "Thinking…"
		case .sessionStart: return "Ready"
		default: return nil
		}
	}

	/// `paneId` から deterministic に avatar style を選ぶ。
	/// Swift の hashValue は per-process random seed なので、FNV-1a で安定 hash。
	private func randomAvatar(seed: String) -> SpinnerStyle {
		let pool: [SpinnerStyle] = [.invader, .ghost, .chibiCat, .rainbowCat, .partyParrot]
		var h: UInt64 = 14695981039346656037 // FNV offset basis
		for byte in seed.utf8 {
			h ^= UInt64(byte)
			h &*= 1099511628211 // FNV prime
		}
		return pool[Int(h % UInt64(pool.count))]
	}
}

/// Companion の bubble 1 つ (= agent の思考・発言)。
struct CompanionMessage: Identifiable, Equatable {
	let id: UUID
	let text: String
	let timestamp: Date
}

/// Companion 1 つの表示 snapshot。Window 側はこれを観測して redraw する。
struct AgentCompanion: Identifiable, Equatable {
	var id: String { paneId }
	let paneId: String
	let projectId: UUID
	let projectName: String
	let status: AgentStatus
	let avatarStyle: SpinnerStyle
	/// ユーザーの最新指示。常に表示する固定ヘッダ。
	let userPrompt: String
	/// Agent の思考 / 発言 bubble (= tool 以外の message)。最新 3 件。
	var messages: [CompanionMessage]
	/// 現在実行中の tool (= 小さいインライン表示用)。nil = tool 実行中でない。
	let currentTool: String?
}
