import AppKit
import Combine
import SwiftUI

/// Belve のセッションごとに常駐させる「キャラクター・コンパニオン」の状態管理。
/// 1 pane (= floating avatar) = 1 AgentCompanion。`AgentSessionStore.sessionsPublisher`
/// を観測し、active session に bind された pane ごとに companion を生成、終了・archive で
/// 自動 dismiss する。identity は `AgentSessionStore` が唯一のソース。
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

	/// canonical (大文字) paneId をキーに companion を追跡。session に bind された pane と
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
		if let store = agentSessionStore {
			reconcile(sessions: store.sessions)
		}
	}

	/// Sidebar context menu → "Hide Companion" / companion 右クリック → Dismiss で呼ぶ。
	func disableCompanion(for paneId: String) {
		manuallyEnabled.remove(paneId)
		manuallyDismissed.insert(paneId)
		companions.removeValue(forKey: paneId)
		selectedPaneIds.remove(paneId)
	}

	/// 全 companion を非表示にする。
	func dismissAll() {
		for paneId in companions.keys {
			manuallyEnabled.remove(paneId)
			manuallyDismissed.insert(paneId)
		}
		companions.removeAll()
		selectedPaneIds.removeAll()
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
		if let store = agentSessionStore {
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
	private weak var agentSessionStore: AgentSessionStore?
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

	/// AppDelegate.didFinishLaunching から呼ぶ。`AgentSessionStore` の session ストリームを
	/// 観測して companion lifecycle を駆動する。`notificationStore` は reload warm-up 判定
	/// (replay 由来 event を bubble に積まない) 専用で、identity/状態のソースではない。
	func attach(
		notificationStore: NotificationStore,
		agentSessionStore: AgentSessionStore,
		projectStore: ProjectStore
	) {
		self.notificationStore = notificationStore
		self.agentSessionStore = agentSessionStore
		self.projectStore = projectStore
		// upstream (AgentSessionStore) が status 即時 / churn 200ms debounce で coalesce
		// 済みなので、ここでは追加の throttle を掛けない。
		agentSessionStore.sessionsPublisher
			.receive(on: DispatchQueue.main)
			.sink { [weak self] sessions in
				self?.reconcile(sessions: sessions)
			}
			.store(in: &cancellables)
	}

	/// Sessions のスナップショットから companions を再構成。
	/// active session に bind された pane ごとに companion を生成 / 更新し、それ以外は削除。
	/// paneId は `AgentSessionStore.panes(forSession:)` (小文字保持) を canonical (大文字)
	/// に正規化して webview identifier / avatar キーと揃える。
	private func reconcile(sessions: [AgentSession]) {
		guard let agentSessionStore else { return }

		// active session に bind された canonical paneId → その session。
		var desired: [String: AgentSession] = [:]
		for session in sessions where isActive(session) {
			for rawPane in agentSessionStore.panes(forSession: session.id) {
				guard let paneId = UUID(uuidString: rawPane)?.uuidString else { continue }
				desired[paneId] = session
			}
		}
		let desiredPaneIds = Set(desired.keys)

		// 既存 companion のうち、対応 pane が active session に無くなったら削除。
		// isArchived / sessionEnd / idle の session は isActive=false → desired から
		// 抜けるので、ここで確実に avatar が消える (sidebar dismiss = archive の反映)。
		// done は active のまま残り、完了バブルを表示し続ける。
		for paneId in companions.keys where !desiredPaneIds.contains(paneId) {
			companions.removeValue(forKey: paneId)
			selectedPaneIds.remove(paneId)
			manuallyDismissed.remove(paneId)
			messageHistory.removeValue(forKey: paneId)
			lastMessageText.removeValue(forKey: paneId)
			lastSeenPrompt.removeValue(forKey: paneId)
		}

		// active pane に対応する companion が無ければ追加 / 既存は更新。
		for (paneId, session) in desired {
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
			let currentPrompt = session.state.lastUserPrompt ?? ""
			if !currentPrompt.isEmpty && currentPrompt != lastSeenPrompt[paneId] {
				lastSeenPrompt[paneId] = currentPrompt
				messageHistory.removeValue(forKey: paneId)
				lastMessageText.removeValue(forKey: paneId)
			}

			// Bubble-worthy message: transcript 由来 agent 発話 / result / waiting 等。
			// Replay warm-up 中は skip。Dedup は consecutive only (= lastMessageText)。
			// warm-up 判定は transport/通知の関心なので NotificationStore に残す。
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
				status: session.state.status,
				avatarStyle: style,
				userPrompt: session.state.lastUserPrompt ?? session.name,
				messages: messageHistory[paneId] ?? [],
				currentTool: currentToolText(for: session)
			)
			companions[paneId] = snapshot
		}
		// Dock panel + status bar の表示 / 非表示を更新
		AgentStatusBarWindowManager.shared.updateStatusBar(hasCompanions: !companions.isEmpty)
	}

	/// companion を出さない (dismiss する) 終端状態。session が sessionEnd / idle に落ちるか
	/// archived になった時点で avatar を消す。done は「完了バブル」を表示するため **active
	/// のまま** 維持し、session が真に終了 (sessionEnd/idle) するまで残す。
	private static let inactiveStatuses: Set<AgentStatus> = [.sessionEnd, .idle]

	private func isActive(_ session: AgentSession) -> Bool {
		!session.isArchived && !Self.inactiveStatuses.contains(session.state.status)
	}

	/// Bubble として追加すべきテキスト。Agent の行動・発話を可視化する:
	/// - tool 実行 (= 何をしようとしているか)
	/// - speech (= transcript 由来の中間発話・思考)
	/// - waiting message (= ユーザーへの問いかけ)
	/// - result summary (= 何をやったか)
	/// User prompt は header 固定表示なので bubble には出さない。
	private func bubbleWorthyText(for session: AgentSession) -> String? {
		let status = session.state.status
		let msg = session.state.message
		// Blocked (= agent がユーザーに聞いてる) → 最も重要な bubble
		if status == .blocked { return msg }
		// Done の最終応答
		if status == .done, !msg.isEmpty, msg != "Done" {
			return msg
		}
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
		// User prompt / name と同じテキストは bubble に出さない (= header で既に表示)
		if msg == session.state.lastUserPrompt || msg == session.name { return nil }
		if msg.hasPrefix("subagent-done:") { return nil }
		if ["Generating", "started", "ended", "Done", "Ready"].contains(msg) { return nil }
		if msg.isEmpty { return nil }
		// それ以外 → bubble
		return msg
	}

	/// 現在実行中の tool を小さいインライン表示用テキストにする。
	private func currentToolText(for session: AgentSession) -> String? {
		guard let tool = session.state.currentTool, !tool.isEmpty else { return nil }
		if let activity = session.state.lastActivity, !activity.isEmpty {
			return "\(tool): \(activity)"
		}
		return tool
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
