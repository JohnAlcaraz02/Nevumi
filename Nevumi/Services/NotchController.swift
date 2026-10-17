import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

/// Which action the notch's drop area offers under the cursor: the left half
/// converts the dragged files, the right half shares them via AirDrop.
enum NotchDropAction {
    case convert
    case airDrop
}

/// What the notch pill currently shows. A reference type so the already-live
/// `DynamicNotch` content redraws in place when playback changes, instead of
/// the pill being torn down and rebuilt (which would restart its animations).
@MainActor
final class NotchPlaybackState: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var isPlaying = false
    @Published var artworkURL: URL?
    @Published var duration: TimeInterval = 0
    @Published var currentLyric: String?
    @Published var isFileDropTargeted = false
    @Published var fileDropName: String?
    @Published var fileDropAction: NotchDropAction = .convert
}

/// Mirrors now-playing + the current lyric line into a small pill that hugs
/// the physical camera notch (or floats under the menu bar on Macs without
/// one) via DynamicNotchKit — a "Dynamic Island" for Nevumi. It expands
/// on hover, stays up during normal use, and is brought back in front of
/// Sleep Mode's fullscreen overlay so it's still reachable there too.
@MainActor
final class NotchController {
    static let shared = NotchController()

    private let state = NotchPlaybackState()
    private var notch: DynamicNotch<AnyView, AnyView, AnyView>?
    private var hoverCancellable: AnyCancellable?
    private var isShown = false
    private var isShowingFileDrop = false
    private var isSpotifyRunning = false
    private var spotify: SpotifyObserver!

    private init() {}

    /// Gives the pill a `SpotifyObserver` to read live playback position from
    /// and to wire its transport buttons to. Call once, before the first
    /// `update`.
    func configure(spotify: SpotifyObserver) {
        self.spotify = spotify
    }

    func update(title: String, artist: String, isPlaying: Bool, isSpotifyRunning: Bool, artworkURL: URL?, duration: TimeInterval, currentLyric: String?) {
        state.title = title
        state.artist = artist
        state.isPlaying = isPlaying
        state.artworkURL = artworkURL
        state.duration = duration
        state.currentLyric = currentLyric
        self.isSpotifyRunning = isSpotifyRunning

        guard !isShowingFileDrop else { return }
        if isSpotifyRunning {
            showIfNeeded()
        } else {
            hide()
        }
    }

    /// Reuses the music player's DynamicNotch for file-drop feedback. The
    /// window ignores pointer events during the drag so the native receiver
    /// underneath continues to receive Finder's drop messages.
    func setFileDropTargeted(_ targeted: Bool, fileName: String?, action: NotchDropAction = .convert) {
        state.fileDropName = fileName
        state.fileDropAction = action
        guard isShowingFileDrop != targeted else { return }

        isShowingFileDrop = targeted
        state.isFileDropTargeted = targeted

        if targeted {
            showIfNeeded()
            notch?.windowController?.window?.ignoresMouseEvents = true
            if let notch {
                Task { await notch.expand() }
            }
        } else {
            notch?.windowController?.window?.ignoresMouseEvents = false
            if isSpotifyRunning, let notch {
                Task { await notch.compact() }
            } else {
                hide()
            }
        }
    }

    /// Re-orders the pill above Sleep Mode's fullscreen overlay, which sits
    /// at the same window level and would otherwise cover it.
    func bringToFront() {
        notch?.windowController?.window?.orderFrontRegardless()
    }

    private func showIfNeeded() {
        guard !isShown else { return }
        isShown = true

        let notch = DynamicNotch(hoverBehavior: .all) {
            AnyView(NotchExpandedView(state: self.state, spotify: self.spotify))
        } compactLeading: {
            AnyView(NotchCompactLeadingView(state: self.state))
        } compactTrailing: {
            AnyView(NotchCompactTrailingView(state: self.state))
        }
        self.notch = notch

        hoverCancellable = notch.$isHovering
            .removeDuplicates()
            .sink { [weak self] hovering in
                Task { @MainActor in
                    guard self?.isShowingFileDrop == false else { return }
                    if hovering {
                        await notch.expand()
                    } else {
                        await notch.compact()
                    }
                }
            }

        if isShowingFileDrop {
            notch.windowController?.window?.ignoresMouseEvents = true
            Task { @MainActor in
                await notch.expand()
                notch.windowController?.window?.ignoresMouseEvents = true
            }
        } else {
            Task { await notch.compact() }
        }
    }

    private func hide() {
        guard isShown, let notch else { return }
        isShown = false
        hoverCancellable?.cancel()
        hoverCancellable = nil
        self.notch = nil
        Task { await notch.hide() }
    }
}

private struct NotchCompactLeadingView: View {
    @ObservedObject var state: NotchPlaybackState

    var body: some View {
        EqualizerIcon(isAnimating: state.isPlaying)
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
    }
}

private struct NotchCompactTrailingView: View {
    @ObservedObject var state: NotchPlaybackState

    var body: some View {
        if let lyric = state.currentLyric, !lyric.isEmpty {
            Image("NevumiMark")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 12)
                .foregroundStyle(Color(red: 0.72, green: 0.65, blue: 1))
        } else {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// The expanded pill: an Apple Music-style "Now Playing" card (artwork,
/// title/artist, scrubber, transport row) with the current synced lyric
/// line running underneath.
private struct NotchExpandedView: View {
    @ObservedObject var state: NotchPlaybackState
    @ObservedObject var spotify: SpotifyObserver

    var body: some View {
        Group {
            if state.isFileDropTargeted {
                NotchFileDropExpandedView(fileName: state.fileDropName, action: state.fileDropAction)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    progressSection
                    transportControls

                    if let lyric = state.currentLyric, !lyric.isEmpty {
                        Text(lyric)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.3), value: lyric)
                    }
                }
                .padding(.horizontal, 4)
                .frame(minWidth: 260, maxWidth: 340, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.16), value: state.isFileDropTargeted)
    }

    private var header: some View {
        HStack(spacing: 10) {
            artworkThumbnail

            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(state.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var artworkThumbnail: some View {
        AsyncImage(url: state.artworkURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.3))
                    )
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var progressSection: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = max(state.duration, 1)
            let position = min(spotify.estimatedPosition(), duration)
            let progress = position / duration

            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white.opacity(0.9)).frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 3)

                HStack {
                    Text(timeString(position))
                    Spacer()
                    Text("-" + timeString(max(duration - position, 0)))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            }
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
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
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
        .font(.system(size: 14, weight: .semibold))
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Content only—the surrounding shape and animation are supplied by the
/// exact same DynamicNotch instance used for the music player. The card
/// mirrors the receiver's two halves (left: convert, right: AirDrop) and
/// highlights whichever side the cursor is over.
private struct NotchFileDropExpandedView: View {
    let fileName: String?
    let action: NotchDropAction

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    if let fileName {
                        Text(fileName)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Text(subtitle)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))

            HStack {
                zoneHint("Convert", isActive: action == .convert)
                Spacer(minLength: 24)
                zoneHint("AirDrop", isActive: action == .airDrop)
            }
        }
        .frame(minWidth: 260, minHeight: 107)
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(tint.opacity(0.85))
                .frame(width: 54, height: 2)
        }
        .animation(.easeInOut(duration: 0.15), value: action)
    }

    private var icon: String {
        switch action {
        case .convert: return "arrow.down.doc.fill"
        case .airDrop: return "dot.radiowaves.left.and.right"
        }
    }

    private var tint: Color {
        switch action {
        case .convert: return .green
        case .airDrop: return .blue
        }
    }

    private var title: String {
        switch action {
        case .convert: return "Drop to convert"
        case .airDrop: return "Drop to AirDrop"
        }
    }

    private var subtitle: String {
        switch action {
        case .convert: return "Release to choose an output format"
        case .airDrop: return "Release to send to a nearby device"
        }
    }

    private func zoneHint(_ label: String, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isActive ? tint : .white.opacity(0.25))
                .frame(width: 4, height: 4)
            Text(label)
                .font(.system(size: 9, weight: isActive ? .bold : .medium, design: .rounded))
                .foregroundStyle(isActive ? .white.opacity(0.9) : .white.opacity(0.35))
        }
    }
}
