import SwiftUI

struct LoadingTrack: View {
	let trackHeight: CGFloat
	let widthFactor: CGFloat
	let minimumWidth: CGFloat
	var capsuleTrack: Bool = false

	var body: some View {
		TimelineView(.animation) { timeline in
			GeometryReader { geo in
				let elapsed = timeline.date.timeIntervalSinceReferenceDate
				let cycle = elapsed.remainder(dividingBy: 0.86) / 0.86
				let highlightWidth = max(geo.size.width * widthFactor, minimumWidth)
				let travel = geo.size.width + (highlightWidth * 1.28)
				let offset = (-highlightWidth) + (travel * cycle)

				ZStack(alignment: .leading) {
					if capsuleTrack {
						Capsule()
							.fill(Theme.borderSubtle)
							.frame(height: trackHeight)
					} else {
						Theme.borderSubtle
					}

					ForEach([-1.0, 0.0, 1.0], id: \.self) { phase in
						LinearGradient(
							colors: [
								Theme.textTertiary.opacity(0),
								Theme.textPrimary.opacity(0.82),
								Theme.textSecondary.opacity(0)
							],
							startPoint: .leading,
							endPoint: .trailing
						)
						.frame(width: highlightWidth, height: trackHeight)
						.offset(x: offset + (travel * phase))
					}
				}
				.clipped()
				.mask {
					LinearGradient(
						stops: [
							.init(color: .clear, location: 0),
							.init(color: .white, location: 0.08),
							.init(color: .white, location: 0.92),
							.init(color: .clear, location: 1)
						],
						startPoint: .leading,
						endPoint: .trailing
					)
				}
			}
		}
	}
}
