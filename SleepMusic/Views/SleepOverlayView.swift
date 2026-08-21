import SwiftUI

/// The "screen while the Mac sleeps" surface, matching the native Lock
/// Screen's Now Playing + lyrics composition: a centered clock up top, big
/// artwork with a player widget beneath it on the left, and the synced
/// lyrics running alongside — all vertically centered together.
struct SleepOverlayView: View {
    @ObservedObject var spotify: SpotifyObserver
    @ObservedObject var lyrics: LyricsViewModel
    let onDismiss: () -> Void

    @StateObject private var palette = ArtworkPalette()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AmbientBackground(intensity: 0.4, accentColor: palette.accentColor)
                artworkBackdrop

                // Pinned to the exact geometric center of the screen via
                // .position, so it can't be thrown off by Spacer math or by
                // the clock/footer's own sizing.
                HStack(alignment: .center, spacing: 56) {
                    VStack(spacing: 22) {
                        artwork
                        playerWidget
                    }
                    .frame(width: 320)

                    lyricsBlock
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: geo.size.width - 140, alignment: .leading)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)

                VStack {
                    clockHeader
                    Spacer(minLength: 0)
                }
                .padding(.top, 56)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                VStack {
                    Spacer(minLength: 0)
                    Text("Click or press any key to exit")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.2))
                }
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .onAppear {
            palette.update(artworkURL: spotify.nowPlaying?.artworkURL)
        }
        .onChange(of: spotify.nowPlaying?.artworkURL) { _, url in
            palette.update(artworkURL: url)
        }
    }

    // MARK: - Backdrop

    private var artworkBackdrop: some View {
        AsyncImage(url: spotify.nowPlaying?.artworkURL) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 70)
                    .overlay(Color.black.opacity(0.65))
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: spotify.nowPlaying?.artworkURL)
    }

    // MARK: - Clock

    private var clockHeader: some View {
        VStack(spacing: 8) {
            Text(Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))

            Text(Date.now, style: .time)
                .font(.system(size: 68, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Artwork + player

    private var artwork: some View {
        AsyncImage(url: spotify.nowPlaying?.artworkURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.3))
                    )
            }
        }
        .frame(width: 320, height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 14)
    }

    private var playerWidget: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spotify.nowPlaying?.title ?? "")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(spotify.nowPlaying?.artist ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            progressBar
            transportControls
        }
        .padding(20)
        .frame(width: 320)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var progressBar: some View {
        let duration = max(spotify.nowPlaying?.duration ?? 0, 1)
        let progress = min(max(spotify.estimatedPosition() / duration, 0), 1)

        return VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white.opacity(0.9)).frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 3)

            HStack {
                Text(timeString(spotify.estimatedPosition()))
                Spacer()
                Text(timeString(duration))
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.4))
        }
    }

    private var transportControls: some View {
        HStack {
            Button(action: spotify.toggleShuffle) {
                Image(systemName: "shuffle")
            }
            Spacer()
            Button(action: spotify.skipToPrevious) {
                Image(systemName: "backward.fill")
            }
            Spacer()
            Button(action: spotify.togglePlayPause) {
                Image(systemName: (spotify.nowPlaying?.isPlaying ?? false) ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
            }
            Spacer()
            Button(action: spotify.skipToNext) {
                Image(systemName: "forward.fill")
            }
            Spacer()
            Button(action: spotify.toggleRepeat) {
                Image(systemName: "repeat")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .font(.system(size: 15, weight: .semibold))
        .disabled(spotify.nowPlaying == nil)
        .padding(.top, 4)
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Lyrics

    @ViewBuilder
    private var lyricsBlock: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let previous = previousLine {
                Text(previous.text)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))
                    .lineLimit(2)
            }

            if lyrics.isLoading {
                ProgressView().tint(.white).controlSize(.large)
            } else if let current = lyrics.currentLine {
                Text(current.text)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .shadow(color: .black.opacity(0.3), radius: 20)
                    .id(current.id)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut(duration: 0.4), value: current.id)
            } else {
                Text("🌙")
                    .font(.system(size: 52))
                    .opacity(0.5)
            }

            if let next = nextLine {
                Text(next.text)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .blur(radius: 3)
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var previousLine: LyricLine? {
        guard let current = lyrics.currentLine,
              let idx = lyrics.lines.firstIndex(of: current),
              idx > 0
        else { return nil }
        return lyrics.lines[idx - 1]
    }

    private var nextLine: LyricLine? {
        guard let current = lyrics.currentLine,
              let idx = lyrics.lines.firstIndex(of: current),
              idx + 1 < lyrics.lines.count
        else { return nil }
        return lyrics.lines[idx + 1]
    }
}
