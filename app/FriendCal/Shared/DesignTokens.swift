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
    /// Tracking (wordmark -0.01em, display -0.02em) arrives with TextStyle (T12).
    public enum Typography {
        public static let wordmark = custom(.cabinetExtrabold, 28, .title)
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
