import SwiftUI
import AppKit

/// A classic Pac-Man shape whose mouth opening can be animated.
private struct PacmanShape: Shape {
    /// Opening angle in degrees (0 means fully closed).
    var mouthAngle: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2 - 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = Angle(degrees: mouthAngle)
        let end = Angle(degrees: 360 - mouthAngle)

        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.addLine(to: center)
        path.closeSubpath()
        return path
    }

    // Enable implicit animation by making `mouthAngle` animatable.
    var animatableData: Double {
        get { mouthAngle }
        set { mouthAngle = newValue }
    }
}

/// A menu‐bar icon view that snapshots the PacmanShape into an NSImage for display.
struct PacmanBarIcon: View {
    let averagePower: Double
    let peakPower: Double
    let isRecording: Bool
    @State private var currentImage = NSImage()
    private var mouthAngle: Double {
        guard isRecording else { return 30 }
        // Clamp input levels
        let clampedAvg = max(0, min(averagePower, 1))
        let clampedPeak = max(0, min(peakPower, 1))

        // Square the average level for a smoother response curve so that
        // low-level input produces smaller mouth movements while louder
        // input ramps up more quickly.  Use the peak level unmodified so
        // that sharp transients can immediately open the mouth fully.
        let curvedAvg = clampedAvg * clampedAvg

        // Choose the stronger of the two signals.  This means a sudden peak
        // can fully open the mouth even if the average power is still low.
        let effectiveLevel = max(curvedAvg, clampedPeak)

        // Map the 0‒1 effective level to an angle between 6° and 45°.
        return 6 + effectiveLevel * 39
    }
    var body: some View {
        Image(nsImage: currentImage)
            .resizable()
            .renderingMode(.template)
            .frame(width: 18, height: 18)
            .onAppear(perform: updateImage)
            .onChange(of: mouthAngle) { _, _ in updateImage() }
            .onChange(of: peakPower) { _, _ in updateImage() }
            .onChange(of: isRecording) { _, _ in updateImage() }
    }
    private func updateImage() {
        let size = CGSize(width: 36, height: 36)
        let hosting = NSHostingView(rootView:
            PacmanShape(mouthAngle: mouthAngle)
                .stroke(Color.primary, lineWidth: 3)
                .frame(width: size.width, height: size.height)
        )
        // Ensure the view has the correct bounds for offscreen rendering
        hosting.frame = CGRect(origin: .zero, size: size)
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        // Mark the raster as a 2× representation (36 × 36 px = 18 × 18 pt)
        rep.size = NSSize(width: 18, height: 18)
        let img = NSImage(size: CGSize(width: 18, height: 18))
        img.addRepresentation(rep)
        img.isTemplate = true
        currentImage = img
    }
}


