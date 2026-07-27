import Foundation

/// PTY 出力ストリームから belve-status OSC 9 シーケンス
/// (`ESC ] 9 ; belve-status ; <message> BEL`) を抽出する純粋パーサ。
///
/// 入力はチャンク境界が任意 (read() の切れ目) なので、プレフィックスは見つかったが
/// 終端 (BEL) がまだ来ていない末尾を `trailingData` として呼び出し側に返し、次チャンクの
/// 先頭に連結して再スキャンさせる。
///
/// **無限膨張ガード (`maxPendingBytes`)**: mid-OSC で接続が切れる / replay が途中で切れる等で
/// BEL が永久に来ないプレフィックスが宙ぶらりんになると、以後の全出力が trailing に吸い込まれて
/// 無限に伸び、数十GB でプロセスが殺される (実測: 100GB で macOS がクラッシュ)。pending が
/// 上限を超えたら「BEL 無しの偽プレフィックス」と判断し、literal 出力として吐いて保持を打ち切る。
/// 実際の status メッセージは短いのでこの上限で取りこぼさない。
///
/// Coordinator 非依存の純粋関数として切り出し、unit-test 可能にしている。
enum BelveStatusOSCParser {
	/// belve-status OSC の終端 (BEL) 待ちで保持する pending バイト数の上限。
	static let defaultMaxPendingBytes = 4096

	struct Result {
		let messages: [String]
		let outputData: Data
		let trailingData: Data
		/// pending が上限を超えて保持を打ち切った (= BEL 無しの偽プレフィックスを検出した)。
		/// 稀な異常経路なので呼び出し側がログできるようにフラグで返す。
		let didExceedPendingCap: Bool

		init(messages: [String], outputData: Data, trailingData: Data, didExceedPendingCap: Bool = false) {
			self.messages = messages
			self.outputData = outputData
			self.trailingData = trailingData
			self.didExceedPendingCap = didExceedPendingCap
		}
	}

	/// - Parameters:
	///   - data: 前回の `trailingData` に新チャンクを連結したもの。
	///   - maxPendingBytes: BEL 待ちで保持する pending の上限 (超過で literal 出力に切替)。
	static func extract(from data: Data, maxPendingBytes: Int = defaultMaxPendingBytes) -> Result {
		let prefix = Array("\u{1b}]9;belve-status;".utf8)
		let suffix: UInt8 = 0x07
		let bytes = Array(data)
		var messages: [String] = []
		var output = Data()
		var cursor = 0
		var lastCopied = 0

		while cursor + prefix.count <= bytes.count {
			if Array(bytes[cursor..<(cursor + prefix.count)]) != prefix {
				cursor += 1
				continue
			}

			if lastCopied < cursor {
				output.append(contentsOf: bytes[lastCopied..<cursor])
			}

			var end = cursor + prefix.count
			while end < bytes.count {
				if bytes[end] == suffix {
					let messageBytes = Data(bytes[(cursor + prefix.count)..<end])
					if let message = String(data: messageBytes, encoding: .utf8), !message.isEmpty {
						messages.append(message)
					}
					cursor = end + 1
					lastCopied = cursor
					break
				}
				end += 1
			}

			if end == bytes.count {
				// BEL がまだ来ていない。pending が上限を超えたら偽プレフィックスと判断し
				// literal 出力として吐いて保持を打ち切る (無限膨張の防止)。
				if bytes.count - cursor > maxPendingBytes {
					output.append(contentsOf: bytes[cursor...])
					return Result(messages: messages, outputData: output, trailingData: Data(), didExceedPendingCap: true)
				}
				return Result(messages: messages, outputData: output, trailingData: Data(bytes[cursor...]))
			}
		}

		if lastCopied < bytes.count {
			output.append(contentsOf: bytes[lastCopied...])
		}
		return Result(messages: messages, outputData: output, trailingData: Data())
	}
}
