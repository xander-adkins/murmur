import CoreAudio
import Foundation

/// What an audio graph's input node is actually bound to after device selection. The *resolved*
/// binding, not the requested one: a pinned name that could not be found falls back to the default.
enum InputSelection: Equatable {
    case pinned(AudioInputDevice)
    /// The system default input; `id` is nil when CoreAudio could not say which device that is.
    case systemDefault(id: AudioDeviceID?)

    var description: String {
        switch self {
        case .pinned(let device):
            return device.name
        case .systemDefault:
            return "system default"
        }
    }
}

/// Decides whether a pre-built audio graph can serve the next take. Pure, so the cases that once
/// crashed the app (a stale graph started against changed hardware) are enumerated in tests.
enum GraphReusePolicy {
    static func canReuse(prepared: InputSelection?, requested: InputSelection, formatsStillMatch: Bool) -> Bool {
        guard let prepared, formatsStillMatch else {
            return false
        }
        switch (prepared, requested) {
        case let (.pinned(a), .pinned(b)):
            return a.id == b.id
        case let (.systemDefault(a?), .systemDefault(b?)):
            // Unknown on either side is not evidence of "unchanged"; rebuild.
            return a == b
        default:
            return false
        }
    }
}
