//
//  AppModel.swift
//  Vela
//
//  Central state machine: voice mode ⇄ Glas-Chat, listening → thinking → speaking,
//  speech in/out and the brain. Mirrors the prototype's app.js logic.
//

import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Permission { case unknown, granted, denied }

    // MARK: Published UI state
    @Published private(set) var mode: VelaMode = .voice
    @Published private(set) var state: VelaState = .idle
    @Published var messages: [ChatMessage]
    @Published private(set) var isTyping = false
    @Published private(set) var subline = "Sprachmodus"
    @Published private(set) var micEnabled = true
    @Published private(set) var toast: String?
    @Published private(set) var showSplash = true
    @Published var openSource: VelaSource?
    @Published var showSettings = false

    // MARK: Engines
    let driver = VisualDriver()
    let listener = SpeechListener()
    let voice = VoiceOutput()
    let knowledge: KnowledgeStore
    let brain: VelaBrain

    private var permission: Permission = .unknown
    private var heardText = ""
    private var silenceTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var restartFailures = 0

    private init() {
        let store = DemoKnowledgeStore()
        knowledge = store
        // TODO(LLM): switch to LocalLLMBrain(knowledge: store) once the model is integrated.
        brain = DemoBrain()
        messages = DemoBrain.welcomeExchange()

        driver.design = VelaSettings.design
        driver.state = state
        let listener = self.listener
        driver.levelProvider = { listener.level }

        listener.onResult = { [weak self] text, isFinal in
            self?.handleRecognition(text: text, isFinal: isFinal)
        }
        listener.onEnd = { [weak self] error in
            self?.handleRecognitionEnded(error)
        }
        voice.onFinish = { [weak self] cancelled in
            self?.speechFinished(cancelled: cancelled)
        }
    }

    // MARK: - State helpers

    private func setState(_ s: VelaState) {
        guard s != state else { return }
        state = s
        driver.state = s
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2400))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func setDesign(_ design: Int) {
        driver.design = design
    }

    // MARK: - Lifecycle

    func splashFinished() {
        guard showSplash else { return }
        showSplash = false
        Task { await startVoiceSession() }
    }

    func sceneBecameActive() {
        AudioSessionManager.activate()
        if mode == .voice && !showSplash && !showSettings {
            Task { await startVoiceSession() }
        }
    }

    func sceneWentToBackground() {
        silenceTask?.cancel()
        listener.stop()
        driver.micActive = false
        voice.stop()
        if state != .thinking { setState(.idle) }
    }

    /// "Hey Siri, starte Vela" → app opens directly in voice mode.
    func openedFromShortcut() {
        showSettings = false
        openSource = nil
        if mode == .chat {
            toVoice()
        } else if !showSplash {
            Task { await startVoiceSession() }
        }
    }

    // MARK: - Voice session

    func startVoiceSession() async {
        guard mode == .voice else { return }
        if permission == .unknown {
            permission = await SpeechListener.requestPermissions() ? .granted : .denied
        }
        AudioSessionManager.activate()
        guard permission == .granted else {
            setState(.idle)
            subline = "Mikrofon oder Spracherkennung nicht erlaubt · bitte in den iOS-Einstellungen freigeben"
            return
        }
        restartFailures = 0
        startListening()
    }

    private func startListening() {
        guard mode == .voice, !showSplash, !showSettings, permission == .granted else { return }
        guard micEnabled else {
            setState(.idle)
            subline = "Mikrofon aus"
            return
        }
        guard state != .thinking, state != .speaking else { return }
        heardText = ""
        silenceTask?.cancel()
        do {
            try listener.start()
            driver.micActive = true
            setState(.listening)
            subline = listener.isOnDevice ? "Offline-Spracherkennung aktiv" : "Spracherkennung aktiv"
        } catch {
            driver.micActive = false
            setState(.idle)
            subline = error.localizedDescription
        }
    }

    private func stopListening() {
        silenceTask?.cancel()
        listener.stop()
        driver.micActive = false
    }

    private func handleRecognition(text: String, isFinal: Bool) {
        guard mode == .voice, state == .listening else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        heardText = t
        subline = "„\(t)“"
        restartFailures = 0
        silenceTask?.cancel()
        if isFinal {
            finishUtterance()
            return
        }
        // End of utterance after 1.2 s without new words (prototype VAD: silence > 1.2 s).
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.finishUtterance()
        }
    }

    private func handleRecognitionEnded(_ error: Error?) {
        guard mode == .voice, state == .listening else { return }
        if !heardText.isEmpty {
            finishUtterance()
            return
        }
        // Nothing heard (timeout / no speech): restart quietly, give up after a few failures.
        stopListening()
        restartFailures += 1
        if restartFailures > 5 {
            setState(.idle)
            subline = "Spracherkennung pausiert · tippe auf das Mikrofon"
            micEnabled = false
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.startListening()
        }
    }

    private func finishUtterance() {
        silenceTask?.cancel()
        let question = heardText
        heardText = ""
        stopListening()
        guard !question.isEmpty else {
            startListening()
            return
        }
        Task { await ask(question, fromVoice: true) }
    }

    // MARK: - Asking

    func sendText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task { await ask(t, fromVoice: false) }
    }

    private func ask(_ question: String, fromVoice: Bool) async {
        voice.stop()
        messages.append(.user(question))
        if !fromVoice {
            try? await Task.sleep(for: .milliseconds(250))
            isTyping = true
        }
        setState(.thinking)
        let answer = await brain.answer(to: question, history: messages)
        isTyping = false
        messages.append(.assistant(answer))
        respond(with: answer)
    }

    private func respond(with answer: VelaAnswer) {
        setState(.speaking)
        if VelaSettings.ttsEnabled {
            AudioSessionManager.activate()
            voice.speak(answer.spoken, voiceID: VelaSettings.voiceID)
        } else {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(3500))
                self?.speechFinished(cancelled: false)
            }
        }
    }

    private func speechFinished(cancelled: Bool) {
        guard !cancelled, state == .speaking else { return }
        setState(.idle)
        if mode == .voice {
            startListening()
        }
    }

    /// Siri/Shortcuts asked a question while the app was in the background.
    func recordExternalExchange(question: String, answer: VelaAnswer) {
        messages.append(.user(question))
        messages.append(.assistant(answer))
    }

    // MARK: - Mode switching

    func toChat() {
        guard mode == .voice else { return }
        stopListening()
        voice.stop()
        mode = .chat
        driver.mode = .chat
        if state != .thinking { setState(.idle) }
    }

    func toVoice() {
        guard mode == .chat else { return }
        voice.stop()
        mode = .voice
        driver.mode = .voice
        if state == .speaking { setState(.idle) }
        if permission == .unknown {
            Task { await startVoiceSession() }
        } else {
            restartFailures = 0
            startListening()
        }
    }

    func toggleMic() {
        micEnabled.toggle()
        if micEnabled {
            restartFailures = 0
            Task { await startVoiceSession() }
        } else {
            stopListening()
            if state == .listening { setState(.idle) }
            subline = "Mikrofon aus"
        }
    }

    // MARK: - Sheets

    func settingsWillOpen() {
        stopListening()
        voice.stop()
        if state == .listening || state == .speaking { setState(.idle) }
    }

    func settingsDidClose() {
        if mode == .voice {
            Task { await startVoiceSession() }
        }
    }

    func previewVoice(id: String) {
        voice.speak("Hallo, ich bin Vela. So klinge ich mit dieser Stimme.", voiceID: id)
    }
}
