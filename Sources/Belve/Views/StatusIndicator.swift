import SwiftUI

/// Sidebar の session row 等で使う「動作中インジケータ」のスタイル選択。
/// AppConfig で永続化。形は固定、色 (status) と動きの両方で意味を伝える。
enum SpinnerStyle: String, CaseIterable, Codable {
	case pulse      // 円ベース、状態で pulse 速度/振幅が変わる
	case invader    // ピクセルアート (Space Invader インスパイア)
	case ghost      // おばけ
	case cat        // 猫 (横向き全身、running で脚が前後)
	case dog        // 犬 (横向き全身、running で脚が前後)
	case braille    // ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏
	case dotsWave   // 単点が circle 状に巡回
	case bar        // ▁▂▃▄▅▆▇█▇▆▅▄▃▂

	var displayName: String {
		switch self {
		case .pulse: return "Pulse"
		case .invader: return "Invader"
		case .ghost: return "Ghost"
		case .cat: return "Cat"
		case .dog: return "Dog"
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
	@ObservedObject private var config = AppConfig.shared

	private var resolvedStyle: SpinnerStyle {
		styleOverride ?? config.spinnerStyle
	}

	private var color: Color {
		switch status {
		case .running: return Theme.accent
		case .waiting: return Theme.yellow
		case .completed, .sessionEnd: return Theme.green
		case .sessionStart, .idle: return Theme.textTertiary
		}
	}

	var body: some View {
		// 9 分岐 (≤ ViewBuilder の switch 限界) を直接 return。AnyView で wrap すると
		// 子の TimelineView の view identity が安定せず SwiftUI AG::Graph::update で
		// SIGBUS する事象あり (2026-04-24)。
		switch resolvedStyle {
		case .pulse:
			PulseIndicator(status: status, color: color)
		case .invader:
			PixelSpriteIndicator(status: status, color: color, frames: PixelSprites.invader)
		case .ghost:
			PixelSpriteIndicator(status: status, color: color, frames: PixelSprites.ghost)
		case .cat:
			PixelSpriteIndicator(status: status, color: color, frames: PixelSprites.cat)
		case .dog:
			PixelSpriteIndicator(status: status, color: color, frames: PixelSprites.dog)
		case .braille:
			TextSpinnerIndicator(status: status, color: color, frames: SpinnerFrames.braille, interval: 0.08, restFrame: "⠿")
		case .dotsWave:
			TextSpinnerIndicator(status: status, color: color, frames: SpinnerFrames.dotsWave, interval: 0.18, restFrame: "•")
		case .bar:
			TextSpinnerIndicator(status: status, color: color, frames: SpinnerFrames.bar, interval: 0.10, restFrame: "█")
		}
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
		let isActive = status == .running || status == .waiting
		let opacityFill = status == .completed || status == .sessionEnd ? 1.0 : (isActive ? 1.0 : 0.3)
		let pulseScale: CGFloat = status == .running ? 1.4 : (status == .waiting ? 1.15 : 1.0)
		let pulsePeriod: Double = status == .running ? 1.2 : 2.0

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

// MARK: - Pixel sprite (汎用キャラクター描画)

/// 8x8 grid の pixel sprite を status 駆動でアニメさせる共通コンポーネント。
/// running: frame[0] / frame[1] を 400ms で alternate
/// waiting: frame[0] のまま 600ms で y 方向に bob
/// completed/sessionEnd: frame[0] static (色: green)
/// sessionStart/idle: frame[0] static (薄)
private struct PixelSpriteIndicator: View {
	let status: AgentStatus
	let color: Color
	let frames: [[[Bool]]]  // 最低 1 frame、running 時は最大 2 frame swap

	var body: some View {
		switch status {
		case .running:
			animated(interval: 0.4, bob: false)
		case .waiting:
			animated(interval: 0.6, bob: true, useFirstFrameOnly: true)
		case .completed, .sessionEnd:
			SpriteCanvas(frame: frames[0], color: color)
		case .sessionStart, .idle:
			SpriteCanvas(frame: frames[0], color: color.opacity(0.4))
		}
	}

	private func animated(interval: TimeInterval, bob: Bool, useFirstFrameOnly: Bool = false) -> some View {
		TimelineView(.periodic(from: .now, by: interval)) { ctx in
			let tick = Int(ctx.date.timeIntervalSinceReferenceDate / interval)
			let frameIndex = useFirstFrameOnly ? 0 : (tick % frames.count)
			let yOffset: CGFloat = bob ? (tick % 2 == 0 ? -0.5 : 0.5) : 0
			SpriteCanvas(frame: frames[frameIndex], color: color)
				.offset(y: yOffset)
		}
	}
}

private struct SpriteCanvas: View {
	let frame: [[Bool]]
	let color: Color

	var body: some View {
		Canvas { gc, size in
			let cols = frame.first?.count ?? 8
			let cell = size.width / CGFloat(cols)
			for (y, row) in frame.enumerated() {
				for (x, on) in row.enumerated() where on {
					let rect = CGRect(
						x: CGFloat(x) * cell,
						y: CGFloat(y) * cell,
						width: cell,
						height: cell
					)
					gc.fill(Path(rect), with: .color(color))
				}
			}
		}
		.frame(width: 10, height: 10)
	}
}

// MARK: - Sprite definitions

private enum PixelSprites {
	// 8x8。`1` = 塗る、`.` = 透明。
	// 文字列 → bool grid に parse する helper を最後に定義。

	// Invader (元のスペースインベーダー風、足が左右で入れ替わる歩行)
	static let invader: [[[Bool]]] = [
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
	]

	// Ghost (丸い頭、波打つ裾)
	static let ghost: [[[Bool]]] = [
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
	]

	// Cat (横向き全身、頭=右、尻尾=左、ピン耳、4 脚)
	// frame1: 4 脚揃って立つ。frame2: 前後脚を前後に開いて running pose。
	static let cat: [[[Bool]]] = [
		grid([
			"......##",  // ピン耳 (右側=頭)
			"#....###",  // 尻尾の先 + 頭
			"##..####",  // 尻尾 + 頭/背中
			".#######",  // 体
			".#######",  // 体
			".#######",  // 腹
			"#.#..#.#",  // 4 脚 (前2 + 後2)
			"#.#..#.#",  // 足 (床)
		]),
		grid([
			"......##",
			"#....###",
			"##..####",
			".#######",
			".#######",
			".#######",
			"##....##",  // 前脚は後ろへ、後脚は前へ (走り pose)
			"#......#",  // 足が伸びてる
		]),
	]

	// Dog (横向き全身、頭=右、垂れ耳、尻尾=左ピン、4 脚)
	// 猫より体ががっしり、耳が垂れてる、尻尾は短く真っ直ぐ。
	static let dog: [[[Bool]]] = [
		grid([
			".....###",  // 頭 (耳含む)
			"#...####",  // 尻尾の付け根 + 垂れ耳 + 頭
			"########",  // 背中 + 体全長
			"########",  // 体
			"########",  // 体
			"########",  // 腹
			"##.##.##",  // 4 太脚
			"##.##.##",  // 足
		]),
		grid([
			".....###",
			"#...####",
			"########",
			"########",
			"########",
			"########",
			"##....##",  // 前脚後ろ、後脚前 (running)
			"#......#",  // 足伸びる
		]),
	]

	private static func grid(_ rows: [String]) -> [[Bool]] {
		// `.` 以外を ON 扱い (`1` でも `#` でも何でも OK)。スプライト定義の自由度を上げる。
		rows.map { $0.map { $0 != "." } }
	}
}

// MARK: - Text spinner (CLI classic)

/// running: 通常速度、waiting: ×2.5 でゆっくり、completed: restFrame で静止、
/// その他: restFrame を opacity 落として静止。
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
		case .waiting:
			animated(interval: interval * 2.5)
		case .completed, .sessionEnd:
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

/// 選択中の style を全 status で並べて表示する settings 用ギャラリー row。
/// 各 status の動き/色を見比べられる。
struct StatusIndicatorGallery: View {
	let style: SpinnerStyle
	private let states: [(AgentStatus, String)] = [
		(.idle, "Idle"),
		(.sessionStart, "Start"),
		(.running, "Running"),
		(.waiting, "Waiting"),
		(.completed, "Done"),
	]

	var body: some View {
		HStack(alignment: .top, spacing: 14) {
			ForEach(states, id: \.0) { (s, label) in
				VStack(spacing: 4) {
					StatusIndicator(status: s, styleOverride: style)
					Text(label)
						.font(.system(size: 9))
						.foregroundStyle(Theme.textTertiary)
				}
			}
		}
	}
}
