import AppKit
import Darwin
import Foundation

/// Process entry point. Runs as a menu bar app when launched from a `.app` bundle (or with
/// `MURMUR_MENU_BAR=1`), otherwise as a foreground command-line tool that stops on Ctrl-C.
public enum MurmurApp {
    public static func main() {
        if Settings.forceMenuBar || isRunningFromBundle {
            runMenuBarApp()
        } else {
            runCommandLine()
        }
    }

    private static func runCommandLine() {
        let controller = RemoteController()

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

        func stopAndExit() {
            controller.stop()
            CFRunLoopStop(CFRunLoopGetMain())
        }

        sigintSource.setEventHandler(handler: stopAndExit)
        sigtermSource.setEventHandler(handler: stopAndExit)
        sigintSource.resume()
        sigtermSource.resume()

        controller.start()

        if let holdDuration = Settings.simulatedPressDuration {
            let warmUp: TimeInterval = 4
            log(.simulate, "Siri press in \(Int(warmUp))s, held for \(holdDuration)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + warmUp) {
                controller.dispatchButton(.siri, isPressed: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) {
                    controller.dispatchButton(.siri, isPressed: false)
                }
            }
        }

        CFRunLoopRun()
    }

    private static func runMenuBarApp() {
        // The bundle drives the terminal and stays quiet on stdout unless the environment says otherwise.
        Settings.environment = ["MURMUR_TERMINAL": "1", "MURMUR_STDOUT": "0"]
            .merging(ProcessInfo.processInfo.environment) { _, real in real }

        let application = NSApplication.shared
        let delegate = MenuBarAppDelegate(controller: RemoteController(), logFileURL: logFileURL)
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
