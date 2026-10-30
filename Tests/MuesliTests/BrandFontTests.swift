import UIKit
import XCTest
@testable import Muesli

final class BrandFontTests: XCTestCase {
    @MainActor
    func testBundledFacesAreRegisteredWithoutInstalledMacFonts() throws {
        for face in ["Regular", "Medium", "SemiBold", "Bold", "Italic", "BoldItalic"] {
            let name = "NunitoSans-\(face)"
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "ttf"), name)
            let font = try XCTUnwrap(UIFont(name: name, size: 17), name)
            XCTAssertEqual(font.fontName, name)
        }
    }
}
