import SwiftUI

@main
struct BelveApp: App {
	var body: some Scene {
		WindowGroup {
			MainWindow()
				.frame(minWidth: 900, minHeight: 500)
		}
		.windowToolbarStyle(.unifiedCompact)
		.defaultSize(width: 1200, height: 800)
	}
}
