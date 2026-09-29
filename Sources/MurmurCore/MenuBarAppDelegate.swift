import AppKit
import Foundation
import ServiceManagement

extension String {
    /// One-line, length-capped version of a transcript for a menu item.
    func menuPreview(limit: Int = 48) -> String {
        let flattened = replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit else {
            return flattened
        }
        return String(flattened.prefix(limit - 1)) + "…"
    }
}

/// A checkbox menu item bound to a setting: how to read it, how to write it, what to do after.
struct SettingToggle {
    let title: String
    let isOn: () -> Bool
    let set: (Bool) -> Void
    var isEnabled: () -> Bool = { true }
    var afterChange: () -> Void = {}
}

/// Boxes a toggle so an `NSMenuItem.representedObject` carries the binding itself, not an index.
private final class ToggleTag {
    let toggle: SettingToggle
    init(_ toggle: SettingToggle) { self.toggle = toggle }
}

/// What the microphone submenu offers: follow macOS, or pin a device by name.
private enum MicrophoneChoice {
    case systemDefault
    case named(String)
}

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller: RemoteController
    private let logFileURL: URL
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusMenuItem = NSMenuItem(title: "Murmur: Starting", action: nil, keyEquivalent: "")
    private let connectionMenuItem = NSMenuItem(title: "Remote: Searching", action: nil, keyEquivalent: "")
    private let dictationMenuItem = NSMenuItem(title: "Mic: Idle", action: nil, keyEquivalent: "")
    private let startMenuItem = NSMenuItem(title: "Start Murmur", action: #selector(startRemote), keyEquivalent: "")
    private let stopMenuItem = NSMenuItem(title: "Stop Murmur", action: #selector(stopRemote), keyEquivalent: "")
    private let microphoneMenu = NSMenu(title: "Microphone")
    private var toggleItems: [NSMenuItem] = []
    private var remoteConnected = false
    private var dictationState: DictationState = .idle
    private var idleReset: DispatchWorkItem?

    init(controller: RemoteController, logFileURL: URL) {
        self.controller = controller
        self.logFileURL = logFileURL
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.remotePresenceHandler = { [weak self] connected in
            DispatchQueue.main.async {
                self?.remoteConnected = connected
                self?.updateMenu()
            }
        }
        controller.dictationStateHandler = { [weak self] state in
            DispatchQueue.main.async {
                self?.apply(state)
            }
        }
        configureStatusItem()
        startRemote()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    // MARK: - Toggles

    private var sendOnReleaseToggle: SettingToggle {
        SettingToggle(
            title: "Send on Release (press Return)",
            isOn: { Settings.submitOnRelease },
            set: { Settings.submitOnRelease = $0 }
        )
    }

    private var keepMicWarmToggle: SettingToggle {
        SettingToggle(
            title: "Keep Microphone Warm (instant AirPods, mic stays on)",
            isOn: { Settings.keepMicWarm },
            set: { Settings.keepMicWarm = $0 },
            afterChange: { [weak self] in self?.controller.microphoneSettingsChanged() }
        )
    }

    private var optionToggles: [SettingToggle] {
        [
            SettingToggle(
                title: "Insert by Typing Instead of Paste",
                isOn: { Settings.insertByTyping },
                set: { Settings.insertByTyping = $0 }
            ),
            SettingToggle(
                title: "Restore Clipboard After Paste",
                isOn: { Settings.restoreClipboard },
                set: { Settings.restoreClipboard = $0 },
                isEnabled: { !Settings.insertByTyping }
            ),
            SettingToggle(
                title: "Keep Audio On Device (legacy engine)",
                isOn: { Settings.onDeviceRecognition },
                set: { Settings.onDeviceRecognition = $0 }
            ),
        ]
    }

    private var launchAtLoginToggle: SettingToggle {
        SettingToggle(
            title: "Launch at Login",
            isOn: { SMAppService.mainApp.status == .enabled },
            set: { enable in
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    log(.menu, "launch at login change failed: \(error.localizedDescription)")
                }
            },
            isEnabled: { isRunningFromBundle }
        )
    }

    private func makeItem(for toggle: SettingToggle) -> NSMenuItem {
        let item = NSMenuItem(title: toggle.title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ToggleTag(toggle)
        toggleItems.append(item)
        return item
    }

    // MARK: - Menu construction

    private func configureStatusItem() {
        startMenuItem.target = self
        stopMenuItem.target = self

        let openLogItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        openLogItem.target = self

        let quitItem = NSMenuItem(title: "Quit Murmur", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneMenu.delegate = self
        microphoneItem.submenu = microphoneMenu

        let optionsItem = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        let optionsMenu = NSMenu()
        optionToggles.map(makeItem).forEach(optionsMenu.addItem)
        optionsItem.submenu = optionsMenu

        let menu = NSMenu()
        menu.delegate = self
        [statusMenuItem, connectionMenuItem, dictationMenuItem].forEach { $0.isEnabled = false }
        menu.addItem(statusMenuItem)
        menu.addItem(connectionMenuItem)
        menu.addItem(dictationMenuItem)
        menu.addItem(.separator())
        menu.addItem(startMenuItem)
        menu.addItem(stopMenuItem)
        menu.addItem(.separator())
        menu.addItem(makeItem(for: sendOnReleaseToggle))
        menu.addItem(microphoneItem)
        menu.addItem(makeItem(for: keepMicWarmToggle))
        menu.addItem(optionsItem)
        menu.addItem(makeItem(for: launchAtLoginToggle))
        menu.addItem(.separator())
        menu.addItem(buttonMappingsMenuItem())
        menu.addItem(openLogItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu

        updateMenu()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === microphoneMenu {
            rebuildMicrophoneMenu()
        } else {
            updateMenu()
        }
    }

    // MARK: - Actions

    @objc private func startRemote() {
        controller.start()
        updateMenu()
    }

    @objc private func stopRemote() {
        controller.stop()
        apply(.idle)
        updateMenu()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(logFileURL)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let toggle = (sender.representedObject as? ToggleTag)?.toggle else {
            return
        }
        let newValue = !toggle.isOn()
        toggle.set(newValue)
        log(.menu, "\(toggle.title)=\(newValue)")
        toggle.afterChange()
        updateMenu()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        switch sender.representedObject as? MicrophoneChoice {
        case .named(let name):
            Settings.inputDeviceName = name
        case .systemDefault, .none:
            Settings.inputDeviceName = nil
        }
        log(.menu, "inputDevice=\(Settings.inputDeviceName ?? "system default")")
        controller.microphoneSettingsChanged()
    }

    // MARK: - State

    private func apply(_ state: DictationState) {
        dictationState = state
        idleReset?.cancel()
        idleReset = nil

        switch state {
        case .sent, .failed:
            let reset = DispatchWorkItem { [weak self] in
                self?.dictationState = .idle
                self?.updateMenu()
            }
            idleReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: reset)
        case .idle, .listening, .transcribing:
            break
        }
        updateMenu()
    }

    private func updateMenu() {
        let running = controller.isRunning
        statusMenuItem.title = running ? "Murmur: Running" : "Murmur: Stopped"
        connectionMenuItem.title = remoteConnected ? "Remote: Connected ✓" : "Remote: Searching..."
        dictationMenuItem.title = dictationTitle()
        startMenuItem.isEnabled = !running
        stopMenuItem.isEnabled = running

        for item in toggleItems {
            guard let toggle = (item.representedObject as? ToggleTag)?.toggle else { continue }
            item.state = toggle.isOn() ? .on : .off
            item.isEnabled = toggle.isEnabled()
        }

        if let button = statusItem.button {
            button.image = statusIcon()
            button.toolTip = "\(statusMenuItem.title) · \(connectionMenuItem.title) · \(dictationMenuItem.title)"
        }
    }

    private func dictationTitle() -> String {
        switch dictationState {
        case .idle:
            return "Mic: Idle (hold Siri button to talk)"
        case .listening(let device):
            return "Mic: Listening — \(device)"
        case .transcribing:
            return "Mic: Transcribing…"
        case .sent(let text):
            return "Sent: \(text.menuPreview())"
        case .failed(let failure):
            return "Mic: \(failure.message)"
        }
    }

    private func statusIcon() -> NSImage? {
        let (symbolName, tint): (String, NSColor?) = {
            switch dictationState {
            case .idle:
                return (controller.isRunning ? "waveform" : "waveform.slash", nil)
            case .listening:
                return ("mic.fill", .systemRed)
            case .transcribing:
                return ("ellipsis.bubble.fill", nil)
            case .sent:
                return ("checkmark.bubble.fill", nil)
            case .failed:
                return ("exclamationmark.bubble.fill", .systemOrange)
            }
        }()

        guard var image = NSImage(systemSymbolName: symbolName, accessibilityDescription: dictationTitle()) else {
            return nil
        }

        if let tint {
            let configuration = NSImage.SymbolConfiguration(paletteColors: [tint])
            image = image.withSymbolConfiguration(configuration) ?? image
            image.isTemplate = false
        } else {
            image.isTemplate = true
        }
        return image
    }

    private func rebuildMicrophoneMenu() {
        microphoneMenu.removeAllItems()
        let selected = Settings.inputDeviceName

        let defaultItem = NSMenuItem(title: "System Default", action: #selector(selectMicrophone(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = MicrophoneChoice.systemDefault
        defaultItem.state = selected == nil ? .on : .off
        if let device = AudioDeviceProbe.defaultInputDevice() {
            defaultItem.title = "System Default (\(device.name))"
        }
        microphoneMenu.addItem(defaultItem)
        microphoneMenu.addItem(.separator())

        let devices = AudioDeviceProbe.inputDevices()
        if devices.isEmpty {
            let none = NSMenuItem(title: "No input devices", action: nil, keyEquivalent: "")
            none.isEnabled = false
            microphoneMenu.addItem(none)
        }

        // The first device whose name contains the pinned text is the one AudioCapture will pick.
        let pinned = selected.flatMap { name in devices.first { $0.name.localizedCaseInsensitiveContains(name) } }
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MicrophoneChoice.named(device.name)
            item.state = device == pinned ? .on : .off
            microphoneMenu.addItem(item)
        }
    }

    private func buttonMappingsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Button Mappings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let lines = [
            "Siri / Mic -> hold to talk, release to send",
            "Menu during a take -> discard it",
        ] + TerminalControl.mappingLines
        for title in lines {
            let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            menuItem.isEnabled = false
            submenu.addItem(menuItem)
        }
        item.submenu = submenu
        return item
    }
}
