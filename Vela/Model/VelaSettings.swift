//
//  VelaSettings.swift
//  Vela
//
//  UserDefaults keys shared by @AppStorage (SettingsView) and the app model.
//

import Foundation

enum VelaSettings {
    static let designKey = "vela.design"        // Int: VelaDesign raw value
    static let voiceKey = "vela.voiceID"        // String: AVSpeechSynthesisVoice identifier, "" = automatisch
    static let ttsKey = "vela.tts"              // Bool: Antworten vorlesen (default true)
    static let webSearchKey = "vela.webSearch"  // Bool: Websuche erlauben (Platzhalter, default false)
    static let engineKey = "vela.engine"        // VelaEngineKind: local, apple, demo
    static let swipeHintKey = "vela.swipeHint"  // Bool: first-launch swipe hint already shown
    static let modelOnboardingKey = "vela.modelOnboarding" // Bool: first-launch model guide finished
    static let modelLoadGuardKey = "vela.modelLoadGuard"   // Bool: previous process died while loading weights
    static let modelChoiceKey = "vela.modelChoice"         // VelaModelKind: fast or smart
    static let autoLearnKey = "vela.autoLearn"             // Bool: learn facts after replies (default true)

    static var design: Int { UserDefaults.standard.integer(forKey: designKey) }
    static var engine: VelaEngineKind {
        let raw = UserDefaults.standard.string(forKey: engineKey) ?? VelaEngineKind.local.rawValue
        return VelaEngineKind(rawValue: raw) ?? .local
    }
    static var voiceID: String { UserDefaults.standard.string(forKey: voiceKey) ?? "" }
    static var ttsEnabled: Bool { UserDefaults.standard.object(forKey: ttsKey) as? Bool ?? true }
    static var webSearchEnabled: Bool { UserDefaults.standard.bool(forKey: webSearchKey) }
    static var autoLearn: Bool { UserDefaults.standard.object(forKey: autoLearnKey) as? Bool ?? true }
}
