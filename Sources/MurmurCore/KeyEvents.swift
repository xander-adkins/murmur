import CoreGraphics
import Foundation

/// Posts synthetic keyboard events to the focused application.
enum KeyEvents {
    private static let source = CGEventSource(stateID: .hidSystemState)
    private static let tap = CGEventTapLocation.cgSessionEventTap

    /// The virtual key codes this app ever presses.
    enum Key: CGKeyCode, CaseIterable {
        case escape = 53
        case `return` = 36
        case c = 8
        case v = 9
        case upArrow = 126
        case downArrow = 125
        case leftArrow = 123
        case rightArrow = 124

        var name: String {
            switch self {
            case .escape: return "Esc"
            case .return: return "Return"
            case .c: return "C"
            case .v: return "V"
            case .upArrow: return "Up"
            case .downArrow: return "Down"
            case .leftArrow: return "Left"
            case .rightArrow: return "Right"
            }
        }
    }

    static func press(_ key: Key, modifiers: CGEventFlags = []) {
        guard let (down, up) = keyPair(virtualKey: key.rawValue) else {
            log(.keys, "failed to create keyboard event for \(key.name)")
            return
        }
        down.flags = modifiers
        up.flags = modifiers
        post(down, up)
    }

    /// CGEvent carries at most this many UTF-16 units per keyboard event.
    static let maxUnitsPerEvent = 20

    /// Splits text into UTF-16 runs that fit in one keyboard event each, never separating a
    /// surrogate pair (an emoji split across two events types as two broken characters).
    /// Grapheme clusters may still be split across events; the receiving app reassembles them.
    /// Total for every limit: anything below 2 is raised to 2, the smallest unit that holds a scalar.
    static func chunks(of text: String, limit: Int = maxUnitsPerEvent) -> [[UInt16]] {
        let limit = max(limit, 2)
        return text.unicodeScalars.reduce(into: [[UInt16]]()) { chunks, scalar in
            let units = Array(String(scalar).utf16)
            if let last = chunks.last, last.count + units.count <= limit {
                chunks[chunks.count - 1].append(contentsOf: units)
            } else {
                chunks.append(units)
            }
        }
    }

    /// Types arbitrary text without touching the clipboard.
    static func type(_ text: String) {
        for chunk in chunks(of: text) {
            guard let (down, up) = keyPair(virtualKey: 0) else {
                log(.keys, "failed to create text event")
                return
            }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            post(down, up)
            usleep(2_000)
        }
    }

    private static func keyPair(virtualKey: CGKeyCode) -> (CGEvent, CGEvent)? {
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else {
            return nil
        }
        return (down, up)
    }

    private static func post(_ down: CGEvent, _ up: CGEvent) {
        down.post(tap: tap)
        up.post(tap: tap)
    }
}
