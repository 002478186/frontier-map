import SwiftUI
import MapLibre

enum MapStyle {
    static var key: String { Bundle.main.object(forInfoDictionaryKey: "MAPTILER_KEY") as? String ?? "" }
    static var hasKey: Bool { !key.isEmpty && key != "YOUR_MAPTILER_KEY" }

    /// The bundled style carries a placeholder; the key is injected at runtime so it never sits in source.
    static func url() -> URL? {
        guard let src = Bundle.main.url(forResource: "frontier-style", withExtension: "json"),
              let json = try? String(contentsOf: src) else { return nil }
        let out = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("frontier-style.json")
        try? json.replacingOccurrences(of: "MAPTILER_KEY_PLACEHOLDER", with: key)
            .write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

final class Pin: MLNPointAnnotation {
    var id = UUID()
}

struct MapView: UIViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: MapStyle.url())
        map.delegate = context.coordinator
        map.showsUserLocation = true // MapLibre asks for When-In-Use permission itself
        map.setCenter(CLLocationCoordinate2D(latitude: 30, longitude: -40), zoomLevel: 1, animated: false)
        map.compassViewMargins = CGPoint(x: 16, y: 130) // keep the compass clear of the search bar
        map.addGestureRecognizer(UILongPressGestureRecognizer(target: context.coordinator,
                                                              action: #selector(Coordinator.longPress(_:))))
        model.map = map
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let pins = (map.annotations ?? []).compactMap { $0 as? Pin }
        guard Set(pins.map(\.id)) != Set(model.waypoints.map(\.id)) else { return }
        map.removeAnnotations(pins)
        map.addAnnotations(model.waypoints.map { w in
            let pin = Pin()
            pin.id = w.id
            pin.coordinate = w.coordinate
            pin.title = w.name
            return pin
        })
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        let model: AppModel
        init(_ model: AppModel) { self.model = model }

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map = g.view as? MLNMapView else { return }
            model.pendingPin = map.convert(g.location(in: map), toCoordinateFrom: map)
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { true }

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

        func mapView(_ mapView: MLNMapView, annotation: MLNAnnotation, calloutAccessoryControlTapped control: UIControl) {
            if let pin = annotation as? Pin, let w = model.waypoints.first(where: { $0.id == pin.id }) {
                if control.tag == 1 {
                    Task { @MainActor in await model.directions(to: w.name, at: w.coordinate) }
                } else {
                    model.guide(to: w)
                }
            }
            mapView.deselectAnnotation(annotation, animated: true)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            let source = MLNShapeSource(identifier: "route", shape: nil)
            style.addSource(source)
            let casing = MLNLineStyleLayer(identifier: "route-casing", source: source)
            casing.lineColor = NSExpression(forConstantValue: UIColor(Color.parchment))
            casing.lineWidth = NSExpression(forConstantValue: 9)
            casing.lineCap = NSExpression(forConstantValue: "round")
            let trail = MLNLineStyleLayer(identifier: "route-trail", source: source)
            trail.lineColor = NSExpression(forConstantValue: UIColor(red: 0.55, green: 0.12, blue: 0.08, alpha: 1))
            trail.lineWidth = NSExpression(forConstantValue: 5)
            trail.lineDashPattern = NSExpression(forConstantValue: [2, 1.2])
            style.addLayer(casing)
            style.addLayer(trail)
        }

        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            model.locationChanged(userLocation?.location)
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            model.banner = "Map failed to load. Check your connection and MapTiler key."
        }
    }
}
