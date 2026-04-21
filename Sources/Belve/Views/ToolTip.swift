import SwiftUI

/// Lightweight SwiftUI tooltip with a configurable delay. macOS's native
/// tooltip (via `.help(_:)`) feels sluggish — about 1.5–2 s before it
/// appears. This version shows after 400 ms and uses the app's own visual
/// language (material + accent border).
struct TooltipModifier: ViewModifier {
	let text: String
	let delay: TimeInterval
	@State private var showing = false
	@State private var hoverTask: Task<Void, Never>?

	func body(content: Content) -> some View {
		content
			.onHover { hovering in
				hoverTask?.cancel()
				if hovering {
					hoverTask = Task {
						try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
						if !Task.isCancelled {
							showing = true
						}
					}
				} else {
					showing = false
				}
			}
			.overlay(alignment: .top) {
				if showing {
					Text(text)
						.font(.system(size: 10))
						.foregroundStyle(Theme.textPrimary)
						.padding(.horizontal, 8)
						.padding(.vertical, 4)
						.background(
							RoundedRectangle(cornerRadius: 4)
								.fill(.ultraThinMaterial)
								.environment(\.colorScheme, .dark)
						)
						.overlay(
							RoundedRectangle(cornerRadius: 4)
								.strokeBorder(Theme.border, lineWidth: 1)
						)
						.shadow(color: .black.opacity(0.4), radius: 6, y: 2)
						.fixedSize()
						// Sit the tooltip *above* the host: move the tooltip's
						// bottom edge 4 pt above the host's top edge by treating
						// the tooltip's `.top` alignment guide as its own
						// (bottom + 4).
						.alignmentGuide(.top) { dims in dims[.bottom] + 4 }
						.transition(.opacity.combined(with: .offset(y: 4)))
						.zIndex(500)
						.allowsHitTesting(false)
				}
			}
			.animation(.easeOut(duration: 0.1), value: showing)
	}
}

extension View {
	/// Faster tooltip than `.help()` — appears after 400 ms and matches the
	/// app's material styling. Pointer events pass through the tooltip so
	/// it doesn't interfere with adjacent controls.
	func tooltip(_ text: String, delay: TimeInterval = 0.4) -> some View {
		modifier(TooltipModifier(text: text, delay: delay))
	}
}
