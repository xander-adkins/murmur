import Foundation
import Testing
@testable import MurmurCore

/// Drives the shell (controller + fake engine) and checks it interprets the machine's effects.
/// Dry-run mode keeps it from touching the clipboard or posting keystrokes.
extension GlobalState {
@Suite final class DictationFlowTests {
    private let sandbox = SettingsSandbox(environment: ["MURMUR_DRY_RUN": "1"])
    private let engine = FakeEngine()
    private var states: [DictationState] = []
    private let controller: SpeechDictationController

    init() {
        let engine = self.engine
        controller = SpeechDictationController(engineFactory: { .success(engine) }, permissions: .granted)
        controller.stateHandler = { [self] state in states.append(state) }
    }

    private var stateNames: [String] {
        states.map(\.name)
    }

    @Test func pressThenReleaseTranscribesAndSends() {
        controller.handle(button: .siri, isPressed: true)
        #expect(controller.isListening)
        #expect(stateNames == ["listening"])

        controller.handle(button: .siri, isPressed: false)
        #expect(!controller.isListening)
        #expect(stateNames == ["listening", "transcribing", "sent(Hello world.)"])
        #expect(engine.beginCount == 1)
        #expect(engine.finishCount == 1)
        #expect(engine.cancelCount == 0)
    }

    @Test func transcriptIsTrimmedBeforeSending() {
        engine.transcript = "  Ship it.\n"
        controller.handle(button: .siri, isPressed: true)
        controller.handle(button: .siri, isPressed: false)
        #expect(stateNames.last == "sent(Ship it.)")
    }

    @Test func emptyTranscriptReportsNothingHeard() {
        engine.transcript = "   "
        controller.handle(button: .siri, isPressed: true)
        controller.handle(button: .siri, isPressed: false)
        #expect(stateNames == ["listening", "transcribing", "failed(Nothing heard)"])
    }

    @Test func cancelWhileHoldingDiscardsTheTake() {
        controller.handle(button: .siri, isPressed: true)
        controller.cancel()
        #expect(!controller.isListening)
        #expect(!controller.hasActiveTake)
        #expect(engine.cancelCount == 1)
        #expect(engine.finishCount == 0)
        #expect(stateNames == ["listening", "idle"])

        // The release that follows the cancel must not start or finish anything.
        controller.handle(button: .siri, isPressed: false)
        #expect(engine.finishCount == 0)
        #expect(stateNames == ["listening", "idle"])
    }

    @Test func cancelWhenIdleIsHarmless() {
        controller.cancel()
        #expect(states.isEmpty)
        #expect(engine.cancelCount == 0)
    }

    @Test func repeatedPressWhileListeningIsIgnored() {
        controller.handle(button: .siri, isPressed: true)
        controller.handle(button: .siri, isPressed: true)
        controller.handle(button: .siri, isPressed: true)
        #expect(engine.beginCount == 1)
        #expect(stateNames == ["listening"])
    }

    @Test func releaseWithoutPressIsIgnored() {
        controller.handle(button: .siri, isPressed: false)
        #expect(engine.finishCount == 0)
        #expect(states.isEmpty)
    }

    @Test func otherButtonsDoNotStartDictation() {
        for button in RemoteButton.allCases where button != .siri {
            controller.handle(button: button, isPressed: true)
            controller.handle(button: button, isPressed: false)
        }
        #expect(engine.beginCount == 0)
        #expect(states.isEmpty)
    }

    @Test func engineFailureOnBeginIsReportedAndClearsTheTake() {
        engine.failOnBegin = .audioEngine("no input")
        controller.handle(button: .siri, isPressed: true)
        #expect(!controller.isListening)
        #expect(engine.cancelCount == 1)
        #expect(stateNames == ["failed(Audio engine: no input)"])

        // A fresh press afterwards works normally.
        engine.failOnBegin = nil
        controller.handle(button: .siri, isPressed: true)
        controller.handle(button: .siri, isPressed: false)
        #expect(stateNames.last == "sent(Hello world.)")
    }

    @Test func missingMicrophonePermissionFailsBeforeTouchingTheEngine() {
        var permissions = Permissions.granted
        permissions.isMicrophoneAuthorized = { false }
        var prompted = 0
        permissions.requestMicrophoneAccess = { _ in prompted += 1 }
        let denied = SpeechDictationController(engineFactory: { .success(self.engine) }, permissions: permissions)
        var seen: [DictationState] = []
        denied.stateHandler = { seen.append($0) }

        denied.handle(button: .siri, isPressed: true)
        #expect(engine.beginCount == 0)
        #expect(!denied.isListening)
        #expect(prompted == 1)
        #expect(seen.map(\.name) == ["failed(Microphone permission missing)"])
    }

    @Test func engineFactoryFailureIsReportedAsItself() {
        let none = SpeechDictationController(engineFactory: { .failure(.engineNotReady) }, permissions: .granted)
        var seen: [DictationState] = []
        none.stateHandler = { seen.append($0) }
        none.handle(button: .siri, isPressed: true)
        #expect(!none.isListening)
        #expect(seen.map(\.name) == ["failed(Speech engine still loading)"])
    }

    @Test func consecutiveTakesEachGetAFreshEngine() {
        var made = 0
        let counting = SpeechDictationController(engineFactory: { made += 1; return .success(FakeEngine()) }, permissions: .granted)
        counting.handle(button: .siri, isPressed: true)
        counting.handle(button: .siri, isPressed: false)
        counting.handle(button: .siri, isPressed: true)
        counting.handle(button: .siri, isPressed: false)
        #expect(made == 2)
    }

    @Test func stopDuringATakeCancelsAndCreatesNoNewEngine() {
        var made = 0
        let counting = SpeechDictationController(engineFactory: { made += 1; return .success(self.engine) }, permissions: .granted)
        counting.start()
        counting.handle(button: .siri, isPressed: true)
        #expect(made == 1)
        counting.stop()
        #expect(engine.cancelCount == 1)
        #expect(!counting.hasActiveTake)
        // A press after stop still works (the CLI keeps dispatching); it must not use a stale engine.
        counting.handle(button: .siri, isPressed: true)
        #expect(made == 2)
    }

    @Test func settingsChangesAreIgnoredWhileStopped() {
        // Nothing observable should happen: no warmer, no prewarm. The test is that it does not crash
        // or start hardware; the controller exposes no state for it, so this pins the early return.
        controller.microphoneSettingsChanged()
        #expect(states.isEmpty)
    }
}
}

/// The controller-level rule: Menu during a take cancels instead of sending Esc.
extension GlobalState {
@Suite final class RemoteControllerRoutingTests {
    private let sandbox = SettingsSandbox(environment: ["MURMUR_DRY_RUN": "1"])

    private func make() -> (RemoteController, SpeechDictationController, FakeEngine) {
        let engine = FakeEngine()
        let dictation = SpeechDictationController(engineFactory: { .success(engine) }, permissions: .granted)
        return (RemoteController(speechDictation: dictation), dictation, engine)
    }

    @Test func menuWhileHoldingSiriCancelsTheTake() {
        let (controller, dictation, engine) = make()
        var seen: [DictationState] = []
        dictation.stateHandler = { seen.append($0) }

        controller.dispatchButton(.siri, isPressed: true)
        controller.dispatchButton(.menu, isPressed: true)
        controller.dispatchButton(.menu, isPressed: false)
        controller.dispatchButton(.siri, isPressed: false)

        #expect(engine.cancelCount == 1)
        #expect(engine.finishCount == 0)
        #expect(seen.last?.name == "idle")
    }

    @Test func backWorksLikeMenuForCancelling() {
        let (controller, dictation, engine) = make()
        controller.dispatchButton(.siri, isPressed: true)
        controller.dispatchButton(.back, isPressed: true)
        #expect(engine.cancelCount == 1)
        #expect(!dictation.isListening)
    }

    @Test func menuWhenNotListeningDoesNotTouchDictation() {
        let (controller, _, engine) = make()
        controller.dispatchButton(.menu, isPressed: true)
        controller.dispatchButton(.menu, isPressed: false)
        #expect(engine.cancelCount == 0)
        #expect(engine.beginCount == 0)
    }
}
}
