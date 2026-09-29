import Foundation
import IOKit
import IOKit.hid

/// Decides whether a HID device is a Siri Remote from its vendor, product and name.
enum RemoteIdentity {
    static let appleVendorID = 0x004C

    /// Product IDs seen on Siri Remotes of different generations.
    static let knownProductIDs: Set<Int> = [
        0x0221, 0x0255, 0x0266, 0x0267, 0x0269,
        0x0C4E, 0x0C4F, 0x030D, 0x030E,
    ]

    static func isLikelyRemote(vendorID: Int?, productID: Int?, productName: String?) -> Bool {
        guard vendorID == appleVendorID else {
            return false
        }
        if let productID, knownProductIDs.contains(productID) {
            return true
        }
        let name = (productName ?? "").lowercased()
        return name.contains("remote") || name.contains("siri") || name.contains("apple tv")
    }
}

/// Finds the paired Siri Remote through IOHIDManager and decodes its button usages.
/// A remote shows up as several HID interfaces (consumer, digitizer, vendor); all are opened.
final class HIDMonitor {
    private let seizeRemote = Settings.Diagnostics.seizeHID
    private let passiveMode = Settings.Diagnostics.passiveHID
    private let rawReportLogging = Settings.Diagnostics.rawReports

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var knownDevices: Set<UInt64> = []
    private var openedDevices: Set<UInt64> = []
    private var reportBuffers: [UInt64: UnsafeMutablePointer<UInt8>] = [:]
    private let buttonHandler: (RemoteButton, Bool) -> Void
    var remotePresenceHandler: ((Bool) -> Void)?

    /// The monitor is owned for the life of the process; the C callbacks below hold it unretained.
    init(buttonHandler: @escaping (RemoteButton, Bool) -> Void) {
        self.buttonHandler = buttonHandler
    }

    func start() {
        // Match every Apple HID interface on the usage pages a remote uses; isLikelyRemote filters later.
        let matches: [[String: Any]] = [0x0C, 0x0D, 0xFF00, 0x01].map { page in
            [kIOHIDVendorIDKey: RemoteIdentity.appleVendorID, kIOHIDPrimaryUsagePageKey: page]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatched, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemoved, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        log(.hid, "manager open status=\(openStatus) passive=\(passiveMode) seize=\(seizeRemote) rawReports=\(rawReportLogging)")
        for device in currentDevices().sorted(by: { registryID($0) < registryID($1) }) {
            handleMatchedDevice(device)
        }
    }

    func stop() {
        currentDevices().forEach(closeDeviceIfOpen)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let closeStatus = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        log(.hid, "manager close status=\(closeStatus)")
    }

    // MARK: - Device lifecycle

    fileprivate func handleMatchedDevice(_ device: IOHIDDevice) {
        let id = registryID(device)
        let isNew = knownDevices.insert(id).inserted
        log(.hid, "\(isNew ? "matched" : "re-matched") \(describe(device))")

        guard isLikelyRemote(device) else {
            return
        }

        remotePresenceHandler?(true)
        guard !passiveMode else {
            log(.hid, "passive mode: not opening remote registryID=\(id)")
            return
        }
        openDeviceForInput(device)
    }

    fileprivate func handleRemovedDevice(_ device: IOHIDDevice) {
        knownDevices.remove(registryID(device))
        closeDeviceIfOpen(device)
        log(.hid, "removed \(describe(device))")
        remotePresenceHandler?(currentDevices().contains(where: isLikelyRemote))
    }

    private func openDeviceForInput(_ device: IOHIDDevice) {
        let id = registryID(device)
        guard !openedDevices.contains(id) else {
            return
        }

        let seized = seizeRemote && IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess
        if seizeRemote, !seized {
            log(.hid, "seize failed registryID=\(id), retrying shared")
        }
        if !seized {
            let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard status == kIOReturnSuccess else {
                log(.hid, "open failed registryID=\(id) status=\(status)")
                return
            }
        }
        let mode = seized ? "seized" : "shared"

        openedDevices.insert(id)
        IOHIDDeviceRegisterInputValueCallback(device, hidInputValueReceived, Unmanaged.passUnretained(self).toOpaque())
        if rawReportLogging {
            let size = intProperty(kIOHIDMaxInputReportSizeKey, device: device) ?? 512
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            buffer.initialize(repeating: 0, count: size)
            reportBuffers[id] = buffer
            IOHIDDeviceRegisterInputReportCallback(device, buffer, size, hidInputReportReceived, Unmanaged.passUnretained(self).toOpaque())
        }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        log(.hid, "opened remote registryID=\(id) mode=\(mode)")
    }

    private func closeDeviceIfOpen(_ device: IOHIDDevice) {
        let id = registryID(device)
        guard openedDevices.remove(id) != nil else {
            return
        }

        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let status = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        reportBuffers.removeValue(forKey: id)?.deallocate()
        log(.hid, "closed remote registryID=\(id) status=\(status)")
    }

    // MARK: - Input

    fileprivate func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)
        let button = RemoteButton(usagePage: usagePage, usage: usage)

        log(
            .hid,
            "input registryID=\(registryID(device)) usagePage=\(hex(usagePage)) usage=\(hex(usage)) "
                + "value=\(intValue) button=\(button?.rawValue ?? "-") device=\(shortDeviceName(device))"
        )

        if let button {
            buttonHandler(button, intValue != 0)
        }
    }

    fileprivate func handleInputReport(sender: UnsafeMutableRawPointer?, reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        let device = sender.map { Unmanaged<IOHIDDevice>.fromOpaque($0).takeUnretainedValue() }
        let bytes = Data(bytes: report, count: length).map { String(format: "%02X", $0) }.joined()
        log(.hidReport, "registryID=\(device.map(registryID) ?? 0) reportID=\(hex(reportID)) length=\(length) data=\(bytes)")
    }

    // MARK: - Device properties

    private func currentDevices() -> Set<IOHIDDevice> {
        IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
    }

    private func isLikelyRemote(_ device: IOHIDDevice) -> Bool {
        RemoteIdentity.isLikelyRemote(
            vendorID: intProperty(kIOHIDVendorIDKey, device: device),
            productID: intProperty(kIOHIDProductIDKey, device: device),
            productName: stringProperty(kIOHIDProductKey, device: device)
        )
    }

    private func describe(_ device: IOHIDDevice) -> String {
        let vendorID = intProperty(kIOHIDVendorIDKey, device: device) ?? -1
        let productID = intProperty(kIOHIDProductIDKey, device: device) ?? -1
        let usagePage = intProperty(kIOHIDPrimaryUsagePageKey, device: device) ?? -1
        let usage = intProperty(kIOHIDPrimaryUsageKey, device: device) ?? -1
        let transport = stringProperty(kIOHIDTransportKey, device: device) ?? "unknown"
        let product = stringProperty(kIOHIDProductKey, device: device) ?? "unknown"
        let remoteHint = isLikelyRemote(device) ? " remoteCandidate=yes" : ""
        return "registryID=\(registryID(device)) vendor=\(hex(vendorID)) product=\(hex(productID)) transport=\(transport) "
            + "usagePage=\(hex(usagePage)) usage=\(hex(usage)) productName=\(product)\(remoteHint)"
    }

    private func shortDeviceName(_ device: IOHIDDevice) -> String {
        let product = stringProperty(kIOHIDProductKey, device: device) ?? "unknown"
        let productID = intProperty(kIOHIDProductIDKey, device: device) ?? -1
        return "\(product)(\(hex(productID)))"
    }

    private func intProperty(_ key: String, device: IOHIDDevice) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private func stringProperty(_ key: String, device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private func registryID(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == kIOReturnSuccess ? id : 0
    }

    private func hex<T: BinaryInteger>(_ value: T) -> String {
        String(format: "0x%04X", Int(value))
    }
}

private let hidDeviceMatched: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().handleMatchedDevice(device)
}

private let hidDeviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().handleRemovedDevice(device)
}

private let hidInputValueReceived: IOHIDValueCallback = { context, _, _, value in
    guard let context else { return }
    Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().handleInputValue(value)
}

private let hidInputReportReceived: IOHIDReportCallback = { context, _, sender, _, reportID, report, reportLength in
    guard let context else { return }
    Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
        .handleInputReport(sender: sender, reportID: reportID, report: report, length: reportLength)
}
