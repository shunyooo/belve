import SwiftUI
import AppKit

struct SplitDivider: NSViewRepresentable {
	@Binding var position: CGFloat
	let minLeft: CGFloat
	let minRight: CGFloat
	let availableWidth: CGFloat

	func makeNSView(context: Context) -> SplitDividerNSView {
		let view = SplitDividerNSView()
		view.translatesAutoresizingMaskIntoConstraints = false
		view.onPositionChanged = { newPosition in
			position = newPosition
		}
		return view
	}

	func updateNSView(_ nsView: SplitDividerNSView, context: Context) {
		nsView.position = position
		nsView.minLeft = minLeft
		nsView.minRight = minRight
		nsView.availableWidth = availableWidth
		nsView.onPositionChanged = { newPosition in
			position = newPosition
		}
		nsView.needsDisplay = true
		nsView.updateTrackingAreas()
	}
}

final class SplitDividerNSView: NSView {
	var position: CGFloat = 0
	var minLeft: CGFloat = 250
	var minRight: CGFloat = 250
	var availableWidth: CGFloat = 0
	var onPositionChanged: ((CGFloat) -> Void)?

	private let hitWidth = DividerMetrics.absoluteHitWidth
	private let lineWidth = DividerMetrics.lineWidth
	private var isDragging = false
	private var positionAtDragStart: CGFloat = 0
	private var trackingArea: NSTrackingArea?

	override var isFlipped: Bool { true }

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.backgroundColor = NSColor.clear.cgColor

		let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
		addGestureRecognizer(pan)
	}

	required init?(coder: NSCoder) {
		return nil
	}

	override var intrinsicContentSize: NSSize {
		NSSize(width: hitWidth, height: NSView.noIntrinsicMetric)
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		window?.invalidateCursorRects(for: self)
	}

	override func hitTest(_ point: NSPoint) -> NSView? {
		bounds.contains(point) ? self : nil
	}

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
		true
	}

	override func resetCursorRects() {
		discardCursorRects()
		addCursorRect(bounds, cursor: .resizeLeftRight)
	}

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

	override func mouseEntered(with event: NSEvent) {
		NSCursor.resizeLeftRight.set()
		super.mouseEntered(with: event)
	}

	override func mouseMoved(with event: NSEvent) {
		NSCursor.resizeLeftRight.set()
		super.mouseMoved(with: event)
	}

	override func cursorUpdate(with event: NSEvent) {
		NSCursor.resizeLeftRight.set()
		super.cursorUpdate(with: event)
	}

	override func draw(_ dirtyRect: NSRect) {
		super.draw(dirtyRect)

		if isDragging {
			let fillColor = NSColor(Theme.border.opacity(0.12))
			fillColor.setFill()
			bounds.fill()
		}

		let lineColor = isDragging ? NSColor(Theme.border) : NSColor(Theme.borderSubtle)
		lineColor.setFill()
		NSRect(
			x: (bounds.width - lineWidth) * 0.5,
			y: 0,
			width: lineWidth,
			height: bounds.height
		).fill()
	}

	@objc
	private func handlePan(_ gesture: NSPanGestureRecognizer) {
		switch gesture.state {
		case .began:
			isDragging = true
			positionAtDragStart = position
			NSCursor.resizeLeftRight.push()
			needsDisplay = true

		case .changed:
			let translation = gesture.translation(in: self).x
			let maxPosition = max(minLeft, availableWidth - minRight - hitWidth)
			let newPosition = max(minLeft, min(positionAtDragStart + translation, maxPosition))
			position = newPosition
			onPositionChanged?(newPosition)
			NSCursor.resizeLeftRight.set()

		case .ended, .cancelled, .failed:
			if isDragging {
				NSCursor.pop()
			}
			isDragging = false
			needsDisplay = true

		default:
			break
		}
	}
}
