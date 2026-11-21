import Foundation
import Speech
import AVFoundation

@MainActor
final class SpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var transcript = ""
    @Published var status = "Ready"
    @Published var armed = false
    @Published var listening = false
    @Published private(set) var paused = false
    @Published var reply = "—"
    @Published var history: [String] = []
    @Published var cooldownSeconds: Double = 3 // Legacy setting; random response delay is 3–15 seconds.
    @Published var silenceSeconds: Double = 1.4
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "nightvoice.serverURL") ?? ""
    @Published var lastSource: String = ""
    @Published var pendingDelay: Int? = nil

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let responseEngine = ResponseEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var responseTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var speechRecoveryTask: Task<Void, Never>?
    private var engineRecoveryTask: Task<Void, Never>?
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
        guard speechAllowed else { status = "Speech permission denied"; return }
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        guard micAllowed else { status = "Microphone permission denied"; return }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            status = "Offline recognition unavailable for en-US"; return
        }
        armed = true
        paused = false
        processing = false
        sessionID = UUID()
        lastAnsweredQuestion = ""
        lastAnswerTime = .distantPast
        startEngineRecoveryMonitor()
        await beginListening()
    }

    func updateServerURL(_ value: String) {
        serverURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(serverURL, forKey: "nightvoice.serverURL")
    }

    func disarm() {
        armed = false
        paused = false
        sessionID = UUID()
        silenceTask?.cancel()
        restartTask?.cancel()
        responseTask?.cancel()
        watchdogTask?.cancel()
        speechRecoveryTask?.cancel()
        engineRecoveryTask?.cancel()
        pendingDelay = nil
        synthesizer.stopSpeaking(at: .immediate)
        stopRecognition()
        processing = false
        status = "Disarmed"
    }

    func pause() {
        guard armed && !paused else { return }
        paused = true
        // Invalidate any queued reply and prevent stale speech callbacks
        // from rearming recognition while investigators are talking.
        sessionID = UUID()
        silenceTask?.cancel()
        restartTask?.cancel()
        responseTask?.cancel()
        watchdogTask?.cancel()
        speechRecoveryTask?.cancel()
        engineRecoveryTask?.cancel()
        pendingDelay = nil
        stopRecognition()
        synthesizer.stopSpeaking(at: .immediate)
        processing = false
        status = "Paused"
    }

    func resume() async {
        guard armed && paused else { return }
        paused = false
        processing = false
        transcript = ""
        sessionID = UUID()
        status = "Resuming"
        startEngineRecoveryMonitor()
        await beginListening()
    }

    private func beginListening() async {
        guard armed && !paused && !processing && !listening && !synthesizer.isSpeaking else { return }
        guard let recognizer, recognizer.isAvailable else {
            status = "Recognition unavailable; retrying"
            scheduleRestart(after: 2)
            return
        }
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
                    guard let self, self.armed, !self.paused, self.recognitionID == id else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        if text != self.transcript {
                            self.transcript = text
                            self.scheduleSilenceCheck(id: id, text: text)
                        }
                        if result.isFinal {
                            if self.looksLikeQuestion(text) {
                                self.queueQuestion(text)
                            } else {
                                self.stopRecognition()
                                self.scheduleRestart(after: 0.25)
                            }
                        }
                    }
                    if error != nil && !self.processing {
                        self.stopRecognition()
                        self.scheduleRestart(after: 0.8)
                    }
                }
            }
            // Speech recognizers may end or stall after a period of continuous use.
            // Recreate the recognition request periodically, without disarming.
            watchdogTask?.cancel()
            watchdogTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self, self.armed, !self.paused, self.listening,
                      !self.processing, self.recognitionID == id else { return }
                if self.looksLikeQuestion(self.transcript) {
                    self.queueQuestion(self.transcript)
                } else {
                    self.stopRecognition()
                    self.scheduleRestart(after: 0.25)
                }
            }
        } catch {
            stopRecognition()
            status = "Audio error; retrying"
            scheduleRestart(after: 2)
        }
    }

    private func scheduleSilenceCheck(id: UUID, text: String) {
        silenceTask?.cancel()
        guard !text.isEmpty else { return }
        silenceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.silenceSeconds))
            guard !Task.isCancelled, self.armed, !self.paused, self.recognitionID == id,
                  self.transcript == text, self.looksLikeQuestion(text) else { return }
            self.queueQuestion(text)
        }
    }

    private func looksLikeQuestion(_ text: String) -> Bool {
        let q = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["who", "what", "where", "when", "why", "how", "are", "is", "do", "did", "does", "can", "could", "would", "will", "have", "has", "were", "was", "should", "may"].contains { q == $0 || q.hasPrefix($0 + " ") } || q.hasSuffix("?")
    }

    private func queueQuestion(_ question: String) {
        guard armed && !paused && !processing && looksLikeQuestion(question) else { return }
        let normalized = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        // Ignore immediate duplicate transcription callbacks, not future questions.
        if normalized == lastAnsweredQuestion && Date().timeIntervalSince(lastAnswerTime) < 2 { return }
        processing = true
        silenceTask?.cancel()
        stopRecognition()
        let currentSession = sessionID
        let delay = Int.random(in: 3...15)
        pendingDelay = delay
        status = "Question received"
        responseTask?.cancel()
        responseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.armed, !self.paused, self.sessionID == currentSession else { return }
            self.pendingDelay = nil
            await self.deliverResponse(for: question, normalized: normalized, session: currentSession)
        }
    }

    private func deliverResponse(for question: String, normalized: String, session: UUID) async {
        status = "Preparing response"
        let result = await responseEngine.respond(to: question, endpoint: serverURL)
        guard armed && !paused && sessionID == session && !Task.isCancelled else { return }
        let limited = ResponseEngine.clean(result.words)
        guard !limited.isEmpty else {
            processing = false
            scheduleRestart(after: 0.2)
            return
        }
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
        // AVSpeechSynthesizer completion callbacks are not guaranteed in every
        // interruption/audio-route situation. Never let one missing callback
        // permanently block the microphone.
        speechRecoveryTask?.cancel()
        speechRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.armed, !self.paused,
                  self.sessionID == session else { return }
            if self.processing {
                if self.synthesizer.isSpeaking {
                    self.synthesizer.stopSpeaking(at: .immediate)
                }
                self.processing = false
                if self.armed && !self.paused { self.scheduleRestart(after: 0.4) }
            }
        }
    }

    func answerCurrentQuestion() async {
        guard armed && !paused && !processing else { return }
        queueQuestion(transcript)
    }

    func manualAnswer() async {
        guard armed && !paused else { return }
        if processing {
            // Manual override: skip the remaining delay and answer now.
            responseTask?.cancel()
            pendingDelay = nil
            let question = transcript
            guard !question.isEmpty && !synthesizer.isSpeaking else { return }
            await deliverResponse(for: question, normalized: question.lowercased(), session: sessionID)
        } else if looksLikeQuestion(transcript) {
            queueQuestion(transcript)
        } else {
            status = "Ask a question first"
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.speechRecoveryTask?.cancel()
            self.processing = false
            if self.armed && !self.paused { self.scheduleRestart(after: 0.4) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.speechRecoveryTask?.cancel()
            self.processing = false
            if self.armed && !self.paused { self.scheduleRestart(after: 0.4) }
        }
    }

    private func startEngineRecoveryMonitor() {
        engineRecoveryTask?.cancel()
        let currentSession = sessionID
        engineRecoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self, self.armed, !self.paused,
                      self.sessionID == currentSession else { return }
                // When no response is pending, no speech is playing, and
                // recognition has stopped, re-arm the recognizer.
                if !self.processing && !self.listening && !self.synthesizer.isSpeaking {
                    self.scheduleRestart(after: 0.2)
                }
            }
        }
    }

    private func scheduleRestart(after delay: Double) {
        restartTask?.cancel()
        guard armed && !paused else { return }
        status = "Reconnecting microphone"
        let id = sessionID
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.armed, !self.paused, self.sessionID == id else { return }
            await self.beginListening()
        }
    }

    private func stopRecognition() {
        silenceTask?.cancel()
        watchdogTask?.cancel()
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
