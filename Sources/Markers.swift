import SwiftUI
import MapLibre

/// Hand-drawn map furniture: category pins, the player arrow and the compass rose.
/// All original artwork in the app's parchment-and-ink palette.
enum Markers {
    private static var cache: [String: UIImage] = [:]

    /// Teardrop pin with a white glyph. The canvas is twice the pin's height with the tip at its centre,
    /// because MapLibre centres annotation images on the coordinate.
    /// `faded`: an undiscovered place, drawn pale until you've been there.
    static func pin(_ kind: Waypoint.Kind, faded: Bool = false) -> UIImage {
        let key = kind.rawValue + (faded ? "-faded" : "")
        if let hit = cache[key] { return hit }
        let w: CGFloat = 34, h: CGFloat = 44
        let image = UIGraphicsImageRenderer(size: CGSize(width: w, height: h * 2)).image { _ in
            let r = w / 2 - 1.5, c = CGPoint(x: w / 2, y: r + 1.5), tip = CGPoint(x: w / 2, y: h)
            let a = acos(r / (tip.y - c.y)) // angle from straight down to where the sides touch the circle
            let path = UIBezierPath()
            path.move(to: tip)
            path.addArc(withCenter: c, radius: r, startAngle: .pi / 2 - a, endAngle: .pi / 2 + a, clockwise: false)
            path.close()
            UIColor(kind.color).withAlphaComponent(faded ? 0.45 : 1).setFill()
            path.fill()
            UIColor(Color.ink).setStroke()
            path.lineWidth = 1.5
            path.stroke()
            let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
            if let glyph = UIImage(systemName: kind.symbol, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                glyph.draw(at: CGPoint(x: c.x - glyph.size.width / 2, y: c.y - glyph.size.height / 2))
            }
        }
        cache[key] = image
        return image
    }

    /// Arrowhead with a notched tail, pointing up.
    static func arrow(in rect: CGRect) -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.28))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.close()
        return p
    }
}

/// The user's position on the map: a white arrowhead turned to their heading (or course while moving).
final class PlayerArrowView: MLNUserLocationAnnotationView {
    private let shape = CAShapeLayer()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        shape.path = Markers.arrow(in: bounds.insetBy(dx: 5, dy: 3)).cgPath
        shape.fillColor = UIColor.white.cgColor
        shape.strokeColor = UIColor(Color.ink).cgColor
        shape.lineWidth = 2
        shape.lineJoin = .round
        shape.shadowOpacity = 0.4
        shape.shadowRadius = 2
        shape.shadowOffset = .zero
        layer.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("not used from storyboards") }

    override func update() {
        guard let degrees = PlayerArrowView.heading(userLocation) else { return }
        let onScreen = (degrees - (mapView?.direction ?? 0)) * .pi / 180
        shape.setAffineTransform(CGAffineTransform(rotationAngle: onScreen))
    }

    /// Compass heading when the phone has one, else direction of travel; nil when neither is known.
    static func heading(_ u: MLNUserLocation?) -> Double? {
        if let h = u?.heading?.trueHeading, h >= 0 { return h }
        if let c = u?.location?.course, c >= 0 { return c }
        return nil
    }
}

/// Engraved compass rose that turns with the map. Tap to face north.
struct CompassRose: View {
    var direction: Double
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2), r = size.width / 2 - 2
                let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(ring, with: .color(.parchment))
                ctx.stroke(ring, with: .color(.ink), lineWidth: 2)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r * 0.8, y: c.y - r * 0.8, width: r * 1.6, height: r * 1.6)),
                           with: .color(.ink), lineWidth: 0.8)
                for deg in stride(from: 0, to: 360, by: 15) { // tick marks, longer at the quarters
                    let a = Double(deg) * .pi / 180, inner = deg % 90 == 0 ? 0.62 : 0.8
                    var t = Path()
                    t.move(to: point(c, r * inner, a))
                    t.addLine(to: point(c, r * 0.95, a))
                    ctx.stroke(t, with: .color(.ink), lineWidth: deg % 90 == 0 ? 1.2 : 0.6)
                }
                // Star points: each split into a dark and a light half, like an engraving.
                for (i, len) in [1.0, 0.55, 1.0, 0.55, 1.0, 0.55, 1.0, 0.55].enumerated() {
                    let a = Double(i) * .pi / 4, tip = point(c, r * 0.9 * len, a)
                    for side in [-1.0, 1.0] {
                        var half = Path()
                        half.move(to: c)
                        half.addLine(to: tip)
                        half.addLine(to: point(c, r * 0.16, a + side * .pi / 4))
                        half.closeSubpath()
                        ctx.fill(half, with: .color(side < 0 ? .ink : .parchment))
                        ctx.stroke(half, with: .color(.ink), lineWidth: 0.8)
                    }
                }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.ink))
                let north = point(c, r * 1.0, 0)
                ctx.draw(Text("N").font(.system(size: 11, weight: .heavy, design: .serif)).foregroundColor(.ink),
                         at: CGPoint(x: north.x, y: north.y + 9))
            }
            .frame(width: 64, height: 64)
            .rotationEffect(.degrees(-direction))
        }
        .accessibilityLabel("Compass. Tap to face north.")
    }
}

/// Point at distance `d` from `c`, `a` radians clockwise from straight up.
private func point(_ c: CGPoint, _ d: Double, _ a: Double) -> CGPoint {
    CGPoint(x: c.x + d * sin(a), y: c.y - d * cos(a))
}

/// Fog of war over the map: a haze with soft holes wherever you've been. Redrawn as the map moves (`tick`).
struct FogView: View {
    @ObservedObject var model: AppModel
    let tick: Int

    var body: some View {
        Canvas { ctx, size in
            _ = tick
            guard let map = model.map, map.bounds.width > 0 else { return }
            let b = map.visibleCoordinateBounds
            let cells = model.explorer.cells(sw: b.sw, ne: b.ne)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.parchment.opacity(0.55)))
            // A revealed cell's radius on screen: ~1.5 cells wide so neighbours merge into one clearing.
            let mid = map.centerCoordinate
            let r = max(Explorer.cell * 111_320 / map.metersPerPoint(atLatitude: mid.latitude) * 0.9, 1.5)
            var eraser = ctx
            eraser.blendMode = .destinationOut
            eraser.addFilter(.blur(radius: r * 0.5))
            eraser.drawLayer { layer in
                for k in cells {
                    let p = map.convert(Explorer.center(k), toPointTo: map)
                    layer.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(.black))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A round speed-limit sign, in the units the phone uses.
struct SpeedSign: View {
    let kmh: Double

    var body: some View {
        let metric = Locale.current.measurementSystem == .metric
        Text("\(Int((metric ? kmh : kmh / 1.609344).rounded()))")
            .font(.system(size: 17, weight: .heavy, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: 42, height: 42)
            .background(Circle().fill(.white))
            .overlay(Circle().stroke(Color.red, lineWidth: 5))
            .accessibilityLabel("Speed limit \(Guide.speed(kmh / 3.6))")
    }
}
