//
//  SettingsView.swift
//  Vela
//
//  Einstellungen: Design (live thumbnails), Stimme, Vorlesen, Websuche, Wissen.
//  Persisted with @AppStorage (keys in VelaSettings).
//

import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage(VelaSettings.designKey) private var design = 0
    @AppStorage(VelaSettings.voiceKey) private var voiceID = ""
    @AppStorage(VelaSettings.ttsKey) private var ttsEnabled = true
    @AppStorage(VelaSettings.webSearchKey) private var webSearch = false
    @AppStorage(VelaSettings.engineKey) private var engine = VelaEngineKind.local.rawValue

    @State private var importing = false
    @State private var macCode = ""
    @State private var pairingPeer: MacPeer?
    @State private var explainAlways = false

    @State private var thumbnails: [VisualDriver] = VelaDesign.allCases.map { VisualDriver.thumbnail(design: $0.rawValue) }
    @State private var voices: [AVSpeechSynthesisVoice] = []

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        return v
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Einstellungen") { dismiss() }

                SectionTitle("Design")
                designGrid

                SectionTitle("Stimme")
                voiceGroup
                SettingsGroup {
                    Toggle(isOn: $ttsEnabled) {
                        RowLabel(icon: "speaker.wave.2", title: "Antworten vorlesen",
                                 subtitle: "Über iPhone, AirPlay oder Bluetooth")
                    }
                    .toggleStyle(VelaToggleStyle())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
                .padding(.top, 10)

                SectionTitle("Internet")
                SettingsGroup {
                    Toggle(isOn: $webSearch) {
                        RowLabel(icon: "globe", title: "Websuche erlauben",
                                 subtitle: "Quellen werden immer angezeigt · folgt in einer späteren Version")
                    }
                    .toggleStyle(VelaToggleStyle())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }

                SectionTitle("KI-Modell")
                modelGroup

                SectionTitle("Mac-Verbindung")
                macSection

                SectionTitle("Mikrofon")
                SettingsGroup {
                    Toggle(isOn: Binding(get: { model.micEnabled }, set: { model.setMic($0) })) {
                        RowLabel(icon: "mic", title: "Zuhören", subtitle: "Im Sprachmodus, ohne extra Schalter auf dem Bild")
                    }
                    .toggleStyle(VelaToggleStyle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                SectionTitle("Wissen")
                SettingsGroup {
                    if model.knowledge.documents.isEmpty {
                        Text("Noch keine Dokumente")
                            .velaText(15)
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        Divider().overlay(Color.white.opacity(0.07))
                    }
                    ForEach(model.knowledge.documents) { doc in
                        HStack(spacing: 12) {
                            RowLabel(icon: "doc.text", title: doc.name, subtitle: doc.detail)
                            Spacer(minLength: 8)
                            Button {
                                model.knowledge.deleteDocument(id: doc.id)
                            } label: {
                                Image(systemName: "trash")
                                    .velaText(14)
                                    .foregroundStyle(.white.opacity(0.55))
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(doc.name) löschen")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        Divider().overlay(Color.white.opacity(0.07))
                    }
                    Button { importing = true } label: {
                        HStack(spacing: 12) {
                            IconTile(icon: "plus")
                            Text(model.knowledge.isImporting ? "Dokument wird gelesen …" : "Dokument hinzufügen")
                                .velaText(15.5)
                                .foregroundStyle(Color.rgba(185, 160, 255))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.knowledge.isImporting)
                    .accessibilityLabel("Dokument hinzufügen")
                }

                if !model.knowledge.facts.isEmpty {
                    SectionTitle("Gedächtnis")
                    SettingsGroup {
                        ForEach(model.knowledge.facts) { fact in
                            HStack(alignment: .top, spacing: 12) {
                                Text(fact.text)
                                    .velaText(15)
                                    .foregroundStyle(.white.opacity(0.9))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    model.knowledge.forgetFact(id: fact.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .velaText(14)
                                        .foregroundStyle(.white.opacity(0.55))
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Fakt löschen")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            Divider().overlay(Color.white.opacity(0.07))
                        }
                    }
                }

                Text(footer)
                    .velaText(11.5)
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                    .padding(.bottom, 6)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .presentationDetents([.large])
        .velaSheetStyle()
        .onAppear {
            voices = VoiceOutput.germanVoices()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: ImportTypes.allowed, allowsMultipleSelection: false) { result in
            model.importFile(result)
        }
    }

    private var footer: String {
        switch VelaEngineKind(rawValue: engine) ?? .local {
        case .local where model.models.isInstalled:
            return "Vela · \(version) · \(model.models.selected.displayName) · offline"
        case .apple where AppleIntelligenceStatus.isAvailable:
            return "Vela · \(version) · Apple Intelligence · offline"
        case .demo:
            return "Vela · \(version) · Demo-Antworten"
        default:
            return "Vela · \(version) · Demo, bis das Modell geladen ist"
        }
    }

    private var modelGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup {
                VoiceRow(title: "Lokal auf dem iPhone", subtitle: "\(model.models.selected.displayName) · 4-bit · offline",
                         selected: engine == VelaEngineKind.local.rawValue) {
                    engine = VelaEngineKind.local.rawValue
                }
                Divider().overlay(Color.white.opacity(0.07))
                VoiceRow(title: "Apple Intelligence", subtitle: AppleIntelligenceStatus.detail,
                         selected: engine == VelaEngineKind.apple.rawValue,
                         enabled: AppleIntelligenceStatus.isAvailable) {
                    engine = VelaEngineKind.apple.rawValue
                }
                Divider().overlay(Color.white.opacity(0.07))
                VoiceRow(title: "Demo", subtitle: "Feste Beispielantworten, ohne Modell",
                         selected: engine == VelaEngineKind.demo.rawValue) {
                    engine = VelaEngineKind.demo.rawValue
                }
            }
            SettingsGroup {
                ForEach(Array(VelaModelKind.allCases.enumerated()), id: \.element.id) { index, kind in
                    if index > 0 {
                        Divider().overlay(Color.white.opacity(0.07))
                    }
                    VoiceRow(title: kind.title, subtitle: model.models.statusLine(for: kind),
                             selected: model.models.selected == kind) {
                        model.models.select(kind)
                    }
                }
            }
            SettingsGroup {
                VStack(alignment: .leading, spacing: 8) {
                    RowLabel(icon: "cpu", title: model.models.selected.title, subtitle: model.models.detail)
                    if case .downloading = model.models.phase {
                        ProgressView(value: model.models.fraction)
                            .tint(Theme.violet)
                        Button("Laden abbrechen") { model.models.cancelDownload() }
                            .velaText(14, weight: .medium)
                            .foregroundStyle(Color.rgba(185, 160, 255))
                    } else if model.models.isInstalled {
                        Button("\(model.models.selected.title) löschen") { model.models.delete() }
                            .velaText(14, weight: .medium)
                            .foregroundStyle(Color.rgba(185, 160, 255))
                    } else {
                        Button("\(model.models.selected.title) laden") { model.models.download() }
                            .velaText(15.5, weight: .semibold)
                            .foregroundStyle(Color.rgba(185, 160, 255))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var macSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.mac.status)
                        .velaText(15)
                        .foregroundStyle(.white)
                    Button(model.mac.isPaired ? "Verbindung trennen" : "Macs suchen") {
                        if model.mac.isPaired {
                            Task { await model.mac.unpair() }
                        } else {
                            model.mac.startSearch()
                        }
                    }
                    .velaText(15.5, weight: .semibold)
                    .foregroundStyle(Color.rgba(185, 160, 255))
                    if !model.mac.isPaired {
                        ForEach(model.mac.peers) { peer in
                            Button {
                                pairingPeer = peer
                            } label: {
                                HStack {
                                    Text(peer.name)
                                        .velaText(15)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text(pairingPeer == peer ? "ausgewählt" : "wählen")
                                        .velaText(12.5)
                                        .foregroundStyle(.white.opacity(0.45))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if pairingPeer != nil {
                            TextField("6-stelliger Code", text: $macCode)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                                .velaText(17)
                                .foregroundStyle(.white)
                            Button("Koppeln") {
                                guard let peer = pairingPeer else { return }
                                let code = macCode
                                Task {
                                    let message = await model.mac.pair(with: peer, code: code)
                                    model.showToast(message)
                                }
                            }
                            .velaText(15.5, weight: .semibold)
                            .foregroundStyle(Color.rgba(185, 160, 255))
                            .disabled(macCode.count < 6)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.mac.isPaired {
                SettingsGroup {
                    VoiceRow(title: "Jedes Mal fragen", subtitle: "Vor jeder Aktion einmal bestätigen",
                             selected: model.mac.mode == .ask) {
                        Task { await model.mac.setMode(.ask) }
                    }
                    Divider().overlay(Color.white.opacity(0.07))
                    VoiceRow(title: "Für diese Sitzung erlauben", subtitle: "Bis Vela schließt oder der Mac weg ist",
                             selected: model.mac.mode == .session && model.mac.sessionActive) {
                        Task { await model.mac.setMode(.session) }
                    }
                    Divider().overlay(Color.white.opacity(0.07))
                    VoiceRow(title: "Immer erlauben", subtitle: "Die angehakten Aktionen sofort ausführen",
                             selected: model.mac.mode == .always) {
                        if UserDefaults.standard.bool(forKey: "vela.mac.alwaysExplained") {
                            Task { await model.mac.setMode(.always) }
                        } else {
                            explainAlways = true
                        }
                    }
                }
                SettingsGroup {
                    ForEach(MacCapabilities.groups, id: \.key) { group in
                        Toggle(isOn: Binding(get: { model.mac.groupOn(group.key) }, set: { value in
                            Task { await model.mac.setGroup(group.key, value) }
                        })) {
                            Text(group.title).velaText(15).foregroundStyle(.white)
                        }
                        .toggleStyle(VelaToggleStyle())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
                Button("Alles widerrufen") {
                    Task { await model.mac.revokeAll() }
                }
                .velaText(15.5, weight: .semibold)
                .foregroundStyle(Color.rgba(185, 160, 255))
                .padding(.horizontal, 4)
                if !model.mac.log.isEmpty {
                    SectionTitle("Letzte Aktionen")
                    SettingsGroup {
                        ForEach(model.mac.log) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.message)
                                    .velaText(14)
                                    .foregroundStyle(.white.opacity(0.9))
                                Text(entry.time)
                                    .velaText(11.5)
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
        }
        .onAppear {
            if model.mac.isPaired { Task { await model.mac.refreshLog() } }
        }
        .alert("Immer erlauben", isPresented: $explainAlways) {
            Button("Erlauben") {
                UserDefaults.standard.set(true, forKey: "vela.mac.alwaysExplained")
                Task { await model.mac.setMode(.always) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Vela führt die angehakten Aktionen danach sofort aus und sagt dir Bescheid.")
        }
    }

    private func permissionToggle(_ key: String, _ title: String) -> some View {
        Toggle(isOn: Binding(get: { model.mac.permissions[key] ?? false }, set: { value in
            Task { await model.mac.setPermission(key, value) }
        })) {
            Text(title).velaText(15).foregroundStyle(.white)
        }
        .toggleStyle(VelaToggleStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Design

    private var designGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(VelaDesign.allCases) { d in
                let selected = design == d.rawValue
                Button {
                    design = d.rawValue
                } label: {
                    VStack(spacing: 8) {
                        VelaVisual(driver: thumbnails[d.rawValue])
                            .aspectRatio(1, contentMode: .fit)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        Text(d.title)
                            .velaText(12)
                            .multilineTextAlignment(.center)
                            .lineSpacing(1)
                            .foregroundStyle(.white.opacity(selected ? 1 : 0.75))
                            .frame(minHeight: 30, alignment: .top)
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                    .background(selected ? Color.rgba(140, 100, 255, 0.12) : Color.white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(selected ? Color.rgba(185, 150, 255, 0.9) : Color.white.opacity(0.08),
                                      lineWidth: selected ? 1.5 : 1))
                    .shadow(color: selected ? Color.rgba(140, 100, 255, 0.35) : .clear, radius: 9)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(d.title.replacingOccurrences(of: "\n", with: " "))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.easeOut(duration: 0.25), value: design)
    }

    // MARK: Voice

    private var voiceGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
        SettingsGroup {
            VoiceRow(title: "Automatisch",
                     subtitle: voices.first.map { "Beste deutsche Stimme: \($0.name) · \(VoiceOutput.qualityLabel($0))" } ?? "Systemstimme Deutsch",
                     selected: voiceID.isEmpty) {
                voiceID = ""
                model.previewVoice(id: "")
            }
            ForEach(voices, id: \.identifier) { v in
                Divider().overlay(Color.white.opacity(0.07))
                VoiceRow(title: "\(v.name) (\(VoiceOutput.qualityLabel(v)))",
                         subtitle: "Apple-Stimme · offline · \(v.language)",
                         selected: voiceID == v.identifier) {
                    voiceID = v.identifier
                    model.previewVoice(id: v.identifier)
                }
            }
            Divider().overlay(Color.white.opacity(0.07))
            VoiceRow(title: "Offline-KI-Stimme", subtitle: "Natürlicher Klang · läuft auf dem iPhone · folgt",
                     selected: false, enabled: false) {}
            Divider().overlay(Color.white.opacity(0.07))
            VoiceRow(title: "Online-Premium", subtitle: "Fast menschlich · braucht Internet · folgt",
                     selected: false, enabled: false) {}
        }

        if voices.allSatisfy({ $0.quality != .premium }) {
            Text("Tipp: Premium-Stimmen (z. B. Anna) unter iOS-Einstellungen › Bedienungshilfen › Gesprochene Inhalte › Stimmen › Deutsch laden.")
                .velaText(12)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 4)
                .padding(.top, 8)
        }
        }
    }
}

// MARK: - Building blocks

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .velaText(12, weight: .semibold)
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 4)
            .padding(.top, 18)
            .padding(.bottom, 8)
    }
}

private struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct IconTile: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .velaText(14)
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Theme.iconGradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct RowLabel: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            IconTile(icon: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .velaText(15.5)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .velaText(12.5)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct VoiceRow: View {
    let title: String
    let subtitle: String
    let selected: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .velaText(15.5)
                        .foregroundStyle(.white.opacity(enabled ? 1 : 0.5))
                    Text(subtitle)
                        .velaText(12.5)
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle().strokeBorder(selected ? Color.rgba(181, 151, 255) : Color.white.opacity(0.3), lineWidth: 1.5)
                    if selected {
                        Circle()
                            .fill(Theme.radioGradient)
                            .padding(5)
                            .shadow(color: Color.rgba(160, 120, 255, 0.8), radius: 4)
                    }
                }
                .frame(width: 22, height: 22)
                .opacity(enabled ? 1 : 0.4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
