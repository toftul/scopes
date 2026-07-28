import Metal
import MetalKit
import CoreVideo
import simd

/// GPU pipeline for the vectorscope.
///
/// Frames are consumed **in the capture callback** (`process(pixelBuffer:)`),
/// because ScreenCaptureKit's IOSurface is only valid for the duration of that
/// callback — its pool recycles the surface afterwards. We build the histogram
/// there (keeping the CVMetalTexture wrapper alive until the GPU is done) and
/// publish it into a double buffer. `draw(in:)` only renders from the finished
/// front buffer, so the display is decoupled from the capture rate and never
/// reads a recycled surface.
final class VectorscopeRenderer: NSObject, MTKViewDelegate {

    // Uniform structs — layout must match ShaderSource exactly.
    private struct ScopeParams { var kr: Float; var kb: Float; var scale: Float; var bins: UInt32 }
    private struct TraceParams {
        var bins: UInt32; var gain: Float; var mode: UInt32
        var scale: Float; var kr: Float; var kb: Float; var saturation: Float
    }

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache!

    private var accumulatePipeline: MTLComputePipelineState!
    private var tracePipeline: MTLRenderPipelineState!
    private var graticulePipeline: MTLRenderPipelineState!

    private let bins = 256
    private var histograms: [MTLBuffer] = []   // [0] and [1], double-buffered
    private var frontIndex = 0                  // buffer draw() reads; guarded by histLock
    private let histLock = NSLock()

    private var graticuleBuffer: MTLBuffer!
    private var graticuleVertexCount = 0

    // User-tweakable display state.
    var colorSpace: Colorimetry.Space = .rec709 { didSet { rebuildGraticule() } }
    var mode: UInt32 = 0            // 0 colorize, 1 mono, 2 heatmap
    var gain: Float = 0.15
    var saturation: Float = 0.65    // < 1 = paler

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        super.init()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard textureCache != nil else { return nil }

        do {
            try buildPipelines()
        } catch {
            NSLog("Vectorscope: pipeline build failed: \(error)")
            return nil
        }

        // Two histogram buffers, both zeroed so draw() before the first frame
        // shows an empty scope rather than garbage (private buffers aren't
        // zero-initialised).
        let length = bins * bins * MemoryLayout<UInt32>.stride
        guard let h0 = device.makeBuffer(length: length, options: .storageModePrivate),
              let h1 = device.makeBuffer(length: length, options: .storageModePrivate) else {
            return nil
        }
        histograms = [h0, h1]
        if let cmd = commandQueue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.fill(buffer: h0, range: 0..<length, value: 0)
            blit.fill(buffer: h1, range: 0..<length, value: 0)
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        rebuildGraticule()
    }

    // MARK: - Frame intake (called on the capture queue)

    /// Build the histogram for this frame while its IOSurface is still valid.
    func process(pixelBuffer pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)

        // NOTE: keep `cvTex` alive until the GPU finishes below — releasing the
        // CVMetalTexture wrapper can invalidate the MTLTexture it vends.
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pb, nil,
                .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let src = CVMetalTextureGetTexture(cvTex),
              let cmd = commandQueue.makeCommandBuffer() else { return }

        histLock.lock(); let back = 1 - frontIndex; histLock.unlock()
        let target = histograms[back]

        if let blit = cmd.makeBlitCommandEncoder() {
            blit.fill(buffer: target, range: 0..<target.length, value: 0)
            blit.endEncoding()
        }
        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(accumulatePipeline)
            enc.setTexture(src, index: 0)
            enc.setBuffer(target, offset: 0, index: 0)
            var p = ScopeParams(kr: colorSpace.kr, kb: colorSpace.kb,
                                scale: Colorimetry.displayScale, bins: UInt32(bins))
            enc.setBytes(&p, length: MemoryLayout<ScopeParams>.stride, index: 1)
            let tw = accumulatePipeline.threadExecutionWidth
            let th = max(1, accumulatePipeline.maxTotalThreadsPerThreadgroup / tw)
            enc.dispatchThreads(MTLSize(width: src.width, height: src.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            enc.endEncoding()
        }

        cmd.commit()
        cmd.waitUntilCompleted()     // src (IOSurface) read + histogram done here
        _ = cvTex                    // keep the wrapper alive across the GPU work
        CVMetalTextureCacheFlush(textureCache, 0)

        histLock.lock(); frontIndex = back; histLock.unlock()
    }

    // MARK: - Pipeline setup

    private func buildPipelines() throws {
        let library = try device.makeLibrary(source: ShaderSource.metal, options: nil)

        guard let kAccum = library.makeFunction(name: "accumulateHistogram") else {
            throw RendererError.missingFunction("accumulateHistogram")
        }
        accumulatePipeline = try device.makeComputePipelineState(function: kAccum)

        let trace = MTLRenderPipelineDescriptor()
        trace.vertexFunction = library.makeFunction(name: "traceVertex")
        trace.fragmentFunction = library.makeFunction(name: "traceFragment")
        trace.colorAttachments[0].pixelFormat = .bgra8Unorm
        tracePipeline = try device.makeRenderPipelineState(descriptor: trace)

        let grat = MTLRenderPipelineDescriptor()
        grat.vertexFunction = library.makeFunction(name: "gratVertex")
        grat.fragmentFunction = library.makeFunction(name: "gratFragment")
        let att = grat.colorAttachments[0]!
        att.pixelFormat = .bgra8Unorm
        att.isBlendingEnabled = true
        att.sourceRGBBlendFactor = .sourceAlpha
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        graticulePipeline = try device.makeRenderPipelineState(descriptor: grat)
    }

    private enum RendererError: Error { case missingFunction(String) }

    // MARK: - Graticule geometry

    private func rebuildGraticule() {
        var v: [SIMD2<Float>] = []
        let scale = Colorimetry.displayScale

        func circle(_ radius: Float, segments: Int = 96) {
            for i in 0..<segments {
                let a0 = Float(i) / Float(segments) * 2 * .pi
                let a1 = Float(i + 1) / Float(segments) * 2 * .pi
                v.append(SIMD2(cos(a0) * radius, sin(a0) * radius))
                v.append(SIMD2(cos(a1) * radius, sin(a1) * radius))
            }
        }
        circle(0.25); circle(0.5); circle(0.75); circle(1.0)

        // crosshair
        v.append(SIMD2(-1, 0)); v.append(SIMD2(1, 0))
        v.append(SIMD2(0, -1)); v.append(SIMD2(0, 1))

        // 75% colour-bar target boxes
        let level: Float = 0.75
        let targets: [(Float, Float, Float)] = [
            (level, 0, 0), (0, level, 0), (0, 0, level),      // R, G, B
            (0, level, level), (level, 0, level), (level, level, 0), // Cy, Mg, Yl
        ]
        for (r, g, b) in targets {
            let cc = Colorimetry.cbcr(r: r, g: g, b: b, space: colorSpace)
            let p = SIMD2(cc.x * scale, cc.y * scale)
            let s: Float = 0.04
            let corners = [SIMD2(p.x - s, p.y - s), SIMD2(p.x + s, p.y - s),
                           SIMD2(p.x + s, p.y + s), SIMD2(p.x - s, p.y + s)]
            for i in 0..<4 { v.append(corners[i]); v.append(corners[(i + 1) % 4]) }
        }

        // skin-tone reference line (approximate; representative flesh chroma)
        let skin = Colorimetry.cbcr(r: 0.85, g: 0.62, b: 0.52, space: colorSpace)
        var dir = SIMD2(skin.x * scale, skin.y * scale)
        let len = (dir.x * dir.x + dir.y * dir.y).squareRoot()
        if len > 0 { dir = dir / len * 0.95 }
        v.append(SIMD2(0, 0)); v.append(dir)

        graticuleVertexCount = v.count
        graticuleBuffer = device.makeBuffer(bytes: v,
                                            length: MemoryLayout<SIMD2<Float>>.stride * v.count,
                                            options: .storageModeShared)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        histLock.lock(); let hist = histograms[frontIndex]; histLock.unlock()

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer() else { return }

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)

        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(tracePipeline)
            enc.setFragmentBuffer(hist, offset: 0, index: 0)
            var tp = TraceParams(bins: UInt32(bins), gain: gain, mode: mode,
                                 scale: Colorimetry.displayScale,
                                 kr: colorSpace.kr, kb: colorSpace.kb, saturation: saturation)
            enc.setFragmentBytes(&tp, length: MemoryLayout<TraceParams>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            if graticuleVertexCount > 0 {
                enc.setRenderPipelineState(graticulePipeline)
                enc.setVertexBuffer(graticuleBuffer, offset: 0, index: 0)
                var color = SIMD4<Float>(0.55, 0.55, 0.6, 0.5)
                enc.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: graticuleVertexCount)
            }
            enc.endEncoding()
        }

        cmd.present(drawable)
        cmd.commit()
    }
}
