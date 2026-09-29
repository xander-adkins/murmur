import Foundation
import Testing
@testable import MurmurCore

/// Parent for every suite that touches process-global state (`Settings.environment`, `Settings.defaults`).
/// Serialization is inherited by nested suites, so these never interleave; pure-value suites stay outside.
@Suite(.serialized)
struct GlobalState {
    private init() {}
}

/// Points `Settings` at a throwaway defaults suite and an empty environment for one test instance.
final class SettingsSandbox {
    private let suite = "MurmurTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init(environment: [String: String] = [:]) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        Settings.defaults = defaults
        Settings.environment = environment
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        Settings.defaults = .standard
        Settings.environment = ProcessInfo.processInfo.environment
    }
}

/// Deterministic generator for randomized law tests; failures print the seed-derived inputs.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A transcription engine that does what the test tells it, synchronously.
final class FakeEngine: TranscriptionEngine {
    let name = "Fake"
    var transcript = "Hello world."
    var failOnBegin: DictationFailure?
    private(set) var beginCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private var onEvent: ((EngineEvent) -> Void)?

    func begin(onEvent: @escaping (EngineEvent) -> Void) {
        beginCount += 1
        if let failOnBegin {
            onEvent(.failed(failOnBegin))
            return
        }
        self.onEvent = onEvent
        onEvent(.listening(device: "fake mic"))
    }

    func hear(_ text: String) {
        onEvent?(.partial(text))
    }

    func finish(completion: @escaping (String) -> Void) {
        finishCount += 1
        completion(transcript)
    }

    func cancel() {
        cancelCount += 1
    }
}

extension Array where Element == DictationEffect {
    /// Effects with log lines removed, for tests about behaviour rather than wording.
    var withoutLogs: [DictationEffect] {
        filter { if case .log = $0 { return false } else { return true } }
    }
}

extension DictationState {
    var name: String {
        switch self {
        case .idle: return "idle"
        case .listening: return "listening"
        case .transcribing: return "transcribing"
        case .sent(let text): return "sent(\(text))"
        case .failed(let failure): return "failed(\(failure.message))"
        }
    }
}
