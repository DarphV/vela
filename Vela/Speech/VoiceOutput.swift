//
//  VoiceOutput.swift
//  Vela
//
//  Speech output. Streaming replies are synthesized to PCM and scheduled back
//  to back on the shared audio engine, so one phrase starts as the previous
//  one ends. If buffer playback cannot be scheduled, utterances are queued
//  on AVSpeechSynthesizer with no pre/post delay.
//

import AVFoundation
import Foundation

private final class WriteProgress {
    var buffers = 0
}

final class VoiceOutput: NSObject, AVSpeechSynthesizerDelegate {
    /// Called on the main queue when speech starts.
    var onStart: (() -> Void)?
    /// Called on the main queue when speech ends. `cancelled` is true after stop().
    var onFinish: ((_ cancelled: Bool) -> Void)?
    /// Engine that also owns the microphone, so echo cancellation has a reference.
    weak var playback: SpeechListener?

    private let synthesizer = AVSpeechSynthesizer()
    private var epoch = 0
    private var pending = 0
    private var openWrites = 0
    private var epochs: [ObjectIdentifier: Int] = [:]
    private var bufferPathFailed = false
    private let levelLock = NSLock()
    private var level: Float = 0
    private var levelAt = Date.distantPast

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    var isSpeaking: Bool { synthesizer.isSpeaking || pending > 0 }

    var hasPending: Bool { pending > 0 || synthesizer.isSpeaking }

    /// Real output level 0...1 from the PCM just handed to the player.
    var outputLevel: Float {
        levelLock.lock()
        let value = level
        let stamp = levelAt
        levelLock.unlock()
        if Date().timeIntervalSince(stamp) > 0.12 { return 0 }
        return value
    }

    /// Replaces anything currently spoken. Used for the voice preview.
    func speak(_ text: String, voiceID: String) {
        stop()
        enqueue(text, voiceID: voiceID)
    }

    /// Queues the next phrase. Synthesis of this chunk runs while the previous one is still playing.
    func enqueue(_ text: String, voiceID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if bufferPathFailed {
            enqueueUtterance(makeUtterance(trimmed, voiceID: voiceID))
            return
        }
        let token = epoch
        openWrites += 1
        let utterance = makeUtterance(trimmed, voiceID: voiceID)
        let produced = WriteProgress()
        synthesizer.write(utterance) { [weak self] buffer in
            guard let self, token == self.epoch else { return }
            if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                produced.buffers += 1
                let level = Self.level(of: pcm)
                DispatchQueue.main.async {
                    guard token == self.epoch else { return }
                    self.rememberLevel(level)
                    let played: () -> Void = {
                        DispatchQueue.main.async { self.bufferPlayed(token: token) }
                    }
                    if self.playback?.scheduleSpeech(pcm, played: played) == true {
                        self.pending += 1
                        self.onStart?()
                    } else if produced.buffers == 1 {
                        self.failBuffers(token: token, text: trimmed, voiceID: voiceID)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    guard token == self.epoch else { return }
                    self.openWrites = max(0, self.openWrites - 1)
                    if produced.buffers == 0 {
                        self.failBuffers(token: token, text: trimmed, voiceID: voiceID)
                    } else {
                        self.finishIfIdle(token: token, cancelled: false)
                    }
                }
            }
        }
    }

    func stop() {
        epoch += 1
        pending = 0
        openWrites = 0
        epochs.removeAll()
        rememberLevel(0)
        playback?.stopSpeechPlayback()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: Voices

    /// Installed German voices, best quality first.
    static func germanVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("de") }
            .sorted { a, b in
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra > rb }
                if a.language != b.language { return a.language == "de-DE" }
                return a.name < b.name
            }
    }

    static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Erweitert"
        default: return "Standard"
        }
    }

    static func resolveVoice(id: String) -> AVSpeechSynthesisVoice? {
        if !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }
        return germanVoices().first ?? AVSpeechSynthesisVoice(language: "de-DE")
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.onStart?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.completeUtterance(utterance, cancelled: false)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.completeUtterance(utterance, cancelled: true)
        }
    }

    private func makeUtterance(_ text: String, voiceID: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = VoiceOutput.resolveVoice(id: voiceID)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        utterance.prefersAssistiveTechnologySettings = false
        return utterance
    }

    private func enqueueUtterance(_ utterance: AVSpeechUtterance) {
        epochs[ObjectIdentifier(utterance)] = epoch
        pending += 1
        synthesizer.speak(utterance)
    }

    private func completeUtterance(_ utterance: AVSpeechUtterance, cancelled: Bool) {
        let key = ObjectIdentifier(utterance)
        guard epochs[key] == epoch else { return }
        epochs[key] = nil
        pending = max(0, pending - 1)
        finishIfIdle(token: epoch, cancelled: cancelled)
    }

    private func bufferPlayed(token: Int) {
        guard token == epoch else { return }
        pending = max(0, pending - 1)
        finishIfIdle(token: token, cancelled: false)
    }

    private func finishIfIdle(token: Int, cancelled: Bool) {
        guard token == epoch, pending == 0, openWrites == 0 else { return }
        rememberLevel(0)
        onFinish?(cancelled)
    }

    private func failBuffers(token: Int, text: String, voiceID: String) {
        guard token == epoch else { return }
        bufferPathFailed = true
        playback?.stopSpeechPlayback()
        pending = 0
        enqueueUtterance(makeUtterance(text, voiceID: voiceID))
    }

    private func rememberLevel(_ value: Float) {
        levelLock.lock()
        level = value
        levelAt = Date()
        levelLock.unlock()
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        let stride = max(count / 400, 1)
        var used = 0
        var index = 0
        while index < count {
            let sample = channel[index]
            sum += sample * sample
            used += 1
            index += stride
        }
        guard used > 0 else { return 0 }
        let rms = (sum / Float(used)).squareRoot()
        let db = 20 * log10(rms + 1e-7)
        return min(1, max(0, (db + 50) / 32))
    }
}
