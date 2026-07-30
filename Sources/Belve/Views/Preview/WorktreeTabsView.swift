import SwiftUI

/// ファイルツリー上部に出る git worktree のタブ列。main + 各 worktree を pill で並べ、
/// 選択で Preview 側 (tree/editor/Changes) をその worktree に再ルートする。
/// Claude 製 (`.claude/worktrees/` 配下) にはマークを付ける。
///
/// 状態は持たない: 選択パスは `ProjectLayoutState.selectedWorktreePath` に置き、
/// ここは表示と callback だけ (単一責務)。worktree が 1 個以下 (main のみ) の時は
/// 何も描かない (共通ケースで縦スペースを食わない)。
struct WorktreeTabsView: View {
	let worktrees: [Worktree]
	/// nil = main 選択。非 nil = その worktree の絶対パス。
	let selectedPath: String?
	let onSelect: (Worktree) -> Void
	let onRefresh: () -> Void

	var body: some View {
		if worktrees.count > 1 {
			HStack(spacing: 4) {
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 4) {
						ForEach(worktrees) { wt in
							tab(wt)
						}
					}
					.padding(.horizontal, 6)
				}
				refreshButton
					.padding(.trailing, 6)
			}
			.frame(height: 30)
			.background(Theme.surface.opacity(0.5))
			Theme.borderSubtle.frame(height: 1)
		}
	}

	private func isSelected(_ wt: Worktree) -> Bool {
		if let selectedPath { return wt.path == selectedPath }
		return wt.isMain
	}

	private func tab(_ wt: Worktree) -> some View {
		let selected = isSelected(wt)
		return Button {
			onSelect(wt)
		} label: {
			HStack(spacing: 4) {
				if wt.isClaudeCreated {
					Image(systemName: "sparkle")
						.font(.system(size: 8, weight: .semibold))
						.foregroundStyle(Theme.accent)
				} else if wt.isMain {
					Image(systemName: "house")
						.font(.system(size: 8))
						.foregroundStyle(Theme.textSecondary)
				}
				Text(wt.displayLabel)
					.font(.system(size: 11, weight: selected ? .semibold : .regular))
					.foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
					.lineLimit(1)
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(
				RoundedRectangle(cornerRadius: 5)
					.fill(selected ? Theme.surfaceActive : Color.clear)
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help(wt.path)
	}

	private var refreshButton: some View {
		Button(action: onRefresh) {
			Image(systemName: "arrow.clockwise")
				.font(.system(size: 10, weight: .medium))
				.foregroundStyle(Theme.textSecondary)
		}
		.buttonStyle(.plain)
		.help("worktree 一覧を再取得")
	}
}
