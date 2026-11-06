import SwiftUI

/// SwiftUI counterpart to `NotchView.notchPath(in:cornerRadius:)`.
/// The short top shoulders flare outward into the display edge while the
/// lower corners retain the radius appropriate to each expanded activity.
struct NotchContourShape: Shape {
    var bottomCornerRadius: CGFloat = 18
    var topShoulder: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let shoulder = min(topShoulder, min(rect.width / 2, rect.height / 2))
        let radius = min(bottomCornerRadius, min(rect.width / 2, rect.height / 2))
        var path = Path()

        path.move(to: CGPoint(x: 0, y: 0))
        path.addCurve(
            to: CGPoint(x: shoulder, y: shoulder),
            control1: CGPoint(x: shoulder * 0.55, y: 0),
            control2: CGPoint(x: shoulder, y: shoulder * 0.55)
        )
        path.addLine(to: CGPoint(x: shoulder, y: rect.maxY - radius))
        path.addCurve(
            to: CGPoint(x: shoulder + radius, y: rect.maxY),
            control1: CGPoint(x: shoulder, y: rect.maxY - radius * 0.42),
            control2: CGPoint(x: shoulder + radius * 0.42, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - shoulder - radius, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - radius),
            control1: CGPoint(x: rect.maxX - shoulder - radius * 0.42, y: rect.maxY),
            control2: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - radius * 0.42)
        )
        path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: shoulder))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: 0),
            control1: CGPoint(x: rect.maxX - shoulder, y: shoulder * 0.45),
            control2: CGPoint(x: rect.maxX - shoulder * 0.45, y: 0)
        )
        path.closeSubpath()
        return path
    }
}
