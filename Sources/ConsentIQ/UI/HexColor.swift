import SwiftUI

struct HexColor: Equatable {
    static let defaultPrimary = HexColor(red: 0xF9, green: 0x73, blue: 0x16)

    let red: UInt8
    let green: UInt8
    let blue: UInt8

    static func parse(_ value: String?) -> HexColor? {
        guard let value else { return nil }
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6, let bits = UInt32(hex, radix: 16) else { return nil }
        return HexColor(red: UInt8((bits >> 16) & 0xFF), green: UInt8((bits >> 8) & 0xFF), blue: UInt8(bits & 0xFF))
    }

    // The banner's own colors must be #rgb or #rrggbb, matching the server and the web banner.
    static func parseLiteral(_ value: String?) -> HexColor? {
        guard let value, value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") else { return nil }
        return parse(value)
    }

    var brightness: Int {
        (Int(red) * 299 + Int(green) * 587 + Int(blue) * 114) / 1000
    }

    // YIQ brightness, the one light or dark rule the server and the web banner share.
    var isDark: Bool { brightness < 150 }

    var color: Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

struct SheetPalette: Equatable {
    let background: HexColor
    let text: HexColor

    var isDark: Bool { background.isDark }

    init?(banner: BannerConfig?) {
        guard let background = HexColor.parseLiteral(banner?.bannerBgColor) else { return nil }
        self.background = background
        text = HexColor.parseLiteral(banner?.bannerTextColor)
            ?? (background.isDark ? HexColor(red: 0xFF, green: 0xFF, blue: 0xFF) : HexColor(red: 0, green: 0, blue: 0))
    }
}

extension Color {
    static func consentPrimary(_ hex: String?) -> Color {
        (HexColor.parse(hex) ?? HexColor.defaultPrimary).color
    }
}
