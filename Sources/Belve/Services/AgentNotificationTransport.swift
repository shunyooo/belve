import Foundation

/// Protocol for receiving agent status updates from terminal processes.
/// Abstracted so the transport can be swapped (OSC → Socket in the future).
protocol AgentNotificationTransport: AnyObject {
	/// Called when agent status changes. (paneId, status, message)
	var onAgentStatus: ((String, String, String) -> Void)? { get set }
}

/// OSC-based transport: scans PTY output for BELVE: prefixed OSC 9 sequences.
class OSCAgentTransport: AgentNotificationTransport {
	var onAgentStatus: ((String, String, String) -> Void)?

	/// Scan data for BELVE:<pane_id>:<status>:<message> in OSC 9 sequences.
	func scan(_ data: Data) {
		guard let str = String(data: data, encoding: .utf8) else { return }

		// Pattern: \x1b]9;BELVE:<pane_id>:<status>:<message>\x07
		guard let pattern = try? NSRegularExpression(
			pattern: "\u{1b}\\]9;BELVE:([^:]+):([^:]+):([^\u{07}\u{1b}]*)\u{07}"
		) else { return }

		let nsStr = str as NSString
		let range = NSRange(location: 0, length: nsStr.length)

		pattern.enumerateMatches(in: str, range: range) { match, _, _ in
			guard let match,
				  let paneIdRange = Range(match.range(at: 1), in: str),
				  let statusRange = Range(match.range(at: 2), in: str),
				  let messageRange = Range(match.range(at: 3), in: str)
			else { return }

			let paneId = String(str[paneIdRange])
			let status = String(str[statusRange])
			let message = String(str[messageRange])

			DispatchQueue.main.async { [weak self] in
				self?.onAgentStatus?(paneId, status, message)
			}
		}
	}

	/// Check if data contains a BELVE: OSC sequence (to skip generic notification).
	func containsBelveOSC(_ data: Data) -> Bool {
		guard let str = String(data: data, encoding: .utf8) else { return false }
		return str.contains("BELVE:")
	}
}
