import Foundation

// MARK: - Vocabulary

/// Why a push-to-talk take produced nothing. Rendered in the menu bar, so every case has a short message.
enum DictationFailure: Error, Equatable {
    case microphoneDenied
    case speechNotAuthorized
    case engineNotReady
    case recognizerUnavailable
    case noInputDevice
    case audioEngine(String)
    case analyzerSetup(String)
    case noCompatibleFormat
    case sessionEnded
    case nothingHeard
    case accessibilityMissing

    var message: String {
        switch self {
        case .microphoneDenied:
            return "Microphone permission missing"
        case .speechNotAuthorized:
            return "Speech Recognition permission missing"
        case .engineNotReady:
            return "Speech engine still loading"
        case .recognizerUnavailable:
            return "Speech recognizer unavailable"
        case .noInputDevice:
            return "No audio input device"
        case .audioEngine(let detail):
            return "Audio engine: \(detail)"
        case .analyzerSetup(let detail):
            return "Speech engine: \(detail)"
        case .noCompatibleFormat:
            return "No compatible audio format"
        case .sessionEnded:
            return "Speech session ended early"
        case .nothingHeard:
            return "Nothing heard"
        case .accessibilityMissing:
            return "Grant Accessibility to paste (text is on clipboard)"
        }
    }
}

/// What the menu bar shows.
enum DictationState: Equatable {
    case idle
    case listening(device: String)
    case transcribing
    case sent(String)
    case failed(DictationFailure)
}

/// How a transcript reaches the focused app.
enum InsertionMethod: Equatable {
    case paste(restoreClipboard: Bool)
    case type
}

/// What happens after the text is in place.
enum Submission: Equatable {
    case none
    case pressReturn(after: TimeInterval)
}

/// What the outside world tells the push-to-talk flow.
enum DictationEvent: Equatable {
    case pressed
    case released
    case cancelRequested
    case engineListening(device: String)
    case enginePartial(String)
    case engineFailed(DictationFailure)
    case engineFinished(transcript: String)
    case insertionFinished
}

/// What the flow asks the outside world to do, in order. The shell executes; the machine decides.
///
/// Ordering rule the shell relies on: at most one effect per list may synchronously feed an event
/// back into the machine (`beginEngine`, `finishEngine`, `insert`), and it is always last.
enum DictationEffect: Equatable {
    case beginEngine
    case finishEngine
    case cancelEngine
    case retireEngine
    case prewarmNextEngine
    case requestMicrophoneAccess
    case requestAccessibility
    case copyToClipboard(String)
    case insert(String, via: InsertionMethod, then: Submission)
    case report(DictationState)
    case log(String)
}

/// Facts the flow needs at the moment of an event, snapshotted by the shell so the machine never
/// reads global state. Permissions have no defaults: forgetting one must not silently mean "granted".
struct DictationContext: Equatable {
    var microphoneAuthorized: Bool
    var accessibilityTrusted: Bool
    var dryRun = false
    var insertion: InsertionMethod = .paste(restoreClipboard: true)
    var submission: Submission = .pressReturn(after: 0.3)

    static let allGranted = DictationContext(microphoneAuthorized: true, accessibilityTrusted: true)
}

// MARK: - Machine

/// The push-to-talk state machine. Pure and value-typed: every transition is
/// `(phase, event) -> (phase, [effect])`, which is what the tests enumerate.
struct DictationMachine: Equatable {
    enum Phase: Equatable, Hashable {
        case idle
        /// Engine asked to start; the microphone is not confirmed open yet.
        case starting
        case listening(device: String)
        /// Button released; waiting for the engine's final transcript.
        case finalizing
        /// Transcript handed to the inserter; waiting for it to finish typing or pasting.
        case inserting(text: String)
    }

    private(set) var phase: Phase = .idle

    init() {}

    /// Starts in a given phase; for exhaustive tests only.
    init(phase: Phase) {
        self.phase = phase
    }

    /// The button is held and a take is in progress.
    var isListening: Bool {
        switch phase {
        case .starting, .listening:
            return true
        case .idle, .finalizing, .inserting:
            return false
        }
    }

    /// An engine exists and may still call back.
    var hasEngine: Bool {
        switch phase {
        case .starting, .listening, .finalizing:
            return true
        case .idle, .inserting:
            return false
        }
    }

    mutating func handle(_ event: DictationEvent, context: DictationContext) -> [DictationEffect] {
        switch (phase, event) {
        case (.idle, .pressed):
            guard context.microphoneAuthorized else {
                return [
                    .log("cannot start: microphone is not authorized"),
                    .requestMicrophoneAccess,
                    .report(.failed(.microphoneDenied)),
                ]
            }
            phase = .starting
            return [.beginEngine]

        case (.finalizing, .pressed), (.inserting, .pressed):
            // Not silent: a quick re-press after release is the likeliest way to lose a take.
            return [.log("press ignored while the previous take is being delivered")]

        case (.starting, .engineListening(let device)), (.listening, .engineListening(let device)):
            phase = .listening(device: device)
            return [.report(.listening(device: device))]

        case (_, .enginePartial(let text)) where hasEngine:
            return [.log("partial=\(text)")]

        case (.starting, .released), (.listening, .released):
            phase = .finalizing
            return [.report(.transcribing), .finishEngine]

        case (_, .cancelRequested) where hasEngine:
            phase = .idle
            return [.cancelEngine, .retireEngine, .prewarmNextEngine, .log("cancelled"), .report(.idle)]

        case (.inserting, .cancelRequested):
            // Nothing to cancel, but the phase must not depend on the inserter calling back.
            phase = .idle
            return [.log("cancelled while inserting"), .report(.idle)]

        case (_, .engineFailed(let failure)) where hasEngine:
            phase = .idle
            return [
                .log("failed: \(failure.message)"),
                .cancelEngine,
                .retireEngine,
                .prewarmNextEngine,
                .report(.failed(failure)),
            ]

        case (.finalizing, .engineFinished(let transcript)):
            return finish(transcript.trimmed, context: context)

        case (.inserting(let text), .insertionFinished):
            phase = .idle
            return [.report(.sent(text))]

        default:
            return []
        }
    }

    private mutating func finish(_ text: String, context: DictationContext) -> [DictationEffect] {
        var effects: [DictationEffect] = [
            .retireEngine,
            .prewarmNextEngine,
            .log("transcript=\(text.isEmpty ? "<empty>" : text)"),
        ]

        guard !text.isEmpty else {
            phase = .idle
            return effects + [.report(.failed(.nothingHeard))]
        }

        if context.dryRun {
            phase = .idle
            let verb = context.insertion == .type ? "type" : "paste"
            let suffix = context.submission == .none ? "" : " and press Return"
            effects.append(.log("dry run: would \(verb)\(suffix)"))
            return effects + [.report(.sent(text))]
        }

        guard context.accessibilityTrusted else {
            // Without Accessibility the paste and Return are silently dropped, so say so instead of pretending.
            phase = .idle
            return effects + [
                .log("Accessibility permission missing; transcript left on clipboard, keystrokes not posted"),
                .requestAccessibility,
                .copyToClipboard(text),
                .report(.failed(.accessibilityMissing)),
            ]
        }

        phase = .inserting(text: text)
        return effects + [.insert(text, via: context.insertion, then: context.submission)]
    }
}
