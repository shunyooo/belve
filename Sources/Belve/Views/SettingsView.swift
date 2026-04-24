import SwiftUI

struct SettingsView: View {
	@ObservedObject var config = AppConfig.shared
	@State private var excludeText: String = ""
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			// Header
			HStack {
				Text("Settings")
					.font(.system(size: 15, weight: .bold))
					.foregroundStyle(Theme.textPrimary)
				Spacer()
				Button {
					dismiss()
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

			Theme.borderSubtle.frame(height: 1)

			ScrollView {
				VStack(alignment: .leading, spacing: 20) {
					// Status indicator style
					settingsSection(title: "Status indicator", icon: "circle.dotted") {
						VStack(alignment: .leading, spacing: 8) {
							Text("行 = スタイル、列 = 状態。クリックで選択。色が状態 (running/waiting/done 等) を表します。")
								.font(.system(size: 10))
								.foregroundStyle(Theme.textTertiary.opacity(0.7))
								.fixedSize(horizontal: false, vertical: true)

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

						StatusIndicatorMatrix()

							// Live preview with current style + size
							VStack(alignment: .leading, spacing: 6) {
								Text("Preview")
									.font(.system(size: 11, weight: .medium))
									.foregroundStyle(Theme.textSecondary)
								HStack(spacing: 16) {
									previewItem(status: .running, label: "Running")
									previewItem(status: .waiting, label: "Waiting")
									previewItem(status: .completed, label: "Done")
									previewItem(status: .idle, label: "Idle")
								}
								.padding(.vertical, 8)
								.padding(.horizontal, 12)
								.background(
									RoundedRectangle(cornerRadius: 6)
										.fill(Theme.surfaceActive)
								)
							}
						}
					}

					// File Tree Exclusion
					settingsSection(title: "File Tree", icon: "folder.badge.minus") {
						VStack(alignment: .leading, spacing: 6) {
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
								.frame(minHeight: 140)
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
				.padding(20)
			}
		}
		.frame(width: 460, height: 640)
		.background(Theme.bg)
		.onAppear {
			excludeText = config.excludePatterns.joined(separator: "\n")
		}
	}

	private func previewItem(status: AgentStatus, label: String) -> some View {
		VStack(spacing: 4) {
			StatusIndicator(status: status)
			Text(label)
				.font(.system(size: 9))
				.foregroundStyle(Theme.textTertiary)
		}
	}

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
