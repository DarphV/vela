//
//  RootView.swift
//  Vela
//
//  Layer stack and geometry 1:1 from the prototype (index.html / app.js layout()):
//    stars · ambient · Glas-Chat · stage (visual) · avatar ring · voice UI · chips · gear · toast · splash
//  Stage size S = 1.12 × width, centered at 43 % of the screen height. In chat mode
//  it shrinks to a 70 pt avatar under the status bar.
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
    @Namespace private var orbSpace

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
                    travelRing(L)
                    avatarRing(L)

                    VoiceModeView(layout: L)
                        .opacity(isChat || model.showSplash ? 0 : 1)
                        .allowsHitTesting(!isChat && !model.showSplash)
                        .animation(.easeOut(duration: 0.45), value: isChat)

                    header(L)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .ignoresSafeArea(.keyboard)

            toastView

            if model.showSplash {
                SplashView { model.splashFinished() }
                    .transition(.opacity)
                    .zIndex(10)
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
        .onChange(of: reduceMotion, initial: true) { _, value in
            model.driver.reduceMotion = value
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.sceneBecameActive()
            case .background: model.sceneWentToBackground()
            default: break
            }
        }
    }

    // MARK: Stage

    private func stage(_ L: StageLayout) -> some View {
        let scale = isChat ? StageLayout.avatarSize / L.stage : 1
        let centerY = isChat ? L.avatarCenter : L.centerY
        return VelaVisual(driver: model.driver, preferredFPS: isChat ? 60 : 120)
            .frame(width: L.stage, height: L.stage)
            .clipShape(Circle())
            .scaleEffect(scale)
            .position(x: L.width / 2, y: L.y(centerY))
            .opacity(stageOpacity)
            .allowsHitTesting(false)
            .animation(.spring(response: 0.78, dampingFraction: 0.86), value: isChat)
    }

    /// The stroke travels with the visual. Two views share one identity so the
    /// shrink into the avatar is a matched geometry spring, while the Metal
    /// view itself stays alive and only changes frame.
    private func travelRing(_ L: StageLayout) -> some View {
        Group {
            if isChat {
                ringStroke(StageLayout.avatarSize, bright: true)
                    .matchedGeometryEffect(id: "velaRing", in: orbSpace)
                    .position(x: L.width / 2, y: L.y(L.avatarCenter))
            } else {
                ringStroke(L.stage, bright: false)
                    .matchedGeometryEffect(id: "velaRing", in: orbSpace)
                    .position(x: L.width / 2, y: L.y(L.centerY))
            }
        }
        .allowsHitTesting(false)
    }

    private func ringStroke(_ side: CGFloat, bright: Bool) -> some View {
        Circle()
            .strokeBorder(
                LinearGradient(colors: [Color.white.opacity(bright ? 0.85 : 0.35), Color.rgba(190, 160, 255, bright ? 0.7 : 0.22)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: bright ? 1.4 : 1
            )
            .frame(width: side, height: side)
    }

    private func avatarRing(_ L: StageLayout) -> some View {
        Button {
            model.toVoice()
        } label: {
            Circle()
                .fill(
                    RadialGradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0)],
                                   center: UnitPoint(x: 0.34, y: 0.26), startRadius: 0, endRadius: 20)
                )
                .background(
                    Circle().fill(RadialGradient(stops: [
                        .init(color: .clear, location: 0.58),
                        .init(color: Color.rgba(160, 120, 255, 0.22), location: 0.72),
                        .init(color: Color.white.opacity(0.08), location: 1)
                    ], center: .center, startRadius: 0, endRadius: 35))
                )
                .overlay(Circle().strokeBorder(Color.rgba(210, 180, 255, 0.55), lineWidth: 1))
                .shadow(color: Color.rgba(150, 100, 255, 0.65), radius: 9)
                .shadow(color: Color.rgba(90, 170, 255, 0.35), radius: 23)
                .frame(width: StageLayout.avatarSize, height: StageLayout.avatarSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zurück zum Sprachmodus")
        .opacity(isChat ? 1 : 0)
        .scaleEffect(isChat ? 1 : 0.6)
        .animation(isChat ? .spring(response: 0.6, dampingFraction: 0.6).delay(0.6) : .easeOut(duration: 0.3), value: isChat)
        .allowsHitTesting(isChat)
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
