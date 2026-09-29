import Testing
@testable import MurmurCore

@Suite struct RemoteButtonTests {
    /// The HID usages a paired Siri Remote actually sends, as observed in the log. Changing one of
    /// these means a button stops working on real hardware.
    @Test(arguments: [
        (UInt32(0x01), UInt32(0x86), RemoteButton.menu),
        (0x01, 0x40, .menu),
        (0x0C, 0x04, .siri),
        (0x0C, 0x60, .tv),
        (0x0C, 0x223, .tv),
        (0x0C, 0x80, .select),
        (0x0C, 0x41, .select),
        (0x09, 0x01, .select),
        (0x0C, 0xCD, .playPause),
        (0x0C, 0xE9, .volumeUp),
        (0x0C, 0xEA, .volumeDown),
        (0x0C, 0x224, .back),
        (0x0C, 0x30, .power),
        (0x0B, 0x21, .telephony),
        (0x0B, 0x2F, .telephony),
        (0xFF00, 0x0010, .appleVendor),
    ])
    func usageDecodesToButton(page: UInt32, usage: UInt32, expected: RemoteButton) {
        #expect(RemoteButton(usagePage: page, usage: usage) == expected)
    }

    @Test func unknownUsagesAreNilNotAGuess() {
        #expect(RemoteButton(usagePage: 0x0C, usage: 0x9999) == nil)
        #expect(RemoteButton(usagePage: 0x07, usage: 0x04) == nil)
        #expect(RemoteButton(usagePage: 0x01, usage: 0x30) == nil, "generic desktop X axis must not become a button")
        #expect(RemoteButton(usagePage: 0x0C, usage: 0x86) == nil, "a documented usage on the wrong page is nothing")
    }

    /// The decoding is a function whose fibres are exactly the documented usage pairs (plus the
    /// whole vendor page), so no arm of the switch can shadow another.
    @Test func decodingFibresAreExactlyTheDocumentedOnes() {
        let documented: [RemoteButton: Set<[UInt32]>] = [
            .menu: [[0x01, 0x86], [0x01, 0x40]], .siri: [[0x0C, 0x04]], .tv: [[0x0C, 0x60], [0x0C, 0x223]],
            .select: [[0x0C, 0x80], [0x0C, 0x41], [0x09, 0x01]], .playPause: [[0x0C, 0xCD]],
            .volumeUp: [[0x0C, 0xE9]], .volumeDown: [[0x0C, 0xEA]], .back: [[0x0C, 0x224]], .power: [[0x0C, 0x30]],
            .telephony: [[0x0B, 0x21], [0x0B, 0x2F]],
        ]
        var fibres: [RemoteButton: Set<[UInt32]>] = [:]
        for page in [UInt32(0x01), 0x07, 0x09, 0x0B, 0x0C, 0x0D, 0xFF00] {
            for usage in UInt32(0)...0x3FF {
                if let button = RemoteButton(usagePage: page, usage: usage) {
                    fibres[button, default: []].insert([page, usage])
                }
            }
        }
        #expect(fibres[.appleVendor]?.count == 0x400, "every usage on the vendor page is appleVendor")
        fibres[.appleVendor] = nil
        #expect(fibres == documented)
    }

    @Test func onlyMenuAndBackCancelATake() {
        #expect(RemoteButton.allCases.filter(\.isEscape) == [.menu, .back])
    }

    @Test func everyButtonHasADisplayName() {
        for button in RemoteButton.allCases {
            #expect(!button.displayName.isEmpty)
        }
    }
}

@Suite struct DictationFailureTests {
    /// Every failure is rendered in a menu item, so none may be empty or run off the menu.
    @Test(arguments: [
        DictationFailure.microphoneDenied, .speechNotAuthorized, .engineNotReady, .recognizerUnavailable,
        .noInputDevice, .audioEngine("boom"), .analyzerSetup("boom"), .noCompatibleFormat, .sessionEnded,
        .nothingHeard, .accessibilityMissing,
    ])
    func messageFitsAMenuItem(failure: DictationFailure) {
        #expect(!failure.message.isEmpty)
        #expect(failure.message.count < 60)
    }
}
