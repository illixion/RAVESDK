import Foundation

/// The server-independent facts needed to order a Continue Watching / Up Next
/// row. Hosts map their own server DTOs into this type and keep rendering data
/// in their own model layer.
public struct LibraryUpNextEntry: Sendable {
    public var id: String
    public var seriesID: String?
    public var lastPlayedAt: Date?
    public var isResume: Bool

    public init(id: String, seriesID: String?, lastPlayedAt: Date?, isResume: Bool) {
        self.id = id
        self.seriesID = seriesID
        self.lastPlayedAt = lastPlayedAt
        self.isResume = isResume
    }
}

/// Shared ordering for resume items and each show's next episode.
/// A partly watched episode also returned by NextUp appears once, and when a
/// show has both a resume and a later next episode, the more recently watched
/// one wins (resume wins a tie).
public enum LibraryUpNextOrdering {
    public static func orderedIDs(resume: [LibraryUpNextEntry], nextUp: [LibraryUpNextEntry],
                                  watchedEpisodes: [LibraryUpNextEntry]) -> [String] {
        var seriesLastWatched: [String: Date] = [:]
        for episode in watchedEpisodes + resume {
            guard let series = episode.seriesID, let date = episode.lastPlayedAt else { continue }
            seriesLastWatched[series] = max(seriesLastWatched[series] ?? .distantPast, date)
        }
        struct Candidate {
            let entry: LibraryUpNextEntry
            let date: Date?
            let order: Int
        }
        var candidates = resume.enumerated().map { index, entry in
            Candidate(entry: entry, date: entry.lastPlayedAt, order: index)
        }
        let resumeIDs = Set(resume.map(\.id))
        for (index, entry) in nextUp.enumerated() where !resumeIDs.contains(entry.id) {
            let date = entry.seriesID.flatMap { seriesLastWatched[$0] } ?? entry.lastPlayedAt
            candidates.append(Candidate(entry: entry, date: date, order: resume.count + index))
        }
        candidates.sort { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if lhs.entry.isResume != rhs.entry.isResume { return lhs.entry.isResume }
                return lhs.order < rhs.order
            }
        }
        var seenSeries = Set<String>()
        return candidates.compactMap { candidate in
            if let series = candidate.entry.seriesID, !seenSeries.insert(series).inserted { return nil }
            return candidate.entry.id
        }
    }
}
