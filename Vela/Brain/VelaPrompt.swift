//
//  VelaPrompt.swift
//  Vela
//
//  One German instruction for every engine, plus the retrieved passages.
//

import Foundation

enum VelaPrompt {
    static func instructions(profile: String, summary: String) -> String {
        var text = """
        Du bist Vela, eine freundliche Assistentin auf dem iPhone.
        Antworte immer auf richtigem Deutsch, in ganzen Sätzen, meist zwei bis vier Sätze.
        Achte auf die Verbform. Beziehe dich auf die letzte Nachricht und wiederhole nicht eine frühere Antwort, wenn die neue Nachricht etwas anderes sagt.
        Smalltalk wie „Alles gut“, „Danke“ oder „Hallo“ beantwortest du kurz und natürlich. Dafür brauchst du keine Dokumente und keine Quellen.
        Persönliche Fakten sind kein Zitat. Erwähne sie nur, wenn sie zur Nachricht passen, zum Beispiel „Wie läuft es mit dem Projekt?“. Zähle sie nicht in jeder Antwort auf und schreibe dafür keine eckigen Klammern.
        Dokumentstellen sind nur Hintergrund. Benutze sie nur, wenn sie die letzte Nachricht wirklich beantworten. Sonst ignoriere sie.
        Nur wenn du eine Dokumentstelle wirklich benutzt, nenne sie als [1] oder [2]. Sonst erfinde keine Quellen.
        Keine Überschriften und kein Markdown.
        """
        if !profile.isEmpty {
            text += "\n\nÜber die Person:\n\(profile)"
        }
        if !summary.isEmpty {
            text += "\n\nÄltere Gespräche, nur als Hintergrund:\n\(summary)"
        }
        return text
    }

    /// Earlier turns, without the question that is about to be asked again.
    static func priorTurns(history: [ChatMessage], question: String) -> [(isUser: Bool, text: String)] {
        var turns = Array(history.suffix(8))
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = turns.last, last.role == .user,
           last.text.trimmingCharacters(in: .whitespacesAndNewlines) == asked {
            turns.removeLast()
        }
        return turns.suffix(6).map { (isUser: $0.role == .user, text: String($0.text.prefix(500))) }
    }

    /// The new user turn. History stays outside this string so the chat template can keep the roles.
    static func prompt(question: String, passages: [KnowledgePassage], facts: [MemoryFact]) -> String {
        var parts: [String] = []
        if !facts.isEmpty {
            let lines = facts.prefix(4).map { "- \($0.text)" }.joined(separator: "\n")
            parts.append("Passende persönliche Fakten, nicht zitieren und nur erwähnen wenn es natürlich ist:\n\(lines)")
        }
        if !passages.isEmpty {
            let blocks = passages.enumerated().map { index, passage in
                let body = String(passage.text.prefix(500))
                return "[\(index + 1)] \(passage.source.document), \(passage.source.location)\n\(body)"
            }.joined(separator: "\n\n")
            parts.append("Dokumentstellen, nur verwenden wenn sie die Nachricht wirklich beantworten:\n\(blocks)")
        }
        parts.append(question)
        return parts.joined(separator: "\n\n")
    }

    static func user(question: String, history: [ChatMessage], passages: [KnowledgePassage], facts: [MemoryFact]) -> String {
        var parts: [String] = []
        let prior = priorTurns(history: history, question: question)
        if !prior.isEmpty {
            let lines = prior.map { ($0.isUser ? "Person" : "Vela") + ": \($0.text)" }.joined(separator: "\n")
            parts.append("Bisheriges Gespräch:\n\(lines)")
        }
        parts.append(prompt(question: question, passages: passages, facts: facts))
        return parts.joined(separator: "\n\n")
    }

    static func isSmallTalk(_ text: String) -> Bool {
        var folded = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        folded = folded.folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE"))
        folded = folded.replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
        let phrases: Set<String> = [
            "hallo", "hi", "hey", "moin", "servus", "guten tag", "guten morgen", "guten abend", "gute nacht",
            "danke", "dankeschoen", "vielen dank", "bitte", "ok", "okay", "alles gut", "alles klar", "passt",
            "super", "prima", "cool", "genau", "ja", "nein", "mhm", "wie gehts", "wie geht es dir",
            "mir gehts gut", "gut", "tschuess", "bis dann", "bis bald", "verstanden", "schon gut",
            "kein problem", "na gut", "in ordnung", "alles beste"
        ]
        if phrases.contains(folded) { return true }
        return folded.count <= 28 && contentTokens(folded).isEmpty
    }

    /// Facts are kept only when the person asks about themselves or the words overlap.
    static func relevantFacts(question: String, from facts: [MemoryFact]) -> [MemoryFact] {
        guard !facts.isEmpty, !isSmallTalk(question) else { return [] }
        if question.range(of: #"(?i)\b(über mich|mein name|wer bin ich|erinnerst du|was weißt du|was weisst du)\b"#, options: .regularExpression) != nil {
            return Array(facts.prefix(6))
        }
        let words = contentTokens(question)
        guard !words.isEmpty else { return [] }
        return facts.filter { !words.isDisjoint(with: contentTokens($0.text)) }.prefix(5).map { $0 }
    }

    static func withoutCitations(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\s*\[\d+\]"#, with: "", options: .regularExpression)
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func contentTokens(_ text: String) -> Set<String> {
        let words = text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE"))
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        return Set(words.filter { $0.count >= 4 && !stopwords.contains($0) })
    }

    private static let stopwords: Set<String> = [
        "alles", "aber", "auch", "bist", "bitte", "danke", "dass", "dein", "deine", "dich", "dies", "diese",
        "dieser", "doch", "eine", "einem", "einen", "einer", "eines", "euch", "euer", "fuer", "ganz", "geht",
        "gehts", "gute", "guten", "habe", "haben", "hallo", "hast", "hier", "ihre", "ihrer", "kann", "klar",
        "keine", "keiner", "mein", "meine", "meiner", "mich", "nicht", "noch", "okay", "passt", "prima",
        "schon", "sehr", "seid", "sein", "seine", "sich", "sind", "super", "ueber", "und", "viel", "viele",
        "vom", "von", "warum", "wenn", "werde", "wieder", "wird", "wirst", "wohl"
    ]

    static func blocks(from text: String) -> [AnswerBlock] {
        let cleaned = withoutThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
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
        var result = withoutThinking(text).replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "•", with: "")
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops a Qwen3 thinking block so the chat and the voice never read it.
    static func withoutThinking(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>", options: .caseInsensitive),
              let end = result.range(of: "</think>", options: .caseInsensitive),
              start.lowerBound <= end.lowerBound {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        if let start = result.range(of: "<think>", options: .caseInsensitive) {
            result = String(result[..<start.lowerBound])
        }
        return result
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
