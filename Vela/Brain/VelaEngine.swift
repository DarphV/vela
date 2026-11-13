//
//  VelaEngine.swift
//  Vela
//
//  Picks the engine from the settings. Without a downloaded model, Vela
//  stays on the demo brain and says so.
//

import Foundation

enum VelaEngineKind: String {
    case local
    case apple
    case demo
}

@MainActor
final class VelaEngine: VelaBrain {
    let demo = DemoBrain()
    let local: LocalLLMBrain
    let apple: AppleIntelligenceBrain
    private let models: ModelStore
    var performMac: ((MacAction) async -> String)?
    var olderSummary = "" {
        didSet {
            local.olderSummary = olderSummary
            apple.olderSummary = olderSummary
        }
    }

    init(knowledge: LocalKnowledgeStore, models: ModelStore) {
        self.models = models
        local = LocalLLMBrain(knowledge: knowledge, models: models)
        apple = AppleIntelligenceBrain(knowledge: knowledge)
    }

    var displayName: String {
        switch resolved {
        case .local: return local.displayName
        case .apple: return apple.displayName
        case .demo: return demo.displayName
        }
    }

    var isOffline: Bool { true }

    private var resolved: VelaEngineKind {
        switch VelaSettings.engine {
        case .apple where AppleIntelligenceStatus.isAvailable:
            return .apple
        case .local where models.isInstalled:
            return .local
        case .demo:
            return .demo
        default:
            return .demo
        }
    }

    private var needsHint: Bool {
        switch VelaSettings.engine {
        case .demo: return false
        case .apple: return !AppleIntelligenceStatus.isAvailable
        case .local: return !models.isInstalled
        }
    }

    func answer(to question: String, history: [ChatMessage]) async -> VelaAnswer {
        await streamAnswer(to: question, history: history) { _ in }
    }

    func streamAnswer(to question: String, history: [ChatMessage], onUpdate: @escaping @MainActor (String) async -> Void) async -> VelaAnswer {
        if let action = MacToolRouter.match(question) {
            let text = await performMac?(action) ?? "Der Mac ist nicht verbunden."
            await onUpdate(text)
            return VelaAnswer(blocks: [.paragraph(text)], spoken: text, sources: [], isDemo: false)
        }
        if resolved == .local && !models.safeMode {
            do {
                _ = try await models.container()
            } catch {
                let engine: VelaEngineKind = AppleIntelligenceStatus.isAvailable ? .apple : .demo
                UserDefaults.standard.set(engine.rawValue, forKey: VelaSettings.engineKey)
                let fallback: any VelaBrain = engine == .apple ? apple : demo
                let answer = await fallback.streamAnswer(to: question, history: history, onUpdate: onUpdate)
                return withModelNotice(answer)
            }
        }
        let brain: any VelaBrain
        switch resolved {
        case .local: brain = local
        case .apple: brain = apple
        case .demo: brain = demo
        }
        let answer = await brain.streamAnswer(to: question, history: history, onUpdate: onUpdate)
        guard needsHint else { return answer }
        let hinted = withHint(answer)
        await onUpdate(VelaPrompt.joined(hinted))
        return hinted
    }

    func learnFacts(from message: String, known: [String], stop: LearnStop) async -> [FactDraft] {
        guard resolved == .local, !models.safeMode else { return [] }
        return await local.learnFacts(from: message, known: known, stop: stop)
    }

    private func withModelNotice(_ answer: VelaAnswer) -> VelaAnswer {
        var copy = answer
        let notice = "Das lokale Modell konnte nicht geladen werden. Vela antwortet ohne es."
        copy.blocks.insert(.paragraph(notice), at: 0)
        copy.spoken = notice + " " + copy.spoken
        return copy
    }

    private func withHint(_ answer: VelaAnswer) -> VelaAnswer {
        var copy = answer
        copy.blocks.append(.paragraph("Hinweis: Das ist eine Demo-Antwort. Unter Einstellungen kannst du das KI-Modell laden."))
        copy.spoken += " Hinweis: Das ist eine Demo-Antwort. Das KI-Modell ist noch nicht geladen."
        copy.isDemo = true
        return copy
    }
}
