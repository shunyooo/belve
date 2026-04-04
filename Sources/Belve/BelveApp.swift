import SwiftUI

@main
struct BelveApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

	var body: some Scene {
		WindowGroup {
			MainWindow()
				.frame(minWidth: 900, minHeight: 500)
		}
		.windowToolbarStyle(.unifiedCompact)
		.defaultSize(width: 1200, height: 800)
	}
}

class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		// SPM binary needs explicit activation to receive key events
		NSApp.activate(ignoringOtherApps: true)
	}

	func applicationDidBecomeActive(_ notification: Notification) {
		NSLog("[Belve] App became active")
	}
}
