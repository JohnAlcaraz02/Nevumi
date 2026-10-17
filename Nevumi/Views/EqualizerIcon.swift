import SwiftUI

/// Three bars that bounce in a loop while `isAnimating`, used as a small
/// "now playing" indicator next to the Spotify banner.
struct EqualizerIcon: View {
    var isAnimating: Bool

    @State private var grow = false

    private let heights: [CGFloat] = [7, 13, 10]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .frame(width: 2.5, height: isAnimating ? heights[i] * (grow ? 1 : 0.3) : 4)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.12),
                        value: grow
                    )
            }
        }
        .onAppear { grow = true }
    }
}
