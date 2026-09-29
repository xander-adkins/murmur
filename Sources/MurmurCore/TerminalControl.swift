import ApplicationServices
import CoreGraphics
import Foundation

/// Maps the remote's other buttons to keystrokes in the focused terminal.
final class TerminalControl {
    private let enabled = Settings.terminalControlEnabled

    /// Buttons that post a single keystroke when pressed. Siri is handled by dictation.
    static let keyMapping: [RemoteButton: KeyMapping] = [
        .menu: KeyMapping(key: .escape),
        .back: KeyMapping(key: .escape),
        .tv: KeyMapping(key: .c, modifiers: .maskControl),
        .select: KeyMapping(key: .return),
        .playPause: KeyMapping(key: .return),
        .volumeUp: KeyMapping(key: .upArrow),
        .volumeDown: KeyMapping(key: .downArrow),
    ]

    /// "Menu -> Esc" lines in button order; the single source for the log line and the menu.
    static var mappingLines: [String] {
        RemoteButton.allCases.compactMap { button in
            keyMapping[button].map { "\(button.displayName) -> \($0.name)" }
        }
    }

    func start() {
        guard enabled else {
            log(.terminal, "off")
            return
        }

        log(.terminal, "on; \(Self.mappingLines.joined(separator: ", "))")
        if !requestAccessibilityTrustIfNeeded() {
            log(.terminal, "Accessibility permission is not granted; posted key events may be ignored.")
        }
    }

    func handle(button: RemoteButton, isPressed: Bool) {
        guard enabled, isPressed, let mapping = Self.keyMapping[button] else {
            return
        }
        KeyEvents.press(mapping.key, modifiers: mapping.modifiers)
        log(.terminal, "button=\(button.rawValue) key=\(mapping.name)")
    }

    private func requestAccessibilityTrustIfNeeded() -> Bool {
        if AXIsProcessTrusted() {
            log(.terminal, "Accessibility permission is granted.")
            return true
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        log(.terminal, trusted ? "Accessibility permission is granted." : "requested Accessibility permission prompt.")
        return trusted
    }
}

struct KeyMapping: Equatable {
    let key: KeyEvents.Key
    var modifiers: CGEventFlags = []

    var name: String {
        modifiers.contains(.maskControl) ? "Ctrl-\(key.name)" : key.name
    }
}
