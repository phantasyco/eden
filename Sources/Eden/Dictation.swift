import AVFoundation
import Observation
import Speech

/// Voice dictation for the composer: the Mac's own speech recognition (on
/// device when the Mac supports it), written into the message as you speak.
/// It listens only while you dictate. Stop keeps what you said, after a
/// moment of transcribing while the recognizer settles on its final text;
/// Cancel puts the message back the way it was.
@MainActor @Observable
final class Dictation {
    enum Phase { case idle, listening, transcribing }

    private(set) var phase = Phase.idle
    var isActive: Bool { phase != .idle }
    /// Recent loudness, oldest first, 0 to 1, for the waveform.
    private(set) var levels: [Float] = []
    static let history = 260

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// The message as it was when dictation started; what you say goes after it.
    @ObservationIgnored private var base = ""
    @ObservationIgnored private var write: ((String) -> Void)?
    /// What dictation last put in the message, to tell your own typing from it.
    @ObservationIgnored private(set) var written: String?

    func start(after text: String, write: @escaping (String) -> Void, fail: @escaping (String) -> Void) async {
        guard phase == .idle else { return }
        guard await Self.authorize(fail: fail) else { return }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            fail("Speech recognition isn't available right now. Check Siri & Dictation in System Settings.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // What you say stays on this Mac when it can do the recognizing itself.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        nonisolated(unsafe) let feed = request
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            feed.append(buffer)
            let level = Self.level(of: buffer)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.push(level) } }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            fail("Couldn't start the microphone. \(error.localizedDescription)")
            return
        }

        base = text
        written = text
        self.write = write
        self.engine = engine
        self.request = request
        levels = Array(repeating: 0, count: Self.history)
        phase = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let heard = result?.bestTranscription.formattedString
            let ended = error != nil || result?.isFinal == true
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.phase != .idle else { return }
                    if let heard { self.show(heard) }
                    // The final text, or recognition stopping by itself (a long silence, an error).
                    if ended { self.finish() }
                }
            }
        }
    }

    /// Stop: no more listening, then a moment of transcribing while the
    /// recognizer settles on its final text for what it heard.
    func stop() {
        guard phase == .listening else { return }
        phase = .transcribing
        stopAudio()
        request?.endAudio()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.phase == .transcribing { self?.finish() }
        }
    }

    /// Cancel: the message goes back to how it was before you started.
    func cancel() {
        guard phase != .idle else { return }
        written = base
        write?(base)
        abandon()
    }

    /// Stops without touching the message again: you've typed in it or sent it.
    func abandon() {
        guard phase != .idle else { return }
        stopAudio()
        finish()
    }

    private func finish() {
        phase = .idle
        task?.cancel()
        task = nil
        request = nil
        write = nil
    }

    private func stopAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func show(_ heard: String) {
        let separator = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? "" : " "
        let text = base + separator + heard
        written = text
        write?(text)
    }

    private func push(_ level: Float) {
        guard phase == .listening else { return }
        levels.append(level)
        if levels.count > Self.history { levels.removeFirst(levels.count - Self.history) }
    }

    /// How loud a buffer is, from silence (0) to speaking up (1).
    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let decibels = 20 * log10(max(sqrt(sum / Float(count)), 0.000_001))
        return max(0, min(1, (decibels + 55) / 40))
    }

    /// Speech recognition, then the microphone: each asks once, the first time.
    private static func authorize(fail: (String) -> Void) async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            fail("Eden needs Speech Recognition to dictate. Turn it on in System Settings > Privacy & Security > Speech Recognition.")
            return false
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            fail("Eden needs the microphone to dictate. Turn it on in System Settings > Privacy & Security > Microphone.")
            return false
        }
        return true
    }
}
