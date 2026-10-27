import SwiftUI
import MapKit

extension Color {
    /// Paper and ink; at night the paper goes dark and the ink light.
    static let parchment = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.17, green: 0.14, blue: 0.11, alpha: 1) : UIColor(red: 0.91, green: 0.84, blue: 0.69, alpha: 1) })
    static let ink = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.91, green: 0.84, blue: 0.69, alpha: 1) : UIColor(red: 0.23, green: 0.15, blue: 0.09, alpha: 1) })
}

extension Font {
    /// Chinese Rocks by Ray Larabie (freeware, licence in Sources/Fonts), a touch larger since it's condensed.
    static func frontier(_ size: CGFloat) -> Font { .custom("ChineseRocks", size: size * 1.15, relativeTo: .body) }
}

/// Search-as-you-type suggestions from Apple Maps.
final class Completer: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    func update(_ text: String, region: MKCoordinateRegion?) {
        if let region { completer.region = region }
        if text.isEmpty { suggestions = [] } else { completer.queryFragment = text }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.queryFragment.isEmpty ? [] : Array(completer.results.prefix(6))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { suggestions = [] }
}

struct ContentView: View {
    enum Sheet: String, Identifiable {
        case journal, turns, layers, ask, stops, elevation
        var id: String { rawValue }
    }

    @StateObject private var model = AppModel()
    @StateObject private var completer = Completer()
    @State private var query = ""
    @FocusState private var searching: Bool
    @State private var sheet: Sheet?
    @State private var editNext: Waypoint? // opened once the sheet in the way has closed
    @State private var moreOpen = false     // the drive bar's extra buttons
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            MapView(model: model).ignoresSafeArea()
            if !model.drivingClear { // fog and vignette step aside while driving, for readability
                if model.fog { FogView(model: model, tick: model.camera).ignoresSafeArea() }
                // Aged-paper vignette; decorative, so taps pass through.
                RadialGradient(colors: [.clear, .ink.opacity(0.3)], center: .center, startRadius: 180, endRadius: 650)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            VStack(spacing: 8) {
                if let turn = model.nextTurn { turnBanner(turn) } else { searchBar }
                if !model.navigating && model.results.isEmpty && !searching { findsBar }
                if !MapStyle.hasKey { note("No MapTiler key set. See README, \"Configure the key\".") }
                if let banner = model.banner { note(banner).onTapGesture { model.banner = nil } }
                HStack(alignment: .top) {
                    if !model.navigating, let weather = model.weather {
                        Button { model.say(weather.spoken()) } label: { note(weather.chip()) }
                            .accessibilityHint("Speaks the weather")
                    }
                    Spacer()
                    CompassRose(direction: model.mapDirection) { model.map?.resetNorth() }
                }
                Spacer()
                if model.navigating && !model.following {
                    Button { model.recenter() } label: {
                        Label("Re-center", systemImage: "location.fill").font(.frontier(17)).padding(.horizontal, 18).padding(.vertical, 10)
                    }
                    .foregroundStyle(Color.parchment)
                    .background(Color.ink, in: Capsule())
                }
                if model.navigating { driveBar } else {
                    if model.route != nil { routePanel }
                    HStack(spacing: 16) {
                        tool("location.north.line.fill", "Follow me") { model.followMe() }
                        tool("book.closed.fill", "Journal") { sheet = .journal }
                        tool("wand.and.stars", "Ask the guide to plan a trip") { sheet = .ask }
                        tool("square.3.layers.3d", "Map style, fog and offline maps") { sheet = .layers }
                    }
                }
            }
            .padding()
        }
        .preferredColorScheme(model.colorScheme)
        .onChange(of: phase) {
            if $0 != .active { model.persist() }
            Task { await model.scheduleCommute() }
        }
        .sheet(item: $model.editing) { w in PinEditor(model: model, waypoint: w) }
        .sheet(isPresented: Binding(get: { model.place != nil }, set: { if !$0 { model.place = nil } }), onDismiss: openNext) {
            if let item = model.place { PlaceSheet(model: model, item: item) { editNext = $0 } }
        }
        .sheet(item: $sheet, onDismiss: openNext) { s in
            switch s {
            case .journal: Journal(model: model) { editNext = $0 }
            case .turns: Turns(model: model)
            case .layers: Layers(model: model)
            case .ask: AskGuide(model: model)
            case .stops: Stops(model: model)
            case .elevation: ElevationSheet(model: model)
            }
        }
    }

    private func openNext() {
        guard let w = editNext else { return }
        editNext = nil
        model.editing = w
    }

    private func turnBanner(_ turn: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Guide.maneuverSymbol(turn)).font(.system(size: 40, weight: .bold)).frame(width: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let d = model.nextTurnDistance { Text("In \(Guide.distance(d))").font(.frontier(15)) }
                Text(turn).font(.frontier(22)).fixedSize(horizontal: false, vertical: true)
                if let crossing = model.nextCrossing {
                    Label("Take the \(crossing)", systemImage: "road.lanes").font(.frontier(16))
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                if let limit = model.speedLimit { SpeedSign(kmh: limit) }
                if let speed = model.speed { Text(Guide.speed(speed)).font(.frontier(15)) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .foregroundStyle(Color.parchment)
        .background(Color.ink, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var etaText: String {
        guard let route = model.route, let dest = model.destination else { return "" }
        let arrive = Date().addingTimeInterval(model.remaining?.time ?? route.totalTime).formatted(date: .omitted, time: .shortened)
        return "Heading to \(dest.name), arriving around \(arrive). \(mapsLink(dest.name, dest.coordinate).absoluteString)"
    }

    /// While navigating: arrival time and what's left, counting down, with End and the co-pilot to hand.
    private var driveBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { withAnimation { moreOpen.toggle() } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        if let left = model.remaining {
                            Text(Date().addingTimeInterval(left.time).formatted(date: .omitted, time: .shortened)).font(.frontier(26))
                            Text("\(Guide.duration(left.time)) · \(Guide.distance(left.distance))").font(.frontier(15))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Arrival and time left. Tap for turns, stops and sharing.")
                Button { sheet = .ask } label: {
                    Image(systemName: "mic.fill").font(.title2).frame(width: 52, height: 52)
                }
                .background(Color.ink.opacity(0.12), in: Circle())
                .accessibilityLabel("Ask the guide")
                Button { model.endRoute() } label: {
                    Text("End").font(.frontier(20)).padding(.horizontal, 20).frame(height: 52)
                }
                .foregroundStyle(.white)
                .background(Color.red, in: Capsule())
            }
            if moreOpen {
                HStack(spacing: 0) {
                    mini("list.bullet", "Turns") { sheet = .turns }
                    mini("mappin.and.ellipse", "Stops") { sheet = .stops }
                    mini("chart.xyaxis.line", "Elevation") { sheet = .elevation }
                    ShareLink(item: etaText) { miniLabel("square.and.arrow.up", "Share ETA") }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .foregroundStyle(Color.ink)
        .background(Color.parchment, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.ink, lineWidth: 1.5))
    }

    private var routePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let route = model.route {
                let stops = model.stops.count - 1
                Text("To \(model.destination?.name ?? "destination")" + (stops > 0 ? " · \(stops) stop\(stops == 1 ? "" : "s")" : ""))
                    .font(.frontier(18)).lineLimit(2)
                Text("\(Guide.duration(route.totalTime)) · \(Guide.distance(route.distance)) · arrive "
                     + Date().addingTimeInterval(route.totalTime).formatted(date: .omitted, time: .shortened))
                    .font(.frontier(15))
                if route.beeline { Text("Straight line: no road data. The guide calls out the bearing.").font(.caption) }
                else if model.travel == .car {
                    Text("Time includes current traffic (Apple Maps)"
                         + (model.avoidTolls ? " · no tolls" : "") + (model.avoidHighways ? " · no highways" : "")).font(.caption)
                }
                else if model.travel == .bike { Text("Bike time estimated at 16 km/h on walking paths").font(.caption) }
                if !model.navigating && model.alternatives.count > 1 {
                    ForEach(Array(model.alternatives.enumerated()), id: \.offset) { i, alt in
                        Button { model.select(i, overview: true) } label: {
                            HStack {
                                Image(systemName: i == model.selected ? "largecircle.fill.circle" : "circle")
                                Text((alt.name.isEmpty ? "Route \(i + 1)" : alt.name) + (i == 0 ? " · fastest" : "")).lineLimit(1)
                                Spacer()
                                Text("\(Guide.duration(alt.totalTime)) · \(Guide.distance(alt.distance))")
                            }
                            .font(.frontier(14))
                        }
                        .accessibilityAddTraits(i == model.selected ? .isSelected : [])
                    }
                }
                if !model.navigating, let transit = model.transitTime {
                    Button { model.openTransitInMaps() } label: {
                        Label("Transit about \(Guide.duration(transit)) · open in Apple Maps", systemImage: "tram.fill").font(.frontier(14))
                    }
                }
            }
            Picker("Travel by", selection: Binding(get: { model.travel }, set: { model.setTravel($0) })) {
                ForEach(Travel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if !model.navigating {
                Button { model.go() } label: {
                    Label("Start", systemImage: "location.north.fill")
                        .font(.frontier(20))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .foregroundStyle(Color.parchment)
                .background(Color.ink, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 0) {
                mini("list.bullet", "Turns") { sheet = .turns }
                mini("mappin.and.ellipse", "Stops") { sheet = .stops }
                if !model.navigating && model.stops.count == 1 && model.route?.beeline == false {
                    mini("leaf.fill", "Scenic") { Task { await model.scenic() } }
                }
                mini("chart.xyaxis.line", "Elevation") { sheet = .elevation }
                ShareLink(item: etaText) { miniLabel("square.and.arrow.up", "Share") }
                    .frame(maxWidth: .infinity)
                mini("xmark.circle.fill", "End") { model.endRoute() }
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .foregroundStyle(Color.ink)
        .background(Color.parchment, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.ink, lineWidth: 1.5))
    }

    private func mini(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { miniLabel(icon, label) }.frame(maxWidth: .infinity)
    }

    private func miniLabel(_ icon: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 18))
            Text(label).font(.frontier(11))
        }
        .frame(minHeight: 44)
    }

    /// One-tap searches for what's around: saloons, grub, stores, doctors, fuel, lodging, camps.
    private var findsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Waypoint.Kind.finds) { find in
                    Button { Task { await model.nearby(find.kind) } } label: {
                        HStack(spacing: 4) {
                            Image(uiImage: Markers.pin(find.kind)).resizable().frame(width: 12, height: 31)
                                .frame(height: 16, alignment: .top).clipped()
                            Text(find.title).font(.frontier(14))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    .foregroundStyle(Color.ink)
                    .background(Color.parchment, in: Capsule())
                    .overlay(Capsule().stroke(Color.ink, lineWidth: 1))
                    .accessibilityLabel("Nearby \(find.title)")
                }
            }
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Search the world…", text: $query)
                    .font(.frontier(17))
                    .focused($searching)
                    .submitLabel(.search)
                    .onSubmit { Task { await model.search(query) } }
                    .onChange(of: query) { completer.update($0, region: model.searchRegion) }
                if !query.isEmpty || !model.results.isEmpty {
                    Button {
                        query = ""
                        model.results = []
                        searching = false
                    } label: { Image(systemName: "xmark.circle.fill").frame(width: 32, height: 32) }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if searching && query.isEmpty {
                savedPlaces
            } else if searching && !completer.suggestions.isEmpty {
                ForEach(completer.suggestions, id: \.self) { s in
                    Divider()
                    row(s.title, s.subtitle, icon: "magnifyingglass") {
                        query = s.title
                        searching = false
                        Task { await model.search(s) }
                    }
                }
            } else {
                ForEach(model.results, id: \.self) { item in
                    Divider()
                    HStack {
                        row(item.name ?? "Unknown place", item.placemark.title ?? "", icon: nil) {
                            searching = false
                            model.show(place: item)
                        }
                        Button {
                            model.results = []
                            Task { await model.directions(to: item.name ?? "there", at: item.placemark.coordinate) }
                        } label: {
                            Image(systemName: "car.fill").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Directions to \(item.name ?? "this place")")
                    }
                }
            }
        }
        .foregroundStyle(Color.ink)
        .background(Color.parchment, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.ink, lineWidth: 1.5))
    }

    /// Home, Work and recent places, shown when the search box is empty.
    private var savedPlaces: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                ForEach([Waypoint.Kind.home, .work]) { kind in
                    Button {
                        searching = false
                        if let w = model.waypoints.first(where: { $0.kind == kind }) {
                            Task { await model.directions(to: w.name, at: w.coordinate) }
                        } else {
                            model.banner = "No \(kind.label) pin yet. Long-press the spot on the map and pick the \(kind.label) pin."
                        }
                    } label: {
                        Label(kind.label, systemImage: kind.symbol).font(.frontier(15)).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .overlay(Capsule().stroke(Color.ink, lineWidth: 1))
                }
            }
            .padding(10)
            ForEach(model.waypoints.filter { $0.kind == .parked }) { w in
                Divider()
                row("Parked car", "Walk back to it", icon: "car.fill") {
                    searching = false
                    model.travel = .walk
                    Task { await model.directions(to: w.name, at: w.coordinate) }
                }
            }
            ForEach(model.waypoints.filter(\.favorite)) { w in
                Divider()
                row(w.name, "Favorite", icon: "star.fill") {
                    searching = false
                    Task { await model.directions(to: w.name, at: w.coordinate) }
                }
            }
            ForEach(model.recents) { w in
                Divider()
                row(w.name, "Recent", icon: "clock") {
                    searching = false
                    Task { await model.directions(to: w.name, at: w.coordinate) }
                }
            }
        }
    }

    private func row(_ title: String, _ subtitle: String, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).frame(width: 20).accessibilityHidden(true) }
                VStack(alignment: .leading) {
                    Text(title).font(.frontier(15))
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).lineLimit(1) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.frontier(14))
            .foregroundStyle(Color.ink)
            .padding(8)
            .background(Color.parchment.opacity(0.95), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tool(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2).frame(width: 52, height: 52)
        }
        .foregroundStyle(Color.ink)
        .background(Color.parchment, in: Circle())
        .overlay(Circle().stroke(Color.ink, lineWidth: 1.5))
        .accessibilityLabel(label)
    }
}
