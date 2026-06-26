import SwiftUI

/// Sidebar 左下に置く ⓘ ボタン。click すると popover にショートカット一覧が出る。
/// 一覧は静的なので Source of Truth は本ファイルに置く (= BelveApp の handler と
/// 二重管理だが、Belve のショートカット数は数十個レベルなので run-time 反映の
/// 仕組みを入れるオーバーヘッドの方が大きい)。
struct ShortcutHelpButton: View {
	@State private var isShowing = false

	var body: some View {
		Button {
			isShowing.toggle()
		} label: {
			Image(systemName: "info.circle")
				.font(.system(size: 13))
				.foregroundStyle(Theme.textTertiary)
				.contentShape(Rectangle())
				.frame(width: 22, height: 22)
		}
		.buttonStyle(.plain)
		.help("Keyboard shortcuts")
		.popover(isPresented: $isShowing, arrowEdge: .top) {
			ShortcutHelpPopover()
		}
	}
}

private struct ShortcutHelpPopover: View {
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				Text("Keyboard Shortcuts")
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(Theme.textPrimary)
					.padding(.bottom, 2)

				section(title: "Project", items: [
					("⌘1 〜 ⌘9", "プロジェクト切替 (1-9 番目)"),
					("⌘⇧]", "次のプロジェクト"),
					("⌘⇧[", "前のプロジェクト"),
					("⌘O", "プロジェクト追加 (フォルダ選択)"),
					("⌘T", "Tile / Project view 切替"),
				])

				section(title: "View / File", items: [
					("⌘]", "次の View"),
					("⌘[", "前の View"),
					("⌘-", "前のファイルに戻る"),
					("⌘=", "次のファイルに進む"),
					("⌘P", "ファイル検索"),
					("⌘⇧P", "Command palette"),
				])

				section(title: "Pane", items: [
					("⌘D", "Pane 縦分割"),
					("⌘⇧D", "Pane 横分割"),
					("⌘W", "Pane を閉じる"),
					("⌘'", "次の pane にフォーカス"),
					("⌘;", "前の pane にフォーカス"),
					("⌘↩", "Tile mode で focus 中 pane の project view を開く"),
				])

				section(title: "Sidebar / Panel", items: [
					("⌘\\", "サイドバーをトグル"),
					("⌘E", "エディタトグル"),
					("⌘L", "エディタにフォーカス"),
					("⌘⇧E", "ファイルツリーをトグル"),
					("⌘⇧B", "ブラウザパネルをトグル"),
					("⌘⇧G", "差分ビューを開く"),
				])

				section(title: "Terminal", items: [
					("⌘+", "フォントサイズ拡大"),
					("⌘-", "フォントサイズ縮小 (※ ファイル view では戻る扱い)"),
					("⌘0", "フォントサイズリセット"),
				])

				section(title: "App", items: [
					("⌘,", "設定"),
					("⌘⇧.", "アプリの表示 / 非表示 (グローバル)"),
				])
			}
			.padding(14)
		}
		.frame(width: 380, height: 540)
	}

	@ViewBuilder
	private func section(title: String, items: [(String, String)]) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title)
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(Theme.textSecondary)
				.padding(.bottom, 2)
			ForEach(items, id: \.0) { item in
				HStack(alignment: .firstTextBaseline, spacing: 12) {
					Text(item.0)
						.font(.system(size: 11, design: .monospaced))
						.foregroundStyle(Theme.textPrimary)
						.frame(width: 90, alignment: .leading)
					Text(item.1)
						.font(.system(size: 11))
						.foregroundStyle(Theme.textSecondary)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
			}
		}
	}
}
