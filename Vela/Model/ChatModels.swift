//
//  ChatModels.swift
//  Vela
//

import Foundation

/// A cited passage in a document (shown as source chip + source sheet).
struct VelaSource: Identifiable, Hashable {
    let id: String
    /// Short label on the chip, e.g. "Standard QS-12 · Abschnitt 4.2"
    let chip: String
    /// File name, e.g. "Standard QS-12.pdf"
    let document: String
    /// Location inside the document, e.g. "Abschnitt 4.2 · Seite 17"
    let location: String
    /// Quoted excerpt. Text between `==` markers is highlighted.
    let excerpt: String
}

/// Rich answer content. Strings support inline Markdown (**fett**).
enum AnswerBlock: Hashable {
    case paragraph(String)
    case bullets([String])
}

struct VelaAnswer: Hashable {
    var blocks: [AnswerBlock]
    /// Shorter, natural sentence(s) for speech output and Siri dialogs.
    var spoken: String
    var sources: [VelaSource]
    /// Marks canned demo content ("Demo-Antwort").
    var isDemo: Bool
}

struct ChatMessage: Identifiable, Hashable {
    enum Role: Hashable { case user, assistant }

    let id: UUID
    let role: Role
    let text: String
    let answer: VelaAnswer?
    let date: Date

    static func user(_ text: String, date: Date = Date()) -> ChatMessage {
        ChatMessage(id: UUID(), role: .user, text: text, answer: nil, date: date)
    }

    static func assistant(_ answer: VelaAnswer, date: Date = Date()) -> ChatMessage {
        ChatMessage(id: UUID(), role: .assistant, text: answer.spoken, answer: answer, date: date)
    }

    var timeString: String { ChatMessage.timeFormatter.string(from: date) }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm"
        return f
    }()
}
