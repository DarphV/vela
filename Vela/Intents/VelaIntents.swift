//
//  VelaIntents.swift
//  Vela
//
//  Siri & Kurzbefehle:
//   • "Hey Siri, starte Vela"   → opens the app directly in voice mode
//   • "Hey Siri, frag Vela"     → Siri asks for the question, Vela answers as dialog
//                                  (works from HomePod via "Persönliche Anfragen")
//  App Shortcuts become available after the app has been launched once.
//

import AppIntents
import Foundation

struct StartVelaIntent: AppIntent {
    static let title: LocalizedStringResource = "Vela starten"
    static let description: IntentDescription? = IntentDescription("Öffnet Vela direkt im Sprachmodus.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.openedFromShortcut()
        return .result()
    }
}

struct AskVelaIntent: AppIntent {
    static let title: LocalizedStringResource = "Frag Vela"
    static let description: IntentDescription? = IntentDescription("Stellt Vela eine Frage und gibt die Antwort mit Quelle zurück.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Frage", requestValueDialog: IntentDialog("Was möchtest du Vela fragen?"))
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Frag Vela \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        // TODO(LLM): use model.brain once a real brain exists; the demo brain answers instantly here.
        let answer: VelaAnswer
        if let demo = model.brain as? DemoBrain {
            answer = demo.quickAnswer(to: question)
        } else {
            answer = await model.brain.answer(to: question, history: [])
        }
        model.recordExternalExchange(question: question, answer: answer)

        var text = answer.spoken
        if let source = answer.sources.first {
            text += " Quelle: \(source.chip)."
        }
        if answer.isDemo {
            text += " (Demo-Antwort)"
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct VelaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVelaIntent(),
            phrases: [
                "Starte \(.applicationName)",
                "\(.applicationName) starten",
                "Öffne \(.applicationName)",
                "Hallo \(.applicationName)"
            ],
            shortTitle: "Vela starten",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: AskVelaIntent(),
            phrases: [
                "Frag \(.applicationName)",
                "Frage \(.applicationName)",
                "\(.applicationName) fragen"
            ],
            shortTitle: "Frag Vela",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
    }
}
