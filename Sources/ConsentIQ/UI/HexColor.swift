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

    var color: Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

extension Color {
    static func consentPrimary(_ hex: String?) -> Color {
        (HexColor.parse(hex) ?? HexColor.defaultPrimary).color
    }
}
