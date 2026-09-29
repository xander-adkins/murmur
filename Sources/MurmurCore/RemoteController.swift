import Foundation

/// Wires the remote's buttons to dictation and terminal control. One instance per process;
/// the menu bar app starts and stops it, the command-line tool runs it until Ctrl-C.
final class RemoteController {
    private let terminalControl = TerminalControl()
    private let audioDeviceProbe = AudioDeviceProbe()
    private let speechDictation: SpeechDictationController
    private lazy var hidMonitor = HIDMonitor { [weak self] button, isPressed in
        self?.dispatchButton(button, isPressed: isPressed)
    }

    private(set) var isRunning = false

    init(speechDictation: SpeechDictationController = SpeechDictationController()) {
        self.speechDictation = speechDictation
    }

    /// Called with `true` when a Siri Remote HID interface appears and `false` when the last one goes.
    var remotePresenceHandler: ((Bool) -> Void)? {
        get { hidMonitor.remotePresenceHandler }
        set { hidMonitor.remotePresenceHandler = newValue }
    }

    var dictationStateHandler: ((DictationState) -> Void)? {
        get { speechDictation.stateHandler }
        set { speechDictation.stateHandler = newValue }
    }

    func start() {
        guard !isRunning else {
            return
        }
        isRunning = true

        log(.app, "Murmur launched pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "cli") log=\(logFileURL.path)")
        log(.app, "Input Monitoring is required to read the remote; Accessibility to post keystrokes.")

        terminalControl.start()
        speechDictation.start()
        audioDeviceProbe.start()
        hidMonitor.start()
    }

    func stop() {
        guard isRunning else {
            return
        }
        isRunning = false

        hidMonitor.stop()
        speechDictation.stop()
        audioDeviceProbe.stop()
        log(.app, "Murmur stopped")
    }

    /// Routes a button event. Also the entry point for simulated presses (`MURMUR_SIMULATE_PTT`).
    func dispatchButton(_ button: RemoteButton, isPressed: Bool) {
        // Menu during a take (held, or still finalizing) discards it instead of sending Esc to the terminal.
        if button.isEscape, isPressed, speechDictation.hasActiveTake {
            speechDictation.cancel()
            return
        }

        speechDictation.handle(button: button, isPressed: isPressed)
        terminalControl.handle(button: button, isPressed: isPressed)
    }

    /// Re-applies microphone choice and keep-warm after a menu change.
    func microphoneSettingsChanged() {
        speechDictation.microphoneSettingsChanged()
    }
}
