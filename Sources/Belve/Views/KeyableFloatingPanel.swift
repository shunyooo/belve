import AppKit
import SwiftUI

/// `FloatingMenuPopup` の text-input 対応版。
/// SwiftUI の `.popover` は borderless + custom chrome のメインウィンドウだと
/// key window 化が不安定で、TextField 編集中にボタンクリックが無視される問題が
/// あった。このパネルは `canBecomeKey = true` + `becomesKeyOnlyIfNeeded = false`
/// で確実に key 化するため、内側の TextField とボタンが期待通りに動く。
///
/// 自動閉じ: 外側クリック / Escape / 親ウィンドウ resign-key / `close()`。
@MainActor
final class KeyableFloatingPanel {
	static let shared = KeyableFloatingPanel()

	private var panel: NSPanel?
	private var globalMonitor: Any?
	private var localMonitor: Any?
	private var keyMonitor: Any?
	private var onCloseCallback: (() -> Void)?

	var isShown: Bool { panel != nil }

	/// `anchor` は基準ボタンの screen rect (AppKit, y=0 が画面下端)。
	/// パネルはアンカーの上端に bottom 揃えで描画する (BottomBar の上に出す想定)。
	/// `excludeRect` 内のクリックは「外側クリック」として扱わない (= 閉じない)。
	/// アンカーボタン自身のクリックを渡すと、トグルが期待通り動く
	/// (monitor が close → ボタン action が即 show、というレースを防ぐ)。
	func show<Content: View>(
		anchor: NSRect,
		size: NSSize,
		excludeRect: NSRect? = nil,
		onClose: (() -> Void)? = nil,
		@ViewBuilder content: () -> Content
	) {
		close()
		// SwiftUI content の intrinsic size に合わせて panel を縮める。
		// `size` は最低サイズ (width はだいたい固定したい、height は fitting
		// が 0 になった時の保険)。中身が "No forwards yet" のような短い状態でも
		// 余白が浮いて見えなくなる。
		let host = NSHostingView(rootView: content())
		host.layoutSubtreeIfNeeded()
		let fitting = host.fittingSize
		let actual = NSSize(
			width: max(size.width, fitting.width),
			height: fitting.height > 0 ? fitting.height : size.height
		)
		let originX = max(8, anchor.midX - actual.width / 2)
		let originY = anchor.maxY + 4
		let panel = KeyablePanelImpl(
			contentRect: NSRect(x: originX, y: originY, width: actual.width, height: actual.height),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.level = .popUpMenu
		panel.isMovableByWindowBackground = false
		panel.hidesOnDeactivate = true
		panel.becomesKeyOnlyIfNeeded = false
		panel.contentView = host
		panel.makeKeyAndOrderFront(nil)
		self.panel = panel
		self.onCloseCallback = onClose

		// 各 monitor は自分が show した panel だけを閉じるよう guard で識別する
		// (連続 show 時の race で新 panel を誤って閉じないように)。
		globalMonitor = NSEvent.addGlobalMonitorForEvents(
			matching: [.leftMouseDown, .rightMouseDown]
		) { [weak self, weak panel] _ in
			MainActor.assumeIsolated {
				guard let self, self.panel === panel else { return }
				self.close()
			}
		}
		localMonitor = NSEvent.addLocalMonitorForEvents(
			matching: [.leftMouseDown, .rightMouseDown]
		) { [weak self, weak panel] event in
			MainActor.assumeIsolated {
				guard let self, self.panel === panel else { return event }
				if event.window !== panel {
					// excludeRect (= アンカーボタン) 内のクリックは無視。
					// そうしないと「ボタンを押して閉じる」が「monitor が
					// close → ボタン action が show」で結局開きっぱなしになる。
					let screenLoc = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
					if let excludeRect, excludeRect.contains(screenLoc) {
						return event
					}
					self.close()
				}
				return event
			}
		}
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
			MainActor.assumeIsolated {
				guard let self, self.panel === panel else { return event }
				if event.keyCode == 53 { // Escape
					self.close()
					return nil
				}
				return event
			}
		}
	}

	func close() {
		panel?.orderOut(nil)
		panel = nil
		if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
		if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
		if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
		onCloseCallback?()
		onCloseCallback = nil
	}
}

/// borderless NSPanel は default で key になれない。TextField の focus を
/// 取れるように override する。
private final class KeyablePanelImpl: NSPanel {
	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { false }
}
