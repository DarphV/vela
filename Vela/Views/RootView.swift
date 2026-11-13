//
//  RootView.swift
//  Vela
//
//  Stars, ambient glow, Glas-Chat, the orb, chips, gear, toast and splash.
//  The splash plays the full visual once. After that the orb is a small soft
//  avatar under the status bar, in voice mode and in the chat, with no ring.
//

import SwiftUI

struct StageLayout {
    let width: CGFloat
    let height: CGFloat     // full screen height incl. safe areas
    let top: CGFloat        // safe area top inset
    let bottom: CGFloat
    let sat: CGFloat        // max(top, 14)
    let sab: CGFloat        // max(bottom, 12)
    let stage: CGFloat      // S
    let centerY: CGFloat    // cy (full-screen coordinates)

    init(size: CGSize, insets: EdgeInsets) {
        width = size.width
        top = insets.top
        bottom = insets.bottom
        height = size.height + insets.top + insets.bottom
        sat = max(insets.top, 14)
        sab = max(insets.bottom, 12)
        stage = (size.width * 1.12).rounded()
        centerY = (height * 0.43).rounded()
    }

    /// Converts a full-screen y coordinate to the GeometryReader's (safe-area) space.
    func y(_ full: CGFloat) -> CGFloat { full - top }

    var avatarCenter: CGFloat { sat + 6 + 35 }
    static let avatarSize: CGFloat = 70
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(VelaSettings.designKey) private var design = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stageOpacity: Double = 1
    @State private var topInset: CGFloat = 59
    /// After the splash, the orb sits at the top and the full-screen Metal view is gone.
    @State private var orbCompact = false
    @State private var metalRetired = false
    /// The mini avatar fades in only once the splash shrink has finished.
    @State private var avatarOpacity: Double = 0

    private var isChat: Bool { model.mode == .chat }
    private var modeAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.3) : .timingCurve(0.7, 0, 0.16, 1, duration: 0.95)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            StarfieldView()
                .opacity(isChat ? 0.55 : 1)
                .animation(.easeInOut(duration: 1), value: isChat)
                .ignoresSafeArea()

            AmbientGlow()
                .opacity(isChat ? 1 : 0)
                .animation(.easeInOut(duration: 1.2), value: isChat)
                .ignoresSafeArea()

            ChatView(topInset: topInset)

            GeometryReader { geo in
                let L = StageLayout(size: geo.size, insets: geo.safeAreaInsets)
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .onChange(of: geo.safeAreaInsets.top, initial: true) { _, value in
                            topInset = value
                        }

                    stage(L)
                    avatarHitTarget(L)

                    header(L)
                        .opacity(isChat ? 1 : 0)
                        .allowsHitTesting(isChat)
                        .animation(.easeInOut(duration: 0.35), value: isChat)

                    Color.clear
                        .contentShape(Rectangle())
                        .allowsHitTesting(!isChat && !model.showSplash && !model.showSettings)
                        .gesture(homeDrag)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .ignoresSafeArea(.keyboard)

            if model.showSwipeHint && !isChat && !model.showSplash && !model.showOnboarding && ScreenshotLaunch.kind == nil {
                VStack {
                    Spacer()
                    Text("Nach oben für den Chat\nNach unten für Einstellungen")
                        .multilineTextAlignment(.center)
                        .velaText(13)
                        .foregroundStyle(.white.opacity(0.42))
                        .padding(.bottom, 28)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            toastView

            if model.showSplash {
                SplashView { model.splashFinished() }
                    .transition(.opacity)
                    .zIndex(10)
            }

            if model.showOnboarding {
                ModelOnboardingView()
                    .transition(.opacity)
                    .zIndex(9)
            }

            if model.models.safeMode && !model.showSplash {
                ModelSafeModeView()
                    .transition(.opacity)
                    .zIndex(8)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .sheet(isPresented: $model.showSettings, onDismiss: { model.settingsDidClose() }) {
            SettingsView()
                .environmentObject(model)
        }
        .sheet(item: $model.openSource) { source in
            SourceSheet(source: source) { model.showToast("Diese Quelle hat keine Datei auf dem iPhone") }
        }
        .onChange(of: design) { _, newValue in
            switchDesign(to: newValue)
        }
        .onChange(of: model.showSplash) { _, showing in
            guard !showing, !orbCompact else { return }
            if reduceMotion {
                orbCompact = true
                revealMiniAvatar()
                return
            }
            withAnimation(.spring(response: 0.85, dampingFraction: 0.88)) {
                orbCompact = true
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(920))
                revealMiniAvatar()
            }
        }
        .onChange(of: reduceMotion, initial: true) { _, value in
            model.driver.reduceMotion = value
        }
        .confirmationDialog(
            "Auf dem Mac ausführen?",
            isPresented: Binding(get: { model.pendingMacAction != nil }, set: { if !$0 { model.pendingMacAction = nil } }),
            titleVisibility: .visible
        ) {
            Button("Ausführen") { model.approvePendingMac() }
            Button("Abbrechen", role: .cancel) { model.pendingMacAction = nil }
        } message: {
            Text(model.pendingMacAction?.summary ?? "")
        }
        .accessibilityAction(named: "Textmodus") { model.toChat() }
        .accessibilityAction(named: "Einstellungen") {
            model.settingsWillOpen()
            model.showSettings = true
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.sceneBecameActive()
            case .background: model.sceneWentToBackground()
            default: break
            }
        }
    }

    private var homeDrag: some Gesture {
        DragGesture(minimumDistance: 28, coordinateSpace: .local)
            .onEnded { value in
                guard !model.showSplash, !model.showSettings else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if value.startLocation.x < 28, dx > 56 {
                    revealSettings()
                } else if dy < -64, abs(dy) > abs(dx) {
                    model.dismissSwipeHint()
                    if !isChat { model.toChat() }
                } else if dy > 64, abs(dy) > abs(dx) {
                    model.dismissSwipeHint()
                    if isChat { model.toVoice() } else { revealSettings() }
                }
            }
    }

    private func revealSettings() {
        model.dismissSwipeHint()
        model.settingsWillOpen()
        model.showSettings = true
    }

    // MARK: Stage

    private func stage(_ L: StageLayout) -> some View {
        let compact = isChat || orbCompact
        let side = compact ? StageLayout.avatarSize : L.stage
        let centerY = compact ? L.avatarCenter : L.centerY
        return ZStack {
            if !metalRetired {
                VelaVisual(driver: model.driver, preferredFPS: 30)
            }
            if orbCompact {
                SkinAvatar(design: design)
                    .opacity(avatarOpacity)
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .position(x: L.width / 2, y: L.y(centerY))
        .opacity(stageOpacity)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.85, dampingFraction: 0.88), value: compact)
    }

    /// Fades in the paused mini avatar, then removes the full-screen Metal view.
    private func revealMiniAvatar() {
        withAnimation(.easeIn(duration: 0.55)) {
            avatarOpacity = 1
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(560))
            metalRetired = true
        }
    }

    /// Invisible tap target over the small orb in the chat. No stroke.
    private func avatarHitTarget(_ L: StageLayout) -> some View {
        Button {
            model.toVoice()
        } label: {
            Color.clear
                .frame(width: StageLayout.avatarSize, height: StageLayout.avatarSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zurück zum Sprachmodus")
        .allowsHitTesting(isChat && metalRetired)
        .position(x: L.width / 2, y: L.y(L.avatarCenter))
    }

    // MARK: Header (chips + gear)

    private func header(_ L: StageLayout) -> some View {
        ZStack(alignment: .top) {
            HStack(spacing: 10) {
                HeaderChip {
                    Circle().fill(Theme.dotViolet).frame(width: 7, height: 7).shadow(color: Theme.dotViolet, radius: 4)
                    Text(model.brain.isOffline ? "Offline" : "Online")
                }
                HeaderChip {
                    Image(systemName: "brain")
                        .velaText(14)
                        .opacity(0.85)
                    Text("Gedächtnis \(model.knowledge.memoryCount.formatted(.number.locale(Locale(identifier: "de_DE"))))")
                    Circle().fill(Theme.memoryGreen).frame(width: 6, height: 6).shadow(color: Theme.memoryGreen, radius: 3)
                }
            }
            .frame(maxWidth: .infinity)
            .offset(y: isChat ? 80 : 0)
            .animation(modeAnimation, value: isChat)

            HStack {
                Spacer()
                Button {
                    model.settingsWillOpen()
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .velaText(16, weight: .regular)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 34, height: 34)
                        .velaChip(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Einstellungen")
                .padding(.trailing, 16)
            }
        }
        .padding(.top, L.y(L.sat + 10))
        .opacity(model.showSplash ? 0 : 1)
        .animation(.easeInOut(duration: 0.8), value: model.showSplash)
    }

    // MARK: Toast

    private var toastView: some View {
        VStack {
            if let toast = model.toast {
                Text(toast)
                    .velaText(13.5)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.rgba(30, 26, 48, 0.8), in: Capsule())
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 54)
            }
            Spacer()
        }
        .animation(.easeOut(duration: 0.3), value: model.toast)
        .allowsHitTesting(false)
    }

    // MARK: Design switch (prototype: fade out 330 ms, swap, fade in)

    private func switchDesign(to newValue: Int) {
        withAnimation(.easeInOut(duration: 0.33)) { stageOpacity = 0 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(330))
            model.setDesign(newValue)
            withAnimation(.easeInOut(duration: 0.35)) { stageOpacity = 1 }
        }
    }
}

private struct HeaderChip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .velaText(13.5)
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .velaChip(Capsule())
    }
}

/// Soft violet/cyan glow behind the Glas-Chat (prototype: #ambient).
struct AmbientGlow: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Ellipse()
                    .fill(RadialGradient(colors: [Color.rgba(120, 70, 255, 0.22), .clear], center: .center, startRadius: 0, endRadius: w * 0.5))
                    .frame(width: w * 1.1, height: h * 0.5)
                    .position(x: w * 0.12, y: h * 0.28)
                Ellipse()
                    .fill(RadialGradient(colors: [Color.rgba(40, 190, 255, 0.16), .clear], center: .center, startRadius: 0, endRadius: w * 0.5))
                    .frame(width: w * 1.1, height: h * 0.5)
                    .position(x: w * 0.92, y: h * 0.66)
                Ellipse()
                    .fill(RadialGradient(colors: [Color.rgba(170, 60, 255, 0.14), .clear], center: .center, startRadius: 0, endRadius: w * 0.6))
                    .frame(width: w * 1.4, height: h * 0.5)
                    .position(x: w * 0.4, y: h * 0.98)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Static starfield (prototype: stars(), 260 stars, seed 42).
struct StarfieldView: View {
    var body: some View {
        Canvas { context, size in
            var s: Int64 = 42
            func rnd() -> Double {
                s = (s * 16807) % 2_147_483_647
                return Double(s) / 2_147_483_647.0
            }
            for _ in 0..<260 {
                let x = rnd() * size.width
                let y = rnd() * size.height
                let m = rnd()
                let a = 0.08 + 0.5 * pow(m, 3)
                let color: Color = m > 0.96 ? Color.rgba(200, 180, 255, a) : (m > 0.92 ? Color.rgba(170, 230, 255, a) : Color.white.opacity(a))
                let r = 0.35 + m * 0.9
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(color))
            }
        }
        .allowsHitTesting(false)
    }
}
