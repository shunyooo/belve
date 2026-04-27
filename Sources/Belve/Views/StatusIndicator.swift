import SwiftUI

/// Sidebar の session row 等で使う「動作中インジケータ」のスタイル選択。
/// AppConfig で永続化。形は固定、色 (status) と動きの両方で意味を伝える。
enum SpinnerStyle: String, CaseIterable, Codable {
	case pulse        // 円ベース、状態で pulse 速度/振幅が変わる
	case invader      // ピクセルアート (Space Invader インスパイア)
	case ghost        // おばけ
	case chibiCat     // ちび黒猫 (Viggle 生成、anti-aliased illustration)。state 別 outline 色変更
	case rainbowCat   // 黒猫 with 虹色 outline cycle (Lottie 由来、単一アニメ × speed で状態表現)
	case partyParrot  // Party Parrot (Cult of the Party Parrot 公式 GIF)
	case braille      // ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏
	case dotsWave     // 単点が circle 状に巡回
	case bar          // ▁▂▃▄▅▆▇█▇▆▅▄▃▂

	var displayName: String {
		switch self {
		case .pulse: return "Pulse"
		case .invader: return "Invader"
		case .ghost: return "Ghost"
		case .chibiCat: return "Chibi Cat"
		case .rainbowCat: return "Rainbow Cat"
		case .partyParrot: return "Party Parrot"
		case .braille: return "Braille spinner"
		case .dotsWave: return "Dots wave"
		case .bar: return "Bar"
		}
	}
}

/// Status と現在の SpinnerStyle 設定から適切な描画を返す共通 view。
/// 動きと色の両方が status に応じて変わる:
/// - running: 通常速度、accent 色
/// - waiting: ゆっくり/別動作、yellow
/// - completed: 静止 (落ち着いたポーズ)、green
/// - sessionEnd: 静止、green
/// - sessionStart, idle: 静止 (薄)、gray
struct StatusIndicator: View {
	let status: AgentStatus
	/// 設定を無視して特定スタイルで描画したい時 (settings の preview 等) に渡す。
	var styleOverride: SpinnerStyle? = nil
	/// サイズを上書きしたい時 (settings preview 等)。nil = config の値。
	var sizeOverride: CGFloat? = nil
	@ObservedObject private var config = AppConfig.shared

	private var resolvedStyle: SpinnerStyle {
		styleOverride ?? config.spinnerStyle
	}

	var resolvedSize: CGFloat {
		sizeOverride ?? config.spinnerSize
	}

	private var color: Color {
		switch status {
		case .running: return Theme.accent
		case .runningSubagent: return Theme.purple
		case .waiting: return Theme.yellow
		case .completed, .sessionEnd: return Theme.green
		case .sessionStart, .idle: return Theme.textTertiary
		}
	}

	var body: some View {
		let scale = resolvedSize / 10.0
		// 9 分岐 (≤ ViewBuilder の switch 限界) を直接 return。AnyView で wrap すると
		// 子の TimelineView の view identity が安定せず SwiftUI AG::Graph::update で
		// SIGBUS する事象あり (2026-04-24)。
		Group {
			switch resolvedStyle {
			case .pulse:
				PulseIndicator(status: status, color: color)
			case .invader:
				PixelSpriteIndicator(status: status, color: color, data: PixelSprites.invader)
			case .ghost:
				PixelSpriteIndicator(status: status, color: color, data: PixelSprites.ghost)
			case .chibiCat:
				// Viggle 由来 illustration (anti-aliased outline) なので .high で smooth scale。
				// State ごとに outline 色を変える (orange→yellow→green→gray):
				//   running/subagent = orange (走り cycle / 歩き cycle、active な作業中)
				//   waiting = yellow 静止 + ふわふわ (user 入力待ち)
				//   done = green 静止 (完了)
				//   idle/start = gray dim 静止 (float なし、目立たせない)
				PNGSpriteIndicator(
					status: status,
					runFrames: (0...47).map { "chibicat-run-\($0)" },
					restFrame: "chibicat-rest",
					runInterval: 0.083,
					subagentFrames: (0...11).map { "chibicat-walk-\($0)" },
					subagentInterval: 0.083,
					waitingFrames: ["chibicat-waiting"],
					waitingInterval: 1.0,
					completedFrames: ["chibicat-done"],
					completedInterval: 1.0,
					idleFrames: ["chibicat-idle"],
					idleInterval: 1.0,
					interpolation: .high,
					trimPadding: false, // 既に union bbox で揃え済み (個別 trim すると jitter)
					enableBob: false,   // 源 video に body bob が既に入ってる
					idleFloat: false,
					waitingFloat: true
				)
			case .rainbowCat:
				// 単一アニメ (32f, 虹色 outline cycle) を active 系では速度で state 表現、
				// done = 完全静止 (1 枚)、idle/start = 同 1 枚 + ふわふわ float。
				// active = フル虹 cycle 速度差、waiting = 黄 + float、
				// done = 緑 静止、idle/start = 灰 静止 (float なし)
				let cycle = (0...31).map { "rainbocat-cycle-\($0)" }
				PNGSpriteIndicator(
					status: status,
					runFrames: cycle,
					restFrame: "rainbocat-rest",
					runInterval: 0.05,
					subagentFrames: cycle,
					subagentInterval: 0.08,
					waitingFrames: ["rainbocat-waiting"],
					waitingInterval: 1.0,
					completedFrames: ["rainbocat-done"],
					completedInterval: 1.0,
					idleFrames: ["rainbocat-idle"],
					idleInterval: 1.0,
					interpolation: .high,
					trimPadding: false,
					enableBob: false,
					idleFloat: false,
					waitingFloat: true
				)
			case .partyParrot:
				// 高品質 Lottie 由来 (LottieFiles 公式 Party Parrot, 31f, 虹色羽毛 cycle)。
				// rainbow cat と同パターン: active = フル虹 cycle 速度差、waiting = 黄 + float、
				// done = 緑 静止、idle/start = 灰 静止 (float なし)。
				let parrot = (0...30).map { "parrot-cycle-\($0)" }
				PNGSpriteIndicator(
					status: status,
					runFrames: parrot,
					restFrame: "parrot-rest",
					runInterval: 0.025,
					subagentFrames: parrot,
					subagentInterval: 0.05,
					waitingFrames: ["parrot-waiting"],
					waitingInterval: 1.0,
					completedFrames: ["parrot-done"],
					completedInterval: 1.0,
					idleFrames: ["parrot-idle"],
					idleInterval: 1.0,
					interpolation: .high,
					trimPadding: false,
					enableBob: false,
					idleFloat: false,
					waitingFloat: true
				)
			case .braille:
				TextSpinnerIndicator(status: status, color: color, frames: SpinnerFrames.braille, interval: 0.08, restFrame: "⠿")
			case .dotsWave:
				TextSpinnerIndicator(status: status, color: color, frames: SpinnerFrames.dotsWave, interval: 0.18, restFrame: "•")
			case .bar:
				TextSpinnerIndicator(status: status, color: color, frames: SpinnerFrames.bar, interval: 0.10, restFrame: "█")
			}
		}
		.scaleEffect(scale)
		.frame(width: resolvedSize, height: resolvedSize)
	}
}

// MARK: - Pulse

/// running: 1.2s 周期で大きく拡張、waiting: 2s 周期で小さめ拡張、
/// completed: 静止した塗り、idle/sessionStart/sessionEnd: 薄/濃の静止円。
private struct PulseIndicator: View {
	let status: AgentStatus
	let color: Color
	@State private var pulsePhase: CGFloat = 0

	var body: some View {
		let isActive = status == .running || status == .runningSubagent || status == .waiting
		let opacityFill = status == .completed || status == .sessionEnd ? 1.0 : (isActive ? 1.0 : 0.3)
		let pulseScale: CGFloat = status == .running || status == .runningSubagent ? 1.4 : (status == .waiting ? 1.15 : 1.0)
		let pulsePeriod: Double = status == .runningSubagent ? 1.6 : (status == .running ? 1.2 : 2.0)

		Circle()
			.fill(color.opacity(opacityFill))
			.frame(width: 6, height: 6)
			.overlay(
				Group {
					if isActive {
						Circle()
							.stroke(color.opacity(0.4), lineWidth: 1.5)
							.frame(width: 10, height: 10)
							.scaleEffect(pulsePhase == 1 ? pulseScale : 1.0)
							.opacity(pulsePhase == 1 ? 0 : 0.6)
					}
				}
			)
			.frame(width: 10, height: 10)
			.onAppear {
				if isActive {
					withAnimation(.easeInOut(duration: pulsePeriod).repeatForever(autoreverses: false)) {
						pulsePhase = 1
					}
				}
			}
			.id(status)
	}
}

// MARK: - PNG sprite (PixelLab AI で生成したフルカラーキャラ用)

/// PNG sprite を Image で描画する indicator。Cat / Dog 等、AI で生成した
/// フルカラー pixel art を扱う。Status ごとに異なる sprite cycle を当てられる。
///
/// 必須: `runFrames` (running) / `restFrame` (fallback static)
/// 任意:
///   - `subagentFrames`: runningSubagent 用 (= slow-walk 等)
///   - `waitingFrames`:  waiting 用 (= こっち向き idle 等)
///   - `completedFrames`: completed/sessionEnd 用 (= sit 等)
///   - `idleFrames`: sessionStart/idle 用 (= sleep 等)。指定なしなら restFrame を opacity 0.5 で静止
///   - 各 *Interval で frame 切替速度を個別制御
private struct PNGSpriteIndicator: View {
	let status: AgentStatus
	let runFrames: [String]
	let restFrame: String
	let runInterval: TimeInterval
	var subagentFrames: [String]? = nil
	var subagentInterval: TimeInterval = 0.2
	var waitingFrames: [String]? = nil
	var waitingInterval: TimeInterval = 0.2
	var completedFrames: [String]? = nil
	var completedInterval: TimeInterval = 0.2
	var idleFrames: [String]? = nil
	var idleInterval: TimeInterval = 0.25
	// Pixel art (cat/dog) は .none、anti-aliased illustration (halloween cat) は .high
	var interpolation: Image.Interpolation = .none
	// PixelLab sprites は frame ごとに padding がバラバラ → 個別 trim で揃える。
	// Halloween cat は事前に union bbox 揃えで export 済みなので、ここで再 trim
	// すると frame ごとに微妙に extent 違って scale が変わり jitter する → false で skip。
	var trimPadding: Bool = true
	// pixel art 用 ±0.4pt bounce。源 frame に既に body bob が入ってる illustration では
	// 二重モーションで jitter に見えるので false で無効化できる。
	var enableBob: Bool = true
	// idle/sessionStart で frame サイクルではなく「1 枚をふわふわ上下」表示にする。
	// idleFrames の最初の 1 枚を sin-curve で滑らかに float。完全静止な完了状態 (.completed)
	// との差別化に使う ("done" は止まり、"idle" は息してる感)。
	var idleFloat: Bool = false
	// waiting で「1 枚をふわふわ上下」表示にする。waitingFrames の最初の 1 枚を sin-curve で float。
	// active 系のサイクルではなく "user 入力待ち = 静止 + 呼吸" を表現したい時に使う。
	var waitingFloat: Bool = false

	var body: some View {
		switch status {
		case .running:
			cycle(runFrames, interval: runInterval, bob: enableBob)
		case .runningSubagent:
			cycle(subagentFrames ?? runFrames, interval: subagentInterval, bob: enableBob)
		case .waiting:
			if waitingFloat, let frames = waitingFrames, !frames.isEmpty {
				floatStatic(frames[0])
			} else {
				cycle(waitingFrames ?? [restFrame], interval: waitingInterval, bob: false)
			}
		case .completed, .sessionEnd:
			cycle(completedFrames ?? [restFrame], interval: completedInterval, bob: false)
		case .sessionStart, .idle:
			if let frames = idleFrames, !frames.isEmpty {
				if idleFloat {
					floatStatic(frames[0], opacity: 0.85)
				} else {
					cycle(frames, interval: idleInterval, bob: false, opacity: 0.85)
				}
			} else {
				spriteImage(restFrame).opacity(0.5)
			}
		}
	}

	/// 1 枚の sprite を sin curve で y 方向にゆっくり上下 (= ふわふわ呼吸感)。
	/// period = 2.5s、振幅 ±0.6pt。idle/sessionStart の「止まってるけど生きてる」表現用。
	private func floatStatic(_ name: String, opacity: Double = 1.0) -> some View {
		TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
			let t = ctx.date.timeIntervalSinceReferenceDate
			let yOffset = CGFloat(sin(t * 2 * .pi / 2.5)) * 0.6
			spriteImage(name)
				.offset(y: yOffset)
				.opacity(opacity)
		}
	}

	@ViewBuilder
	private func cycle(_ frames: [String], interval: TimeInterval, bob: Bool, opacity: Double = 1.0) -> some View {
		if frames.isEmpty {
			spriteImage(restFrame)
		} else {
			TimelineView(.periodic(from: .now, by: interval)) { ctx in
				let tick = Int(ctx.date.timeIntervalSinceReferenceDate / interval)
				let frameIndex = tick % frames.count
				let yOffset: CGFloat = bob ? ((tick % 2 == 0) ? -0.4 : 0.4) : 0
				spriteImage(frames[frameIndex])
					.offset(y: yOffset)
					.opacity(opacity)
			}
		}
	}

	@ViewBuilder
	private func spriteImage(_ name: String) -> some View {
		if let nsImage = SpriteImageCache.shared.image(named: name, trim: trimPadding) {
			// PixelLab quadruped (cat/dog) は横長アスペクト比なので、`.fit` で 10x10
			// に収めると縦が小さく見える (= 他 style の 10x10 grid と比較して縮む)。
			// 14x14 frame で描画して視覚的サイズを揃える。layout は外側 scaleEffect
			// で resolvedSize に比例正規化される。
			Image(nsImage: nsImage)
				.interpolation(interpolation)
				.resizable()
				.aspectRatio(contentMode: .fit)
				.frame(width: 14, height: 14)
		} else {
			Color.clear.frame(width: 14, height: 14)
		}
	}
}

/// PNG sprite を bundle から load してキャッシュする singleton。
/// `Resources/sprites/<name>.png` を解決する。
/// Load 時に **透明 padding を auto-crop** してキャラ本体が frame を満たすようにする
/// (PixelLab は canvas が character より一回り大きい padding 付きで返してくる)。
final class SpriteImageCache: @unchecked Sendable {
	static let shared = SpriteImageCache()
	private let lock = NSLock()
	private var cache: [String: NSImage] = [:]

	func image(named name: String, trim: Bool = true) -> NSImage? {
		let key = trim ? name : "\(name)|notrim"
		lock.lock(); defer { lock.unlock() }
		if let cached = cache[key] { return cached }
		guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources/sprites"),
		      let img = NSImage(contentsOf: url) else {
			NSLog("[Belve] sprite not found: \(name).png")
			return nil
		}
		let result = trim ? (trimTransparentPadding(img) ?? img) : img
		cache[key] = result
		return result
	}

	/// Alpha > 0 の pixel の bounding box を求めて crop する。
	/// 透明 padding が削れて、表示時に同じ frame でも character がより大きく見える。
	private func trimTransparentPadding(_ image: NSImage) -> NSImage? {
		guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
		let width = cgImage.width
		let height = cgImage.height
		let bytesPerPixel = 4
		let bytesPerRow = width * bytesPerPixel
		var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
		let colorSpace = CGColorSpaceCreateDeviceRGB()
		guard let ctx = CGContext(
			data: &pixels, width: width, height: height,
			bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		) else { return nil }
		ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

		var minX = width, maxX = -1
		var minY = height, maxY = -1
		for y in 0..<height {
			for x in 0..<width {
				let alpha = pixels[(y * width + x) * 4 + 3]
				if alpha > 0 {
					if x < minX { minX = x }
					if x > maxX { maxX = x }
					if y < minY { minY = y }
					if y > maxY { maxY = y }
				}
			}
		}
		guard maxX >= minX, maxY >= minY else { return nil }
		let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
		guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
		return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
	}
}

// MARK: - Pixel sprite (汎用キャラクター描画)

/// pixel sprite。`runFrames` を循環で running 表現、`restFrame` を静止系
/// (waiting / completed / idle) に使う分離設計。
/// 各セルは Int の palette index: 0 = 透明、1+ = `palette` の色 (1-indexed)。
/// `palette` が nil なら monochrome 扱いで、index >0 の全セルを status color
/// で塗る (= 既存の Invader/Ghost のように status を色で表現するキャラ向け)。
struct PixelSpriteData {
	let runFrames: [[[Int]]]
	let restFrame: [[Int]]
	let runInterval: TimeInterval
	let palette: [Color]?       // nil = monochrome (status color), 配列 = 色付きキャラ
}

/// running: runFrames を runInterval で循環、subtle な y bob
/// runningSubagent: 親が subagent 待ち、走らず seated pose で軽く bob
/// waiting: restFrame で軽く bob (待機中の呼吸感)
/// completed/sessionEnd: restFrame static
/// sessionStart/idle: restFrame static (薄)
private struct PixelSpriteIndicator: View {
	let status: AgentStatus
	let color: Color
	let data: PixelSpriteData

	var body: some View {
		switch status {
		case .running:
			running()
		case .runningSubagent:
			restingBob(interval: 0.7)
		case .waiting:
			restingBob(interval: 0.6)
		case .completed, .sessionEnd:
			SpriteCanvas(frame: data.restFrame, color: color, palette: data.palette)
		case .sessionStart, .idle:
			SpriteCanvas(frame: data.restFrame, color: color.opacity(0.4), palette: data.palette)
				.opacity(0.4)
		}
	}

	private func running() -> some View {
		TimelineView(.periodic(from: .now, by: data.runInterval)) { ctx in
			let tick = Int(ctx.date.timeIntervalSinceReferenceDate / data.runInterval)
			let frameIndex = tick % data.runFrames.count
			// 走ってる時の body bob (1 frame ごとに少し上下)
			let yOffset: CGFloat = (tick % 2 == 0) ? -0.4 : 0.4
			SpriteCanvas(frame: data.runFrames[frameIndex], color: color, palette: data.palette)
				.offset(y: yOffset)
		}
	}

	private func restingBob(interval: TimeInterval) -> some View {
		TimelineView(.periodic(from: .now, by: interval)) { ctx in
			let tick = Int(ctx.date.timeIntervalSinceReferenceDate / interval)
			let yOffset: CGFloat = (tick % 2 == 0) ? -0.3 : 0.3
			SpriteCanvas(frame: data.restFrame, color: color, palette: data.palette)
				.offset(y: yOffset)
		}
	}
}

private struct SpriteCanvas: View {
	let frame: [[Int]]
	let color: Color           // monochrome 時の塗り色 (palette が nil の時に使う)
	let palette: [Color]?      // nil = 全 ON セルを `color` で塗る、配列 = idx-1 を使う

	var body: some View {
		Canvas { gc, size in
			let cols = frame.first?.count ?? 8
			let rows = frame.count
			// 非正方形 grid (e.g. 12x8 横長キャラ) を 10x10 frame 内に
			// アスペクト維持で center 配置。cell は min で揃えて square pixel。
			let cell = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
			let drawW = cell * CGFloat(cols)
			let drawH = cell * CGFloat(rows)
			let offsetX = (size.width - drawW) / 2
			let offsetY = (size.height - drawH) / 2
			for (y, row) in frame.enumerated() {
				for (x, idx) in row.enumerated() where idx > 0 {
					let cellColor: Color
					if let palette, idx <= palette.count {
						cellColor = palette[idx - 1]
					} else {
						cellColor = color
					}
					let rect = CGRect(
						x: offsetX + CGFloat(x) * cell,
						y: offsetY + CGFloat(y) * cell,
						width: cell,
						height: cell
					)
					gc.fill(Path(rect), with: .color(cellColor))
				}
			}
		}
		.frame(width: 10, height: 10)
	}
}

// MARK: - Sprite definitions

private enum PixelSprites {
	// `.` = 透明 (0)、`1`〜`9` = palette index (1-indexed)、`#` = 1 (index 1)。
	// palette = nil → status color で塗る (monochrome)、配列 → 各 index の色を使う。

	// Invader (status color で塗る monochrome キャラ)
	static let invader = PixelSpriteData(
		runFrames: [
			grid([
				"..1..1..",
				"...11...",
				"..1111..",
				".11..11.",
				"11111111",
				"1.1111.1",
				"1.1..1.1",
				"...11...",
			]),
			grid([
				"..1..1..",
				"1..11..1",
				"1.1111.1",
				"111..111",
				"11111111",
				".111111.",
				"..1..1..",
				".1....1.",
			]),
		],
		restFrame: grid([
			"..1..1..",
			"...11...",
			"..1111..",
			".11..11.",
			"11111111",
			"1.1111.1",
			"1.1..1.1",
			"...11...",
		]),
		runInterval: 0.4,
		palette: nil
	)

	// Ghost (status color、monochrome)
	static let ghost = PixelSpriteData(
		runFrames: [
			grid([
				".######.",
				"########",
				"##.##.##",
				"##.##.##",
				"########",
				"########",
				"########",
				"##.##.##",
			]),
			grid([
				".######.",
				"########",
				"##.##.##",
				"##.##.##",
				"########",
				"########",
				"########",
				".##.##.#",
			]),
		],
		restFrame: grid([
			".######.",
			"########",
			"##.##.##",
			"##.##.##",
			"########",
			"########",
			"########",
			"##.##.##",
		]),
		runInterval: 0.4,
		palette: nil
	)

	// 旧 PixelLab 由来の cat / dog 定義は SpinnerStyle から削除 (halloweenCat に統合)。

	/// `.` 以外は palette index (1-indexed)。`1`〜`9` の数字は数値、`#` は 1 として扱う。
	private static func grid(_ rows: [String]) -> [[Int]] {
		rows.map { $0.map { ch -> Int in
			if ch == "." || ch == " " { return 0 }
			if let n = ch.wholeNumberValue, n > 0 { return n }
			return 1   // `#` その他 → palette index 1
		}}
	}
}

// MARK: - Text spinner (CLI classic)

/// running: 通常速度、runningSubagent: ×2 でゆっくり (subagent 待ち感)、
/// waiting / completed / sessionEnd: restFrame static (= 動かない、color で区別)
/// sessionStart / idle: restFrame opacity 落として静止。
private struct TextSpinnerIndicator: View {
	let status: AgentStatus
	let color: Color
	let frames: [String]
	let interval: TimeInterval
	let restFrame: String

	var body: some View {
		switch status {
		case .running:
			animated(interval: interval)
		case .runningSubagent:
			animated(interval: interval * 2)
		case .waiting, .completed, .sessionEnd:
			Text(restFrame)
				.font(.system(size: 10, weight: .medium, design: .monospaced))
				.foregroundStyle(color)
				.frame(width: 10, height: 10, alignment: .center)
		case .sessionStart, .idle:
			Text(restFrame)
				.font(.system(size: 10, weight: .medium, design: .monospaced))
				.foregroundStyle(color.opacity(0.4))
				.frame(width: 10, height: 10, alignment: .center)
		}
	}

	private func animated(interval: TimeInterval) -> some View {
		TimelineView(.periodic(from: .now, by: interval)) { ctx in
			let i = Int(ctx.date.timeIntervalSinceReferenceDate / interval) % frames.count
			Text(frames[i])
				.font(.system(size: 10, weight: .medium, design: .monospaced))
				.foregroundStyle(color)
				.frame(width: 10, height: 10, alignment: .center)
		}
	}
}

private enum SpinnerFrames {
	static let braille = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
	static let dotsWave = ["⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈"]
	static let bar = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅", "▄", "▃", "▂"]
}

// MARK: - Status gallery (settings preview)

/// 全 style × 全 status の matrix を一覧で表示する settings 用テーブル。
/// 行 = style、列 = status。クリックで style を切替えられる。
struct StatusIndicatorMatrix: View {
	@ObservedObject var config = AppConfig.shared
	private let states: [(AgentStatus, String)] = [
		(.idle, "Idle"),
		(.sessionStart, "Start"),
		(.running, "Running"),
		(.runningSubagent, "Subagent"),
		(.waiting, "Waiting"),
		(.completed, "Done"),
	]

	var body: some View {
		VStack(spacing: 0) {
			// header row
			HStack(spacing: 0) {
				Text("Style")
					.font(.system(size: 9, weight: .medium))
					.foregroundStyle(Theme.textTertiary)
					.frame(width: 110, alignment: .leading)
					.padding(.horizontal, 8)
				ForEach(states, id: \.0) { (_, label) in
					Text(label)
						.font(.system(size: 9, weight: .medium))
						.foregroundStyle(Theme.textTertiary)
						.frame(maxWidth: .infinity)
				}
			}
			.padding(.vertical, 6)
			.background(Theme.surfaceActive.opacity(0.5))

			ForEach(SpinnerStyle.allCases, id: \.self) { style in
				let selected = config.spinnerStyle == style
				HStack(spacing: 0) {
					HStack(spacing: 6) {
						if selected {
							Image(systemName: "checkmark")
								.font(.system(size: 9, weight: .semibold))
								.foregroundStyle(Theme.accent)
						} else {
							Color.clear.frame(width: 9)
						}
						Text(style.displayName)
							.font(.system(size: 11))
							.foregroundStyle(Theme.textPrimary)
						Spacer()
					}
					.frame(width: 110, alignment: .leading)
					.padding(.horizontal, 8)
					ForEach(states, id: \.0) { (s, _) in
						StatusIndicator(status: s, styleOverride: style, sizeOverride: 18)
							.frame(maxWidth: .infinity)
					}
				}
				.padding(.vertical, 8)
				.background(selected ? Theme.surfaceActive : Color.clear)
				.contentShape(Rectangle())
				.onTapGesture {
					config.spinnerStyle = style
				}
				Divider().background(Theme.borderSubtle)
			}
		}
		.background(
			RoundedRectangle(cornerRadius: 6)
				.fill(Theme.surface)
		)
		.overlay(
			RoundedRectangle(cornerRadius: 6)
				.stroke(Theme.borderSubtle, lineWidth: 1)
		)
	}
}

/// 旧 API: 互換用に残す (= 既存呼び元が壊れないように)。新しい matrix UI 移行後は不要。
struct StatusIndicatorGallery: View {
	let style: SpinnerStyle
	var body: some View {
		StatusIndicatorMatrix()
	}
}
