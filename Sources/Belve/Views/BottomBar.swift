import AppKit
import SwiftUI

/// Thin status strip anchored at the bottom of the main window. Houses
/// cross-cutting indicators that don't belong to any single pane: connection
/// target, git branch, port forwards, agent activity summary. Each item is a
/// hit target that can expand into a richer popover in the future (Ports
/// management, git log, etc.).
struct BottomBar: View {
	let project: Project?
	let gitBranch: String?
	let activeAgentProjectCount: Int
	@ObservedObject var portManager: PortForwardManager
	let onUpdateForwards: (UUID, [PortForward]) -> Void
	var onResolveDetection: ((UUID, Int, PortForwardManager.DetectionAction) -> Void)?
	var onOpenBrowser: (() -> Void)?
	@State private var portsButtonScreenFrame: NSRect = .zero
	/// BottomBar が乗っている NSWindow への参照。座標変換時に
	/// `NSApp.keyWindow` を使うと、ポップアップ自身が key になった瞬間に
	/// 計算が popup の contentView 基準にずれて壊れるため、
	/// 自分のホスト window を直接握って使う。
	@State private var hostWindow: NSWindow?

	var body: some View {
		HStack(spacing: 12) {
			if let project {
				connectionItem(for: project)
			}
			if let branch = gitBranch {
				gitItem(branch: branch)
			}
			portsItem()
			browserItem()
			Spacer(minLength: 8)
			if activeAgentProjectCount > 0 {
				agentSummaryItem(count: activeAgentProjectCount)
			}
		}
		.padding(.horizontal, 10)
		.frame(height: 24)
		.background(Theme.surface.opacity(0.98))
		.background(HostWindowReader(window: $hostWindow))
		// プロジェクト切替時はパネルを必ず閉じる (古い project の forwards を編集
		// したまま残ってしまう問題への対処)。
		.onChange(of: project?.id) { _, _ in
			KeyableFloatingPanel.shared.close()
		}
	}

	private func connectionItem(for project: Project) -> some View {
		let (icon, label, color) = Self.connectionDisplay(for: project)
		return HStack(spacing: 4) {
			Image(systemName: icon)
				.font(.system(size: 11))
				.foregroundStyle(color)
			Text(label)
				.font(.system(size: 11))
				.foregroundStyle(Theme.textSecondary)
				.lineLimit(1)
		}
	}

	private static func connectionDisplay(for project: Project) -> (String, String, Color) {
		switch project.workspace {
		case .local:
			return ("laptopcomputer", "Local", Theme.textTertiary)
		case .ssh(let host, _):
			let short = host.components(separatedBy: ".").first ?? host
			return ("network", short, Theme.accent)
		case .devContainer(let host, _):
			let short = host.components(separatedBy: ".").first ?? host
			return ("shippingbox", "\(short) / DevContainer", Theme.accent)
		}
	}

	private func gitItem(branch: String) -> some View {
		HStack(spacing: 4) {
			Image(systemName: "arrow.triangle.branch")
				.font(.system(size: 11))
			Text(branch)
				.font(.system(size: 11))
				.lineLimit(1)
				.truncationMode(.middle)
		}
		.foregroundStyle(Theme.textSecondary)
	}

	private func agentSummaryItem(count: Int) -> some View {
		HStack(spacing: 4) {
			Circle()
				.fill(Theme.accent)
				.frame(width: 5, height: 5)
			Text("\(count) active")
				.font(.system(size: 11))
				.foregroundStyle(Theme.textSecondary)
		}
	}

	private func browserItem() -> some View {
		let enabled = (project != nil)
		return Button(action: { if enabled { onOpenBrowser?() } }) {
			HStack(spacing: 4) {
				Image(systemName: "globe")
					.font(.system(size: 11))
				Text("Browser")
					.font(.system(size: 11))
			}
			.foregroundStyle(enabled ? Theme.textSecondary : Theme.textTertiary.opacity(0.6))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(!enabled)
		.help("Open browser window for this project")
	}

	private func portsItem() -> some View {
		let enabled = (project?.isRemote ?? false)
		let count = project.map { portManager.statuses[$0.id]?.count ?? 0 } ?? 0
		return Button(action: { if enabled { togglePortsPopup() } }) {
			HStack(spacing: 4) {
				Image(systemName: "arrow.left.arrow.right")
					.font(.system(size: 11))
				Text(count > 0 ? "Ports (\(count))" : "Ports")
					.font(.system(size: 11))
			}
			.foregroundStyle(enabled ? Theme.textSecondary : Theme.textTertiary.opacity(0.6))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(!enabled)
		.background(GeometryReader { geo in
			// ボタンの screen rect を保持。ポップアップを開く時のアンカーに使う。
			Color.clear
				.preference(
					key: PortsButtonFramePreferenceKey.self,
					value: geo.frame(in: .global)
				)
		})
		.onPreferenceChange(PortsButtonFramePreferenceKey.self) { rect in
			portsButtonScreenFrame = localToScreen(rect)
		}
		// Detection toasts sit entirely above the Ports indicator. `.overlay`
		// with `.bottom` alignment positions the stack's bottom at the host's
		// bottom; the negative offset equal to (host height + gap) lifts the
		// stack so its lower edge ends just above the button's top — the
		// bottomBar is 24pt tall, we add a 6pt gap.
		.overlay(alignment: .bottom) {
			if let project, project.isRemote {
				PortDetectionToastStack(
					project: project,
					portManager: portManager,
					onResolve: { port, action in
						onResolveDetection?(project.id, port, action)
					}
				)
				.fixedSize()
				.offset(y: -30)
			}
		}
	}

	private func togglePortsPopup() {
		NSLog("[Belve][ports] toggle invoked, isShown=%@, frame=%@", String(KeyableFloatingPanel.shared.isShown), NSStringFromRect(portsButtonScreenFrame))
		if KeyableFloatingPanel.shared.isShown {
			KeyableFloatingPanel.shared.close()
			return
		}
		guard let project else { return }
		// preference がまだ走ってない初回クリックだと frame が .zero。
		// その時はマウス位置を中心に小さい anchor を作るフォールバック。
		let anchor: NSRect
		if portsButtonScreenFrame == .zero {
			let p = NSEvent.mouseLocation
			anchor = NSRect(x: p.x - 30, y: p.y, width: 60, height: 24)
		} else {
			anchor = portsButtonScreenFrame
		}
		KeyableFloatingPanel.shared.show(
			anchor: anchor,
			size: NSSize(width: 348, height: 360),
			excludeRect: anchor,
			content: {
				PortsPanel(
					project: project,
					portManager: portManager,
					onUpdateForwards: { forwards in
						onUpdateForwards(project.id, forwards)
					},
					onDismiss: { KeyableFloatingPanel.shared.close() }
				)
			}
		)
	}

	/// SwiftUI の `frame(in: .global)` は SwiftUI scene 座標 (y 下方向、原点
	/// content-view 左上)。これを AppKit screen 座標 (y 上方向、原点画面左下)
	/// に変換する。`hostWindow` を直接使うため、ポップアップが key になっても
	/// ずれない。
	private func localToScreen(_ rect: CGRect) -> NSRect {
		guard let window = hostWindow, let contentView = window.contentView else {
			return .zero
		}
		let h = contentView.bounds.height
		let flipped = NSRect(
			x: rect.minX,
			y: h - rect.maxY,
			width: rect.width,
			height: rect.height
		)
		return window.convertToScreen(flipped)
	}
}

/// 自身が乗っている NSWindow を SwiftUI 側に橋渡しするだけの小さな
/// representable。`@State var window: NSWindow?` を bind して、その後の
/// 座標変換に使う。
private struct HostWindowReader: NSViewRepresentable {
	@Binding var window: NSWindow?

	func makeNSView(context: Context) -> NSView {
		let v = NSView()
		DispatchQueue.main.async {
			if window !== v.window { window = v.window }
		}
		return v
	}

	func updateNSView(_ v: NSView, context: Context) {
		DispatchQueue.main.async {
			if window !== v.window { window = v.window }
		}
	}
}

private struct PortsButtonFramePreferenceKey: PreferenceKey {
	static var defaultValue: CGRect = .zero
	static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
		value = nextValue()
	}
}
