import Testing
@testable import MurmurCore

@Suite struct RemoteIdentityTests {
    @Test func knownProductIDIsARemoteWhateverItsName() {
        #expect(RemoteIdentity.isLikelyRemote(vendorID: 0x004C, productID: 0x0266, productName: "DNCQQDDNGQQT"))
        #expect(RemoteIdentity.isLikelyRemote(vendorID: 0x004C, productID: 0x0266, productName: nil))
    }

    @Test func nameFallbackForUnknownProductIDs() {
        #expect(RemoteIdentity.isLikelyRemote(vendorID: 0x004C, productID: 0x9999, productName: "Apple Remote"))
        #expect(RemoteIdentity.isLikelyRemote(vendorID: 0x004C, productID: nil, productName: "Siri thing"))
        #expect(RemoteIdentity.isLikelyRemote(vendorID: 0x004C, productID: nil, productName: "apple tv gadget"))
    }

    @Test func otherAppleDevicesAreNotRemotes() {
        #expect(!RemoteIdentity.isLikelyRemote(vendorID: 0x004C, productID: 0x0265, productName: "Magic Trackpad"))
        #expect(!RemoteIdentity.isLikelyRemote(vendorID: 0x004C, productID: nil, productName: nil))
    }

    @Test func nonAppleVendorIsNeverARemote() {
        #expect(!RemoteIdentity.isLikelyRemote(vendorID: 0x046D, productID: 0x0266, productName: "Siri Remote"))
        #expect(!RemoteIdentity.isLikelyRemote(vendorID: nil, productID: 0x0266, productName: "Siri Remote"))
    }
}
