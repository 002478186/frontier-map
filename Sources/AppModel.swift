import SwiftUI
import MapKit
import MapLibre
import UserNotifications

final class AppModel: ObservableObject {
    @Published var waypoints = Waypoint.load() { didSet { Waypoint.save(waypoints); checkAchievements() } }
    @Published var recents = Waypoint.load("recents") { didSet { Waypoint.save(recents, "recents") } }
    @Published var editing: Waypoint?        // pin editor sheet (new or existing)
    @Published var place: MKMapItem?         // place details sheet
    @Published var results: [MKMapItem] = []
    @Published var banner: String? { // fades after 6 s so it never sits over the road
        didSet {
            guard let text = banner else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in if self?.banner == text { self?.banner = nil } }
        }
    }
    @Published private(set) var route: Route?
    @Published private(set) var alternatives: [Route] = []
    @Published private(set) var selected = 0
    @Published private(set) var stops: [Destination] = []
    @Published private(set) var transitTime: TimeInterval?
    @Published var travel = Travel.car
    @Published private(set) var nextStep = 1
    @Published private(set) var navigating = false
    @Published private(set) var nextTurnDistance: CLLocationDistance?
    @Published private(set) var nextCrossing: String?  // "bridge" / "flyover" when the next turn takes one
    @Published private(set) var speed: CLLocationSpeed?
    @Published private(set) var speedLimit: Double?    // km/h, from OpenStreetMap
    @Published var following = true                   // false once the user pans away mid-trip
    @Published var resultKind: Waypoint.Kind?          // set when `results` came from a nearby-finds search
    @Published private(set) var weather: Weather?
    @Published var rider = Rider(rawValue: UserDefaults.standard.string(forKey: "rider") ?? "") ?? .drifter {
        didSet { UserDefaults.standard.set(rider.rawValue, forKey: "rider") }
    }
    @Published var skin = MapSkin(rawValue: UserDefaults.standard.string(forKey: "skin") ?? "") ?? .frontier {
        didSet { UserDefaults.standard.set(skin.rawValue, forKey: "skin") }
    }
    @Published var nightMode = NightMode(rawValue: UserDefaults.standard.string(forKey: "night") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(nightMode.rawValue, forKey: "night") }
    }
    @Published var fog = UserDefaults.standard.object(forKey: "fog") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fog, forKey: "fog") }
    }
    @Published var avoidTolls = UserDefaults.standard.bool(forKey: "avoidTolls") {
        didSet { UserDefaults.standard.set(avoidTolls, forKey: "avoidTolls"); replan() }
    }
    @Published var avoidHighways = UserDefaults.standard.bool(forKey: "avoidHighways") {
        didSet { UserDefaults.standard.set(avoidHighways, forKey: "avoidHighways"); replan() }
    }
    /// Swap the parchment map for the plain street map while driving, so it never hurts readability.
    @Published var clearDriving = UserDefaults.standard.object(forKey: "clearDriving") as? Bool ?? true {
        didSet { UserDefaults.standard.set(clearDriving, forKey: "clearDriving") }
    }
    @Published var commute = UserDefaults.standard.bool(forKey: "commute") {
        didSet { UserDefaults.standard.set(commute, forKey: "commute"); Task { @MainActor in await scheduleCommute(force: true) } }
    }
    @Published var arriveAt = UserDefaults.standard.object(forKey: "arriveAt") as? Int ?? 9 * 60 { // minutes after midnight
        didSet { UserDefaults.standard.set(arriveAt, forKey: "arriveAt"); Task { @MainActor in await scheduleCommute(force: true) } }
    }
    @Published private(set) var trips = Store.load("trips.json", as: [Trip].self) ?? []
    @Published private(set) var explorer = Store.load("explorer.json", as: Explorer.self) ?? Explorer()
    @Published private(set) var discoveries = Store.load("discoveries.json", as: [Discovery].self) ?? [] // found ones are saved; unfound nearby ones aren't
    @Published private(set) var earned = Store.load("achievements.json", as: [String: Date].self) ?? [:]
    @Published private(set) var shownTrip: Trip?
    @Published var camera = 0                          // bumped as the map moves, so the fog redraws
    var heading = 0.0                  // degrees; faces the camera on Start when there is no course yet
    @Published var mapDirection = 0.0  // map rotation, for the compass rose
    weak var map: MLNMapView?
    private let guide = Guide()
    private let background = BackgroundLocation()
    private var tracker: StepTracker?
    private var recorder = TripRecorder()
    private var famousRoads = Set(UserDefaults.standard.stringArray(forKey: "famousRoads") ?? [])
    private var offRouteCount = 0
    private var lastReroute = Date.distantPast
    private var weatherFetched = Date.distantPast
    private var lastScout: CLLocation?
    private var lastLimitCheck: CLLocation?
    private var speedingCount = 0
    private var warnedLimit: Double?
    private var lastBearingCall: CLLocation?
    private var unsavedCells = 0
    private var commuteScheduled = Date.distantPast

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
        background.onUpdate = { [weak self] in self?.locationChanged($0) }
    }

    var here: CLLocation? { map?.userLocation?.location }
    var destination: Destination? { stops.last }

    // MARK: Waypoints and places

    func dropPin(at c: CLLocationCoordinate2D) { editing = Waypoint("", c) }

    func save(_ w: Waypoint) {
        var w = w
        if w.name.trimmingCharacters(in: .whitespaces).isEmpty { w.name = "Waypoint \(waypoints.count + 1)" }
        if let i = waypoints.firstIndex(where: { $0.id == w.id }) { waypoints[i] = w } else { waypoints.append(w) }
    }

    func delete(_ w: Waypoint) {
        if let url = w.photoURL { try? FileManager.default.removeItem(at: url) }
        waypoints.removeAll { $0.id == w.id }
    }

    func fly(to c: CLLocationCoordinate2D) {
        map?.setCenter(c, zoomLevel: max(map?.zoomLevel ?? 0, 13), animated: true)
    }

    func show(place item: MKMapItem) {
        fly(to: item.placemark.coordinate)
        place = item
    }

    /// Kept for the search box: the last few places you looked up or went to.
    func remember(_ name: String, _ c: CLLocationCoordinate2D) {
        recents.removeAll { $0.name == name }
        recents.insert(Waypoint(name, c), at: 0)
        if recents.count > 8 { recents.removeLast(recents.count - 8) }
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

    func say(_ text: String) {
        if Self.demoRun { print("SAY: " + text) }
        guide.say(text, as: rider)
    }

    /// CI's simulated drive (see ios.yml): `-demo lat,lon` routes there from the first fix, starts, prints the route
    /// so the simulator can drive it, and prints every spoken line.
    /// `-from lat,lon` is where the simulated car starts (DemoLocation drives it).
    static let demoRun = ProcessInfo.processInfo.arguments.contains("-demo")
    static let demoStart = argument("-from")
    private var demo = argument("-demo")
    var demoDriver: DemoLocation?

    private static func argument(_ name: String) -> CLLocationCoordinate2D? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let p = args[i + 1].split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? CLLocationCoordinate2D(latitude: p[0], longitude: p[1]) : nil
    }

    /// Plain, high-contrast map while driving; the chosen style otherwise.
    var drivingClear: Bool { clearDriving && navigating && travel == .car }
    var mapSkin: MapSkin { drivingClear && skin == .frontier ? .modern : skin }

    /// Remembers where the car was left, replacing the last spot.
    func park(at c: CLLocationCoordinate2D) {
        waypoints.removeAll { $0.kind == .parked }
        waypoints.append(Waypoint("Parked car", c, kind: .parked))
    }

    /// Night map and dark controls: always, never, or (auto) after sunset, else the phone's own setting.
    var colorScheme: ColorScheme? {
        switch nightMode {
        case .on: .dark
        case .off: .light
        case .auto: weather?.isDark() == true ? .dark : nil
        }
    }

    // MARK: Routes

    @MainActor
    func directions(to name: String, at coordinate: CLLocationCoordinate2D) async {
        remember(name, coordinate)
        stops = [Destination(name: name, coordinate: coordinate)]
        await plan()
    }

    /// Adds a stop where it makes the shortest detour, keeping the destination last.
    @MainActor
    func addStop(_ name: String, at c: CLLocationCoordinate2D, stay: TimeInterval = 15 * 60) async {
        guard let here, !stops.isEmpty else { return await directions(to: name, at: c) }
        stops.insert(Destination(name: name, coordinate: c, stay: stay),
                     at: Geo.insertionIndex(of: c, into: stops.map(\.coordinate), from: here.coordinate))
        await plan()
    }

    func removeStops(at offsets: IndexSet) {
        stops.remove(atOffsets: offsets)
        if stops.isEmpty { endRoute() } else { Task { @MainActor in await plan() } }
    }

    func moveStops(from: IndexSet, to: Int) {
        stops.move(fromOffsets: from, toOffset: to)
        Task { @MainActor in await plan() }
    }

    func setTravel(_ t: Travel) {
        travel = t
        replan()
    }

    private func replan() {
        if !stops.isEmpty { Task { @MainActor in await plan() } }
    }

    private func avoid(_ request: MKDirections.Request) {
        request.tollPreference = avoidTolls ? .avoid : .any
        request.highwayPreference = avoidHighways ? .avoid : .any
    }

    /// Routes through every stop. Without road data (no connection, or nowhere near a road) it falls back
    /// to a straight line and the guide calls out the bearing instead of turns.
    @MainActor
    func plan(quiet: Bool = false) async {
        guard let here else {
            banner = "Need your location to plan a route. Tap the follow button and allow location."
            return
        }
        guard let dest = destination else { return }
        let wasNavigating = navigating // e.g. switching Car/Walk mid-trip, or re-routing
        do {
            let options = try await routes(from: here.coordinate, through: stops, alternates: stops.count == 1)
            show(options, overview: !wasNavigating)
            if wasNavigating { go(announce: false) }
            transitTime = nil
            if stops.count == 1, !wasNavigating { transitTime = try? await transitETA(from: here.coordinate, to: dest.coordinate) }
        } catch {
            if quiet, route?.beeline == true { return }
            show([Route.beeline(from: here.coordinate, to: dest, travel: travel)], overview: !wasNavigating)
            if wasNavigating { go(announce: false) }
            banner = "No road route (\(error.localizedDescription)). Showing a straight line; the guide will call out the bearing."
        }
    }

    private func routes(from start: CLLocationCoordinate2D, through stops: [Destination], alternates: Bool) async throws -> [Route] {
        var legs: [MKRoute] = [], options: [MKRoute] = []
        var from = start
        for stop in stops {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: stop.coordinate))
            request.transportType = travel.transport
            request.departureDate = Date() // so Apple's ETA reflects current traffic
            request.requestsAlternateRoutes = alternates
            avoid(request)
            let found = try await MKDirections(request: request).calculate().routes
            guard let best = found.first else { throw MKError(.directionsNotFound) }
            legs.append(best)
            options = found
            from = stop.coordinate
        }
        let travel = travel
        return alternates ? options.map { Route(legs: [$0], travel: travel, stops: stops) } : [Route(legs: legs, travel: travel, stops: stops)]
    }

    /// Apple gives transit times but not transit turn-by-turn, so transit opens in Apple Maps.
    private func transitETA(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) async throws -> TimeInterval {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
        request.transportType = .transit
        request.departureDate = Date()
        return try await MKDirections(request: request).calculateETA().expectedTravelTime
    }

    func openTransitInMaps() {
        guard let dest = destination else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: dest.coordinate))
        item.name = dest.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit])
    }

    /// Shows the routes found; nothing is tracked or spoken until go().
    private func show(_ options: [Route], overview: Bool) {
        resetGuidance()
        alternatives = options.sorted { $0.totalTime < $1.totalTime } // fastest first, and picked
        select(0, overview: overview)
    }

    func select(_ i: Int, overview: Bool = false) {
        guard alternatives.indices.contains(i) else { return }
        selected = i
        route = alternatives[i]
        stops = alternatives[i].stops
        drawRoute()
        guard overview, let coords = route?.coordinates else { return }
        map?.setVisibleCoordinates(coords, count: UInt(coords.count),
                                   edgePadding: UIEdgeInsets(top: 160, left: 40, bottom: 340, right: 40), animated: true)
    }

    /// Puts the chosen route, the other options and any Journal trail onto the map's line layers.
    func drawRoute() {
        let line = { (c: [CLLocationCoordinate2D]) in MLNPolyline(coordinates: c, count: UInt(c.count)) }
        let source = { (id: String) in self.map?.style?.source(withIdentifier: id) as? MLNShapeSource }
        // While navigating, only the road still ahead is drawn, and the other options are hidden.
        source("route")?.shape = route.map { line(navigating ? tracker?.remaining ?? $0.coordinates : $0.coordinates) }
        source("alternates")?.shape = navigating ? nil
            : MLNShapeCollection(shapes: alternatives.indices.filter { $0 != selected }.map { line(alternatives[$0].coordinates) })
        source("trail")?.shape = shownTrip.map { line($0.coordinates) }
    }

    /// Picks the prettiest detour on the way: a park, beach or waterfront near the middle of the trip that adds
    /// no more than 40% to the drive. Shown as one more route option.
    @MainActor
    func scenic() async {
        guard let here, let dest = destination, stops.count == 1, let fastest = alternatives.first, !fastest.beeline else { return }
        banner = "Scouting a scenic way…"
        let a = here.coordinate, b = dest.coordinate
        let mid = CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
        let request = MKLocalPointsOfInterestRequest(center: mid, radius: min(max(fastest.distance / 3, 1500), 20000))
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.park, .nationalPark, .beach, .marina])
        let midpoint = CLLocation(latitude: mid.latitude, longitude: mid.longitude)
        let items = ((try? await MKLocalSearch(request: request).start())?.mapItems ?? [])
            .sorted { midpoint.distance(from: $0.placemark.location ?? midpoint) < midpoint.distance(from: $1.placemark.location ?? midpoint) }
        var best: Route?
        for item in items.prefix(3) { // each candidate costs two routing calls, and Apple limits how many we can make
            let via = Destination(name: item.name ?? "the park", coordinate: item.placemark.coordinate)
            guard let r = try? await routes(from: a, through: [via, dest], alternates: false).first,
                  r.expectedTravelTime <= fastest.expectedTravelTime * 1.4,
                  r.expectedTravelTime < best?.expectedTravelTime ?? .infinity else { continue }
            best = r
            best?.name = "Scenic, via \(via.name)"
        }
        guard let pick = best else {
            banner = "No scenic detour within reach. The fastest road's the prettiest you'll get."
            return
        }
        banner = nil
        alternatives.append(pick)
        select(alternatives.count - 1, overview: true)
    }

    /// Start button: follow the user heading-up and begin spoken turns.
    func go(announce: Bool = true) {
        guard let route, let dest = destination else { return }
        tracker = StepTracker(steps: route.steps.map(\.coordinates), walking: travel.onFoot)
        nextStep = 1
        navigating = true
        UIApplication.shared.isIdleTimerDisabled = true // keep the screen on so turns keep being spoken
        background.start() // and keep going with the screen locked
        recenter()
        if announce { say(Guide.routeStart(route, to: dest.name, travel: travel, rider: rider)) }
        locationChanged(here)
    }

    /// Fly to the user, tilted and facing the way they're heading, then follow. Turning on follow mode
    /// during a zoom animation gets cancelled by it, which left the camera on the route overview.
    func recenter() {
        let follow: () -> Void = { [weak self] in self?.map?.setUserTrackingMode(.followWithCourse, animated: true, completionHandler: nil) }
        guard let here, let map else { return follow() }
        let facing = here.course >= 0 ? here.course : heading
        map.setCamera(MLNMapCamera(lookingAtCenter: here.coordinate, acrossDistance: travel.onFoot ? 250 : 700,
                                   pitch: 45, heading: facing),
                      withDuration: 1, animationTimingFunction: nil, completionHandler: follow)
    }

    private func resetGuidance() {
        route = nil
        tracker = nil
        navigating = false
        nextTurnDistance = nil
        nextCrossing = nil
        speed = nil
        speedLimit = nil
        offRouteCount = 0
        lastBearingCall = nil
    }

    func endRoute() {
        resetGuidance()
        alternatives = []
        stops = []
        transitTime = nil
        UIApplication.shared.isIdleTimerDisabled = false
        background.stop()
        if let trip = recorder.finish() { log(trip) }
        drawRoute()
        if let map, map.camera.pitch > 0 { // flatten the tilted driving view
            let camera = map.camera
            camera.pitch = 0
            map.setCamera(camera, animated: true)
        }
    }

    /// What's left while navigating: road distance, and time (moving time scaled by distance, plus stops still ahead).
    var remaining: (distance: CLLocationDistance, time: TimeInterval)? {
        guard navigating, let route, let tracker, let total = tracker.along.last, total > 0 else { return nil }
        let left = max(total - tracker.progress, 0)
        return (left, route.expectedTravelTime * left / total + stops.dropLast().reduce(0) { $0 + $1.stay })
    }

    var nextTurn: String? {
        guard navigating, let route, nextStep < route.steps.count else { return nil }
        if route.beeline, let here, let dest = destination {
            return "Head \(Geo.compassPoint(Geo.bearing(from: here.coordinate, to: dest.coordinate))) to \(dest.name)"
        }
        let text = route.steps[nextStep].instructions
        return text.isEmpty ? "Continue" : text
    }

    // MARK: Every location fix

    func locationChanged(_ here: CLLocation?) {
        guard let here else { return }
        if let d = demo {
            demo = nil
            Task { @MainActor in
                await directions(to: "Demo destination", at: d)
                go()
                demoDriver?.drive(route?.coordinates ?? [])
                print("DEMO_STARTED")
            }
        }
        explore(here)
        if let trip = recorder.update(here, name: destination?.name ?? "Free ride") { log(trip) }
        scout(here)
        collect(here)
        guard let route, var tracker else { return }
        let events = tracker.update(here, speed: max(here.speed, 0))
        self.tracker = tracker
        nextStep = tracker.next
        nextTurnDistance = tracker.toNext
        speed = here.speed >= 0 ? here.speed : nil
        drawRoute() // trims the line behind you
        checkSpeed(here, route)
        if rerouteIfOffTrail(here, route, off: tracker.offBy) { return }
        if route.beeline { callBearing(here) }
        for event in events { guard announce(event, on: route) else { return } }
    }

    /// Speaks a turn twice: a few hundred metres out, and again right before it. False once the route has ended.
    private func announce(_ event: StepTracker.Event, on route: Route) -> Bool {
        switch event {
        case .prepare(let i):
            let text = route.steps[i].instructions
            nextCrossing = crossing(route.steps[i])
            guard !text.isEmpty, !route.beeline, let ahead = nextTurnDistance else { return true }
            say("In \(Guide.distance(ahead)), \(Guide.lowerFirst(text))." + (nextCrossing.map { " Take the \($0)." } ?? ""))
            guide.prepare(Self.turnNow(text), as: rider) // so the last-moment call plays without a delay
        case .now(let i):
            let text = route.steps[i].instructions
            // Arrivals get their own line when you reach them.
            if !text.isEmpty, !route.beeline, i < route.steps.count - 1, route.arrivals[i] == nil { say(Self.turnNow(text)) }
        case .reached(let i):
            noteFamousRoad(route.steps[i].instructions)
            nextCrossing = nil
            if i == route.steps.count - 1 {
                say(rider.arrived(destination?.name ?? "your destination"))
                banner = "Arrived at \(destination?.name ?? "your destination")."
                endRoute()
                return false
            }
            if let stop = route.arrivals[i] {
                if !stops.isEmpty { stops.removeFirst() } // a re-route shouldn't send you back to it
                say(stop.stay > 0 ? rider.arrived(stop.name) : "Passing \(stop.name). Take a look.")
                if stop.stay > 0 { banner = "At \(stop.name). Next: \(destination?.name ?? "onward")." }
            }
        }
        return true
    }

    static func turnNow(_ instruction: String) -> String { "Now, \(Guide.lowerFirst(instruction))." }

    /// Asks Apple for a fresh route after a few fixes well off the line; at most every 20 s.
    /// On a straight-line route it quietly tries for a road route every 2 minutes instead.
    private func rerouteIfOffTrail(_ here: CLLocation, _ route: Route, off distance: CLLocationDistance) -> Bool {
        if route.beeline {
            if Date().timeIntervalSince(lastReroute) > 120 {
                lastReroute = Date()
                Task { @MainActor in await plan(quiet: true) }
            }
            return false
        }
        let limit: CLLocationDistance = travel.onFoot ? 40 : 80
        let off = distance > limit && here.horizontalAccuracy < limit // a poor GPS fix isn't proof of a wrong turn
        offRouteCount = off ? offRouteCount + 1 : 0
        guard offRouteCount >= 3, Date().timeIntervalSince(lastReroute) > 20, destination != nil else { return false }
        offRouteCount = 0
        lastReroute = Date()
        say(rider.offTrail)
        Task { @MainActor in await plan() }
        return true
    }

    /// Straight-line guidance: the bearing and distance, every 500 m (100 m on foot).
    private func callBearing(_ here: CLLocation) {
        guard let dest = destination, lastBearingCall.map({ here.distance(from: $0) > (travel.onFoot ? 100 : 500) }) ?? true else { return }
        lastBearingCall = here
        say(rider.toward(dest.name, Guide.heading(from: here, to: Waypoint(dest.name, dest.coordinate))))
    }

    /// Posted limit for the road you're on (checked every 250 m or 30 s), and one spoken warning per limit if you're
    /// more than 10% over it for 5 fixes in a row.
    private func checkSpeed(_ here: CLLocation, _ route: Route) {
        guard travel == .car, !route.beeline else { return }
        if lastLimitCheck.map({ here.distance(from: $0) > 250 || here.timestamp.timeIntervalSince($0.timestamp) > 30 }) ?? true {
            lastLimitCheck = here
            Task { @MainActor in
                do { speedLimit = try await SpeedLimit.fetch(at: here.coordinate) } catch {} // keep the last limit when offline
            }
        }
        guard let limit = speedLimit, here.speed > 0 else { return }
        speedingCount = here.speed * 3.6 > limit * 1.1 + 3 ? speedingCount + 1 : 0
        if speedingCount >= 5, warnedLimit != limit {
            warnedLimit = limit
            say(rider.slowDown(Guide.speed(limit / 3.6)))
        }
    }

    private func noteFamousRoad(_ text: String) {
        guard let road = Achievement.famousRoad(in: text), famousRoads.insert(road).inserted else { return }
        UserDefaults.standard.set(Array(famousRoads), forKey: "famousRoads")
        checkAchievements()
    }

    /// "flyover" / "bridge" when a step crosses one: from Apple's wording, else from the map tiles
    /// (OpenMapTiles `brunnel`) along the start of the step, but only on a road with the same name as
    /// the instruction, so a flyover passing overhead isn't mistaken for the one you take.
    func crossing(_ step: Route.Step) -> String? {
        let text = step.instructions.lowercased()
        if let word = Guide.crossingWord(in: text) { return word }
        guard let map, let road = text.components(separatedBy: " onto ").dropFirst().first, !road.isEmpty else { return nil }
        for c in step.coordinates.prefix(8) {
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

    // MARK: Explorer: fog, trips, discoveries, achievements

    private func explore(_ here: CLLocation) {
        guard here.horizontalAccuracy >= 0, here.horizontalAccuracy < 80, explorer.visit(here.coordinate) else { return }
        unsavedCells += 1
        if unsavedCells >= 5 { persist() }
    }

    /// Saves what's only kept in memory between fixes. Called every few new cells and when the app goes to the background.
    func persist() {
        unsavedCells = 0
        Store.save(explorer, "explorer.json")
        checkAchievements()
    }

    private func log(_ trip: Trip) {
        trips.insert(trip, at: 0)
        Store.save(trips, "trips.json")
        checkAchievements()
        // shortcut: anything averaging over 25 km/h counts as a drive (a bus ride would too); use CMMotionActivity if that annoys.
        if let end = trip.coordinates.last, trip.distance / max(trip.end.timeIntervalSince(trip.start), 1) > 7 { park(at: end) }
        guard trip.name == "Free ride", let end = trip.coordinates.last else { return }
        // Name free rides after where they ended, e.g. "Ride to Indiranagar".
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: end.latitude, longitude: end.longitude)) { [weak self] marks, _ in
            guard let self, let mark = marks?.first, let place = mark.subLocality ?? mark.locality ?? mark.name,
                  let i = trips.firstIndex(where: { $0.id == trip.id }) else { return }
            trips[i].name = "Ride to \(place)"
            Store.save(trips, "trips.json")
        }
    }

    func deleteTrips(at offsets: IndexSet) {
        trips.remove(atOffsets: offsets)
        Store.save(trips, "trips.json")
    }

    func showTrail(_ trip: Trip?) {
        shownTrip = trip
        drawRoute()
        guard let coords = trip?.coordinates, coords.count > 1 else { return }
        map?.setVisibleCoordinates(coords, count: UInt(coords.count),
                                   edgePadding: UIEdgeInsets(top: 160, left: 40, bottom: 200, right: 40), animated: true)
    }

    /// Looks for parks, historic sites, scenic spots and trails within 3 km, each time you've moved 1.5 km.
    private func scout(_ here: CLLocation) {
        guard lastScout.map({ here.distance(from: $0) > 1500 }) ?? true else { return }
        lastScout = here
        let categories = Discovery.categories
        Task { @MainActor in
            let request = MKLocalPointsOfInterestRequest(center: here.coordinate, radius: 3000)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: Array(categories.keys))
            guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return }
            let found = discoveries.filter { $0.found != nil }
            var seen = Set(found.map(\.id))
            let near = items.compactMap { item -> Discovery? in
                guard let name = item.name, let kind = item.pointOfInterestCategory.flatMap({ categories[$0] }) else { return nil }
                let c = item.placemark.coordinate
                let d = Discovery(name: name, lat: c.latitude, lon: c.longitude, kind: kind)
                return seen.insert(d.id).inserted ? d : nil
            }
            discoveries = found + near.prefix(15)
        }
    }

    /// Collects an undiscovered place once you're close to it.
    private func collect(_ here: CLLocation) {
        let reach: CLLocationDistance = travel == .car && navigating ? 150 : 80
        guard here.horizontalAccuracy >= 0, here.horizontalAccuracy < reach,
              let i = discoveries.firstIndex(where: {
                  $0.found == nil && here.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon)) < reach
              }) else { return }
        discoveries[i].found = Date()
        let found = discoveries.filter { $0.found != nil }
        Store.save(found, "discoveries.json")
        banner = "Discovered \(discoveries[i].name)! \(found.count) found so far."
        if !navigating || (nextTurnDistance ?? .infinity) > 500 { say(rider.discovered(discoveries[i].name)) } // never talk over a turn
        checkAchievements()
    }

    /// The last 7 days, for the Journal's logbook.
    var weekSummary: String {
        let since = Date().addingTimeInterval(-7 * 86400)
        let week = trips.filter { $0.start > since }
        let distance = week.reduce(0) { $0 + $1.distance }
        let time = week.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let found = discoveries.filter { ($0.found ?? .distantPast) > since }.count
        return "This week: \(Guide.distance(distance)) over \(week.count) ride\(week.count == 1 ? "" : "s"), "
            + "\(Guide.duration(time)) on the road, \(found) new discover\(found == 1 ? "y" : "ies")"
    }

    var stats: Stats {
        Stats(distance: trips.reduce(0) { $0 + $1.distance }, trips: trips.count,
              found: Dictionary(grouping: discoveries.filter { $0.found != nil }, by: \.kind).mapValues(\.count),
              area: explorer.area, waypoints: waypoints.count, hasHome: waypoints.contains { $0.kind == .home },
              famousRoads: famousRoads)
    }

    func checkAchievements() {
        let s = stats
        let new = Achievement.all.filter { earned[$0.id] == nil && $0.earned(s) }
        guard let first = new.first else { return }
        for a in new { earned[a.id] = Date() }
        Store.save(earned, "achievements.json")
        banner = "Achievement unlocked: " + new.map(\.title).joined(separator: ", ")
        if !navigating { say(rider.achievement(first.title)) }
    }

    /// Privacy: wipes every trace of where you've been. Waypoints you made yourself stay.
    func eraseHistory() {
        trips = []
        explorer.erase()
        discoveries = []
        earned = [:]
        recents = []
        famousRoads = []
        shownTrip = nil
        UserDefaults.standard.removeObject(forKey: "famousRoads")
        for file in ["trips.json", "explorer.json", "discoveries.json", "achievements.json"] {
            try? FileManager.default.removeItem(at: Store.url(file))
        }
        drawRoute()
        banner = "History erased. Only your waypoints are left."
    }

    // MARK: Trip assistant

    /// "Plan a 3-hour drive with a lunch stop and a lookout point", "find a quiet coffee shop on my way to work".
    @MainActor
    func ask(_ text: String) async {
        guard let here else {
            banner = "Need your location to plan a trip."
            return
        }
        banner = "The guide's thinking…"
        var request = await TripRequest.understand(text) ?? TripRequest.parse(text)
        if let how = TripRequest.parse(text).travel { travel = how }
        let named = TripRequest.addedPlace(text)
        if route != nil, request.destination == nil, request.hours == nil {
            // Mid-trip: "find gas on my way", "add a coffee stop", "add a Tim Hortons stop".
            if !request.stops.isEmpty {
                for stop in request.stops { await addAlongRoute(stop) }
                return
            }
            if let named { return await addAlongRoute(named: named) }
        }
        if let named, request.destination == nil, request.stops.isEmpty { request.destination = named }
        var wanted = request.stops
        var end: Destination
        var after: [Destination] = [] // stops after the far point of a round trip
        if let place = request.destination {
            guard let found = await resolve(place, near: here) else { return }
            end = found
        } else if let hours = request.hours {
            // Round trip: out to a turnaround about a third of the time away (the rest is the way back and the stops).
            let speed: Double = [Travel.car: 12, .walk: 1.2, .bike: 4][travel]!
            let reach = hours * 3600 * speed * 0.35
            let kind: TripRequest.Stop = wanted.contains(.history) ? .history : wanted.contains(.park) ? .park : .lookout
            guard let turn = await findPlace(kind, near: here.coordinate, radius: reach, preferDistance: reach) else {
                banner = "Couldn't find anywhere worth riding to in that time."
                return
            }
            end = turn
            wanted.removeAll { $0 == kind }
            if wanted.contains(.food), let food = await findPlace(.food, near: turn.coordinate, radius: 3000) {
                after.append(food) // eat at the far end
                wanted.removeAll { $0 == .food }
            }
            after.append(Destination(name: "where you started", coordinate: here.coordinate))
        } else if let first = wanted.first {
            guard let found = await findPlace(first, near: here.coordinate, radius: 5000) else {
                banner = "No \(first.title) within 5 km."
                return
            }
            end = Destination(name: found.name, coordinate: found.coordinate)
            wanted.removeFirst()
        } else {
            banner = "Tell me where to, or how long a ride. Try \"plan a 2-hour drive with a lunch stop\"."
            return
        }

        // Spread the other stops along the way there, each the nearest match to its share of the route.
        let path = (try? await routes(from: here.coordinate, through: [end], alternates: false).first?.coordinates)
            ?? [here.coordinate, end.coordinate]
        let marks = path.sampled(wanted.count + 2)
        var along: [Destination] = []
        for (i, stop) in wanted.enumerated() {
            if let found = await findPlace(stop, near: marks[i + 1], radius: 3000) { along.append(found) }
        }
        stops = along + [end] + after
        await plan()
        guard let route, !route.beeline else { return }
        let names = route.stops.map(\.name)
        let lower = text.lowercased()
        var line = "Here's the plan: \(ListFormatter.localizedString(byJoining: names)). About \(Guide.duration(route.totalTime, spoken: true)) all told."
        if lower.contains("traffic") || lower.contains("how long") {
            let arrive = Date().addingTimeInterval(route.totalTime).formatted(date: .omitted, time: .shortened)
            line = "About \(Guide.duration(route.totalTime, spoken: true)) to \(end.name) in today's traffic. You'd get there around \(arrive)."
        }
        if text.lowercased().contains("quiet") { line += " Can't promise how quiet it is, mind." }
        if along.count < wanted.count { line += " Couldn't find every stop you asked for." }
        banner = nil
        say(line)
    }

    /// Adds fuel, food or the like near the halfway point of the current route.
    @MainActor
    func addAlongRoute(_ stop: TripRequest.Stop) async {
        guard let route else { return }
        let point = route.coordinates.sampled(3)[1]
        guard let found = await findPlace(stop, near: point, radius: 3000) else {
            banner = "No \(stop.title) near the halfway point."
            return
        }
        await addStop(found.name, at: found.coordinate, stay: found.stay)
        say("Added \(found.name) to the trip.")
    }

    /// A particular place or chain, e.g. "Tim Hortons": the match closest to the route, if within 3 km of it.
    @MainActor
    func addAlongRoute(named name: String) async {
        guard let route else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        let lats = route.coordinates.map(\.latitude), lons = route.coordinates.map(\.longitude)
        if let south = lats.min(), let north = lats.max(), let west = lons.min(), let east = lons.max() {
            request.region = MKCoordinateRegion(center: .init(latitude: (south + north) / 2, longitude: (west + east) / 2),
                                                span: .init(latitudeDelta: north - south + 0.05, longitudeDelta: east - west + 0.05))
        }
        let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        let off = { (item: MKMapItem) in Geo.distance(from: item.placemark.coordinate, toPath: route.coordinates) }
        guard let pick = items.min(by: { off($0) < off($1) }), off(pick) < 3000 else {
            banner = "No \(name) within 3 km of your route."
            return
        }
        await addStop(pick.name ?? name, at: pick.placemark.coordinate)
        say("Added \(pick.name ?? name) to the trip.")
    }

    // MARK: Commute

    /// "Leave by 8:12" alerts on the next 5 weekdays, from Home to Work, timed with Apple's predicted traffic
    /// for arriving at `arriveAt`. shortcut: refreshed only when the app is opened or closed (no background
    /// refresh task), so a week without opening the app means no alerts; add BGAppRefreshTask if that matters.
    @MainActor
    func scheduleCommute(force: Bool = false) async {
        guard force || Date().timeIntervalSince(commuteScheduled) > 3600 else { return }
        commuteScheduled = Date()
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: (0..<8).map { "commute\($0)" })
        guard commute else { return }
        guard let home = waypoints.first(where: { $0.kind == .home }), let work = waypoints.first(where: { $0.kind == .work }) else {
            banner = "Leave-by alerts need a Home pin and a Work pin. Long-press each spot on the map."
            return
        }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
            banner = "Notifications are off for Frontier Map. Turn them on in Settings to get leave-by alerts."
            return
        }
        let calendar = Calendar.current
        var planned = 0
        for day in 0..<8 where planned < 5 {
            guard let date = calendar.date(byAdding: .day, value: day, to: Date()), !calendar.isDateInWeekend(date),
                  let arrive = calendar.date(bySettingHour: arriveAt / 60, minute: arriveAt % 60, second: 0, of: date),
                  arrive > Date() else { continue }
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: home.coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: work.coordinate))
            request.transportType = .automobile
            request.arrivalDate = arrive
            avoid(request)
            guard let eta = try? await MKDirections(request: request).calculateETA() else { continue }
            let alert = eta.expectedDepartureDate.addingTimeInterval(-10 * 60) // ten minutes' warning
            guard alert > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Leave by \(eta.expectedDepartureDate.formatted(date: .omitted, time: .shortened))"
            content.body = "About \(Guide.duration(eta.expectedTravelTime)) to \(work.name) in expected traffic, to arrive by \(arrive.formatted(date: .omitted, time: .shortened))."
            content.sound = .default
            let when = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: alert)
            try? await center.add(UNNotificationRequest(identifier: "commute\(planned)", content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
            planned += 1
        }
    }

    @MainActor
    private func resolve(_ place: String, near here: CLLocation) async -> Destination? {
        if place == "home" || place == "work" {
            let kind: Waypoint.Kind = place == "home" ? .home : .work
            guard let w = waypoints.first(where: { $0.kind == kind }) else {
                banner = "No \(place) pin yet. Long-press the spot and pick the \(kind.label) pin."
                return nil
            }
            return Destination(name: w.name, coordinate: w.coordinate)
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place
        request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 100_000, longitudinalMeters: 100_000)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else {
            banner = "Couldn't find \(place)."
            return nil
        }
        return Destination(name: item.name ?? place, coordinate: item.placemark.coordinate)
    }

    /// The place of a kind nearest to `preferDistance` from `c` (0: simply the nearest).
    private func findPlace(_ stop: TripRequest.Stop, near c: CLLocationCoordinate2D, radius: CLLocationDistance,
                           preferDistance: CLLocationDistance = 0) async -> Destination? {
        let request = MKLocalPointsOfInterestRequest(center: c, radius: min(radius, 50_000))
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: stop.categories)
        let center = CLLocation(latitude: c.latitude, longitude: c.longitude)
        let off = { (item: MKMapItem) in abs(center.distance(from: item.placemark.location ?? center) - preferDistance) }
        guard let pick = (try? await MKLocalSearch(request: request).start())?.mapItems.min(by: { off($0) < off($1) }) else { return nil }
        return Destination(name: pick.name ?? stop.title, coordinate: pick.placemark.coordinate, stay: stop.stay)
    }

    // MARK: Search, nearby, weather, offline

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

    /// Where searches look first: around you, else around the middle of the map.
    var searchRegion: MKCoordinateRegion? {
        guard let c = here?.coordinate ?? map?.centerCoordinate else { return nil }
        return MKCoordinateRegion(center: c, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
    }

    @MainActor
    func search(_ text: String) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        await search(request)
    }

    /// A tapped autocomplete suggestion.
    @MainActor
    func search(_ completion: MKLocalSearchCompletion) async {
        await search(MKLocalSearch.Request(completion: completion))
    }

    @MainActor
    private func search(_ request: MKLocalSearch.Request) async {
        resultKind = nil
        if let region = searchRegion { request.region = region }
        let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        if items.count == 1 {
            results = []
            show(place: items[0])
        } else {
            results = Array(items.prefix(8))
        }
        if items.isEmpty { banner = "No trail leads there. (Search needs a connection.)" }
    }

    /// Downloads what's on screen plus three zoom levels deeper, in the current map style.
    func saveVisibleArea() {
        guard let map, let style = map.styleURL else { return }
        let region = MLNTilePyramidOfflineRegion(styleURL: style, bounds: map.visibleCoordinateBounds,
                                                 fromZoomLevel: map.zoomLevel,
                                                 toZoomLevel: min(map.zoomLevel + 3, 15))
        let name = "\(skin.label) map, saved \(Date().formatted(date: .abbreviated, time: .omitted))"
        MLNOfflineStorage.shared.addPack(for: region, withContext: Data(name.utf8)) { [weak self] pack, error in
            if let error { self?.banner = "Offline save failed: \(error.localizedDescription)" } else { pack?.resume() }
        }
    }

    func deleteOfflineAreas() {
        MLNOfflineStorage.shared.packs?.forEach { MLNOfflineStorage.shared.removePack($0, withCompletionHandler: nil) }
        banner = "Offline areas deleted."
    }
}

/// Keeps turn-by-turn going with the screen locked or another app open: MapLibre only reports
/// location while the map is on screen.
final class BackgroundLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onUpdate: (CLLocation) -> Void = { _ in }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
    }

    func start() {
        manager.allowsBackgroundLocationUpdates = true // needs UIBackgroundModes "location" (project.yml)
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // In the foreground the map delivers the same fixes; don't count them twice.
        guard UIApplication.shared.applicationState != .active, let last = locations.last else { return }
        onUpdate(last)
    }
}
