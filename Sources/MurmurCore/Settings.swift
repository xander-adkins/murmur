import Foundation

/// Runtime configuration. Environment variables win so the CLI stays scriptable;
/// the menu bar toggles persist in UserDefaults; otherwise the built-in default applies.
/// Settings without a menu toggle have no defaults layer on purpose.
///
/// `environment` and `defaults` are injectable so tests can run without touching the real ones.
enum Settings {
    static var defaults: UserDefaults = .standard
    static var environment: [String: String] = ProcessInfo.processInfo.environment

    /// Press Return after inserting the transcript (walkie-talkie "release to send").
    static var submitOnRelease: Bool {
        get { flag(env: "MURMUR_SUBMIT", key: "submitOnRelease", default: true) }
        set { defaults.set(newValue, forKey: "submitOnRelease") }
    }

    /// Legacy engine only: keep audio on the Mac instead of Apple's servers when the locale supports it.
    static var onDeviceRecognition: Bool {
        get { flag(env: "MURMUR_ON_DEVICE", key: "onDeviceRecognition", default: true) }
        set { defaults.set(newValue, forKey: "onDeviceRecognition") }
    }

    /// Prefer the macOS 26+ SpeechAnalyzer engine over SFSpeechRecognizer when available.
    static var preferAnalyzerEngine: Bool {
        environment["MURMUR_ENGINE"]?.lowercased() != "legacy"
    }

    /// Insert the transcript by synthesising keystrokes instead of Cmd-V.
    static var insertByTyping: Bool {
        get {
            if let value = environment["MURMUR_INSERT"] {
                return value.lowercased() == "type"
            }
            return defaults.bool(forKey: "insertByTyping")
        }
        set { defaults.set(newValue, forKey: "insertByTyping") }
    }

    /// Put the previous clipboard contents back after pasting.
    static var restoreClipboard: Bool {
        get { flag(env: "MURMUR_RESTORE_CLIPBOARD", key: "restoreClipboard", default: true) }
        set { defaults.set(newValue, forKey: "restoreClipboard") }
    }

    /// Keep the dictation mic streaming between takes so AirPods answer instantly (mic indicator stays lit).
    static var keepMicWarm: Bool {
        get { flag(env: "MURMUR_KEEP_MIC_WARM", key: "keepMicWarm", default: false) }
        set { defaults.set(newValue, forKey: "keepMicWarm") }
    }

    /// Swipes on the remote's touch surface press the arrow keys. Needs terminal control.
    static var swipeNavigation: Bool {
        get { flag(env: "MURMUR_SWIPE", key: "swipeNavigation", default: true) }
        set { defaults.set(newValue, forKey: "swipeNavigation") }
    }

    /// Substring of a CoreAudio input device name, e.g. "AirPods". Nil means the system default input.
    static var inputDeviceName: String? {
        get {
            let value = environment["MURMUR_INPUT_DEVICE"] ?? defaults.string(forKey: "inputDeviceName")
            guard let value, !value.trimmed.isEmpty else {
                return nil
            }
            return value
        }
        set { defaults.set(newValue, forKey: "inputDeviceName") }
    }

    /// Recognition locale; falls back to the system locale.
    static var locale: Locale {
        Locale(identifier: environment["MURMUR_LOCALE"] ?? Locale.current.identifier)
    }

    /// How the transcript is inserted, as one value the machine can carry.
    static var insertion: InsertionMethod {
        insertByTyping ? .type : .paste(restoreClipboard: restoreClipboard)
    }

    /// What happens after insertion, as one value the machine can carry.
    static var submission: Submission {
        submitOnRelease ? .pressReturn(after: submitDelay) : .none
    }

    /// Log the transcript instead of inserting it. For testing the pipeline without touching the focused app.
    static var dryRun: Bool {
        envBool("MURMUR_DRY_RUN") ?? false
    }

    /// Seconds to hold a simulated Siri press shortly after launch. For testing without the remote.
    static var simulatedPressDuration: TimeInterval? {
        environment["MURMUR_SIMULATE_PTT"].flatMap(finiteNonNegative)
    }

    /// Delay between inserting the text and pressing Return, so the terminal finishes consuming the paste.
    static var submitDelay: TimeInterval {
        let millis = environment["MURMUR_SUBMIT_DELAY_MS"].flatMap(finiteNonNegative) ?? 300
        return min(millis, 60_000) / 1000
    }

    /// Post mapped keystrokes to the focused app. The app bundle turns this on; the bare CLI leaves it off.
    static var terminalControlEnabled: Bool {
        envBool("MURMUR_TERMINAL") ?? false
    }

    /// Log to stdout as well as the file (the app bundle turns this off).
    static var stdoutLogging: Bool {
        envBool("MURMUR_STDOUT") ?? true
    }

    /// Run as a menu bar app even when not launched from a bundle.
    static var forceMenuBar: Bool {
        envBool("MURMUR_MENU_BAR") ?? false
    }

    /// HID switches for investigating a remote that does not behave; all default off.
    enum Diagnostics {
        /// List remote HID interfaces without opening them.
        static var passiveHID: Bool { envBool("MURMUR_PASSIVE") ?? false }
        /// Open the remote exclusively instead of shared with the system.
        static var seizeHID: Bool { envBool("MURMUR_SEIZE") ?? false }
        /// Log raw HID input reports (useful for mapping new buttons or the touch surface).
        static var rawReports: Bool { envBool("MURMUR_RAW_REPORTS") ?? false }
    }

    // MARK: - Decoding

    /// One grammar for every boolean variable: 1/true/yes/on and 0/false/no/off. Anything else is
    /// treated as unset so the next layer decides.
    static func envBool(_ name: String) -> Bool? {
        guard let raw = environment[name] else {
            return nil
        }
        switch raw.trimmed.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func finiteNonNegative(_ raw: String) -> Double? {
        guard let value = Double(raw), value.isFinite, value >= 0 else {
            return nil
        }
        return value
    }

    private static func flag(env: String, key: String, default defaultValue: Bool) -> Bool {
        if let value = envBool(env) {
            return value
        }
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        return defaultValue
    }
}
