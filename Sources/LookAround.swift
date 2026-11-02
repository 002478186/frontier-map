import MapKit
import SwiftUI

/// Street-level photos of a place: Apple's Look Around where Apple has driven, otherwise a button that opens
/// Google Street View (Google's public Maps URL, no key) at the same spot. Tap the photo to look around full screen.
struct LookAround: View {
    let coordinate: CLLocationCoordinate2D
    var item: MKMapItem?
    @State private var scene: MKLookAroundScene?
    @State private var checked = false

    var body: some View {
        Group {
            if let scene {
                LookAroundCard(scene: scene)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Street-level photo. Tap to look around.")
            } else if checked {
                Link(destination: Self.streetView(coordinate)) {
                    Label("No Apple Look Around here. Open Street View", systemImage: "binoculars.fill")
                }
            } else {
                HStack { ProgressView(); Text("Looking for street photos…").font(.caption) }
            }
        }
        .task(id: "\(coordinate.latitude),\(coordinate.longitude)") {
            let request = item.map { MKLookAroundSceneRequest(mapItem: $0) } ?? MKLookAroundSceneRequest(coordinate: coordinate)
            scene = try? await request.scene
            if scene == nil, item != nil { scene = try? await MKLookAroundSceneRequest(coordinate: coordinate).scene }
            checked = true
        }
    }

    /// https://developers.google.com/maps/documentation/urls/get-started#street-view-action
    static func streetView(_ c: CLLocationCoordinate2D) -> URL {
        var url = URLComponents(string: "https://www.google.com/maps/@")!
        url.queryItems = [.init(name: "api", value: "1"), .init(name: "map_action", value: "pano"),
                          .init(name: "viewpoint", value: String(format: "%.6f,%.6f", c.latitude, c.longitude))]
        return url.url!
    }
}

private struct LookAroundCard: UIViewControllerRepresentable {
    let scene: MKLookAroundScene
    func makeUIViewController(context: Context) -> MKLookAroundViewController {
        let controller = MKLookAroundViewController(scene: scene)
        controller.badgePosition = .bottomTrailing
        return controller
    }
    func updateUIViewController(_ controller: MKLookAroundViewController, context: Context) { controller.scene = scene }
}
