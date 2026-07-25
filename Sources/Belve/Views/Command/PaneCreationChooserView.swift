import SwiftUI

/// ペイン追加時に表示するチューザ。
/// - 上段: 新規セッション名の入力 (デフォルト候補入り・編集可)。Enter で即作成。
/// - 下段: 既存セッションへの attach。「このプロジェクト」と「他のプロジェクト」で
///   グルーピング。既に開いている (= どこかの pane が使用中の) セッションは除外する。
///
/// キーボードだけで完結できる: ↑/↓ で名前欄⇄一覧を移動、Enter で確定
/// (名前欄なら新規作成 / 行なら attach)、Esc で閉じる。各行の 🗑 で削除。
struct PaneCreationChooserView: View {
	let project: Project
	/// projShort → プロジェクト名。「他のプロジェクト」行の表示名解決に使う。
	let projectNamesByShort: [String: String]
	/// 名前欄の初期候補。
	let defaultName: String
	/// 既に pane で開いているセッション名。アタッチ候補から除外する。
	let inUseNames: Set<String>
	/// リモートプロジェクトの ssh host。nil = ローカル。set 時はこの host の
	/// tmux セッションを列挙し、attach は tmux セッション名で行う。
	let remoteHost: String?
	let onCreateNew: (String) -> Void
	/// アタッチ確定。ローカルは socket、リモートは tmux 名で解決するため
	/// SessionInfo を渡し、呼び出し側 (MainWindow) が remote/local を分岐する。
	let onAttach: (MasterClient.SessionInfo) -> Void
	let onDismiss: () -> Void

	private var isRemote: Bool { remoteHost != nil }

	@State private var name: String
	@State private var sessions: [MasterClient.SessionInfo] = []
	@State private var isLoading = true
	@State private var error: String?
	/// -1 = 名前欄, 0.. = navigableSessions のインデックス。
	@State private var selectedIndex: Int = -1
	/// リネーム中のセッション名 (nil = リネームしていない)。
	@State private var renamingName: String?
	@State private var renameText: String = ""
	@FocusState private var nameFocused: Bool
	@FocusState private var renameFocused: Bool
	/// 選択中 remote セッションの画面プレビュー (tmux capture-pane)。session名→内容 でキャッシュ。
	@State private var previewCache: [String: String] = [:]
	@State private var previewLoading = false
	/// プレビュー取得に失敗した session名 (失敗はキャッシュせず、この名前で error 表示)。
	@State private var previewError: String?

	init(
		project: Project,
		projectNamesByShort: [String: String],
		defaultName: String,
		inUseNames: Set<String>,
		remoteHost: String?,
		onCreateNew: @escaping (String) -> Void,
		onAttach: @escaping (MasterClient.SessionInfo) -> Void,
		onDismiss: @escaping () -> Void
	) {
		self.project = project
		self.projectNamesByShort = projectNamesByShort
		self.defaultName = defaultName
		self.inUseNames = inUseNames
		self.remoteHost = remoteHost
		self.onCreateNew = onCreateNew
		self.onAttach = onAttach
		self.onDismiss = onDismiss
		_name = State(initialValue: defaultName)
	}

	private var projShort: String {
		String(project.id.uuidString.prefix(8))
	}

	private func sortRule(_ a: MasterClient.SessionInfo, _ b: MasterClient.SessionInfo) -> Bool {
		a.modTime > b.modTime
	}

	/// アタッチ候補。ローカルは alive かつ未使用のみ。リモート (tmux) は host 上の
	/// 全セッションをそのまま出す (全 tmux セッション対象という方針)。
	private var attachable: [MasterClient.SessionInfo] {
		// remote は最終アクティビティの新しい順。
		if isRemote { return sessions.sorted { ($0.activity ?? 0) > ($1.activity ?? 0) } }
		return sessions.filter { $0.alive && !inUseNames.contains($0.name) }
	}

	/// リモート: host の全セッション (単一グループ)。
	private var hostSessions: [MasterClient.SessionInfo] { attachable }

	private var currentProjectSessions: [MasterClient.SessionInfo] {
		attachable.filter { $0.name.contains(projShort) }.sorted(by: sortRule)
	}

	private var otherProjectSessions: [MasterClient.SessionInfo] {
		attachable.filter { !$0.name.contains(projShort) }.sorted(by: sortRule)
	}

	/// キーボードで辿れる行の並び (グループ順に flatten)。selectedIndex はこの配列に対応。
	private var navigableSessions: [MasterClient.SessionInfo] {
		isRemote ? hostSessions : currentProjectSessions + otherProjectSessions
	}

	/// 現在キーボード選択中の remote セッション (プレビュー対象)。
	private var selectedRemoteSession: MasterClient.SessionInfo? {
		guard isRemote, selectedIndex >= 0, selectedIndex < navigableSessions.count else { return nil }
		return navigableSessions[selectedIndex]
	}

	var body: some View {
		HStack(spacing: 0) {
			VStack(spacing: 0) {
				header
				Divider().overlay(Theme.border)
				newSessionField
				Divider().overlay(Theme.borderSubtle.opacity(0.5))
				attachSection
			}
			.frame(width: 480)
			if isRemote {
				Divider().overlay(Theme.border)
				previewPane.frame(width: 460)
			}
		}
		.frame(width: isRemote ? 940 : 480, height: 440)
		.task(id: selectedRemoteSession?.name) { await loadPreview() }
		.background(Theme.surface)
		.cornerRadius(Theme.radiusLg)
		.overlay(
			RoundedRectangle(cornerRadius: Theme.radiusLg)
				.stroke(Theme.border, lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.34), radius: 18, y: 8)
		.onAppear {
			loadSessions()
			// 名前欄のフォーカスは常時保持する。フォーカスを外すと矢印キーが
			// .onKeyPress へ bubble しなくなり、連続移動できなくなるため
			// (選択のハイライトは selectedIndex だけで表現する)。
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { nameFocused = true }
		}
		.onKeyPress(.upArrow) { if renamingName != nil { return .ignored }; moveSelection(-1); return .handled }
		.onKeyPress(.downArrow) { if renamingName != nil { return .ignored }; moveSelection(1); return .handled }
		.onKeyPress(.escape) {
			// リネーム中は Esc で編集キャンセル、そうでなければチューザを閉じる。
			if renamingName != nil { cancelRename() } else { onDismiss() }
			return .handled
		}
	}

	private var header: some View {
		HStack {
			VStack(alignment: .leading, spacing: 2) {
				Text("New Pane")
					.font(.system(size: 14, weight: .semibold))
					.foregroundStyle(Theme.textPrimary)
				Text(project.name)
					.font(.system(size: 11))
					.foregroundStyle(Theme.textSecondary)
			}
			Spacer()
			Button(action: onDismiss) {
				Image(systemName: "xmark")
					.font(.system(size: 10, weight: .medium))
					.foregroundStyle(Theme.textTertiary)
			}
			.buttonStyle(.plain)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
	}

	private var newSessionField: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("新規セッション")
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(Theme.textTertiary)
			HStack(spacing: 8) {
				TextField("セッション名 (空欄で自動)", text: $name)
					.textFieldStyle(.plain)
					.font(.system(size: 13))
					.foregroundStyle(Theme.textPrimary)
					.focused($nameFocused)
					// フォーカスは常に名前欄にあるので、Enter はここに一本化。
					// selectedIndex に応じて 新規作成 / 行アタッチ を分岐する。
					.onSubmit(confirmSelection)
					.padding(.horizontal, 10)
					.padding(.vertical, 7)
					.background(
						RoundedRectangle(cornerRadius: 6)
							.fill(Theme.bg)
					)
					.overlay(
						RoundedRectangle(cornerRadius: 6)
							.stroke(selectedIndex == -1 ? Theme.accent : Theme.border, lineWidth: 1)
					)
				Button("作成", action: submitNew)
					.buttonStyle(.plain)
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(Theme.accent)
					.padding(.horizontal, 12)
					.padding(.vertical, 7)
					.background(
						RoundedRectangle(cornerRadius: 6)
							.fill(Theme.accent.opacity(0.12))
					)
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
	}

	private var attachSection: some View {
		Group {
			if isLoading {
				centeredMessage { ProgressView().controlSize(.small); Text("セッションを読み込み中…") }
			} else if let error {
				centeredMessage {
					Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(Theme.textTertiary)
					Text(error).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
					Button("再試行") { loadSessions() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
				}
			} else if navigableSessions.isEmpty {
				centeredMessage {
					Image(systemName: "terminal").font(.system(size: 20)).foregroundStyle(Theme.textTertiary)
					Text("アタッチできる既存セッションはありません").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
				}
			} else if isRemote {
				ScrollViewReader { proxy in
					ScrollView {
						VStack(spacing: 0) {
							groupHeader("このホストのセッション")
							ForEach(Array(hostSessions.enumerated()), id: \.element.name) { offset, session in
								sessionRow(session, index: offset)
							}
						}
					}
					.onChange(of: selectedIndex) { _, i in followScroll(proxy, to: i) }
				}
			} else {
				ScrollViewReader { proxy in
				ScrollView {
					VStack(spacing: 0) {
						if !currentProjectSessions.isEmpty {
							groupHeader("このプロジェクト")
							ForEach(Array(currentProjectSessions.enumerated()), id: \.element.name) { offset, session in
								sessionRow(session, index: offset)
							}
						}
						if !otherProjectSessions.isEmpty {
							groupHeader("他のプロジェクト")
							ForEach(Array(otherProjectSessions.enumerated()), id: \.element.name) { offset, session in
								sessionRow(session, index: currentProjectSessions.count + offset)
							}
						}
					}
				}
				.onChange(of: selectedIndex) { _, i in followScroll(proxy, to: i) }
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	/// キーボード選択が画面外に出ないよう、選択行までスクロール追従する。
	private func followScroll(_ proxy: ScrollViewProxy, to index: Int) {
		guard index >= 0 else { return }
		withAnimation(.easeOut(duration: 0.12)) {
			proxy.scrollTo(index, anchor: .center)
		}
	}

	private func centeredMessage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
		VStack(spacing: 8, content: content)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private func groupHeader(_ title: String) -> some View {
		HStack {
			Text(title)
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(Theme.textTertiary)
			Spacer()
		}
		.padding(.horizontal, 16)
		.padding(.top, 12)
		.padding(.bottom, 4)
	}

	@ViewBuilder
	private func sessionRow(_ session: MasterClient.SessionInfo, index: Int) -> some View {
		if renamingName == session.name {
			renameRow(session).id(index)
		} else {
			normalRow(session, index: index).id(index)
		}
	}

	private func normalRow(_ session: MasterClient.SessionInfo, index: Int) -> some View {
		let selected = index == selectedIndex
		return HStack(spacing: 10) {
			Circle()
				.fill(isRemote ? (session.attached ? Theme.green : Theme.textTertiary) : Theme.green)
				.frame(width: 8, height: 8)
			VStack(alignment: .leading, spacing: 2) {
				Text(displayName(session))
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(Theme.textPrimary)
					.lineLimit(1)
				Text(subtitle(session))
					.font(.system(size: 9))
					.foregroundStyle(Theme.textTertiary)
					.lineLimit(1)
			}
			Spacer()
			Button("アタッチ") { onAttach(session) }
				.buttonStyle(.plain)
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(Theme.accent)
				.padding(.horizontal, 8)
				.padding(.vertical, 3)
				.background(RoundedRectangle(cornerRadius: 4).fill(Theme.accent.opacity(0.1)))
			// rename/delete はローカル belve-persist セッション用 op。リモート tmux
			// セッションには適用できないので remote では出さない。
			if !isRemote {
				Button(action: { beginRename(session) }) {
					Image(systemName: "pencil")
						.font(.system(size: 10))
						.foregroundStyle(Theme.textTertiary)
				}
				.buttonStyle(.plain)
				Button(action: { deleteSession(session.name) }) {
					Image(systemName: "trash")
						.font(.system(size: 10))
						.foregroundStyle(Theme.textTertiary)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
		.background(selected ? Theme.surfaceSelected : Color.clear)
		.contentShape(Rectangle())
		.onTapGesture { selectedIndex = index }
	}

	/// リネーム編集中の行。`belve-<shortId>-` prefix は固定し、token 部分だけ編集させる。
	private func renameRow(_ session: MasterClient.SessionInfo) -> some View {
		HStack(spacing: 6) {
			if let prefix = renamePrefix(session.name) {
				Text(prefix)
					.font(.system(size: 10))
					.foregroundStyle(Theme.textTertiary)
			}
			TextField("名前", text: $renameText)
				.textFieldStyle(.plain)
				.font(.system(size: 12))
				.foregroundStyle(Theme.textPrimary)
				.focused($renameFocused)
				.onSubmit(commitRename)
				.padding(.horizontal, 8)
				.padding(.vertical, 5)
				.background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg))
				.overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.accent, lineWidth: 1))
			Button("保存", action: commitRename)
				.buttonStyle(.plain)
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(Theme.accent)
			Button(action: cancelRename) {
				Image(systemName: "xmark")
					.font(.system(size: 10))
					.foregroundStyle(Theme.textTertiary)
			}
			.buttonStyle(.plain)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
	}

	/// 他プロジェクトのセッションは projShort からプロジェクト名を引いて見やすく表示。
	private func displayName(_ session: MasterClient.SessionInfo) -> String {
		let parts = session.name.split(separator: "-")
		guard parts.count >= 3 else { return session.name }
		let shortId = String(parts[1])
		let token = parts[2...].joined(separator: "-")
		if let projName = projectNamesByShort[shortId] {
			return "\(projName) / \(token)"
		}
		return session.name
	}

	/// 行の 2 段目。remote は `1:claude · 25秒前 · 接続中` 風、local は生セッション名。
	private func subtitle(_ session: MasterClient.SessionInfo) -> String {
		guard isRemote else { return session.name }
		var parts: [String] = []
		// belve フックが書いた agent 状態 (@belve_state) があれば先頭に。
		if !session.agentState.isEmpty {
			parts.append(agentStateLabel(session.agentState))
		}
		let cmd = session.command.isEmpty ? "" : ":\(session.command)"
		parts.append("\(session.windows)\(cmd)")
		if let rel = relativeActivity(session.activity) {
			parts.append(rel)
		}
		if session.attached {
			parts.append("接続中")
		}
		// agent の最新メッセージ (今なにをしているか) を末尾に短く。
		if !session.agentMsg.isEmpty {
			parts.append(String(session.agentMsg.prefix(40)))
		}
		return parts.joined(separator: " · ")
	}

	private func agentStateLabel(_ state: String) -> String {
		switch state {
		case "running": return "▶ 実行中"
		case "waiting": return "⏸ 入力待ち"
		case "completed", "done": return "✓ 完了"
		default: return state
		}
	}

	private static let relativeFormatter: RelativeDateTimeFormatter = {
		let f = RelativeDateTimeFormatter()
		f.unitsStyle = .short
		return f
	}()

	/// epoch 秒 → "25秒前" / "3分前" 等。remote server の epoch を Mac の時計基準で
	/// 比較するため、両者の NTP ズレぶんだけ誤差が乗りうる (表示用途なので許容)。
	private func relativeActivity(_ epoch: TimeInterval?) -> String? {
		guard let epoch else { return nil }
		return Self.relativeFormatter.localizedString(for: Date(timeIntervalSince1970: epoch), relativeTo: Date())
	}

	// MARK: - Preview (remote 画面キャプチャ)

	private var previewPane: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 6) {
				Text(selectedRemoteSession.map(displayName) ?? "プレビュー")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(Theme.textSecondary)
					.lineLimit(1)
				if previewLoading { ProgressView().controlSize(.mini) }
				Spacer()
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 10)
			Divider().overlay(Theme.borderSubtle)
			if let session = selectedRemoteSession, let content = previewCache[session.name] {
				ScrollView([.vertical, .horizontal]) {
					Text(content.isEmpty ? "(空の画面)" : content)
						.font(.system(size: 8, design: .monospaced))
						.foregroundStyle(Theme.textPrimary)
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(10)
				}
			} else if let session = selectedRemoteSession, previewError == session.name {
				VStack(spacing: 8) {
					Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(Theme.textTertiary)
					Text("プレビュー取得に失敗").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
					Button("再試行", action: retryPreview).buttonStyle(.plain).foregroundStyle(Theme.accent)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				VStack {
					Text(selectedRemoteSession == nil ? "セッションを選ぶと画面プレビュー" : "読み込み中…")
						.font(.system(size: 11))
						.foregroundStyle(Theme.textTertiary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.frame(maxHeight: .infinity)
		.background(Theme.bg)
	}

	/// 選択中 remote セッションの画面を capture-pane で取得 (200ms デバウンス、
	/// キャッシュ済みは再取得しない)。`.task(id:)` が選択変更で自動キャンセルする。
	private func loadPreview() async {
		guard let host = remoteHost, let session = selectedRemoteSession else { return }
		if previewCache[session.name] != nil { return }
		do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
		previewLoading = true
		previewError = nil
		defer { previewLoading = false }
		do {
			// 成功時のみキャッシュ。失敗/キャンセルは残さず再取得余地を残す
			// (空文字を焼くと "(空の画面)" が固着するため)。
			previewCache[session.name] = try await MasterClient.shared.captureRemotePane(host: host, session: session.name)
		} catch is CancellationError {
			// 選択変更でキャンセル: 何もしない。
		} catch {
			previewError = session.name
		}
	}

	private func retryPreview() {
		guard let session = selectedRemoteSession else { return }
		previewError = nil
		previewCache[session.name] = nil
		Task { await loadPreview() }
	}

	// MARK: - Rename

	/// `belve-<shortId>-<token>` の shortId 部分。パターン外なら nil。
	private func shortId(of name: String) -> String? {
		let parts = name.split(separator: "-")
		guard parts.count >= 3, parts[0] == "belve" else { return nil }
		return String(parts[1])
	}

	/// リネーム行に固定表示する `belve-<shortId>-` prefix。パターン外なら nil。
	private func renamePrefix(_ name: String) -> String? {
		shortId(of: name).map { "belve-\($0)-" }
	}

	/// 編集対象の token 部分 (prefix を除いた末尾)。パターン外なら名前全体。
	private func renameToken(_ name: String) -> String {
		let parts = name.split(separator: "-")
		guard parts.count >= 3, parts[0] == "belve" else { return name }
		return parts[2...].joined(separator: "-")
	}

	private func beginRename(_ session: MasterClient.SessionInfo) {
		renamingName = session.name
		renameText = renameToken(session.name)
		nameFocused = false
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { renameFocused = true }
	}

	private func cancelRename() {
		renamingName = nil
		renameFocused = false
		nameFocused = true
	}

	private func commitRename() {
		guard let old = renamingName else { return }
		guard let token = PaneSessionNaming.sanitizedToken(renameText) else { cancelRename(); return }
		let newName = shortId(of: old).map { "belve-\($0)-\(token)" } ?? token
		guard newName != old else { cancelRename(); return }
		Task { @MainActor in
			renamingName = nil
			renameFocused = false
			nameFocused = true
			do {
				try await MasterClient.shared.renameSession(from: old, to: newName)
				loadSessions() // 成功時のみ再読込 (loadSessions が error=nil を立てるため)
			} catch {
				// 失敗時は再読込せずエラーを残す (名前は変わっていない)。
				self.error = "リネームに失敗しました: \(error.localizedDescription)"
			}
		}
	}

	// MARK: - Keyboard

	private func moveSelection(_ delta: Int) {
		let maxIndex = navigableSessions.count - 1
		selectedIndex = max(-1, min(maxIndex, selectedIndex + delta))
	}

	private func confirmSelection() {
		if selectedIndex == -1 {
			submitNew()
		} else if selectedIndex < navigableSessions.count {
			onAttach(navigableSessions[selectedIndex])
		}
	}

	private func submitNew() {
		onCreateNew(name.trimmingCharacters(in: .whitespaces))
	}

	// MARK: - Data

	private func loadSessions() {
		// @MainActor Task: 前後の @State 更新は全て main で行う (await 後の再開も main)。
		Task { @MainActor in
			isLoading = true
			error = nil
			do {
				if let host = remoteHost {
					sessions = try await MasterClient.shared.listRemoteSessions(host: host)
				} else {
					sessions = try await MasterClient.shared.listSessions()
				}
			} catch {
				self.error = error.localizedDescription
			}
			isLoading = false
		}
	}

	private func deleteSession(_ name: String) {
		Task { @MainActor in
			do {
				try await MasterClient.shared.killSession(name: name)
				loadSessions() // 成功時のみ再読込 (loadSessions が error=nil を立てるため)
			} catch {
				self.error = "削除に失敗しました: \(error.localizedDescription)"
			}
		}
	}
}
