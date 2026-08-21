import SwiftUI

/// A slow-drifting field of blurred color blobs behind the glass UI, giving
/// the main surface and Sleep Mode a living backdrop instead of a flat
/// fill. `accentColor` tints the blobs to match the current track's
/// artwork when available, falling back to a fixed indigo palette.
struct AmbientBackground: View {
    var intensity: Double
    var accentColor: Color?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(Array(blobColors.enumerated()), id: \.offset) { index, color in
                            blob(
                                color: color,
                                t: t,
                                speed: 0.05 + Double(index) * 0.015,
                                radius: min(geo.size.width, geo.size.height) * 0.7,
                                phase: Double(index) * 2.1,
                                in: geo.size
                            )
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .compositingGroup()
            .blur(radius: 90)
            .opacity(intensity)
            .animation(.easeInOut(duration: 1.2), value: accentColor)
            .ignoresSafeArea()

            LinearGradient(
                colors: [.clear, .black.opacity(0.5)],
                startPoint: .center,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var blobColors: [Color] {
        let base = accentColor ?? Color(.sRGB, red: 0.29, green: 0.24, blue: 0.68, opacity: 1)
        return [
            base,
            base.hueShifted(by: 0.12),
            base.hueShifted(by: -0.14),
            base.hueShifted(by: 0.28),
        ]
    }

    private func blob(color: Color, t: TimeInterval, speed: Double, radius: CGFloat, phase: Double, in size: CGSize) -> some View {
        let angle = t * speed + phase
        let x = size.width / 2 + cos(angle) * size.width * 0.28
        let y = size.height / 2 + sin(angle * 1.3) * size.height * 0.28

        return Circle()
            .fill(color)
            .frame(width: radius, height: radius)
            .position(x: x, y: y)
    }
}
