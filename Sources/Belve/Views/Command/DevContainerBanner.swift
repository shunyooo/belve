import SwiftUI

/// A banner shown when a devcontainer.json is detected in the project folder.
/// Similar to VS Code's "Reopen in Container" notification.
struct DevContainerBanner: View {
	let onReopen: () -> Void
	let onDismiss: () -> Void
	@State private var isHoveringReopen = false
	@State private var isHoveringDismiss = false

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: "shippingbox")
				.font(.system(size: 14))
				.foregroundStyle(Theme.accent)

			Text("Dev Container detected")
				.font(.system(size: 13, weight: .medium))
				.foregroundStyle(Theme.textPrimary)

			Spacer()

			Button(action: onReopen) {
				Text("Reopen in Container")
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(.white)
					.padding(.horizontal, 12)
					.padding(.vertical, 5)
					.background(
						RoundedRectangle(cornerRadius: 5)
							.fill(isHoveringReopen ? Theme.accent.opacity(0.9) : Theme.accent)
					)
			}
			.buttonStyle(.plain)
			.onHover { isHoveringReopen = $0 }

			Button(action: onDismiss) {
				Image(systemName: "xmark")
					.font(.system(size: 10, weight: .medium))
					.foregroundStyle(isHoveringDismiss ? Theme.textPrimary : Theme.textTertiary)
					.frame(width: 22, height: 22)
			}
			.buttonStyle(.plain)
			.onHover { isHoveringDismiss = $0 }
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
		.background(
			RoundedRectangle(cornerRadius: Theme.radiusMd)
				.fill(Theme.surface)
		)
		.overlay(
			RoundedRectangle(cornerRadius: Theme.radiusMd)
				.stroke(Theme.border, lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.3), radius: 8, y: 4)
	}
}
