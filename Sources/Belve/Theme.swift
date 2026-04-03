import SwiftUI

enum Theme {
	// Backgrounds
	static let bg = Color(red: 0.10, green: 0.10, blue: 0.12)
	static let surface = Color(red: 0.14, green: 0.15, blue: 0.18)
	static let surfaceHover = Color(white: 1, opacity: 0.06)
	static let surfaceActive = Color(white: 1, opacity: 0.10)

	// Text
	static let textPrimary = Color(red: 0.88, green: 0.89, blue: 0.92)
	static let textSecondary = Color(white: 1, opacity: 0.45)
	static let textTertiary = Color(white: 1, opacity: 0.25)

	// Accent
	static let accent = Color(red: 0.45, green: 0.68, blue: 0.91)

	// Borders
	static let border = Color(white: 1, opacity: 0.08)
	static let borderSubtle = Color(white: 1, opacity: 0.04)

	// Status
	static let green = Color(red: 0.35, green: 0.75, blue: 0.45)
	static let yellow = Color(red: 0.85, green: 0.70, blue: 0.30)
	static let red = Color(red: 0.85, green: 0.35, blue: 0.35)

	// Spacing
	static let radiusSm: CGFloat = 6
	static let radiusMd: CGFloat = 8
	static let radiusLg: CGFloat = 12

	// Fonts
	static let fontMono = Font.system(size: 13, weight: .regular, design: .monospaced)
	static let fontBody = Font.system(size: 13, weight: .regular)
	static let fontCaption = Font.system(size: 11, weight: .medium)
	static let fontHeading = Font.system(size: 13, weight: .semibold)
}
