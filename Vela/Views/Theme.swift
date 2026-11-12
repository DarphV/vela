//
//  Theme.swift
//  Vela
//
//  Colors, gradients and the glass material used across the app
//  (values taken from the prototype's CSS).
//

import SwiftUI

extension Color {
    /// CSS-style rgba(r, g, b, a) with 0...255 channels.
    static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
}

enum Theme {
    static let violet = Color.rgba(160, 123, 255)          // --violet #a07bff
    static let cyan = Color.rgba(82, 220, 255)             // --cyan #52dcff
    static let glassTint = Color.rgba(24, 20, 40, 0.42)    // --glass
    static let userTint = Color.rgba(36, 30, 58, 0.5)
    static let sheetTint = Color.rgba(18, 15, 30, 0.72)
    static let bullet = Color.rgba(127, 220, 255)
    static let memoryGreen = Color.rgba(83, 224, 138)
    static let dotViolet = Color.rgba(165, 125, 255)

    /// .glass::before border: 140deg violet -> transparent white -> cyan
    static let glassBorder = LinearGradient(
        stops: [
            .init(color: Color.rgba(200, 165, 255, 0.95), location: 0),
            .init(color: Color.white.opacity(0.10), location: 0.38),
            .init(color: Color.white.opacity(0.06), location: 0.62),
            .init(color: Color.rgba(90, 215, 255, 0.85), location: 1)
        ],
        startPoint: UnitPoint(x: 0.1, y: 0), endPoint: UnitPoint(x: 0.9, y: 1))

    static let accentGradient = LinearGradient(colors: [Color.rgba(142, 99, 255), Color.rgba(67, 201, 255)],
                                               startPoint: .leading, endPoint: .trailing)
    static let radioGradient = LinearGradient(colors: [Color.rgba(181, 151, 255), Color.rgba(95, 216, 255)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)
    static let iconGradient = LinearGradient(colors: [Color.rgba(150, 110, 255, 0.35), Color.rgba(70, 190, 255, 0.25)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
    static let wordmark = LinearGradient(stops: [
        .init(color: .white, location: 0.1),
        .init(color: Color.rgba(217, 198, 255), location: 0.45),
        .init(color: Color.rgba(143, 230, 255), location: 0.9)
    ], startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Glass

/// Glass surface: iOS 26 Liquid Glass when available, otherwise .ultraThinMaterial
/// with the prototype's tint, gradient border and soft violet glow.
struct VelaGlass<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color = Theme.glassTint
    var border = true
    var glow = true

    func body(content: Content) -> some View {
        decorated(base(content))
    }

    @ViewBuilder
    private func base(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint), in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(tint, in: shape)
            .background(.ultraThinMaterial, in: shape)
    }

    @ViewBuilder
    private func decorated<V: View>(_ view: V) -> some View {
        let highlighted = view
            .overlay(alignment: .top) {
                shape.stroke(
                    LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.02)], startPoint: .top, endPoint: .center),
                    lineWidth: 1
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
            .overlay(shape.strokeBorder(Theme.glassBorder, lineWidth: border ? 1 : 0).allowsHitTesting(false))
        if glow {
            highlighted
                .shadow(color: Color.rgba(150, 100, 255, 0.18), radius: 16)
                .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 12)
        } else {
            highlighted
        }
    }
}

struct VelaTextModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var size: CGFloat
    var weight: Font.Weight = .regular

    func body(content: Content) -> some View {
        content.font(.system(size: size * VelaType.scale(for: dynamicTypeSize), weight: weight, design: .rounded))
    }
}

enum VelaType {
    static func scale(for size: DynamicTypeSize) -> CGFloat {
        let factor: CGFloat
        switch size {
        case .xSmall: factor = 0.82
        case .small: factor = 0.9
        case .medium: factor = 0.95
        case .large: factor = 1
        case .xLarge: factor = 1.08
        case .xxLarge: factor = 1.16
        case .xxxLarge: factor = 1.24
        case .accessibility1: factor = 1.32
        case .accessibility2: factor = 1.4
        default: factor = 1.45
        }
        return factor
    }
}

extension View {
    func velaText(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(VelaTextModifier(size: size, weight: weight))
    }
}

extension View {
    func velaGlass<S: InsettableShape>(_ shape: S, tint: Color = Theme.glassTint, border: Bool = true, glow: Bool = true) -> some View {
        modifier(VelaGlass(shape: shape, tint: tint, border: border, glow: glow))
    }

    /// Small frosted chip/button background (prototype: .chip, #gear, #micBtn).
    func velaChip<S: InsettableShape>(_ shape: S, highlighted: Bool = false) -> some View {
        self
            .background(highlighted ? Color.rgba(120, 90, 255, 0.18) : Color.white.opacity(0.045), in: shape)
            .background(.ultraThinMaterial.opacity(0.6), in: shape)
            .overlay(shape.strokeBorder(highlighted ? Color.rgba(180, 150, 255, 0.7) : Color.white.opacity(0.11), lineWidth: 1))
            .shadow(color: highlighted ? Color.rgba(140, 100, 255, 0.6) : .clear, radius: 11)
    }
}

/// Toggle styled like the prototype (.tog): gradient track when on.
struct VelaToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.16)))
                        .frame(width: 51, height: 31)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 27, height: 27)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                        .padding(2)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
