import XCTest
@testable import CheekyPint

/// Regression tests for the beer-photo URLs.
///
/// The catalog used to point at `commons.wikimedia.org/wiki/Special:FilePath/...?width=700`, which
/// cost two redirects per image and — because 700 is not one of Wikimedia's permitted thumbnail
/// widths — silently served the 960px bucket, roughly 3x the bytes the card needs. These pin the
/// direct-CDN form so that cannot regress.
final class BeerImageURLTests: XCTestCase {

    private func beer(_ id: String) -> BeerChoice? {
        BeerCatalog.beers.first { $0.id == id }
    }

    /// Expected values were confirmed against Wikimedia: `Special:FilePath` resolves to exactly
    /// these paths, and the MD5 shard is how Commons partitions the thumbnail store.
    func testAddressesTheCDNDirectlyWithTheCorrectShard() {
        XCTAssertEqual(
            beer("puntigamer")?.imageURL?.absoluteString,
            "https://upload.wikimedia.org/wikipedia/commons/thumb/c/cd/Puntigamer_beer.jpg/500px-Puntigamer_beer.jpg")
    }

    /// Spaces become underscores and the MD5 is taken over the underscored name, not the original.
    func testHandlesSpacesAndNonASCIIFilenames() {
        let url = beer("augustiner-helles")?.imageURL?.absoluteString
        XCTAssertEqual(
            url,
            "https://upload.wikimedia.org/wikipedia/commons/thumb/c/c2/Augustinerbr%C3%A4u_M%C3%BCnchen_Lagerbier_Hell.jpg/500px-Augustinerbr%C3%A4u_M%C3%BCnchen_Lagerbier_Hell.jpg")
    }

    /// `.urlPathAllowed` would leave parentheses unescaped; Wikimedia's canonical form escapes them.
    func testEscapesParentheses() {
        XCTAssertEqual(
            beer("paulaner")?.imageURL?.absoluteString,
            "https://upload.wikimedia.org/wikipedia/commons/thumb/6/63/Helles_im_Glas-Helles_%28pale_beer%29.jpg/500px-Helles_im_Glas-Helles_%28pale_beer%29.jpg")
    }

    func testEveryBeerUsesAPermittedThumbnailWidthOnTheCDN() {
        // Anything outside this set is a hard HTTP 400 from Wikimedia.
        let permitted = [120, 250, 330, 500, 960, 1280]
        for beer in BeerCatalog.beers {
            guard let url = beer.imageURL else { continue }
            XCTAssertEqual(url.host(), "upload.wikimedia.org", "\(beer.id) should skip the redirect host")
            XCTAssertFalse(url.absoluteString.contains("Special:FilePath"), "\(beer.id) still redirects")
            let width = permitted.first { url.lastPathComponent.hasPrefix("\($0)px-") }
            XCTAssertNotNil(width, "\(beer.id) uses a width Wikimedia will reject: \(url.lastPathComponent)")
        }
    }

    /// The whole reason `ImageLoader` de-duplicates: 98 cards, a handful of photos.
    func testCatalogReusesFarFewerPhotosThanCards() {
        let urls = BeerCatalog.beers.compactMap(\.imageURL)
        XCTAssertEqual(urls.count, 98)
        XCTAssertLessThanOrEqual(Set(urls).count, 20,
                                 "cards share photos, so the loader must collapse duplicate requests")
    }
}
