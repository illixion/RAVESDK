/*
 RAVE SDK — subtitle parsing and lookup.

 The fixtures are the dialects media servers actually emit: Jellyfin's
 converted WebVTT, a sidecar SRT with <font> tags and ASS overrides.
 */

import Foundation
import Testing
@testable import RAVEUI

@Suite("Subtitles")
struct RAVESubtitleTests {
    @Test("SubRip with a BOM, CRLF line ends and comma milliseconds")
    func subRip() throws {
        let srt = "\u{FEFF}1\r\n00:00:01,500 --> 00:00:03,000\r\nHello\r\nthere\r\n\r\n2\r\n00:01:02,000 --> 00:01:04,250\r\n<i>Off screen</i>\r\n"
        let track = try RAVESubtitleTrack(text: srt)
        #expect(track.cues.count == 2)
        #expect(track.cues[0].start == 1.5)
        #expect(track.cues[0].plainText == "Hello\nthere")
        #expect(track.cues[1].start == 62)
        #expect(track.cues[1].end == 64.25)
        let italic = track.cues[1].text.runs.first?.inlinePresentationIntent
        #expect(italic == .emphasized)
    }

    @Test("WebVTT header, NOTE blocks, cue ids, short timestamps and settings")
    func webVTT() throws {
        let vtt = """
        WEBVTT - converted

        NOTE this is ignored

        intro
        00:05.000 --> 00:07.000 align:center line:10%
        Sign at the top

        00:00:08.000 --> 00:00:09.000 line:-1
        <c.yellow>Bottom</c> &amp; <b>bold</b>
        """
        let track = try RAVESubtitleTrack(text: vtt)
        #expect(track.cues.count == 2)
        #expect(track.cues[0].start == 5)
        #expect(track.cues[0].placement == .top)
        #expect(track.cues[1].placement == .bottom)
        #expect(track.cues[1].plainText == "Bottom & bold")
    }

    /// Verbatim shape of Jellyfin 10.11's converted SRT (`Subtitles/{n}/Stream.vtt`):
    /// a Region header, `line:90%` on every cue, ASS overrides passed through.
    @Test("Jellyfin's converted WebVTT")
    func jellyfinWebVTT() throws {
        let vtt = "\u{FEFF}WEBVTT\n\nRegion: id:subtitle width:80% lines:3 regionanchor:50%,100% viewportanchor:50%,90%\n\n"
            + "00:00:01.000 --> 00:00:03.500 region:subtitle line:90%\nEnglish subtitle 1\nSecond line\n\n"
            + "00:00:25.000 --> 00:00:27.500 region:subtitle line:90%\n{\\an8}English subtitle 7 (top)\nSecond line\n"
        let track = try RAVESubtitleTrack(text: vtt)
        #expect(track.cues.count == 2)
        #expect(track.cues[0].placement == .bottom)
        #expect(track.cues[0].plainText == "English subtitle 1\nSecond line")
        #expect(track.cues[1].placement == .top)
        #expect(track.cues[1].plainText == "English subtitle 7 (top)\nSecond line")
    }

    @Test("ASS overrides are removed and \\an8 moves a cue to the top")
    func assOverrides() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n{\\an8}<font color=\"#ffff00\">Caption</font>\\NSecond\n"
        let cue = try #require(try RAVESubtitleTrack(text: srt).cues.first)
        #expect(cue.placement == .top)
        #expect(cue.plainText == "Caption\nSecond")
    }

    @Test("Lookup finds overlapping and long cues, and nothing in gaps")
    func lookup() {
        func cue(_ start: Double, _ end: Double, _ text: String) -> RAVESubtitleCue {
            RAVESubtitleCue(start: start, end: end, text: AttributedString(text))
        }
        let track = RAVESubtitleTrack(cues: [cue(10, 12, "b"), cue(0, 30, "long"), cue(11, 13, "c"), cue(40, 41, "d")])
        #expect(track.cues(at: 5).map(\.plainText) == ["long"])
        #expect(track.cues(at: 11.5).map(\.plainText) == ["long", "b", "c"])
        #expect(track.cues(at: 12).map(\.plainText) == ["long", "c"])
        #expect(track.cues(at: 35).isEmpty)
        #expect(track.cues(at: -1).isEmpty)
        #expect(track.cues(at: 41).isEmpty)
    }

    @Test("Empty and cue-less files are errors")
    func empty() {
        #expect(throws: RAVESubtitleError.self) { try RAVESubtitleTrack(text: "WEBVTT\n\n") }
        #expect(throws: RAVESubtitleError.self) { try RAVESubtitleTrack(text: "") }
    }

    #if canImport(SwiftUI)
    @Test("Text sits inside an aspect-fitted picture")
    func fittedRect() {
        let wide = RAVESubtitleOverlay.fittedRect(in: CGSize(width: 1600, height: 900), aspect: 2.4)
        #expect(wide.width == 1600)
        #expect(abs(wide.height - 666.67) < 0.01)
        #expect(abs(wide.minY - 116.67) < 0.01)
        let tall = RAVESubtitleOverlay.fittedRect(in: CGSize(width: 1600, height: 900), aspect: 1)
        #expect(tall == CGRect(x: 350, y: 0, width: 900, height: 900))
    }
    #endif
}
