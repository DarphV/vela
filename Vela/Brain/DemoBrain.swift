//
//  DemoBrain.swift
//  Vela
//
//  Canned German answers from the web prototype, each with a cited source.
//  Every answer is marked as "Demo-Antwort" in the UI.
//

import Foundation

@MainActor
final class DemoBrain: VelaBrain {
    let displayName = "Demo"
    let isOffline = true

    /// Simulated thinking time (prototype: 1.7–2.4 s incl. typing indicator).
    var simulatedDelay: ClosedRange<Int> = 1450...2150
    private var nextIndex = 0

    func answer(to question: String, history: [ChatMessage]) async -> VelaAnswer {
        try? await Task.sleep(for: .milliseconds(Int.random(in: simulatedDelay)))
        return Self.match(question, fallbackIndex: &nextIndex)
    }

    /// Answers instantly (used by the Siri intent).
    func quickAnswer(to question: String) -> VelaAnswer {
        Self.match(question, fallbackIndex: &nextIndex)
    }

    private static func match(_ question: String, fallbackIndex: inout Int) -> VelaAnswer {
        if let hit = entries.first(where: { question.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive]) != nil }) {
            return hit.answer
        }
        let a = entries[fallbackIndex % entries.count].answer
        fallbackIndex += 1
        return a
    }

    // MARK: - Demo sources (prototype: SRC)

    static let qs12 = VelaSource(
        id: "qs12", chip: "Standard QS-12 · Abschnitt 4.2", document: "Standard QS-12.pdf", location: "Abschnitt 4.2 · Seite 17",
        excerpt: "4.2 Prüfprotokoll — Jedes Prüfprotokoll ist ==vollständig und eindeutig== zu führen. Es enthält Prüfgegenstand, Prüfdatum, Prüfer sowie die verwendeten Messmittel. Abweichungen sind zu begründen und mit den getroffenen Korrekturmaßnahmen zu dokumentieren. Das Protokoll wird nach Freigabe ==zehn Jahre archiviert==.")

    static let hb42 = VelaSource(
        id: "hb42", chip: "Handbuch.pdf · Seite 42", document: "Handbuch.pdf", location: "Kapitel 6 · Seite 42",
        excerpt: "6.3 Export — Wählen Sie ==Datei › Exportieren › Video==. Unter „Format“ stellen Sie MP4 (H.264) ein. Für die Weitergabe per E-Mail empfiehlt sich die Voreinstellung „Kompakt“. Der Export läuft im Hintergrund weiter, ==das Projekt bleibt währenddessen bearbeitbar==.")

    static let qs07 = VelaSource(
        id: "qs07", chip: "Standard QS-07 · Abschnitt 3.1", document: "Standard QS-07.pdf", location: "Abschnitt 3.1 · Seite 9",
        excerpt: "3.1 Prüfmittelüberwachung — Messmittel sind ==vor dem ersten Einsatz und danach jährlich== zu kalibrieren. Die Kalibrierung ist mit Datum, Ergebnis und nächster Fälligkeit auf dem Prüfmittel zu kennzeichnen. Messmittel mit abgelaufener Kalibrierung ==dürfen nicht verwendet werden==.")

    static let bh118 = VelaSource(
        id: "bh118", chip: "Betriebshandbuch.pdf · Seite 118", document: "Betriebshandbuch Anlage 3.pdf", location: "Störungen · Seite 118",
        excerpt: "Fehlercode E-17: Druckabfall im Hydraulikkreis. Maßnahmen: ==Anlage in den sicheren Zustand fahren==, Füllstand am Schauglas prüfen, Filter auf Verschmutzung kontrollieren. Tritt der Fehler nach dem Quittieren erneut auf, ==Instandhaltung verständigen==.")

    static let ks03 = VelaSource(
        id: "ks03", chip: "Standard KS-03 · Abschnitt 5.4", document: "Standard KS-03.docx", location: "Abschnitt 5.4",
        excerpt: "5.4 Freigabe — Zeichnungen gelten erst nach ==Prüfung durch eine zweite Person== als freigegeben. Die Freigabe erfolgt im Schriftfeld mit Name, Datum und Revisionsstand. Bei Änderungen ist der ==Revisionsindex hochzuzählen== und die Änderung in der Änderungstabelle zu beschreiben.")

    // MARK: - Demo answers (prototype: ANSWERS)

    private struct Entry {
        let pattern: String
        let answer: VelaAnswer
    }

    private static let entries: [Entry] = [
        Entry(pattern: "export|mp4|video|speicher", answer: VelaAnswer(
            blocks: [
                .paragraph("So exportierst du laut Handbuch als MP4:"),
                .bullets(["**Menü:** Datei › Exportieren › Video",
                          "**Format:** MP4 (H.264) auswählen",
                          "**Tipp:** Für E-Mails die Voreinstellung „Kompakt“ nehmen"]),
                .paragraph("Du kannst währenddessen weiterarbeiten, der Export läuft im Hintergrund.")
            ],
            spoken: "Zum Exportieren gehst du auf Datei, Exportieren, Video und wählst als Format MP4. Für E-Mails nimmst du am besten die Voreinstellung Kompakt.",
            sources: [hb42], isDemo: true)),
        Entry(pattern: "kalib|messmittel|prüfmittel", answer: VelaAnswer(
            blocks: [
                .paragraph("Für Messmittel gilt nach Standard QS-07:"),
                .bullets(["**Wann:** vor dem ersten Einsatz, danach jährlich kalibrieren",
                          "**Kennzeichnung:** Datum, Ergebnis und nächste Fälligkeit am Messmittel",
                          "**Abgelaufen?** Dann darf es nicht verwendet werden."])
            ],
            spoken: "Messmittel musst du vor dem ersten Einsatz und danach jährlich kalibrieren. Ist die Kalibrierung abgelaufen, darfst du das Messmittel nicht verwenden.",
            sources: [qs07], isDemo: true)),
        Entry(pattern: "fehler|e-?17|störung|druck|alarm", answer: VelaAnswer(
            blocks: [
                .paragraph("**E-17** bedeutet Druckabfall im Hydraulikkreis. Das Betriebshandbuch empfiehlt:"),
                .bullets(["Anlage in den **sicheren Zustand** fahren",
                          "Füllstand am Schauglas prüfen",
                          "Filter auf Verschmutzung kontrollieren"]),
                .paragraph("Tritt der Fehler nach dem Quittieren wieder auf, die Instandhaltung verständigen.")
            ],
            spoken: "Fehler E siebzehn bedeutet Druckabfall im Hydraulikkreis. Fahr die Anlage in den sicheren Zustand, prüf den Füllstand und den Filter. Kommt der Fehler wieder, sag der Instandhaltung Bescheid.",
            sources: [bh118], isDemo: true)),
        Entry(pattern: "zeichnung|freigabe|revision", answer: VelaAnswer(
            blocks: [
                .paragraph("Nach Standard KS-03 gilt für die Freigabe:"),
                .bullets(["**Vier-Augen-Prinzip:** Prüfung durch eine zweite Person",
                          "**Schriftfeld:** Name, Datum und Revisionsstand eintragen",
                          "**Änderungen:** Revisionsindex hochzählen und in der Änderungstabelle beschreiben"])
            ],
            spoken: "Eine Zeichnung ist erst freigegeben, wenn eine zweite Person sie geprüft hat. Bei Änderungen zählst du den Revisionsindex hoch und trägst die Änderung in die Tabelle ein.",
            sources: [ks03], isDemo: true)),
        Entry(pattern: "protokoll|prüf", answer: VelaAnswer(
            blocks: [
                .paragraph("Kurz zusammengefasst aus Standard QS-12:"),
                .bullets(["**Vollständig:** alle Prüfpunkte und Messwerte",
                          "**Eindeutig:** Gegenstand, Datum, Prüfer, Messmittel",
                          "**Archivierung:** zehn Jahre nach Freigabe"])
            ],
            spoken: "Wichtig sind Vollständigkeit, eindeutige Angaben, nachvollziehbare Abweichungen und die Archivierung für zehn Jahre.",
            sources: [qs12], isDemo: true))
    ]

    /// The exchange the prototype shows when the chat opens for the first time.
    static func welcomeExchange() -> [ChatMessage] {
        let now = Date()
        let answer = VelaAnswer(
            blocks: [
                .paragraph("Beim Prüfprotokoll nach Standard QS-12 sind folgende Punkte besonders wichtig:"),
                .bullets(["**Vollständigkeit:** Alle geforderten Prüfpunkte, Messwerte und Beobachtungen dokumentieren.",
                          "**Eindeutigkeit:** Prüfgegenstand, Prüfdatum, Prüfer und verwendete Messmittel klar angeben.",
                          "**Nachvollziehbarkeit:** Abweichungen, Korrekturmaßnahmen und Entscheidungen begründen.",
                          "**Aufbewahrung:** Das Protokoll zehn Jahre nach Freigabe archivieren."]),
                .paragraph("Halte dich eng an die Vorlage in Abschnitt 4.2.")
            ],
            spoken: "Wichtig sind Vollständigkeit, Eindeutigkeit, Nachvollziehbarkeit und die Aufbewahrung für zehn Jahre.",
            sources: [qs12], isDemo: true)
        return [.user("Was muss ich beim Prüfprotokoll beachten?", date: now), .assistant(answer, date: now)]
    }
}
