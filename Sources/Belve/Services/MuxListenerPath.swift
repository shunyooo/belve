import Foundation
import CryptoKit

/// Mac mac-master が host ごとに listen している per-host Unix socket の path
/// を計算する。Go 側 (`tools/belve-persist/mux.go` の `muxListenerPath`) と
/// 同じ計算式 (sha1(host) の先頭 6 byte を hex) でなければならない。
///
/// 互換性に注意: Go 側を変えたらこちらも合わせて変えること。
enum MuxListenerPath {
	static func forHost(_ host: String) -> String {
		let digest = Insecure.SHA1.hash(data: Data(host.utf8))
		let firstSix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
		return "/tmp/belve-mux-listener-\(firstSix).sock"
	}
}
