import ForerunCore
import SwiftUI

/// Warm editorial, not productivity-app cold. Every colour and every type ramp in the app comes
/// from here — there are no ad-hoc `Color(red:green:blue:)` calls in view code.
///
/// Every token is **dynamic**: one `UIColor` that resolves light or dark at draw time, with the
/// SwiftUI `Color` derived from it. Two representations of one value rather than two values, so
/// the UIKit appearance proxy in `NavigationBarAppearance` can never drift from the SwiftUI views.
public enum Palette {
    /// A light/dark pair as a single resolving colour.
    private static func ui(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    // The dark column is the design system's own table. Dark mode carries elevation with surface
    // lift rather than shadow, so the three paper surfaces are deliberately three distinct steps.
    static let uiPaper = ui(0xFBF7F0, 0x191512)
    static let uiPaperSunk = ui(0xF4EEE4, 0x141110)
    static let uiPaperLift = ui(0xFFFDFA, 0x221D19)
    static let uiInk = ui(0x241F1A, 0xF5F0E8)
    static let uiAmber = ui(0xC77D33, 0xDFA05A)
    static let uiClay = ui(0x9B5C4A, 0xC4826D)
    static let uiGraphite = ui(0x5A5550, 0xA8A099)
    static let uiMuted = ui(0x8A8078, 0x948C84)
    static let uiHairline = ui(0xE8E0D5, 0x332C25)

    public static let paper = Color(uiPaper)
    public static let ink = Color(uiInk)
    public static let amber = Color(uiAmber)
    public static let muted = Color(uiMuted)
    public static let hairline = Color(uiHairline)
    public static let clay = Color(uiClay)
    public static let graphite = Color(uiGraphite)

    /// The field the containers sit on. Deeper than paper in light; *darker* than the cards in
    /// dark, which is what makes an unshadowed card read as lifted.
    public static let paperSunk = Color(uiPaperSunk)

    /// The one surface above paper — the hero card and today's day tile, and nothing else.
    public static let paperLift = Color(uiPaperLift)

    // Rules and fills that only ever appear *inside* a container. The dark values are derived
    // rather than given: each keeps the same relationship to its neighbour that it has in light.
    /// A rule inside a card, one step softer than `hairline`.
    public static let hairlineSoft = Color(ui(0xEFE7DB, 0x2A241E))
    /// The tinted band behind the rung dots.
    public static let footerTint = Color(ui(0xFDFAF5, 0x1E1916))
    /// A spent rung, and the outline on a secondary button.
    public static let dotSpent = Color(ui(0xE3D9CB, 0x4A403A))
    /// Adjacent-month dates in the month grid.
    public static let dateOutside = Color(ui(0xC6BCAE, 0x5C554E))
    /// Disclosure chevrons.
    public static let chevron = Color(ui(0xD6CCBE, 0x4A433C))

    public static func forAudience(_ audience: Audience) -> Color {
        switch audience.colorToken {
        case "amber": amber
        case "clay": clay
        default: graphite
        }
    }

    /// Calendar colour swatches. These are the *family* colours, not the calendar's own colour,
    /// so the swatch matches what the rule actually means.
    ///
    /// Deliberately **not** the audience colours: both appear on the same event card and they mean
    /// different things. The dark column is lightened from the light one — these are drawn at 9pt
    /// and the light values disappear against a dark card.
    public static func forColorFamily(_ family: ColorFamily) -> Color {
        switch family {
        case .red: Color(ui(0xC0392B, 0xD9614F))
        case .orange: Color(ui(0xC77D33, 0xDFA05A))
        case .yellow: Color(ui(0xC9A227, 0xDCC05A))
        case .green: Color(ui(0x4F7A4A, 0x7BA675))
        case .blue: Color(ui(0x3C6E8F, 0x6D9DBC))
        case .purple: Color(ui(0x6B5B8E, 0x9B8ABD))
        case .pink: Color(ui(0xB05A7A, 0xD08AA6))
        case .gray: Color(ui(0x8A8078, 0x948C84))
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

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
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

    /// Monospaced, for the one place raw diagnostic text is shown.
    public static func diagnostic() -> Font { .system(.caption, design: .monospaced) }

    /// Monospaced at body size, for the shareable plain-text plan — its alignment is the point.
    public static func monoBody() -> Font { .system(.body, design: .monospaced) }

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

    // Container radii. Size carries meaning here: the further a container is from the field,
    // the rounder it is.
    public static let rHero: CGFloat = 20
    public static let rContainer: CGFloat = 18
    public static let rCard: CGFloat = 16
    public static let rTile: CGFloat = 13
    public static let rDayTile: CGFloat = 12
    public static let rPill: CGFloat = 22

    /// Minimum hit target. The day tiles are the one place this has to be asserted.
    public static let minTarget: CGFloat = 44
}

// MARK: - Containers

/// How far a container sits off the field.
///
/// In light this is shadow. In dark it cannot be — a shadow on a dark field is invisible — so the
/// same case resolves to surface lift plus a hairline top edge instead. One vocabulary, two
/// renderings, so no call site has to know which mode it is in.
enum Elevation {
    case flat
    case sm
    case md
    case lift
    case tracked
    case hero

    /// CSS blur radius halves to reach a SwiftUI shadow radius.
    var shadows: [(color: Double, radius: CGFloat, y: CGFloat)] {
        switch self {
        case .flat: []
        case .sm: [(0.05, 1.5, 1)]
        case .md: [(0.06, 3, 2), (0.04, 1, 1)]
        case .lift: [(0.07, 6, 4), (0.04, 1, 1)]
        case .tracked: [(0.08, 7, 5), (0.04, 1.5, 1)]
        case .hero: [(0.10, 13, 10), (0.05, 3, 2)]
        }
    }
}

/// A container: a surface, a radius, and an elevation. Never nested inside another container —
/// grouping *within* a card is done with hairlines and the footer tint, never a second card.
struct ContainerStyle: ViewModifier {
    let surface: Color
    let radius: CGFloat
    let elevation: Elevation
    var stroke: Color?

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background {
            // The shadow goes on the shape, not on the content. Applying it to the composited
            // view would put a drop shadow behind every glyph of every label in the card.
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape
                .fill(surface)
                .modifier(ShadowStack(shadows: scheme == .dark ? [] : elevation.shadows))
                .overlay {
                    if let stroke {
                        shape.strokeBorder(stroke, lineWidth: 1)
                    } else if scheme == .dark, elevation != .flat {
                        // Dark's substitute for a shadow: a lit top edge, brightest where the
                        // light would fall. A full border would read as an outline, not a lift.
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [Palette.hairline, Palette.hairline.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                    }
                }
        }
    }
}

/// Applies a list of shadows in order. A `ForEach` cannot stack modifiers, so this recurses.
private struct ShadowStack: ViewModifier {
    let shadows: [(color: Double, radius: CGFloat, y: CGFloat)]

    func body(content: Content) -> some View {
        shadows.reduce(AnyView(content)) { view, shadow in
            AnyView(
                view.shadow(
                    color: Palette.shadowInk.opacity(shadow.color),
                    radius: shadow.radius,
                    x: 0,
                    y: shadow.y
                )
            )
        }
    }
}

extension Palette {
    /// Every shadow in the app is warm ink. A grey or black shadow reads as a productivity
    /// dashboard immediately, which is the one thing this design is not.
    static let shadowInk = Color(hex: 0x241F1A)
}

extension View {
    /// The standard container. `surface` defaults to paper because that is what a card is.
    func container(
        surface: Color = Palette.paper,
        radius: CGFloat = Metrics.rCard,
        elevation: Elevation = .md,
        stroke: Color? = nil
    ) -> some View {
        modifier(ContainerStyle(surface: surface, radius: radius, elevation: elevation, stroke: stroke))
    }
}

/// A section label — `THIS WEEK`, `ALSO TODAY`, `THE MONTH`. Optionally with a right-hand
/// counterpart on the same baseline.
struct EyebrowRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(.caption2, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            trailing
                .font(.system(.caption2, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

extension EyebrowRow where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// The audience dot. Always accompanied by its word at the call site — colour alone has to
/// survive greyscale and colour blindness, so the word is not optional.
struct AudienceDot: View {
    let audience: Audience
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(Palette.forAudience(audience))
            .frame(width: size, height: size)
    }
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

/// The field the containers sit on. Deeper than paper, so an unshadowed card still reads as
/// lifted — which is the only way elevation can work in dark mode.
struct FieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Palette.paperSunk.ignoresSafeArea())
            .tint(Palette.amber)
    }
}

extension View {
    func paperBackground() -> some View { modifier(PaperBackground()) }

    /// For the three tab screens, which are container layouts. Plan and the sheets stay on paper.
    func fieldBackground() -> some View { modifier(FieldBackground()) }
}

/// Serif navigation titles.
///
/// `navigationTitle` renders SF Pro and there is no SwiftUI modifier for its font, so the design
/// system's first type rule — New York for screen titles — needs the UIKit appearance proxy.
/// Applied once, at launch, rather than per screen.
@MainActor
enum NavigationBarAppearance {
    static func apply() {
        // The dynamic UIColors themselves, not `UIColor(Color(...))` round-trips — the proxy
        // holds these for the life of the process and has to resolve per trait change.
        let ink = Palette.uiInk
        let paper = Palette.uiPaper

        let large = UIFont.preferredFont(forTextStyle: .largeTitle)
        let inline = UIFont.preferredFont(forTextStyle: .headline)
        let largeSerif = serif(large)
        let inlineSerif = serif(inline)

        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = paper
        appearance.shadowColor = .clear
        appearance.largeTitleTextAttributes = [.font: largeSerif, .foregroundColor: ink]
        appearance.titleTextAttributes = [.font: inlineSerif, .foregroundColor: ink]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().tintColor = Palette.uiAmber
    }

    /// Falls back to the original font when the serif design is unavailable, rather than
    /// force-unwrapping a descriptor.
    private static func serif(_ font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withDesign(.serif) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}
