import Foundation

/// リモートプロジェクトで「ツリーの展開中フォルダ」を broker の fsnotify watch に
/// 追従させるサービス。fsnotify は非再帰なので、root だけ watch しても
/// サブディレクトリの変更はライブで拾えない (= フォーカスし直すまで反映されない)。
/// 展開されたフォルダだけを on-demand で watch/unwatch することで、可視範囲を
/// 軽量にカバーする (巨大 remote でも inotify 上限を食わないよう件数上限あり)。
///
/// fsevent の push 自体は `ProjectStore.subscribeRPCFsEvents` の既存ハンドラが
/// watchId 非依存で捌く (= どの watch から来ても debounced refresh に乗る) ので、
/// このサービスの責務は **watch の登録/解除の台帳管理だけ**。UI / refresh は持たない。
///
/// 全 mutation は main thread 前提 (`ProjectStore` から呼ばれる)。RPC 送信のみ Task。
protocol RemoteFolderWatching: AnyObject {
	/// `desiredPaths` (= 現在監視すべき絶対パス集合) に broker 側 watch を一致させる。
	/// 差分だけ watch/unwatch する冪等 diff。
	func reconcile(projectId: UUID, desiredPaths: Set<String>)
	/// 指定 project の watch を全解除する (project 切替時)。
	func stopAll(projectId: UUID)
}

final class RemoteFolderWatcher: RemoteFolderWatching {
	/// 同時 watch 数の上限 (opWatch は 1 dir = 1 inotify instance なので、Linux の
	/// per-process inotify instance 上限 (既定 ~128) を食い潰さないよう抑える)。
	private let maxWatches: Int

	private let clientResolver: (UUID) -> RemoteRPCClient?

	/// projectId → (絶対パス → watchId)。watchId="" は登録 RPC in-flight のプレースホルダ。
	private var watches: [UUID: [String: String]] = [:]
	/// projectId → 望む監視集合 (再接続時の張り直し用)。
	private var desired: [UUID: Set<String>] = [:]
	/// reconnect ハンドラ登録済みの client (client identity が変わったら張り直す)。
	private var reconnectClient: [UUID: RemoteRPCClient] = [:]
	/// projectId ごとの世代。reconnect / stopAll で++し、跨いだ in-flight add の
	/// 結果 (旧接続の無効な watchId) が台帳に混入するのを防ぐ。
	private var generation: [UUID: Int] = [:]

	init(maxWatches: Int = 64, clientResolver: @escaping (UUID) -> RemoteRPCClient?) {
		self.maxWatches = maxWatches
		self.clientResolver = clientResolver
	}

	/// 純粋な差分計算 (unit-test 面)。現在の台帳 `current` (path→watchId) と望む集合
	/// `desired` から、張るべき path (`toAdd`) と解除すべき (path, watchId) (`toRemove`)
	/// を返す。`.git`/空パス除外と件数上限 `maxWatches` を適用する。
	/// - Note: 上限は「解除後の残数」に対して効かせる (解除で空いた枠は再利用できる)。
	static func plan(current: [String: String], desired: Set<String>, maxWatches: Int)
		-> (toAdd: [String], toRemove: [(path: String, watchId: String)]) {
		let want = desired.filter { p in
			!p.isEmpty && !p.contains("/.git/") && !p.hasSuffix("/.git") && p != ".git"
		}
		let toRemove: [(String, String)] = current
			.filter { !want.contains($0.key) }
			.map { ($0.key, $0.value) }
		let remaining = current.count - toRemove.count
		var budget = max(0, maxWatches - remaining)
		var toAdd: [String] = []
		for path in want.sorted() where current[path] == nil {
			guard budget > 0 else { break }
			budget -= 1
			toAdd.append(path)
		}
		return (toAdd, toRemove)
	}

	func reconcile(projectId: UUID, desiredPaths: Set<String>) {
		guard let client = clientResolver(projectId) else { return }
		ensureReconnectHandler(projectId: projectId, client: client)

		var current = watches[projectId] ?? [:]
		let (toAdd, toRemove) = Self.plan(current: current, desired: desiredPaths, maxWatches: maxWatches)
		desired[projectId] = Self.gitFiltered(desiredPaths)
		let gen = generation[projectId] ?? 0

		for (path, id) in toRemove {
			current[path] = nil
			if !id.isEmpty {
				Task { _ = try? await client.send(op: "unwatch", params: ["watchId": id]) }
			}
		}
		for path in toAdd {
			// プレースホルダを先に入れ、連続 reconcile での二重登録を防ぐ。
			current[path] = ""
			addWatch(projectId: projectId, path: path, client: client, generation: gen)
		}
		watches[projectId] = current
	}

	func stopAll(projectId: UUID) {
		// 世代を上げて in-flight の add 結果を無効化する。
		generation[projectId, default: 0] += 1
		guard let client = clientResolver(projectId) else {
			watches[projectId] = nil
			desired[projectId] = nil
			return
		}
		for (_, id) in watches[projectId] ?? [:] where !id.isEmpty {
			Task { _ = try? await client.send(op: "unwatch", params: ["watchId": id]) }
		}
		watches[projectId] = nil
		desired[projectId] = nil
	}

	/// 1 件 watch を張り、結果を台帳へ反映する。`generation` は発行時点の世代で、
	/// 完了時に世代が変わっていたら (reconnect / stopAll) 結果を破棄し、掴んだ watch は
	/// 解放する (世代を跨いだ stale id の混入を防ぐ)。
	private func addWatch(projectId: UUID, path: String, client: RemoteRPCClient, generation gen: Int) {
		Task { [weak self] in
			let res = try? await client.send(op: "watch", params: ["path": path])
			let id = res?.result?["watchId"] as? String
			await MainActor.run {
				guard let self else { return }
				guard self.generation[projectId] == gen else {
					// 世代が変わった → この結果は無効。掴んだ watch を解放。
					if let id { Task { _ = try? await client.send(op: "unwatch", params: ["watchId": id]) } }
					return
				}
				var m = self.watches[projectId] ?? [:]
				// まだこの path を望んでいる時だけ確定。途中で collapse された場合は
				// プレースホルダが消えているので、掴んだ watch は即解除する。
				if m[path] == "" {
					if let id { m[path] = id } else { m[path] = nil }
					self.watches[projectId] = m
				} else if let id {
					Task { _ = try? await client.send(op: "unwatch", params: ["watchId": id]) }
				}
			}
		}
	}

	/// client ごとに一度だけ reconnect ハンドラを張る。再接続で broker 側 watch は
	/// 消えるので、世代を上げて台帳をクリアし、desired を **上限内で** 張り直す
	/// (root watch の再登録と同じ思想。cap を守るため plan を通す)。
	private func ensureReconnectHandler(projectId: UUID, client: RemoteRPCClient) {
		guard reconnectClient[projectId] !== client else { return }
		reconnectClient[projectId] = client
		client.subscribeReconnect { [weak self, weak client] in
			guard let self, let client else { return }
			DispatchQueue.main.async {
				self.generation[projectId, default: 0] += 1
				let gen = self.generation[projectId] ?? 0
				let want = self.desired[projectId] ?? []
				// current を空にして張り直す = 上限も改めて効かせる。
				let (toAdd, _) = Self.plan(current: [:], desired: want, maxWatches: self.maxWatches)
				var m: [String: String] = [:]
				for path in toAdd { m[path] = "" }
				self.watches[projectId] = m
				for path in toAdd {
					self.addWatch(projectId: projectId, path: path, client: client, generation: gen)
				}
			}
		}
	}

	/// `.git` / 空パスを除いた集合 (git status の書込みによる self-trigger loop 防止)。
	private static func gitFiltered(_ paths: Set<String>) -> Set<String> {
		paths.filter { p in
			!p.isEmpty && !p.contains("/.git/") && !p.hasSuffix("/.git") && p != ".git"
		}
	}
}
