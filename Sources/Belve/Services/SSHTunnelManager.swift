import Foundation

/// **Phase 3 移行後**: SSH tunnel の実体は Mac master daemon (`belve-persist
/// -mac-master`) が持っている。このクラスは MasterClient への薄い wrapper で、
/// 既存呼び出し元の API 互換性を保つために残してある。
///
/// 今後の方針: 呼び出し元を直接 `MasterClient.shared` に置き換えれば、この
/// class 自体が不要になる (= Phase 5 cleanup の対象)。
final class SSHTunnelManager: @unchecked Sendable {
	static let shared = SSHTunnelManager()
	private init() {}

	/// host への SSH ControlMaster を保証 (master が spawn する)。
	func ensureControlMaster(host: String) async throws {
		try await MasterClient.shared.ensureControlMaster(host: host)
	}

	/// Per-VM router 用の forward を保証し、Mac 側 local port を返す。
	func ensureRouterForward(host: String, remotePort: Int = 19200) async throws -> Int {
		try await MasterClient.shared.ensureRouterForward(host: host, remotePort: remotePort)
	}

	/// 全 forward + master を teardown。BelveApp 起動時 / 終了時に呼ばれる。
	/// 本来は master が常駐するので「Belve.app 起動時の stale 掃除」は不要だが、
	/// 互換性のため残す (= no-op に近い)。Master 側で実際の cleanup を行う。
	func teardownAll() {
		Task.detached {
			do {
				try await MasterClient.shared.teardownAllTunnels()
			} catch {
				NSLog("[Belve][tunnel] teardownAll IPC failed: %@", error.localizedDescription)
			}
		}
	}

	/// 特定 project の tunnel teardown。Phase 3 段階では、router forward を
	/// 共有 (= host 単位) してるので per-project teardown は no-op。Phase 4 で
	/// session ベースの teardown が要るかもしれない。
	func teardownTunnel(host: String, projectId: UUID) {
		// no-op: per-project tunnel は廃止 (Phase B + 3 で host-shared 化済)
	}
}
