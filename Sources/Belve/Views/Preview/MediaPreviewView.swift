import SwiftUI
import AppKit
import AVKit

/// Preview for images and videos
struct MediaPreviewView: View {
	let path: String
	let provider: any WorkspaceProvider

	@State private var localURL: URL?
	@State private var isLoading = true
	@State private var error: String?

	var body: some View {
		Group {
			if isLoading {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if let error {
				VStack(spacing: 8) {
					Image(systemName: "exclamationmark.triangle")
						.font(.system(size: 28, weight: .thin))
						.foregroundStyle(Theme.textTertiary)
					Text(error)
						.font(Theme.fontBody)
						.foregroundStyle(Theme.textTertiary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if let url = localURL {
				let fileType = FileType.detect(path: path)
				if fileType == .video {
					VideoPlayer(player: AVPlayer(url: url))
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if let image = NSImage(contentsOf: url) {
					ZoomableImageView(image: image)
				} else {
					cannotPreview
				}
			} else {
				cannotPreview
			}
		}
		.background(Theme.surface)
		.onAppear { loadFile() }
		.onChange(of: path) { loadFile() }
	}

	private var cannotPreview: some View {
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

	private func loadFile() {
		NSLog("[Belve] loadFile: %@, isRemote=%d", path, provider.isRemote ? 1 : 0)
		isLoading = true
		error = nil
		localURL = nil

		if !provider.isRemote {
			// Local: resolve absolute path and use directly
			let absPath: String
			if path.hasPrefix("/") {
				absPath = path
			} else {
				absPath = (provider.effectivePath as NSString).appendingPathComponent(path)
			}
			if FileManager.default.fileExists(atPath: absPath) {
				localURL = URL(fileURLWithPath: absPath)
			} else {
				error = "File not found: \(absPath)"
			}
			isLoading = false
			return
		}

		// Remote: download file via SCP/docker cp (fast, binary-safe)
		let filePath = path
		let downloadBlock: (String, URL) -> Bool = { [provider] rp, url in provider.downloadFile(remotePath: rp, to: url) }

		DispatchQueue.global(qos: .userInitiated).async {
			let ext = (filePath as NSString).pathExtension
			let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("belve-preview")
			try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
			let tmpFile = tmpDir.appendingPathComponent(UUID().uuidString + "." + ext)

			NSLog("[Belve] MediaPreview: downloading %@", filePath)
			let ok = downloadBlock(filePath, tmpFile)
			DispatchQueue.main.async {
				if ok {
					NSLog("[Belve] MediaPreview: download success")
					localURL = tmpFile
				} else {
					NSLog("[Belve] MediaPreview: download failed")
					error = "Failed to download file"
				}
				isLoading = false
			}
		}
	}

}

/// Detect file type for routing
enum FileType {
	case code
	case markdown
	case image
	case video
	case pdf
	case unknown

	static func detect(path: String) -> FileType {
		let ext = (path as NSString).pathExtension.lowercased()
		switch ext {
		case "md", "markdown":
			return .markdown
		case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "svg", "ico":
			return .image
		case "mp4", "webm", "mov", "m4v", "avi":
			return .video
		case "pdf":
			return .pdf
		default:
			return .code
		}
	}
}

// MARK: - Zoomable Image View

struct ZoomableImageView: NSViewRepresentable {
	let image: NSImage

	func makeNSView(context: Context) -> FlippedScrollView {
		let scrollView = FlippedScrollView()
		scrollView.hasVerticalScroller = true
		scrollView.hasHorizontalScroller = true
		scrollView.allowsMagnification = true
		scrollView.minMagnification = 0.1
		scrollView.maxMagnification = 10.0
		scrollView.magnification = 1.0
		scrollView.backgroundColor = NSColor(Theme.surface)
		scrollView.drawsBackground = true

		let flippedContainer = FlippedView()
		let imageView = NSImageView()
		imageView.image = image
		imageView.imageScaling = .scaleNone
		imageView.setFrameSize(image.size)
		flippedContainer.addSubview(imageView)
		flippedContainer.setFrameSize(image.size)

		scrollView.documentView = flippedContainer

		// Fit to view on initial display
		DispatchQueue.main.async {
			fitToView(scrollView: scrollView, imageSize: image.size)
		}

		return scrollView
	}

	func updateNSView(_ scrollView: FlippedScrollView, context: Context) {
		guard let container = scrollView.documentView as? FlippedView,
			  let imageView = container.subviews.first as? NSImageView else { return }
		if imageView.image !== image {
			imageView.image = image
			imageView.setFrameSize(image.size)
			container.setFrameSize(image.size)
			DispatchQueue.main.async {
				fitToView(scrollView: scrollView, imageSize: image.size)
			}
		}
	}

}

/// NSScrollView subclass with flipped coordinates (top-left origin)
class FlippedScrollView: NSScrollView {
	override var isFlipped: Bool { true }
}

/// NSView subclass with flipped coordinates
class FlippedView: NSView {
	override var isFlipped: Bool { true }
}

extension ZoomableImageView {
	private func fitToView(scrollView: NSScrollView, imageSize: NSSize) {
		let viewSize = scrollView.contentSize
		guard viewSize.width > 0, imageSize.width > 0, imageSize.height > 0 else { return }
		let scale = min(viewSize.width / imageSize.width, 1.0) // Fit width, don't upscale
		scrollView.magnification = scale
	}
}
