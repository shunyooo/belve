import SwiftUI

/// ペイン追加時に表示するチューザ。
/// - 上段: 新規セッション名の入力 (デフォルト候補入り・編集可)。Enter で即作成。
/// - 下段: 既存セッションへの attach。「このプロジェクト」と「他のプロジェクト」で
///   グルーピングして一覧する。
///
/// 何も選ばず新規名で確定するのが既定動作 (= セッションの無秩序な増殖を避け、
/// 名前を付けて意図的に作る / 既存に相乗りする、をユーザーが選べるようにする)。
struct PaneCreationChooserView: View {
	let project: Project
	/// projShort → プロジェクト名。「他のプロジェクト」行の表示名解決に使う。
	let projectNamesByShort: [String: String]
	/// 名前欄の初期候補。
	let defaultName: String
	let onCreateNew: (String) -> Void
	let onAttach: (String) -> Void
	let onDismiss: () -> Void

	@State private var name: String
	@State private var sessions: [MasterClient.SessionInfo] = []
	@State private var isLoading = true
	@State private var error: String?
	@FocusState private var nameFocused: Bool

	init(
		project: Project,
		projectNamesByShort: [String: String],
		defaultName: String,
		onCreateNew: @escaping (String) -> Void,
		onAttach: @escaping (String) -> Void,
		onDismiss: @escaping () -> Void
	) {
		self.project = project
		self.projectNamesByShort = projectNamesByShort
		self.defaultName = defaultName
		self.onCreateNew = onCreateNew
		self.onAttach = onAttach
		self.onDismiss = onDismiss
		_name = State(initialValue: defaultName)
	}

	private var projShort: String {
		String(project.id.uuidString.prefix(8))
	}

	/// このプロジェクトのセッション (alive 優先, modTime 降順)。
	private var currentProjectSessions: [MasterClient.SessionInfo] {
		sessions.filter { $0.name.contains(projShort) }.sorted(by: sortRule)
	}

	/// 他プロジェクトのセッション。
	private var otherProjectSessions: [MasterClient.SessionInfo] {
		sessions.filter { !$0.name.contains(projShort) }.sorted(by: sortRule)
	}

	private func sortRule(_ a: MasterClient.SessionInfo, _ b: MasterClient.SessionInfo) -> Bool {
		if a.alive != b.alive { return a.alive }
		return a.modTime > b.modTime
	}

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider().overlay(Theme.border)
			newSessionField
			Divider().overlay(Theme.borderSubtle.opacity(0.5))
			attachSection
		}
		.frame(width: 480, height: 420)
		.background(Theme.surface)
		.cornerRadius(Theme.radiusLg)
		.overlay(
			RoundedRectangle(cornerRadius: Theme.radiusLg)
				.stroke(Theme.border, lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.34), radius: 18, y: 8)
		.onAppear {
			loadSessions()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { nameFocused = true }
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
					.onSubmit(submitNew)
					.padding(.horizontal, 10)
					.padding(.vertical, 7)
					.background(
						RoundedRectangle(cornerRadius: 6)
							.fill(Theme.bg)
					)
					.overlay(
						RoundedRectangle(cornerRadius: 6)
							.stroke(nameFocused ? Theme.accent : Theme.border, lineWidth: 1)
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
			} else if currentProjectSessions.isEmpty && otherProjectSessions.isEmpty {
				centeredMessage {
					Image(systemName: "terminal").font(.system(size: 20)).foregroundStyle(Theme.textTertiary)
					Text("アタッチできる既存セッションはありません").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
				}
			} else {
				ScrollView {
					VStack(spacing: 0) {
						if !currentProjectSessions.isEmpty {
							groupHeader("このプロジェクト")
							ForEach(currentProjectSessions, id: \.name) { sessionRow($0) }
						}
						if !otherProjectSessions.isEmpty {
							groupHeader("他のプロジェクト")
							ForEach(otherProjectSessions, id: \.name) { sessionRow($0) }
						}
					}
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
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

	private func sessionRow(_ session: MasterClient.SessionInfo) -> some View {
		HStack(spacing: 10) {
			Circle()
				.fill(session.alive ? Theme.green : Theme.textTertiary)
				.frame(width: 8, height: 8)
			VStack(alignment: .leading, spacing: 2) {
				Text(displayName(session))
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(Theme.textPrimary)
					.lineLimit(1)
				Text(session.name)
					.font(.system(size: 9))
					.foregroundStyle(Theme.textTertiary)
					.lineLimit(1)
			}
			Spacer()
			if session.alive {
				Button("アタッチ") { onAttach(session.socket) }
					.buttonStyle(.plain)
					.font(.system(size: 11, weight: .medium))
					.foregroundStyle(Theme.accent)
					.padding(.horizontal, 8)
					.padding(.vertical, 3)
					.background(RoundedRectangle(cornerRadius: 4).fill(Theme.accent.opacity(0.1)))
			} else {
				Text("停止中").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
			}
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

	private func submitNew() {
		onCreateNew(name.trimmingCharacters(in: .whitespaces))
	}

	private func loadSessions() {
		isLoading = true
		error = nil
		Task {
			do {
				let result = try await MasterClient.shared.listSessions()
				await MainActor.run {
					sessions = result
					isLoading = false
				}
			} catch {
				await MainActor.run {
					self.error = error.localizedDescription
					isLoading = false
				}
			}
		}
	}
}
