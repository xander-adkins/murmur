import AppKit
import Testing
@testable import MurmurCore

@Suite struct KeyEventsTests {
    private func string(_ units: [UInt16]) -> String {
        String(utf16CodeUnits: units, count: units.count)
    }

    @Test func emptyTextHasNoChunks() {
        #expect(KeyEvents.chunks(of: "").isEmpty)
    }

    @Test func shortTextIsOneChunk() {
        let chunks = KeyEvents.chunks(of: "hello")
        #expect(chunks.count == 1)
        #expect(string(chunks[0]) == "hello")
    }

    @Test func chunksNeverExceedTheEventLimit() {
        let text = String(repeating: "abcdefghij", count: 7)
        let chunks = KeyEvents.chunks(of: text)
        #expect(chunks.count == 4)
        #expect(chunks.allSatisfy { $0.count <= KeyEvents.maxUnitsPerEvent })
        #expect(chunks.map(\.count) == [20, 20, 20, 10])
    }

    @Test func everyChunkIsValidUTF16OnItsOwn() {
        // 19 ASCII characters then an emoji: a naive split would put half the surrogate pair in
        // the next event, and the terminal would receive two replacement characters.
        let text = String(repeating: "a", count: 19) + "🎙️ and 🚀 go"
        let chunks = KeyEvents.chunks(of: text)
        for chunk in chunks {
            #expect(String(decoding: chunk, as: UTF16.self).utf16.elementsEqual(chunk), "chunk contains a broken surrogate: \(chunk)")
        }
        #expect(chunks[0].count == 19)
        #expect(chunks.flatMap { $0 }.elementsEqual(text.utf16))
    }

    @Test func customLimit() {
        #expect(KeyEvents.chunks(of: "abcdef", limit: 4).map(\.count) == [4, 2])
        #expect(KeyEvents.chunks(of: "🚀🚀🚀", limit: 2).map(\.count) == [2, 2, 2])
        #expect(KeyEvents.chunks(of: "a🚀b", limit: 3).map(\.count) == [3, 1])
    }

    @Test func limitsBelowASurrogatePairAreRaisedNotTrapped() {
        #expect(KeyEvents.chunks(of: "🚀a", limit: 0).map(\.count) == [2, 1])
        #expect(KeyEvents.chunks(of: "abc", limit: 1).map(\.count) == [2, 1])
    }

    /// Concatenation, bound, validity, non-emptiness and greedy maximality over random strings.
    @Test func chunkLaws() {
        var rng = SplitMix64(seed: 42)
        let alphabet = ["a", "é", "🚀", "🎙️", "👨‍👩‍👧", "\u{301}", " ", "\n", "𝔘", "字", "🇫🇮"]
        for _ in 0..<2000 {
            let text = (0..<Int.random(in: 0...60, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }.joined()
            let limit = Int.random(in: 2...25, using: &rng)
            let chunks = KeyEvents.chunks(of: text, limit: limit)
            #expect(chunks.flatMap { $0 }.elementsEqual(text.utf16))
            #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= limit })
            #expect(chunks.allSatisfy { String(decoding: $0, as: UTF16.self).utf16.elementsEqual($0) })
            for index in chunks.indices.dropLast() {
                let nextFirst = String(decoding: chunks[index + 1], as: UTF16.self).unicodeScalars.first!
                #expect(chunks[index].count + String(nextFirst).utf16.count > limit, "chunk \(index) is not maximal")
            }
        }
    }

    @Test func terminalKeyMappingCoversTheRightButtons() {
        let mapped = Set(TerminalControl.keyMapping.keys)
        #expect(mapped == [.menu, .back, .tv, .select, .playPause, .volumeUp, .volumeDown])
        #expect(TerminalControl.keyMapping[.menu] == TerminalControl.keyMapping[.back])
        #expect(TerminalControl.keyMapping[.select]?.key == .return)
        #expect(TerminalControl.keyMapping[.tv]?.name == "Ctrl-C")
    }

    @Test func everySwipeDirectionPressesItsOwnArrow() {
        #expect(Set(TerminalControl.swipeMapping.keys) == Set(SwipeDirection.allCases))
        #expect(TerminalControl.swipeMapping.values.allSatisfy { $0.modifiers.isEmpty })
        #expect(Set(TerminalControl.swipeMapping.values.map(\.key)).count == SwipeDirection.allCases.count)
    }

    @Test func mappingLinesFollowButtonOrderThenSwipesAndTheTable() {
        #expect(TerminalControl.mappingLines == [
            "Menu -> Esc", "Back -> Esc", "TV -> Ctrl-C", "Select -> Return",
            "Play/Pause -> Return", "Volume Up -> Up", "Volume Down -> Down",
            "Swipe Up -> Up", "Swipe Down -> Down", "Swipe Left -> Left", "Swipe Right -> Right",
        ])
    }
}

@Suite struct PasteboardSnapshotTests {
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MurmurTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    @Test func emptyPasteboardHasNothingToRestore() {
        let pasteboard = makePasteboard()
        #expect(PasteboardSnapshot.capture(from: pasteboard) == nil)
        pasteboard.releaseGlobally()
    }

    @Test func textSurvivesBeingReplaced() {
        let pasteboard = makePasteboard()
        pasteboard.setString("what I had copied", forType: .string)
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("the transcript", forType: .string)
        #expect(pasteboard.string(forType: .string) == "the transcript")

        snapshot?.restore(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "what I had copied")
        pasteboard.releaseGlobally()
    }

    @Test func allTypesOfAnItemAreRestored() {
        let pasteboard = makePasteboard()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setString("<b>rich</b>", forType: .html)
        pasteboard.writeObjects([item])
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("x", forType: .string)
        snapshot?.restore(to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "plain")
        #expect(pasteboard.string(forType: .html) == "<b>rich</b>")
        pasteboard.releaseGlobally()
    }
}
