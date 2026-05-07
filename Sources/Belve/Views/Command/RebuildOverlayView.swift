import SwiftUI

/// DevContainer rebuild 中に CommandArea のペイン群を覆って表示するオーバーレイ。
/// `master` から push event で stream される `belve-setup --rebuild` の出力を
/// rolling log として表示。完了 (success) で 1.5s 後に自動で消えてペイン再生成、
/// failure で残って Retry / Dismiss ボタンが出る。
struct RebuildOverlayView: View {
	let projectId: UUID
	let projectName: String
	let state: RebuildState
	let onRetry: () -> Void
	let onDismiss: () -> Void

	@State private var elapsed: TimeInterval = 0
	private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			Divider().background(Theme.borderSubtle)
			logScroll
			if state.phase == .failed {
				footerButtons
			}
		}
		.background(Theme.bg)
	}

	private var header: some View {
		HStack(spacing: 10) {
			phaseIcon
			VStack(alignment: .leading, spacing: 2) {
				Text(headerTitle)
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(Theme.textPrimary)
				Text(headerSubtitle)
					.font(.system(size: 11))
					.foregroundStyle(Theme.textSecondary)
			}
			Spacer()
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 12)
	}

	@ViewBuilder
	private var phaseIcon: some View {
		switch state.phase {
		case .running:
			ProgressView().controlSize(.small).scaleEffect(0.9)
		case .success:
			Image(systemName: "checkmark.circle.fill")
				.foregroundStyle(Theme.green)
				.font(.system(size: 16))
		case .failed:
			Image(systemName: "xmark.octagon.fill")
				.foregroundStyle(Theme.red)
				.font(.system(size: 16))
		}
	}

	private var headerTitle: String {
		switch state.phase {
		case .running: return "Rebuilding container — \(projectName)"
		case .success: return "Container ready — \(projectName)"
		case .failed: return "Rebuild failed — \(projectName)"
		}
	}

	private var headerSubtitle: String {
		let secs = Int(elapsed)
		switch state.phase {
		case .running:
			let m = secs / 60, s = secs % 60
			return m > 0 ? "elapsed \(m)m \(s)s" : "elapsed \(secs)s"
		case .success:
			return "Reconnecting panes…"
		case .failed:
			return "See log below for details"
		}
	}

	private var logScroll: some View {
		// 全 log を 1 つの Text にまとめる (= 行をまたいだ選択コピーを可能にする)。
		// 個別 Text を ForEach すると textSelection は行ごとにしか効かない。
		let joined = state.log.joined(separator: "\n")
		return ScrollViewReader { proxy in
			ScrollView {
				Text(joined)
					.font(.system(size: 11, design: .monospaced))
					.foregroundStyle(Theme.textSecondary)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, 14)
					.padding(.vertical, 8)
					.textSelection(.enabled)
					.id("__log__")
				Color.clear.frame(height: 1).id("__bottom__")
			}
			.onChange(of: state.log.count) {
				withAnimation(.easeOut(duration: 0.1)) {
					proxy.scrollTo("__bottom__", anchor: .bottom)
				}
			}
		}
		.onReceive(timer) { _ in
			if state.phase == .running {
				elapsed = Date().timeIntervalSince(state.startedAt)
			}
		}
	}

	private var footerButtons: some View {
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
