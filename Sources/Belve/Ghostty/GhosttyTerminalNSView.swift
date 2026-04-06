import GhosttyKit
import AppKit
import QuartzCore

/// NSView backed by a CAMetalLayer that hosts a single Ghostty terminal surface.
/// Handles keyboard input (via NSTextInputClient), mouse events, and resize.
final class GhosttyTerminalNSView: NSView, NSTextInputClient {

	/// The Ghostty surface handle. Created when the view is attached to a window.
	private(set) var surface: ghostty_surface_t?

	/// Called when the shell process exits and Ghostty requests surface close.
	var onSurfaceClosed: (() -> Void)?

	/// Working directory for the shell.
	var workingDirectory: String?

	/// Custom command to run instead of default shell (e.g. "ssh host" for remote).
	var command: String?

	/// Environment variables to inject into the shell.
	var environmentVariables: [String: String] = [:]

	// MARK: - Text Input State

	private var keyTextAccumulator: [String]?
	private var markedTextStorage = NSMutableAttributedString()
	private var trackingArea: NSTrackingArea?

	// MARK: - Layer Setup

	override var wantsUpdateLayer: Bool { true }
	override var isFlipped: Bool { false }

	override func makeBackingLayer() -> CALayer {
		let metalLayer = CAMetalLayer()
		metalLayer.pixelFormat = .bgra8Unorm
		metalLayer.isOpaque = false
		metalLayer.framebufferOnly = false
		return metalLayer
	}

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		setup()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		setup()
	}

	private func setup() {
		wantsLayer = true
		layer?.masksToBounds = true
	}

	// MARK: - Surface Lifecycle

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		guard window != nil else { return }

		if surface == nil {
			createSurface()
		}

		updateTrackingAreas()

		if let surface {
			if let screen = window?.screen ?? NSScreen.main,
			   let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
			   displayID != 0 {
				ghostty_surface_set_display_id(surface, displayID)
			}
			updateSurfaceScale()
			updateSurfaceSize()
			ghostty_surface_set_focus(surface, true)
		}
	}

	private func createSurface() {
		guard let app = GhosttyRuntime.shared.app else {
			NSLog("[Belve] Cannot create surface: Ghostty runtime not initialized")
			return
		}

		var config = ghostty_surface_config_new()
		config.platform_tag = GHOSTTY_PLATFORM_MACOS
		config.platform = ghostty_platform_u(
			macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
		)
		config.userdata = Unmanaged.passUnretained(self).toOpaque()

		let scaleFactor = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
		config.scale_factor = Double(scaleFactor)
		config.font_size = 13.0

		// Environment variables
		var envVars: [ghostty_env_var_s] = []
		var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []

		var env = environmentVariables
		env["BELVE_SESSION"] = "1"

		for (key, value) in env {
			guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
			envStorage.append((keyPtr, valuePtr))
			envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
		}

		let createdSurface: ghostty_surface_t?
		if !envVars.isEmpty {
			let count = envVars.count
			createdSurface = envVars.withUnsafeMutableBufferPointer { buffer in
				config.env_vars = buffer.baseAddress
				config.env_var_count = count
				if let wd = workingDirectory {
					return wd.withCString { cwd in
						config.working_directory = cwd
						return ghostty_surface_new(app, &config)
					}
				} else {
					return ghostty_surface_new(app, &config)
				}
			}
		} else {
			if let wd = workingDirectory {
				createdSurface = wd.withCString { cwd in
					config.working_directory = cwd
					return ghostty_surface_new(app, &config)
				}
			} else {
				createdSurface = ghostty_surface_new(app, &config)
			}
		}

		for (key, value) in envStorage {
			free(key)
			free(value)
		}

		guard let createdSurface else {
			NSLog("[Belve] Failed to create ghostty surface")
			return
		}

		self.surface = createdSurface
		NSLog("[Belve] Ghostty surface created")
	}

	/// Send text to the terminal (simulates keyboard input).
	func sendText(_ text: String) {
		guard let surface else { return }
		text.withCString { ptr in
			ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
		}
	}

	func destroySurface() {
		guard let surface else { return }
		// Clear reference first to prevent callbacks on freed surface
		self.surface = nil
		// Free on main thread with a small delay to let Ghostty finish any pending work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			ghostty_surface_free(surface)
		}
	}

	deinit {
		let s = surface
		let ta = trackingArea
		surface = nil
		// deinit may not be on main thread; schedule cleanup
		DispatchQueue.main.async {
			if let s {
				ghostty_surface_free(s)
			}
		}
		if let ta {
			removeTrackingArea(ta)
		}
	}

	// MARK: - Resize

	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		updateSurfaceScale()
		updateSurfaceSize()
	}

	override func viewDidChangeBackingProperties() {
		super.viewDidChangeBackingProperties()
		updateSurfaceScale()
		updateSurfaceSize()
	}

	private func updateSurfaceScale() {
		guard let surface else { return }
		let scaleFactor = window?.backingScaleFactor ?? 2.0
		ghostty_surface_set_content_scale(surface, Double(scaleFactor), Double(scaleFactor))

		CATransaction.begin()
		CATransaction.setDisableActions(true)
		layer?.contentsScale = scaleFactor
		if let metalLayer = layer as? CAMetalLayer {
			let backingSize = convertToBacking(bounds).size
			let pixelSize = CGSize(
				width: floor(max(0, backingSize.width)),
				height: floor(max(0, backingSize.height))
			)
			if pixelSize.width > 0, pixelSize.height > 0 {
				metalLayer.drawableSize = pixelSize
			}
		}
		CATransaction.commit()
	}

	private func updateSurfaceSize() {
		guard let surface, window != nil else { return }
		let backingSize = convertToBacking(NSRect(origin: .zero, size: bounds.size)).size
		let wpx = UInt32(max(1, floor(backingSize.width)))
		let hpx = UInt32(max(1, floor(backingSize.height)))
		guard wpx > 0, hpx > 0 else { return }
		ghostty_surface_set_size(surface, wpx, hpx)
	}

	// MARK: - Focus

	override var acceptsFirstResponder: Bool { true }

	var onBecomeFirstResponder: (() -> Void)?

	override func becomeFirstResponder() -> Bool {
		let result = super.becomeFirstResponder()
		if result, let surface {
			ghostty_surface_set_focus(surface, true)
		}
		if result {
			onBecomeFirstResponder?()
		}
		return result
	}

	override func resignFirstResponder() -> Bool {
		let result = super.resignFirstResponder()
		if result, let surface {
			ghostty_surface_set_focus(surface, false)
		}
		return result
	}

	// MARK: - Cursor Shape

	func updateCursorShape(_ shape: ghostty_action_mouse_shape_e) {
		switch shape {
		case GHOSTTY_MOUSE_SHAPE_TEXT:
			NSCursor.iBeam.set()
		case GHOSTTY_MOUSE_SHAPE_POINTER:
			NSCursor.pointingHand.set()
		case GHOSTTY_MOUSE_SHAPE_DEFAULT:
			NSCursor.arrow.set()
		default:
			NSCursor.arrow.set()
		}
	}

	// MARK: - Keyboard Input

	override func keyDown(with event: NSEvent) {
		guard let surface else {
			super.keyDown(with: event)
			return
		}

		// Fast path for Ctrl-modified keys (e.g. Ctrl+C, Ctrl+D)
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		if flags.contains(.control), !flags.contains(.command), !flags.contains(.option),
		   markedTextStorage.length == 0 {
			var keyEvent = ghostty_input_key_s()
			keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
			keyEvent.keycode = UInt32(event.keyCode)
			keyEvent.mods = modsFromEvent(event)
			keyEvent.consumed_mods = GHOSTTY_MODS_NONE
			keyEvent.composing = false
			keyEvent.unshifted_codepoint = unshiftedCodepoint(event)

			let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
			if text.isEmpty {
				keyEvent.text = nil
				if ghostty_surface_key(surface, keyEvent) { return }
			} else {
				let handled = text.withCString { ptr -> Bool in
					keyEvent.text = ptr
					return ghostty_surface_key(surface, keyEvent)
				}
				if handled { return }
			}
		}

		let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

		// Use interpretKeyEvents for IME / dead key support
		let markedBefore = markedTextStorage.length > 0
		keyTextAccumulator = []
		defer { keyTextAccumulator = nil }
		interpretKeyEvents([event])

		// Sync preedit
		syncPreedit(clearIfNeeded: markedBefore)

		// Build and send key event
		var keyEvent = ghostty_input_key_s()
		keyEvent.action = action
		keyEvent.keycode = UInt32(event.keyCode)
		keyEvent.mods = modsFromEvent(event)
		keyEvent.consumed_mods = consumedMods(event)
		keyEvent.unshifted_codepoint = unshiftedCodepoint(event)
		keyEvent.composing = markedTextStorage.length > 0 || markedBefore

		let accumulated = keyTextAccumulator ?? []
		if !accumulated.isEmpty {
			keyEvent.composing = false
			for text in accumulated {
				text.withCString { ptr in
					keyEvent.text = ptr
					_ = ghostty_surface_key(surface, keyEvent)
				}
			}
		} else {
			let text = textForKeyEvent(event)
			if let text, !text.isEmpty {
				text.withCString { ptr in
					keyEvent.text = ptr
					_ = ghostty_surface_key(surface, keyEvent)
				}
			} else {
				keyEvent.text = nil
				_ = ghostty_surface_key(surface, keyEvent)
			}
		}
	}

	override func keyUp(with event: NSEvent) {
		guard let surface else { return }
		var keyEvent = ghostty_input_key_s()
		keyEvent.action = GHOSTTY_ACTION_RELEASE
		keyEvent.keycode = UInt32(event.keyCode)
		keyEvent.mods = modsFromEvent(event)
		keyEvent.consumed_mods = GHOSTTY_MODS_NONE
		keyEvent.unshifted_codepoint = unshiftedCodepoint(event)
		keyEvent.composing = false
		keyEvent.text = nil
		_ = ghostty_surface_key(surface, keyEvent)
	}

	override func flagsChanged(with event: NSEvent) {
		guard let surface else { return }
		var keyEvent = ghostty_input_key_s()
		keyEvent.action = GHOSTTY_ACTION_PRESS
		keyEvent.keycode = UInt32(event.keyCode)
		keyEvent.mods = modsFromEvent(event)
		keyEvent.consumed_mods = GHOSTTY_MODS_NONE
		keyEvent.unshifted_codepoint = 0
		keyEvent.composing = false
		keyEvent.text = nil
		_ = ghostty_surface_key(surface, keyEvent)
	}

	// Suppress system beep for unhandled key commands
	override func doCommand(by selector: Selector) {}

	override func performKeyEquivalent(with event: NSEvent) -> Bool {
		guard let surface else { return false }

		// Let Cmd-based shortcuts pass through to SwiftUI menu system.
		// Don't send to Ghostty — its default keybindings (tab switch etc.)
		// expect infrastructure we don't provide.
		if event.modifierFlags.contains(.command) {
			return false
		}

		var keyEvent = ghostty_input_key_s()
		keyEvent.action = GHOSTTY_ACTION_PRESS
		keyEvent.keycode = UInt32(event.keyCode)
		keyEvent.mods = modsFromEvent(event)
		keyEvent.consumed_mods = GHOSTTY_MODS_NONE
		keyEvent.unshifted_codepoint = unshiftedCodepoint(event)
		keyEvent.composing = false
		keyEvent.text = nil

		if ghostty_surface_key_is_binding(surface, keyEvent, nil) {
			keyDown(with: event)
			return true
		}
		return false
	}

	// MARK: - NSTextInputClient

	func insertText(_ string: Any, replacementRange: NSRange) {
		var chars = ""
		switch string {
		case let v as NSAttributedString: chars = v.string
		case let v as String: chars = v
		default: return
		}

		unmarkText()
		guard !chars.isEmpty else { return }

		if keyTextAccumulator != nil {
			keyTextAccumulator?.append(chars)
			return
		}

		// Direct text insertion (paste from IME etc)
		guard let surface else { return }
		var keyEvent = ghostty_input_key_s()
		keyEvent.action = GHOSTTY_ACTION_PRESS
		keyEvent.keycode = 0
		keyEvent.mods = GHOSTTY_MODS_NONE
		keyEvent.consumed_mods = GHOSTTY_MODS_NONE
		keyEvent.unshifted_codepoint = 0
		keyEvent.composing = false
		chars.withCString { ptr in
			keyEvent.text = ptr
			_ = ghostty_surface_key(surface, keyEvent)
		}
	}

	func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
		switch string {
		case let v as NSAttributedString:
			markedTextStorage = NSMutableAttributedString(attributedString: v)
		case let v as String:
			markedTextStorage = NSMutableAttributedString(string: v)
		default:
			markedTextStorage = NSMutableAttributedString()
		}
	}

	func unmarkText() {
		markedTextStorage = NSMutableAttributedString()
		if let surface {
			ghostty_surface_preedit(surface, nil, 0)
		}
	}

	func selectedRange() -> NSRange {
		NSRange(location: NSNotFound, length: 0)
	}

	func markedRange() -> NSRange {
		if markedTextStorage.length > 0 {
			return NSRange(location: 0, length: markedTextStorage.length)
		}
		return NSRange(location: NSNotFound, length: 0)
	}

	func hasMarkedText() -> Bool {
		markedTextStorage.length > 0
	}

	func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
		nil
	}

	func validAttributesForMarkedText() -> [NSAttributedString.Key] {
		[]
	}

	func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
		guard let surface else { return .zero }
		var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
		ghostty_surface_ime_point(surface, &x, &y, &w, &h)
		let pointInView = NSPoint(x: x, y: bounds.height - y - h)
		guard let window else { return NSRect(origin: pointInView, size: NSSize(width: w, height: h)) }
		let pointInWindow = convert(pointInView, to: nil)
		let screenPoint = window.convertPoint(toScreen: pointInWindow)
		return NSRect(origin: screenPoint, size: NSSize(width: w, height: h))
	}

	func characterIndex(for point: NSPoint) -> Int {
		0
	}

	// MARK: - Mouse Input

	override func mouseDown(with event: NSEvent) {
		window?.makeFirstResponder(self)
		guard let surface else { return }
		let point = convert(event.locationInWindow, from: nil)
		if event.clickCount == 1 {
			ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
		}
		_ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
	}

	override func mouseUp(with event: NSEvent) {
		guard let surface else { return }
		_ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
	}

	override func mouseDragged(with event: NSEvent) {
		guard let surface else { return }
		let point = convert(event.locationInWindow, from: nil)
		ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
	}

	override func mouseMoved(with event: NSEvent) {
		guard let surface else { return }
		let point = convert(event.locationInWindow, from: nil)
		ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
	}

	override func rightMouseDown(with event: NSEvent) {
		guard let surface else { super.rightMouseDown(with: event); return }
		if !ghostty_surface_mouse_captured(surface) {
			super.rightMouseDown(with: event)
			return
		}
		let point = convert(event.locationInWindow, from: nil)
		ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
		_ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
	}

	override func rightMouseUp(with event: NSEvent) {
		guard let surface else { super.rightMouseUp(with: event); return }
		if !ghostty_surface_mouse_captured(surface) {
			super.rightMouseUp(with: event)
			return
		}
		_ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
	}

	override func scrollWheel(with event: NSEvent) {
		guard let surface else { return }
		var x = event.scrollingDeltaX
		var y = event.scrollingDeltaY
		if event.hasPreciseScrollingDeltas {
			x *= 2
			y *= 2
		}

		var mods: Int32 = 0
		if event.hasPreciseScrollingDeltas {
			mods |= 0b0000_0001
		}

		let momentum: Int32
		switch event.momentumPhase {
		case .began:     momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
		case .changed:   momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
		case .ended:     momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
		case .cancelled: momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
		case .mayBegin:  momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
		default:         momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
		}
		mods |= momentum << 1

		ghostty_surface_mouse_scroll(surface, x, y, ghostty_input_scroll_mods_t(mods))
	}

	// MARK: - Tracking Area

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let trackingArea {
			removeTrackingArea(trackingArea)
		}
		trackingArea = NSTrackingArea(
			rect: bounds,
			options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
			owner: self,
			userInfo: nil
		)
		if let trackingArea {
			addTrackingArea(trackingArea)
		}
	}

	// MARK: - Helpers

	private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
		var mods = GHOSTTY_MODS_NONE.rawValue
		if event.modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
		if event.modifierFlags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
		if event.modifierFlags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
		if event.modifierFlags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
		return ghostty_input_mods_e(rawValue: mods)
	}

	private func consumedMods(_ event: NSEvent) -> ghostty_input_mods_e {
		var mods = GHOSTTY_MODS_NONE.rawValue
		if event.modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
		if event.modifierFlags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
		return ghostty_input_mods_e(rawValue: mods)
	}

	private func unshiftedCodepoint(_ event: NSEvent) -> UInt32 {
		guard let chars = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
			  let scalar = chars.unicodeScalars.first,
			  scalar.value >= 0x20,
			  !(scalar.value >= 0xF700 && scalar.value <= 0xF8FF) else {
			return 0
		}
		return scalar.value
	}

	private func textForKeyEvent(_ event: NSEvent) -> String? {
		guard let chars = event.characters, !chars.isEmpty else { return nil }
		if chars.count == 1, let scalar = chars.unicodeScalars.first {
			// Skip Private Use Area characters (function keys)
			if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
		}
		return chars
	}

	private func syncPreedit(clearIfNeeded: Bool) {
		guard let surface else { return }
		if markedTextStorage.length > 0 {
			let str = markedTextStorage.string
			str.withCString { ptr in
				ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count))
			}
		} else if clearIfNeeded {
			ghostty_surface_preedit(surface, nil, 0)
		}
	}
}
