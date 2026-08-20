import SwiftUI

struct SleepOverlayView: View {
    let trackTitle: String
    @ObservedObject var lyrics: LyricsViewModel
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Text(trackTitle)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))

                content
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 40)

                Text("Click or press any key to exit")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.2))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }

    @ViewBuilder
    private var content: some View {
        if lyrics.isLoading {
            ProgressView()
                .tint(.white)
        } else if let line = lyrics.currentLine {
            Text(line.text)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .id(line.id)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: line.id)
        } else {
            Text("🌙")
                .font(.system(size: 44))
                .opacity(0.6)
        }
    }
}
