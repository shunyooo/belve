import Foundation

/// Protocol for receiving agent status updates from terminal processes.
/// Abstracted so the transport can be swapped (OSC → Socket in the future).
protocol AgentNotificationTransport: AnyObject {
	/// Called when agent status changes. (paneId, status, message)
	var onAgentStatus: ((String, String, String) -> Void)? { get set }
}

/// OSC-based transport: scans PTY output for BELVE: prefixed OSC 9 sequences.
/// Buffers partial data across chunks since OSC sequences can span chunk boundaries.
class OSCAgentTransport: AgentNotificationTransport {
	var onAgentStatus: ((String, String, String) -> Void)?
	private var partialBuffer = ""

	/// Scan data for BELVE:<pane_id>:<status>:<message> in OSC 9 sequences.
	func scan(_ data: Data) {
		guard let str = String(data: data, encoding: .utf8) else { return }

		// Only buffer if there's a potential BELVE sequence in progress or starting
		if partialBuffer.isEmpty && !str.contains("BELVE") && !str.contains("\u{1b}") {
			return
		}

		partialBuffer += str

		// Try to extract complete OSC sequences
		let escOSC = "\u{1b}]9;BELVE:"
		let bel = "\u{07}"

		while let startRange = partialBuffer.range(of: escOSC) {
			guard let endRange = partialBuffer.range(of: bel, range: startRange.upperBound..<partialBuffer.endIndex) else {
				// Incomplete sequence — keep buffered, but limit buffer size
				if partialBuffer.count > 2000 {
					// Discard stale data before the last ESC
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

			// Parse: <pane_id>:<status>:<message>
			let parts = payload.split(separator: ":", maxSplits: 2)
			guard parts.count >= 2 else { continue }
			let paneId = String(parts[0])
			let status = String(parts[1])
			let message = parts.count > 2 ? String(parts[2]) : ""

			DispatchQueue.main.async { [weak self] in
				self?.onAgentStatus?(paneId, status, message)
			}
		}

		// If no more BELVE prefix pending, clear buffer
		if !partialBuffer.contains("BELVE") && !partialBuffer.contains("\u{1b}]9;") {
			partialBuffer = ""
		}
	}
}
