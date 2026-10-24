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
    @State private var showJournal = false

    var body: some View {
        ZStack {
            MapView(model: model).ignoresSafeArea()
            // Aged-paper vignette; decorative, so taps pass through.
            RadialGradient(colors: [.clear, .ink.opacity(0.35)], center: .center, startRadius: 180, endRadius: 650)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 8) {
                searchBar
                if !MapStyle.hasKey { note("No MapTiler key set. See README, \"Configure the key\".") }
                if let banner = model.banner { note(banner).onTapGesture { model.banner = nil } }
                Spacer()
                HStack(spacing: 16) {
                    tool("location.north.line.fill", "Follow me") { model.followMe() }
                    tool("book.closed.fill", "Journal") { showJournal = true }
                    tool("arrow.down.circle.fill", "Save this area for offline") { model.saveVisibleArea() }
                }
            }
            .padding()
        }
        .alert("Name this waypoint", isPresented: Binding(get: { model.pendingPin != nil },
                                                          set: { if !$0 { model.pendingPin = nil } })) {
            TextField("Camp, creek, ranch…", text: $pinName)
            Button("Save") { model.addPin(named: pinName); pinName = "" }
            Button("Cancel", role: .cancel) { pinName = "" }
        }
        .sheet(isPresented: $showJournal) { Journal(model: model) }
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
                    ForEach(model.waypoints) { w in
                        Button {
                            model.fly(to: w.coordinate)
                            model.guide(to: w)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(w.name).font(.frontier(17))
                                if let here = model.here { Text(Guide.heading(from: here, to: w)).font(.caption) }
                            }
                        }
                    }
                    .onDelete { model.waypoints.remove(atOffsets: $0) }
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
