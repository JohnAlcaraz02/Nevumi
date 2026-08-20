import Foundation

enum LyricsServiceError: LocalizedError {
    case noResults
    case noSyncedLyrics

    var errorDescription: String? {
        switch self {
        case .noResults:
            return "No lyrics found for this track."
        case .noSyncedLyrics:
            return "Lyrics were found, but not a time-synced version."
        }
    }
}

/// Looks up time-synced lyrics on LRCLIB (lrclib.net) — a free, open,
/// unauthenticated lyrics database. No API key, no account, no tracking:
/// just a GET request keyed by track name, matched by closest duration.
struct LyricsService {
    static let shared = LyricsService()

    private let session = URLSession.shared

    func fetchSyncedLyrics(forQuery query: String, durationHint: TimeInterval?) async throws -> [LyricLine] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]

        let (data, _) = try await session.data(from: components.url!)
        let results = try JSONDecoder().decode([LRCLIBResult].self, from: data)
        guard !results.isEmpty else { throw LyricsServiceError.noResults }

        guard let synced = bestMatch(in: results, durationHint: durationHint)?.syncedLyrics,
              !synced.isEmpty else {
            throw LyricsServiceError.noSyncedLyrics
        }
        return Self.parseLRC(synced)
    }

    /// Prefers results that actually have synced lyrics, then picks
    /// whichever candidate's reported duration is closest to our file's —
    /// the search endpoint has no artist/album filter, so duration is the
    /// best signal we have for picking the right recording among covers.
    private func bestMatch(in results: [LRCLIBResult], durationHint: TimeInterval?) -> LRCLIBResult? {
        let synced = results.filter { $0.syncedLyrics?.isEmpty == false }
        guard let durationHint, !synced.isEmpty else { return synced.first ?? results.first }
        return synced.min { lhs, rhs in
            abs((lhs.duration ?? 0) - durationHint) < abs((rhs.duration ?? 0) - durationHint)
        }
    }

    static func parseLRC(_ raw: String) -> [LyricLine] {
        let pattern = #"^\[(\d{2}):(\d{2}(?:\.\d+)?)\](.*)$"#
        let regex = try? NSRegularExpression(pattern: pattern)

        var lines: [LyricLine] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex?.firstMatch(in: line, range: range),
                  let minutesRange = Range(match.range(at: 1), in: line),
                  let secondsRange = Range(match.range(at: 2), in: line),
                  let textRange = Range(match.range(at: 3), in: line),
                  let minutes = Double(line[minutesRange]),
                  let seconds = Double(line[secondsRange])
            else { continue }

            let text = line[textRange].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            lines.append(LyricLine(time: minutes * 60 + seconds, text: text))
        }
        return lines.sorted { $0.time < $1.time }
    }
}

private struct LRCLIBResult: Decodable {
    let trackName: String?
    let artistName: String?
    let duration: Double?
    let syncedLyrics: String?
}
