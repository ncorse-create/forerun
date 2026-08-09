import Foundation

/// The colour bucket an event's calendar falls into. This is what "auto-track everything red"
/// is written against, so it is deterministic Swift with no platform colour types involved —
/// which is also what lets it be unit-tested without a device.
public enum ColorFamily: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, pink, gray

    /// Anything under 15% saturation is grey regardless of hue, because a nearly-colourless
    /// calendar has no colour the user could have meant.
    public static let saturationFloor = 0.15

    /// Anything darker than this is grey too. A very dark colour is still technically saturated
    /// — `#241F1A` computes to a 30° hue and would otherwise bucket as *orange* — but nobody
    /// looking at it would call it anything but black, and "auto-track orange" must not
    /// silently pick it up. A deep maroon (`#5A0F0F`, brightness 0.35) stays red.
    public static let brightnessFloor = 0.15

    /// Buckets by hue in degrees.
    public static func from(hue degrees: Double, saturation: Double, brightness: Double) -> ColorFamily {
        guard saturation >= saturationFloor, brightness >= brightnessFloor else { return .gray }
        var h = degrees.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        switch h {
        case 345..<360, 0..<16: return .red
        case 16..<46: return .orange
        case 46..<66: return .yellow
        case 66..<166: return .green
        case 166..<256: return .blue
        case 256..<291: return .purple
        default: return .pink
        }
    }

    /// sRGB components in 0...1.
    public static func from(red: Double, green: Double, blue: Double) -> ColorFamily {
        let (h, s, b) = hsb(red: red, green: green, blue: blue)
        return from(hue: h, saturation: s, brightness: b)
    }

    /// `#RRGGBB` or `RRGGBB`, with or without a leading `#`, case-insensitive. Also accepts
    /// `#AARRGGBB` and `#RRGGBBAA` by ignoring the alpha byte, because calendar colours have
    /// arrived in both shapes.
    public static func from(hex: String) -> ColorFamily? {
        guard let rgb = rgbComponents(hex: hex) else { return nil }
        return from(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    public static func rgbComponents(hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        switch s.count {
        case 6: break
        case 8:
            // Ambiguous. TickTick and Apple both publish #RRGGBB; the 8-digit forms seen in the
            // wild have been #RRGGBBAA far more often than #AARRGGBB, so drop the trailing pair.
            s = String(s.prefix(6))
        case 3:
            s = s.map { "\($0)\($0)" }.joined()
        default:
            return nil
        }
        guard let value = UInt32(s, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255)
    }

    /// Pure-Swift RGB→HSB. Hue in degrees, saturation and brightness in 0...1.
    public static func hsb(red: Double, green: Double, blue: Double) -> (h: Double, s: Double, b: Double) {
        let maxV = max(red, green, blue)
        let minV = min(red, green, blue)
        let delta = maxV - minV
        var hue: Double = 0
        if delta > 0 {
            if maxV == red {
                hue = 60 * (((green - blue) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxV == green {
                hue = 60 * (((blue - red) / delta) + 2)
            } else {
                hue = 60 * (((red - green) / delta) + 4)
            }
        }
        if hue < 0 { hue += 360 }
        let saturation = maxV == 0 ? 0 : delta / maxV
        return (hue, saturation, maxV)
    }

    public var displayName: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}
