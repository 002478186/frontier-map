import Foundation
import MapKit

/// What someone asked the guide for, e.g. "plan a 3-hour drive with a lunch stop and a lookout point"
/// or "find a quiet coffee shop on my way to work".
struct TripRequest: Equatable {
    var hours: Double?         // a round trip of about this long, when there's no destination
    var destination: String?   // "home", "work", or a place to search for
    var stops: [Stop] = []
    var travel: Travel?        // when the request says how: "bike ride", "walk", "drive"

    enum Stop: String, CaseIterable {
        case food, coffee, fuel, lookout, park, history, lodging, shop, charger

        var title: String {
            switch self {
            case .food: "a bite to eat"
            case .coffee: "coffee"
            case .fuel: "fuel"
            case .lookout: "a lookout"
            case .park: "a park"
            case .history: "a historic site"
            case .lodging: "a bed for the night"
            case .shop: "a store"
            case .charger: "an EV charger"
            }
        }

        /// Minutes planned at the stop.
        var stay: TimeInterval { [45, 15, 10, 20, 30, 30, 0, 15, 30][Self.allCases.firstIndex(of: self)!] * 60 }

        var categories: [MKPointOfInterestCategory] {
            switch self {
            case .food: return [.restaurant, .bakery]
            case .coffee: return [.cafe]
            case .fuel: return [.gasStation]
            case .charger: return [.evCharger]
            case .lookout:
                if #available(iOS 18.0, *) { return [.park, .nationalPark, .beach, .marina, .landmark] }
                return [.park, .nationalPark, .beach, .marina]
            case .park: return [.park, .nationalPark]
            case .history:
                if #available(iOS 18.0, *) { return [.museum, .landmark, .castle, .fortress, .nationalMonument] }
                return [.museum]
            case .lodging: return [.hotel, .campground]
            case .shop: return [.store]
            }
        }

        fileprivate static let words: [(String, Stop)] = [
            ("coffee shop", .coffee), ("tea shop", .coffee), ("gas station", .fuel), ("petrol pump", .fuel),
            ("charging station", .charger), ("ev charg", .charger), ("supercharg", .charger), ("lunch", .food), ("dinner", .food), ("breakfast", .food), ("food", .food), ("eat", .food), ("restaurant", .food),
            ("grub", .food), ("coffee", .coffee), ("cafe", .coffee), ("café", .coffee), ("tea", .coffee),
            ("fuel", .fuel), ("gas", .fuel), ("petrol", .fuel), ("charg", .charger),
            ("lookout", .lookout), ("viewpoint", .lookout), ("view", .lookout), ("vista", .lookout), ("scenic", .lookout),
            ("sunset", .lookout), ("beach", .lookout), ("lake", .lookout),
            ("park", .park), ("nature", .park), ("museum", .history), ("histor", .history), ("monument", .history),
            ("castle", .history), ("fort", .history), ("hotel", .lodging), ("motel", .lodging), ("lodging", .lodging),
            ("camp", .lodging), ("store", .shop), ("shop", .shop), ("grocer", .shop),
        ]
    }

    /// Reads a request with plain keyword rules, so the assistant works on every phone and offline.
    static func parse(_ text: String) -> TripRequest {
        let t = " " + text.lowercased().replacingOccurrences(of: "-", with: " ") + " "
        var r = TripRequest()

        let numbers = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "eight": 8, "half a": 0.5, "half an": 0.5]
        if let n = firstGroup(#" (\d+(?:\.\d+)?|half an?|an?|one|two|three|four|five|six|eight) ?(?:hours?|hrs?|h)\b"#, in: t) {
            r.hours = Double(n) ?? numbers[n]
        } else if let n = firstGroup(#" (\d+) ?(?:minutes?|mins?)\b"#, in: t).flatMap(Double.init) {
            r.hours = n / 60
        }

        if t.contains(" bike") || t.contains(" cycl") { r.travel = .bike }
        else if t.contains(" walk") || t.contains(" hike") || t.contains(" stroll") { r.travel = .walk }
        else if t.contains(" drive") || t.contains(" driving") { r.travel = .car }

        // "... to work", "drive to the coast with a lunch stop", "way to Mysore": the words after the last " to ".
        if let to = t.range(of: " to ", options: .backwards) {
            var place = String(t[to.upperBound...])
            for end in [" with ", " via ", " and ", " for ", ",", ".", "?", "!"] {
                if let e = place.range(of: end) { place = String(place[..<e.lowerBound]) }
            }
            place = place.trimmingCharacters(in: .whitespaces)
            for article in ["the ", "my "] where place.hasPrefix(article) { place.removeFirst(article.count) }
            let verbs = ["eat", "get", "go", "see", "stop", "find", "grab", "visit"]
            if !place.isEmpty, !verbs.contains(where: { place == $0 || place.hasPrefix($0 + " ") }) { r.destination = place }
        }

        // Stops in the order they're mentioned, without repeats, and not the destination itself. Words match at
        // the start of a word ("eat" but not "great"), longest first so "coffee shop" isn't also a shop.
        let target = r.destination ?? "\u{0}"
        var taken: [Range<String.Index>] = [], found: [(String.Index, Stop)] = []
        for (word, stop) in Stop.words.sorted(by: { $0.0.count > $1.0.count }) where !target.contains(word) {
            var from = t.startIndex
            while let at = t.range(of: " " + word, range: from..<t.endIndex) {
                if !taken.contains(where: { $0.overlaps(at) }) { taken.append(at); found.append((at.lowerBound, stop)) }
                from = at.upperBound
            }
        }
        for (_, stop) in found.sorted(by: { $0.0 < $1.0 }) where !r.stops.contains(stop) { r.stops.append(stop) }
        return r
    }

    /// The place in "add a Tim Hortons stop" / "stop at Starbucks on the way", keeping its capitals.
    static func addedPlace(_ text: String) -> String? {
        let pattern = #"^\s*(?:please\s+)?(?:add|stop at|stop by)\s+(?:a |an |the )?(.+?)(?:\s+stop)?(?:\s+(?:on|along) (?:the|my) way)?[.!?]?\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let g = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[g])
    }

    private static func firstGroup(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let g = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[g])
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct TripIdea {
    var destination: String?
    var hours: Double?
    var stops: [String]
}

extension TripRequest {
    /// Apple's on-device model reads the request; nil when Apple Intelligence isn't available on this phone.
    static func understand(_ text: String) async -> TripRequest? {
        guard #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You turn a traveller's request into a trip plan. destination: where they are heading (a place name, or \
            "home" or "work"), or null for a round trip. hours: how long a round trip should take, or null. \
            stops: the kinds of stops they want, in order, each exactly one of: \(Stop.allCases.map(\.rawValue).joined(separator: ", ")).
            """)
        guard let idea = try? await session.respond(to: text, generating: TripIdea.self).content else { return nil }
        return TripRequest(hours: idea.hours, destination: idea.destination?.lowercased(),
                           stops: idea.stops.compactMap { Stop(rawValue: $0.lowercased()) })
    }
}
#else
extension TripRequest {
    static func understand(_ text: String) async -> TripRequest? { nil }
}
#endif
