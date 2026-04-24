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
		case .runningSubagent: return Theme.purple
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
			PixelSpriteIndicator(status: status, color: color, data: PixelSprites.invader)
		case .ghost:
			PixelSpriteIndicator(status: status, color: color, data: PixelSprites.ghost)
		case .cat:
			PixelSpriteIndicator(status: status, color: color, data: PixelSprites.cat)
		case .dog:
			PixelSpriteIndicator(status: status, color: color, data: PixelSprites.dog)
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

// MARK: - Pixel sprite (汎用キャラクター描画)

/// 8x8 grid の pixel sprite。`runFrames` を循環で running 表現、`restFrame` を
/// 静止系 (waiting / completed / idle) に使う分離設計。
/// `runFrames` が 2 frame でも 4 frame でもよい (= キャラごとに動きの粒度を変えられる)。
struct PixelSpriteData {
	let runFrames: [[[Bool]]]   // running 用の循環アニメ (length >= 1)
	let restFrame: [[Bool]]     // waiting / completed / idle 用の静止 pose
	let runInterval: TimeInterval  // frame 切替間隔。多 frame は 短く (= 脚が速く動く)
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
			SpriteCanvas(frame: data.restFrame, color: color)
		case .sessionStart, .idle:
			SpriteCanvas(frame: data.restFrame, color: color.opacity(0.4))
		}
	}

	private func running() -> some View {
		TimelineView(.periodic(from: .now, by: data.runInterval)) { ctx in
			let tick = Int(ctx.date.timeIntervalSinceReferenceDate / data.runInterval)
			let frameIndex = tick % data.runFrames.count
			// 走ってる時の body bob (1 frame ごとに少し上下)
			let yOffset: CGFloat = (tick % 2 == 0) ? -0.4 : 0.4
			SpriteCanvas(frame: data.runFrames[frameIndex], color: color)
				.offset(y: yOffset)
		}
	}

	private func restingBob(interval: TimeInterval) -> some View {
		TimelineView(.periodic(from: .now, by: interval)) { ctx in
			let tick = Int(ctx.date.timeIntervalSinceReferenceDate / interval)
			let yOffset: CGFloat = (tick % 2 == 0) ? -0.3 : 0.3
			SpriteCanvas(frame: data.restFrame, color: color)
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
	// 8x8。`.` 以外を ON 扱い (`1` でも `#` でも OK)。

	// Invader (元のスペースインベーダー風、足が左右で入れ替わる)
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
		runInterval: 0.4
	)

	// Ghost (波打つ裾)
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
		runInterval: 0.4
	)

	// Cat (横向き全身、頭=右、尻尾=左、ピン耳、4 脚)
	// 4-frame walk cycle で脚が前後にしっかり動く。rest = 座り pose。
	static let cat = PixelSpriteData(
		runFrames: [
			// frame 1: 全脚下 (=接地直前)
			grid([
				"......##",
				"#....###",
				"##.#####",
				".#######",
				".#######",
				".#######",
				"#.#..#.#",
				"#.#..#.#",
			]),
			// frame 2: 前左+後右 上、前右+後左 下 (= 1/4 stride)
			grid([
				"......##",
				"#....###",
				"##.#####",
				".#######",
				".#######",
				".#######",
				".##..#.#",
				"##....#.",
			]),
			// frame 3: 全脚開き (= mid-stride)
			grid([
				"......##",
				"#....###",
				"##.#####",
				".#######",
				".#######",
				".#######",
				"##....##",
				"#......#",
			]),
			// frame 4: 前右+後左 上、前左+後右 下 (= 3/4 stride)
			grid([
				"......##",
				"#....###",
				"##.#####",
				".#######",
				".#######",
				".#######",
				"#.#..##.",
				".#....##",
			]),
		],
		// 止まった時は顔アップ (8x8 で全身座りは認識難)。両ピン耳 + 目 + 鼻口
		// で「猫がこっち見てる」感を出す。
		restFrame: grid([
			"#......#",  // ピン耳の先 (両側に大きく)
			"##....##",  // 耳本体
			"########",  // 頭頂部
			"##.##.##",  // 目 (両側、白目で gap)
			"########",  // 鼻周り
			"###..###",  // 口 (Y字 / 鼻下の隙間)
			"########",  // 顎
			".######.",  // 顎下
		]),
		runInterval: 0.12  // 速いコマ送りで「走ってる」感
	)

	// Dog (横向き全身、頭=右、垂れ耳、尻尾=左、4 太脚)
	// 4-frame walk cycle。猫より一回り大きい / どっしりした見た目。
	static let dog = PixelSpriteData(
		runFrames: [
			// frame 1: 全脚下
			grid([
				".....###",
				"#...####",
				"########",
				"########",
				"########",
				"########",
				"##.##.##",
				"##.##.##",
			]),
			// frame 2: 1/4 stride
			grid([
				".....###",
				"#...####",
				"########",
				"########",
				"########",
				"########",
				".##.##.#",
				"##....#.",
			]),
			// frame 3: 全開
			grid([
				".....###",
				"#...####",
				"########",
				"########",
				"########",
				"########",
				"##....##",
				"#......#",
			]),
			// frame 4: 3/4 stride
			grid([
				".....###",
				"#...####",
				"########",
				"########",
				"########",
				"########",
				"#.##.##.",
				".#....##",
			]),
		],
		// おすわり pose: 正面向き、垂れ耳 + 目 + 前脚。猫より太め。
		restFrame: grid([
			"##....##",  // 垂れ耳の上
			"##....##",  // 垂れ耳
			"########",  // 頭
			"##.##.##",  // 目
			"########",  // 鼻 / 顔下
			"########",  // 胸 (太い)
			".######.",  // 体下
			"##....##",  // 前脚 (左右に外向き)
		]),
		runInterval: 0.13
	)

	private static func grid(_ rows: [String]) -> [[Bool]] {
		rows.map { $0.map { $0 != "." } }
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
				Button {
					config.spinnerStyle = style
				} label: {
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
							StatusIndicator(status: s, styleOverride: style)
								.frame(maxWidth: .infinity)
						}
					}
					.padding(.vertical, 6)
					.background(
						selected ? Theme.surfaceActive : Color.clear
					)
				}
				.buttonStyle(.plain)
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
