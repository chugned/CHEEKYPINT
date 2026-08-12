import XCTest
import CheekyPintCore
@testable import CheekyPint

/// The save-time length gates on the two screens that write `profiles.display_name`/`bio`/`city`.
///
/// Both screens sanitise before saving, and sanitising *truncates* — silently. Profile writes are a
/// plain PostgREST `PATCH` with no server-side clamp, so whatever the client trims never reaches the
/// server to be complained about: the CHECK constraints only ever see the already-shortened text.
/// The regression these gates exist for is the extreme end of that. A grapheme cluster can hold
/// unboundedly many code points, so a single visible character can be wider than a whole field
/// budget, and the truncation then emits nothing at all — turning a non-empty bio into an empty
/// column on Save, with no error anywhere.
///
/// `hasOverLongField` is `static` on both views (like `ComposePostSheet.canSubmit`) precisely so
/// these inputs can be pushed through the real gate without a view instance.
final class ProfileFieldLimitTests: XCTestCase {

    /// One grapheme cluster, 205 code points: `"a"` followed by U+0300…U+0332 four times over.
    /// Nonspacing marks are category Mn, so `ProfileTextSanitizer` strips none of them.
    private static func oversizedCluster(scalars: Int) -> String {
        let marks = (0x0300...0x0332).map { Character(UnicodeScalar($0)!) }
        var text = "a"
        while text.unicodeScalars.count < scalars {
            text.append(marks[(text.unicodeScalars.count - 1) % marks.count])
        }
        return text
    }

    func testFixtureIsOneVisibleCharacterOfManyCodePoints() {
        let bioInput = Self.oversizedCluster(scalars: 205)
        XCTAssertEqual(bioInput.count, 1, "the whole point: this is ONE user-visible character")
        XCTAssertEqual(bioInput.unicodeScalars.count, 205)
    }

    // MARK: - EditProfileView

    /// The verified defect: a 205-code-point bio sanitised to `""` and `EditProfileView.save()` wrote
    /// that empty string over the user's bio. The gate must refuse it.
    func testAnOversizedBioBlocksSave() {
        let bio = Self.oversizedCluster(scalars: 205)
        XCTAssertEqual(ProfileTextSanitizer().sanitizeBio(bio), "",
                       "precondition: this is the input that sanitises away to nothing")

        XCTAssertTrue(EditProfileView.hasOverLongField(displayName: "Nedim", bio: bio, city: "Graz"),
                      "a bio that would be saved as \"\" must block Save")
    }

    /// The flip: the same three fields with an ordinary bio must NOT block Save, or the gate is just
    /// "always true" and the screen is unusable.
    func testAnOrdinaryProfileDoesNotBlockSave() {
        XCTAssertFalse(
            EditProfileView.hasOverLongField(
                displayName: "Nedim", bio: "Two pints and a packet of crisps.", city: "Graz, Austria"),
            "ordinary text in all three fields must leave Save enabled")
    }

    /// A 52-code-point display name in one cluster: the input that greyed out Save with the field
    /// visibly containing a character and nothing on screen explaining it.
    func testAnOversizedDisplayNameBlocksSave() {
        let name = Self.oversizedCluster(scalars: 52)
        XCTAssertEqual(ProfileTextSanitizer().sanitizeDisplayName(name), "",
                       "precondition: sanitises away to nothing, so the old code disabled Save silently")

        XCTAssertTrue(EditProfileView.hasOverLongField(displayName: name, bio: "", city: ""),
                      "the name field must be reported as over-long, not merely empty")
    }

    /// Each of the three fields must be gated independently. City is the one with no other guard at
    /// all — an over-long city was truncated on save with nothing shown, whatever the other fields
    /// contained.
    func testAnOversizedCityBlocksSaveOnItsOwn() {
        let city = String(repeating: "z", count: ProfileTextSanitizer.cityMaxLength + 1)
        XCTAssertTrue(EditProfileView.hasOverLongField(displayName: "Nedim", bio: "", city: city),
                      "61 characters of city must block Save rather than being trimmed to 60")
        XCTAssertFalse(
            EditProfileView.hasOverLongField(
                displayName: "Nedim", bio: "",
                city: String(repeating: "z", count: ProfileTextSanitizer.cityMaxLength)),
            "exactly 60 must still be saveable — the gate is > limit, not >= limit")
    }

    /// The bio boundary in its own right, in code points rather than characters: 80 NFD characters is
    /// 160 code points and must pass; 81 is 162 and must not. A grapheme-based gate passes both.
    func testTheBioBoundaryIsMeasuredInCodePoints() {
        XCTAssertFalse(
            EditProfileView.hasOverLongField(
                displayName: "Nedim", bio: String(repeating: "a\u{0308}", count: 80), city: ""),
            "160 code points (80 NFD characters) must be saveable")
        XCTAssertTrue(
            EditProfileView.hasOverLongField(
                displayName: "Nedim", bio: String(repeating: "a\u{0308}", count: 81), city: ""),
            "162 code points must block Save even though it is only 81 characters")
    }

    // MARK: - ProfileSetupFlowView

    /// Onboarding's Next button had the same defect from the other direction: it disabled on
    /// `sanitizeDisplayName(…).isEmpty`, which this input satisfies, so the user was stuck with no
    /// message. The gate must now report it as over-long so the screen can say so.
    func testAnOversizedDisplayNameBlocksNextInOnboarding() {
        let name = Self.oversizedCluster(scalars: 52)
        XCTAssertTrue(ProfileSetupFlowView.hasOverLongField(displayName: name, city: ""),
                      "an over-long name must block Next with a reason, not just grey it out")
        XCTAssertFalse(ProfileSetupFlowView.hasOverLongField(displayName: "Nedim", city: ""),
                       "an ordinary name must not block Next")
    }

    /// Onboarding writes city too, and the final step commits both fields at once — so the city gate
    /// must hold on every step, not only while the city field is on screen.
    func testAnOversizedCityBlocksTheFinalOnboardingStep() {
        let city = String(repeating: "z", count: ProfileTextSanitizer.cityMaxLength + 1)
        XCTAssertTrue(ProfileSetupFlowView.hasOverLongField(displayName: "Nedim", city: city),
                      "an over-long city must block Start pouring, whichever step is showing")
        XCTAssertFalse(ProfileSetupFlowView.hasOverLongField(displayName: "Nedim", city: "Graz, Austria"),
                       "an ordinary city must not")
    }

    /// The two screens must agree on the display-name limit: they write the same column, and it was
    /// exactly this kind of per-screen divergence that left the user-report path unsanitised.
    func testBothScreensAgreeOnTheDisplayNameLimit() {
        let atLimit = String(repeating: "z", count: ProfileTextSanitizer.displayNameMaxLength)
        let overLimit = atLimit + "z"

        XCTAssertEqual(EditProfileView.hasOverLongField(displayName: atLimit, bio: "", city: ""),
                       ProfileSetupFlowView.hasOverLongField(displayName: atLimit, city: ""))
        XCTAssertEqual(EditProfileView.hasOverLongField(displayName: overLimit, bio: "", city: ""),
                       ProfileSetupFlowView.hasOverLongField(displayName: overLimit, city: ""))
        XCTAssertTrue(ProfileSetupFlowView.hasOverLongField(displayName: overLimit, city: ""),
                      "and the shared answer for 41 characters must be \"too long\", not \"fine\"")
    }
}
