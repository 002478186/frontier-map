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
        case .drifter: "Weary gunslinger. Dry, tired, quietly decent."
        case .boss: "Silver-tongued gang leader. Every ride is a sermon on freedom."
        case .oldTimer: "Lazy old prospector. Aches, gripes and naps."
        }
    }

    /// Kokoro speaker IDs from kokoro-int8-multi-lang-v1_0: 53 is a fenrir/onyx blend CI writes (ios.yml), then am_michael, am_santa.
    var speaker: Int32 { [53, 16, 19][index] }
    var speed: Float { [0.88, 0.95, 0.85][index] }
    /// Pitch shift in cents after synthesis; the Drifter is taken two semitones down for grit.
    var pitch: Float { [-200, 0, 0][index] }
    /// Built-in iOS voice delivery, used until (or if) the Kokoro model isn't available.
    var fallbackRate: Float { [0.40, 0.46, 0.38][index] }
    var fallbackPitch: Float { [0.70, 0.85, 1.10][index] }
    private var index: Int { Self.allCases.firstIndex(of: self)! }

    func start(_ name: String, _ distance: String, _ time: String, walking: Bool) -> String {
        let how = walking ? "on foot" : "riding"
        return switch self {
        case .drifter: "Alright. \(name). \(distance) out, about \(time) \(how). Reckon I've ridden further for worse reasons."
        case .boss: "Listen to me now. \(name) lies \(distance) yonder, some \(time) \(how). Out there is freedom, son. Let's go and take it."
        case .oldTimer: "\(name)? That's \(distance)! \(time) \(how)? My back's achin' already. Fine, fine. Let's go."
        }
    }

    func toward(_ name: String, _ way: String) -> String {
        switch self {
        case .drifter: [
            "\(name)'s \(way). Try not to get yourself shot on the way.",
            "Head \(way). \(name)'s out there, same as it was yesterday.",
            "\(way) to \(name). Keep your head down and your eyes open.",
        ].randomElement()!
        case .boss: [
            "\(name) lies \(way). The world is closing in, friend, but not today.",
            "Head \(way). \(name) waits for those with the courage to ride.",
            "\(way), to \(name). Stick with me, and we'll get there together.",
        ].randomElement()!
        case .oldTimer: [
            "\(name)'s \(way), I reckon. Or maybe it ain't. Just go.",
            "\(name)'s \(way). I'd come with you, but I'm restin' my eyes.",
            "\(way) to \(name). Wake me when we get there.",
        ].randomElement()!
        }
    }

    func standingOn(_ name: String) -> String {
        switch self {
        case .drifter: "You're standing on \(name). Not much to look at, is it."
        case .boss: "We stand upon \(name). Remember this moment."
        case .oldTimer: "You're standin' right on \(name), you durn fool. Sit down a spell."
        }
    }

    func arrived(_ name: String) -> String {
        switch self {
        case .drifter: "\(name). Well. That weren't so bad."
        case .boss: "\(name). Did I not tell you we would make it? Stick with me, and the world is ours."
        case .oldTimer: "\(name). Finally. Somebody pour me a drink."
        }
    }

    var offTrail: String {
        switch self {
        case .drifter: "Wrong way. Hold on, finding us another trail."
        case .boss: "A detour, nothing more. I'll find us a new road."
        case .oldTimer: "Now you've gone and got us lost. Lemme think of another way."
        }
    }

    var lost: String {
        switch self {
        case .drifter: "Can't find you, partner. Switch your location on."
        case .boss: "I cannot lead a man I cannot find. Turn your location on, son."
        case .oldTimer: "Where in tarnation are you? Turn that fancy location thing on."
        }
    }
}

final class Guide {
    private let synth = AVSpeechSynthesizer()
    private var kokoro: Kokoro?

    init() {
        // Loading the ~110 MB model takes a moment; speak with the iOS voice until it's ready.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let k = Kokoro()
            DispatchQueue.main.async { self?.kokoro = k }
        }
    }

    func say(_ text: String, as rider: Rider) {
        guard !text.isEmpty else { return }
        // .playback so the guide still talks with the silent switch on; mixes over music instead of stopping it.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        synth.stopSpeaking(at: .immediate)
        if let kokoro { return kokoro.say(text, speaker: rider.speaker, speed: rider.speed, pitch: rider.pitch) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = rider.fallbackRate
        utterance.pitchMultiplier = rider.fallbackPitch
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

    /// What to call a raised crossing named in lowercased text, e.g. "flyover" in "turn left onto hebbal flyover".
    static func crossingWord(in text: String) -> String? {
        if text.contains("flyover") { return "flyover" }
        if text.contains("overpass") { return "overpass" }
        return ["bridge", "viaduct", "skyway"].contains { text.contains($0) } ? "bridge" : nil
    }

    /// "38 mph" or "61 km/h", following the phone's region.
    static func speed(_ mps: CLLocationSpeed) -> String {
        let unit: UnitSpeed = Locale.current.measurementSystem == .metric ? .kilometersPerHour : .milesPerHour
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: Measurement(value: mps, unit: UnitSpeed.metersPerSecond).converted(to: unit))
    }

    /// Arrow for a turn instruction's banner, read from Apple's wording.
    static func maneuverSymbol(_ instruction: String) -> String {
        let t = instruction.lowercased()
        let left = t.contains("left"), right = t.contains("right")
        if t.contains("u-turn") { return "arrow.uturn.down" }
        if t.contains("roundabout") { return "arrow.triangle.turn.up.right.circle" }
        if t.contains("arrive") || t.contains("destination") { return "flag.checkered" }
        if t.contains("exit") || t.contains("ramp") || t.contains("keep") || t.contains("slight") || t.contains("bear") {
            return left ? "arrow.up.left" : right ? "arrow.up.right" : "arrow.up"
        }
        return left ? "arrow.turn.up.left" : right ? "arrow.turn.up.right" : "arrow.up"
    }

    static func directions(from here: CLLocation, to w: Waypoint, rider: Rider) -> String {
        if here.distance(from: CLLocation(latitude: w.lat, longitude: w.lon)) < 30 { return rider.standingOn(w.name) }
        return rider.toward(w.name, heading(from: here, to: w))
    }
}
