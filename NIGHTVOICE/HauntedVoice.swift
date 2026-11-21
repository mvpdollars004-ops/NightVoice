import Foundation
import AVFoundation

/// Renders Apple's speech into an audio engine with actual reverb.
/// The selected voice is a dramatic character preset, not a detected entity.
@MainActor
final class HauntedVoice: NSObject, AVSpeechSynthesizerDelegate {
    enum Character: String, CaseIterable, Identifiable {
        case automatic = "AUTO"
        case masculine = "MALE"
        case feminine = "FEMALE"
        var id: String { rawValue }
    }

    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let reverb = AVAudioUnitReverb()
    private var playbackTask: Task<Void, Never>?
    private var generation = UUID()
    private var speaking = false
    private var finishHandler: (() -> Void)?
    private var sampleFrames: AVAudioFramePosition = 0
    private var startedPlayback = false
    private var pendingFormat: AVAudioFormat?

    var isSpeaking: Bool { speaking }
    var character: Character = .automatic
    var wetDryMix: Float = 47

    override init() {
        super.init()
        synth.delegate = self
        engine.attach(player)
        engine.attach(reverb)
        reverb.loadFactoryPreset(.largeHall)
    }

    func speak(_ words: String, completion: @escaping () -> Void) {
        stop()
        let token = UUID()
        generation = token
        speaking = true
        finishHandler = completion
        sampleFrames = 0
        startedPlayback = false
        pendingFormat = nil
        reverb.wetDryMix = min(85, max(0, wetDryMix))

        let utterance = AVSpeechUtterance(string: words)
        let chosen = chooseCharacter(for: words)
        utterance.voice = findVoice(for: chosen)
        utterance.rate = chosen == .masculine ? 0.39 : 0.43
        utterance.pitchMultiplier = chosen == .masculine ? 0.67 : 0.83
        utterance.volume = 0.95

        // The write callback provides synthesized PCM audio instead of
        // playing it directly. This allows us to process it through reverb.
        synth.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            // Copy PCM because speech synthesis owns the supplied buffer.
            guard pcm.frameLength > 0 else {
                Task { @MainActor [weak self] in self?.finishScheduling(token: token) }
                return
            }
            guard let copied = Self.copyPCM(pcm) else { return }
            Task { @MainActor [weak self] in
                self?.enqueue(copied, token: token)
            }
        }
    }

    private nonisolated static func copyPCM(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let sourceList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceList.count == destList.count else { return nil }
        for index in 0..<sourceList.count {
            let sourceBuffer = sourceList[index]
            let byteCount = Int(sourceBuffer.mDataByteSize)
            if let from = sourceBuffer.mData, let to = destList[index].mData {
                memcpy(to, from, byteCount)
                destList[index].mDataByteSize = sourceBuffer.mDataByteSize
            }
        }
        return copy
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, token: UUID) {
        guard generation == token, speaking else { return }
        if !startedPlayback {
            let format = buffer.format
            pendingFormat = format
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(reverb)
            engine.connect(player, to: reverb, format: format)
            engine.connect(reverb, to: engine.mainMixerNode, format: format)
            do {
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                                                                options: [.defaultToSpeaker, .duckOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
                player.play()
                startedPlayback = true
            } catch {
                // Fail gracefully so the listening loop is never stranded.
                complete(token: token)
                return
            }
        }
        sampleFrames += AVAudioFramePosition(buffer.frameLength)
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func finishScheduling(token: UUID) {
        guard generation == token, speaking else { return }
        // PCM callbacks arrive in order. Allow the queued audio to finish and
        // let the reverb tail decay before reactivating the microphone.
        let seconds = Double(sampleFrames) / max(1, pendingFormat?.sampleRate ?? 22050)
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(12, max(0.6, seconds + 1.1))))
            guard !Task.isCancelled else { return }
            self?.complete(token: token)
        }
    }

    func stop() {
        generation = UUID()
        playbackTask?.cancel()
        playbackTask = nil
        synth.stopSpeaking(at: .immediate)
        player.stop()
        engine.stop()
        speaking = false
        finishHandler = nil
        startedPlayback = false
    }

    private func complete(token: UUID) {
        guard generation == token else { return }
        let handler = finishHandler
        stop()
        handler?()
    }

    private func chooseCharacter(for words: String) -> Character {
        if character != .automatic { return character }
        // Stable within each spoken reply; alternates character presets without
        // suggesting that gender or identity has been measured or discovered.
        return Bool.random() ? .masculine : .feminine
    }

    private func findVoice(for character: Character) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let target: AVSpeechSynthesisVoiceGender = character == .feminine ? .female : .male
        return voices.first(where: { $0.gender == target && $0.language == "en-US" })
            ?? voices.first(where: { $0.gender == target })
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}
