import SwiftUI

struct MainView: View {
    @StateObject private var viewModel = PlayerViewModel()
    @StateObject private var spotify = SpotifyObserver()

    var body: some View {
        ZStack {
            background

            VStack(spacing: 28) {
                header

                if let nowPlaying = spotify.nowPlaying {
                    spotifyBanner(nowPlaying)
                }

                lyricsCard

                sleepModeButton

                Spacer(minLength: 0)
            }
            .padding(28)
        }
        .frame(minWidth: 420, minHeight: 480)
        .onAppear {
            SleepOverlayController.shared.observeLockEvents(
                lyrics: viewModel.lyrics,
                isPlaying: { spotify.nowPlaying?.isPlaying ?? false },
                trackTitle: { spotify.nowPlaying?.title ?? "" }
            )
            spotify.start()
            viewModel.lyrics.attachToSpotify(spotify)
        }
        .onDisappear {
            spotify.stop()
        }
        .onChange(of: spotify.nowPlaying) { nowPlaying in
            viewModel.lyrics.syncWithSpotify(nowPlaying)
        }
    }

    private func spotifyBanner(_ nowPlaying: SpotifyObserver.NowPlaying) -> some View {
        HStack(spacing: 10) {
            Image(systemName: nowPlaying.isPlaying ? "waveform" : "pause.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(nowPlaying.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(nowPlaying.artist)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            Text("Spotify")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(12)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var sleepModeButton: some View {
        Button {
            SleepOverlayController.shared.show(trackTitle: spotify.nowPlaying?.title ?? "", lyrics: viewModel.lyrics)
        } label: {
            Label("Enter Sleep Mode", systemImage: "moon.stars.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .controlSize(.large)
        .disabled(spotify.nowPlaying == nil)
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.06, blue: 0.12),
                Color(red: 0.10, green: 0.08, blue: 0.18)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("🌙 Sleep Mode")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Relax, listen, and let your Mac rest.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var lyricsCard: some View {
        VStack(spacing: 12) {
            if viewModel.lyrics.isLoading {
                ProgressView()
                    .tint(.white)
            } else if let line = viewModel.lyrics.currentLine {
                Text(line.text)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .id(line.id)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: line.id)
            } else if viewModel.lyrics.lookupFailed {
                Text("No synced lyrics found for this track.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            } else if spotify.nowPlaying != nil {
                Text("🌙")
                    .font(.system(size: 32))
                    .opacity(0.5)
            } else {
                Text("Play something in Spotify to see lyrics here.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding(20)
        .background(.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

#Preview {
    MainView()
}
