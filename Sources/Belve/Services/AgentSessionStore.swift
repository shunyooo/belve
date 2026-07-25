import Combine
import Foundation

/// 統合エージェントセッション実体の唯一の所有者。
///
/// SessionKey (= tmux セッション名 = `AgentSession.id`) をキーに、project→sessions、
/// 状態更新、永続化、トリアージ集約を担う。OSC プロデューサ経路 (端で paneId→SessionKey
/// 解決) から `updateState(sessionKey:...)` を通じて供給される。
///
/// `docs/notes/2026-07-23-unified-agent-session.md` の契約に基づく。identity/状態は
/// 旧 `NotificationStore` から本ストアへ移る (consumer 移行は別 unit)。
final class AgentSessionStore: ObservableObject {
	/// セッション配列。**backing store は常に同期的に最新**であり、読み取り
	/// (`session(for:)` 等) は常に確定値を返す。SwiftUI / companion への「通知」だけ
	/// を coalescing する (下記 publishNow / publishCoalesced 参照)。@Published にすると
	/// mutate ごとに強制的に objectWillChange が飛び高頻度 OSC で SwiftUI が thrash する
	/// ため、通知は手動制御する。
	private(set) var sessions: [AgentSession] = []

	/// セッションスナップショットの value ストリーム。companion 等の値ベース購読者向け。
	/// status 変化は即時、非 status churn (message/tool/activity) は ~200ms debounce で emit。
	private let sessionsSubject = CurrentValueSubject<[AgentSession], Never>([])
	var sessionsPublisher: AnyPublisher<[AgentSession], Never> {
		sessionsSubject.eraseToAnyPublisher()
	}

	/// pane (paneId) → SessionKey の揮発 binding。**永続化しない**。
	/// paneId は再起動で変わるので model / disk には載せず、OSC 端が bind し直す。
	/// key は小文字化して保持 (sidebar の paneIdsForView が小文字 UUID 文字列を
	/// 返すのに合わせる)。@Published にして binding 変化で sidebar を再 render。
	@Published private var paneBindings: [String: String] = [:]

	// MARK: - Lookups

	func session(for key: String) -> AgentSession? {
		sessions.first { $0.id == key }
	}

	// MARK: - Pane binding (volatile, non-persisted)

	/// pane を SessionKey に bind する。OSC 端が paneId と実 tmux セッション名の
	/// 両方を知っている時に呼ぶ。paneId は小文字化して記録する。
	func bind(paneId: String, sessionKey: String) {
		let key = paneId.lowercased()
		// idempotent re-bind (OSC 端が event 毎に無条件で呼ぶ) は mutate も publish も
		// しない。@Published dict の再代入は毎回 objectWillChange を飛ばし、publish
		// coalescing を無効化して sidebar/tile/BottomBar を OSC 頻度で re-render する。
		guard paneBindings[key] != sessionKey else { return }
		paneBindings[key] = sessionKey
	}

	/// pane の binding を解除する (pane close 時)。
	func unbind(paneId: String) {
		paneBindings.removeValue(forKey: paneId.lowercased())
	}

	/// pane に bind された SessionKey を引く。
	func sessionKey(forPane paneId: String) -> String? {
		paneBindings[paneId.lowercased()]
	}

	/// SessionKey に bind された pane 群 (小文字 paneId)。逆引き。
	func panes(forSession sessionKey: String) -> [String] {
		paneBindings.compactMap { $0.value == sessionKey ? $0.key : nil }
	}

	/// 指定 project の非 archive セッション。updatedAt 降順 (recency)。
	func sessions(forProject projectId: UUID) -> [AgentSession] {
		sessions
			.filter { $0.projectId == projectId && !$0.isArchived }
			.sorted { $0.updatedAt > $1.updatedAt }
	}

	// MARK: - Triage rollup

	/// 要対応順: blocked → working → done → idle。
	/// (sessionStart は working 群、sessionEnd は idle 群として扱う)
	func triageOrdered(forProject projectId: UUID) -> [AgentSession] {
		sessions(forProject: projectId).sorted { a, b in
			let ra = Self.triageRank(a.state.status)
			let rb = Self.triageRank(b.state.status)
			if ra != rb { return ra < rb }
			return a.updatedAt > b.updatedAt
		}
	}

	/// 要対応 (blocked) 数。
	func attentionCount(forProject projectId: UUID) -> Int {
		sessions(forProject: projectId).filter { $0.state.status == .blocked }.count
	}

	/// 作業中数 (working / runningSubagent / sessionStart を作業中群として集計)。
	func workingCount(forProject projectId: UUID) -> Int {
		sessions(forProject: projectId).filter {
			switch $0.state.status {
			case .working, .runningSubagent, .sessionStart: return true
			default: return false
			}
		}.count
	}

	/// project の非 archive セッションのうち最も severe な status。
	/// 重篤度: blocked > working/runningSubagent/sessionStart > done > idle/sessionEnd。
	/// セッションが無ければ nil。project row の status dot に使う。
	func rollupStatus(forProject projectId: UUID) -> AgentStatus? {
		sessions(forProject: projectId)
			.min { Self.triageRank($0.state.status) < Self.triageRank($1.state.status) }?
			.state.status
	}

	// MARK: - Archive

	/// SessionKey のセッションを archive (sidebar から dismiss)。存在しなければ no-op。
	func archive(sessionKey: String) {
		guard let idx = sessions.firstIndex(where: { $0.id == sessionKey }) else { return }
		sessions[idx].isArchived = true
		save()
		// 可視性の変化 (sidebar / companion から消える) → 即時 publish。
		publishNow()
	}

	private static func triageRank(_ status: AgentStatus) -> Int {
		switch status {
		case .blocked: return 0
		case .working, .runningSubagent, .sessionStart: return 1  // working-ish
		case .done: return 2
		case .idle, .sessionEnd: return 3
		}
	}

	// MARK: - State update (OSC edge entry point)

	/// OSC 経路の状態更新エントリポイント。旧 `NotificationStore.updateAgentStatus` の
	/// per-session 遷移ロジックを SessionKey ベースに移植したもの (通知/desktop 系は除く)。
	///
	/// - `hookStatus`: 旧 hook 語彙 (running/waiting/completed/session_start/…)。
	/// - `message`: 生の OSC payload。内部で `AgentMessageSanitizer` で整形する。
	func updateState(
		sessionKey: String,
		projectId: UUID,
		hookStatus: String,
		message rawMessage: String,
		sessionOrigin: SessionOrigin = .launched
	) {
		let message = AgentMessageSanitizer.sanitize(rawMessage)
		// canonical / legacy 双方を受理する (NotificationStore.updateAgentStatus と同じ語彙)。
		// hook が将来 canonical 語彙を出しても silently drop しないため。
		guard let status = AgentStatus(rawValue: hookStatus) else { return }

		NSLog("[Belve][session] %@ - %@ (key: %@)", hookStatus, message, sessionKey)

		switch status {
		case .sessionStart:
			if let idx = sessions.firstIndex(where: { $0.id == sessionKey }) {
				// reload / 再起動ケース: identity を保持したまま state を初期化。
				sessions[idx].state = AgentState(status: .sessionStart, message: message)
				sessions[idx].origin = sessionOrigin
				sessions[idx].isArchived = false
				sessions[idx].updatedAt = Date()
				save()
			} else {
				let session = AgentSession(
					id: sessionKey,
					projectId: projectId,
					name: "",
					state: AgentState(status: .sessionStart, message: message),
					origin: sessionOrigin,
					startedAt: Date(),
					updatedAt: Date()
				)
				sessions.insert(session, at: 0)
				// 長時間稼働でメモリが無限に膨らまないよう、save()/load() と同じ 50 件
				// cap を in-memory 配列にも即適用 (最古から drop)。
				if sessions.count > 50 {
					sessions = Array(sessions.prefix(50))
				}
				save()
			}
			// create / reset は identity・可視性の変化 → 即時 publish。
			publishNow()

		case .working:
			mutate(sessionKey) { session in
				// Subagent event は child-agent lifecycle。parent の status は変えない
				// (SubagentStop が .blocked/.done を .working に戻して stuck する事故防止)。
				let isSubagentEvent = message.hasPrefix("subagent:") || message.hasPrefix("subagent-done:")
				let isSpeechEvent = message.hasPrefix("speech:")
				let isBackgroundEvent = message.hasPrefix("background:")
				if !isSubagentEvent {
					session.state.status = .working
					session.state.message = message
				}
				// 最初の user prompt を name として捕捉 (speech/tool/lifecycle/background は除外)。
				if session.name.isEmpty
					&& !message.hasPrefix("tool:")
					&& !message.hasPrefix("result:")
					&& !message.hasPrefix("subagent")
					&& !isSpeechEvent
					&& !isBackgroundEvent
					&& message != "Generating" {
					session.name = message
				}
				// 構造化メッセージの parse。
				if message.hasPrefix("tool:") {
					let detail = String(message.dropFirst(5))
					let parts = detail.split(separator: ":", maxSplits: 1)
					session.state.currentTool = String(parts.first ?? "")
					session.state.lastActivity = parts.count > 1 ? String(parts[1]) : nil
				} else if message.hasPrefix("result:") {
					let detail = String(message.dropFirst(7))
					let parts = detail.split(separator: ":", maxSplits: 1)
					session.state.lastActivity = parts.count > 1 ? String(parts[1]).prefix(80).description : nil
					// currentTool は次 tool / 完了まで残す。
				} else if message.hasPrefix("subagent:") {
					session.state.currentTool = "Agent"
					session.state.lastActivity = String(message.dropFirst(9))
					session.state.subagentCount += 1
				} else if message.hasPrefix("subagent-done:") {
					session.state.subagentCount = max(0, session.state.subagentCount - 1)
					// parent が active な時だけ tool を clear。
					if session.state.status == .working || session.state.status == .sessionStart {
						session.state.currentTool = nil
					}
				} else if isSpeechEvent {
					// speech: は agent 中間発話。lastUserPrompt / tool / activity は触らない。
				} else if isBackgroundEvent {
					session.state.currentTool = "Background"
					session.state.lastActivity = String(message.dropFirst("background:".count))
				} else if message != "Generating" {
					session.state.lastUserPrompt = message
					session.state.currentTool = nil
					session.state.lastActivity = nil
				}
			}

		case .blocked:
			mutate(sessionKey) { session in
				session.state.status = .blocked
				session.state.message = message
				session.state.currentTool = nil
			}

		case .done:
			mutate(sessionKey) { session in
				session.state.status = .done
				session.state.message = message
				if message != "Done" {
					session.state.lastActivity = message
				}
				session.state.currentTool = nil
			}

		case .sessionEnd:
			mutate(sessionKey) { session in
				// completed イベントを取り逃していたら "Done" メッセージだけ補完してから終了。
				if session.state.status == .working
					|| session.state.status == .blocked
					|| session.state.status == .sessionStart {
					if session.state.lastActivity == nil {
						session.state.message = "Done"
					}
				}
				// 削除はしない (durable)。sidebar が引き続き表示できるよう sessionEnd に落とす。
				session.state.status = .sessionEnd
				session.state.currentTool = nil
			}

		case .idle:
			mutate(sessionKey) { session in
				session.state.status = .idle
			}

		case .runningSubagent:
			// hook event 由来では来ない (派生表示状態)。網羅性のための case。
			break
		}
	}

	// MARK: - Discovered session merge (discovery source entry point)

	/// discovered セッション (`SessionDiscoveryService.discover` の結果) を取り込む。
	/// OSC 経路を持たない生 tmux セッションを sidebar に浮上させるための独立ソース供給点で
	/// あり、OSC 経路 (`updateState`) の fallback ではない。
	///
	/// PRECEDENCE (OSC が権威):
	/// 1. 未知の SessionKey → `origin: .discovered` で新規挿入 (粗い status)。
	/// 2. 既存 `.launched` (OSC 追跡中) → **state を上書きしない**。OSC が権威なので touch しない。
	/// 3. 既存 `.discovered` → 粗い status / updatedAt を更新 (discovery が所有し続ける)。
	/// 4. この project の既存 `.discovered` で今回の discovered 一覧に **居ない** もの
	///    → tmux が消えたとみなし `.sessionEnd` に落とす。これは silent fallback ではなく
	///    **明示的な状態遷移** (契約の no-fallback 原則)。`.launched` は absence では touch
	///    しない (OSC / edge がライフサイクルを所有)。
	func mergeDiscovered(_ discovered: [DiscoveredSession], projectId: UUID) {
		let discoveredKeys = Set(discovered.map { $0.sessionKey })
		var statusChanged = false
		var mutated = false

		// (1)-(3): 発見された各セッションを取り込む。
		for entry in discovered {
			if let idx = sessions.firstIndex(where: { $0.id == entry.sessionKey }) {
				// (2) OSC 追跡中の .launched は権威。state を一切上書きしない。
				if sessions[idx].origin == .launched { continue }
				// (3) discovery 所有の既存セッション → status / message を更新。
				if sessions[idx].state.status != entry.coarseStatus {
					sessions[idx].state.status = entry.coarseStatus
					statusChanged = true
				}
				if !entry.message.isEmpty, sessions[idx].state.message != entry.message {
					sessions[idx].state.message = entry.message
					statusChanged = true
				}
				sessions[idx].updatedAt = Date()
				mutated = true
			} else {
				// (1) 未知 → discovered として新規挿入。
				let session = AgentSession(
					id: entry.sessionKey,
					projectId: projectId,
					name: "",
					state: AgentState(status: entry.coarseStatus, message: entry.message),
					origin: .discovered
				)
				sessions.insert(session, at: 0)
				if sessions.count > 50 {
					sessions = Array(sessions.prefix(50))
				}
				statusChanged = true
				mutated = true
			}
		}

		// (4) この project の discovery 所有セッションで、今回発見されなかったもの →
		// tmux 消滅とみなし sessionEnd に落とす (既に sessionEnd / archive は除外)。
		for idx in sessions.indices {
			guard sessions[idx].projectId == projectId,
			      sessions[idx].origin == .discovered,
			      !sessions[idx].isArchived,
			      sessions[idx].state.status != .sessionEnd,
			      !discoveredKeys.contains(sessions[idx].id)
			else { continue }
			sessions[idx].state.status = .sessionEnd
			sessions[idx].state.currentTool = nil
			sessions[idx].updatedAt = Date()
			statusChanged = true
			mutated = true
		}

		guard mutated else { return }
		save()
		// status 変化 (insert / status 更新 / sessionEnd) は可視性が変わる → 即時 publish。
		// updatedAt bump だけの churn は coalesce。
		if statusChanged {
			publishNow()
		} else {
			publishCoalesced()
		}
	}

	/// SessionKey で既存セッションを in-place 更新。存在しなければ no-op
	/// (作成は sessionStart のみ)。updatedAt を bump し debounced save。
	/// status が変化したら即時 publish、非 status churn (message/tool/activity のみ) は
	/// coalesce する。
	private func mutate(_ sessionKey: String, _ update: (inout AgentSession) -> Void) {
		guard let idx = sessions.firstIndex(where: { $0.id == sessionKey }) else { return }
		let oldStatus = sessions[idx].state.status
		// OSC hook event を 1 つでも受けたら OSC がライフサイクルの権威。discovery 由来の
		// セッションを .launched に昇格し、discovery の absence-sweep (mergeDiscovered (4))
		// が OSC-active なセッションを取り違えて sessionEnd に落とすのを防ぐ。
		if sessions[idx].origin == .discovered {
			sessions[idx].origin = .launched
		}
		update(&sessions[idx])
		sessions[idx].updatedAt = Date()
		save()
		if sessions[idx].state.status != oldStatus {
			publishNow()
		} else {
			publishCoalesced()
		}
	}

	// MARK: - Publish coalescing

	/// 高頻度 OSC (tool:/result:/speech:) で SwiftUI / companion を thrash させないための
	/// 通知 coalescing。backing store (`sessions`) は常に同期更新済みなので、ここで制御する
	/// のは「観測者への通知タイミング」だけ。永続化 (`save()`) は別 debounce。
	private var pendingPublishTask: DispatchWorkItem?

	/// 即時 publish。保留中の coalesce を取り消し、確定した最新スナップショットを流す。
	/// status 変化・create/reset・archive など「見た目が変わる」変化で使う。
	private func publishNow() {
		pendingPublishTask?.cancel()
		pendingPublishTask = nil
		objectWillChange.send()
		sessionsSubject.send(sessions)
	}

	/// 非 status churn を ~200ms debounce で publish。連続する churn は最後の 1 発に畳まれ、
	/// fire 時点の backing store をそのまま流すため **最終状態は必ず publish される**
	/// (途中で status 変化が来れば publishNow が pending を取り消して即時に最新を流す)。
	private func publishCoalesced() {
		pendingPublishTask?.cancel()
		let task = DispatchWorkItem { [weak self] in
			guard let self else { return }
			self.pendingPublishTask = nil
			self.objectWillChange.send()
			self.sessionsSubject.send(self.sessions)
		}
		pendingPublishTask = task
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
	}

	// MARK: - Persistence

	private static var saveURL: URL {
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let belveDir = appSupport.appendingPathComponent("Belve")
		try? FileManager.default.createDirectory(at: belveDir, withIntermediateDirectories: true)
		return belveDir.appendingPathComponent("sessions.json")
	}

	func load() {
		clearOrphanedNotificationStoreFile()
		guard let data = try? Data(contentsOf: Self.saveURL),
			  var decoded = try? JSONDecoder().decode([AgentSession].self, from: data) else { return }
		// 再起動時は agent process の生死が不明。volatile な in-flight status
		// (working/blocked/sessionStart) は sessionStart placeholder に落とす
		// (旧 NotificationStore.loadSessions と同じ挙動)。
		for i in decoded.indices {
			let s = decoded[i].state.status
			if s == .working || s == .blocked || s == .sessionStart {
				decoded[i].state.status = .sessionStart
				decoded[i].state.currentTool = nil
			}
		}
		sessions = Array(decoded.prefix(50))
		publishNow()
	}

	/// 旧 `NotificationStore` が書いていた `agent-sessions.json` を一度だけ `.bak` に退避する。
	/// 契約 §4 のセーフティネット意図に沿う後始末。ただし **中身は移行しない**: 旧レコードは
	/// paneId-keyed の legacy `AgentSession` で、新 SessionKey identity へ綺麗に再キー付けできず
	/// (binding は揮発で load 時に存在しない)、かつ前回起動の死んだ agent の stale runtime state
	/// のため。よってファイル名変更のみ (best-effort、失敗は無視)。契約の文言 (中身の移行) からの
	/// 意図的な逸脱。
	private func clearOrphanedNotificationStoreFile() {
		let dir = Self.saveURL.deletingLastPathComponent()
		let orphan = dir.appendingPathComponent("agent-sessions.json")
		guard FileManager.default.fileExists(atPath: orphan.path) else { return }
		let backup = dir.appendingPathComponent("agent-sessions.json.bak")
		try? FileManager.default.removeItem(at: backup)
		try? FileManager.default.moveItem(at: orphan, to: backup)
	}

	private var pendingSaveTask: DispatchWorkItem?

	private func save() {
		pendingSaveTask?.cancel()
		let task = DispatchWorkItem { [weak self] in
			guard let self else { return }
			let toSave = Array(self.sessions.prefix(50))
			if let data = try? JSONEncoder().encode(toSave) {
				try? data.write(to: Self.saveURL)
			}
		}
		pendingSaveTask = task
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
	}
}
