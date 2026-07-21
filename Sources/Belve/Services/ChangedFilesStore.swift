import SwiftUI

/// このプロジェクト (working tree) で変更されたファイル 1 件。
/// 司令塔のセッションレビュー用に mtime を持ち、recency 順に並べるための軽量モデル。
/// ChangesView.ChangedFile が diff 本文と staged/commit 概念を持つのに対し、
/// こちらは「最近エージェントが触ったファイル」の一覧に特化する。
struct SessionChangedFile: Identifiable, Equatable {
	let status: String   // git porcelain status ("M", "A", "??", "D", "R", ...)
	let path: String     // repo 相対パス
	let modTime: Date?   // working tree の mtime (recency 用)。削除済みは nil

	var id: String { path }
	var filename: String { (path as NSString).lastPathComponent }
	var directory: String {
		let dir = (path as NSString).deletingLastPathComponent
		return dir.isEmpty ? "" : dir
	}

	var statusColor: Color {
		switch status {
		case "M", "MM": return Theme.yellow
		case "A", "??": return Theme.green
		case "D": return Theme.red
		case "R": return Theme.accent
		default: return Theme.textTertiary
		}
	}

	var statusLabel: String { status == "??" ? "U" : status }
}

/// プロジェクトの未コミット変更を recency (mtime 降順) で提供する Store。
/// 司令塔のレビューパネル「変更」モードのデータ源。
///
/// データ源は WorkspaceProvider の git op (control RPC 経由):
///   gitChangedFiles(args: []) で working tree の変更一覧を取り、各ファイルの
///   modificationDate (stat op) で mtime を付与して降順ソートする。
///
/// 「このセッションの変更」は現状 working tree の未コミット差分で近似する
/// (エージェントが直近に触ったファイル ≒ mtime が新しい変更ファイル)。厳密な
/// セッション baseline (開始時 HEAD からの差分) は将来拡張。
final class ChangedFilesStore: ObservableObject {
	@Published private(set) var files: [SessionChangedFile] = []
	@Published private(set) var isLoading = false

	/// 連続 refresh の競合を防ぐトークン。最新の取得結果だけを反映する。
	private var refreshToken = 0

	/// 指定プロジェクトの変更ファイルを取得して recency 順に反映する。
	func refresh(for project: Project) {
		refreshToken &+= 1
		let token = refreshToken
		isLoading = true
		let provider = project.provider
		let rootPath = project.effectivePath

		DispatchQueue.global(qos: .userInitiated).async { [weak self] in
			let changed = provider.gitChangedFiles(rootPath, args: [])
			let entries: [SessionChangedFile] = changed.map { status, path in
				let full = rootPath == "." ? path : (rootPath as NSString).appendingPathComponent(path)
				// 削除済みファイルは stat 不能なので mtime なし (末尾に並ぶ)。
				let mtime = status == "D" ? nil : provider.modificationDate(full)
				return SessionChangedFile(status: status, path: path, modTime: mtime)
			}
			let sorted = entries.sorted(by: Self.byRecency)

			DispatchQueue.main.async {
				guard let self, token == self.refreshToken else { return }
				self.files = sorted
				self.isLoading = false
			}
		}
	}

	/// mtime 降順。mtime を持つものが先、両方 nil はパス辞書順で安定化。
	private static func byRecency(_ a: SessionChangedFile, _ b: SessionChangedFile) -> Bool {
		switch (a.modTime, b.modTime) {
		case let (x?, y?): return x > y
		case (_?, nil): return true
		case (nil, _?): return false
		case (nil, nil): return a.path < b.path
		}
	}
}
