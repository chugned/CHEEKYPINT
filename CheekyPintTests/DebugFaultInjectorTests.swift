import XCTest
@testable import CheekyPint

/// `DebugFaultInjector`'s pure parsing/mapping logic — `values(after:in:)` and `error(for:)` are
/// both plain functions of their arguments rather than `ProcessInfo.processInfo.arguments`
/// directly, so they're testable here without relaunching a process with different launch
/// arguments (the `-uiTestFailOperation`/`-uiTestForceEmpty`-driven behaviour itself is exercised
/// by UI tests, e.g. `docs/STATE_AUDIT.md`'s scripted screenshots, not here).
final class DebugFaultInjectorTests: XCTestCase {

    // MARK: - values(after:in:)

    func testValuesAfterFlagSplitsOnCommas() {
        let arguments = ["/path/to/app", "-uiTestDemo", "-uiTestFailOperation", "createPost,addComment"]
        XCTAssertEqual(DebugFaultInjector.values(after: "-uiTestFailOperation", in: arguments),
                       ["createPost", "addComment"])
    }

    func testValuesAfterFlagWithASingleOperation() {
        let arguments = ["/path/to/app", "-uiTestFailOperation", "exportMyData"]
        XCTAssertEqual(DebugFaultInjector.values(after: "-uiTestFailOperation", in: arguments), ["exportMyData"])
    }

    func testValuesAfterFlagAbsentReturnsEmpty() {
        let arguments = ["/path/to/app", "-uiTestDemo"]
        XCTAssertEqual(DebugFaultInjector.values(after: "-uiTestFailOperation", in: arguments), [])
    }

    /// The flag present but as the very last argument, with nothing after it — must not crash or
    /// read past the array's end.
    func testValuesAfterFlagWithNoFollowingValueReturnsEmpty() {
        let arguments = ["/path/to/app", "-uiTestFailOperation"]
        XCTAssertEqual(DebugFaultInjector.values(after: "-uiTestFailOperation", in: arguments), [])
    }

    /// A different flag's value must never leak into another flag's lookup — this is what lets
    /// `-uiTestFailOperation` and `-uiTestFailError` (and `-uiTestForceEmpty`) coexist on one
    /// launch without any of the three misreading another's argument.
    func testValuesAfterFlagOnlyMatchesItsOwnFlag() {
        let arguments = ["/path/to/app", "-uiTestFailOperation", "addComment", "-uiTestFailError", "offline"]
        XCTAssertEqual(DebugFaultInjector.values(after: "-uiTestFailOperation", in: arguments), ["addComment"])
        XCTAssertEqual(DebugFaultInjector.values(after: "-uiTestFailError", in: arguments), ["offline"])
    }

    // MARK: - error(for:)

    func testErrorForOfflineKind() {
        XCTAssertEqual(DebugFaultInjector.error(for: "offline"), .offline)
    }

    func testErrorForRateLimitedKindCarriesNoHint() {
        XCTAssertEqual(DebugFaultInjector.error(for: "rateLimited"), .rateLimited(hint: nil))
    }

    func testErrorForForbiddenKind() {
        XCTAssertEqual(DebugFaultInjector.error(for: "forbidden"), .forbidden)
    }

    func testErrorForNotFoundKind() {
        XCTAssertEqual(DebugFaultInjector.error(for: "notFound"), .notFound)
    }

    func testErrorForNotAuthenticatedKind() {
        XCTAssertEqual(DebugFaultInjector.error(for: "notAuthenticated"), .notAuthenticated)
    }

    /// The documented default: an unrecognised (or absent, per `DebugFaultInjector`'s own
    /// `errorKind` fallback) kind must still produce *a* visible error, not a crash.
    func testErrorForUnrecognisedKindFallsBackToServer() {
        XCTAssertEqual(DebugFaultInjector.error(for: "not-a-real-kind"), .server(status: 500, message: "Internal Server Error"))
    }

    func testErrorForServerKind() {
        XCTAssertEqual(DebugFaultInjector.error(for: "server"), .server(status: 500, message: "Internal Server Error"))
    }
}
