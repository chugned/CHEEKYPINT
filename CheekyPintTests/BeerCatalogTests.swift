import XCTest
@testable import CheekyPint

/// The catalog no longer carries imagery. These pin the shape that survived so the 98 entries
/// and the diary-note behaviour cannot regress while the image layer is removed.
final class BeerCatalogTests: XCTestCase {

    func testCatalogStillHasEveryBeer() {
        XCTAssertEqual(BeerCatalog.beers.count, 98)
    }

    func testEveryBeerHasDisplayableText() {
        for beer in BeerCatalog.beers {
            XCTAssertFalse(beer.name.isEmpty, "\(beer.id) has no name")
            XCTAssertFalse(beer.country.isEmpty, "\(beer.id) has no country")
            XCTAssertFalse(beer.style.isEmpty, "\(beer.id) has no style")
        }
    }

    func testBeerIDsAreUnique() {
        XCTAssertEqual(Set(BeerCatalog.beers.map(\.id)).count, BeerCatalog.beers.count)
    }

    func testDiaryNoteIncludesTheBeerName() {
        let beer = BeerCatalog.beers[0]
        let note = BeerCatalog.diaryNote(for: beer, userNote: "")
        XCTAssertTrue(note.contains(beer.name), "expected \(beer.name) in \(note)")
    }
}
