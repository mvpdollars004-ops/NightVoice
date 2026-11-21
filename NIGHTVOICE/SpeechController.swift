import Foundation
import Speech
import AVFoundation

@MainActor
final class SpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var transcript = ""
    @Published var status = "Ready"
    @Published var armed = false
    @Published var listening = false
    @Published var reply = "—"
    @Published var history: [String] = []
    @Published var cooldownSeconds: Double = 5
    @Published var silenceSeconds: Double = 1.6
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "nightvoice.serverURL") ?? ""
    @Published var lastSource: String = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let responseEngine = ResponseEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var processing = false
    private var sessionID = UUID()
    private var recognitionID = UUID()
    private var lastAnsweredQuestion = ""
    private var lastAnswerTime = Date.distantPast

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func arm() async {
        guard !armed else { return }
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { auth in
                continuation.resume(returning: auth == .authorized)
            }
        }
        guard speechAllowed else { status = "Speech recognition permission denied"; return }
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        guard micAllowed else { status = "Microphone permission denied"; return }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            status = "Offline speech recognition unavailable for en-US"; return
        }
        armed = true
        sessionID = UUID()
        lastAnsweredQuestion = ""
        lastAnswerTime = .distantPast
        await beginListening()
    }

    func updateServerURL(_ value: String) {
        serverURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(serverURL, forKey: "nightvoice.serverURL")
    }

    func disarm() {
        armed = false
        sessionID = UUID()
        silenceTask?.cancel()
        restartTask?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        stopRecognition()
        processing = false
        status = "Disarmed"
    }

    private func beginListening() async {
        guard armed && !processing && !listening && !synthesizer.isSpeaking else { return }
        guard let recognizer, recognizer.isAvailable else { status = "Speech recognition unavailable"; return }
        do {
            transcript = ""
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let newRequest = SFSpeechAudioBufferRecognitionRequest()
            newRequest.requiresOnDeviceRecognition = true
            newRequest.shouldReportPartialResults = true
            request = newRequest
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak newRequest] buffer, _ in
                newRequest?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            listening = true
            status = "Listening for questions"
            let id = UUID()
            recognitionID = id
            recognitionTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self, self.armed, self.recognitionID == id else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        if text != self.transcript {
                            self.transcript = text
                            self.scheduleSilenceCheck(id: id, text: text)
                        }
                        if result.isFinal { await self.answerCurrentQuestion() }
                    } else if error != nil {
                        self.stopRecognition()
                        self.scheduleRestart(after: 0.8)
                    }
                }
            }
        } catch {
            stopRecognition()
            status = "Audio error: \(error.localizedDescription)"
            scheduleRestart(after: 2)
        }
    }

    private func scheduleSilenceCheck(id: UUID, text: String) {
        silenceTask?.cancel()
        guard !text.isEmpty else { return }
        silenceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.silenceSeconds))
            guard !Task.isCancelled, self.armed, self.recognitionID == id,
                  self.transcript == text, self.looksLikeQuestion(text) else { return }
            await self.answerCurrentQuestion()
        }
    }

    private func looksLikeQuestion(_ text: String) -> Bool {
        let q = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["who", "what", "where", "when", "why", "how", "are", "is", "do", "did", "does", "can", "could", "would", "will", "have", "has", "were", "was"].contains { q == $0 || q.hasPrefix($0 + " ") } || q.hasSuffix("?")
    }

    func answerCurrentQuestion() async {
        guard armed && !processing else { return }
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard looksLikeQuestion(question) else { return }
        let normalized = question.lowercased()
        if Date().timeIntervalSince(lastAnswerTime) < cooldownSeconds {
            return
        }
        if normalized == lastAnsweredQuestion && Date().timeIntervalSince(lastAnswerTime) < 30 {
            return
        }
        processing = true
        silenceTask?.cancel()
        stopRecognition()
        let currentSession = sessionID
        let result = await responseEngine.respond(to: question, endpoint: serverURL)
        guard armed && sessionID == currentSession else { processing = false; return }
        let limited = ResponseEngine.clean(result.words)
        guard !limited.isEmpty else { processing = false; scheduleRestart(after: cooldownSeconds); return }
        lastSource = result.source
        lastAnsweredQuestion = normalized
        lastAnswerTime = Date()
        reply = limited
        history.insert("\(Date().formatted(date: .omitted, time: .standard)) | Q: \(question) | A: \(limited) [\(result.source)]", at: 0)
        status = "Responding"
        let utterance = AVSpeechUtterance(string: limited)
        utterance.rate = 0.42
        utterance.pitchMultiplier = 0.72
        synthesizer.speak(utterance)
    }

    func manualAnswer() async {
        guard armed && !processing else { return }
        if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await answerCurrentQuestion()
        } else {
            status = "Ask a question first"
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.processing = false
            self.scheduleRestart(after: self.cooldownSeconds)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.processing = false
            if self.armed { self.scheduleRestart(after: self.cooldownSeconds) }
        }
    }

    private func scheduleRestart(after delay: Double) {
        restartTask?.cancel()
        guard armed else { return }
        status = "Cooldown: \(Int(delay.rounded())) seconds"
        let id = sessionID
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.armed, self.sessionID == id else { return }
            await self.beginListening()
        }
    }

    private func stopRecognition() {
        silenceTask?.cancel()
        recognitionID = UUID()
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        listening = false
    }
}
