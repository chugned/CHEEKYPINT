import XCTest
@testable import CheekyPintCore

final class FriendTokenTests: XCTestCase {
    func testGeneratedTokenIsWellFormedURLSafeBase64() {
        let token = FriendToken.generate()
        // 32 bytes → 43 base64url chars (no padding).
        XCTAssertEqual(token.rawValue.count, 43)
        XCTAssertFalse(token.rawValue.contains("+"))
        XCTAssertFalse(token.rawValue.contains("/"))
        XCTAssertFalse(token.rawValue.contains("="))
        XCTAssertNotNil(FriendToken(rawValue: token.rawValue))
    }

    func testGeneratedTokensAreUnique() {
        let tokens = Set((0..<500).map { _ in FriendToken.generate().rawValue })
        XCTAssertEqual(tokens.count, 500)
    }

    func testRejectsMalformedToken() {
        XCTAssertNil(FriendToken(rawValue: "too short"))       // space + short
        XCTAssertNil(FriendToken(rawValue: "abc"))             // too short
        XCTAssertNil(FriendToken(rawValue: "has spaces here in it aaaa"))
    }

    func testSHA256HexIsStableAndLowercase() {
        let token = FriendToken(rawValue: "abcdef0123456789abcdefghij")!
        let hash = token.sha256Hex
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, hash.lowercased())
        XCTAssertEqual(token.sha256Hex, hash) // deterministic
    }

    func testShortFriendCode() {
        let code = ShortFriendCode.generate()
        XCTAssertEqual(code.rawValue.count, 8)
        XCTAssertTrue(code.formatted.contains("-"))
        // Round-trips through normalisation with spaces/dashes/lowercase.
        let messy = code.formatted.lowercased().replacingOccurrences(of: "-", with: " ")
        XCTAssertEqual(ShortFriendCode(rawValue: messy)?.rawValue, code.rawValue)
        // Ambiguous glyphs are not in the alphabet and are rejected.
        XCTAssertNil(ShortFriendCode(rawValue: "O0IL1234"))
    }
}

final class DeepLinkTests: XCTestCase {
    private let parser = DeepLinkParser()

    func testParsesCustomSchemeFriendLink() {
        let token = FriendToken.generate()
        let url = URL(string: "cheekypint://friend/\(token.rawValue)")!
        XCTAssertEqual(parser.parse(url), .addFriend(token))
    }

    func testParsesUniversalSessionLink() {
        let token = FriendToken.generate()
        let url = URL(string: "https://cheekypint.app/session/\(token.rawValue)")!
        XCTAssertEqual(parser.parse(url), .joinSession(token))
    }

    func testBuildAndParseRoundTrip() {
        let token = FriendToken.generate()
        XCTAssertEqual(parser.parse(parser.addFriendURL(token)), .addFriend(token))
        XCTAssertEqual(parser.parse(parser.addFriendURL(token, universal: true)), .addFriend(token))
        XCTAssertEqual(parser.parse(parser.joinSessionURL(token)), .joinSession(token))
    }

    func testRejectsUnknownHostsAndSchemes() {
        XCTAssertNil(parser.parse(URL(string: "cheekypint://profile/abcabcabcabcabcabc")!))
        XCTAssertNil(parser.parse(URL(string: "https://evil.example/friend/abcabcabcabcabcabc")!))
        XCTAssertNil(parser.parse(URL(string: "https://cheekypint.app/friend")!))       // no token
        XCTAssertNil(parser.parse(URL(string: "cheekypint://friend/abc")!))             // token too short
    }
}
