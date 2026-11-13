//
//  Lyrics.swift
//  DynamicNotch
//
//  Fetching and reading song lyrics: LRCLIB on the web, or Apple Music's own.
//

import Foundation

/// Where lyrics come from and how timed (LRC) lyrics are read. Stateless; `MusicManager`
/// decides when to fetch and keeps the result.
enum Lyrics {
    static func fromAppleMusic() async -> String {
        let script = """
        tell application "Music"
            try
                set l to lyrics of current track
                if l is missing value then return ""
                return l
            on error
                return ""
            end try
        end tell
        """
        let result = try? await AppleScriptHelper.execute(script)
        return result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func normalizedQuery(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
    }

    /// Looks the track up on LRCLIB (free, no account). Picks the result whose length
    /// matches the playing track, preferring one with timed lines.
    static func web(title: String, artist: String, duration: Double) async -> (plain: String, synced: [(time: Double, text: String)]) {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        // URLQueryItem encodes "&", "+" and "#" in titles, which plain percent-encoding misses.
        components.queryItems = [
            URLQueryItem(name: "track_name", value: normalizedQuery(title)),
            URLQueryItem(name: "artist_name", value: normalizedQuery(artist)),
        ]
        guard let url = components.url else { return ("", []) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("DynamicNotch (https://github.com/Bauer-Haus/DynamicNotch)", forHTTPHeaderField: "User-Agent")

        // LRCLIB is sometimes briefly overloaded (503) or rate-limits (429): try once more.
        for attempt in 0 ..< 2 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(1.5))
            }
            guard !Task.isCancelled else { return ("", []) }
            let reply = try? await URLSession.shared.data(for: request)
            let status = (reply?.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let data = reply?.0 {
                return lyrics(fromSearchResults: data, duration: duration)
            }
            guard isWorthRetrying(status: status) else { break }
        }
        return ("", [])
    }

    /// No reply (network error, timeout), rate limiting or a server error.
    static func isWorthRetrying(status: Int) -> Bool {
        status == 0 || status == 429 || (500 ..< 600).contains(status)
    }

    /// Picks the LRCLIB search result whose length matches the playing track, preferring
    /// one with timed lines, and returns its plain and timed lyrics.
    static func lyrics(fromSearchResults data: Data, duration: Double) -> (plain: String, synced: [(time: Double, text: String)]) {
        guard let results = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !results.isEmpty
        else { return ("", []) }

        func lengthMatches(_ item: [String: Any]) -> Bool {
            guard duration > 0, let d = item["duration"] as? Double else { return true }
            return abs(d - duration) <= 3
        }
        func hasSynced(_ item: [String: Any]) -> Bool {
            !((item["syncedLyrics"] as? String) ?? "").isEmpty
        }
        let candidates = results.filter(lengthMatches)
        guard let best = candidates.first(where: hasSynced) ?? candidates.first ?? results.first else { return ("", []) }

        if best["instrumental"] as? Bool == true {
            return ("♪ Instrumental", [])
        }
        let plain = ((best["plainLyrics"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let synced = parseLRC((best["syncedLyrics"] as? String) ?? "")
        return (plain.isEmpty ? synced.map(\.text).joined(separator: "\n") : plain, synced)
    }

    /// Matches one LRC timestamp: [m:ss], [mm:ss.xx] or [mm:ss.xxx].
    private static let lrcTimestamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)

    static func parseLRC(_ lrc: String) -> [(time: Double, text: String)] {
        var result: [(time: Double, text: String)] = []
        for lineSub in lrc.split(whereSeparator: \.isNewline) {
            let nsLine = String(lineSub) as NSString
            // A line can carry several timestamps when it repeats ("[00:12.00][01:30.00]text").
            let matches = lrcTimestamp.matches(in: nsLine as String, range: NSRange(location: 0, length: nsLine.length))
            guard let last = matches.last else { continue }
            let text = nsLine.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for match in matches {
                let minutes = Double(nsLine.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
                let fracRange = match.range(at: 3)
                // ".5" is half a second and ".05" five hundredths, so read it as a decimal.
                let fraction = fracRange.location != NSNotFound ? Double("0." + nsLine.substring(with: fracRange)) ?? 0 : 0
                result.append((minutes * 60 + seconds + fraction, text))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    /// The line being sung at `elapsed`: the last one starting at or before it (the first
    /// line before the song reaches it). `lines` must be sorted by time and not empty.
    static func line(in lines: [(time: Double, text: String)], at elapsed: Double) -> String {
        var low = 0
        var high = lines.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return lines[idx].text
    }
}
