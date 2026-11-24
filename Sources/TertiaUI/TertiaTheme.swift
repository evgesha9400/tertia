import SwiftUI

public struct TertiaPalette: Sendable {
    public let canvas: Color
    public let card: Color
    public let pillSurface: Color
    public let pillSelected: Color
    public let pillSelectedText: Color
    public let border: Color
    public let ink: Color
    public let muted: Color
    public let faint: Color
    public let openStatus: Color
    public let warningStatus: Color

    public static let dark = TertiaPalette(
        canvas: Color(red: 0x0A / 255.0, green: 0x0A / 255.0, blue: 0x0A / 255.0),
        card: Color(red: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x14 / 255.0),
        pillSurface: Color.white.opacity(0.06),
        pillSelected: Color(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF5 / 255.0),
        pillSelectedText: Color(red: 0x11 / 255.0, green: 0x11 / 255.0, blue: 0x11 / 255.0),
        border: Color(red: 0x26 / 255.0, green: 0x26 / 255.0, blue: 0x26 / 255.0),
        ink: Color(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF5 / 255.0),
        muted: Color(red: 0xA3 / 255.0, green: 0xA3 / 255.0, blue: 0xA3 / 255.0),
        faint: Color(red: 0x73 / 255.0, green: 0x73 / 255.0, blue: 0x73 / 255.0),
        openStatus: Color(red: 0x34 / 255.0, green: 0xD3 / 255.0, blue: 0x99 / 255.0),
        warningStatus: Color(red: 0xFB / 255.0, green: 0xBF / 255.0, blue: 0x24 / 255.0)
    )

    public static let light = TertiaPalette(
        canvas: Color(red: 0xFA / 255.0, green: 0xFA / 255.0, blue: 0xF8 / 255.0),
        card: Color.white,
        pillSurface: Color(red: 0xF2 / 255.0, green: 0xF2 / 255.0, blue: 0xEE / 255.0),
        pillSelected: Color(red: 0x11 / 255.0, green: 0x11 / 255.0, blue: 0x11 / 255.0),
        pillSelectedText: Color.white,
        border: Color(red: 0xE5 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0),
        ink: Color(red: 0x11 / 255.0, green: 0x11 / 255.0, blue: 0x11 / 255.0),
        muted: Color(red: 0x52 / 255.0, green: 0x52 / 255.0, blue: 0x52 / 255.0),
        faint: Color(red: 0x73 / 255.0, green: 0x73 / 255.0, blue: 0x73 / 255.0),
        openStatus: Color(red: 0x06 / 255.0, green: 0x5F / 255.0, blue: 0x46 / 255.0),
        warningStatus: Color(red: 0x92 / 255.0, green: 0x40 / 255.0, blue: 0x0E / 255.0)
    )

    public static func resolve(_ scheme: ColorScheme) -> TertiaPalette {
        scheme == .dark ? .dark : .light
    }
}

public enum TertiaMetrics {
    public static let containerRadius: CGFloat = 14
    public static let cardRadius: CGFloat = 11
    public static let pillRadius: CGFloat = 8
}

public extension View {
    func tertiaSurface(fill: Color, border: Color = .clear, radius: CGFloat) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(border, lineWidth: 1))
    }
}
