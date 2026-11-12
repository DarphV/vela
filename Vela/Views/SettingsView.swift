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

                SectionTitle("Wissen")
                SettingsGroup {
                    ForEach(model.knowledge.documents) { doc in
                        HStack(spacing: 12) {
                            RowLabel(icon: "doc.text", title: doc.name, subtitle: doc.detail)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        Divider().overlay(Color.white.opacity(0.07))
                    }
                    Button {
                        // TODO(RAG-Import): .fileImporter(allowedContentTypes: [.pdf, .plainText, docx]) → knowledge.importDocument(at:)
                        model.showToast("Dokument-Import folgt im nächsten Schritt")
                    } label: {
                        HStack(spacing: 12) {
                            IconTile(icon: "plus")
                            Text("Dokument hinzufügen")
                                .font(.system(size: 15.5))
                                .foregroundStyle(Color.rgba(185, 160, 255))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Text("Vela · \(version) · Antworten sind Demo-Daten")
                    .font(.system(size: 11.5))
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
                            .font(.system(size: 12))
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
                .font(.system(size: 12))
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
            .font(.system(size: 12, weight: .semibold))
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
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct IconTile: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14))
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
                    .font(.system(size: 15.5))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12.5))
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
                        .font(.system(size: 15.5))
                        .foregroundStyle(.white.opacity(enabled ? 1 : 0.5))
                    Text(subtitle)
                        .font(.system(size: 12.5))
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
