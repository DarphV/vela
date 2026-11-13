//
//  VelaVisualView.swift
//  Vela
//
//  SwiftUI wrapper around the Metal visual. Falls back to a gradient orb when
//  Metal is unavailable (e.g. some simulators / previews).
//

import SwiftUI
import MetalKit

struct VelaVisual: View {
    let driver: VisualDriver
    var preferredFPS: Int = 60

    var body: some View {
        if VelaGPU.shared != nil {
            VelaMetalView(driver: driver, preferredFPS: preferredFPS)
        } else {
            FallbackOrb(design: driver.design)
        }
    }
}

struct VelaMetalView: UIViewRepresentable {
    let driver: VisualDriver
    var preferredFPS: Int = 60

    final class Coordinator {
        var renderer: VelaRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: VelaGPU.shared?.device)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = VelaGPU.pixelFormat
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        // Full-screen caps the device pixel ratio at 2. A paused mini avatar stays at 1.
        view.contentScaleFactor = driver.isStatic ? 1 : 2
        view.isUserInteractionEnabled = false
        view.preferredFramesPerSecond = driver.isStatic ? 2 : (driver.economy ? 24 : preferredFPS)

        if let gpu = VelaGPU.shared {
            let renderer = VelaRenderer(gpu: gpu, driver: driver)
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }
        if driver.isStatic {
            // Thumbnails: draw once on demand.
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.setNeedsDisplay()
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        if driver.isStatic {
            if !view.isPaused { view.isPaused = true }
            if view.contentScaleFactor != 1 { view.contentScaleFactor = 1 }
            return
        }
        let economy = driver.economy
        let fps = economy ? 24 : preferredFPS
        if view.preferredFramesPerSecond != fps {
            view.preferredFramesPerSecond = fps
        }
        if economy {
            if view.contentScaleFactor != 1 { view.contentScaleFactor = 1 }
        } else if view.contentScaleFactor <= 1.01 {
            view.contentScaleFactor = 2
        }
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        coordinator.renderer = nil
    }
}

/// One paused frame of the real shader, used for the top avatar and the chat bubbles.
/// Nebula, black hole and black hole nebula each keep their own picture.
struct SkinAvatar: View {
    let design: Int

    var body: some View {
        let skin = max(0, min(2, design))
        VelaVisual(driver: VisualDriver.thumbnail(design: skin))
            .id(skin)
            .accessibilityHidden(true)
    }
}

/// Simple non-Metal stand-in (prototype: Canvas2D fallback / thumbnail placeholders).
struct FallbackOrb: View {
    let design: Int

    var body: some View {
        GeometryReader { geo in
            let radius = max(geo.size.width, geo.size.height) * 0.5
            switch design {
            case 1:
                Circle().fill(RadialGradient(colors: [.black, .black, Color.rgba(255, 217, 160), Color.rgba(192, 96, 16), .black],
                                             center: .center, startRadius: radius * 0.08, endRadius: radius))
            case 2:
                Circle().fill(RadialGradient(colors: [.black, Color.rgba(90, 40, 180), Color.rgba(40, 170, 255), .black],
                                             center: .center, startRadius: radius * 0.12, endRadius: radius))
            default:
                Circle().fill(RadialGradient(colors: [Color.rgba(255, 230, 250), Color.rgba(170, 80, 255), Color.rgba(30, 140, 255), Color.rgba(8, 6, 20)],
                                             center: .center, startRadius: 0, endRadius: radius))
            }
        }
    }
}
