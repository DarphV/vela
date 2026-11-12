//
//  ChatView.swift
//  Vela
//
//  "Glas-Chat" text mode: glass bubbles, source chips, typing indicator and the
//  glowing input bar. The visual is shown as avatar above (RootView).
//

import SwiftUI

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    let topInset: CGFloat

    @State private var draft = ""
    @State private var importing = false
    @FocusState var inputFocused: Bool

    private var isChat: Bool { model.mode == .chat }
    private var sat: CGFloat { max(topInset, 14) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.messages) { message in
                        MessageRow(message: message) { source in
                            model.openSource = source
                        }
                        .id(message.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.98)),
                                                removal: .opacity))
                    }
                    if model.isTyping {
                        TypingRow()
                            .id("typing")
                            .transition(.opacity.combined(with: .offset(y: 14)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 150 + (sat - topInset))
                .padding(.bottom, 20)
                .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.55), value: model.messages.count)
                .animation(.easeOut(duration: 0.3), value: model.isTyping)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .offset(y: isChat ? 0 : 40)
            .onChange(of: model.messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: model.streamRevision) { _, _ in scrollToEnd(proxy, animated: false) }
            .onChange(of: model.isTyping) { _, _ in scrollToEnd(proxy) }
            .onChange(of: isChat) { _, chat in
                if chat {
                    scrollToEnd(proxy, animated: false)
                } else {
                    inputFocused = false
                }
            }
            .onAppear { scrollToEnd(proxy, animated: false) }
        }
        .overlay(alignment: .top) {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.74),
                .init(color: .black.opacity(0), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: sat + 168)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            InputBar(draft: $draft, focused: $inputFocused,
                     onSend: send,
                     onVoice: { inputFocused = false; model.toVoice() },
                     onAttach: { importing = true })
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .offset(y: isChat ? 0 : 140)
                .animation(isChat ? .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.7).delay(0.35) : .easeIn(duration: 0.3), value: isChat)
        }
        .opacity(isChat ? 1 : 0)
        .allowsHitTesting(isChat)
        .animation(isChat ? .easeOut(duration: 0.45).delay(0.3) : .easeOut(duration: 0.3), value: isChat)
        .fileImporter(isPresented: $importing, allowedContentTypes: ImportTypes.allowed, allowsMultipleSelection: false) { result in
            model.importFile(result)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            inputFocused = false
            model.toVoice()
            return
        }
        draft = ""
        model.sendText(text)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo("bottom", anchor: .bottom) }
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

// MARK: - Rows

struct MessageRow: View {
    let message: ChatMessage
    let onSource: (VelaSource) -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(message.text)
                        .velaText(17)
                        .lineSpacing(3)
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                    Text(message.timeString)
                        .velaText(11.5)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.horizontal, 18)
                .padding(.top, 15)
                .padding(.bottom, 10)
                .velaGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: Theme.userTint)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                MiniAvatar()
                    .padding(.top, -4)
                if let answer = message.answer {
                    AnswerBubble(answer: answer, time: message.timeString, onSource: onSource)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct AnswerBubble: View {
    let answer: VelaAnswer
    let time: String
    let onSource: (VelaSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(answer.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(RichText.markdown(text))
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(Theme.bullet)
                                Text(RichText.markdown(item))
                            }
                        }
                    }
                }
            }
            ForEach(answer.sources) { source in
                SourceChip(source: source) { onSource(source) }
            }
            HStack(spacing: 8) {
                if answer.isDemo {
                    Text("DEMO-ANTWORT")
                        .velaText(10.5)
                        .tracking(0.4)
                        .foregroundStyle(Color.rgba(190, 160, 255, 0.55))
                }
                Spacer(minLength: 0)
                Text(time)
                    .velaText(11.5)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .velaText(15.5)
        .lineSpacing(4)
        .foregroundStyle(.white.opacity(0.92))
        .textSelection(.enabled)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .velaGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct SourceChip: View {
    let source: VelaSource
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                Text(source.chip)
                    .lineLimit(1)
                Image(systemName: "arrow.up.right.square")
            }
            .velaText(13)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
        }
        .buttonStyle(SourceChipButtonStyle())
        .accessibilityLabel("Quelle: \(source.chip)")
    }
}

private struct SourceChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.rgba(190, 160, 255, configuration.isPressed ? 0.5 : 0), lineWidth: 1))
            .shadow(color: Color.rgba(140, 100, 255, configuration.isPressed ? 0.35 : 0), radius: 7)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Small glowing nebula avatar next to bot messages (prototype: .mini).
struct MiniAvatar: View {
    @State private var spin = false

    var body: some View {
        Circle()
            .fill(RadialGradient(stops: [
                .init(color: .white, location: 0),
                .init(color: Color.rgba(255, 210, 244), location: 0.06),
                .init(color: Color.rgba(255, 120, 220, 0.85), location: 0.14),
                .init(color: Color.rgba(150, 80, 255, 0.75), location: 0.30),
                .init(color: Color.rgba(40, 170, 255, 0.55), location: 0.52),
                .init(color: Color.rgba(20, 10, 50, 0.9), location: 0.72),
                .init(color: Color.rgba(5, 3, 12), location: 1)
            ], center: UnitPoint(x: 0.5, y: 0.52), startRadius: 0, endRadius: 20))
            .overlay(
                Circle()
                    .fill(AngularGradient(colors: [.clear, Color.rgba(80, 220, 255, 0.35), .clear, Color.rgba(200, 90, 255, 0.35), .clear],
                                          center: .center))
                    .blendMode(.screen)
                    .rotationEffect(.degrees(spin ? 360 : 0))
            )
            .overlay(
                Circle().fill(RadialGradient(colors: [Color.white.opacity(0.5), .clear],
                                             center: UnitPoint(x: 0.32, y: 0.26), startRadius: 0, endRadius: 12))
            )
            .overlay(Circle().strokeBorder(Color.rgba(210, 180, 255, 0.5), lineWidth: 1))
            .shadow(color: Color.rgba(150, 100, 255, 0.55), radius: 7)
            .frame(width: 40, height: 40)
            .onAppear {
                withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) { spin = true }
            }
            .accessibilityHidden(true)
    }
}

struct TypingRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MiniAvatar().padding(.top, -4)
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        let k = TypingRow.pulse(t - Double(i) * 0.15)
                        Circle()
                            .fill(Theme.radioGradient)
                            .frame(width: 7, height: 7)
                            .scaleEffect(0.6 + 0.4 * k)
                            .opacity(0.4 + 0.6 * k)
                            .shadow(color: Color.rgba(150, 110, 255, 0.8), radius: 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .velaGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Spacer(minLength: 0)
        }
        .accessibilityLabel("Vela schreibt")
    }

    /// keyframes 0/80/100 % → 0, 40 % → 1, period 1.2 s
    static func pulse(_ t: Double) -> Double {
        var p = (t / 1.2).truncatingRemainder(dividingBy: 1)
        if p < 0 { p += 1 }
        if p < 0.4 { return p / 0.4 }
        if p < 0.8 { return 1 - (p - 0.4) / 0.4 }
        return 0
    }
}

// MARK: - Input bar

struct InputBar: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onVoice: () -> Void
    let onAttach: () -> Void

    @State private var glow = false

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onAttach) {
                Image(systemName: "paperclip")
                    .velaText(20)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Datei anhängen")

            TextField("", text: $draft, prompt: Text("Nachricht schreiben …").foregroundStyle(.white.opacity(0.45)))
                .velaText(17)
                .foregroundStyle(.white)
                .tint(Theme.cyan)
                .submitLabel(.send)
                .focused(focused)
                .onSubmit(onSend)
                .frame(height: 44)

            Button {
                if hasText { onSend() } else { onVoice() }
            } label: {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Color.rgba(29, 24, 56), Color.rgba(7, 6, 14)],
                                             center: UnitPoint(x: 0.5, y: 0.35), startRadius: 0, endRadius: 30))
                    Circle()
                        .strokeBorder(glow ? Color.rgba(190, 160, 255, 0.9) : Color.rgba(140, 225, 255, 0.85), lineWidth: 1.5)
                    Image(systemName: "mic")
                        .velaText(19, weight: .medium)
                        .opacity(hasText ? 0 : 1)
                        .scaleEffect(hasText ? 0.5 : 1)
                    Image(systemName: "arrow.up")
                        .velaText(19, weight: .semibold)
                        .opacity(hasText ? 1 : 0)
                        .scaleEffect(hasText ? 1 : 0.5)
                        .rotationEffect(.degrees(hasText ? 0 : -30))
                }
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .shadow(color: glow ? Color.rgba(150, 100, 255, 0.7) : Color.rgba(90, 200, 255, 0.55), radius: glow ? 12 : 9)
                .shadow(color: glow ? Color.rgba(80, 200, 255, 0.4) : Color.rgba(150, 90, 255, 0.45), radius: glow ? 22 : 17)
                .animation(.easeOut(duration: 0.25), value: hasText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hasText ? "Senden" : "Sprachmodus")
        }
        .padding(.leading, 18)
        .padding(.trailing, 7)
        .frame(height: 64)
        .velaGlass(Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}

// MARK: - Text helpers

enum RichText {
    /// Inline Markdown (**fett**) → AttributedString.
    static func markdown(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if var a = try? AttributedString(markdown: s, options: options) {
            for run in a.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                a[run.range].foregroundColor = Color.white
                a[run.range].font = Font.system(size: 15.5, weight: .semibold)
            }
            return a
        }
        return AttributedString(s)
    }

    /// Excerpt with ==highlight== markers → highlighted AttributedString.
    static func highlighted(_ s: String) -> AttributedString {
        var out = AttributedString()
        for (i, part) in s.components(separatedBy: "==").enumerated() {
            var a = AttributedString(part)
            if i % 2 == 1 {
                a.backgroundColor = Color.rgba(110, 155, 255, 0.33)
                a.foregroundColor = Color.white
            }
            out.append(a)
        }
        return out
    }
}
