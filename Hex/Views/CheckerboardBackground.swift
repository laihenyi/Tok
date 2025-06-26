import SwiftUI

/// A lightweight checkerboard background similar to Keynote/Karaoke overlay.
/// Looks best when used behind brightly coloured text on dark mode.
struct CheckerboardBackground: View {
    /// Base colour of dark squares (default: #111)
    var darkColor: Color = Color(red: 0.08, green: 0.08, blue: 0.08)
    /// Base colour of light squares (default: #1d1d1d)
    var lightColor: Color = Color(red: 0.13, green: 0.13, blue: 0.13)
    /// Size of each checker square in points.
    var squareSize: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let rows = Int(size.height / squareSize) + 2
                let cols = Int(size.width / squareSize) + 2
                for row in 0..<rows {
                    for col in 0..<cols where (row + col).isMultiple(of: 2) {
                        let rect = CGRect(x: CGFloat(col) * squareSize,
                                          y: CGFloat(row) * squareSize,
                                          width: squareSize,
                                          height: squareSize)
                        context.fill(Path(rect), with: .color(darkColor))
                    }
                }
            }
            .background(lightColor)
        }
        .ignoresSafeArea()
    }
} 