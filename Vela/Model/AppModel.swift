//
//  AppModel.swift
//  Vela
//
//  Central state machine: voice mode ⇄ Glas-Chat, listening → thinking → speaking,
//  speech in/out and the brain. Mirrors the prototype's app.js logic.
//

import Combine
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
    @Published private(set) var showOnboarding = false
    @Published var openSource: VelaSource?
    @Published var showSettings = false
    @Published var streamRevision = 0
    @Published var pendingMacAction: MacAction?
    @Published var showSwipeHint = !UserDefaults.standard.bool(forKey: VelaSettings.swipeHintKey)

    // MARK: Engines
    let driver = VisualDriver()
    let listener = SpeechListener()
    let voice = VoiceOutput()
    let knowledge: LocalKnowledgeStore
    let models: ModelStore
    let brain: VelaEngine
    let mac = MacConnection()

    private var permission: Permission = .unknown
    private var heardText = ""
    private var silenceTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var restartFailures = 0
    private var spokenPrefix = ""
    private var replyToken = 0
    private var replyFinished = false
    private var suggestedSmallerModel = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let store = LocalKnowledgeStore()
        let models = ModelStore()
        knowledge = store
        self.models = models
        brain = VelaEngine(knowledge: store, models: models)
        messages = DemoBrain.welcomeExchange()

        driver.design = VelaSettings.design
        driver.state = state
        voice.playback = listener
        let speech = voice
        driver.levelProvider = { [weak speech, weak listener] in
            let spoken = speech?.outputLevel ?? 0
            if spoken > 0.01 { return spoken }
            return listener?.level ?? 0
        }

        listener.onResult = { [weak self] text, isFinal in
            self?.handleRecognition(text: text, isFinal: isFinal)
        }
        listener.onEnd = { [weak self] error in
            self?.handleRecognitionEnded(error)
        }
        voice.onFinish = { [weak self] cancelled in
            self?.speechQueueDrained(cancelled: cancelled)
        }
        models.onHeavyWork = { [weak self] busy in
            self?.driver.heavyWork = busy
            self?.objectWillChange.send()
        }
        refreshPowerBudget()
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPowerBudget() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPowerBudget() }
            .store(in: &cancellables)

        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }.store(in: &cancellables)
        models.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }.store(in: &cancellables)
        mac.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }.store(in: &cancellables)
        brain.performMac = { [weak self] action in
            await self?.resolveMac(action) ?? "Der Mac ist nicht verbunden."
        }
        prepareScreenshotIfNeeded()
    }

    private func prepareScreenshotIfNeeded() {
        guard let kind = ScreenshotLaunch.kind else { return }
        showSplash = false
        showSwipeHint = false
        switch kind {
        case .voiceNebula:
            driver.design = 0
            setState(.listening)
        case .voiceBlackHole:
            driver.design = 1
            setState(.listening)
        case .voiceNebulaDisk:
            driver.design = 2
            setState(.listening)
        case .chat:
            mode = .chat
            driver.mode = .chat
            setState(.idle)
        case .settings:
            setState(.idle)
            showSettings = true
        }
        for _ in 0..<10 { _ = driver.step(dt: 0.16) }
    }

    // MARK: - State helpers

    private func setState(_ s: VelaState) {
        guard s != state else { return }
        state = s
        driver.state = s
        driver.presenting = s == .thinking || s == .speaking
    }

    func showToast(_ text: String, seconds: Double = 2.4) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func refreshPowerBudget() {
        let thermal = ProcessInfo.processInfo.thermalState
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        driver.conservePower = lowPower || thermal == .fair || thermal == .serious || thermal == .critical
        if models.selected == .smart, thermal == .serious || thermal == .critical, !suggestedSmallerModel {
            suggestedSmallerModel = true
            showToast("Das iPhone ist warm. „1.5B schnell“ in den Einstellungen läuft flüssiger.", seconds: 6)
        }
    }

    func setDesign(_ design: Int) {
        driver.design = design
    }

    func importFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            showToast(error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    let document = try await knowledge.importDocument(at: url)
                    showToast("Gespeichert: \(document.name) · \(document.chunkCount) Abschnitte")
                } catch {
                    showToast(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Lifecycle

    func splashFinished() {
        guard showSplash else { return }
        showSplash = false
        guard ScreenshotLaunch.kind == nil else { return }
        if models.safeMode {
            return
        }
        if needsModelOnboarding {
            showOnboarding = true
            return
        }
        Task { await startVoiceSession() }
    }

    func retryModelLoad() {
        models.clearSafeModeForRetry()
        Task {
            do {
                _ = try await models.container()
                showToast("Das Modell ist bereit.")
                await startVoiceSession()
            } catch {
                showToast("Das Modell konnte nicht geladen werden. Du kannst im Textmodus weiterschreiben.")
                fallBackFromLocalModel()
                toChat()
            }
        }
    }

    func continueInTextMode() {
        models.dismissSafeModeKeepingGuard()
        fallBackFromLocalModel()
        toChat()
    }

    private func fallBackFromLocalModel() {
        let engine: VelaEngineKind = AppleIntelligenceStatus.isAvailable ? .apple : .demo
        UserDefaults.standard.set(engine.rawValue, forKey: VelaSettings.engineKey)
    }

    private func microphoneUnavailable() {
        driver.micActive = false
        setState(.idle)
        subline = "Textmodus"
        showToast("Das Mikrofon lässt sich nicht starten. Du kannst im Textmodus weiterschreiben.")
        if mode == .voice { toChat() }
    }

    private var needsModelOnboarding: Bool {
        ScreenshotLaunch.kind == nil
            && !models.safeMode
            && !models.isInstalled
            && VelaSettings.engine == .local
    }

    func finishModelOnboarding() {
        guard showOnboarding else { return }
        UserDefaults.standard.set(true, forKey: VelaSettings.modelOnboardingKey)
        showOnboarding = false
        Task { await startVoiceSession() }
    }

    func useAppleIntelligenceFromOnboarding() {
        models.cancelDownload()
        UserDefaults.standard.set(VelaEngineKind.apple.rawValue, forKey: VelaSettings.engineKey)
        finishModelOnboarding()
    }

    func sceneBecameActive() {
        guard ScreenshotLaunch.kind == nil else { return }
        AudioSessionManager.activate()
        if models.safeMode { return }
        if mode == .voice && !showSplash && !showSettings && !showOnboarding {
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
        guard ScreenshotLaunch.kind == nil else { return }
        guard mode == .voice else { return }
        if permission == .unknown {
            permission = await SpeechListener.requestPermissions() ? .granted : .denied
        }
        guard permission == .granted else {
            microphoneUnavailable()
            return
        }
        guard AudioSessionManager.activate() else {
            microphoneUnavailable()
            return
        }
        restartFailures = 0
        startListening()
    }

    private func startListening(duringSpeech: Bool = false) {
        guard mode == .voice, !showSplash, !showOnboarding, !showSettings, permission == .granted else { return }
        guard micEnabled else {
            if !duringSpeech {
                setState(.idle)
                subline = "Mikrofon aus"
            }
            return
        }
        if !duringSpeech {
            guard state != .thinking, state != .speaking else { return }
            heardText = ""
        }
        silenceTask?.cancel()
        do {
            try listener.start(hints: knowledge.speechHints)
            driver.micActive = true
            if !duringSpeech {
                setState(.listening)
                subline = listener.isOnDevice ? "Offline-Spracherkennung aktiv" : "Spracherkennung aktiv"
            }
        } catch {
            driver.micActive = false
            if !duringSpeech {
                microphoneUnavailable()
            }
        }
    }

    private func stopListening() {
        silenceTask?.cancel()
        listener.stop()
        driver.micActive = false
    }

    private func handleRecognition(text: String, isFinal: Bool) {
        guard mode == .voice else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if state == .speaking || state == .thinking {
            guard t.count >= 3 else { return }
            bargeIn(heard: t, isFinal: isFinal)
            return
        }
        guard state == .listening else { return }
        heardText = t
        subline = "„\(t)“"
        restartFailures = 0
        silenceTask?.cancel()
        // A final transcript starts the reply immediately. Partials end after ~0.8 s of silence.
        if isFinal {
            finishUtterance()
            return
        }
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.finishUtterance()
        }
    }

    private func handleRecognitionEnded(_ error: Error?) {
        if mode == .voice, state == .speaking || state == .thinking {
            return
        }
        guard mode == .voice, state == .listening else { return }
        if !heardText.isEmpty {
            finishUtterance()
            return
        }
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

    /// The user started talking over Vela. Cut playback and take the new turn.
    private func bargeIn(heard: String, isFinal: Bool) {
        replyToken += 1
        voice.stop()
        spokenPrefix = ""
        replyFinished = true
        heardText = heard
        setState(.listening)
        subline = "„\(heard)“"
        restartFailures = 0
        silenceTask?.cancel()
        if isFinal {
            finishUtterance()
            return
        }
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.finishUtterance()
        }
    }

    // MARK: - Asking

    func sendText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Haptics.light()
        Task { await ask(t, fromVoice: false) }
    }

    private func ask(_ question: String, fromVoice: Bool) async {
        replyToken += 1
        let token = replyToken
        voice.stop()
        stopListening()
        spokenPrefix = ""
        replyFinished = false
        knowledge.rememberIfPersonal(question)
        messages.append(.user(question))
        if !fromVoice {
            try? await Task.sleep(for: .milliseconds(250))
            isTyping = true
        }
        setState(.thinking)
        refreshPowerBudget()
        var messageID: UUID?
        let answer = await brain.streamAnswer(to: question, history: messages) { [weak self] text in
            guard let self, token == self.replyToken else { return }
            self.isTyping = false
            if messageID == nil {
                var message = ChatMessage.assistant(VelaAnswer(blocks: [.paragraph(text)], spoken: text, sources: [], isDemo: false))
                message.text = text
                messageID = message.id
                self.messages.append(message)
                self.setState(.speaking)
            } else if let id = messageID, let index = self.messages.firstIndex(where: { $0.id == id }) {
                self.messages[index].text = text
                self.messages[index].answer = VelaAnswer(blocks: [.paragraph(text)], spoken: text, sources: [], isDemo: false)
            }
            self.streamRevision += 1
            await self.feedSpeech(text, flush: false)
        }
        guard token == replyToken else { return }
        isTyping = false
        if let id = messageID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = VelaPrompt.joined(answer)
            messages[index].answer = answer
        } else {
            messages.append(.assistant(answer))
        }
        streamRevision += 1
        await feedSpeech(VelaPrompt.joined(answer), flush: true)
        replyFinished = true
        if !VelaSettings.ttsEnabled || !voice.hasPending {
            speechFinished(cancelled: false)
        }
    }

    /// Speaks one finished sentence at a time. Synthesis finishes before the next
    /// sentence is generated, and the microphone stays off while the buffers play.
    private func feedSpeech(_ full: String, flush: Bool) async {
        guard VelaSettings.ttsEnabled else { return }
        let token = replyToken
        let spoken = VelaPrompt.spoken(from: full)
        guard spoken.hasPrefix(spokenPrefix) else { return }
        var rest = String(spoken.dropFirst(spokenPrefix.count))
        while let taken = takeSpeechChunk(from: rest, flush: flush) {
            guard token == replyToken else { return }
            let chunk = taken.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { break }
            setState(.speaking)
            await voice.playSentence(chunk, voiceID: VelaSettings.voiceID)
            guard token == replyToken else { return }
            spokenPrefix += taken.raw
            rest = String(rest.dropFirst(taken.raw.count))
        }
    }

    private func takeSpeechChunk(from rest: String, flush: Bool) -> (text: String, raw: String)? {
        let lead = rest.prefix { $0.isWhitespace }.count
        let body = String(rest.dropFirst(lead))
        guard !body.isEmpty else { return nil }
        let cut: Int
        if flush {
            cut = body.count
        } else if let end = sentenceCut(in: body) {
            cut = end
        } else if body.count >= 240, let end = lastBoundary(in: body, max: 240, min: 80) {
            cut = end
        } else {
            return nil
        }
        let rawCount = lead + cut
        let text = String(body.prefix(cut))
        return (text, String(rest.prefix(rawCount)))
    }

    /// End of the first complete sentence, including its closing mark.
    private func sentenceCut(in text: String) -> Int? {
        var count = 0
        var index = text.startIndex
        while index < text.endIndex {
            count += 1
            let mark = text[index]
            let next = text.index(after: index)
            if ".!?…".contains(mark), count >= 8, next == text.endIndex || text[next].isWhitespace || text[next].isNewline {
                return count
            }
            index = next
        }
        return nil
    }

    /// Last sentence or clause end inside `max` characters, at least `min` in.
    private func lastBoundary(in text: String, max: Int, min: Int) -> Int? {
        var best: Int?
        var count = 0
        var index = text.startIndex
        while index < text.endIndex, count < max {
            count += 1
            let next = text.index(after: index)
            let mark = text[index]
            let boundary = ".!?…".contains(mark) || (count >= min && ",;:".contains(mark)) || mark.isNewline
            if boundary, count >= min { best = count }
            index = next
        }
        if best == nil, count >= min, let space = text.prefix(max).lastIndex(of: " ") {
            return text.distance(from: text.startIndex, to: space)
        }
        return best
    }

    private func sentenceEnd(in text: Substring) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if ".!?…".contains(character) || character.isNewline {
                let next = text.index(after: index)
                if next == text.endIndex || text[next].isWhitespace || text[next].isNewline {
                    return next
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func speechQueueDrained(cancelled: Bool) {
        guard replyFinished || cancelled else { return }
        speechFinished(cancelled: cancelled)
    }

    private func speechFinished(cancelled: Bool) {
        guard !cancelled, state == .speaking || state == .thinking else { return }
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
        Haptics.light()
        stopListening()
        voice.stop()
        mode = .chat
        driver.mode = .chat
        if state != .thinking { setState(.idle) }
    }

    func toVoice() {
        guard mode == .chat else { return }
        Haptics.light()
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

    func setMic(_ enabled: Bool) {
        guard enabled != micEnabled else { return }
        toggleMic()
    }

    func dismissSwipeHint() {
        guard showSwipeHint else { return }
        showSwipeHint = false
        UserDefaults.standard.set(true, forKey: VelaSettings.swipeHintKey)
    }

    func resolveMac(_ action: MacAction) async -> String {
        guard mac.isPaired else { return "Zuerst den Mac unter Einstellungen koppeln." }
        if !mac.isOn(action.name) {
            return "Diese Berechtigung ist auf dem Mac aus."
        }
        if mac.needsConfirmation(action.name) {
            pendingMacAction = action
            return "Bitte einmal auf dem iPhone bestätigen."
        }
        let result = await mac.perform(action, confirm: false)
        if result == "CONFIRM" {
            pendingMacAction = action
            return "Bitte einmal auf dem iPhone bestätigen."
        }
        return result
    }

    func approvePendingMac() {
        guard let action = pendingMacAction else { return }
        pendingMacAction = nil
        Task { await reportMac(action) }
    }

    private func reportMac(_ action: MacAction) async {
        let result = await mac.perform(action, confirm: true)
        showToast(result)
        if mode == .chat {
            messages.append(.assistant(VelaAnswer(blocks: [.paragraph(result)], spoken: result, sources: [], isDemo: false)))
        }
        if mode != .chat, VelaSettings.ttsEnabled {
            voice.enqueue(result, voiceID: VelaSettings.voiceID)
        }
    }
}
