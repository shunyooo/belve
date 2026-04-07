import SwiftUI
import AppKit

enum DividerMetrics {
	static let lineWidth: CGFloat = 1
	static let absoluteHitWidth: CGFloat = 10
	static let paneHitWidth: CGFloat = 7
}

struct DividerCursorModifier: ViewModifier {
	let cursor: NSCursor

	func body(content: Content) -> some View {
		content.background(DividerCursorTrackingView(cursor: cursor))
	}
}

extension View {
	func dividerCursor(_ cursor: NSCursor) -> some View {
		modifier(DividerCursorModifier(cursor: cursor))
	}
}

struct DividerCursorTrackingView: NSViewRepresentable {
	let cursor: NSCursor

	func makeNSView(context: Context) -> DividerCursorTrackingNSView {
		let view = DividerCursorTrackingNSView()
		view.cursor = cursor
		return view
	}

	func updateNSView(_ nsView: DividerCursorTrackingNSView, context: Context) {
		nsView.cursor = cursor
		nsView.updateTrackingAreas()
	}
}

final class DividerCursorTrackingNSView: NSView {
	var cursor: NSCursor = .arrow
	private var trackingArea: NSTrackingArea?

	override var isFlipped: Bool { true }

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let trackingArea {
			removeTrackingArea(trackingArea)
		}

		let area = NSTrackingArea(
			rect: bounds,
			options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
			owner: self,
			userInfo: nil
		)
		addTrackingArea(area)
		trackingArea = area
		window?.invalidateCursorRects(for: self)
	}

	override func resetCursorRects() {
		discardCursorRects()
		addCursorRect(bounds, cursor: cursor)
	}

	override func hitTest(_ point: NSPoint) -> NSView? {
		self
	}

	override func mouseEntered(with event: NSEvent) {
		cursor.set()
		super.mouseEntered(with: event)
	}

	override func mouseMoved(with event: NSEvent) {
		cursor.set()
		super.mouseMoved(with: event)
	}

	override func cursorUpdate(with event: NSEvent) {
		cursor.set()
		super.cursorUpdate(with: event)
	}
}
