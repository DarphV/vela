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
        // Prototype caps the device pixel ratio at 2; saves a lot of GPU on 3x screens.
        view.contentScaleFactor = 2
        view.isUserInteractionEnabled = false
        view.preferredFramesPerSecond = driver.economy ? 24 : preferredFPS

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
        let economy = driver.economy && !driver.isStatic
        let fps = economy ? 24 : preferredFPS
        if view.preferredFramesPerSecond != fps {
            view.preferredFramesPerSecond = fps
        }
        if economy {
            if view.contentScaleFactor != 1 { view.contentScaleFactor = 1 }
        } else if view.contentScaleFactor <= 1.01 {
            view.contentScaleFactor = 2
        }
        if driver.isStatic {
            view.setNeedsDisplay()
        }
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        coordinator.renderer = nil
    }
}

/// Simple non-Metal stand-in (prototype: Canvas2D fallback / thumbnail placeholders).
struct FallbackOrb: View {
    let design: Int

    var body: some View {
        switch design {
        case 1:
            Circle().fill(RadialGradient(colors: [.black, .black, Color.rgba(255, 217, 160), Color.rgba(192, 96, 16), .black],
                                         center: .center, startRadius: 0, endRadius: 160))
        case 2:
            Circle().fill(RadialGradient(colors: [.black, .black, Color.rgba(224, 192, 255), Color.rgba(112, 48, 255), Color.rgba(16, 160, 255), .black],
                                         center: .center, startRadius: 0, endRadius: 160))
        default:
            Circle().fill(RadialGradient(colors: [Color.rgba(255, 208, 240), Color.rgba(160, 80, 255), Color.rgba(26, 160, 255), .black],
                                         center: .center, startRadius: 0, endRadius: 160))
        }
    }
}
