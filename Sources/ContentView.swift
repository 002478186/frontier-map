import SwiftUI

extension Color {
    static let parchment = Color(red: 0.91, green: 0.84, blue: 0.69)
    static let ink = Color(red: 0.23, green: 0.15, blue: 0.09)
}

extension Font {
    static func frontier(_ size: CGFloat) -> Font { .custom("Copperplate", size: size, relativeTo: .body) }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var query = ""
    @State private var pinName = ""
    @State private var pinKind = Waypoint.Kind.pin
    @State private var showJournal = false
    @State private var showTurns = false

    var body: some View {
        ZStack {
            MapView(model: model).ignoresSafeArea()
            // Aged-paper vignette; decorative, so taps pass through.
            RadialGradient(colors: [.clear, .ink.opacity(0.35)], center: .center, startRadius: 180, endRadius: 650)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 8) {
                if let turn = model.nextTurn { turnBanner(turn) } else { searchBar }
                if !model.navigating && model.results.isEmpty { findsBar }
                if !MapStyle.hasKey { note("No MapTiler key set. See README, \"Configure the key\".") }
                if let banner = model.banner { note(banner).onTapGesture { model.banner = nil } }
                HStack(alignment: .top) {
                    if let weather = model.weather {
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
                if model.route != nil { routePanel }
                HStack(spacing: 16) {
                    tool("location.north.line.fill", "Follow me") { model.followMe() }
                    tool("book.closed.fill", "Journal") { showJournal = true }
                    tool("arrow.down.circle.fill", "Save this area for offline") { model.saveVisibleArea() }
                }
            }
            .padding()
        }
        .sheet(isPresented: Binding(get: { model.pendingPin != nil }, set: { if !$0 { model.pendingPin = nil } }),
               onDismiss: { pinName = ""; pinKind = .pin }) { newPin }
        .sheet(isPresented: $showJournal) { Journal(model: model) }
        .sheet(isPresented: $showTurns) { Turns(model: model) }
    }

    private var newPin: some View {
        NavigationStack {
            Form {
                TextField("Camp, creek, ranch…", text: $pinName).font(.frontier(17))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                    ForEach(Waypoint.Kind.allCases) { k in
                        Button { pinKind = k } label: {
                            Image(uiImage: Markers.pin(k))
                                .frame(width: 34, height: 44, alignment: .top)
                                .clipped() // show the pin, not its transparent lower half
                                .padding(4)
                                .background(pinKind == k ? Color.ink.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(k.label)
                        .accessibilityAddTraits(pinKind == k ? .isSelected : [])
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.parchment)
            .navigationTitle("Name this waypoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.pendingPin = nil } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { model.addPin(named: pinName, kind: pinKind) } }
            }
        }
        .presentationDetents([.medium])
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
            if let speed = model.speed { Text(Guide.speed(speed)).font(.frontier(15)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .foregroundStyle(Color.parchment)
        .background(Color.ink, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var routePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let route = model.route {
                Text("To \(model.destination?.name ?? "destination")").font(.frontier(18))
                Text("\(Guide.duration(route.expectedTravelTime)) · \(Guide.distance(route.distance)) · arrive "
                     + Date().addingTimeInterval(route.expectedTravelTime).formatted(date: .omitted, time: .shortened))
                    .font(.frontier(15))
                if !model.walking { Text("Time includes current traffic (Apple Maps)").font(.caption) }
            }
            Picker("Travel by", selection: Binding(get: { model.walking }, set: { walking in
                model.walking = walking
                if let d = model.destination { Task { await model.directions(to: d.name, at: d.coordinate) } }
            })) {
                Text("Car").tag(false)
                Text("Walk").tag(true)
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
            HStack {
                Button("Turns") { showTurns = true }
                Spacer()
                Button("End route", role: .destructive) { model.endRoute() }
            }
            .font(.frontier(16))
        }
        .padding(12)
        .foregroundStyle(Color.ink)
        .background(Color.parchment, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.ink, lineWidth: 1.5))
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
            TextField("Search the world…", text: $query)
                .font(.frontier(17))
                .submitLabel(.search)
                .onSubmit { Task { await model.search(query) } }
                .padding(12)
            ForEach(model.results, id: \.self) { item in
                Divider()
                HStack {
                    Button {
                        model.fly(to: item.placemark.coordinate)
                        model.results = []
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.name ?? "Unknown place").font(.frontier(15))
                            Text(item.placemark.title ?? "").font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
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
        .foregroundStyle(Color.ink)
        .background(Color.parchment, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.ink, lineWidth: 1.5))
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

struct Journal: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Waypoints") {
                    if model.waypoints.isEmpty { Text("Long-press the map to drop a pin.") }
                    else { Text("Tap a waypoint for directions.").font(.caption) }
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
                                    if let here = model.here { Text(Guide.heading(from: here, to: w)).font(.caption) }
                                }
                            }
                        }
                    }
                    .onDelete { model.waypoints.remove(atOffsets: $0) }
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
                Section("Offline maps") {
                    Button("Delete saved areas", role: .destructive) { model.deleteOfflineAreas() }
                }
            }
            .foregroundStyle(Color.ink)
            .scrollContentBackground(.hidden)
            .background(Color.parchment)
            .navigationTitle("Journal")
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
