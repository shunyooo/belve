import AppKit
import SwiftUI

/// Companion 用の floating NSPanel を 1 paneId = 1 panel で生成 / 更新 / 破棄。
/// Phase 1 MVP: 画面右上に縦 stack で配置 (offset で重ねない)。
/// Phase 2 で drag 配置 + 永続化を足す予定。
@MainActor
final class AgentCompanionWindowManager {
	static let shared = AgentCompanionWindowManager()

	private var panels: [String: AgentCompanionPanel] = [:]
	private var stackOrder: [String] = []  // paneId 順、配置 stack 用

	private init() {}

	func upsert(companion: AgentCompanion) {
		if let existing = panels[companion.paneId] {
			existing.update(companion: companion)
			return
		}
		let panel = AgentCompanionPanel(companion: companion)
		panels[companion.paneId] = panel
		stackOrder.append(companion.paneId)
		// 保存済み位置があれば復元、無ければデフォルト stack 配置。
		if let saved = AgentCompanionPanel.restoredOrigin(for: companion.paneId) {
			panel.setOriginByLayout(saved)
			panel.hasUserPosition = true
		} else {
			positionInStack(panel: panel, indexInStack: stackOrder.count - 1)
		}
		panel.orderFrontRegardless()
	}

	func dismiss(paneId: String) {
		guard let panel = panels.removeValue(forKey: paneId) else { return }
		panel.close()
		if let idx = stackOrder.firstIndex(of: paneId) {
			stackOrder.remove(at: idx)
			repositionAll()
		}
	}

	func dismissAll() {
		for panel in panels.values { panel.close() }
		panels.removeAll()
		stackOrder.removeAll()
	}

	/// `sourcePaneId` が動いた時に、他の選択中 companion を同じ delta で動かす。
	/// 自分自身は除外、伝播先の windowDidMove 連鎖は ignoreNextMove flag で抑止。
	func propagateMove(from sourcePaneId: String, delta: NSPoint) {
		let selected = AgentCompanionStore.shared.selectedPaneIds
		guard selected.contains(sourcePaneId), selected.count > 1 else { return }
		for paneId in selected where paneId != sourcePaneId {
			guard let panel = panels[paneId] else { continue }
			let new = NSPoint(x: panel.frame.origin.x + delta.x, y: panel.frame.origin.y + delta.y)
			panel.setOriginByPropagation(new)
		}
	}

	private func positionInStack(panel: AgentCompanionPanel, indexInStack: Int) {
		// User が drag で動かした panel はユーザー配置を尊重 (= 触らない)。
		guard !panel.hasUserPosition else { return }
		guard let screen = NSScreen.main else { return }
		let panelSize = panel.frame.size
		let margin: CGFloat = 16
		let gap: CGFloat = 8
		let visible = screen.visibleFrame
		let x = visible.maxX - panelSize.width - margin
		let y = visible.maxY - panelSize.height - margin - (panelSize.height + gap) * CGFloat(indexInStack)
		panel.setOriginByLayout(NSPoint(x: x, y: y))
	}

	private func repositionAll() {
		// 既に drag された panel は skip しつつ、index は stackOrder の元 index で
		// そのまま使う (= 詰めない)。詰めると残ってる panel のデフォルト位置が
		// ガクッと上にズレて違和感、また user-positioned の隙間に被る恐れがある。
		for (i, paneId) in stackOrder.enumerated() {
			if let panel = panels[paneId] {
				positionInStack(panel: panel, indexInStack: i)
			}
		}
	}
}

/// SwiftUI コンテンツを乗せる NSPanel。floating + 非アクティブ化 (= main app の
/// frontmost を奪わない) + 透過背景。`windowDidMove` を観測して
/// 「複数選択中の他 panel に delta を伝播」する (= まとめて移動)。
final class AgentCompanionPanel: NSPanel, NSWindowDelegate {
	private let host: NSHostingController<AgentCompanionView>
	private let model: AgentCompanionViewModel
	let paneId: String
	private var lastOrigin: NSPoint = .zero
	/// 伝播由来 (= 他 panel が動いたから動かされた) の windowDidMove を抑止する。
	private var ignoreNextMove = false
	/// User が drag (or 伝播 drag) で動かしたら true。一度でも動かされた panel は
	/// reconcile / dismiss 時の再 stack 配置の対象から外す (= ユーザー配置を尊重)。
	var hasUserPosition = false

	init(companion: AgentCompanion) {
		self.paneId = companion.paneId
		self.model = AgentCompanionViewModel(companion: companion)
		self.host = NSHostingController(rootView: AgentCompanionView(model: model))
		// 透過パネルなので大きめ frame でも見た目は SwiftUI content のみ。
		// avatar + bubble ×3 + 展開分を余裕で収める固定 size。
		let initialFrame = NSRect(x: 0, y: 0, width: 360, height: 300)
		super.init(
			contentRect: initialFrame,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		self.isFloatingPanel = true
		self.level = .floating
		self.becomesKeyOnlyIfNeeded = true
		self.isOpaque = false
		self.backgroundColor = .clear
		self.hasShadow = false
		self.hidesOnDeactivate = false
		self.isMovableByWindowBackground = true
		self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
		// contentViewController 経由ではなく直接 subview 追加 + autoresizing。
		// contentViewController を使うと sizingOptions 周りの挙動が不安定で
		// content が 0 サイズに潰れたり panel が見えなくなる。
		let hostView = host.view
		hostView.frame = self.contentView!.bounds
		hostView.autoresizingMask = [.width, .height]
		self.contentView!.addSubview(hostView)
		self.delegate = self
		self.lastOrigin = self.frame.origin
	}

	func update(companion: AgentCompanion) {
		model.companion = companion
		// content size の自動追従は NSHostingController 任せにする (=
		// setContentSize を毎回呼ぶと origin が jump して「位置崩れ」になる)。
		// panel の初期サイズは十分余裕を持たせ、SwiftUI 側の layout に委ねる。
	}

	/// 伝播経由の origin 移動。windowDidMove の chain reaction を防ぐため flag を立てる。
	func setOriginByPropagation(_ origin: NSPoint) {
		ignoreNextMove = true
		setFrameOrigin(origin)
		lastOrigin = origin
		hasUserPosition = true
		persistOrigin(origin)
	}

	/// Manager が初期 stack 配置 / repositionAll で呼ぶ。userPosition flag は立てない。
	func setOriginByLayout(_ origin: NSPoint) {
		ignoreNextMove = true
		setFrameOrigin(origin)
		lastOrigin = origin
	}

	func windowDidMove(_ notification: Notification) {
		if ignoreNextMove { ignoreNextMove = false; return }
		let new = frame.origin
		let delta = NSPoint(x: new.x - lastOrigin.x, y: new.y - lastOrigin.y)
		lastOrigin = new
		guard delta.x != 0 || delta.y != 0 else { return }
		hasUserPosition = true
		persistOrigin(new)
		AgentCompanionWindowManager.shared.propagateMove(from: paneId, delta: delta)
	}

	/// origin を per-pane UserDefaults に保存。
	private func persistOrigin(_ origin: NSPoint) {
		let key = "Belve.companionPosition.\(paneId)"
		UserDefaults.standard.set([origin.x, origin.y], forKey: key)
	}

	/// 保存済みの origin があれば復元。無ければ nil。
	static func restoredOrigin(for paneId: String) -> NSPoint? {
		let key = "Belve.companionPosition.\(paneId)"
		guard let arr = UserDefaults.standard.array(forKey: key) as? [Double], arr.count == 2 else { return nil }
		return NSPoint(x: arr[0], y: arr[1])
	}
}

/// ViewModel: SwiftUI 側で観測する。Window manager から差し替えられる。
@MainActor
final class AgentCompanionViewModel: ObservableObject {
	@Published var companion: AgentCompanion

	init(companion: AgentCompanion) {
		self.companion = companion
	}
}
