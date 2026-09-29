import Testing
@testable import MurmurCore

@Suite struct TranscriptAssemblerTests {
    @Test func emptyByDefault() {
        #expect(TranscriptAssembler().text == "")
    }

    @Test func volatileTextIsShownUntilReplaced() {
        var assembler = TranscriptAssembler()
        assembler.accept(text: "hel", isFinal: false)
        #expect(assembler.text == "hel")
        assembler.accept(text: "hello wor", isFinal: false)
        #expect(assembler.text == "hello wor")
    }

    @Test func finalReplacesVolatileAndIsKept() {
        var assembler = TranscriptAssembler()
        assembler.accept(text: "hello wor", isFinal: false)
        assembler.accept(text: "Hello world.", isFinal: true)
        #expect(assembler.text == "Hello world.")
        assembler.accept(text: "Second", isFinal: false)
        #expect(assembler.text == "Hello world. Second")
    }

    @Test func finalsAreJoinedInOrderWithSingleSpaces() {
        var assembler = TranscriptAssembler()
        assembler.accept(text: "  One.  ", isFinal: true)
        assembler.accept(text: "Two.", isFinal: true)
        assembler.accept(text: "\nThree.\n", isFinal: true)
        #expect(assembler.text == "One. Two. Three.")
    }

    @Test func emptyFinalDoesNotAddSpaces() {
        var assembler = TranscriptAssembler()
        assembler.accept(text: "One.", isFinal: true)
        assembler.accept(text: "   ", isFinal: true)
        assembler.accept(text: "Two.", isFinal: true)
        #expect(assembler.text == "One. Two.")
    }

    @Test func emptyFinalClearsStaleVolatile() {
        var assembler = TranscriptAssembler()
        assembler.accept(text: "guess", isFinal: false)
        assembler.accept(text: "", isFinal: true)
        #expect(assembler.text == "")
    }

    @Test(arguments: [
        (["hello world how are"], "hello world.", "hello world."),
        ([String](), "\u{00A0}x\u{00A0}", "x"),
        ([String](), "a\n\nb", "a\n\nb"),
    ])
    func edgeCases(volatiles: [String], final: String, expected: String) {
        var assembler = TranscriptAssembler()
        volatiles.forEach { assembler.accept(text: $0, isFinal: false) }
        assembler.accept(text: final, isFinal: true)
        #expect(assembler.text == expected)
    }
}

/// `accept` is a fold over (finals as a list, volatile as last-write-wins) and `text` renders it.
@Suite struct TranscriptAssemblerLaws {
    private func join(_ parts: [String]) -> String {
        parts.map(\.trimmed).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Reference model: all finals in order, plus the last volatile if no final came after it.
    private func model(_ ops: [(String, Bool)]) -> String {
        let finals = ops.filter(\.1).map(\.0)
        let trailingVolatile = ops.lastIndex(where: { !$0.1 })
            .flatMap { index in ops[(index + 1)...].contains(where: \.1) ? nil : ops[index].0 } ?? ""
        return join(finals + [trailingVolatile])
    }

    @Test func textIsTheRenderedModel() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        let words = ["", " ", "a", "hello", "wor ld", "\n", "  x  ", "\u{00A0}", "a\nb", "🚀"]
        for _ in 0..<3000 {
            let ops = (0..<Int.random(in: 0...8, using: &rng)).map { _ in
                (words.randomElement(using: &rng)!, Bool.random(using: &rng))
            }
            var assembler = TranscriptAssembler()
            for (text, isFinal) in ops {
                assembler.accept(text: text, isFinal: isFinal)
            }
            #expect(assembler.text == model(ops), "\(ops)")
        }
    }

    @Test func volatileIsIdempotentAndLastWriteWins() {
        var base = TranscriptAssembler()
        base.accept(text: "one.", isFinal: true)

        var once = base
        once.accept(text: "v", isFinal: false)
        var twice = once
        twice.accept(text: "v", isFinal: false)
        #expect(once == twice)

        var replaced = base
        replaced.accept(text: "old", isFinal: false)
        replaced.accept(text: "v", isFinal: false)
        #expect(replaced == once)
    }

    @Test func finalsAppendAndAreNotIdempotent() {
        // The engine contract is "each final arrives once"; the type does not defend against repeats.
        var assembler = TranscriptAssembler()
        assembler.accept(text: "a", isFinal: true)
        assembler.accept(text: "a", isFinal: true)
        #expect(assembler.text == "a a")
    }
}
