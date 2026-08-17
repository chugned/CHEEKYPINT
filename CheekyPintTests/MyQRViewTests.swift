import XCTest
@testable import CheekyPint

/// `MyQRView.cacheKey(forProfile:)` — which Keychain entry the locally cached **raw friend token**
/// is read from and written to.
///
/// That token is a credential: whoever holds it can resolve it to your profile
/// (`resolve_friend_token`) and send you a friend request. The key used to be
/// `session.currentProfile?.id.uuidString ?? "me"`, so any caller that reached this screen without a
/// loaded profile read and wrote a **shared** slot — account B opening My QR would be handed and
/// shown account A's token. Nothing reaches that today (`MainTabView` renders only in
/// `.ready(profile)`, `SessionController.swift:178`, and `MyQRView` is presented only from
/// `FriendsView`'s toolbar), which is exactly why the seam is tested here rather than driven through
/// a presentation path invented for the purpose: the function is reachable, the bad UI state is not.
final class MyQRViewTests: XCTestCase {

    // MARK: - No profile, no shared bucket

    /// THE assertion. The concrete input that flips it is the code that was there before: restore
    /// `?? "me"` (i.e. make this return `.account("me")` when `id` is nil) and this fails.
    func testNoProfileRefusesInsteadOfReturningAKey() {
        guard case .noAccount(let message) = MyQRView.cacheKey(forProfile: nil) else {
            return XCTFail("a nil profile produced a usable Keychain key. Any key returned here " +
                           "is shared by every account that reaches this screen without a loaded " +
                           "profile, and the value behind it is a raw friend token")
        }
        XCTAssertFalse(message.isEmpty,
                       "refusing has to say something — `load(forceNew:)` renders this message in " +
                       "the \"Couldn't load your code\" state, and an empty one is a blank screen")
    }

    /// Belt and braces on the above, and specific about the value that was wrong: `"me"` must not
    /// be a key this function can produce for anybody, profile or no profile.
    func testTheOldSharedFallbackValueIsNotProducedForAnyInput() {
        let candidates: [UUID?] = [nil, UUID(), UUID(uuidString: "00000000-0000-0000-0000-000000000000")]
        for candidate in candidates {
            if case .account(let key) = MyQRView.cacheKey(forProfile: candidate) {
                XCTAssertNotEqual(key, "me",
                                  "'me' was the shared slot two accounts could collide in; no " +
                                  "input may resolve to it. Input: \(String(describing: candidate))")
            }
        }
    }

    // MARK: - One account, one entry

    /// Flip point: return any value that ignores `id` — a constant, or the old `"me"` — and these
    /// two become equal, which is the collision itself.
    func testTwoAccountsNeverShareAnEntry() {
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        guard case .account(let keyA) = MyQRView.cacheKey(forProfile: a),
              case .account(let keyB) = MyQRView.cacheKey(forProfile: b) else {
            return XCTFail("a loaded profile must produce a key")
        }
        XCTAssertNotEqual(keyA, keyB,
                          "two accounts resolved to the same Keychain entry ('\(keyA)'), so the " +
                          "second one to open My QR is shown the first one's friend token")
    }

    /// The same account must resolve to the same entry every time, or reopening the screen would
    /// miss its own cache and silently mint a new token — which revokes the one already printed on
    /// a QR code someone is holding up (`regenerate_friend_token` revokes the caller's live tokens).
    func testTheSameAccountResolvesToTheSameEntry() {
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        guard case .account(let first) = MyQRView.cacheKey(forProfile: id),
              case .account(let second) = MyQRView.cacheKey(forProfile: id) else {
            return XCTFail("a loaded profile must produce a key")
        }
        XCTAssertEqual(first, second)
    }

    // MARK: - Namespaced

    /// The key is namespaced to this feature and still scoped to the one account. Flip point:
    /// return a bare `id.uuidString`, which is what it used to be, and the namespace check fails.
    func testTheKeyIsNamespacedToThisFeatureAndCarriesTheAccount() {
        let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        guard case .account(let key) = MyQRView.cacheKey(forProfile: id) else {
            return XCTFail("a loaded profile must produce a key")
        }
        XCTAssertTrue(key.contains("friendcode"),
                      "'\(key)' says nothing about which feature owns it; a bare identifier can " +
                      "collide with any other entry stored against the same account")
        XCTAssertNotEqual(key, id.uuidString,
                          "the key is still the unnamespaced account identifier it used to be")
        XCTAssertTrue(key.contains(id.uuidString),
                      "'\(key)' has lost the account it is scoped to")
    }

    /// The friend token has its own Keychain service and must never be filed with the auth session.
    func testTheFriendCodeServiceIsNotTheSessionService() {
        XCTAssertNotEqual(MyQRView.keychainService, KeychainStore().service,
                          "the cached friend token must not share a Keychain service with the " +
                          "access/refresh tokens")
    }
}
