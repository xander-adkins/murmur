import Foundation

/// Everything the app reports goes to this file; the menu bar "Open Log" item points here.
let logFileURL: URL = {
    let base = FileManager.default.homeDirectoryForCurrentUser
    return base.appendingPathComponent("Library/Logs/Murmur.log")
}()

/// Subsystems that prefix their log lines, so a `grep '\[Dictation\]'` finds one story.
enum LogTopic: String {
    case app = "App"
    case dictation = "Dictation"
    case audio = "Audio"
    case audioProbe = "AudioProbe"
    case hid = "HID"
    case hidReport = "HIDReport"
    case terminal = "TerminalControl"
    case keys = "KeyEvents"
    case insert = "Insert"
    case menu = "Menu"
    case simulate = "Simulate"
}

/// Appends one line to the log file and, unless `MURMUR_STDOUT=0`, echoes it to stdout.
/// Main thread only: it does file I/O and reads `Settings`.
func log(_ topic: LogTopic, _ message: String) {
    let line = "[\(topic.rawValue)] \(message)"
    if Settings.stdoutLogging {
        print(line)
    }

    let data = Data("\(line)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: logFileURL) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        try? FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: logFileURL)
    }
}
