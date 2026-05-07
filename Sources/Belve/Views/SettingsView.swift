import SwiftUI

struct SettingsView: View {
	@ObservedObject var config = AppConfig.shared
	@State private var excludeText: String = ""
	@State private var selectedTab: SettingsTab = .display
	var onDismiss: (() -> Void)? = nil
	@Environment(\.dismiss) private var dismiss

	enum SettingsTab: String, CaseIterable {
		case display = "Display"
		case editor = "Editor"

		var icon: String {
			switch self {
			case .display: return "paintbrush"
			case .editor: return "doc.text"
			}
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			// Header
			HStack {
				Text("Settings")
					.font(.system(size: 15, weight: .bold))
					.foregroundStyle(Theme.textPrimary)
				Spacer()
				Button {
					if let onDismiss { onDismiss() } else { dismiss() }
				} label: {
					Image(systemName: "xmark.circle.fill")
						.font(.system(size: 16))
						.foregroundStyle(Theme.textTertiary)
				}
				.buttonStyle(.plain)
				.onHover { hovering in
					if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
				}
			}
			.padding(.horizontal, 20)
			.padding(.top, 18)
			.padding(.bottom, 12)

			// Tab bar
			HStack(spacing: 0) {
				ForEach(SettingsTab.allCases, id: \.self) { tab in
					tabButton(tab)
				}
			}
			.padding(.horizontal, 16)
			.padding(.bottom, 8)

			Theme.borderSubtle.frame(height: 1)

			// Tab content
			TabView(selection: $selectedTab) {
				ScrollView {
					displayTab.padding(20)
				}
				.tag(SettingsTab.display)

				ScrollView {
					editorTab.padding(20)
				}
				.tag(SettingsTab.editor)
			}
			.tabViewStyle(.automatic)
		}
		.frame(width: 460, height: 640)
		.background(Theme.bg)
		.onAppear {
			excludeText = config.excludePatterns.joined(separator: "\n")
		}
	}

	// MARK: - Tab Button

	private func tabButton(_ tab: SettingsTab) -> some View {
		Button {
			withAnimation(.easeOut(duration: 0.15)) {
				selectedTab = tab
			}
		} label: {
			HStack(spacing: 5) {
				Image(systemName: tab.icon)
					.font(.system(size: 11))
				Text(tab.rawValue)
					.font(.system(size: 12, weight: .medium))
			}
			.foregroundStyle(selectedTab == tab ? Theme.textPrimary : Theme.textTertiary)
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
			.background(
				RoundedRectangle(cornerRadius: 6)
					.fill(selectedTab == tab ? Theme.surfaceActive : Color.clear)
			)
		}
		.buttonStyle(.plain)
	}

	// MARK: - Display Tab

	private var displayTab: some View {
		VStack(alignment: .leading, spacing: 20) {
			settingsSection(title: "Status indicator", icon: "circle.dotted") {
				VStack(alignment: .leading, spacing: 8) {
					Text("行 = スタイル、列 = 状態。クリックで選択。")
						.font(.system(size: 10))
						.foregroundStyle(Theme.textTertiary.opacity(0.7))
						.fixedSize(horizontal: false, vertical: true)

					StatusIndicatorMatrix()
				}
			}

			settingsSection(title: "Size & Preview", icon: "slider.horizontal.3") {
				VStack(alignment: .leading, spacing: 10) {
					HStack(spacing: 12) {
						Text("Size")
							.font(.system(size: 11))
							.foregroundStyle(Theme.textSecondary)
						Slider(value: $config.spinnerSize, in: 6...24, step: 1)
							.frame(maxWidth: 160)
						Text("\(Int(config.spinnerSize))pt")
							.font(.system(size: 11, design: .monospaced))
							.foregroundStyle(Theme.textTertiary)
							.frame(width: 30, alignment: .trailing)
					}

					mockSessionPreview()
				}
			}
		}
	}

	// MARK: - Editor Tab

	private var editorTab: some View {
		VStack(alignment: .leading, spacing: 20) {
			settingsSection(title: "File Tree", icon: "folder.badge.minus") {
				VStack(alignment: .leading, spacing: 10) {
					HStack {
						Text("Position")
							.font(.system(size: 11))
							.foregroundStyle(Theme.textSecondary)
						Spacer()
						Picker("", selection: Binding(
							get: { config.fileTreePosition },
							set: { config.fileTreePosition = $0 }
						)) {
							Text("Left").tag(FileTreePosition.left)
							Text("Right").tag(FileTreePosition.right)
						}
						.pickerStyle(.segmented)
						.frame(width: 140)
					}

					Text("Hidden patterns")
						.font(.system(size: 11))
						.foregroundStyle(Theme.textTertiary)

					Text("One pattern per line. Files and folders matching these names will be hidden from the file tree.")
						.font(.system(size: 10))
						.foregroundStyle(Theme.textTertiary.opacity(0.7))
						.fixedSize(horizontal: false, vertical: true)

					TextEditor(text: $excludeText)
						.font(.system(size: 12, design: .monospaced))
						.foregroundStyle(Theme.textPrimary)
						.scrollContentBackground(.hidden)
						.padding(8)
						.frame(minHeight: 200)
						.background(
							RoundedRectangle(cornerRadius: 6)
								.fill(Theme.surfaceActive)
						)
						.overlay(
							RoundedRectangle(cornerRadius: 6)
								.strokeBorder(Theme.borderSubtle, lineWidth: 1)
						)
						.onChange(of: excludeText) { _, newValue in
							let patterns = newValue.components(separatedBy: "\n")
								.map { $0.trimmingCharacters(in: .whitespaces) }
								.filter { !$0.isEmpty }
							config.excludePatterns = patterns
							config.save()
						}
				}
			}
		}
	}

	// MARK: - Mock Session Preview

	private func mockSessionPreview() -> some View {
		VStack(spacing: 2) {
			mockSessionRow(status: .running, prompt: "API のエラーハンドリングを修正して", tool: "Edit", detail: "src/api/handler.ts")
			mockSessionRow(status: .waiting, prompt: "テストを書いて", waitingMessage: "Claude is waiting for your input")
			mockSessionRow(status: .completed, prompt: "ドキュメントを更新", detail: "Done")
			mockSessionRow(status: .idle, prompt: "Ready", detail: nil)
		}
		.padding(6)
		.background(
			RoundedRectangle(cornerRadius: 6)
				.fill(Theme.bg)
		)
		.overlay(
			RoundedRectangle(cornerRadius: 6)
				.stroke(Theme.borderSubtle, lineWidth: 1)
		)
	}

	@ViewBuilder
	private func mockSessionRow(status: AgentStatus, prompt: String, tool: String? = nil, detail: String? = nil, waitingMessage: String? = nil) -> some View {
		let isActive = status == .running || status == .waiting
		HStack(alignment: .top, spacing: 10) {
			VStack {
				Spacer().frame(height: 3)
				StatusIndicator(status: status)
			}
			VStack(alignment: .leading, spacing: 2) {
				Text(prompt)
					.font(.system(size: 11, weight: isActive ? .medium : .regular))
					.foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
					.lineLimit(2)
				if let tool {
					HStack(spacing: 3) {
						Image(systemName: "wrench.and.screwdriver")
							.font(.system(size: 8))
						Text(tool)
							.lineLimit(1)
					}
					.font(.system(size: 9))
					.foregroundStyle(Theme.accent)
				}
				if let detail {
					Text(detail)
						.font(.system(size: 9))
						.foregroundStyle(status == .completed ? Theme.green : Theme.textTertiary)
						.lineLimit(1)
				}
				if let waitingMessage {
					Text(waitingMessage)
						.font(.system(size: 9))
						.foregroundStyle(Theme.yellow)
						.lineLimit(1)
				}
				Text("now")
					.font(.system(size: 9))
					.foregroundStyle(Theme.textTertiary.opacity(0.6))
			}
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 5)
		.background(
			RoundedRectangle(cornerRadius: 4)
				.fill(isActive ? Theme.surfaceActive.opacity(0.3) : Color.clear)
		)
	}

	// MARK: - Section Helper

	private func settingsSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 6) {
				Image(systemName: icon)
					.font(.system(size: 12))
					.foregroundStyle(Theme.accent)
				Text(title)
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(Theme.textPrimary)
			}
			content()
		}
	}
}
