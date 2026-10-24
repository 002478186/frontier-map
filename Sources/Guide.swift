import AVFoundation
import CoreLocation

/// Original frontier-guide narrator spoken by the built-in iOS voice. No game audio or cloned voices.
final class Guide {
    private let synth = AVSpeechSynthesizer()

    func say(_ text: String) {
        // .playback so the guide still talks with the silent switch on; mixes over music instead of stopping it.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.42
        utterance.pitchMultiplier = 0.75
        synth.stopSpeaking(at: .immediate)
        synth.speak(utterance)
    }

    /// e.g. "3.2 miles northeast" (units follow the phone's region settings).
    static func heading(from here: CLLocation, to w: Waypoint) -> String {
        let meters = here.distance(from: CLLocation(latitude: w.lat, longitude: w.lon))
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.unitStyle = .long
        formatter.numberFormatter.maximumFractionDigits = 1
        let distance = formatter.string(from: Measurement(value: meters, unit: UnitLength.meters))
        return "\(distance) \(Geo.compassPoint(Geo.bearing(from: here.coordinate, to: w.coordinate)))"
    }

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
