import SwiftUI

struct MainView: View {
    @StateObject private var viewModel = PlayerViewModel()

    var body: some View {
        ZStack {
            background

            VStack(spacing: 28) {
                header
                trackCard

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer(minLength: 0)
            }
            .padding(28)
        }
        .frame(minWidth: 420, minHeight: 480)
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

    private var trackCard: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: viewModel.channel.track?.category.symbol ?? "music.note")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.channel.track?.name ?? "No track loaded")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()
            }

            HStack(spacing: 16) {
                Button(action: viewModel.togglePlayPause) {
                    Image(systemName: viewModel.channel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.channel.track == nil)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Volume")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Text("\(Int(viewModel.channel.volume * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.channel.volume) },
                            set: { viewModel.setVolume(Float($0)) }
                        ),
                        in: 0...1
                    )
                    .tint(.indigo)
                }
            }

            Button {
                viewModel.importAndLoad(category: .music)
            } label: {
                Label("Import Audio File", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .controlSize(.large)
        }
        .padding(20)
        .background(.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var statusText: String {
        guard viewModel.channel.track != nil else { return "Import a file to begin" }
        return viewModel.channel.isPlaying ? "Playing" : "Paused"
    }
}

#Preview {
    MainView()
}
