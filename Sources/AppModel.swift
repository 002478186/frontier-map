import SwiftUI
import MapKit
import MapLibre

final class AppModel: ObservableObject {
    @Published var waypoints = Waypoint.load() { didSet { Waypoint.save(waypoints) } }
    @Published var pendingPin: CLLocationCoordinate2D?
    @Published var results: [MKMapItem] = []
    @Published var banner: String?
    weak var map: MLNMapView?
    private let guide = Guide()

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
