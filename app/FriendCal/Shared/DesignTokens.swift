import SwiftUI

/// Design tokens from DESIGN.md — Kinetic Warmth (Variant A)
/// Source of truth: DESIGN.md colors/typography/rounded/spacing
public enum DesignTokens {
    public enum Colors {
        public static let primary = Color(hex: "#FF4E2E") // ember coral pulse
        public static let onPrimary = Color.white
        public static let background = Color(hex: "#FBF1E5") // warm paper
        public static let surface = Color(hex: "#FFF8EF") // card ivory
        public static let surface2 = Color(hex: "#FFF1E6")
        public static let text = Color(hex: "#151515")
        public static let textMuted = Color(hex: "#7A6C5F")
        public static let accent = Color(hex: "#18A99A") // teal calm
        public static let accentHover = Color(hex: "#0E6F68")
        public static let accentSoft = Color(hex: "#E6F7F5")
        public static let peach = Color(hex: "#F7C9A4")
        public static let peachLight = Color(hex: "#FBE1C8")
        /// Third heatmap ramp step, between peach and primary (coverage [0.5, 0.75)).
        public static let heatOrange = Color(hex: "#FF6A32")
        public static let border = Color(hex: "#EADCCB")
        public static let shadow = Color(hex: "#C9A98A")
        public static let success = Color(hex: "#1A9E5C")
        public static let warning = Color(hex: "#E8A317")
        public static let error = Color(hex: "#E23D3D")
        // Semantic heatmap
        public static let heatGreen = Color(hex: "#FF4E2E").opacity(0.95) // best — ember pulse
        public static let heatYellow = Color(hex: "#F7C9A4")
        public static let heatRed = Color(hex: "#EADCCB").opacity(0.6)
        public static let busyGray = Color(hex: "#D9D2C7")
    }
    public enum Radius {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 20
        public static let pill: CGFloat = 9999
    }
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
    }
    /// D27 type scale. Every token scales with Dynamic Type via `relativeTo:`.
    /// SwiftUI `Font` only: Shared/ also builds for macOS, so no UIFont here.
    /// Tracking lives in `TextStyle`; Home components apply tokens via `.textStyle(_:)`.
    public enum Typography {
        public static let wordmark = custom(.cabinetExtrabold, 28, .title)
        /// Invite headline (issue #5 R9). Views cap it at xxxLarge inside the fixed-aspect card (design 6.2A).
        public static let hero = custom(.cabinetExtrabold, 34, .largeTitle)
        public static let display = custom(.cabinetExtrabold, 26, .title2)
        public static let title = custom(.sourceSansSemibold, 17, .headline)
        public static let button = custom(.sourceSansSemibold, 17, .headline)
        public static let body = custom(.sourceSansRegular, 15, .body)
        public static let label = custom(.sourceSansSemibold, 13, .footnote)
        public static let caption = custom(.sourceSansRegular, 12, .caption)
        public static let mono = custom(.jetBrainsMonoMedium, 12, .caption)
        public static let badge = custom(.sourceSansSemibold, 10, .caption2)

        private static func custom(_ name: FontName, _ size: CGFloat, _ style: Font.TextStyle) -> Font {
            .custom(name.rawValue, size: size, relativeTo: style)
        }
    }
}

extension DesignTokens {
    /// A Typography font plus its tracking in points (em x size), since `Font` can't carry tracking.
    public struct TextStyle {
        public let font: Font
        public let tracking: CGFloat

        public static let wordmark = TextStyle(font: Typography.wordmark, tracking: -0.28) // -0.01em x 28
        public static let hero = TextStyle(font: Typography.hero, tracking: -0.68)         // -0.02em x 34
        public static let display = TextStyle(font: Typography.display, tracking: -0.52)   // -0.02em x 26
        public static let title = TextStyle(font: Typography.title, tracking: 0)
        public static let button = TextStyle(font: Typography.button, tracking: 0)
        public static let body = TextStyle(font: Typography.body, tracking: 0)
        public static let label = TextStyle(font: Typography.label, tracking: 0)
        public static let caption = TextStyle(font: Typography.caption, tracking: 0)
        public static let mono = TextStyle(font: Typography.mono, tracking: 0)
        public static let badge = TextStyle(font: Typography.badge, tracking: 0)
    }

    /// Fixed earth palette for initials faces (D28); never coral.
    public enum FacePalette {
        public static let colors: [Color] = [
            Color(hex: "#A9BFA0"), // sage
            Color(hex: "#E3B76B"), // ochre
            Color(hex: "#9DB0C2"), // slate
            Color(hex: "#D9A08A"), // clay
            Color(hex: "#E2CFAF"), // sand
            Color(hex: "#B7BE8E"), // moss
        ]
        /// FNV-1a 32-bit over the UUID string's UTF-8, mod 6. `hashValue` is reseeded per process
        /// (SE-0206), so it would recolor every face on each launch.
        public static func index(for id: UUID) -> Int {
            var hash: UInt32 = 0x811C_9DC5
            for byte in id.uuidString.utf8 {
                hash ^= UInt32(byte)
                hash = hash &* 0x0100_0193
            }
            return Int(hash % UInt32(colors.count))
        }

        public static func color(for id: UUID) -> Color { colors[index(for: id)] }
    }
}

extension View {
    /// Applies a type token with its tracking.
    public func textStyle(_ style: DesignTokens.TextStyle) -> some View {
        font(style.font).tracking(style.tracking)
    }
}

/// The single list of bundled PostScript names (no fallback fonts).
/// Typography and the DEBUG launch assertion read this. The file names in
/// project.yml (UIAppFonts, font preBuildScript) and scripts/fetch-fonts.sh
/// necessarily repeat them.
public enum FontName: String, CaseIterable {
    case cabinetExtrabold = "CabinetGrotesk-Extrabold"
    case cabinetBold = "CabinetGrotesk-Bold"
    case sourceSansRegular = "SourceSans3-Regular"
    case sourceSansSemibold = "SourceSans3-Semibold"
    case sourceSansBold = "SourceSans3-Bold"
    case jetBrainsMonoRegular = "JetBrainsMono-Regular"
    case jetBrainsMonoMedium = "JetBrainsMono-Medium"
}

extension Color {
    public init(hex: String) {
        let h = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        var int: UInt64 = 0; Scanner(string: h).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch h.count {
        case 6: (a,r,g,b) = (255, int>>16, int>>8 & 0xFF, int & 0xFF)
        case 8: (a,r,g,b) = (int>>24, int>>16 & 0xFF, int>>8 & 0xFF, int & 0xFF)
        default: (a,r,g,b) = (255,0,0,0)
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255, opacity: Double(a)/255)
    }
}
