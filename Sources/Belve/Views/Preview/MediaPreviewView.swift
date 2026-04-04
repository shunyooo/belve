import SwiftUI
import AppKit

/// Preview for images and PDFs
struct MediaPreviewView: View {
	let path: String
	let sshHost: String?

	var body: some View {
		Group {
			if let image = loadImage() {
				ScrollView([.horizontal, .vertical]) {
					Image(nsImage: image)
						.resizable()
						.aspectRatio(contentMode: .fit)
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			} else {
				VStack(spacing: 8) {
					Image(systemName: "doc.questionmark")
						.font(.system(size: 28, weight: .thin))
						.foregroundStyle(Theme.textTertiary)
					Text("Cannot preview this file")
						.font(Theme.fontBody)
						.foregroundStyle(Theme.textTertiary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.background(Theme.surface)
	}

	private func loadImage() -> NSImage? {
		if sshHost != nil {
			// TODO: SSH file download for media
			return nil
		}
		return NSImage(contentsOfFile: path)
	}
}

/// Detect file type for routing
enum FileType {
	case code
	case markdown
	case image
	case pdf
	case unknown

	static func detect(path: String) -> FileType {
		let ext = (path as NSString).pathExtension.lowercased()
		switch ext {
		case "md", "markdown":
			return .markdown
		case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "svg", "ico":
			return .image
		case "pdf":
			return .pdf
		default:
			return .code
		}
	}
}
