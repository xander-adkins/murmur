import AVFoundation
import CoreAudio
import Foundation

/// One microphone session. The expensive part (building the graph for the chosen device) can run
/// ahead of the button press via `prepare`; `start` then only has to open the mic.
final class AudioCapture {
    private var engine = AVAudioEngine()
    private var format: AVAudioFormat?
    private var prepared: InputSelection?
    private var preparedAt = Date.distantPast
    private var configurationObserver: NSObjectProtocol?

    /// What the graph is bound to, for logs: "AirPods" or "MacBook Pro Microphone (default)".
    private(set) var deviceDescription = "system default"

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    /// Builds the graph for `deviceName` (nil = system default). The mic stays closed.
    func prepare(deviceName: String?) throws {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let selection = Self.resolve(deviceName: deviceName)
        deviceDescription = Self.bind(selection, to: inputNode)

        // After switching devices the node's cached format lags the hardware; preparing the graph
        // syncs it, and the tap must use the synced format or installTap throws a format mismatch.
        engine.prepare()
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            prepared = nil
            throw CaptureError.noInput
        }

        self.format = format
        prepared = selection
        preparedAt = Date()

        // A device or format change invalidates the pre-built graph; starting it anyway raises an
        // uncatchable CoreAudio exception, so drop it and rebuild on the next press.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.engine.isRunning else { return }
            // Selecting a device echoes back as a change on the engine that did it; that one is benign.
            guard Date().timeIntervalSince(self.preparedAt) > Self.selectionEchoWindow else { return }
            self.prepared = nil
            log(.audio, "input configuration changed; pre-built graph discarded")
        }
    }

    func start(deviceName: String?, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let t0 = Date()
        let requested = Self.resolve(deviceName: deviceName, reusing: prepared)
        let reused = GraphReusePolicy.canReuse(prepared: prepared, requested: requested, formatsStillMatch: formatsStillMatch())
        if !reused {
            try prepare(deviceName: deviceName)
        }
        let t1 = Date()

        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            onBuffer(buffer)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            prepared = nil
            throw error
        }

        let format = format ?? inputNode.outputFormat(forBus: 0)
        log(
            .audio,
            "graph \(reused ? "reused" : "built") in \(t0.milliseconds(until: t1))ms, mic opened in \(t1.millisecondsAgo)ms "
                + "(\(Int(format.sampleRate))Hz x\(format.channelCount))"
        )
    }

    func stop() {
        prepared = nil
        guard engine.isRunning else {
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Device selection

    /// How long after `prepare` a configuration-change notification is taken to be our own echo.
    static let selectionEchoWindow: TimeInterval = 1.5

    /// Turns a device-name preference into the binding the graph will actually get.
    /// `reusing` lets a pinned request skip device enumeration when the name still matches.
    static func resolve(deviceName: String?, reusing prepared: InputSelection? = nil) -> InputSelection {
        guard let deviceName else {
            return .systemDefault(id: AudioDeviceProbe.defaultInputDeviceID())
        }
        if case .pinned(let device) = prepared, device.name.localizedCaseInsensitiveContains(deviceName) {
            return .pinned(device)
        }
        if let device = AudioDeviceProbe.inputDevice(matching: deviceName) {
            return .pinned(device)
        }
        log(.audio, "no input device matching \"\(deviceName)\"; using system default")
        return .systemDefault(id: AudioDeviceProbe.defaultInputDeviceID())
    }

    /// Points the input node at the selection. Returns a description for logs.
    static func bind(_ selection: InputSelection, to inputNode: AVAudioInputNode) -> String {
        switch selection {
        case .pinned(let device):
            guard let audioUnit = inputNode.audioUnit else {
                log(.audio, "no input audio unit; using system default input")
                return "system default"
            }
            var deviceID = device.id
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                log(.audio, "failed to select input \(device.name) status=\(status); using system default")
                return "system default"
            }
            return device.name
        case .systemDefault:
            if let device = AudioDeviceProbe.defaultInputDevice() {
                return "\(device.name) (default)"
            }
            return "system default"
        }
    }

    /// The graph built earlier still matches what the hardware will deliver.
    private func formatsStillMatch() -> Bool {
        guard prepared != nil, let format else {
            return false
        }
        let inputNode = engine.inputNode
        let nodeFormat = inputNode.outputFormat(forBus: 0)
        guard nodeFormat.sampleRate == format.sampleRate, nodeFormat.channelCount == format.channelCount else {
            return false
        }
        if let hardware = Self.hardwareFormat(of: inputNode), hardware.sampleRate != nodeFormat.sampleRate {
            return false
        }
        return true
    }

    static func hardwareFormat(of inputNode: AVAudioInputNode) -> AVAudioFormat? {
        guard let audioUnit = inputNode.audioUnit else {
            return nil
        }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &description, &size)
        guard status == noErr else {
            return nil
        }
        return AVAudioFormat(streamDescription: &description)
    }

    enum CaptureError: LocalizedError {
        case noInput

        var errorDescription: String? {
            "No audio input device is available"
        }
    }
}

/// Keeps a second, silent input stream open on the dictation microphone so Bluetooth headsets stay
/// in headset mode between takes. Costs a permanently lit mic indicator and call-quality audio on
/// AirPods. "Off" is a state, not a flag: a pending retry is cancelled by `stop()`.
final class MicrophoneWarmer {
    private enum State {
        case off
        case retrying(DispatchWorkItem)
        case on(AVAudioEngine, observer: NSObjectProtocol, since: Date)
    }

    private var state: State = .off
    private var deviceName: String?

    var isRunning: Bool {
        if case .off = state {
            return false
        }
        return true
    }

    func start(deviceName: String?) {
        stop()
        self.deviceName = deviceName

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let description = AudioCapture.bind(AudioCapture.resolve(deviceName: deviceName), to: inputNode)
        engine.prepare()
        let nodeFormat = inputNode.outputFormat(forBus: 0)
        if let hardware = AudioCapture.hardwareFormat(of: inputNode), hardware.sampleRate != nodeFormat.sampleRate {
            // Starting now would raise an uncatchable CoreAudio exception; try again once the HAL settles.
            log(.audio, "mic warmer: node \(Int(nodeFormat.sampleRate))Hz vs hardware \(Int(hardware.sampleRate))Hz; retrying shortly")
            scheduleRestart(after: 1.0)
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { _, _ in }

        do {
            try engine.start()
        } catch {
            log(.audio, "mic warmer failed to start: \(error.localizedDescription)")
            return
        }

        // The engine stops itself when the device changes (AirPods in or out); come back on the new one.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, case .on(let running, _, let since) = self.state, !running.isRunning else { return }
            // Our own start can echo back as a change; ignore anything within a second of it.
            guard Date().timeIntervalSince(since) > 1 else { return }
            log(.audio, "input configuration changed; restarting mic warmer")
            self.scheduleRestart(after: 0.5)
        }
        state = .on(engine, observer: observer, since: Date())
        log(.audio, "mic warmer on: \(description)")
    }

    func stop() {
        switch state {
        case .off:
            return
        case .retrying(let work):
            work.cancel()
        case .on(let engine, let observer, _):
            NotificationCenter.default.removeObserver(observer)
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            log(.audio, "mic warmer off")
        }
        state = .off
    }

    private func scheduleRestart(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .retrying = self.state else { return }
            self.start(deviceName: self.deviceName)
        }
        state = .retrying(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
