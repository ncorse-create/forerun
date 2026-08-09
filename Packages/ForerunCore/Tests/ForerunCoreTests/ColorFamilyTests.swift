import Foundation
import Testing
@testable import ForerunCore

@Suite("Colour families")
struct ColorFamilyTests {

    /// The eight colours Apple Calendar offers by name, as their sRGB hexes.
    static let appleSystemColors: [(name: String, hex: String, expected: ColorFamily)] = [
        ("Red", "#FF3B30", .red),
        ("Orange", "#FF9500", .orange),
        ("Yellow", "#FFCC00", .yellow),
        ("Green", "#34C759", .green),
        ("Blue", "#007AFF", .blue),
        ("Purple", "#AF52DE", .purple),
        ("Brown", "#A2845E", .orange),
        ("Graphite", "#8E8E93", .gray)
    ]

    @Test("Every Apple Calendar system colour lands in the family a user would name it",
          arguments: appleSystemColors)
    func appleSystemColorsBucketAsExpected(sample: (name: String, hex: String, expected: ColorFamily)) {
        #expect(ColorFamily.from(hex: sample.hex) == sample.expected,
                "\(sample.name) \(sample.hex)")
    }

    static let customHexes: [(hex: String, expected: ColorFamily)] = [
        ("#C77D33", .orange),   // Forerun amber
        ("#9B5C4A", .red),      // Forerun clay — computes to a 13° hue, which is red, not orange
        ("#241F1A", .gray),     // Forerun ink — too dark to carry a hue
        ("#5A0F0F", .red),      // deep maroon — dark, but not so dark it stops being red
        ("#E91E8C", .pink),
        ("#00BCD4", .blue)
    ]

    @Test("Custom hexes bucket the way the hue table says", arguments: customHexes)
    func customHexesBucketAsExpected(sample: (hex: String, expected: ColorFamily)) {
        #expect(ColorFamily.from(hex: sample.hex) == sample.expected, "\(sample.hex)")
    }

    @Test("Anything under fifteen percent saturation is grey no matter what hue it claims")
    func desaturatedColorsAreAlwaysGray() {
        #expect(ColorFamily.from(hue: 0, saturation: 0.14, brightness: 0.9) == .gray)
        #expect(ColorFamily.from(hue: 120, saturation: 0.10, brightness: 0.9) == .gray)
        #expect(ColorFamily.from(hue: 240, saturation: 0.0, brightness: 1.0) == .gray)
        // The boundary itself is a colour, not grey.
        #expect(ColorFamily.from(hue: 0, saturation: 0.15, brightness: 0.9) == .red)
    }

    @Test("Near-black is grey even when it is technically saturated")
    func veryDarkColorsAreGray() {
        #expect(ColorFamily.from(hue: 200, saturation: 0.9, brightness: 0.05) == .gray)
        #expect(ColorFamily.from(hue: 200, saturation: 0.9, brightness: 0.14) == .gray)
        // The floor itself is still a colour.
        #expect(ColorFamily.from(hue: 200, saturation: 0.9, brightness: 0.15) == .blue)
    }

    @Test("The red bucket wraps around the top of the hue circle")
    func redWrapsAroundZero() {
        #expect(ColorFamily.from(hue: 350, saturation: 0.8, brightness: 0.8) == .red)
        #expect(ColorFamily.from(hue: 5, saturation: 0.8, brightness: 0.8) == .red)
        #expect(ColorFamily.from(hue: 344, saturation: 0.8, brightness: 0.8) == .pink)
        #expect(ColorFamily.from(hue: 16, saturation: 0.8, brightness: 0.8) == .orange)
    }

    @Test("Out-of-range hues are wrapped rather than rejected")
    func huesWrapInsteadOfFalling() {
        #expect(ColorFamily.from(hue: 370, saturation: 0.8, brightness: 0.8) == .red)
        #expect(ColorFamily.from(hue: -10, saturation: 0.8, brightness: 0.8) == .red)
    }

    @Test("Every bucket boundary is covered with no gap and no overlap")
    func bucketsTileTheWholeCircle() {
        var seen: Set<ColorFamily> = []
        for degrees in stride(from: 0.0, to: 360.0, by: 0.5) {
            seen.insert(ColorFamily.from(hue: degrees, saturation: 0.9, brightness: 0.9))
        }
        #expect(seen == Set(ColorFamily.allCases).subtracting([.gray]))
    }

    @Test("Hex parsing accepts the shapes calendar colours actually arrive in")
    func hexParsingIsForgivingInTheRightWays() {
        #expect(ColorFamily.from(hex: "#FF3B30") == .red)
        #expect(ColorFamily.from(hex: "ff3b30") == .red)
        #expect(ColorFamily.from(hex: "  #FF3B30  ") == .red)
        #expect(ColorFamily.from(hex: "#F00") == .red)
        #expect(ColorFamily.from(hex: "#FF3B30FF") == .red)   // trailing alpha dropped
        #expect(ColorFamily.from(hex: "#F18181") == .red)     // TickTick's documented sample
    }

    @Test("Garbage in gives nil out rather than a wrong colour")
    func badHexReturnsNil() {
        #expect(ColorFamily.from(hex: "") == nil)
        #expect(ColorFamily.from(hex: "#GGGGGG") == nil)
        #expect(ColorFamily.from(hex: "#FF3B3") == nil)
        #expect(ColorFamily.from(hex: "rgb(255,0,0)") == nil)
    }

    @Test("RGB to HSB matches the values the conversion is defined to produce")
    func hsbConversionIsCorrect() {
        let red = ColorFamily.hsb(red: 1, green: 0, blue: 0)
        #expect(abs(red.h - 0) < 0.001)
        #expect(abs(red.s - 1) < 0.001)
        #expect(abs(red.b - 1) < 0.001)

        let green = ColorFamily.hsb(red: 0, green: 1, blue: 0)
        #expect(abs(green.h - 120) < 0.001)

        let blue = ColorFamily.hsb(red: 0, green: 0, blue: 1)
        #expect(abs(blue.h - 240) < 0.001)

        let white = ColorFamily.hsb(red: 1, green: 1, blue: 1)
        #expect(abs(white.s - 0) < 0.001)

        let black = ColorFamily.hsb(red: 0, green: 0, blue: 0)
        #expect(abs(black.b - 0) < 0.001)
        #expect(abs(black.s - 0) < 0.001)
    }
}
