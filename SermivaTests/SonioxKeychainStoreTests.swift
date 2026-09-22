import XCTest
@testable import Sermiva

/// Keychain round trip only - the one place production code touches the
/// key, per AGENTS.md's rule that it never appears anywhere else. Uses a
/// throwaway value, never a real key.
final class SonioxKeychainStoreTests: XCTestCase {
    override func tearDown() {
        SonioxKeychainStore.deleteKey()
        super.tearDown()
    }

    func test_saveThenLoadRoundTripsTheSameKey() {
        SonioxKeychainStore.deleteKey()
        XCTAssertNil(SonioxKeychainStore.loadKey())

        SonioxKeychainStore.saveKey("sx_not_a_real_key_0000000000")

        XCTAssertEqual(SonioxKeychainStore.loadKey(), "sx_not_a_real_key_0000000000")
    }

    func test_savingTwiceOverwritesRatherThanFailing() {
        SonioxKeychainStore.saveKey("sx_first_0000000000")
        SonioxKeychainStore.saveKey("sx_second_0000000000")

        XCTAssertEqual(SonioxKeychainStore.loadKey(), "sx_second_0000000000")
    }

    func test_deleteKeyClearsIt() {
        SonioxKeychainStore.saveKey("sx_to_delete_0000000000")
        XCTAssertNotNil(SonioxKeychainStore.loadKey())

        SonioxKeychainStore.deleteKey()

        XCTAssertNil(SonioxKeychainStore.loadKey())
    }
}
