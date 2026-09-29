import Foundation
import Testing
@testable import MurmurCore

/// Settings is process-global, so these run one at a time against a throwaway defaults suite.
extension GlobalState {
@Suite final class SettingsTests {
    private let sandbox = SettingsSandbox()

    @Test func builtInDefaults() {
        #expect(Settings.submitOnRelease)
        #expect(Settings.onDeviceRecognition)
        #expect(Settings.restoreClipboard)
        #expect(Settings.preferAnalyzerEngine)
        #expect(!Settings.insertByTyping)
        #expect(!Settings.keepMicWarm)
        #expect(!Settings.dryRun)
        #expect(Settings.inputDeviceName == nil)
        #expect(Settings.simulatedPressDuration == nil)
        #expect(abs(Settings.submitDelay - 0.3) < 0.0001)
        #expect(!Settings.terminalControlEnabled)
        #expect(Settings.stdoutLogging)
        #expect(!Settings.forceMenuBar)
        #expect(Settings.insertion == .paste(restoreClipboard: true))
        #expect(Settings.submission == .pressReturn(after: 0.3))
    }

    @Test func menuTogglesPersistInDefaults() {
        Settings.submitOnRelease = false
        #expect(!Settings.submitOnRelease)
        #expect(Settings.submission == .none)
        Settings.keepMicWarm = true
        #expect(Settings.keepMicWarm)
        Settings.insertByTyping = true
        #expect(Settings.insertByTyping)
        #expect(Settings.insertion == .type)
        Settings.restoreClipboard = false
        Settings.insertByTyping = false
        #expect(Settings.insertion == .paste(restoreClipboard: false))
        Settings.inputDeviceName = "AirPods"
        #expect(Settings.inputDeviceName == "AirPods")
    }

    @Test func environmentOverridesDefaults() {
        Settings.submitOnRelease = false
        Settings.environment = ["MURMUR_SUBMIT": "1"]
        #expect(Settings.submitOnRelease)
        Settings.environment = ["MURMUR_SUBMIT": "0"]
        #expect(!Settings.submitOnRelease)
    }

    @Test func unparseableEnvironmentFallsThroughToTheNextLayer() {
        Settings.submitOnRelease = false
        Settings.environment = ["MURMUR_SUBMIT": "maybe"]
        #expect(!Settings.submitOnRelease, "garbage in the environment must not override a persisted choice")
        Settings.environment = ["MURMUR_DRY_RUN": "maybe"]
        #expect(!Settings.dryRun)
    }

    @Test func engineAndInsertModeStrings() {
        Settings.environment = ["MURMUR_ENGINE": "legacy"]
        #expect(!Settings.preferAnalyzerEngine)
        Settings.environment = ["MURMUR_ENGINE": "LEGACY"]
        #expect(!Settings.preferAnalyzerEngine)
        Settings.environment = ["MURMUR_ENGINE": "analyzer"]
        #expect(Settings.preferAnalyzerEngine)

        Settings.environment = ["MURMUR_INSERT": "type"]
        #expect(Settings.insertByTyping)
        Settings.environment = ["MURMUR_INSERT": "paste"]
        #expect(!Settings.insertByTyping)
    }

    @Test func blankInputDeviceMeansSystemDefault() {
        Settings.inputDeviceName = "   "
        #expect(Settings.inputDeviceName == nil)
        Settings.environment = ["MURMUR_INPUT_DEVICE": ""]
        #expect(Settings.inputDeviceName == nil)
        Settings.environment = ["MURMUR_INPUT_DEVICE": "MacBook Pro"]
        #expect(Settings.inputDeviceName == "MacBook Pro")
    }

    @Test func numericSettings() {
        Settings.environment = ["MURMUR_SUBMIT_DELAY_MS": "750", "MURMUR_SIMULATE_PTT": "6.5"]
        #expect(abs(Settings.submitDelay - 0.75) < 0.0001)
        #expect(Settings.simulatedPressDuration == 6.5)

        Settings.environment = ["MURMUR_SUBMIT_DELAY_MS": "abc", "MURMUR_SIMULATE_PTT": "soon"]
        #expect(abs(Settings.submitDelay - 0.3) < 0.0001)
        #expect(Settings.simulatedPressDuration == nil)
    }

    @Test(arguments: ["inf", "nan", "-1", "1e15", "-inf"])
    func submitDelayIsAlwaysFiniteNonNegativeAndBounded(raw: String) {
        Settings.environment = ["MURMUR_SUBMIT_DELAY_MS": raw]
        let delay = Settings.submitDelay
        #expect(delay.isFinite && delay >= 0 && delay <= 60)
    }

    @Test(arguments: ["inf", "nan", "-3"])
    func simulatedPressRejectsNonFiniteOrNegative(raw: String) {
        Settings.environment = ["MURMUR_SIMULATE_PTT": raw]
        #expect(Settings.simulatedPressDuration == nil)
    }

    @Test func localeOverride() {
        Settings.environment = ["MURMUR_LOCALE": "en-GB"]
        #expect(Settings.locale.identifier == "en-GB")
    }

    @Test func diagnosticsDefaultOff() {
        #expect(!Settings.Diagnostics.passiveHID)
        #expect(!Settings.Diagnostics.seizeHID)
        #expect(!Settings.Diagnostics.rawReports)

        Settings.environment = ["MURMUR_PASSIVE": "1", "MURMUR_RAW_REPORTS": "1", "MURMUR_STDOUT": "0"]
        #expect(Settings.Diagnostics.passiveHID)
        #expect(Settings.Diagnostics.rawReports)
        #expect(!Settings.stdoutLogging)
    }
}
}

/// Every boolean variable shares one grammar. `MURMUR_DRY_RUN=true` once meant "not a dry run".
extension GlobalState {
@Suite final class SettingsGrammarTests {
    private let sandbox = SettingsSandbox()

    static let booleans: [(String, () -> Bool)] = [
        ("MURMUR_SUBMIT", { Settings.submitOnRelease }),
        ("MURMUR_ON_DEVICE", { Settings.onDeviceRecognition }),
        ("MURMUR_RESTORE_CLIPBOARD", { Settings.restoreClipboard }),
        ("MURMUR_KEEP_MIC_WARM", { Settings.keepMicWarm }),
        ("MURMUR_DRY_RUN", { Settings.dryRun }),
        ("MURMUR_TERMINAL", { Settings.terminalControlEnabled }),
        ("MURMUR_STDOUT", { Settings.stdoutLogging }),
        ("MURMUR_MENU_BAR", { Settings.forceMenuBar }),
        ("MURMUR_PASSIVE", { Settings.Diagnostics.passiveHID }),
        ("MURMUR_SEIZE", { Settings.Diagnostics.seizeHID }),
        ("MURMUR_RAW_REPORTS", { Settings.Diagnostics.rawReports }),
    ]
    static let spellings: [(String, Bool)] = [
        ("1", true), ("true", true), ("TRUE", true), ("yes", true), ("on", true), (" 1 ", true),
        ("0", false), ("false", false), ("no", false), ("off", false),
    ]

    @Test(arguments: booleans, spellings)
    func everyBooleanSettingSharesOneGrammar(setting: (String, () -> Bool), spelling: (String, Bool)) {
        Settings.environment = [setting.0: spelling.0]
        #expect(setting.1() == spelling.1, "\(setting.0)=\(spelling.0)")
    }
}
}

@Suite struct MenuPreviewTests {
    @Test func shortTextUnchanged() {
        #expect("Hello".menuPreview() == "Hello")
    }

    @Test func newlinesFlattened() {
        #expect("Line one\nline two".menuPreview() == "Line one line two")
    }

    @Test func longTextTruncatedWithEllipsisWithinLimit() {
        let long = String(repeating: "x", count: 100)
        let preview = long.menuPreview(limit: 48)
        #expect(preview.count == 48)
        #expect(preview.hasSuffix("…"))
    }
}
