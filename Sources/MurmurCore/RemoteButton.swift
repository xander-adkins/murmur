import Foundation

/// Buttons on the Siri Remote as they arrive over HID. Raw values double as log names.
/// `power`, `appleVendor` and `telephony` are decoded so the HID log names them; nothing acts on them.
enum RemoteButton: String, CaseIterable {
    case menu
    case back
    case siri
    case tv
    case select
    case playPause
    case volumeUp
    case volumeDown
    case power
    case appleVendor
    case telephony

    init?(usagePage: UInt32, usage: UInt32) {
        switch (usagePage, usage) {
        case (0x01, 0x86), (0x01, 0x40):
            self = .menu
        case (0x0C, 0x04):
            self = .siri
        case (0x0C, 0x60), (0x0C, 0x223):
            self = .tv
        case (0x0C, 0x80), (0x0C, 0x41), (0x09, 0x01):
            self = .select
        case (0x0C, 0xCD):
            self = .playPause
        case (0x0C, 0xE9):
            self = .volumeUp
        case (0x0C, 0xEA):
            self = .volumeDown
        case (0x0C, 0x224):
            self = .back
        case (0x0C, 0x30):
            self = .power
        case (0xFF00, _):
            self = .appleVendor
        case (0x0B, 0x21), (0x0B, 0x2F):
            self = .telephony
        default:
            return nil
        }
    }

    /// Menu and Back both mean "escape".
    var isEscape: Bool {
        self == .menu || self == .back
    }

    var displayName: String {
        switch self {
        case .menu: return "Menu"
        case .back: return "Back"
        case .siri: return "Siri / Mic"
        case .tv: return "TV"
        case .select: return "Select"
        case .playPause: return "Play/Pause"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .power: return "Power"
        case .appleVendor: return "Vendor"
        case .telephony: return "Telephony"
        }
    }
}
