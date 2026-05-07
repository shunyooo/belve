import Foundation
import CoreServices

/// macOS FSEventStream を使った local 用 file watcher。Remote は
/// belve-persist の RPC push で fsevent を受けてるが、local にはそれが無いので
/// terminal で `mkdir` / `mv` 等した時にファイルツリーが反映されないという
/// 問題があった (= 2026-05-05 報告)。
///
/// 1 watcher = 1 root path。`start(rootPath:)` で root を切替えると古い stream は
/// release される。Callback は debounce 用に latency 250ms を内蔵。
/// `.git` 配下の event は呼び出し側が無視する想定 (このクラスは raw event
/// 配信のみ)。
final class LocalFileWatcher {
	var onChanged: (([String]) -> Void)?

	private var stream: FSEventStreamRef?
	private var currentPath: String?

	deinit {
		stop()
	}

	func start(rootPath: String) {
		guard currentPath != rootPath else { return }
		stop()
		currentPath = rootPath

		var context = FSEventStreamContext(
			version: 0,
			info: Unmanaged.passUnretained(self).toOpaque(),
			retain: nil,
			release: nil,
			copyDescription: nil
		)
		let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
			guard let info else { return }
			let watcher = Unmanaged<LocalFileWatcher>.fromOpaque(info).takeUnretainedValue()
			// kFSEventStreamCreateFlagUseCFTypes 指定済みなので eventPaths は
			// CFArray (= [String]) として bridge できる。フラグ無しで cast
			// すると 2026-05-05 の callback クラッシュ (objc_msgSend に
			// invalid pointer) を起こす。
			let cfPaths = Unmanaged<CFArray>.fromOpaque(UnsafeRawPointer(eventPaths))
				.takeUnretainedValue()
			let paths = (cfPaths as? [String]) ?? []
			DispatchQueue.main.async {
				watcher.onChanged?(paths)
			}
		}
		let pathsToWatch = [rootPath] as CFArray
		guard let s = FSEventStreamCreate(
			kCFAllocatorDefault,
			callback,
			&context,
			pathsToWatch,
			FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
			0.25,
			FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
		) else {
			NSLog("[Belve][filewatch][local] FSEventStreamCreate failed root=%@", rootPath)
			return
		}
		FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
		FSEventStreamStart(s)
		stream = s
		NSLog("[Belve][filewatch][local] started watching %@", rootPath)
	}

	func stop() {
		if let stream {
			FSEventStreamStop(stream)
			FSEventStreamInvalidate(stream)
			FSEventStreamRelease(stream)
		}
		stream = nil
		currentPath = nil
	}
}
