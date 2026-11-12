//
//  VelaRenderer.swift
//  Vela
//
//  Metal renderer for the three visuals: one full-screen fragment pass
//  (nebula / black hole / black hole nebula) plus an additive particle pass,
//  exactly like the WebGL prototype.
//

import Foundation
import Metal
import MetalKit
import QuartzCore

/// Must match `struct VelaUniforms` in VelaShaders.metal (12 floats, 48 bytes).
struct VelaUniforms {
    var res: SIMD2<Float> = .zero
    var time: Float = 0
    var phase: Float = 0
    var amp: Float = 0
    var energy: Float = 0
    var zoom: Float = 1
    var bright: Float = 1
    var design: Float = 0
    var k: Float = 0.84
    var rs: Float = 0.22
    var px: Float = 1
}

/// Shared Metal objects (device, pipelines, particle buffer). Created once.
final class VelaGPU {
    static let shared: VelaGPU? = VelaGPU()

    static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    static let sceneFormat: MTLPixelFormat = .rgba16Float
    static let particleCount = 1400

    let device: MTLDevice
    let queue: MTLCommandQueue
    let quadPipelines: [MTLRenderPipelineState]
    let pointPipeline: MTLRenderPipelineState
    let thresholdPipeline: MTLRenderPipelineState
    let blurPipeline: MTLRenderPipelineState
    let compositePipeline: MTLRenderPipelineState
    let particles: MTLBuffer

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            print("[Vela] Metal nicht verfügbar")
            return nil
        }
        do {
            func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat, additive: Bool) throws -> MTLRenderPipelineState {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = library.makeFunction(name: vertex)
                desc.fragmentFunction = library.makeFunction(name: fragment)
                desc.colorAttachments[0].pixelFormat = format
                if additive {
                    let ca = desc.colorAttachments[0]!
                    ca.isBlendingEnabled = true
                    ca.rgbBlendOperation = .add
                    ca.alphaBlendOperation = .add
                    ca.sourceRGBBlendFactor = .one
                    ca.destinationRGBBlendFactor = .one
                    ca.sourceAlphaBlendFactor = .one
                    ca.destinationAlphaBlendFactor = .one
                }
                return try device.makeRenderPipelineState(descriptor: desc)
            }
            let quads = try [
                pipeline("vela_quad_vertex", "vela_nebula_fragment", format: VelaGPU.sceneFormat, additive: false),
                pipeline("vela_quad_vertex", "vela_blackhole_fragment", format: VelaGPU.sceneFormat, additive: false),
                pipeline("vela_quad_vertex", "vela_blackhole_nebula_fragment", format: VelaGPU.sceneFormat, additive: false)
            ]
            let points = try pipeline("vela_points_vertex", "vela_points_fragment", format: VelaGPU.sceneFormat, additive: true)
            let threshold = try pipeline("vela_quad_vertex", "vela_threshold_fragment", format: VelaGPU.sceneFormat, additive: false)
            let blur = try pipeline("vela_quad_vertex", "vela_blur_fragment", format: VelaGPU.sceneFormat, additive: false)
            let composite = try pipeline("vela_quad_vertex", "vela_composite_fragment", format: VelaGPU.pixelFormat, additive: false)

            // Same deterministic random attributes as the prototype (Park-Miller, seed 1234567).
            let n = VelaGPU.particleCount * 4
            var data = [Float](repeating: 0, count: n)
            var s: Int64 = 1_234_567
            for i in 0..<n {
                s = (s * 16807) % 2_147_483_647
                data[i] = Float(Double(s) / 2_147_483_647.0)
            }
            guard let buffer = device.makeBuffer(bytes: data,
                                                 length: n * MemoryLayout<Float>.stride,
                                                 options: .storageModeShared) else {
                return nil
            }
            self.device = device
            self.queue = queue
            self.quadPipelines = quads
            self.pointPipeline = points
            self.thresholdPipeline = threshold
            self.blurPipeline = blur
            self.compositePipeline = composite
            self.particles = buffer
        } catch {
            print("[Vela] Pipeline-Fehler: \(error)")
            return nil
        }
    }
}

/// MTKView delegate. One instance per visible visual (stage + settings thumbnails).
final class VelaRenderer: NSObject, MTKViewDelegate {
    private let gpu: VelaGPU
    let driver: VisualDriver
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var sceneTexture: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?

    // Adaptive resolution (prototype: drop the render scale when frames are slow).
    private var slowAcc: Double = 0
    private var slowN = 0
    private(set) var renderScale: CGFloat = 2

    init(gpu: VelaGPU, driver: VisualDriver) {
        self.gpu = gpu
        self.driver = driver
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Static thumbnails only draw on demand: redraw once the real size is known.
        if driver.isStatic {
            MainActor.assumeIsolated {
                view.setNeedsDisplay()
            }
        }
    }

    func draw(in view: MTKView) {
        // MTKView drives this from the main run loop. `assumeIsolated` keeps the
        // code valid whether or not the SDK marks MTKViewDelegate as @MainActor.
        MainActor.assumeIsolated {
            self.render(in: view)
        }
    }

    @MainActor
    private func render(in view: MTKView) {
        let now = CACurrentMediaTime()
        let rawDt = now - lastTime
        lastTime = now

        if !driver.isStatic {
            adaptResolution(view: view, dt: rawDt)
        }

        let size = view.drawableSize
        guard size.width > 1, size.height > 1,
              let drawable = view.currentDrawable,
              let commandBuffer = gpu.queue.makeCommandBuffer(),
              ensureTargets(size) else {
            return
        }

        var u = driver.step(dt: Float(rawDt))
        u.res = SIMD2<Float>(Float(size.width), Float(size.height))
        let viewWidth = Float(max(view.bounds.width, 1))
        u.px = Float(size.width) * driver.pointRelative(viewWidth: viewWidth)

        let design = max(0, min(2, Int(u.design)))
        let length = MemoryLayout<VelaUniforms>.stride
        guard let scene = sceneTexture, let bloomA, let bloomB else { return }

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = scene
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) else { return }

        encoder.setRenderPipelineState(gpu.quadPipelines[design])
        encoder.setFragmentBytes(&u, length: length, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.setRenderPipelineState(gpu.pointPipeline)
        encoder.setVertexBuffer(gpu.particles, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: length, index: 1)
        let count = design == 0 ? min(VelaGPU.particleCount, 1100) : VelaGPU.particleCount
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        encoder.endEncoding()

        // Bright parts, then a separable blur, then ACES + dither onto the screen.
        fullscreen(commandBuffer, pipeline: gpu.thresholdPipeline, source: scene, target: bloomA, direction: nil)
        fullscreen(commandBuffer, pipeline: gpu.blurPipeline, source: bloomA, target: bloomB, direction: SIMD2<Float>(1, 0))
        fullscreen(commandBuffer, pipeline: gpu.blurPipeline, source: bloomB, target: bloomA, direction: SIMD2<Float>(0, 1))

        guard let drawablePass = view.currentRenderPassDescriptor,
              let composite = commandBuffer.makeRenderCommandEncoder(descriptor: drawablePass) else { return }
        composite.setRenderPipelineState(gpu.compositePipeline)
        composite.setFragmentTexture(scene, index: 0)
        composite.setFragmentTexture(bloomA, index: 1)
        composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        composite.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func fullscreen(_ buffer: MTLCommandBuffer, pipeline: MTLRenderPipelineState, source: MTLTexture, target: MTLTexture, direction: SIMD2<Float>?) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        var targetSize = SIMD2<Float>(Float(target.width), Float(target.height))
        if let direction {
            var dir = direction
            encoder.setFragmentBytes(&dir, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.setFragmentBytes(&targetSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        } else {
            encoder.setFragmentBytes(&targetSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func ensureTargets(_ size: CGSize) -> Bool {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        if sceneTexture?.width == width, sceneTexture?.height == height { return sceneTexture != nil }
        sceneTexture = makeTexture(width, height)
        bloomA = makeTexture(max(width / 4, 1), max(height / 4, 1))
        bloomB = makeTexture(max(width / 4, 1), max(height / 4, 1))
        return sceneTexture != nil && bloomA != nil && bloomB != nil
    }

    private func makeTexture(_ width: Int, _ height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: VelaGPU.sceneFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        return gpu.device.makeTexture(descriptor: desc)
    }

    @MainActor
    private func adaptResolution(view: MTKView, dt: Double) {
        slowAcc += min(dt, 0.1)
        slowN += 1
        guard slowN >= 90 else { return }
        let avg = slowAcc / Double(slowN)
        slowAcc = 0
        slowN = 0
        if avg > 0.024, renderScale > 1.1 {
            renderScale = max(1, renderScale - 0.35)
            view.contentScaleFactor = renderScale
        }
    }
}
