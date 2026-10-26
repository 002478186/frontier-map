import AVFoundation
import MapKit

/// Original guide characters, styled after outlaw-western archetypes. No game names, lines, audio or cloned voices.
enum Rider: String, CaseIterable, Identifiable {
    case drifter, boss, oldTimer
    var id: String { rawValue }

    var name: String {
        switch self {
        case .drifter: "The Drifter"
        case .boss: "The Boss"
        case .oldTimer: "The Old-Timer"
        }
    }

    var blurb: String {
        switch self {
        case .drifter: "Weary gunslinger. Few words, dry as dust."
        case .boss: "Silver-tongued gang leader. Every ride is destiny."
        case .oldTimer: "Cranky old prospector. Grumbles the whole way."
        }
    }

    /// Delivery for the built-in iOS voice; `voice` picks a different male voice per rider when the phone has several.
    var rate: Float { [0.40, 0.46, 0.38][index] }
    var pitch: Float { [0.70, 0.85, 1.10][index] }
    private var index: Int { Self.allCases.firstIndex(of: self)! }

    var voice: AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && $0.gender == .male }
            .sorted { ($0.quality.rawValue, $0.language == "en-US" ? 1 : 0) > ($1.quality.rawValue, $1.language == "en-US" ? 1 : 0) }
        return voices.isEmpty ? AVSpeechSynthesisVoice(language: "en-US") : voices[index % voices.count]
    }

    func start(_ name: String, _ distance: String, _ time: String, walking: Bool) -> String {
        let how = walking ? "on foot" : "riding"
        return switch self {
        case .drifter: "Alright. \(name). \(distance), about \(time) \(how). Let's get this over with."
        case .boss: "Gentlemen, the road calls. \(name) lies \(distance) ahead, some \(time) \(how). Our future waits there."
        case .oldTimer: "\(name)? That's \(distance), near \(time) \(how). My poor knees. Fine, let's go."
        }
    }

    func toward(_ name: String, _ way: String) -> String {
        switch self {
        case .drifter: ["\(name). \(way). Keep your eyes open.", "\(way) to \(name). Don't dawdle."].randomElement()!
        case .boss: ["\(name) lies \(way), friend. Ride with purpose.", "Head \(way). \(name) is where we make our mark."].randomElement()!
        case .oldTimer: ["\(name)'s \(way), if my eyes ain't lyin'.", "\(way), and don't you rush me. \(name) ain't goin' nowhere."].randomElement()!
        }
    }

    func standingOn(_ name: String) -> String {
        switch self {
        case .drifter: "You're on \(name). Rest a minute."
        case .boss: "We stand upon \(name). Savor it."
        case .oldTimer: "You're standin' right on \(name), you fool. Sit a spell."
        }
    }

    func arrived(_ name: String) -> String {
        switch self {
        case .drifter: "Whoa. \(name). We made it."
        case .boss: "\(name). Didn't I tell you we'd get here?"
        case .oldTimer: "Finally. \(name). Somebody fetch me a chair."
        }
    }

    var lost: String {
        switch self {
        case .drifter: "Can't tell where you are. Switch your location on."
        case .boss: "Even I can't lead a man I can't find. Turn your location on."
        case .oldTimer: "Where in tarnation are you? Turn that location thing on."
        }
    }
}

final class Guide {
    private let synth = AVSpeechSynthesizer()

    func say(_ text: String, as rider: Rider) {
        guard !text.isEmpty else { return }
        // .playback so the guide still talks with the silent switch on; mixes over music instead of stopping it.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = rider.voice
        utterance.rate = rider.rate
        utterance.pitchMultiplier = rider.pitch
        synth.stopSpeaking(at: .immediate)
        synth.speak(utterance)
    }

    /// e.g. "3.2 miles" (units follow the phone's region settings).
    static func distance(_ meters: CLLocationDistance) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.unitStyle = .long
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter.string(from: Measurement(value: meters, unit: UnitLength.meters))
    }

    /// "25 min" on screen, "25 minutes" when spoken.
    static func duration(_ seconds: TimeInterval, spoken: Bool = false) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = spoken ? .full : .short
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        return formatter.string(from: max(seconds, 60)) ?? ""
    }

    /// e.g. "3.2 miles northeast", as the crow flies.
    static func heading(from here: CLLocation, to w: Waypoint) -> String {
        let meters = here.distance(from: CLLocation(latitude: w.lat, longitude: w.lon))
        return "\(distance(meters)) \(Geo.compassPoint(Geo.bearing(from: here.coordinate, to: w.coordinate)))"
    }

    static func routeStart(_ route: MKRoute, to name: String, walking: Bool, rider: Rider) -> String {
        let first = route.steps.dropFirst().first { !$0.instructions.isEmpty }?.instructions
        return rider.start(name, distance(route.distance), duration(route.expectedTravelTime, spoken: true), walking: walking)
            + (first.map { " First, \(lowerFirst($0))." } ?? "")
    }

    static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    static func directions(from here: CLLocation, to w: Waypoint, rider: Rider) -> String {
        if here.distance(from: CLLocation(latitude: w.lat, longitude: w.lon)) < 30 { return rider.standingOn(w.name) }
        return rider.toward(w.name, heading(from: here, to: w))
    }
}
