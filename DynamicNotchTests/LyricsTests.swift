//
//  LyricsTests.swift
//  DynamicNotch
//
//  Lyrics lookup and timing.
//

import Foundation
import Testing
@testable import DynamicNotch

@Suite("Lyrics")
struct LyricsTests {
    // MARK: LRC parsing

    @Test func parsesCommonTimestampFormats() {
        let lines = Lyrics.parseLRC("""
        [00:01.50]half past one
        [0:03]no fraction
        [00:05.123]milliseconds
        [01:02.05]a minute in
        """)
        #expect(lines.map(\.text) == ["half past one", "no fraction", "milliseconds", "a minute in"])
        #expect(lines.map(\.time) == [1.5, 3, 5.123, 62.05])
    }

    @Test func repeatedLinesGetEveryTimestamp() {
        let lines = Lyrics.parseLRC("[00:10.00][01:20.00]chorus\n[00:30.00]verse")
        #expect(lines.map(\.time) == [10, 30, 80])
        #expect(lines.map(\.text) == ["chorus", "verse", "chorus"])
    }

    @Test func skipsMetadataBlankAndUntimedLines() {
        let lines = Lyrics.parseLRC("""
        [ar:Artist]
        [00:01.00]
        no timestamp here

        [00:02.00]  real line
        """)
        #expect(lines.count == 1)
        #expect(lines.first?.text == "real line")
    }

    @Test func handlesWindowsLineEndings() {
        let lines = Lyrics.parseLRC("[00:01.00]one\r\n[00:02.00]two\r\n")
        #expect(lines.map(\.text) == ["one", "two"])
    }

    @Test func emptyInputGivesNoLines() {
        #expect(Lyrics.parseLRC("").isEmpty)
    }

    // MARK: Current line

    @Test func picksTheLineBeingSung() {
        let lines: [(time: Double, text: String)] = [(5, "a"), (10, "b"), (15, "c")]
        #expect(Lyrics.line(in: lines, at: 0) == "a")     // before the first line
        #expect(Lyrics.line(in: lines, at: 5) == "a")
        #expect(Lyrics.line(in: lines, at: 9.99) == "a")
        #expect(Lyrics.line(in: lines, at: 10) == "b")
        #expect(Lyrics.line(in: lines, at: 14) == "b")
        #expect(Lyrics.line(in: lines, at: 500) == "c")   // after the last line
    }

    @Test func singleLine() {
        #expect(Lyrics.line(in: [(time: 3, text: "only")], at: 0) == "only")
        #expect(Lyrics.line(in: [(time: 3, text: "only")], at: 99) == "only")
    }

    // MARK: Choosing a search result

    private func json(_ results: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: results)
    }

    @Test func prefersTheResultMatchingTheTrackLength() throws {
        let data = try json([
            ["duration": 120.0, "plainLyrics": "short edit", "syncedLyrics": "[00:01.00]short edit"],
            ["duration": 226.0, "plainLyrics": "album version", "syncedLyrics": "[00:01.00]album version"],
        ])
        let result = Lyrics.lyrics(fromSearchResults: data, duration: 225)
        #expect(result.plain == "album version")
    }

    @Test func prefersTimedLyricsAmongMatches() throws {
        let data = try json([
            ["duration": 200.0, "plainLyrics": "plain only", "syncedLyrics": NSNull()],
            ["duration": 201.0, "plainLyrics": "with timing", "syncedLyrics": "[00:01.00]with timing"],
        ])
        let result = Lyrics.lyrics(fromSearchResults: data, duration: 200)
        #expect(result.plain == "with timing")
        #expect(result.synced.count == 1)
    }

    @Test func unknownLengthAcceptsAnyResult() throws {
        let data = try json([["duration": 999.0, "plainLyrics": "anything"]])
        #expect(Lyrics.lyrics(fromSearchResults: data, duration: 0).plain == "anything")
    }

    @Test func noLengthMatchFallsBackToFirstResult() throws {
        let data = try json([["duration": 60.0, "plainLyrics": "first"], ["duration": 70.0, "plainLyrics": "second"]])
        #expect(Lyrics.lyrics(fromSearchResults: data, duration: 300).plain == "first")
    }

    @Test func instrumentalTracksSaySo() throws {
        let data = try json([["duration": 200.0, "instrumental": true, "plainLyrics": NSNull()]])
        let result = Lyrics.lyrics(fromSearchResults: data, duration: 200)
        #expect(result.plain == "♪ Instrumental")
        #expect(result.synced.isEmpty)
    }

    @Test func timedOnlyLyricsAlsoFillThePlainText() throws {
        let data = try json([["duration": 200.0, "plainLyrics": "", "syncedLyrics": "[00:01.00]one\n[00:02.00]two"]])
        #expect(Lyrics.lyrics(fromSearchResults: data, duration: 200).plain == "one\ntwo")
    }

    @Test(arguments: ["", "not json", "{\"message\":\"busy\"}", "[]"])
    func badRepliesGiveNoLyrics(body: String) {
        let result = Lyrics.lyrics(fromSearchResults: Data(body.utf8), duration: 200)
        #expect(result.plain.isEmpty)
        #expect(result.synced.isEmpty)
    }

    // MARK: Retrying

    @Test(arguments: [0, 429, 500, 502, 503, 599])
    func retriesBusyOrUnreachableServer(status: Int) {
        #expect(Lyrics.isWorthRetrying(status: status))
    }

    @Test(arguments: [200, 301, 400, 401, 403, 404])
    func doesNotRetryAnswersThatWontChange(status: Int) {
        #expect(!Lyrics.isWorthRetrying(status: status))
    }
}
