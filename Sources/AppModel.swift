import SwiftUI
import MapKit
import MapLibre

final class AppModel: ObservableObject {
    @Published var waypoints = Waypoint.load() { didSet { Waypoint.save(waypoints) } }
    @Published var pendingPin: CLLocationCoordinate2D?
    @Published var results: [MKMapItem] = []
    @Published var banner: String?
    @Published var route: MKRoute?
    @Published var destination: Destination?
    @Published var walking = false
    @Published private(set) var nextStep = 1
    weak var map: MLNMapView?
    private let guide = Guide()
    private var tracker: StepTracker?

    init() {
        let center = NotificationCenter.default
        center.addObserver(forName: .MLNOfflinePackProgressChanged, object: nil, queue: .main) { [weak self] note in
            guard let pack = note.object as? MLNOfflinePack else { return }
            let p = pack.progress
            self?.banner = pack.state == .complete
                ? "Area saved for offline use."
                : "Saving map… \(p.countOfResourcesCompleted) of \(p.countOfResourcesExpected)"
        }
        center.addObserver(forName: .MLNOfflinePackError, object: nil, queue: .main) { [weak self] note in
            let error = note.userInfo?[MLNOfflinePackUserInfoKey.error] as? Error
            self?.banner = "Offline save failed: \(error?.localizedDescription ?? "unknown error")"
        }
    }

    var here: CLLocation? { map?.userLocation?.location }

    func addPin(named name: String) {
        guard let c = pendingPin else { return }
        pendingPin = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        waypoints.append(Waypoint(name: trimmed.isEmpty ? "Waypoint \(waypoints.count + 1)" : trimmed,
                                  lat: c.latitude, lon: c.longitude))
    }

    func fly(to c: CLLocationCoordinate2D) {
        map?.setCenter(c, zoomLevel: 12, animated: true)
    }

    func followMe() {
        switch CLLocationManager().authorizationStatus {
        case .denied, .restricted:
            banner = "Location is off for Frontier Map. Turn it on in Settings › Privacy › Location Services."
        default:
            map?.userTrackingMode = .followWithHeading
        }
    }

    func guide(to w: Waypoint) {
        guard let here else {
            guide.say("Can't rightly tell where you're standing. Check that location is switched on.")
            return
        }
        guide.say(Guide.directions(from: here, to: w))
    }

    @MainActor
    func directions(to name: String, at coordinate: CLLocationCoordinate2D) async {
        guard let here else {
            banner = "Need your location to plan a route. Tap the follow button and allow location."
            return
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: here.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        request.transportType = walking ? .walking : .automobile
        request.departureDate = Date() // so Apple's ETA reflects current traffic
        do {
            guard let found = try await MKDirections(request: request).calculate().routes.first else {
                banner = "No trail found to \(name)."
                return
            }
            start(found, to: Destination(name: name, coordinate: coordinate))
        } catch {
            banner = "No trail found to \(name). \(error.localizedDescription)"
        }
    }

    private func start(_ route: MKRoute, to dest: Destination) {
        self.route = route
        destination = dest
        tracker = StepTracker(points: route.steps.map { step in
            let c = step.polyline.coordinates.first ?? dest.coordinate
            return CLLocation(latitude: c.latitude, longitude: c.longitude)
        }, walking: walking)
        nextStep = 1
        UIApplication.shared.isIdleTimerDisabled = true // keep the screen on so turns keep being spoken
        let coords = route.polyline.coordinates
        (map?.style?.source(withIdentifier: "route") as? MLNShapeSource)?.shape =
            MLNPolyline(coordinates: coords, count: UInt(coords.count))
        map?.setVisibleCoordinates(coords, count: UInt(coords.count),
                                   edgePadding: UIEdgeInsets(top: 160, left: 40, bottom: 300, right: 40), animated: true)
        guide.say(Guide.routeStart(route, to: dest.name, walking: walking))
    }

    func endRoute() {
        route = nil
        destination = nil
        tracker = nil
        UIApplication.shared.isIdleTimerDisabled = false
        (map?.style?.source(withIdentifier: "route") as? MLNShapeSource)?.shape = nil
    }

    func locationChanged(_ here: CLLocation?) {
        guard let here, let route, var tracker else { return }
        let event = tracker.update(here)
        self.tracker = tracker
        nextStep = tracker.next
        switch event {
        case .approaching(let i)?:
            let text = route.steps[i].instructions
            if !text.isEmpty {
                guide.say("In \(Guide.distance(here.distance(from: tracker.points[i]))), \(Guide.lowerFirst(text)).")
            }
        case .reached(let i, let announced)?:
            if i == route.steps.count - 1 {
                guide.say("Whoa there. You've reached \(destination?.name ?? "your destination").")
                banner = "Arrived at \(destination?.name ?? "your destination")."
                endRoute()
            } else if !announced {
                guide.say(route.steps[i].instructions)
            }
        case nil:
            break
        }
    }

    @MainActor
    func search(_ text: String) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        let response = try? await MKLocalSearch(request: request).start()
        results = Array((response?.mapItems ?? []).prefix(5))
        if results.isEmpty { banner = "No trail leads there. (Search needs a connection.)" }
    }

    /// Downloads what's on screen plus three zoom levels deeper.
    func saveVisibleArea() {
        guard let map, let style = map.styleURL else { return }
        let region = MLNTilePyramidOfflineRegion(styleURL: style, bounds: map.visibleCoordinateBounds,
                                                 fromZoomLevel: map.zoomLevel,
                                                 toZoomLevel: min(map.zoomLevel + 3, 15))
        MLNOfflineStorage.shared.addPack(for: region, withContext: Data()) { [weak self] pack, error in
            if let error { self?.banner = "Offline save failed: \(error.localizedDescription)" } else { pack?.resume() }
        }
    }

    func deleteOfflineAreas() {
        MLNOfflineStorage.shared.packs?.forEach { MLNOfflineStorage.shared.removePack($0, withCompletionHandler: nil) }
        banner = "Offline areas deleted."
    }
}
