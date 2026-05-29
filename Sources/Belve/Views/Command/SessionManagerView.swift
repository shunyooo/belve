import SwiftUI

struct SessionManagerView: View {
	let project: Project
	@State private var sessions: [MasterClient.SessionInfo] = []
	@State private var isLoading = true
	@State private var error: String?
	let onAttach: (String) -> Void
	let onDismiss: () -> Void

	private var projShort: String {
		String(project.id.uuidString.prefix(8))
	}

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider().overlay(Theme.border)
			if isLoading {
				loadingState
			} else if let error {
				errorState(error)
			} else if sessions.isEmpty {
				emptyState
			} else {
				sessionList
			}
		}
		.frame(width: 480, height: 360)
		.background(Theme.surface)
		.cornerRadius(Theme.radiusLg)
		.overlay(
			RoundedRectangle(cornerRadius: Theme.radiusLg)
				.stroke(Theme.border, lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.34), radius: 18, y: 8)
		.onAppear { loadSessions() }
	}

	private var header: some View {
		HStack {
			VStack(alignment: .leading, spacing: 2) {
				Text("Sessions")
					.font(.system(size: 14, weight: .semibold))
					.foregroundStyle(Theme.textPrimary)
				Text(project.name)
					.font(.system(size: 11))
					.foregroundStyle(Theme.textSecondary)
			}
			Spacer()
			Button(action: { loadSessions() }) {
				Image(systemName: "arrow.clockwise")
					.font(.system(size: 10, weight: .medium))
					.foregroundStyle(Theme.textSecondary)
			}
			.buttonStyle(.plain)
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

	private var loadingState: some View {
		VStack(spacing: 8) {
			ProgressView()
				.controlSize(.small)
			Text("Loading sessions...")
				.font(.system(size: 12))
				.foregroundStyle(Theme.textSecondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private func errorState(_ msg: String) -> some View {
		VStack(spacing: 8) {
			Image(systemName: "exclamationmark.triangle")
				.font(.system(size: 24))
				.foregroundStyle(Theme.textTertiary)
			Text(msg)
				.font(.system(size: 12))
				.foregroundStyle(Theme.textSecondary)
			Button("Retry") { loadSessions() }
				.buttonStyle(.plain)
				.foregroundStyle(Theme.accent)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var emptyState: some View {
		VStack(spacing: 8) {
			Image(systemName: "terminal")
				.font(.system(size: 24))
				.foregroundStyle(Theme.textTertiary)
			Text("No sessions for this project")
				.font(.system(size: 12))
				.foregroundStyle(Theme.textSecondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var sessionList: some View {
		ScrollView {
			VStack(spacing: 0) {
				ForEach(sessions, id: \.name) { session in
					sessionRow(session)
					Divider().overlay(Theme.borderSubtle.opacity(0.4))
				}
			}
		}
	}

	private func sessionRow(_ session: MasterClient.SessionInfo) -> some View {
		let paneShort = extractPaneShort(session.name)
		return HStack(spacing: 10) {
			Circle()
				.fill(session.alive ? Theme.green : Theme.textTertiary)
				.frame(width: 8, height: 8)

			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(session.name)
						.font(.system(size: 12, weight: .medium))
						.foregroundStyle(Theme.textPrimary)
						.lineLimit(1)
					if let paneShort {
						Text("pane: \(paneShort)")
							.font(.system(size: 9))
							.foregroundStyle(Theme.textTertiary)
					}
				}
				Text(formatDate(session.modTime))
					.font(.system(size: 10))
					.foregroundStyle(Theme.textSecondary)
			}

			Spacer()

			if session.alive {
				Button("Attach") {
					onAttach(session.socket)
				}
				.buttonStyle(.plain)
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(Theme.accent)
				.padding(.horizontal, 8)
				.padding(.vertical, 3)
				.background(
					RoundedRectangle(cornerRadius: 4)
						.fill(Theme.accent.opacity(0.1))
				)
			} else {
				Text("Dead")
					.font(.system(size: 10))
					.foregroundStyle(Theme.textTertiary)
			}

			Button(action: { deleteSession(session.name) }) {
				Image(systemName: "trash")
					.font(.system(size: 10))
					.foregroundStyle(Theme.textTertiary)
			}
			.buttonStyle(.plain)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
	}

	private func extractPaneShort(_ name: String) -> String? {
		// belve-<projShort>-<paneShort>
		let parts = name.split(separator: "-")
		guard parts.count >= 3 else { return nil }
		return String(parts.last ?? "")
	}

	private func formatDate(_ iso: String) -> String {
		let formatter = ISO8601DateFormatter()
		guard let date = formatter.date(from: iso) else { return iso }
		let relative = RelativeDateTimeFormatter()
		relative.unitsStyle = .abbreviated
		return relative.localizedString(for: date, relativeTo: Date())
	}

	private func loadSessions() {
		isLoading = true
		error = nil
		Task {
			do {
				let result = try await MasterClient.shared.listSessions()
				await MainActor.run {
					// 現在のプロジェクトのセッションのみフィルタ
					let filtered = result.filter { $0.name.contains(projShort) }
					sessions = filtered.sorted { a, b in
						if a.alive != b.alive { return a.alive }
						return a.modTime > b.modTime
					}
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

	private func deleteSession(_ name: String) {
		Task {
			try? await MasterClient.shared.killSession(name: name)
			loadSessions()
		}
	}
}
