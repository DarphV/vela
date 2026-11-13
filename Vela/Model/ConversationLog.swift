//
//  ConversationLog.swift
//  Vela
//
//  The last turns stay on the phone. Older ones collapse into one short line.
//

import Foundation

enum ConversationLog {
    private struct File: Codable {
        var summary: String
        var turns: [Turn]
    }

    private struct Turn: Codable {
        var role: String
        var text: String
        var date: TimeInterval
    }

    static func load() -> (messages: [ChatMessage], summary: String)? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        let messages = file.turns.compactMap { turn -> ChatMessage? in
            let date = Date(timeIntervalSince1970: turn.date)
            if turn.role == "user" {
                return ChatMessage.user(turn.text, date: date)
            }
            let answer = VelaAnswer(blocks: [.paragraph(turn.text)], spoken: turn.text, sources: [], isDemo: false)
            return ChatMessage.assistant(answer, date: date)
        }
        guard !messages.isEmpty else { return nil }
        return (messages, file.summary)
    }

    static func save(messages: [ChatMessage], summary: String) {
        let turns = messages.suffix(24).map { message in
            Turn(role: message.role == .user ? "user" : "assistant", text: message.text, date: message.date.timeIntervalSince1970)
        }
        let file = File(summary: summary, turns: Array(turns))
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static var url: URL {
        VelaPaths.root.appendingPathComponent("conversation.json")
    }
}
