import Foundation

/// Protocol for receiving agent status updates from terminal processes.
/// Abstracted so the transport can be swapped (OSC → Socket in the future).
protocol AgentNotificationTransport: AnyObject {
	/// Called when agent status changes. (paneId, sessionId, status, message)。
	/// sessionId は claude code hook の `session_id` (= OSC BELVE2 形式)。
	/// 旧 BELVE 形式 (= sessionId 無し) からの event は sessionId="" で渡される。
	var onAgentStatus: ((String, String, String, String) -> Void)? { get set }
}

/// OSC-based transport: scans PTY output for BELVE: / BELVE2: prefixed OSC 9
/// sequences. Buffers partial data across chunks since OSC sequences can span
/// chunk boundaries.
///
/// - `BELVE2:<paneId>:<sessionId>:<status>:<message>` — 現行形式。session_id を
///   含むので NotificationStore で「pane あたり primary session」識別ができる
///   (= Stop hook で spawn された別 claude を識別して通知抑制)。
/// - `BELVE:<paneId>:<status>:<message>` — 旧形式。replay や古い hook script
///   からの event のため互換維持。sessionId は空文字で渡す。
class OSCAgentTransport: AgentNotificationTransport {
	var onAgentStatus: ((String, String, String, String) -> Void)?
	private var partialBuffer = ""

	func scan(_ data: Data) {
		guard let str = String(data: data, encoding: .utf8) else { return }

		// Only buffer if there's a potential BELVE sequence in progress or starting
		if partialBuffer.isEmpty && !str.contains("BELVE") && !str.contains("\u{1b}") {
			return
		}

		partialBuffer += str

		let bel = "\u{07}"
		let oscPrefix = "\u{1b}]9;"

		while let startRange = partialBuffer.range(of: oscPrefix) {
			guard let endRange = partialBuffer.range(of: bel, range: startRange.upperBound..<partialBuffer.endIndex) else {
				// Incomplete sequence — keep buffered, but limit buffer size
				if partialBuffer.count > 2000 {
					if let lastEsc = partialBuffer.range(of: "\u{1b}", options: .backwards) {
						partialBuffer = String(partialBuffer[lastEsc.lowerBound...])
					} else {
						partialBuffer = ""
					}
				}
				return
			}

			let payload = String(partialBuffer[startRange.upperBound..<endRange.lowerBound])
			partialBuffer = String(partialBuffer[endRange.upperBound...])

			// BELVE2: 4 fields (paneId, sessionId, status, message)
			if payload.hasPrefix("BELVE2:") {
				let body = String(payload.dropFirst("BELVE2:".count))
				let parts = body.split(separator: ":", maxSplits: 3)
				guard parts.count >= 3 else { continue }
				let paneId = String(parts[0])
				let sessionId = String(parts[1])
				let status = String(parts[2])
				let message = parts.count > 3 ? String(parts[3]) : ""
				DispatchQueue.main.async { [weak self] in
					self?.onAgentStatus?(paneId, sessionId, status, message)
				}
			} else if payload.hasPrefix("BELVE:") {
				// Legacy 形式: 3 fields。sessionId 空で通知。
				let body = String(payload.dropFirst("BELVE:".count))
				let parts = body.split(separator: ":", maxSplits: 2)
				guard parts.count >= 2 else { continue }
				let paneId = String(parts[0])
				let status = String(parts[1])
				let message = parts.count > 2 ? String(parts[2]) : ""
				DispatchQueue.main.async { [weak self] in
					self?.onAgentStatus?(paneId, "", status, message)
				}
			}
			// その他の OSC 9 (= claude 自身の terminal title 設定等) は素通し。
		}

		if !partialBuffer.contains("BELVE") && !partialBuffer.contains("\u{1b}]9;") {
			partialBuffer = ""
		}
	}
}
