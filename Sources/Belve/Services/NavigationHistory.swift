import Foundation

struct NavigationEntry: Equatable {
	let path: String
	let line: Int
	let column: Int
}

@MainActor
final class NavigationHistoryManager {
	static let shared = NavigationHistoryManager()

	private var histories: [UUID: NavigationHistory] = [:]
	var isNavigating = false

	func history(for viewId: UUID) -> NavigationHistory {
		if let h = histories[viewId] { return h }
		let h = NavigationHistory()
		histories[viewId] = h
		return h
	}

	func push(viewId: UUID, entry: NavigationEntry) {
		guard !isNavigating else { return }
		history(for: viewId).push(entry)
	}

	func goBack(viewId: UUID) -> NavigationEntry? {
		history(for: viewId).goBack()
	}

	func goForward(viewId: UUID) -> NavigationEntry? {
		history(for: viewId).goForward()
	}
}

final class NavigationHistory {
	private var stack: [NavigationEntry] = []
	private var cursor: Int = -1
	private let maxSize = 100

	func push(_ entry: NavigationEntry) {
		if let current, current == entry { return }
		// Same file, close line → replace instead of push
		if let current, current.path == entry.path, abs(current.line - entry.line) < 10 {
			stack[cursor] = entry
			return
		}
		// Truncate forward history
		if cursor < stack.count - 1 {
			stack = Array(stack.prefix(cursor + 1))
		}
		stack.append(entry)
		if stack.count > maxSize {
			stack.removeFirst()
		}
		cursor = stack.count - 1
	}

	func goBack() -> NavigationEntry? {
		guard cursor > 0 else { return nil }
		cursor -= 1
		return stack[cursor]
	}

	func goForward() -> NavigationEntry? {
		guard cursor < stack.count - 1 else { return nil }
		cursor += 1
		return stack[cursor]
	}

	var current: NavigationEntry? {
		guard cursor >= 0 && cursor < stack.count else { return nil }
		return stack[cursor]
	}

	var canGoBack: Bool { cursor > 0 }
	var canGoForward: Bool { cursor < stack.count - 1 }
}
