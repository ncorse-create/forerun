import ForerunCore
import SwiftUI

/// Warm editorial, not productivity-app cold. Every colour and every type ramp in the app comes
/// from here — there are no ad-hoc `Color(red:green:blue:)` calls in view code.
public enum Palette {
    public static let paper = Color(hex: 0xFBF7F0)
    public static let ink = Color(hex: 0x241F1A)
    public static let amber = Color(hex: 0xC77D33)
    public static let muted = Color(hex: 0x8A8078)
    public static let hairline = Color(hex: 0xE8E0D5)
    public static let clay = Color(hex: 0x9B5C4A)
    public static let graphite = Color(hex: 0x5A5550)

    /// A slightly deeper paper for the one surface that needs to sit behind another.
    public static let paperSunk = Color(hex: 0xF4EEE4)

    public static func forAudience(_ audience: Audience) -> Color {
        switch audience.colorToken {
        case "amber": amber
        case "clay": clay
        default: graphite
        }
    }

    /// Calendar colour swatches on the tracking-rules screen. These are the *family* colours,
    /// not the calendar's own colour, so the swatch matches what the rule actually means.
    public static func forColorFamily(_ family: ColorFamily) -> Color {
        switch family {
        case .red: Color(hex: 0xC0392B)
        case .orange: Color(hex: 0xC77D33)
        case .yellow: Color(hex: 0xC9A227)
        case .green: Color(hex: 0x4F7A4A)
        case .blue: Color(hex: 0x3C6E8F)
        case .purple: Color(hex: 0x6B5B8E)
        case .pink: Color(hex: 0xB05A7A)
        case .gray: Color(hex: 0x8A8078)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// One weight step between levels, no more. New York for titles and event names, SF Pro Text
/// for everything that has to be read quickly.
public enum TypeRamp {
    /// Screen titles. Serif, because this app is closer to a notebook than a dashboard.
    public static func screenTitle() -> Font {
        .system(.largeTitle, design: .serif, weight: .regular)
    }

    /// Event names wherever they appear as the subject of the screen.
    public static func eventTitle() -> Font {
        .system(.title2, design: .serif, weight: .regular)
    }

    public static func eventTitleCompact() -> Font {
        .system(.headline, design: .serif, weight: .regular)
    }

    public static func body() -> Font { .system(.body) }
    public static func bodyEmphasis() -> Font { .system(.body, weight: .medium) }
    public static func caption() -> Font { .system(.subheadline) }
    public static func micro() -> Font { .system(.caption, weight: .medium) }
}

public enum Metrics {
    /// 20pt horizontal margins, everywhere, with no exceptions worth making.
    public static let hMargin: CGFloat = 20
    public static let rowSpacing: CGFloat = 14
    public static let sectionSpacing: CGFloat = 28
    public static let railWidth: CGFloat = 1
    public static let dotSize: CGFloat = 9
}

/// A hairline rule. Thin enough to be a rule and not a border.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
    }
}

/// The one-sentence empty state. A sentence, not an illustration — that is the whole component.
struct EmptyStateSentence: View {
    let sentence: String

    var body: some View {
        Text(sentence)
            .font(TypeRamp.body())
            .foregroundStyle(Palette.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.hMargin)
            .padding(.vertical, 44)
            .accessibilityLabel(sentence)
    }
}

/// Screen background. Painted explicitly so the app never borrows a system colour.
struct PaperBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Palette.paper.ignoresSafeArea())
            .tint(Palette.amber)
    }
}

extension View {
    func paperBackground() -> some View { modifier(PaperBackground()) }
}
