import SwiftUI

/// SSH host が unreachable / 接続失敗の時に CommandArea のペイン群を覆う overlay。
/// 原因 (host unreachable / auth failed / その他) と推奨アクションを表示し、
/// Retry / Dismiss ボタンで次のアクションを選ばせる。
struct HostUnreachableOverlayView: View {
	let projectName: String
	let error: ConnectionError
	let onRetry: () -> Void
	let onDismiss: () -> Void

	@State private var elapsed: TimeInterval = 0
	private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			Divider().background(Theme.borderSubtle)
			body_
			footer
		}
		.background(Theme.bg)
	}

	private var header: some View {
		HStack(spacing: 10) {
			Image(systemName: iconName)
				.foregroundStyle(Theme.red)
				.font(.system(size: 18, weight: .medium))
			VStack(alignment: .leading, spacing: 2) {
				Text("\(error.headline) — \(projectName)")
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(Theme.textPrimary)
				Text(error.host)
					.font(.system(size: 11, design: .monospaced))
					.foregroundStyle(Theme.textSecondary)
			}
			Spacer()
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 12)
	}

	private var iconName: String {
		switch error.kind {
		case .hostUnreachable: return "wifi.exclamationmark"
		case .authFailed:      return "key.slash"
		case .other:           return "exclamationmark.triangle.fill"
		}
	}

	private var body_: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text(error.hint)
				.font(.system(size: 12))
				.foregroundStyle(Theme.textSecondary)
				.fixedSize(horizontal: false, vertical: true)

			if case .other = error.kind {
				// .other 以外は detail を hint に既に含めてるので redundant 表示しない
				EmptyView()
			} else {
				ScrollView {
					Text(error.detail)
						.font(.system(size: 10, design: .monospaced))
						.foregroundStyle(Theme.textTertiary)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(8)
						.background(
							RoundedRectangle(cornerRadius: 4)
								.fill(Theme.surfaceActive)
						)
				}
				.frame(maxHeight: 80)
			}

			Text("発生から \(Int(elapsed))s")
				.font(.system(size: 10))
				.foregroundStyle(Theme.textTertiary)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 12)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.onReceive(timer) { _ in
			elapsed = Date().timeIntervalSince(error.occurredAt)
		}
	}

	private var footer: some View {
		HStack(spacing: 8) {
			Spacer()
			Button("Dismiss", action: onDismiss)
				.buttonStyle(.plain)
				.padding(.horizontal, 12).padding(.vertical, 6)
				.background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
				.overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderSubtle, lineWidth: 1))
			Button("Retry", action: onRetry)
				.buttonStyle(.plain)
				.padding(.horizontal, 12).padding(.vertical, 6)
				.background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.2)))
				.overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.4), lineWidth: 1))
				.foregroundStyle(Theme.accent)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
	}
}
