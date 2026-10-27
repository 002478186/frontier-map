import SwiftUI
import MapKit
import MapLibre
import PhotosUI
import Charts

/// Name, kind, notes and a photo for a waypoint; new pins and existing ones.
struct PinEditor: View {
    @ObservedObject var model: AppModel
    @State var waypoint: Waypoint
    @State private var pick: PhotosPickerItem?
    @Environment(\.dismiss) private var dismiss
    private var isNew: Bool { !model.waypoints.contains { $0.id == waypoint.id } }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Camp, creek, ranch…", text: $waypoint.name).font(.frontier(17))
                Toggle("Favorite: show in the search box", isOn: $waypoint.favorite)
                Section("Kind") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(Waypoint.Kind.allCases) { k in
                            Button { waypoint.kind = k } label: {
                                Image(uiImage: Markers.pin(k))
                                    .frame(width: 34, height: 44, alignment: .top)
                                    .clipped() // show the pin, not its transparent lower half
                                    .padding(4)
                                    .background(waypoint.kind == k ? Color.ink.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(k.label)
                            .accessibilityAddTraits(waypoint.kind == k ? .isSelected : [])
                        }
                    }
                }
                Section("Notes") {
                    TextField("Best sunset view here…", text: $waypoint.note, axis: .vertical).lineLimit(2...6)
                }
                Section("Photo") {
                    if let url = waypoint.photoURL, let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                            .accessibilityLabel("Photo of \(waypoint.name)")
                    }
                    PhotosPicker(selection: $pick, matching: .images) {
                        Label(waypoint.photo == nil ? "Add a photo" : "Change photo", systemImage: "photo")
                    }
                }
                if !isNew {
                    Section {
                        ShareLink(item: mapsLink(waypoint.name, waypoint.coordinate)) { Label("Share this place", systemImage: "square.and.arrow.up") }
                        Button("Delete waypoint", role: .destructive) {
                            model.delete(waypoint)
                            dismiss()
                        }
                    }
                }
            }
            .foregroundStyle(Color.ink)
            .scrollContentBackground(.hidden)
            .background(Color.parchment)
            .navigationTitle(isNew ? "New waypoint" : "Waypoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.save(waypoint)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: pick) { item in Task { await attach(item) } }
    }

    /// Stores the picked photo (scaled down to 1600 px) next to the app's other data.
    private func attach(_ item: PhotosPickerItem?) async {
        guard let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let small = image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
        guard let jpeg = small.jpegData(compressionQuality: 0.75) else { return }
        let name = "\(UUID().uuidString).jpg"
        try? FileManager.default.createDirectory(at: Waypoint.photos, withIntermediateDirectories: true)
        guard (try? jpeg.write(to: Waypoint.photos.appendingPathComponent(name))) != nil else { return }
        await MainActor.run {
            if let old = waypoint.photoURL { try? FileManager.default.removeItem(at: old) }
            waypoint.photo = name
        }
    }
}

/// A place from search: details, actions, and Apple's own place card (hours, photos, ratings) on iOS 18+.
struct PlaceSheet: View {
    @ObservedObject var model: AppModel
    let item: MKMapItem
    let edit: (Waypoint) -> Void
    @Environment(\.dismiss) private var dismiss

    private var name: String { item.name ?? "Unknown place" }
    private var coordinate: CLLocationCoordinate2D { item.placemark.coordinate }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(name).font(.frontier(24))
                    if let category = item.pointOfInterestCategory { Text(category.label).font(.caption) }
                    if let address = item.placemark.title { Text(address).font(.frontier(15)) }
                    if let here = model.here { Text(Guide.heading(from: here, to: Waypoint(name, coordinate)) + " as the crow flies").font(.caption) }
                    HStack(spacing: 8) {
                        action("car.fill", "Directions") {
                            dismiss()
                            Task { await model.directions(to: name, at: coordinate) }
                        }
                        if model.route != nil {
                            action("plus.circle.fill", "Add stop") {
                                dismiss()
                                Task { await model.addStop(name, at: coordinate) }
                            }
                        }
                        action("mappin", "Save pin") {
                            edit(Waypoint(name, coordinate, kind: Waypoint.Kind(category: item.pointOfInterestCategory)))
                            dismiss()
                        }
                        ShareLink(item: mapsLink(name, coordinate)) { label("square.and.arrow.up", "Share") }
                            .buttonStyle(.bordered)
                    }
                    if let phone = item.phoneNumber, let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
                        Link(destination: url) { Label(phone, systemImage: "phone.fill") }
                    }
                    if let url = item.url { Link(destination: url) { Label(url.host ?? "Website", systemImage: "safari") } }
                    if #available(iOS 18.0, *) {
                        PlaceCard(item: item).frame(height: 480).clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text("Opening hours, photos and ratings need iOS 18.").font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .foregroundStyle(Color.ink)
            .background(Color.parchment)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func action(_ icon: String, _ text: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { label(icon, text) }.buttonStyle(.bordered)
    }

    private func label(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
            Text(text).font(.frontier(11))
        }
        .frame(maxWidth: .infinity, minHeight: 40)
    }
}

@available(iOS 18.0, *)
private struct PlaceCard: UIViewControllerRepresentable {
    let item: MKMapItem
    func makeUIViewController(context: Context) -> MKMapItemDetailViewController {
        MKMapItemDetailViewController(mapItem: item, displaysMap: false)
    }
    func updateUIViewController(_ controller: MKMapItemDetailViewController, context: Context) {}
}

extension MKPointOfInterestCategory {
    /// "MKPOICategoryNationalPark" → "National Park".
    var label: String {
        rawValue.replacingOccurrences(of: "MKPOICategory", with: "")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }
}

/// Map style, night mode, fog of war and offline areas.
struct Layers: View {
    @ObservedObject var model: AppModel
    @State private var packs: [MLNOfflinePack] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Map") {
                    Picker("Style", selection: $model.skin) { ForEach(MapSkin.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented)
                    Text(model.skin == .frontier ? "Hand-inked parchment." : model.skin == .modern ? "Clear, everyday street map."
                         : "Contours, hiking paths and peaks for the backcountry.").font(.caption)
                }
                Section("Night mode") {
                    Picker("Night", selection: $model.nightMode) { ForEach(NightMode.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented)
                    Text("Auto goes dark after sunset, and whenever your phone is in dark mode.").font(.caption)
                }
                Section("Driving") {
                    Toggle("Avoid tolls", isOn: $model.avoidTolls)
                    Toggle("Avoid highways", isOn: $model.avoidHighways)
                    Toggle("Plain map while driving", isOn: $model.clearDriving)
                    Text("While you drive, the parchment map and fog step aside for the clear street map. Browsing and route preview keep the full frontier look.")
                        .font(.caption)
                }
                Section("Commute") {
                    Toggle("Leave-by alerts", isOn: $model.commute)
                    DatePicker("Arrive at work by", selection: Binding(
                        get: { Calendar.current.date(bySettingHour: model.arriveAt / 60, minute: model.arriveAt % 60, second: 0, of: Date()) ?? Date() },
                        set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); model.arriveAt = (c.hour ?? 9) * 60 + (c.minute ?? 0) }),
                               displayedComponents: .hourAndMinute)
                    Text("On weekdays you get \"Leave by 8:12\" ten minutes before you should go, timed from your Home pin to your Work pin with Apple's traffic forecast. Refreshed whenever you open the app.")
                        .font(.caption)
                }
                Section("Explorer") {
                    Toggle("Fog of war", isOn: $model.fog)
                    Text("Places you haven't been stay hazy and clear as you travel. \(String(format: "%.1f", model.explorer.area)) km² explored so far.")
                        .font(.caption)
                }
                Section("Offline maps") {
                    Button("Save this area") {
                        model.saveVisibleArea()
                        dismiss()
                    }
                    Text("Saves what's on screen in the current style, 3 zoom levels deeper. Heading off-grid? Save a Topo area first: with no signal, routes fall back to a straight line and the guide calls the compass bearing.")
                        .font(.caption)
                    ForEach(packs, id: \.self) { pack in
                        Text(String(decoding: pack.context, as: UTF8.self).isEmpty ? "Saved area" : String(decoding: pack.context, as: UTF8.self))
                    }
                    .onDelete { offsets in
                        offsets.map { packs[$0] }.forEach { MLNOfflineStorage.shared.removePack($0, withCompletionHandler: nil) }
                        packs.remove(atOffsets: offsets)
                    }
                }
            }
            .foregroundStyle(Color.ink)
            .scrollContentBackground(.hidden)
            .background(Color.parchment)
            .navigationTitle("Map")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { packs = MLNOfflineStorage.shared.packs ?? [] }
    }
}

/// The trip assistant: say what kind of trip you want and get a route with stops.
struct AskGuide: View {
    @ObservedObject var model: AppModel
    @StateObject private var listener = Listener()
    @Environment(\.dismiss) private var dismiss
    private var examples: [String] {
        model.route != nil ? ["Find gas on my way", "Add a coffee stop", "Add a Tim Hortons stop", "Find an EV charger on my way"] : [
        "What's the traffic like to work?",
        "Plan a 3-hour drive with a lunch stop and a lookout point",
        "Find a quiet coffee shop on my way to work",
        "Take me to the nearest park",
        "2-hour bike ride with a coffee stop",
        "Drive to the beach with a fuel stop",
    ]}
    private var text: String { listener.text }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Where to, partner?", text: $listener.text, axis: .vertical).font(.frontier(17)).lineLimit(1...4)
                        .submitLabel(.go)
                        .onSubmit(go)
                    Button { listener.toggle() } label: {
                        Label(listener.listening ? "Listening… tap to stop" : "Speak", systemImage: listener.listening ? "waveform" : "mic.fill")
                    }
                    if let problem = listener.problem { Text(problem).font(.caption) }
                    Button("Plan it", action: go).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section("Try") {
                    ForEach(examples, id: \.self) { e in
                        Button(e) {
                            listener.text = e
                            go()
                        }
                    }
                }
                Section {
                    Text("Plans use Apple Maps places and roads. On iPhones with Apple Intelligence the request is read by Apple's on-device model; otherwise by keywords. Nothing you type or say leaves the phone except the place searches.")
                        .font(.caption)
                }
            }
            .foregroundStyle(Color.ink)
            .scrollContentBackground(.hidden)
            .background(Color.parchment)
            .navigationTitle("Ask the guide")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear {
            listener.onFinish = { _ in go() }
            if model.navigating { listener.start() } // hands-free while driving
        }
        .onDisappear { listener.stop() }
    }

    private func go() {
        listener.stop()
        let request = text
        guard !request.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        dismiss()
        Task { await model.ask(request) }
    }
}

/// The road-trip planner: stops in order with arrival times, fuel and food breaks, and the whole day's estimate.
struct Stops: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Arrival time at each planned stop, counting time spent at the ones before it.
    private var arrivals: [Date]? {
        guard let route = model.route, !model.navigating, route.legTimes.count == model.stops.count else { return nil }
        var t = Date(), out: [Date] = []
        for (leg, stop) in zip(route.legTimes, model.stops) {
            t += leg
            out.append(t)
            t += stop.stay
        }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                if let route = model.route {
                    Section {
                        Text("Moving \(Guide.duration(route.expectedTravelTime)) + stops \(Guide.duration(route.totalTime - route.expectedTravelTime))")
                            .font(.frontier(16))
                        Text("\(Guide.distance(route.distance)) · back on the road for good around "
                             + Date().addingTimeInterval(route.totalTime).formatted(date: .omitted, time: .shortened)).font(.caption)
                    }
                }
                Section("Stops") {
                    ForEach(Array(model.stops.enumerated()), id: \.offset) { i, stop in
                        VStack(alignment: .leading) {
                            Text(stop.name).font(.frontier(17))
                            if let at = arrivals?[i] {
                                Text("Arrive \(at.formatted(date: .omitted, time: .shortened))"
                                     + (stop.stay > 0 && i < model.stops.count - 1 ? " · stay \(Guide.duration(stop.stay))" : ""))
                                    .font(.caption)
                            }
                        }
                    }
                    .onDelete(perform: model.removeStops)
                    .onMove(perform: model.moveStops)
                }
                Section("Add along the way") {
                    HStack {
                        add(.fuel, "fuelpump.fill", "Fuel")
                        add(.charger, "bolt.car.fill", "EV")
                        add(.food, "fork.knife", "Food")
                        add(.coffee, "cup.and.saucer.fill", "Coffee")
                        add(.lookout, "binoculars.fill", "Lookout")
                    }
                    Text("Adds the nearest one to the halfway point. To add a particular place, search for it and tap Add stop.").font(.caption)
                }
            }
            .foregroundStyle(Color.ink)
            .scrollContentBackground(.hidden)
            .background(Color.parchment)
            .navigationTitle("Trip")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func add(_ stop: TripRequest.Stop, _ icon: String, _ text: String) -> some View {
        Button { Task { await model.addAlongRoute(stop) } } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                Text(text).font(.frontier(11))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }
}

/// Height along the route, with total climb.
struct ElevationSheet: View {
    @ObservedObject var model: AppModel
    @State private var heights: [Double]?
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss
    private let metric = Locale.current.measurementSystem == .metric

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let h = heights, let lo = h.min(), let hi = h.max(), let route = model.route {
                    let climb = Elevation.climb(h)
                    let along = route.distance / 1000 / (metric ? 1 : 1.609344)
                    Chart(Array(h.enumerated()), id: \.offset) { p in
                        let x = along * Double(p.offset) / Double(max(h.count - 1, 1))
                        AreaMark(x: .value("Distance", x), yStart: .value("Base", height(lo) - 10), yEnd: .value("Height", height(p.element)))
                            .foregroundStyle(Color.ink.opacity(0.18))
                        LineMark(x: .value("Distance", x), y: .value("Height", height(p.element)))
                            .foregroundStyle(Color.ink)
                    }
                    .chartYScale(domain: height(lo) - 10 ... height(hi) + 10)
                    .chartXAxisLabel(metric ? "km" : "mi")
                    .chartYAxisLabel(metric ? "m" : "ft")
                    .frame(height: 240)
                    Text("Climb \(Int(height(climb.up))) \(metric ? "m" : "ft") · descend \(Int(height(climb.down))) \(metric ? "m" : "ft")")
                        .font(.frontier(16))
                    Text("Highest \(Int(height(hi))) \(metric ? "m" : "ft") · lowest \(Int(height(lo))) \(metric ? "m" : "ft")").font(.caption)
                    Text("Elevation data: Open-Meteo.").font(.caption2)
                } else if failed {
                    Text("Couldn't load elevation. It needs a connection.")
                } else {
                    ProgressView("Measuring the hills…")
                }
                Spacer()
            }
            .padding()
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.parchment)
            .navigationTitle("Elevation")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task {
            do { heights = try await Elevation.profile(model.route?.coordinates ?? []) } catch { failed = true }
        }
    }

    private func height(_ meters: Double) -> Double { metric ? meters : meters * 3.28084 }
}

struct Journal: View {
    @ObservedObject var model: AppModel
    let edit: (Waypoint) -> Void
    @State private var confirmErase = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let s = model.stats
                    Text("\(Guide.distance(s.distance)) ridden · \(s.trips) rides · \(s.discoveries) discoveries · \(String(format: "%.1f", s.area)) km² explored")
                        .font(.frontier(15))
                    Text(model.weekSummary).font(.caption)
                    if let here = model.here {
                        ShareLink(item: mapsLink("Where I am", here.coordinate)) { Label("Share where I am", systemImage: "location.fill") }
                    }
                }
                Section("Trail diary") {
                    if model.trips.isEmpty { Text("Rides log themselves as you travel.").font(.caption) }
                    ForEach(model.trips) { t in
                        Button {
                            dismiss()
                            model.showTrail(t)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(t.start.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                Text(t.name).font(.frontier(17))
                                Text("\(Guide.distance(t.distance)) in \(Guide.duration(t.end.timeIntervalSince(t.start)))").font(.caption)
                            }
                        }
                    }
                    .onDelete(perform: model.deleteTrips)
                    if model.shownTrip != nil { Button("Hide trail from the map") { model.showTrail(nil) } }
                }
                Section("Waypoints") {
                    if model.waypoints.isEmpty { Text("Long-press the map to drop a pin.") }
                    else { Text("Tap for directions. Swipe left to edit or delete.").font(.caption) }
                    ForEach(model.waypoints) { w in
                        Button {
                            dismiss()
                            Task { await model.directions(to: w.name, at: w.coordinate) }
                        } label: {
                            HStack {
                                Image(uiImage: Markers.pin(w.kind))
                                    .resizable()
                                    .frame(width: 22, height: 57)
                                    .frame(height: 30, alignment: .top)
                                    .clipped()
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(w.name).font(.frontier(17))
                                    if !w.note.isEmpty { Text(w.note).font(.caption).lineLimit(2) }
                                    if let here = model.here { Text(Guide.heading(from: here, to: w)).font(.caption) }
                                }
                                Spacer()
                                if w.photo != nil { Image(systemName: "photo").accessibilityLabel("Has a photo") }
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.delete(w) }
                            Button("Edit") {
                                edit(w)
                                dismiss()
                            }
                        }
                    }
                }
                Section("Discoveries") {
                    let found = model.discoveries.filter { $0.found != nil }
                    if found.isEmpty {
                        Text("Faded pins on the map are parks, historic sites, scenic spots and trails nearby. Get close to one to collect it.")
                            .font(.caption)
                    }
                    ForEach(found) { d in
                        HStack {
                            Image(uiImage: Markers.pin(d.kind)).resizable().frame(width: 22, height: 57)
                                .frame(height: 30, alignment: .top).clipped().accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(d.name).font(.frontier(16))
                                Text("\(d.kind.label) · \(d.found!.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                            }
                        }
                    }
                }
                Section("Achievements") {
                    ForEach(Achievement.all) { a in
                        let date = model.earned[a.id]
                        HStack {
                            Image(systemName: a.symbol).frame(width: 28).foregroundStyle(date == nil ? Color.secondary : Color.orange)
                            VStack(alignment: .leading) {
                                Text(a.title).font(.frontier(16))
                                Text(a.detail).font(.caption)
                            }
                            Spacer()
                            if let date { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption) }
                            else { Image(systemName: "lock.fill").accessibilityLabel("Locked") }
                        }
                        .opacity(date == nil ? 0.55 : 1)
                        .accessibilityElement(children: .combine)
                    }
                }
                Section("Your guide") {
                    ForEach(Rider.allCases) { r in
                        Button {
                            model.rider = r
                            model.say(r.toward("Camp", "3 miles northeast"))
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(r.name).font(.frontier(17))
                                    Text(r.blurb).font(.caption)
                                }
                                Spacer()
                                if model.rider == r { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityAddTraits(model.rider == r ? .isSelected : [])
                    }
                }
                Section("Privacy") {
                    Text("Your rides, fog map, discoveries, parking spot and pins are kept only on this phone. No account, no ads, no tracking. To work, the app sends locations (never your name) to Apple Maps for search, routes and commute times, MapTiler for map tiles, Open-Meteo for weather and elevation, and OpenStreetMap's Overpass service for speed limits.")
                        .font(.caption)
                    Button("Erase my travel history", role: .destructive) { confirmErase = true }
                }
            }
            .foregroundStyle(Color.ink)
            .scrollContentBackground(.hidden)
            .background(Color.parchment)
            .navigationTitle("Journal")
            .confirmationDialog("Erase all rides, fog, discoveries, achievements and recent searches? Your waypoints stay.",
                                isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Erase history", role: .destructive) { model.eraseHistory() }
            }
        }
    }
}

struct Turns: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let steps = model.route?.steps {
                    ForEach(Array(steps.enumerated()).dropFirst(), id: \.offset) { i, step in
                        VStack(alignment: .leading) {
                            Text(step.instructions.isEmpty ? "Continue" : step.instructions).font(.frontier(16))
                            if step.distance > 0 { Text(Guide.distance(step.distance)).font(.caption) }
                        }
                        .opacity(i < model.nextStep ? 0.4 : 1) // turns already passed fade out
                    }
                }
            }
            .foregroundStyle(Color.ink)
            .scrollContentBackground(.hidden)
            .background(Color.parchment)
            .navigationTitle("Turns")
        }
    }
}
