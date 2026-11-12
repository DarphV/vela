//
//  VelaPrompt.swift
//  Vela
//
//  One German instruction for every engine, plus the retrieved passages.
//

import Foundation

enum VelaPrompt {
    static let system = """
    Du bist Vela, eine freundliche und präzise Assistentin. Du antwortest auf Deutsch, klar und ohne Umschweife.
    Wenn die Frage sich aus den mitgelieferten Dokumentstellen beantworten lässt, stütze dich nur darauf und nenne die Quelle im Text als [1], [2] und so weiter.
    Erfinde keine Stellen, keine Seitenzahlen und keine Zitate. Wenn die Dokumente die Frage nicht hergeben oder du unsicher bist, sag das ehrlich.
    Nutze die bekannten Fakten über die Person nur, wenn sie zur Frage passen.
    Antworte in normaler Sprache. Keine Überschriften.
    """

    static func user(question: String, history: [ChatMessage], passages: [KnowledgePassage], facts: [MemoryFact]) -> String {
        var parts: [String] = []
        if !facts.isEmpty {
            let lines = facts.prefix(12).map { "- \($0.text)" }.joined(separator: "\n")
            parts.append("Bekannte Fakten über die Person:\n\(lines)")
        }
        let recent = history.suffix(6).map { message -> String in
            let who = message.role == .user ? "Person" : "Vela"
            return "\(who): \(message.text.prefix(400))"
        }
        if !recent.isEmpty {
            parts.append("Bisheriges Gespräch:\n" + recent.joined(separator: "\n"))
        }
        if !passages.isEmpty {
            let blocks = passages.enumerated().map { index, passage in
                let body = String(passage.text.prefix(700))
                return "[\(index + 1)] \(passage.source.document), \(passage.source.location)\n\(body)"
            }.joined(separator: "\n\n")
            parts.append("Dokumentstellen:\n\(blocks)")
        }
        parts.append("Frage:\n\(question)")
        return parts.joined(separator: "\n\n")
    }

    static func blocks(from text: String) -> [AnswerBlock] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return [.paragraph("Dazu kann ich gerade nichts Sicheres sagen.")]
        }
        var blocks: [AnswerBlock] = []
        for paragraph in cleaned.components(separatedBy: "\n\n") {
            let lines = paragraph.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            let bullets = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("• ") }
            if bullets.count == lines.count {
                blocks.append(.bullets(lines.map { String($0.drop(while: { $0 == "-" || $0 == "*" || $0 == "•" || $0 == " " })) }))
            } else {
                blocks.append(.paragraph(lines.joined(separator: " ")))
            }
        }
        return blocks.isEmpty ? [.paragraph(cleaned)] : blocks
    }

    static func spoken(from text: String) -> String {
        var result = text.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "•", with: "")
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func joined(_ answer: VelaAnswer) -> String {
        answer.blocks.map { block in
            switch block {
            case .paragraph(let text): return text
            case .bullets(let items): return items.map { "• \($0)" }.joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }
}
