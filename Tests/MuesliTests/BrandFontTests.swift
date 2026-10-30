import UIKit
import XCTest
@testable import Muesli

final class BrandFontTests: XCTestCase {
    func testPrimaryAccentTextContrastInBothAppearances() {
        func luminance(_ hex: Int) -> Double {
            let values = [16, 8, 0].map { shift -> Double in
                let c = Double((hex >> shift) & 255) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
        }
        for accent in MuesliAccentTheme.allCases {
            for (fill, ink) in [(accent.lightHex, 0xFFFFFF), (accent.darkHex, 0x0B0C0E)] {
                let a = luminance(fill), b = luminance(ink)
                XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 4.5, accent.rawValue)
            }
        }
    }

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
