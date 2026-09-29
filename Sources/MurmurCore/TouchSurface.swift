import Foundation

/// Reads the remote's touch surface through MultitouchSupport, the private framework macOS uses
/// for its own trackpads; the remote's surface never reaches IOHIDManager. The framework is
/// loaded with `dlopen` so the build needs no private headers and a system without it simply has
/// no swipes. Frames become `TouchEvent`s for `SwipeRecognizer`; swipes go to `onSwipe` on the
/// main thread.
final class TouchSurface {
    private let framework = MultitouchFramework.load()
    private let onSwipe: (SwipeDirection) -> Void
    /// Started devices by MultitouchSupport device id, each retained for as long as it runs.
    private var devices: [UInt64: MultitouchFramework.Device] = [:]
    private var stroke = SwipeRecognizer.Stroke.idle
    private var rescanTimer: Timer?
    private(set) var isStarted = false

    /// The surface is owned for the life of the controller; the C callback holds it unretained.
    init(onSwipe: @escaping (SwipeDirection) -> Void) {
        self.onSwipe = onSwipe
    }

    func start() {
        guard !isStarted else {
            return
        }
        guard framework != nil else {
            log(.touch, "MultitouchSupport unavailable; swipes off")
            return
        }
        isStarted = true
        log(.touch, "on; looking for the remote's touch surface")
        reconcile()
        // The surface comes and goes with the remote's sleep; the list is the only way to notice,
        // and the first swipe after a doze is lost until it is read again, so look often.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.reconcile() }
        RunLoop.main.add(timer, forMode: .common)
        rescanTimer = timer
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        rescanTimer?.invalidate()
        rescanTimer = nil
        Array(devices.keys).forEach { stopDevice(id: $0) }
        stroke = .idle
        log(.touch, "off")
    }

    /// A button event proves the remote is awake, so its surface may have just appeared.
    func remoteWoke() {
        guard isStarted, devices.isEmpty else {
            return
        }
        reconcile()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.reconcile()
        }
    }

    // MARK: - Devices

    private func reconcile() {
        guard isStarted, let framework else {
            return
        }
        let listed = framework.remoteSurfaces()
        for id in Set(devices.keys).subtracting(listed.keys) {
            stopDevice(id: id)
        }
        for (id, device) in listed {
            if let current = devices[id] {
                if framework.isRunning(current) {
                    framework.release(device)
                    continue
                }
                log(.touch, "surface \(hex(id)) stopped delivering; restarting")
                stopDevice(id: id)
            }
            startDevice(device, id: id)
        }
    }

    /// Takes over the caller's reference to `device`: kept in `devices` while it runs, released on failure.
    private func startDevice(_ device: MultitouchFramework.Device, id: UInt64) {
        guard let framework else {
            return
        }
        framework.registerFrameCallback(device, multitouchFrameReceived, Unmanaged.passUnretained(self).toOpaque())
        let status = framework.start(device, 0)
        guard status == 0 else {
            log(.touch, "start failed for surface \(hex(id)) status=\(hex(status))")
            framework.unregisterFrameCallback(device, multitouchFrameReceived)
            framework.release(device)
            return
        }
        devices[id] = device
        log(.touch, "reading surface \(hex(id)) \(framework.describe(device))")
    }

    private func stopDevice(id: UInt64) {
        guard let framework, let device = devices.removeValue(forKey: id) else {
            return
        }
        framework.unregisterFrameCallback(device, multitouchFrameReceived)
        _ = framework.stop(device)
        framework.release(device)
        stroke = .idle
        log(.touch, "surface \(hex(id)) gone")
    }

    // MARK: - Frames

    /// Main thread. The recognizer decides; this only carries its answer out.
    fileprivate func receive(_ event: TouchEvent) {
        guard isStarted else {
            return
        }
        let (next, swipe) = SwipeRecognizer.step(stroke, event)
        stroke = next
        if let swipe {
            onSwipe(swipe)
        }
    }

    private func hex<T: BinaryInteger>(_ value: T) -> String {
        "0x" + String(UInt64(truncatingIfNeeded: value), radix: 16, uppercase: true)
    }
}

/// Runs on MultitouchSupport's own thread with a buffer that is valid only for the call, so the
/// frame is decoded here and the decision made on the main thread.
private let multitouchFrameReceived: MultitouchFramework.FrameCallback = { _, touches, count, _, _, context in
    guard let context else { return }
    let event = TouchEvent(frame: MultitouchFramework.contacts(in: touches, count: count))
    let surface = Unmanaged<TouchSurface>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        surface.receive(event)
    }
}

/// The handful of MultitouchSupport entry points Murmur uses, bound at runtime.
struct MultitouchFramework {
    typealias Device = UnsafeMutableRawPointer
    typealias FrameCallback = @convention(c) (Device, UnsafeMutableRawPointer?, Int, Double, Int, UnsafeMutableRawPointer?) -> Void

    let createList: @convention(c) () -> Unmanaged<CFArray>?
    let isBuiltIn: @convention(c) (Device) -> Bool
    let isRunning: @convention(c) (Device) -> Bool
    let deviceID: @convention(c) (Device, UnsafeMutablePointer<UInt64>) -> Int32
    let familyID: @convention(c) (Device, UnsafeMutablePointer<Int32>) -> Int32
    let surfaceDimensions: @convention(c) (Device, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    let registerFrameCallback: @convention(c) (Device, FrameCallback, UnsafeMutableRawPointer?) -> Void
    let unregisterFrameCallback: @convention(c) (Device, FrameCallback) -> Void
    let start: @convention(c) (Device, Int32) -> Int32
    let stop: @convention(c) (Device) -> Int32

    static let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    /// Surfaces this small are remotes; every trackpad is far larger. In 0.01 mm units.
    static let maximumRemoteSurfaceSide: Int32 = 6000

    /// Size in bytes of one `MTTouch` record in a frame buffer.
    static let touchStride = 96

    static func load() -> MultitouchFramework? {
        guard let handle = dlopen(path, RTLD_NOW) else {
            return nil
        }
        func symbol<T>(_ name: String) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard
            let createList: @convention(c) () -> Unmanaged<CFArray>? = symbol("MTDeviceCreateList"),
            let isBuiltIn: @convention(c) (Device) -> Bool = symbol("MTDeviceIsBuiltIn"),
            let isRunning: @convention(c) (Device) -> Bool = symbol("MTDeviceIsRunning"),
            let deviceID: @convention(c) (Device, UnsafeMutablePointer<UInt64>) -> Int32 = symbol("MTDeviceGetDeviceID"),
            let familyID: @convention(c) (Device, UnsafeMutablePointer<Int32>) -> Int32 = symbol("MTDeviceGetFamilyID"),
            let surfaceDimensions: @convention(c) (Device, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
                = symbol("MTDeviceGetSensorSurfaceDimensions"),
            let registerFrameCallback: @convention(c) (Device, FrameCallback, UnsafeMutableRawPointer?) -> Void
                = symbol("MTRegisterContactFrameCallbackWithRefcon"),
            let unregisterFrameCallback: @convention(c) (Device, FrameCallback) -> Void = symbol("MTUnregisterContactFrameCallback"),
            let start: @convention(c) (Device, Int32) -> Int32 = symbol("MTDeviceStart"),
            let stop: @convention(c) (Device) -> Int32 = symbol("MTDeviceStop")
        else {
            return nil
        }
        return MultitouchFramework(
            createList: createList, isBuiltIn: isBuiltIn, isRunning: isRunning, deviceID: deviceID,
            familyID: familyID, surfaceDimensions: surfaceDimensions,
            registerFrameCallback: registerFrameCallback, unregisterFrameCallback: unregisterFrameCallback,
            start: start, stop: stop
        )
    }

    /// Remote-sized surfaces currently attached, by device id. The list owns its devices and
    /// frees them with it, so each one returned carries a retain the caller must `release`.
    func remoteSurfaces() -> [UInt64: Device] {
        guard let list = createList()?.takeRetainedValue() else {
            return [:]
        }
        return (list as [AnyObject]).reduce(into: [:]) { surfaces, item in
            let device = Unmanaged.passUnretained(item).toOpaque()
            if isRemoteSurface(device) {
                surfaces[id(of: device)] = Unmanaged.passRetained(item).toOpaque()
            }
        }
    }

    func release(_ device: Device) {
        Unmanaged<AnyObject>.fromOpaque(device).release()
    }

    func describe(_ device: Device) -> String {
        var family: Int32 = -1
        _ = familyID(device, &family)
        let (width, height) = dimensions(of: device)
        return "family=\(family) surface=\(width)x\(height)"
    }

    private func isRemoteSurface(_ device: Device) -> Bool {
        let (width, height) = dimensions(of: device)
        let side = max(width, height)
        return !isBuiltIn(device) && side > 0 && side < Self.maximumRemoteSurfaceSide
    }

    private func id(of device: Device) -> UInt64 {
        var id: UInt64 = 0
        _ = deviceID(device, &id)
        return id
    }

    private func dimensions(of device: Device) -> (Int32, Int32) {
        var width: Int32 = 0
        var height: Int32 = 0
        _ = surfaceDimensions(device, &width, &height)
        return (width, height)
    }

    /// Decodes the `MTTouch` records of a frame: state at byte 20, normalized position at 32.
    static func contacts(in touches: UnsafeMutableRawPointer?, count: Int) -> [MultitouchContact] {
        guard let touches, count > 0 else {
            return []
        }
        return (0..<count).map { index in
            let record = touches + index * touchStride
            let state = MultitouchState(rawValue: record.load(fromByteOffset: 20, as: Int32.self)) ?? .notTracking
            let x = record.load(fromByteOffset: 32, as: Float.self)
            let y = record.load(fromByteOffset: 36, as: Float.self)
            return MultitouchContact(state: state, position: TouchPoint(x: Double(x), y: Double(y)))
        }
    }
}
