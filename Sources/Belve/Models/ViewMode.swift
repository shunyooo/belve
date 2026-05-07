import Foundation
import SwiftUI

/// MainWindow のメインコンテンツの表示モード。
/// - project: 既存の 1 project = 1 画面
/// - tile: 全 project のターミナル pane を grid で並べた監視ビュー
enum ViewMode: String, Codable {
	case project
	case tile

	/// project 以外のモード (= sidebar / browser を hide すべき時)
	var isDedicatedView: Bool {
		switch self {
		case .project: return false
		case .tile: return true
		}
	}

	/// view mode 切替時に使う共通アニメーション。Cmd+\ (sidebar) / Cmd+E (editor)
	/// と同じ snappy spring でテンポを揃える。
	static func toggleAnimation(showing: Bool) -> Animation {
		showing
			? .interpolatingSpring(stiffness: 1280, damping: 56)
			: .easeOut(duration: 0.05)
	}
}
