import Metal
import MetalKit
import CoreVideo
import simd

/// GPU pipeline for the vectorscope + waveform/parade.
///
/// Frames are consumed **in the capture callback** (`process(pixelBuffer:)`),
/// because ScreenCaptureKit's IOSurface is only valid for the duration of that
/// callback. We build both histograms there (keeping the CVMetalTexture alive
/// until the GPU is done) and publish them via a double buffer. `draw(in:)`
/// renders the vectorscope into a square top viewport and the waveform into a
/// wide bottom viewport of the same drawable.
final class VectorscopeRenderer: NSObject, MTKViewDelegate {

    // Uniform structs — layouts must match ShaderSource exactly.
    private struct ScopeParams { var kr: Float; var kb: Float; var scale: Float; var bins: UInt32 }
    private struct TraceParams {
        var bins: UInt32; var gain: Float; var mode: UInt32
        var scale: Float; var kr: Float; var kb: Float; var saturation: Float
    }
    private struct WaveParams { var waveBins: UInt32; var valueBins: UInt32; var kr: Float; var kb: Float }
    private struct WaveDrawParams { var waveBins: UInt32; var valueBins: UInt32; var gain: Float; var mode: UInt32 }

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache!

    private var accumulatePipeline: MTLComputePipelineState!        // vectorscope
    private var accumulateWavePipeline: MTLComputePipelineState!    // waveform
    private var tracePipeline: MTLRenderPipelineState!
    private var wavePipeline: MTLRenderPipelineState!
    private var graticulePipeline: MTLRenderPipelineState!

    private let bins = 256                 // vectorscope histogram is bins×bins
    private let waveBins = 512             // waveform columns
    private let valueBins = 256            // waveform value resolution

    // Double-buffered histograms; frontIndex is what draw() reads.
    private var histograms: [MTLBuffer] = []       // vectorscope
    private var waveHistograms: [MTLBuffer] = []    // waveform (waveBins×valueBins×4)
    private var frontIndex = 0
    private let histLock = NSLock()

    private var graticuleBuffer: MTLBuffer!
    private var graticuleVertexCount = 0
    private var waveGratBuffer: MTLBuffer!          // horizontal IRE lines
    private var waveGratCount = 0
    private var paradeDivBuffer: MTLBuffer!         // vertical dividers (parade)
    private var paradeDivCount = 0

    // User-tweakable display state.
    var colorSpace: Colorimetry.Space = .rec709 { didSet { rebuildGraticule() } }
    var mode: UInt32 = 0            // vectorscope: 0 colorize, 1 mono, 2 heatmap
    var gain: Float = 0.15
    var saturation: Float = 0.65
    var waveformMode: UInt32 = 0   // 0 luma, 1 parade, 2 rgb overlay
    var waveGain: Float = 0.08

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        super.init()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard textureCache != nil else { return nil }

        do { try buildPipelines() }
        catch { NSLog("Vectorscope: pipeline build failed: \(error)"); return nil }

        let vecLen = bins * bins * MemoryLayout<UInt32>.stride
        let waveLen = waveBins * valueBins * 4 * MemoryLayout<UInt32>.stride
        guard let v0 = device.makeBuffer(length: vecLen, options: .storageModePrivate),
              let v1 = device.makeBuffer(length: vecLen, options: .storageModePrivate),
              let w0 = device.makeBuffer(length: waveLen, options: .storageModePrivate),
              let w1 = device.makeBuffer(length: waveLen, options: .storageModePrivate) else { return nil }
        histograms = [v0, v1]
        waveHistograms = [w0, w1]

        // Zero all buffers so draw() before the first frame shows empty scopes
        // (private buffers aren't zero-initialised).
        if let cmd = commandQueue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            for b in histograms + waveHistograms { blit.fill(buffer: b, range: 0..<b.length, value: 0) }
            blit.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
        }

        rebuildGraticule()
        buildWaveGraticule()
    }

    // MARK: - Frame intake (capture queue)

    func process(pixelBuffer pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)

        // Keep `cvTex` alive until the GPU work below finishes — releasing the
        // wrapper can invalidate the MTLTexture it vends.
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pb, nil,
                .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let src = CVMetalTextureGetTexture(cvTex),
              let cmd = commandQueue.makeCommandBuffer() else { return }

        histLock.lock(); let back = 1 - frontIndex; histLock.unlock()
        let vecTarget = histograms[back]
        let waveTarget = waveHistograms[back]

        if let blit = cmd.makeBlitCommandEncoder() {
            blit.fill(buffer: vecTarget, range: 0..<vecTarget.length, value: 0)
            blit.fill(buffer: waveTarget, range: 0..<waveTarget.length, value: 0)
            blit.endEncoding()
        }
        if let enc = cmd.makeComputeCommandEncoder() {
            // vectorscope histogram
            enc.setComputePipelineState(accumulatePipeline)
            enc.setTexture(src, index: 0)
            enc.setBuffer(vecTarget, offset: 0, index: 0)
            var sp = ScopeParams(kr: colorSpace.kr, kb: colorSpace.kb,
                                 scale: Colorimetry.displayScale, bins: UInt32(bins))
            enc.setBytes(&sp, length: MemoryLayout<ScopeParams>.stride, index: 1)
            dispatch(enc, accumulatePipeline, src)

            // waveform histogram
            enc.setComputePipelineState(accumulateWavePipeline)
            enc.setBuffer(waveTarget, offset: 0, index: 0)
            var wp = WaveParams(waveBins: UInt32(waveBins), valueBins: UInt32(valueBins),
                                kr: colorSpace.kr, kb: colorSpace.kb)
            enc.setBytes(&wp, length: MemoryLayout<WaveParams>.stride, index: 1)
            dispatch(enc, accumulateWavePipeline, src)

            enc.endEncoding()
        }

        cmd.commit()
        cmd.waitUntilCompleted()
        _ = cvTex
        CVMetalTextureCacheFlush(textureCache, 0)

        histLock.lock(); frontIndex = back; histLock.unlock()
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder,
                          _ pipe: MTLComputePipelineState, _ src: MTLTexture) {
        let tw = pipe.threadExecutionWidth
        let th = max(1, pipe.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: src.width, height: src.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    // MARK: - Pipelines

    private func buildPipelines() throws {
        let library = try device.makeLibrary(source: ShaderSource.metal, options: nil)

        func compute(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else { throw RendererError.missingFunction(name) }
            return try device.makeComputePipelineState(function: fn)
        }
        accumulatePipeline = try compute("accumulateHistogram")
        accumulateWavePipeline = try compute("accumulateWaveform")

        func render(_ vfn: String, _ ffn: String, blend: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vfn)
            d.fragmentFunction = library.makeFunction(name: ffn)
            let att = d.colorAttachments[0]!
            att.pixelFormat = .bgra8Unorm
            if blend {
                att.isBlendingEnabled = true
                att.sourceRGBBlendFactor = .sourceAlpha
                att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        tracePipeline = try render("traceVertex", "traceFragment", blend: false)
        wavePipeline = try render("waveVertex", "waveFragment", blend: false)
        graticulePipeline = try render("gratVertex", "gratFragment", blend: true)
    }

    private enum RendererError: Error { case missingFunction(String) }

    // MARK: - Graticules

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
        v.append(SIMD2(-1, 0)); v.append(SIMD2(1, 0))
        v.append(SIMD2(0, -1)); v.append(SIMD2(0, 1))

        let level: Float = 0.75
        let targets: [(Float, Float, Float)] = [
            (level, 0, 0), (0, level, 0), (0, 0, level),
            (0, level, level), (level, 0, level), (level, level, 0),
        ]
        for (r, g, b) in targets {
            let cc = Colorimetry.cbcr(r: r, g: g, b: b, space: colorSpace)
            let p = SIMD2(cc.x * scale, cc.y * scale)
            let s: Float = 0.04
            let corners = [SIMD2(p.x - s, p.y - s), SIMD2(p.x + s, p.y - s),
                           SIMD2(p.x + s, p.y + s), SIMD2(p.x - s, p.y + s)]
            for i in 0..<4 { v.append(corners[i]); v.append(corners[(i + 1) % 4]) }
        }

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

    private func buildWaveGraticule() {
        // Horizontal lines at 0/25/50/75/100% (clip y = value*2-1).
        var g: [SIMD2<Float>] = []
        for value in [Float(0), 0.25, 0.5, 0.75, 1.0] {
            let y = value * 2 - 1
            g.append(SIMD2(-1, y)); g.append(SIMD2(1, y))
        }
        waveGratCount = g.count
        waveGratBuffer = device.makeBuffer(bytes: g,
                                           length: MemoryLayout<SIMD2<Float>>.stride * g.count,
                                           options: .storageModeShared)

        // Vertical dividers between the three parade panels.
        var d: [SIMD2<Float>] = []
        for bx in [Float(-1.0 / 3.0), Float(1.0 / 3.0)] {
            d.append(SIMD2(bx, -1)); d.append(SIMD2(bx, 1))
        }
        paradeDivCount = d.count
        paradeDivBuffer = device.makeBuffer(bytes: d,
                                            length: MemoryLayout<SIMD2<Float>>.stride * d.count,
                                            options: .storageModeShared)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        histLock.lock(); let idx = frontIndex; histLock.unlock()
        let vec = histograms[idx]
        let wave = waveHistograms[idx]

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer() else { return }

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let dw = view.drawableSize.width
        let dh = view.drawableSize.height
        let gap = dh * 0.02
        let waveH = dh * 0.33
        let topH = dh - waveH - gap

        // Vectorscope — square, centred in the top region.
        let side = min(dw, topH)
        let sx = (dw - side) / 2, sy = (topH - side) / 2
        enc.setViewport(MTLViewport(originX: sx, originY: sy, width: side, height: side, znear: 0, zfar: 1))
        setScissor(enc, sx, sy, side, side, dw, dh)
        drawVectorscope(enc, hist: vec)

        // Waveform / parade — wide, bottom region.
        let wx = dw * 0.04, ww = dw * 0.92
        let wy = topH + gap, wh = waveH - gap
        enc.setViewport(MTLViewport(originX: wx, originY: wy, width: ww, height: wh, znear: 0, zfar: 1))
        setScissor(enc, wx, wy, ww, wh, dw, dh)
        drawWaveform(enc, wave: wave)

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func setScissor(_ enc: MTLRenderCommandEncoder,
                            _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                            _ dw: Double, _ dh: Double) {
        let ix = max(0, Int(x)), iy = max(0, Int(y))
        let iw = min(Int(w), Int(dw) - ix), ih = min(Int(h), Int(dh) - iy)
        guard iw > 0, ih > 0 else { return }
        enc.setScissorRect(MTLScissorRect(x: ix, y: iy, width: iw, height: ih))
    }

    private func drawVectorscope(_ enc: MTLRenderCommandEncoder, hist: MTLBuffer) {
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
    }

    private func drawWaveform(_ enc: MTLRenderCommandEncoder, wave: MTLBuffer) {
        enc.setRenderPipelineState(wavePipeline)
        enc.setFragmentBuffer(wave, offset: 0, index: 0)
        var wp = WaveDrawParams(waveBins: UInt32(waveBins), valueBins: UInt32(valueBins),
                                gain: waveGain, mode: waveformMode)
        enc.setFragmentBytes(&wp, length: MemoryLayout<WaveDrawParams>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // graticule on top
        enc.setRenderPipelineState(graticulePipeline)
        var gcol = SIMD4<Float>(0.4, 0.4, 0.45, 0.4)
        enc.setVertexBuffer(waveGratBuffer, offset: 0, index: 0)
        enc.setFragmentBytes(&gcol, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: waveGratCount)

        if waveformMode == 1, paradeDivCount > 0 {
            enc.setVertexBuffer(paradeDivBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: paradeDivCount)
        }
    }
}
