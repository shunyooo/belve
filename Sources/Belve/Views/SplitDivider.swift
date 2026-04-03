import SwiftUI

struct SplitDivider: View {
	@Binding var position: CGFloat
	let minLeft: CGFloat
	let minRight: CGFloat
	@State private var isDragging = false

	var body: some View {
		Rectangle()
			.fill(isDragging ? Theme.border : Theme.borderSubtle)
			.frame(width: 1)
			.contentShape(Rectangle().inset(by: -3))
			.onHover { hovering in
				if hovering {
					NSCursor.resizeLeftRight.push()
				} else {
					NSCursor.pop()
				}
			}
			.gesture(
				DragGesture(minimumDistance: 1)
					.onChanged { value in
						isDragging = true
						let newPos = position + value.translation.width
						position = max(minLeft, min(newPos, NSScreen.main!.frame.width - minRight))
					}
					.onEnded { _ in
						isDragging = false
					}
			)
	}
}
