import SwiftUI
import MapKit
import MapLibre

enum MapSkin: String, CaseIterable, Identifiable {
    case frontier, modern, topo
    var id: String { rawValue }
    var label: String {
        switch self {
        case .frontier: "Frontier"
        case .modern: "Modern"
        case .topo: "Topo"
        }
    }
}

enum NightMode: String, CaseIterable, Identifiable {
    case auto, on, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .on: "Always"
        case .off: "Never"
        }
    }
}

enum MapStyle {
    static var key: String { Bundle.main.object(forInfoDictionaryKey: "MAPTILER_KEY") as? String ?? "" }
    static var hasKey: Bool { !key.isEmpty && key != "YOUR_MAPTILER_KEY" }
    private static var written: [Bool: URL] = [:]

    /// Frontier is the bundled parchment style; Modern and Topo are MapTiler's own streets and outdoor maps
    /// (outdoor has contour lines, hiking paths and peaks).
    static func url(_ skin: MapSkin = .frontier, night: Bool = false) -> URL? {
        switch skin {
        case .modern: return remote(night ? "streets-v2-dark" : "streets-v2")
        case .topo: return remote(night ? "outdoor-v2-dark" : "outdoor-v2")
        case .frontier: break
        }
        if let hit = written[night] { return hit }
        // The bundled style carries a placeholder; the key is injected at runtime so it never sits in source.
        guard let src = Bundle.main.url(forResource: "frontier-style", withExtension: "json"),
              let json = try? String(contentsOf: src) else { return nil }
        let out = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(night ? "frontier-night.json" : "frontier-style.json")
        try? (night ? nightify(json) : json).replacingOccurrences(of: "MAPTILER_KEY_PLACEHOLDER", with: key)
            .write(to: out, atomically: true, encoding: .utf8)
        written[night] = out
        return out
    }

    private static func remote(_ map: String) -> URL? {
        URL(string: "https://api.maptiler.com/maps/\(map)/style.json?key=\(key)")
    }

    /// Moonlit parchment: every colour's lightness flipped, hue kept, saturation eased off.
    static func nightify(_ json: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "#[0-9a-fA-F]{6}") else { return json }
        var out = json
        for m in re.matches(in: json, range: NSRange(json.startIndex..., in: json)).reversed() {
            let r = Range(m.range, in: json)!
            out.replaceSubrange(r, with: night(String(json[r])))
        }
        return out
    }

    static func night(_ hex: String) -> String {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        let r = Double(v >> 16 & 255) / 255, g = Double(v >> 8 & 255) / 255, b = Double(v & 255) / 255
        let hi = max(r, g, b), lo = min(r, g, b), l = (hi + lo) / 2, d = hi - lo
        let s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
        var h = 0.0
        if d > 0 {
            h = hi == r ? (g - b) / d : hi == g ? (b - r) / d + 2 : (r - g) / d + 4
            h = (h * 60 + 360).truncatingRemainder(dividingBy: 360)
        }
        let l2 = 0.08 + (1 - l) * 0.84, s2 = s * 0.7 // never pure black or white
        let c = (1 - abs(2 * l2 - 1)) * s2, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = l2 - c / 2
        let (r1, g1, b1): (Double, Double, Double) = switch h {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
        let byte = { (f: Double) in Int(((f + m) * 255).rounded()).clamped(0, 255) }
        return String(format: "#%02x%02x%02x", byte(r1), byte(g1), byte(b1))
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}

class Pin: MLNPointAnnotation {
    var id = UUID()
    var kind = Waypoint.Kind.pin
}

/// A search or nearby-finds result: shown like a waypoint pin but not saved.
final class FindPin: Pin {
    var item: MKMapItem?
}

/// A discovery: faded until you've been there.
final class DiscoveryPin: Pin {
    var found = false
}

/// Fake GPS for CI's simulated drive (ios.yml): stands at the start, then drives a path at 10 m/s, a fix a second.
final class DemoLocation: NSObject, MLNLocationManager {
    weak var delegate: MLNLocationManagerDelegate?
    var headingOrientation: CLDeviceOrientation = .portrait
    var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }
    private var here: CLLocationCoordinate2D
    private var ahead: [CLLocationCoordinate2D] = []
    private var timer: Timer?

    init(start: CLLocationCoordinate2D) { here = start }

    func drive(_ path: [CLLocationCoordinate2D]) { ahead = path }

    func startUpdatingLocation() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stopUpdatingLocation() { timer?.invalidate() }

    private func tick() {
        var left = 10.0, course = -1.0
        while left > 0, let next = ahead.first {
            let d = CLLocation(latitude: here.latitude, longitude: here.longitude)
                .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
            if d > 0.5 { course = Geo.bearing(from: here, to: next) }
            if d <= left {
                here = next
                ahead.removeFirst()
                left -= d
            } else {
                let t = left / d
                here = .init(latitude: here.latitude + (next.latitude - here.latitude) * t,
                             longitude: here.longitude + (next.longitude - here.longitude) * t)
                left = 0
            }
        }
        let fix = CLLocation(coordinate: here, altitude: 900, horizontalAccuracy: 5, verticalAccuracy: 5,
                             course: course, speed: course >= 0 ? 10 : 0, timestamp: Date())
        delegate?.locationManager(self, didUpdate: [fix])
    }

    func requestAlwaysAuthorization() {}
    func requestWhenInUseAuthorization() {}
    func startUpdatingHeading() {}
    func stopUpdatingHeading() {}
    func dismissHeadingCalibrationDisplay() {}
}

struct MapView: UIViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: MapStyle.url(model.mapSkin, night: context.environment.colorScheme == .dark))
        map.delegate = context.coordinator
        if let start = AppModel.demoStart { // CI's simulated drive
            let driver = DemoLocation(start: start)
            map.locationManager = driver
            model.demoDriver = driver
        }
        map.showsUserLocation = true // MapLibre asks for When-In-Use permission itself
        map.showsUserHeadingIndicator = true // delivers compass heading for the arrow
        map.setCenter(CLLocationCoordinate2D(latitude: 30, longitude: -40), zoomLevel: 1, animated: false)
        map.compassView.isHidden = true // replaced by CompassRose
        map.addGestureRecognizer(UILongPressGestureRecognizer(target: context.coordinator,
                                                              action: #selector(Coordinator.longPress(_:))))
        model.map = map
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let style = MapStyle.url(model.mapSkin, night: context.environment.colorScheme == .dark)
        if let style, map.styleURL != style { map.styleURL = style } // didFinishLoading redraws our layers
        syncFinds(map, context.coordinator)
        syncDiscoveries(map, context.coordinator)
        let pins = (map.annotations ?? []).compactMap { $0 as? Pin }.filter { !($0 is FindPin) && !($0 is DiscoveryPin) }
        let shown = context.coordinator.shownWaypoints
        guard shown != model.waypoints else { return }
        context.coordinator.shownWaypoints = model.waypoints
        map.removeAnnotations(pins)
        map.addAnnotations(model.waypoints.map { w in
            let pin = Pin()
            pin.id = w.id
            pin.coordinate = w.coordinate
            pin.title = w.name
            pin.subtitle = w.note.isEmpty ? nil : w.note
            pin.kind = w.kind
            return pin
        })
    }

    private func syncFinds(_ map: MLNMapView, _ c: Coordinator) {
        let shown = model.results
        guard shown != c.shownFinds else { return }
        c.shownFinds = shown
        map.removeAnnotations((map.annotations ?? []).filter { $0 is FindPin })
        map.addAnnotations(shown.map { item in
            let pin = FindPin()
            pin.coordinate = item.placemark.coordinate
            pin.title = item.name
            pin.subtitle = item.placemark.title
            pin.kind = model.resultKind ?? Waypoint.Kind(category: item.pointOfInterestCategory)
            pin.item = item
            return pin
        })
        let here = model.here.map { [$0.coordinate] } ?? []
        if !shown.isEmpty { // frame the user and every result
            let coords = shown.map(\.placemark.coordinate) + here
            map.setVisibleCoordinates(coords, count: UInt(coords.count),
                                      edgePadding: UIEdgeInsets(top: 300, left: 50, bottom: 140, right: 50), animated: true)
        }
    }

    private func syncDiscoveries(_ map: MLNMapView, _ c: Coordinator) {
        guard model.discoveries != c.shownDiscoveries else { return }
        c.shownDiscoveries = model.discoveries
        map.removeAnnotations((map.annotations ?? []).filter { $0 is DiscoveryPin })
        map.addAnnotations(model.discoveries.map { d in
            let pin = DiscoveryPin()
            pin.coordinate = d.coordinate
            pin.title = d.name
            pin.subtitle = d.found.map { "Discovered \($0.formatted(date: .abbreviated, time: .omitted))" }
                ?? "Undiscovered. Go there to collect it."
            pin.kind = d.kind
            pin.found = d.found != nil
            return pin
        })
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        let model: AppModel
        var shownFinds: [MKMapItem] = []
        var shownDiscoveries: [Discovery] = []
        var shownWaypoints: [Waypoint]?
        init(_ model: AppModel) { self.model = model }

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map = g.view as? MLNMapView else { return }
            model.dropPin(at: map.convert(g.location(in: map), toCoordinateFrom: map))
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { true }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            annotation is MLNUserLocation ? PlayerArrowView(reuseIdentifier: "player") : nil // pins use images below
        }

        func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            guard let pin = annotation as? Pin else { return nil }
            let faded = (pin as? DiscoveryPin)?.found == false
            let id = pin.kind.rawValue + (faded ? "-faded" : "")
            return mapView.dequeueReusableAnnotationImage(withIdentifier: id)
                ?? MLNAnnotationImage(image: Markers.pin(pin.kind, faded: faded), reuseIdentifier: id)
        }

        func mapView(_ mapView: MLNMapView, regionIsChangingWith reason: MLNCameraChangeReason) {
            model.mapDirection = mapView.direction
            model.camera &+= 1
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            model.mapDirection = mapView.direction
            model.camera &+= 1
        }

        func mapView(_ mapView: MLNMapView, leftCalloutAccessoryViewFor annotation: MLNAnnotation) -> UIView? {
            button("speaker.wave.2.fill", label: "Ask the guide which way", tag: 0)
        }

        func mapView(_ mapView: MLNMapView, rightCalloutAccessoryViewFor annotation: MLNAnnotation) -> UIView? {
            button("car.fill", label: "Directions", tag: 1)
        }

        private func button(_ icon: String, label: String, tag: Int) -> UIButton {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: icon), for: .normal)
            button.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
            button.tintColor = UIColor(Color.ink)
            button.tag = tag
            button.accessibilityLabel = label
            return button
        }

        private func waypoint(for pin: Pin) -> Waypoint? {
            pin is FindPin || pin is DiscoveryPin
                ? Waypoint(name: pin.title ?? "there", lat: pin.coordinate.latitude, lon: pin.coordinate.longitude, kind: pin.kind)
                : model.waypoints.first(where: { $0.id == pin.id })
        }

        func mapView(_ mapView: MLNMapView, annotation: MLNAnnotation, calloutAccessoryControlTapped control: UIControl) {
            if let pin = annotation as? Pin, let w = waypoint(for: pin) {
                if control.tag == 1 {
                    Task { @MainActor in await model.directions(to: w.name, at: w.coordinate) }
                } else {
                    model.guide(to: w)
                }
            }
            mapView.deselectAnnotation(annotation, animated: true)
        }

        /// Tapping the popup itself: place details for a search result, the editor for your own pin.
        func mapView(_ mapView: MLNMapView, tapOnCalloutFor annotation: MLNAnnotation) {
            if let find = annotation as? FindPin, let item = find.item {
                model.place = item
            } else if let pin = annotation as? Pin, !(pin is DiscoveryPin), let w = waypoint(for: pin) {
                model.editing = w
            }
            mapView.deselectAnnotation(annotation, animated: true)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            func line(_ id: String, _ source: MLNShapeSource, color: UIColor, width: Double, dash: [Double]? = nil) {
                let layer = MLNLineStyleLayer(identifier: id, source: source)
                layer.lineColor = NSExpression(forConstantValue: color)
                layer.lineWidth = NSExpression(forConstantValue: width)
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                if let dash { layer.lineDashPattern = NSExpression(forConstantValue: dash) }
                style.addLayer(layer)
            }
            let ink = UIColor(red: 0.23, green: 0.15, blue: 0.09, alpha: 1)
            let parchment = UIColor(red: 0.91, green: 0.84, blue: 0.69, alpha: 1)
            let trail = MLNShapeSource(identifier: "trail", shape: nil) // a past trip from the Journal
            let alternates = MLNShapeSource(identifier: "alternates", shape: nil)
            let route = MLNShapeSource(identifier: "route", shape: nil)
            for source in [trail, alternates, route] { style.addSource(source) }
            line("trail-line", trail, color: UIColor(red: 0.20, green: 0.40, blue: 0.55, alpha: 0.9), width: 4, dash: [1, 1.5])
            line("alternates-casing", alternates, color: parchment, width: 8)
            line("alternates-line", alternates, color: ink.withAlphaComponent(0.45), width: 4)
            line("route-casing", route, color: parchment, width: 9)
            line("route-trail", route, color: UIColor(red: 0.55, green: 0.12, blue: 0.08, alpha: 1), width: 5, dash: [2, 1.2])
            model.drawRoute()
        }

        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            model.heading = PlayerArrowView.heading(userLocation) ?? model.heading
            model.locationChanged(userLocation?.location)
            model.refreshWeather()
        }

        func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            model.following = mode != .none
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            model.banner = "Map failed to load. Check your connection and MapTiler key."
        }
    }
}
