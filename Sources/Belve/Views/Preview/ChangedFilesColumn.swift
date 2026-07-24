import SwiftUI

/// Preview 右カラムの「ツリー / 変更」モード切替。`fileColumnShowsChanges` を駆動する
/// コンパクトなセグメンテッドコントロール。カラム上部に載る。
struct FileColumnModeToggle: View {
	@Binding var showsChanges: Bool

	var body: some View {
		HStack(spacing: 2) {
			segment(title: "ツリー", active: !showsChanges) { showsChanges = false }
			segment(title: "変更", active: showsChanges) { showsChanges = true }
		}
		.padding(2)
		.background(Theme.bg)
		.clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
		.overlay(
			RoundedRectangle(cornerRadius: Theme.radiusSm)
				.stroke(Theme.borderSubtle, lineWidth: 1)
		)
		.padding(.horizontal, 6)
		.padding(.vertical, 5)
	}

	private func segment(title: String, active: Bool, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Text(title)
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
				.frame(maxWidth: .infinity)
				.padding(.vertical, 3)
				.background(active ? Theme.surfaceActive : Color.clear)
				.clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm - 2))
		}
		.buttonStyle(.plain)
	}
}

/// Preview 右カラムの「変更」モード本体。`ChangedFilesStore` の recency 順の変更
/// ファイル一覧を軽量に表示し、tap で editor に開く。full-panel の `ChangesView`
/// (diff 本文 / staged 概念を持ち editor を置換する) とは別物で、editor を隠さず
/// カラム内に収まる。
struct ChangedFilesColumn: View {
	@ObservedObject var store: ChangedFilesStore
	/// 現在 editor で開いているファイル path。一致行をハイライトする。
	let currentFilePath: String?
	let onSelect: (String) -> Void

	var body: some View {
		Group {
			if store.files.isEmpty && !store.isLoading {
				emptyState
			} else {
				ScrollView {
					VStack(alignment: .leading, spacing: 0) {
						ForEach(store.files) { file in
							ChangedFileRow(file: file, isCurrent: file.path == currentFilePath)
								.onTapGesture { onSelect(file.path) }
						}
					}
					.padding(.vertical, 4)
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.background(Theme.surface)
	}

	private var emptyState: some View {
		VStack(spacing: 6) {
			Image(systemName: "checkmark.circle")
				.font(.system(size: 20, weight: .thin))
				.foregroundStyle(Theme.textTertiary)
			Text("変更なし")
				.font(.system(size: 12))
				.foregroundStyle(Theme.textTertiary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

private struct ChangedFileRow: View {
	let file: SessionChangedFile
	let isCurrent: Bool
	@State private var isHovering = false

	var body: some View {
		HStack(spacing: 6) {
			Text(file.statusLabel)
				.font(.system(size: 10, weight: .bold, design: .monospaced))
				.foregroundStyle(file.statusColor)
				.frame(width: 14, alignment: .center)

			Text(file.filename)
				.font(.system(size: 13))
				.foregroundStyle(Theme.textPrimary)
				.lineLimit(1)

			if !file.directory.isEmpty {
				Text(file.directory)
					.font(.system(size: 11))
					.foregroundStyle(Theme.textTertiary)
					.lineLimit(1)
					.truncationMode(.head)
			}

			Spacer(minLength: 0)
		}
		.padding(.leading, 6)
		.padding(.trailing, 6)
		.padding(.vertical, 3)
		.background(background)
		.contentShape(Rectangle())
		.onHover { isHovering = $0 }
	}

	private var background: Color {
		if isCurrent { return Theme.surfaceSelected }
		if isHovering { return Theme.surfaceHover }
		return .clear
	}
}
