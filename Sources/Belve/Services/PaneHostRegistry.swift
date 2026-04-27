import Foundation
import AppKit
import WebKit

/// Pane (= XTermTerminalView の WKWebView) の singleton registry。
///
/// 目的: project view と tile view が同じ pane インスタンスを共有できるようにする。
/// 既存の WKWebView を使い回すことで、view mode 切替時に新規生成・PTY 再接続が起こらない。
///
/// NSView は同時に複数の親に attach できないため、このレジストリは「現在どこに attach
/// されてるか」を意識せず、単に paneId → WKWebView の lookup を提供する。
/// SwiftUI の NSViewRepresentable.makeNSView がこの registry から既存 WebView を返した時、
/// SwiftUI 側の親 NSView への addSubview が古い親からの自動 detach を引き起こす。
///
/// あわせて pane のメタ情報 (project, paneIndex) も保持する。
/// XTermTerminalView から register、TileView から enumerate。
/// 全 mutation は main thread で行う前提 (UI 関連の callsite から呼ばれる)。
final class PaneHostRegistry: ObservableObject {
	static let shared = PaneHostRegistry()

	struct Entry {
		let paneId: String
		let projectId: UUID
		let paneIndex: Int
		let webView: WKWebView          // strong: registry が pane の寿命を管理
		let coordinator: AnyObject      // strong: PTYService 含む coordinator を生かす
	}

	@Published private(set) var entries: [String: Entry] = [:]  // keyed by paneId

	private init() {
		// pane が close (Cmd+W / "Close Pane" コマンド) された時に registry からも削除。
		// strong ref が外れて Coordinator が deinit → PTYService が fd close + プロセス kill。
		NotificationCenter.default.addObserver(
			forName: .belvePaneClosed, object: nil, queue: .main
		) { [weak self] notif in
			if let paneId = notif.userInfo?["paneId"] as? String {
				self?.unregister(paneId: paneId)
			}
		}
	}

	/// XTermTerminalView.makeNSView から呼ばれる。既存 entry があれば WebView を返し、
	/// 第二戻り値は false (= callback 等の setup を skip)。なければ create クロージャを
	/// 呼び、coordinator もまとめて register。
	func resolveWebView(
		forPaneId paneId: String,
		projectId: UUID,
		paneIndex: Int,
		create: () -> (WKWebView, AnyObject)
	) -> (webView: WKWebView, isNewlyCreated: Bool) {
		if let existing = entries[paneId] {
			// メタ情報のみ最新化 (project / paneIndex 変動対応)
			entries[paneId] = Entry(
				paneId: paneId,
				projectId: projectId,
				paneIndex: paneIndex,
				webView: existing.webView,
				coordinator: existing.coordinator
			)
			return (existing.webView, false)
		}
		let (newWebView, newCoordinator) = create()
		entries[paneId] = Entry(
			paneId: paneId,
			projectId: projectId,
			paneIndex: paneIndex,
			webView: newWebView,
			coordinator: newCoordinator
		)
		return (newWebView, true)
	}

	/// pane が削除された時に呼ぶ (project 削除、pane close 等)。
	/// strong ref を release して PTYService 含む coordinator を deinit させる。
	func unregister(paneId: String) {
		entries.removeValue(forKey: paneId)
	}

	/// project に属する全 pane を unregister (project 削除 / reload 時に呼ぶ)。
	/// reload では PTY を再 spawn したいので、registry を空にして CommandArea が
	/// 再 mount された時に新規 WebView/Coordinator が作られるようにする。
	func unregisterAll(in projectId: UUID) {
		let toRemove = entries.values.filter { $0.projectId == projectId }.map(\.paneId)
		for id in toRemove {
			entries.removeValue(forKey: id)
		}
	}

	/// 指定 project の pane 一覧 (paneIndex 昇順)。
	func panes(in projectId: UUID) -> [Entry] {
		entries.values
			.filter { $0.projectId == projectId }
			.sorted { $0.paneIndex < $1.paneIndex }
	}

	/// 全 pane (project 順 → paneIndex 順)。
	func allPanes() -> [Entry] {
		entries.values.sorted { lhs, rhs in
			if lhs.projectId == rhs.projectId {
				return lhs.paneIndex < rhs.paneIndex
			}
			return lhs.projectId.uuidString < rhs.projectId.uuidString
		}
	}

	/// paneId から WebView だけ取得 (tile cell embed 用)。
	func webView(forPaneId paneId: String) -> WKWebView? {
		entries[paneId]?.webView
	}
}
