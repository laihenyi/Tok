import SwiftUI
import Foundation

extension Color {
    /// Initialize a Color from a hex string
    /// Supports formats: "#RRGGBB", "RRGGBB", "#RGB", "RGB"
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
    
    /// Convert a Color to a hex string
    func toHex() -> String {
        guard let components = cgColor?.components, components.count >= 3 else {
            return "#000000"
        }
        
        let r = Float(components[0])
        let g = Float(components[1])
        let b = Float(components[2])
        
        return String(format: "#%02lX%02lX%02lX",
                     lroundf(r * 255),
                     lroundf(g * 255),
                     lroundf(b * 255))
    }
    
    /// Get a contrasting text color (black or white) for this background color
    var contrastingTextColor: Color {
        guard let components = cgColor?.components, components.count >= 3 else {
            return .white
        }
        
        let r = components[0]
        let g = components[1]
        let b = components[2]
        
        // Calculate luminance using the relative luminance formula
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        
        // Return black for light backgrounds, white for dark backgrounds
        return luminance > 0.5 ? .black : .white
    }
}
