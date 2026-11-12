# Vela – iPhone-App (Gerüst 0.1)

Vela ist deine eigene kleine KI fürs iPhone: startet direkt im **Sprachmodus**, wechselt
beim Antippen in den **Glas-Chat**, zeigt zu jeder Antwort die **Quelle** und lässt sich mit
**„Hey Siri, starte Vela“** öffnen. Design 1:1 aus dem Web-Prototyp übernommen.

> Stand: Gerüst. Die Antworten kommen noch aus einem **Demo-Gehirn** (feste Beispielantworten,
> markiert mit „Demo-Antwort“). Lokale KI und Dokument-Import folgen im nächsten Schritt.

## Was schon drin ist

| Bereich | Status |
|---|---|
| 3 Live-Visuals als Metal-Shader (Nebula, Schwarzes Loch klassisch, Schwarzes Loch Nebula) | ✅ reagieren auf Zuhören / Denken / Sprechen und auf die Lautstärke |
| Sprachmodus beim Start, Tippen → Glas-Chat, Mikrofon-Knopf → zurück | ✅ |
| Glas-Chat mit Glas-Blasen, Quellen-Chips, Quellen-Ansicht mit markierten Stellen | ✅ (iOS 26: echtes Liquid Glass, iOS 18: Milchglas) |
| Spracherkennung Deutsch (wenn möglich offline auf dem iPhone) | ✅ |
| Sprachausgabe mit der besten deutschen Apple-Stimme, auch über AirPlay/Bluetooth | ✅ |
| Einstellungen: Design, Stimme, Vorlesen, Websuche (Platzhalter) | ✅ werden gespeichert |
| Siri: „Starte Vela“, „Frag Vela“ (auch vom HomePod über Persönliche Anfragen) | ✅ |
| Lokale KI (MLX, Qwen 2.5 1.5B 4-bit) | ✅ wird in den Einstellungen geladen, streamt in die Blase; ohne Modell Demo mit Hinweis |
| Apple Intelligence (iOS 26) | ✅ wählbar, wenn das Gerät es hat |
| Handbücher importieren und durchsuchen (PDF, TXT, MD, DOCX) | ✅ Quellen-Chips und „Im Dokument öffnen“ |
| Gedächtnis | ✅ Fakten, die du Vela über dich sagst, lokal |
| Offline-KI-Stimme / Online-Premium-Stimme | ⏳ in den Einstellungen als „folgt“ |

## Aufbau

```
vela-ios/
├─ project.yml                  XcodeGen-Projektbeschreibung (daraus entsteht Vela.xcodeproj)
├─ Support/Info.plist           wird von XcodeGen erzeugt (deutsche Texte für Mikrofon/Sprache)
├─ .github/workflows/ios-build.yml   Cloud-Build → unsignierte .ipa und TestFlight
└─ Vela/
   ├─ App/VelaApp.swift         Einstieg
   ├─ Model/                    AppModel (Ablauf Sprachmodus ⇄ Chat), Nachrichten, Einstellungen
   ├─ Brain/                    VelaBrain-Schnittstelle, DemoBrain, LocalLLMBrain (TODO)
   ├─ Knowledge/                KnowledgeStore-Schnittstelle für Dokumente (TODO RAG)
   ├─ Speech/                   Spracherkennung, Sprachausgabe, Audio-Sitzung (AirPlay/Bluetooth)
   ├─ Visuals/                  Metal-Shader + Renderer + Animations-Logik
   ├─ Views/                    Sprachmodus, Glas-Chat, Quellen-Ansicht, Einstellungen, Splash
   ├─ Intents/                  Siri / Kurzbefehle
   └─ Resources/Assets.xcassets App-Icon, Farben
```

## Bauen ohne Mac (GitHub Actions)

1. Den Ordner als Repository zu GitHub hochladen (z. B. `DarphV/Vela`).
2. Bei jedem Push startet automatisch **Actions › iOS Build** (oder per Hand: *Run workflow*).
   Der Workflow installiert XcodeGen, erzeugt das Projekt und baut mit `xcodebuild`
   **ohne Signatur**.
3. Nach ca. 5–10 Minuten unter dem Lauf bei **Artifacts** `Vela-unsigned-ipa` herunterladen und
   entpacken → `Vela-unsigned.ipa`.
4. Derselbe Workflow startet parallel **Vela (TestFlight)**. Der Job signiert in der Cloud
   mit den Secrets `ASC_ISSUER_ID`, `ASC_KEY_ID` und `ASC_PRIVATE_KEY` (komplette `.p8`)
   und lädt nach App Store Connect hoch. Die Build-Nummer ist `github.run_number`,
   die Bundle-ID `de.barczewski.vela` (App Intents ohne eigene Extension).
   `ITSAppUsesNonExemptEncryption` ist aus. Fehlt der App-Eintrag, in App Store Connect
   eine App anlegen: Name **Vela**, Bundle-ID **de.barczewski.vela**, SKU **vela**.
   Kann die Team-ID nicht aus dem Schlüssel gelesen werden, zusätzlich das Secret
   `DEVELOPMENT_TEAM` (10 Zeichen, Mitgliedschaft) setzen.

## Auf das iPhone bringen (Sideloadly, kostenlose Apple-ID)

1. Sideloadly auf dem Windows-PC installieren (sideloadly.io), dazu iTunes und iCloud
   **von der Apple-Website** (nicht aus dem Microsoft Store).
2. iPhone per Kabel anschließen, „Diesem Computer vertrauen“ bestätigen.
3. `Vela-unsigned.ipa` in Sideloadly ziehen, eigene Apple-ID eintragen, **Start**.
   Sideloadly signiert die App dabei mit deiner Apple-ID.
4. Auf dem iPhone: *Einstellungen › Allgemein › VPN & Geräteverwaltung* → deiner Apple-ID
   vertrauen. Ab iOS 16 zusätzlich *Einstellungen › Datenschutz & Sicherheit ›
   Entwicklermodus* einschalten (iPhone startet neu).
5. Vela öffnen, Mikrofon und Spracherkennung erlauben.

Hinweise zur kostenlosen Apple-ID: Die App läuft **7 Tage**, danach in Sideloadly erneut
installieren (Daten bleiben erhalten). Mit dem Apple-Developer-Programm (99 €/Jahr) geht das
über TestFlight ohne Ablauf.

## Tipps

- **Schönere Stimme:** *iOS-Einstellungen › Bedienungshilfen › Gesprochene Inhalte › Stimmen ›
  Deutsch* → z. B. „Anna (Premium)“ laden, dann in Vela unter *Einstellungen › Stimme* wählen.
- **Siri:** Vela einmal öffnen, danach funktioniert „Hey Siri, starte Vela“ bzw. „Hey Siri,
  frag Vela“. Für den HomePod in der Home-App *Persönliche Anfragen* einschalten.
- **Ton über HomePod/Lautsprecher:** im Kontrollzentrum per AirPlay auswählen – Vela spricht
  dann dort, das iPhone-Mikrofon hört weiter zu.

## Lokales Modell

Die Bibliotheken `MLXLLM` und `MLXLMCommon` kommen aus [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) 2.31.3 (sie sind aus mlx-swift-examples dorthin umgezogen). Diese Fassung baut mit dem Xcode 26.3 der GitHub-Runner und lässt den Download-Ordner festlegen, damit das Modell wieder gelöscht werden kann.

In den Einstellungen: **KI-Modell laden**. Das ist der einzige Netzwerkzugriff. Danach liegt Qwen 2.5 1.5B (4-bit, etwa 1 GB) unter Application Support. Auf einem iPhone 16 Pro Max reicht der Speicher für dieses 1.5B-Modell. Das erste Öffnen nach dem Laden dauert einen Moment, weil die Gewichte in den Speicher kommen. Ohne geladenes Modell antwortet weiter das Demo-Gehirn, mit einem Hinweis.

Apple Intelligence ist eine zweite Engine, nur wenn iOS 26 sie auf dem Gerät freigeschaltet hat.

Dokumente (PDF, Text, Markdown, DOCX) werden auf dem Gerät in Abschnitte zerlegt. Vektoren kommen von NaturalLanguage, wenn das deutsche Modell schon auf dem iPhone liegt, sonst eine Stichwortsuche. „Im Dokument öffnen“ zeigt die PDF-Seite. Fakten wie „Ich heiße …“ oder „Merke dir …“ bleiben lokal und zählen im Gedächtnis-Chip mit.

## Mac-Verbindung

`MacCompanion/` baut den lokalen Dienst `vela-macd` (Artefakt `VelaMac-daemon`). Er meldet sich per Bonjour `_vela._tcp` und spricht nur im eigenen Netz. Kopplung mit einem 6-stelligen Code, danach HMAC. Details und die nötigen macOS-Rechte stehen in `MacCompanion/README.md`. In der App: Einstellungen › Mac-Verbindung. Dort wählst du „Jedes Mal fragen“, „Für diese Sitzung erlauben“ oder „Immer erlauben“, plus die Fähigkeiten. Der Mac speichert das und setzt es durch. Mit stehender Freigabe führt Vela die Aktion sofort aus und sagt, was sie getan hat.

## Nächste Schritte

1. Natürliche Offline-Stimme und die Websuche.
2. Vor einer App-Store-Veröffentlichung: Markenrecht für den Namen „Vela“ prüfen.
