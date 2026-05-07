import SwiftUI

/// 1 つの floating companion panel に乗る SwiftUI 内容。
/// レイアウト: avatar (左) + speech bubble (右) で横並び。
/// status の色味は StatusIndicator が自動で切替えてくれる。
struct AgentCompanionView: View {
	@ObservedObject var model: AgentCompanionViewModel
	@ObservedObject private var store = AgentCompanionStore.shared

	private var isSelected: Bool {
		store.isSelected(model.companion.paneId)
	}

	/// 展開中の message id。click で toggle。
	@State private var expandedMessageId: UUID?
	/// ヘッダ (= ユーザー指示) の展開。
	@State private var expandedHeader = false
	/// Tool 行の展開。
	@State private var expandedTool = false

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			// Header: project name + user prompt
			VStack(alignment: .leading, spacing: 3) {
				Text(model.companion.projectName)
					.font(.system(size: 13, weight: .bold))
					.foregroundStyle(Theme.accent)
					.lineLimit(1)
				if !model.companion.userPrompt.isEmpty {
					HStack(alignment: .top, spacing: 5) {
						Text(">")
							.font(.system(size: 12, weight: .bold, design: .monospaced))
							.foregroundStyle(Theme.yellow)
						Text(model.companion.userPrompt)
							.font(.system(size: 12, weight: .medium))
							.foregroundStyle(Theme.textPrimary)
							.lineLimit(expandedHeader ? nil : 2)
							.fixedSize(horizontal: false, vertical: expandedHeader)
							.textSelection(.enabled)
					}
				}
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 7)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.fill(Theme.surface.opacity(0.92))
					.shadow(color: .black.opacity(0.15), radius: 2, y: 1)
			)
			.onTapGesture {
				withAnimation(.easeOut(duration: 0.15)) {
					expandedHeader.toggle()
				}
			}

			// Agent area: [avatar + name] + [bubbles + tool]
			HStack(alignment: .bottom, spacing: 14) {
				// Avatar + project name below
				StatusIndicator(
					status: model.companion.status,
					styleOverride: model.companion.avatarStyle,
					sizeOverride: 48
				)
				.frame(width: 72, height: 72)
				.contentShape(Rectangle())
				.onTapGesture {
					store.clearSelection()
					focusInMainApp()
				}

				VStack(alignment: .leading, spacing: 4) {
					// Agent の思考 / 発言 bubble (= tool 以外)
					ForEach(model.companion.messages) { msg in
						let isExpanded = expandedMessageId == msg.id
						let isLatest = msg.id == model.companion.messages.last?.id
						messageBubble(msg, isExpanded: isExpanded, hasTail: isLatest)
							.transition(.move(edge: .bottom).combined(with: .opacity))
							.onTapGesture {
								let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
								if mods.contains(.command) {
									store.toggleSelection(model.companion.paneId)
								} else {
									withAnimation(.easeOut(duration: 0.15)) {
										expandedMessageId = expandedMessageId == msg.id ? nil : msg.id
									}
								}
							}
					}
					.animation(.easeOut(duration: 0.2), value: model.companion.messages.count)

					// 現在の tool (= 固定高でインライン表示、click で展開)
					HStack(spacing: 4) {
						Image(systemName: "wrench.and.screwdriver")
							.font(.system(size: 8))
						Text(model.companion.currentTool ?? "")
							.lineLimit(expandedTool ? nil : 1)
							.truncationMode(.middle)
							.fixedSize(horizontal: false, vertical: expandedTool)
					}
					.font(.system(size: 9))
					.foregroundStyle(Theme.accent.opacity(0.8))
					.padding(.leading, 4)
					.frame(minHeight: 14, alignment: .leading)
					.frame(maxWidth: .infinity, alignment: .leading)
					.opacity(model.companion.currentTool != nil ? 1 : 0)
					.onTapGesture {
						withAnimation(.easeOut(duration: 0.15)) {
							expandedTool.toggle()
						}
					}
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .bottomLeading)
		.background(
			GeometryReader { geo in
				Color.clear.preference(key: CompanionSizeKey.self, value: geo.size)
			}
		)
		.onPreferenceChange(CompanionSizeKey.self) { size in
			guard let panel = NSApp.windows.first(where: {
				($0 as? AgentCompanionPanel)?.paneId == model.companion.paneId
			}) as? AgentCompanionPanel else { return }
			panel.fitToSize(size)
		}
		.contextMenu {
			Button("Change Avatar") {
				store.cycleAvatar(model.companion.paneId)
			}
			Divider()
			Button("Dismiss") {
				AgentCompanionWindowManager.shared.dismiss(paneId: model.companion.paneId)
				store.dismissManually(model.companion.paneId)
			}
		}
	}

	@ViewBuilder
	private func messageBubble(_ msg: CompanionMessage, isExpanded: Bool, hasTail: Bool) -> some View {
		Text(msg.text)
			.font(.system(size: 12, weight: .medium))
			.foregroundStyle(Theme.textPrimary)
			.lineLimit(isExpanded ? nil : 3)
			.fixedSize(horizontal: false, vertical: isExpanded)
			.textSelection(.enabled)
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 10)
		.padding(.vertical, 8)
		.background(
			Group {
				if hasTail {
					SpeechBubbleShape(tailOnLeft: true)
						.fill(Theme.surface.opacity(0.92))
						.overlay(
							SpeechBubbleShape(tailOnLeft: true)
								.stroke(
									isSelected ? Theme.accent : borderColor.opacity(0.3),
									lineWidth: isSelected ? 2 : 1
								)
						)
				} else {
					RoundedRectangle(cornerRadius: 10, style: .continuous)
						.fill(Theme.surface.opacity(0.92))
						.overlay(
							RoundedRectangle(cornerRadius: 10, style: .continuous)
								.stroke(
									isSelected ? Theme.accent : borderColor.opacity(0.3),
									lineWidth: isSelected ? 2 : 1
								)
						)
				}
			}
			.shadow(color: .black.opacity(0.15), radius: 3, y: 1)
		)
	}

	private var borderColor: Color {
		switch model.companion.status {
		case .running, .runningSubagent: return Theme.accent
		case .waiting: return Theme.yellow
		case .completed, .sessionEnd: return Theme.green
		default: return Theme.borderSubtle
		}
	}

	private var detailColor: Color {
		switch model.companion.status {
		case .waiting: return Theme.yellow
		case .running, .runningSubagent: return Theme.textSecondary
		default: return Theme.textTertiary
		}
	}

}

private struct CompanionSizeKey: PreferenceKey {
	static var defaultValue: CGSize = .zero
	static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
		value = nextValue()
	}
}

/// 吹き出し Shape。左 (or 右) に小さい三角の tail が付く。
/// avatar → bubble の「喋ってる感」を出すための形状。
private struct SpeechBubbleShape: Shape {
	let tailOnLeft: Bool
	private let cornerRadius: CGFloat = 10
	private let tailWidth: CGFloat = 8
	private let tailHeight: CGFloat = 6

	func path(in rect: CGRect) -> Path {
		var path = Path()
		let r = cornerRadius
		// Body は常に rect 全幅 (= tail の有無で body 位置がズレない)。
		// tail は body 左端から外に飛び出す形で描画。
		path.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r))
		if tailOnLeft {
			// tail を bubble の縦中央に配置 (= avatar の「口」の高さに合わせる)
			let tailY = rect.midY - tailHeight / 2
			path.move(to: CGPoint(x: rect.minX, y: tailY))
			path.addLine(to: CGPoint(x: rect.minX - tailWidth, y: tailY + tailHeight / 2))
			path.addLine(to: CGPoint(x: rect.minX, y: tailY + tailHeight))
			path.closeSubpath()
		}
		return path
	}
}

private extension AgentCompanionView {
	/// Click → main app を前面化 + 該当 view にジャンプ。Sidebar の session row click
	/// と同じ動線 (= belveFocusProject + paneId 渡し)。
	func focusInMainApp() {
		NSApp.activate(ignoringOtherApps: true)
		NotificationCenter.default.post(
			name: .belveFocusProject,
			object: nil,
			userInfo: ["projectId": model.companion.projectId]
		)
		NotificationCenter.default.post(
			name: .belveTileActivatePane,
			object: nil,
			userInfo: ["projectId": model.companion.projectId, "paneId": model.companion.paneId]
		)
	}
}
