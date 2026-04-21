import SwiftUI

/// Stack of detection toasts for pending auto-detected ports. Placed as an
/// overlay near the bottom-right of the main window. One card per detected
/// port with three actions — Forward / Always / Never.
struct PortDetectionToastStack: View {
	let project: Project
	@ObservedObject var portManager: PortForwardManager
	let onResolve: (Int, PortForwardManager.DetectionAction) -> Void

	private var pending: [Int] {
		(portManager.pendingDetections[project.id] ?? []).sorted()
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			ForEach(pending, id: \.self) { port in
				PortDetectionToast(
					port: port,
					onForward: { onResolve(port, .forwardOnce) },
					onAlways: { onResolve(port, .always) },
					onNever: { onResolve(port, .never) },
					onDismiss: { onResolve(port, .dismissOnce) }
				)
				// Scale-from-bottom so the card looks like it emerges from the
				// Ports indicator directly below it in the bottom bar.
				.transition(
					.asymmetric(
						insertion: .scale(scale: 0.25, anchor: .bottomLeading)
							.combined(with: .opacity)
							.combined(with: .offset(y: 12)),
						removal: .opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading))
					)
				)
			}
		}
		.animation(.spring(response: 0.32, dampingFraction: 0.8), value: pending)
	}
}

private struct PortDetectionToast: View {
	let port: Int
	let onForward: () -> Void
	let onAlways: () -> Void
	let onNever: () -> Void
	let onDismiss: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: "bell.badge")
					.font(.system(size: 11))
					.foregroundStyle(Theme.accent)
				Text("New remote port")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(Theme.textPrimary)
				Spacer(minLength: 12)
				Button(action: onDismiss) {
					Image(systemName: "xmark")
						.font(.system(size: 9))
						.foregroundStyle(Theme.textTertiary)
						.padding(3)
				}
				.buttonStyle(.plain)
			}

			Text(":\(port)")
				.font(.system(size: 14, weight: .semibold, design: .monospaced))
				.foregroundStyle(Theme.textPrimary)

			HStack(spacing: 6) {
				actionButton("Forward", style: .primary, action: onForward)
				actionButton("Always", style: .secondary, action: onAlways)
				actionButton("Never", style: .destructive, action: onNever)
			}
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 8)
		.frame(width: 240, alignment: .leading)
		.background(
			RoundedRectangle(cornerRadius: Theme.radiusSm)
				.fill(.ultraThinMaterial)
				.environment(\.colorScheme, .dark)
		)
		.overlay(
			RoundedRectangle(cornerRadius: Theme.radiusSm)
				.strokeBorder(Theme.border, lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.35), radius: 10, y: 3)
	}

	private enum ActionStyle { case primary, secondary, destructive }

	private func actionButton(_ label: String, style: ActionStyle, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Text(label)
				.font(.system(size: 10, weight: .medium))
				.padding(.horizontal, 8)
				.padding(.vertical, 3)
				.background(
					RoundedRectangle(cornerRadius: 3).fill(background(for: style))
				)
				.foregroundStyle(foreground(for: style))
		}
		.buttonStyle(.plain)
	}

	private func background(for style: ActionStyle) -> Color {
		switch style {
		case .primary: return Theme.accent.opacity(0.9)
		case .secondary: return Theme.surfaceActive
		case .destructive: return Color.clear
		}
	}

	private func foreground(for style: ActionStyle) -> Color {
		switch style {
		case .primary: return .white
		case .secondary: return Theme.textPrimary
		case .destructive: return Theme.red
		}
	}
}
