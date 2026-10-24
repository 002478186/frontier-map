import AVFoundation
import MapKit

/// Original frontier-guide narrator spoken by the built-in iOS voice. No game audio or cloned voices.
final class Guide {
    private let synth = AVSpeechSynthesizer()

    func say(_ text: String) {
        guard !text.isEmpty else { return }
        // .playback so the guide still talks with the silent switch on; mixes over music instead of stopping it.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.42
        utterance.pitchMultiplier = 0.75
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

    static func routeStart(_ route: MKRoute, to name: String, walking: Bool) -> String {
        let first = route.steps.dropFirst().first { !$0.instructions.isEmpty }?.instructions
        return "Saddle up. \(name) is \(distance(route.distance)) off, about "
            + "\(duration(route.expectedTravelTime, spoken: true)) \(walking ? "on foot" : "riding"). "
            + (first.map { "First, \(lowerFirst($0))." } ?? "")
    }

    static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    static func directions(from here: CLLocation, to w: Waypoint) -> String {
        if here.distance(from: CLLocation(latitude: w.lat, longitude: w.lon)) < 30 {
            return "You're standing right on \(w.name). Rest your boots a spell."
        }
        let way = heading(from: here, to: w)
        return [
            "\(w.name) lies \(way). Ride steady.",
            "Head \(way), or thereabouts, and you'll strike \(w.name).",
            "\(w.name) is \(way) from here. Mind the trail.",
        ].randomElement()!
    }
}
