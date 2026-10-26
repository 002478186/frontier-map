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
    @Published private(set) var navigating = false
    @Published private(set) var nextTurnDistance: CLLocationDistance?
    @Published private(set) var nextCrossing: String?  // "bridge" / "flyover" when the next turn takes one
    @Published private(set) var speed: CLLocationSpeed?
    @Published var following = true                   // false once the user pans away mid-trip
    @Published var resultKind: Waypoint.Kind?          // set when `results` came from a nearby-finds search
    @Published private(set) var weather: Weather?
    @Published var rider = Rider(rawValue: UserDefaults.standard.string(forKey: "rider") ?? "") ?? .drifter {
        didSet { UserDefaults.standard.set(rider.rawValue, forKey: "rider") }
    }
    var heading = 0.0                  // degrees; faces the camera on Start when there is no course yet
    @Published var mapDirection = 0.0  // map rotation, for the compass rose
    weak var map: MLNMapView?
    private let guide = Guide()
    private var tracker: StepTracker?
    private var offRouteCount = 0
    private var lastReroute = Date.distantPast
    private var weatherFetched = Date.distantPast

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

    func addPin(named name: String, kind: Waypoint.Kind) {
        guard let c = pendingPin else { return }
        pendingPin = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        waypoints.append(Waypoint(name: trimmed.isEmpty ? "Waypoint \(waypoints.count + 1)" : trimmed,
                                  lat: c.latitude, lon: c.longitude, kind: kind))
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
        guard let here else { return say(rider.lost) }
        say(Guide.directions(from: here, to: w, rider: rider))
    }

    func say(_ text: String) { guide.say(text, as: rider) }

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
            let wasNavigating = navigating // e.g. switching Car/Walk mid-trip, or re-routing
            preview(found, to: Destination(name: name, coordinate: coordinate), overview: !wasNavigating)
            if wasNavigating { go(announce: false) }
        } catch {
            banner = "No trail found to \(name). \(error.localizedDescription)"
        }
    }

    /// Shows the whole route; nothing is tracked or spoken until go().
    private func preview(_ route: MKRoute, to dest: Destination, overview: Bool = true) {
        endRoute()
        self.route = route
        destination = dest
        let coords = route.polyline.coordinates
        (map?.style?.source(withIdentifier: "route") as? MLNShapeSource)?.shape =
            MLNPolyline(coordinates: coords, count: UInt(coords.count))
        guard overview else { return }
        map?.setVisibleCoordinates(coords, count: UInt(coords.count),
                                   edgePadding: UIEdgeInsets(top: 160, left: 40, bottom: 300, right: 40), animated: true)
    }

    /// Start button: follow the user heading-up and begin spoken turns.
    func go(announce: Bool = true) {
        guard let route, let dest = destination else { return }
        tracker = StepTracker(points: route.steps.map { step in
            let c = step.polyline.coordinates.first ?? dest.coordinate
            return CLLocation(latitude: c.latitude, longitude: c.longitude)
        }, walking: walking)
        nextStep = 1
        navigating = true
        UIApplication.shared.isIdleTimerDisabled = true // keep the screen on so turns keep being spoken
        recenter()
        if announce { say(Guide.routeStart(route, to: dest.name, walking: walking, rider: rider)) }
        locationChanged(here)
    }

    /// Fly to the user, tilted and facing the way they're heading, then follow. Turning on follow mode
    /// during a zoom animation gets cancelled by it, which left the camera on the route overview.
    func recenter() {
        let follow: () -> Void = { [weak self] in self?.map?.setUserTrackingMode(.followWithCourse, animated: true, completionHandler: nil) }
        guard let here, let map else { return follow() }
        let facing = here.course >= 0 ? here.course : heading
        map.setCamera(MLNMapCamera(lookingAtCenter: here.coordinate, acrossDistance: walking ? 250 : 700,
                                   pitch: 45, heading: facing),
                      withDuration: 1, animationTimingFunction: nil, completionHandler: follow)
    }

    func endRoute() {
        route = nil
        destination = nil
        tracker = nil
        navigating = false
        nextTurnDistance = nil
        nextCrossing = nil
        speed = nil
        offRouteCount = 0
        UIApplication.shared.isIdleTimerDisabled = false
        (map?.style?.source(withIdentifier: "route") as? MLNShapeSource)?.shape = nil
    }

    var nextTurn: String? {
        guard navigating, let steps = route?.steps, nextStep < steps.count else { return nil }
        let text = steps[nextStep].instructions
        return text.isEmpty ? "Continue" : text
    }

    func locationChanged(_ here: CLLocation?) {
        guard let here, let route, var tracker else { return }
        let event = tracker.update(here)
        self.tracker = tracker
        nextStep = tracker.next
        nextTurnDistance = tracker.next < tracker.points.count ? here.distance(from: tracker.points[tracker.next]) : nil
        speed = here.speed >= 0 ? here.speed : nil
        if rerouteIfOffTrail(here, route) { return }
        switch event {
        case .approaching(let i)?:
            let text = route.steps[i].instructions
            nextCrossing = crossing(route.steps[i])
            if !text.isEmpty {
                say("In \(Guide.distance(here.distance(from: tracker.points[i]))), \(Guide.lowerFirst(text))."
                    + (nextCrossing.map { " Take the \($0)." } ?? ""))
            }
        case .reached(let i, let announced)?:
            if i == route.steps.count - 1 {
                say(rider.arrived(destination?.name ?? "your destination"))
                banner = "Arrived at \(destination?.name ?? "your destination")."
                endRoute()
            } else if !announced {
                say(route.steps[i].instructions + (crossing(route.steps[i]).map { ". Take the \($0)." } ?? ""))
            }
            nextCrossing = nil
        case nil:
            break
        }
    }

    /// Asks Apple for a fresh route after a few fixes well off the line; at most every 20 s.
    private func rerouteIfOffTrail(_ here: CLLocation, _ route: MKRoute) -> Bool {
        let limit: CLLocationDistance = walking ? 40 : 80
        let off = Geo.distance(from: here.coordinate, toPath: route.polyline.coordinates) > limit
            && here.horizontalAccuracy < limit // a poor GPS fix isn't proof of a wrong turn
        offRouteCount = off ? offRouteCount + 1 : 0
        guard offRouteCount >= 3, Date().timeIntervalSince(lastReroute) > 20, let dest = destination else { return false }
        offRouteCount = 0
        lastReroute = Date()
        say(rider.offTrail)
        Task { @MainActor in await directions(to: dest.name, at: dest.coordinate) }
        return true
    }

    /// "flyover" / "bridge" when a step crosses one: from Apple's wording, else from the map tiles
    /// (OpenMapTiles `brunnel`) along the start of the step, but only on a road with the same name as
    /// the instruction, so a flyover passing overhead isn't mistaken for the one you take.
    func crossing(_ step: MKRoute.Step) -> String? {
        let text = step.instructions.lowercased()
        if let word = Guide.crossingWord(in: text) { return word }
        guard let map, let road = text.components(separatedBy: " onto ").dropFirst().first, !road.isEmpty else { return nil }
        for c in step.polyline.coordinates.prefix(8) {
            let p = map.convert(c, toPointTo: map)
            guard map.bounds.contains(p) else { continue }
            let bridge = map.visibleFeatures(in: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)).first {
                $0.attribute(forKey: "brunnel") as? String == "bridge"
                    && ($0.attribute(forKey: "name") as? String)?.lowercased() == road
            }
            if let bridge {
                return Guide.crossingWord(in: ((bridge.attribute(forKey: "name") as? String) ?? "").lowercased()) ?? "bridge"
            }
        }
        return nil
    }

    /// Nearby places of one kind, listed under the search bar and dropped on the map as that kind's pins.
    @MainActor
    func nearby(_ kind: Waypoint.Kind) async {
        guard let here, let find = Waypoint.Kind.finds.first(where: { $0.kind == kind }) else {
            banner = "Need your location to find what's nearby."
            return
        }
        let request = MKLocalPointsOfInterestRequest(center: here.coordinate, radius: 5000)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: find.categories)
        let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        results = Array(items.sorted { // nearest first
            here.distance(from: $0.placemark.location ?? here) < here.distance(from: $1.placemark.location ?? here)
        }.prefix(8))
        resultKind = results.isEmpty ? nil : kind
        if results.isEmpty { banner = "No \(find.title.lowercased()) within 5 km. (Needs a connection.)" }
    }

    /// Weather chip data; refetched at most every 30 minutes as the user moves.
    func refreshWeather() {
        guard let here, Date().timeIntervalSince(weatherFetched) > 1800 else { return }
        weatherFetched = Date()
        Task { @MainActor in
            do { weather = try await Weather.fetch(at: here.coordinate) }
            catch { weatherFetched = Date().addingTimeInterval(-1500) } // try again in 5 minutes
        }
    }

    @MainActor
    func search(_ text: String) async {
        resultKind = nil
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
