import SwiftUI
import Foundation

struct CustomThemeOption: Identifiable, Codable, Equatable {
    var id = UUID()
    let textColorHex: String
    let backgroundColorHex: String

    var textColor: Color {
        Color(hex: textColorHex) ?? .black
    }

    var backgroundColor: Color {
        Color(hex: backgroundColorHex) ?? .white
    }

    enum CodingKeys: String, CodingKey {
        case textColorHex
        case backgroundColorHex
    }
}
