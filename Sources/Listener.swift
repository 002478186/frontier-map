import Speech
import AVFoundation

/// Hands-free requests for the guide: listens until you pause, transcribing on the phone where it can.
final class Listener: ObservableObject {
    @Published var text = ""
    @Published private(set) var listening = false
    @Published private(set) var problem: String?
    var onFinish: (String) -> Void = { _ in }
    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var silence: DispatchWorkItem?

    func toggle() { listening ? stop() : start() }

    func start() {
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioSession.sharedInstance().requestRecordPermission { mic in
                DispatchQueue.main.async {
                    guard status == .authorized, mic else {
                        self.problem = "Allow the microphone and speech recognition in Settings to talk to the guide."
                        return
                    }
                    self.begin()
                }
            }
        }
    }

    private func begin() {
        guard !listening, let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true } // keep the voice on the phone
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try? session.setActive(true)
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            problem = "Couldn't start the microphone."
            return
        }
        text = ""
        problem = nil
        listening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.listening else { return }
                if let result { self.text = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true { return self.finish() }
                self.waitForPause()
            }
        }
        waitForPause(8) // nothing said at all
    }

    /// Done once you've stopped talking for 1.5 s.
    private func waitForPause(_ seconds: Double = 1.5) {
        silence?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        silence = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func finish() {
        let said = text.trimmingCharacters(in: .whitespaces)
        stop()
        if !said.isEmpty { onFinish(said) }
    }

    func stop() {
        guard listening else { return }
        listening = false
        silence?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
