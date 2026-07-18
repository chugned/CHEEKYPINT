import XCTest
@testable import CheekyPintCore

final class UsernameValidatorTests: XCTestCase {
    private let validator = UsernameValidator()

    func testAcceptsAndNormalisesValidUsername() {
        XCTAssertEqual(try validator.validate("  BarnabY_01 ").get(), "barnaby_01")
    }

    func testRejectsTooShortAndTooLong() {
        XCTAssertEqual(validator.validate("ab"), .failure(.tooShort(min: 3)))
        XCTAssertEqual(validator.validate(String(repeating: "a", count: 21)), .failure(.tooLong(max: 20)))
    }

    func testMustStartWithLetter() {
        XCTAssertEqual(validator.validate("1abc"), .failure(.mustStartWithLetter))
        XCTAssertEqual(validator.validate("_abc"), .failure(.mustStartWithLetter))
    }

    func testRejectsInvalidCharacters() {
        XCTAssertEqual(validator.validate("bad-name"), .failure(.invalidCharacters))
        XCTAssertEqual(validator.validate("space name"), .failure(.invalidCharacters))
        XCTAssertEqual(validator.validate("café"), .failure(.invalidCharacters))
    }

    func testRejectsReservedNames() {
        XCTAssertEqual(validator.validate("admin"), .failure(.reserved))
        XCTAssertEqual(validator.validate("CheekyPint"), .failure(.reserved))
    }
}

final class ProfileTextSanitizerTests: XCTestCase {
    private let sanitizer = ProfileTextSanitizer()

    func testStripsControlAndZeroWidthCharacters() {
        // Contains a zero-width space (U+200B) and a bidi override (U+202E).
        let dirty = "Ne\u{200B}d\u{202E}im"
        XCTAssertEqual(sanitizer.sanitizeDisplayName(dirty), "Nedim")
    }

    func testCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(sanitizer.sanitizeDisplayName("  The   Kings\tArms  "), "The Kings Arms")
    }

    func testDisplayNameRemovesNewlines() {
        XCTAssertEqual(sanitizer.sanitizeDisplayName("line1\nline2"), "line1 line2")
    }

    func testBioKeepsNewlinesButCollapsesBlankRuns() {
        let bio = "First line\n\n\n\nSecond line"
        XCTAssertEqual(sanitizer.sanitizeBio(bio), "First line\n\nSecond line")
    }

    func testTruncatesToLimitWithoutSplittingGraphemes() {
        let longName = String(repeating: "🍺", count: 60)
        let result = sanitizer.sanitizeDisplayName(longName)
        XCTAssertEqual(result.count, ProfileTextSanitizer.displayNameMaxLength)
        XCTAssertTrue(result.allSatisfy { $0 == "🍺" }, "must not split the emoji into scalars")
    }
}
