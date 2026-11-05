import SwiftUI

/// Design tokens from DESIGN.md — Kinetic Warmth (Variant A)
/// Source of truth: DESIGN.md colors/typography/rounded/spacing
enum DesignTokens {
    enum Colors {
        static let primary = Color(hex: "#FF4E2E") // ember coral pulse
        static let onPrimary = Color.white
        static let background = Color(hex: "#FBF1E5") // warm paper
        static let surface = Color(hex: "#FFF8EF") // card ivory
        static let surface2 = Color(hex: "#FFF1E6")
        static let text = Color(hex: "#151515")
        static let textMuted = Color(hex: "#7A6C5F")
        static let accent = Color(hex: "#18A99A") // teal calm
        static let accentHover = Color(hex: "#0E6F68")
        static let accentSoft = Color(hex: "#E6F7F5")
        static let peach = Color(hex: "#F7C9A4")
        static let peachLight = Color(hex: "#FBE1C8")
        static let border = Color(hex: "#EADCCB")
        static let shadow = Color(hex: "#C9A98A")
        static let success = Color(hex: "#1A9E5C")
        static let warning = Color(hex: "#E8A317")
        static let error = Color(hex: "#E23D3D")
        // Semantic heatmap
        static let heatGreen = Color(hex: "#FF4E2E").opacity(0.95) // best — ember pulse
        static let heatYellow = Color(hex: "#F7C9A4")
        static let heatRed = Color(hex: "#EADCCB").opacity(0.6)
        static let busyGray = Color(hex: "#D9D2C7")
    }
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 12
        static let lg: CGFloat = 20
        static let pill: CGFloat = 9999
    }
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }
}

extension Color {
    init(hex: String) {
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
