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
		manuallyEnabled.insert(paneId)
		manuallyDismissed.remove(paneId)
		if let store = notificationStore {
			reconcile(sessions: store.sessions)
		}
	}

	/// Sidebar context menu → "Hide Companion" / companion 右クリック → Dismiss で呼ぶ。
	func disableCompanion(for paneId: String) {
		manuallyEnabled.remove(paneId)
		manuallyDismissed.insert(paneId)
		companions.removeValue(forKey: paneId)
		AgentCompanionWindowManager.shared.dismiss(paneId: paneId)
		selectedPaneIds.remove(paneId)
	}

	/// paneId の companion が有効化されてるか。Sidebar の context menu 表示用。
	func isCompanionEnabled(for paneId: String) -> Bool {
		!manuallyDismissed.contains(paneId)
	}

	/// Sidebar と同じ project 順序 (= projectStore.projects の id 配列)。
	/// Dock の avatar 並び順に使用。
	var projectOrder: [UUID] {
		projectStore?.projects.map(\.id) ?? []
	}

	/// Per-session avatar style を取得。Sidebar の SessionRow と companion が同じ
	/// avatar を表示するための共通 accessor。未設定 (= 一度も companion 表示されてない
	/// session) なら nil を返す (= 呼び出し側が global style を使う)。
	func avatarStyle(for paneId: String) -> SpinnerStyle? {
		if let cached = avatarStyles[paneId] { return cached }
		// UserDefaults に保存済みなら復元
		if let saved = UserDefaults.standard.string(forKey: "Belve.companionAvatar.\(paneId)"),
		   let style = SpinnerStyle(rawValue: saved) {
			avatarStyles[paneId] = style
			return style
		}
		// 未設定: deterministic random で初期化 + persist
		let picked = randomAvatar(seed: paneId)
		avatarStyles[paneId] = picked
		UserDefaults.standard.set(picked.rawValue, forKey: "Belve.companionAvatar.\(paneId)")
		return picked
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
	/// 非 pinned project の pane で、sidebar から明示的に有効化されたもの。
	private var manuallyEnabled = Set<String>()
	/// Per-pane message history。最新 3 件を保持。session 終了でクリア。
	private var messageHistory: [String: [CompanionMessage]] = [:]
	/// 前回の message text (連続重複 dedup 用)。
	private var lastMessageText: [String: String] = [:]
	private var lastSeenPrompt: [String: String] = [:]
	private let maxMessages = 3

	private init() {}

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
			let project = projectStore?.projects.first(where: { $0.id == session.projectId })
			guard let project else { continue }
			// Pinned project → 自動追加。非 pinned → 明示的に有効化されたもののみ。
			if !project.isPinned && !manuallyEnabled.contains(paneId) { continue }
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
			let projectName = project.name

			// ユーザーが新しい prompt を submit したら bubble をリセット
			let currentPrompt = session.lastUserPrompt ?? ""
			if !currentPrompt.isEmpty && currentPrompt != lastSeenPrompt[paneId] {
				lastSeenPrompt[paneId] = currentPrompt
				messageHistory.removeValue(forKey: paneId)
				lastMessageText.removeValue(forKey: paneId)
			}

			// Bubble-worthy message: transcript 由来 agent 発話 / result / waiting 等。
			// Replay warm-up 中は skip。Dedup は consecutive only (= lastMessageText)。
			let inReplay = notificationStore?.isInReloadWarmup(for: paneId) ?? false
			let bubbleText = bubbleWorthyText(for: session)
			NSLog("[Belve][companion] pane=%@ inReplay=%d bubbleText=%@ lastMsg=%@ msgCount=%d",
				String(paneId.prefix(8)), inReplay ? 1 : 0,
				bubbleText ?? "nil", lastMessageText[paneId] ?? "nil",
				messageHistory[paneId]?.count ?? 0)
			if !inReplay, let text = bubbleText, text != lastMessageText[paneId] {
				lastMessageText[paneId] = text
				let msg = CompanionMessage(id: UUID(), text: text, timestamp: Date())
				var history = messageHistory[paneId] ?? []
				history.append(msg)
				if history.count > maxMessages {
					history = Array(history.suffix(maxMessages))
				}
				messageHistory[paneId] = history
			} else if inReplay, let text = bubbleText {
				lastMessageText[paneId] = text
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
		}
		// Dock panel の表示 / 非表示を更新
		AgentCompanionWindowManager.shared.updateDock(hasCompanions: !companions.isEmpty)
	}

	/// Sidebar の session row と同じ表示条件。archived / sessionEnd / idle は非表示。
	/// completed / waiting / running / sessionStart は表示 (= sidebar と揃える)。
	private static let inactiveStatuses: Set<AgentStatus> = [.sessionEnd, .idle]

	private func isActive(_ session: AgentSession) -> Bool {
		!session.isArchived && !Self.inactiveStatuses.contains(session.status)
	}

	/// Bubble として追加すべきテキスト。Agent の行動・発話を可視化する:
	/// - tool 実行 (= 何をしようとしているか)
	/// - speech (= transcript 由来の中間発話・思考)
	/// - waiting message (= ユーザーへの問いかけ)
	/// - result summary (= 何をやったか)
	/// User prompt は header 固定表示なので bubble には出さない。
	private func bubbleWorthyText(for session: AgentSession) -> String? {
		// Waiting (= agent がユーザーに聞いてる) → 最も重要な bubble
		if session.status == .waiting { return session.message }
		// Completed の最終応答
		if session.status == .completed, !session.message.isEmpty, session.message != "Done" {
			return session.message
		}
		let msg = session.message
		// `speech:` prefix = transcript 由来の agent 中間発話
		if msg.hasPrefix("speech:") {
			return String(msg.dropFirst("speech:".count))
		}
		// `result:` prefix = tool 完了後の結果サマリ (= agent が何をしたかの報告)
		if msg.hasPrefix("result:") {
			return String(msg.dropFirst("result:".count))
		}
		// `tool:` prefix = tool 実行中 (= 何をしようとしているか)
		if msg.hasPrefix("tool:") {
			let detail = String(msg.dropFirst("tool:".count))
			let parts = detail.split(separator: ":", maxSplits: 1)
			let toolName = parts.first.map(String.init) ?? detail
			let activity = parts.count > 1 ? String(parts[1]) : nil
			if let activity, !activity.isEmpty {
				return "\(toolName): \(activity)"
			}
			return toolName
		}
		// subagent 起動
		if msg.hasPrefix("subagent:") {
			return "Agent: \(String(msg.dropFirst("subagent:".count)))"
		}
		// User prompt / label と同じテキストは bubble に出さない (= header で既に表示)
		if msg == session.lastUserPrompt || msg == session.label { return nil }
		if msg.hasPrefix("subagent-done:") { return nil }
		if ["Generating", "started", "ended", "Done", "Ready"].contains(msg) { return nil }
		if msg.isEmpty { return nil }
		// それ以外 → bubble
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
