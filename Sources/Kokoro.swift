import AVFoundation
import SherpaOnnxC

/// On-device Kokoro neural voice via sherpa-onnx. The model is downloaded into the app by CI (see ios.yml);
/// init returns nil when it isn't bundled, and Guide falls back to the built-in iOS voice.
final class Kokoro {
    private let tts: OpaquePointer
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let shift = AVAudioUnitTimePitch() // pitch in cents without changing speed
    private let format: AVAudioFormat
    private let queue = DispatchQueue(label: "kokoro") // sherpa-onnx TTS isn't thread-safe
    private var latest = 0 // only the newest line plays; older ones still rendering are dropped
    private var ready: (key: String, buffer: AVAudioPCMBuffer)? // rendered ahead by prepare(); used only on `queue`

    init?(dir: URL? = Bundle.main.url(forResource: "Kokoro", withExtension: nil)) {
        guard let dir, FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.int8.onnx").path)
        else { return nil }
        let paths = ["model.int8.onnx", "voices.bin", "tokens.txt", "espeak-ng-data", "lexicon-us-en.txt"]
            .map { strdup(dir.appendingPathComponent($0).path)! } + [strdup("cpu")!]
        defer { paths.forEach { free($0) } }
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.kokoro.model = UnsafePointer(paths[0])
        config.model.kokoro.voices = UnsafePointer(paths[1])
        config.model.kokoro.tokens = UnsafePointer(paths[2])
        config.model.kokoro.data_dir = UnsafePointer(paths[3])
        config.model.kokoro.lexicon = UnsafePointer(paths[4])
        config.model.kokoro.length_scale = 1
        config.model.provider = UnsafePointer(paths[5])
        config.model.num_threads = 2
        config.max_num_sentences = 1
        guard let tts = SherpaOnnxCreateOfflineTts(&config) else { return nil }
        self.tts = tts
        format = AVAudioFormat(standardFormatWithSampleRate: Double(SherpaOnnxOfflineTtsSampleRate(tts)), channels: 1)!
        engine.attach(player)
        engine.attach(shift)
        engine.connect(player, to: shift, format: format)
        engine.connect(shift, to: engine.mainMixerNode, format: format)
    }

    deinit { SherpaOnnxDestroyOfflineTts(tts) }

    func say(_ text: String, speaker: Int32, speed: Float, pitch: Float = 0) {
        shift.pitch = pitch
        latest += 1
        let id = latest
        player.stop()
        queue.async { [self] in
            let key = "\(speaker) \(speed) \(text)"
            guard let buffer = ready?.key == key ? ready?.buffer : render(text, speaker: speaker, speed: speed) else { return }
            DispatchQueue.main.async { [self] in
                guard id == latest else { return }
                if !engine.isRunning { try? engine.start() }
                player.scheduleBuffer(buffer)
                player.play()
            }
        }
    }

    func prepare(_ text: String, speaker: Int32, speed: Float) {
        queue.async { [self] in
            let key = "\(speaker) \(speed) \(text)"
            if ready?.key != key, let buffer = render(text, speaker: speaker, speed: speed) { ready = (key, buffer) }
        }
    }

    /// Synthesizes one line. Call on `queue` (or from a test with no concurrent use).
    func render(_ text: String, speaker: Int32, speed: Float) -> AVAudioPCMBuffer? {
        guard let audio = SherpaOnnxOfflineTtsGenerate(tts, text, speaker, speed) else { return nil }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        let n = Int(audio.pointee.n)
        guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(n)
        buffer.floatChannelData![0].update(from: audio.pointee.samples, count: n)
        return buffer
    }
}
