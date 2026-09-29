import Testing
@testable import MurmurCore

/// The push-to-talk machine is pure, so each transition is asserted as an exact effect list.
@Suite struct DictationMachineTests {
    private let context = DictationContext.allGranted

    private func drive(_ events: [DictationEvent], context: DictationContext? = nil) -> (DictationMachine, [[DictationEffect]]) {
        var machine = DictationMachine()
        let effects = events.map { machine.handle($0, context: context ?? self.context) }
        return (machine, effects)
    }

    @Test func happyPathPressListenReleaseInsertSent() {
        let (machine, effects) = drive([
            .pressed,
            .engineListening(device: "AirPods"),
            .enginePartial("hel"),
            .released,
            .engineFinished(transcript: " Hello. "),
            .insertionFinished,
        ])
        #expect(effects[0] == [.beginEngine])
        #expect(effects[1] == [.report(.listening(device: "AirPods"))])
        #expect(effects[2] == [.log("partial=hel")])
        #expect(effects[3] == [.report(.transcribing), .finishEngine])
        #expect(effects[4].withoutLogs == [
            .retireEngine, .prewarmNextEngine,
            .insert("Hello.", via: .paste(restoreClipboard: true), then: .pressReturn(after: 0.3)),
        ])
        #expect(effects[5] == [.report(.sent("Hello."))])
        #expect(machine.phase == .idle)
    }

    @Test func theInsertEffectCarriesTheWholeDecision() {
        var typed = context
        typed.insertion = .type
        typed.submission = .none
        let (machine, effects) = drive([.pressed, .released, .engineFinished(transcript: "x")], context: typed)
        #expect(effects[2].last == .insert("x", via: .type, then: .none))
        #expect(machine.phase == .inserting(text: "x"))
    }

    @Test func dryRunReportsSentWithoutInserting() {
        var dry = context
        dry.dryRun = true
        dry.insertion = .type
        let (machine, effects) = drive([.pressed, .released, .engineFinished(transcript: "Hi")], context: dry)
        #expect(effects[2] == [
            .retireEngine, .prewarmNextEngine, .log("transcript=Hi"),
            .log("dry run: would type and press Return"), .report(.sent("Hi")),
        ])
        #expect(machine.phase == .idle)
    }

    @Test func emptyTranscriptIsNothingHeard() {
        let (machine, effects) = drive([.pressed, .released, .engineFinished(transcript: "  \n")])
        #expect(effects[2] == [.retireEngine, .prewarmNextEngine, .log("transcript=<empty>"), .report(.failed(.nothingHeard))])
        #expect(machine.phase == .idle)
    }

    @Test func missingAccessibilityLeavesTextOnClipboardAndAsks() {
        var untrusted = context
        untrusted.accessibilityTrusted = false
        let (machine, effects) = drive([.pressed, .released, .engineFinished(transcript: "Hi")], context: untrusted)
        #expect(effects[2].withoutLogs == [
            .retireEngine, .prewarmNextEngine, .requestAccessibility, .copyToClipboard("Hi"),
            .report(.failed(.accessibilityMissing)),
        ])
        #expect(machine.phase == .idle)
    }

    @Test func missingMicrophoneNeverStartsAnEngine() {
        var denied = context
        denied.microphoneAuthorized = false
        let (machine, effects) = drive([.pressed], context: denied)
        #expect(effects[0].withoutLogs == [.requestMicrophoneAccess, .report(.failed(.microphoneDenied))])
        #expect(machine.phase == .idle)
    }

    @Test(arguments: [
        [DictationEvent.pressed],
        [.pressed, .engineListening(device: "mic")],
        [.pressed, .engineListening(device: "mic"), .released],
    ])
    func cancelWorksInEveryEnginePhase(prefix: [DictationEvent]) {
        var machine = DictationMachine()
        for event in prefix {
            _ = machine.handle(event, context: context)
        }
        let effects = machine.handle(.cancelRequested, context: context)
        #expect(effects == [.cancelEngine, .retireEngine, .prewarmNextEngine, .log("cancelled"), .report(.idle)])
        #expect(machine.phase == .idle)
        #expect(!machine.isListening)
    }

    @Test func cancelWhileInsertingReleasesThePhaseWithoutTouchingAnEngine() {
        var machine = DictationMachine()
        for event in [DictationEvent.pressed, .released, .engineFinished(transcript: "x")] {
            _ = machine.handle(event, context: context)
        }
        #expect(machine.phase == .inserting(text: "x"))
        let effects = machine.handle(.cancelRequested, context: context)
        #expect(effects.withoutLogs == [.report(.idle)])
        #expect(machine.phase == .idle)
        // The inserter's late callback then lands in idle and is dropped.
        #expect(machine.handle(.insertionFinished, context: context) == [])
    }

    @Test func cancelWhenIdleDoesNothing() {
        var machine = DictationMachine()
        #expect(machine.handle(.cancelRequested, context: context) == [])
    }

    @Test func engineFailureClearsTheTakeInEveryEnginePhase() {
        for prefix in [[DictationEvent.pressed], [.pressed, .engineListening(device: "m")], [.pressed, .released]] {
            var machine = DictationMachine()
            prefix.forEach { _ = machine.handle($0, context: context) }
            let effects = machine.handle(.engineFailed(.audioEngine("boom")), context: context)
            #expect(effects.withoutLogs == [
                .cancelEngine, .retireEngine, .prewarmNextEngine,
                .report(.failed(.audioEngine("boom"))),
            ])
            #expect(machine.phase == .idle)
        }
    }

    @Test func pressDuringDeliveryIsAcknowledgedInTheLogButNotActedOn() {
        var machine = DictationMachine()
        for event in [DictationEvent.pressed, .released] {
            _ = machine.handle(event, context: context)
        }
        let whileFinalizing = machine.handle(.pressed, context: context)
        #expect(!whileFinalizing.isEmpty)
        #expect(whileFinalizing.withoutLogs.isEmpty)
        #expect(machine.phase == .finalizing)

        _ = machine.handle(.engineFinished(transcript: "x"), context: context)
        let whileInserting = machine.handle(.pressed, context: context)
        #expect(!whileInserting.isEmpty)
        #expect(whileInserting.withoutLogs.isEmpty)
        #expect(machine.phase == .inserting(text: "x"))
    }

    @Test func eventsOutOfPhaseAreIgnored() {
        var machine = DictationMachine()
        #expect(machine.handle(.released, context: context) == [])
        #expect(machine.handle(.engineFinished(transcript: "ghost"), context: context) == [])
        #expect(machine.handle(.enginePartial("ghost"), context: context) == [])
        #expect(machine.handle(.insertionFinished, context: context) == [])
        #expect(machine.phase == .idle)

        _ = machine.handle(.pressed, context: context)
        #expect(machine.handle(.pressed, context: context) == [], "a repeat press must not start a second engine")
        #expect(machine.handle(.engineFinished(transcript: "early"), context: context) == [], "no transcript before release")
        #expect(machine.phase == .starting)
    }

    @Test func aStaleFinishAfterCancelIsIgnored() {
        var machine = DictationMachine()
        for event in [DictationEvent.pressed, .released, .cancelRequested] {
            _ = machine.handle(event, context: context)
        }
        #expect(machine.handle(.engineFinished(transcript: "late"), context: context) == [])
        #expect(machine.phase == .idle)
    }

    @Test func sentTextIsWhatTheMachineDecidedToInsert() {
        var machine = DictationMachine()
        for event in [DictationEvent.pressed, .released, .engineFinished(transcript: " decided ")] {
            _ = machine.handle(event, context: context)
        }
        #expect(machine.handle(.insertionFinished, context: context) == [.report(.sent("decided"))])
    }

    @Test func listeningDeviceCanBeReportedTwice() {
        let (machine, effects) = drive([.pressed, .engineListening(device: "a"), .engineListening(device: "b")])
        #expect(effects[2] == [.report(.listening(device: "b"))])
        #expect(machine.phase == .listening(device: "b"))
    }
}

/// Invariants over the whole (phase × event × context) space. The space is tiny, so walk all of it.
@Suite struct DictationMachineLaws {
    static let phases: [DictationMachine.Phase] = [.idle, .starting, .listening(device: "d"), .finalizing, .inserting(text: "t")]
    static let events: [DictationEvent] = [
        .pressed, .released, .cancelRequested, .engineListening(device: "e"), .enginePartial("p"),
        .engineFailed(.audioEngine("x")), .engineFinished(transcript: " t "), .insertionFinished,
    ]
    static let contexts: [DictationContext] = [
        .allGranted,
        DictationContext(microphoneAuthorized: false, accessibilityTrusted: true),
        DictationContext(microphoneAuthorized: true, accessibilityTrusted: false),
        DictationContext(microphoneAuthorized: true, accessibilityTrusted: true, dryRun: true),
        DictationContext(microphoneAuthorized: true, accessibilityTrusted: true, submission: .none),
    ]
    static var cells: [(DictationMachine.Phase, DictationEvent, DictationContext)] {
        phases.flatMap { phase in events.flatMap { event in contexts.map { (phase, event, $0) } } }
    }

    private static func isReentrant(_ effect: DictationEffect) -> Bool {
        switch effect {
        case .beginEngine, .finishEngine, .insert:
            return true
        default:
            return false
        }
    }

    private static func isReport(_ effect: DictationEffect) -> Bool {
        if case .report = effect { return true }
        return false
    }

    @Test(arguments: cells)
    func invariants(phase: DictationMachine.Phase, event: DictationEvent, context: DictationContext) {
        var machine = DictationMachine(phase: phase)
        let hadEngine = machine.hasEngine
        let effects = machine.handle(event, context: context)

        let began = effects.contains(.beginEngine)
        let retired = effects.contains(.retireEngine)
        #expect(machine.hasEngine == ((hadEngine || began) && !retired), "hasEngine must equal the effect-derived value")
        #expect(!(began && hadEngine), "never a second engine")
        #expect(!(retired && !hadEngine), "never retire without an engine")
        #expect(!(effects.contains(.cancelEngine) && !hadEngine), "never cancel without an engine")
        #expect(!(effects.contains(.finishEngine) && !(hadEngine && machine.hasEngine)), "finish keeps the engine until it reports")
        #expect(!effects.contains(.report(.idle)) || event == .cancelRequested, "idle is only reported after a cancel")
        #expect(!effects.isEmpty || machine.phase == phase, "a dropped event never moves the phase")
        if let index = effects.firstIndex(of: .retireEngine) {
            #expect(effects.indices.contains(index + 1) && effects[index + 1] == .prewarmNextEngine, "retire is always followed by prewarm")
        }
        let reentrant = effects.filter(Self.isReentrant)
        #expect(reentrant.count <= 1, "at most one re-entrant effect per transition")
        if reentrant.count == 1 {
            #expect(Self.isReentrant(effects[effects.count - 1]), "the re-entrant effect must be last")
        }
        #expect(effects.filter(Self.isReport).count <= 1, "at most one UI report per transition")
        if effects.contains(where: { if case .insert = $0 { return true } else { return false } }) {
            if case .inserting = machine.phase {} else {
                Issue.record("insert must leave the machine inserting; got \(machine.phase)")
            }
        }
        if case .listening(let device) = machine.phase, machine.phase != phase {
            #expect(effects.contains(.report(.listening(device: device))))
        }
    }

    @Test func everyPhaseIsReachableAndEveryPhaseCanReturnToIdle() {
        func step(_ phase: DictationMachine.Phase, _ event: DictationEvent, _ context: DictationContext) -> DictationMachine.Phase {
            var machine = DictationMachine(phase: phase)
            _ = machine.handle(event, context: context)
            return machine.phase
        }

        var seen: Set<DictationMachine.Phase> = [.idle]
        var frontier: [DictationMachine.Phase] = [.idle]
        while let phase = frontier.popLast() {
            for event in Self.events {
                for context in Self.contexts {
                    let next = step(phase, event, context)
                    if seen.insert(next).inserted {
                        frontier.append(next)
                    }
                }
            }
        }
        #expect(seen.count == Self.phases.count, "reachable: \(seen)")

        for phase in Self.phases where phase != .idle {
            let canReturn = Self.events.contains { event in Self.contexts.contains { step(phase, event, $0) == .idle } }
            #expect(canReturn, "\(phase) must be able to reach idle in one step")
        }
    }
}
