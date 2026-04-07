import Foundation

/// Monitors /tmp/belve-agent-events for agent status changes.
/// Falls back from OSC transport when /dev/tty is not available (e.g. Claude Code hooks).
class AgentEventFileMonitor {
	private let filePath = "/tmp/belve-agent-events"
	private var fileHandle: FileHandle?
	private var source: DispatchSourceFileSystemObject?
	private var fileOffset: UInt64 = 0
	private var partialLineBuffer = ""

	var onEvent: ((String, String, String) -> Void)? // (paneId, status, message)

	func start() {
		// Create file if needed
		if !FileManager.default.fileExists(atPath: filePath) {
			FileManager.default.createFile(atPath: filePath, contents: nil)
		}

		// Start from end of file (only new events)
		if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
		   let size = attrs[.size] as? UInt64 {
			fileOffset = size
		}

		guard let fh = FileHandle(forReadingAtPath: filePath) else {
			NSLog("[Belve] AgentEventFileMonitor: cannot open \(filePath)")
			return
		}
		self.fileHandle = fh

		let fd = fh.fileDescriptor
		let src = DispatchSource.makeFileSystemObjectSource(
			fileDescriptor: fd,
			eventMask: [.write, .extend],
			queue: .global(qos: .utility)
		)
		src.setEventHandler { [weak self] in
			self?.readNewEvents()
		}
		src.setCancelHandler {
			fh.closeFile()
		}
		src.resume()
		self.source = src
		NSLog("[Belve] AgentEventFileMonitor: watching \(filePath)")
	}

	private func readNewEvents() {
		guard let fh = fileHandle else { return }

		// Check file size
		guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
			  let size = attrs[.size] as? UInt64 else { return }

		if size <= fileOffset {
			if size < fileOffset {
				fileOffset = 0 // File was truncated
				partialLineBuffer = ""
			}
			return
		}

		fh.seek(toFileOffset: fileOffset)
		let data = fh.readData(ofLength: Int(size - fileOffset))
		fileOffset = size

		guard let str = String(data: data, encoding: .utf8) else { return }
		let lines = consume(str)

		for line in lines {
			guard let jsonData = line.data(using: .utf8),
				  let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
				  let paneId = event["paneId"] as? String,
				  let status = event["status"] as? String,
				  let message = event["message"] as? String
			else { continue }

			NSLog("[Belve] AgentEventFileMonitor: paneId=\(paneId) status=\(status) message=\(message)")

			DispatchQueue.main.async { [weak self] in
				self?.onEvent?(paneId, status, message)
			}
		}
	}

	func consume(_ chunk: String) -> [String] {
		guard !chunk.isEmpty else { return [] }
		partialLineBuffer += chunk
		let segments = partialLineBuffer.components(separatedBy: "\n")
		if partialLineBuffer.hasSuffix("\n") {
			partialLineBuffer = ""
			return segments.filter { !$0.isEmpty }
		}

		partialLineBuffer = segments.last ?? ""
		return segments.dropLast().filter { !$0.isEmpty }
	}

	func stop() {
		source?.cancel()
		source = nil
		fileHandle = nil
	}
}
