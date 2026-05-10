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
	/// Warm-up window: この時刻まで BELVE OSC event を buffer する。
	/// Terminal reload 時の replay で過去 OSC が大量再 dispatch されて status が
	/// 高速で循環する事象を防ぎつつ、warm-up 終了時に最後の event だけ dispatch して
	/// 現在の status を復元する。
	var suppressUntil: Date?
	/// Warm-up 中に受け取った最後の event (= per paneId)。warm-up 終了後に dispatch。
	private var bufferedEvents: [(String, String, String, String)] = []
	private var warmupFlushed = false

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
			let bodyStart = startRange.upperBound
			let belRange = partialBuffer.range(of: bel, range: bodyStart..<partialBuffer.endIndex)
			// 次の OSC start prefix。前 OSC の BEL terminator が欠落した場合の
			// 防御 (= 次 OSC の prefix までを「ここで terminate されたとみなす」)。
			let nextStart = partialBuffer.range(of: oscPrefix, range: bodyStart..<partialBuffer.endIndex)

			let endIdx: String.Index
			if let belR = belRange, let nextR = nextStart {
				// BEL も次 OSC も見えてる → 早く来た方を terminator に
				endIdx = belR.lowerBound < nextR.lowerBound ? belR.lowerBound : nextR.lowerBound
			} else if let belR = belRange {
				endIdx = belR.lowerBound
			} else if let nextR = nextStart {
				// 次 OSC が見えてるが BEL が無い → 前 OSC は truncated。次 OSC 直前で切る。
				endIdx = nextR.lowerBound
			} else {
				// どちらも見えてない → buffer 続行 (size cap で stale 切り詰め)
				if partialBuffer.count > 4000 {
					if let lastEsc = partialBuffer.range(of: "\u{1b}", options: .backwards) {
						partialBuffer = String(partialBuffer[lastEsc.lowerBound...])
					} else {
						partialBuffer = ""
					}
				}
				return
			}

			let payload = String(partialBuffer[bodyStart..<endIdx])
			// terminator が BEL なら 1 文字、次 OSC start なら何もスキップしない
			let consumeUpTo: String.Index
			if endIdx < partialBuffer.endIndex, partialBuffer[endIdx] == "\u{07}" {
				consumeUpTo = partialBuffer.index(after: endIdx)
			} else {
				consumeUpTo = endIdx
			}
			partialBuffer = String(partialBuffer[consumeUpTo...])

			// BELVE2: 4 fields (paneId, sessionId, status, message)
			// Parse event
			var parsed: (String, String, String, String)?
			if payload.hasPrefix("BELVE2:") {
				let body = String(payload.dropFirst("BELVE2:".count))
				let parts = body.split(separator: ":", maxSplits: 3)
				if parts.count >= 3 {
					parsed = (String(parts[0]), String(parts[1]), String(parts[2]),
							  parts.count > 3 ? String(parts[3]) : "")
				}
			} else if payload.hasPrefix("BELVE:") {
				let body = String(payload.dropFirst("BELVE:".count))
				let parts = body.split(separator: ":", maxSplits: 2)
				if parts.count >= 2 {
					parsed = (String(parts[0]), "", String(parts[1]),
							  parts.count > 2 ? String(parts[2]) : "")
				}
			}
			guard let event = parsed else { continue }

			// Warm-up window 中は buffer に貯める (= 全 drop ではなく最後を保持)。
			// Warm-up 終了後に最後の event を dispatch → 現在 status が復元される。
			if let until = suppressUntil, Date() < until {
				bufferedEvents.append(event)
				continue
			}

			// Warm-up 終了: buffer に貯まってた最後の event を 1 回だけ flush
			if !warmupFlushed && !bufferedEvents.isEmpty {
				warmupFlushed = true
				// Per-paneId で最後の event だけ dispatch (= 最新 status を復元)
				var lastPerPane: [String: (String, String, String, String)] = [:]
				for e in bufferedEvents { lastPerPane[e.0] = e }
				bufferedEvents.removeAll()
				for (_, e) in lastPerPane {
					DispatchQueue.main.async { [weak self] in
						self?.onAgentStatus?(e.0, e.1, e.2, e.3)
					}
				}
			}

			DispatchQueue.main.async { [weak self] in
				self?.onAgentStatus?(event.0, event.1, event.2, event.3)
			}
			// その他の OSC 9 (= claude 自身の terminal title 設定等) は素通し。
		}

		if !partialBuffer.contains("BELVE") && !partialBuffer.contains("\u{1b}]9;") {
			partialBuffer = ""
		}
	}
}
