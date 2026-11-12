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

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ text: String, voiceID: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = VoiceOutput.resolveVoice(id: voiceID)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }

    func stop() {
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
            self?.onFinish?(false)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.onFinish?(true)
        }
    }
}
