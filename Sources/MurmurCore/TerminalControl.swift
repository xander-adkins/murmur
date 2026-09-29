import ApplicationServices
import CoreGraphics
import Foundation

/// Maps the remote's other buttons, and swipes on its touch surface, to keystrokes in the
/// focused terminal.
final class TerminalControl {
    let isEnabled = Settings.terminalControlEnabled

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

    /// Swipes post the arrow key of their direction, which is how agent menus are navigated.
    static let swipeMapping: [SwipeDirection: KeyMapping] = [
        .up: KeyMapping(key: .upArrow),
        .down: KeyMapping(key: .downArrow),
        .left: KeyMapping(key: .leftArrow),
        .right: KeyMapping(key: .rightArrow),
    ]

    /// "Menu -> Esc" lines in button order, then the swipes; the single source for the log line
    /// and the menu.
    static var mappingLines: [String] {
        let buttons = RemoteButton.allCases.compactMap { button in
            keyMapping[button].map { "\(button.displayName) -> \($0.name)" }
        }
        let swipes = SwipeDirection.allCases.compactMap { direction in
            swipeMapping[direction].map { "Swipe \(direction.displayName) -> \($0.name)" }
        }
        return buttons + swipes
    }

    func start() {
        guard isEnabled else {
            log(.terminal, "off")
            return
        }

        log(.terminal, "on; \(Self.mappingLines.joined(separator: ", "))")
        if !requestAccessibilityTrustIfNeeded() {
            log(.terminal, "Accessibility permission is not granted; posted key events may be ignored.")
        }
    }

    func handle(button: RemoteButton, isPressed: Bool) {
        guard isPressed, let mapping = Self.keyMapping[button] else {
            return
        }
        press(mapping, for: "button=\(button.rawValue)")
    }

    func handle(swipe: SwipeDirection) {
        guard let mapping = Self.swipeMapping[swipe] else {
            return
        }
        press(mapping, for: "swipe=\(swipe.rawValue)")
    }

    private func press(_ mapping: KeyMapping, for source: String) {
        guard isEnabled else {
            return
        }
        KeyEvents.press(mapping.key, modifiers: mapping.modifiers)
        log(.terminal, "\(source) key=\(mapping.name)")
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
