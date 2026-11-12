//
//  VoiceOutput.swift
//  Vela
//
//  Speech output with AVSpeechSynthesizer. Prefers Premium > Erweitert > Standard
//  German voices. Premium voices must be downloaded once by the user:
//  iOS-Einstellungen › Bedienungshilfen › Gesprochene Inhalte › Stimmen › Deutsch.
//
//  TODO(Stimme): "Offline-KI-Stimme" (Piper/Kokoro via ONNX/MLX) and "Online-Premium"
//  (e.g. ElevenLabs) plug in behind the same speak/stop interface.
//

import AVFoundation
import Foundation

final class VoiceOutput: NSObject, AVSpeechSynthesizerDelegate {
    /// Called on the main queue when speech starts.
    var onStart: (() -> Void)?
    /// Called on the main queue when speech ends. `cancelled` is true after stop().
    var onFinish: ((_ cancelled: Bool) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var epoch = 0
    private var pending = 0
    private var epochs: [ObjectIdentifier: Int] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }
    var hasPending: Bool { pending > 0 }

    /// Replaces anything currently spoken. Used for the voice preview.
    func speak(_ text: String, voiceID: String) {
        stop()
        enqueue(text, voiceID: voiceID)
    }

    /// Queues the next sentence without cutting off the one already playing.
    func enqueue(_ text: String, voiceID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = VoiceOutput.resolveVoice(id: voiceID)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.prefersAssistiveTechnologySettings = false
        epochs[ObjectIdentifier(utterance)] = epoch
        pending += 1
        synthesizer.speak(utterance)
    }

    func stop() {
        epoch += 1
        pending = 0
        epochs.removeAll()
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
            self?.complete(utterance, cancelled: false)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.complete(utterance, cancelled: true)
        }
    }

    private func complete(_ utterance: AVSpeechUtterance, cancelled: Bool) {
        let key = ObjectIdentifier(utterance)
        guard epochs[key] == epoch else { return }
        epochs[key] = nil
        pending = max(0, pending - 1)
        if pending == 0 {
            onFinish?(cancelled)
        }
    }
}
