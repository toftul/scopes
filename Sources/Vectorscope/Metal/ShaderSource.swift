/// Metal shader source, compiled at runtime via `device.makeLibrary(source:)`.
///
/// Runtime compilation is what lets this build with only the Command Line
/// Tools (no offline `metal` compiler). Once full Xcode is installed you can
/// move this into a `.metal` file and precompile to a `.metallib` for faster
/// startup — the shader code itself is unchanged.
enum ShaderSource {
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    // ---- Uniforms (must match the Swift structs field-for-field) ----

    struct ScopeParams {
        float kr;      // Rec.709/601 luma weight (red)
        float kb;      // ...                     (blue)
        float scale;   // Cb/Cr -> scope space multiplier
        uint  bins;    // histogram dimension (NxN)
    };

    struct TraceParams {
        uint  bins;
        float gain;        // trace brightness
        uint  mode;        // 0 = colorize (hue), 1 = mono green, 2 = heatmap
        float scale;       // Cb/Cr -> scope space (to invert back to chroma)
        float kr;          // luma weights, for the inverse Y'CbCr -> RGB
        float kb;
        float saturation;  // 0 = white, 1 = full hue (pale look < 1)
    };

    // ---- Pass 1: accumulate a 2D (Cb,Cr) histogram from the source frame ----

    kernel void accumulateHistogram(
        texture2d<float, access::read> src   [[texture(0)]],
        device atomic_uint*            hist  [[buffer(0)]],
        constant ScopeParams&          p     [[buffer(1)]],
        uint2                          gid   [[thread_position_in_grid]])
    {
        if (gid.x >= src.get_width() || gid.y >= src.get_height()) { return; }

        float4 c = src.read(gid);
        float kr = p.kr, kb = p.kb;
        float y  = kr * c.r + (1.0 - kr - kb) * c.g + kb * c.b;
        float cb = (c.b - y) / (2.0 * (1.0 - kb));
        float cr = (c.r - y) / (2.0 * (1.0 - kr));

        // scope space [-1,1] -> bin coords [0,bins)
        float fx = (cb * p.scale * 0.5 + 0.5) * float(p.bins);
        float fy = (cr * p.scale * 0.5 + 0.5) * float(p.bins);
        if (fx < 0.0 || fy < 0.0 || fx >= float(p.bins) || fy >= float(p.bins)) { return; }

        uint idx = uint(fy) * p.bins + uint(fx);
        atomic_fetch_add_explicit(&hist[idx], 1u, memory_order_relaxed);
    }

    // ---- Pass 2: draw the trace from the histogram (full-screen triangle) ----

    struct VSOut {
        float4 pos   [[position]];
        float2 scope;   // [-1,1] scope-space coordinate
    };

    vertex VSOut traceVertex(uint vid [[vertex_id]]) {
        float2 p;
        p.x = (vid == 2) ? 3.0 : -1.0;
        p.y = (vid == 1) ? 3.0 : -1.0;
        VSOut o;
        o.pos   = float4(p, 0.0, 1.0);
        o.scope = p;             // clip xy == scope space
        return o;
    }

    static inline float sampleHist(device const uint* hist, int x, int y, uint bins) {
        x = clamp(x, 0, int(bins) - 1);
        y = clamp(y, 0, int(bins) - 1);
        return float(hist[uint(y) * bins + uint(x)]);
    }

    fragment float4 traceFragment(
        VSOut                in   [[stage_in]],
        device const uint*   hist [[buffer(0)]],
        constant TraceParams& tp  [[buffer(1)]])
    {
        // Bilinearly sample the histogram so the trace reads as a smooth glow
        // rather than hard cells.
        float2 uv = (in.scope * 0.5 + 0.5) * float(tp.bins) - 0.5;
        int2   i0 = int2(floor(uv));
        float2 fr = uv - float2(i0);
        float c00 = sampleHist(hist, i0.x,     i0.y,     tp.bins);
        float c10 = sampleHist(hist, i0.x + 1, i0.y,     tp.bins);
        float c01 = sampleHist(hist, i0.x,     i0.y + 1, tp.bins);
        float c11 = sampleHist(hist, i0.x + 1, i0.y + 1, tp.bins);
        float count = mix(mix(c00, c10, fr.x), mix(c01, c11, fr.x), fr.y);

        float v = clamp(log(1.0 + count * tp.gain), 0.0, 1.0);
        if (v <= 0.002) { discard_fragment(); return float4(0.0); }

        if (tp.mode == 1u) {                                    // classic green trace
            return float4(0.10 * v, v, 0.20 * v, 1.0);
        }
        if (tp.mode == 2u) {                                    // cool -> warm heatmap
            float3 col = mix(float3(0.0, 0.05, 0.4), float3(1.0, 0.95, 0.2), v);
            return float4(col * v, 1.0);
        }

        // mode 0: colorize — reconstruct the hue at this scope position by
        // inverting Y'CbCr -> R'G'B', then normalise to a pure, bright hue.
        float kr = tp.kr, kb = tp.kb, kg = 1.0 - kr - kb;
        float cb = in.scope.x / tp.scale;
        float cr = in.scope.y / tp.scale;
        float3 c;
        c.r = 2.0 * (1.0 - kr) * cr;
        c.b = 2.0 * (1.0 - kb) * cb;
        c.g = -(kr * c.r + kb * c.b) / kg;
        c -= min(c.r, min(c.g, c.b));           // lift darkest channel to 0
        float mx = max(c.r, max(c.g, c.b));
        c = (mx > 1e-4) ? c / mx : float3(1.0); // pure hue; centre -> white
        c = mix(float3(1.0), c, tp.saturation); // desaturate toward white (pale)
        return float4(c * v, 1.0);
    }

    // ---- Pass 3: graticule (rings, crosshair, target boxes, skin line) ----

    vertex float4 gratVertex(const device float2* verts [[buffer(0)]],
                             uint vid [[vertex_id]]) {
        return float4(verts[vid], 0.0, 1.0);
    }

    fragment float4 gratFragment(constant float4& color [[buffer(0)]]) {
        return color;
    }

    // ---- Waveform / Parade -------------------------------------------------
    //
    // A waveform is a 2D histogram indexed by (source column, value). We
    // accumulate four channels per cell: R, G, B and luma.

    struct WaveParams {   // compute
        uint  waveBins;   // horizontal resolution (source columns)
        uint  valueBins;  // vertical resolution (0..1 value)
        float kr;
        float kb;
    };

    kernel void accumulateWaveform(
        texture2d<float, access::read> src  [[texture(0)]],
        device atomic_uint*            wave [[buffer(0)]],
        constant WaveParams&           p    [[buffer(1)]],
        uint2                          gid  [[thread_position_in_grid]])
    {
        uint W = src.get_width();
        uint H = src.get_height();
        if (gid.x >= W || gid.y >= H) { return; }

        float4 c   = src.read(gid);
        float  kr  = p.kr, kb = p.kb, kg = 1.0 - kr - kb;
        float  lum = kr * c.r + kg * c.g + kb * c.b;

        uint bx = min(uint(float(gid.x) / float(W) * float(p.waveBins)), p.waveBins - 1u);
        uint vb = p.valueBins;
        uint vr = min(uint(clamp(c.r, 0.0, 1.0) * float(vb - 1u)), vb - 1u);
        uint vg = min(uint(clamp(c.g, 0.0, 1.0) * float(vb - 1u)), vb - 1u);
        uint vB = min(uint(clamp(c.b, 0.0, 1.0) * float(vb - 1u)), vb - 1u);
        uint vl = min(uint(clamp(lum, 0.0, 1.0) * float(vb - 1u)), vb - 1u);

        atomic_fetch_add_explicit(&wave[(vr * p.waveBins + bx) * 4u + 0u], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&wave[(vg * p.waveBins + bx) * 4u + 1u], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&wave[(vB * p.waveBins + bx) * 4u + 2u], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&wave[(vl * p.waveBins + bx) * 4u + 3u], 1u, memory_order_relaxed);
    }

    struct WaveVSOut {
        float4 pos [[position]];
        float2 uv;   // 0..1 across the viewport (x left→right, y bottom→top)
    };

    vertex WaveVSOut waveVertex(uint vid [[vertex_id]]) {
        float2 p;
        p.x = (vid == 2) ? 3.0 : -1.0;
        p.y = (vid == 1) ? 3.0 : -1.0;
        WaveVSOut o;
        o.pos = float4(p, 0.0, 1.0);
        o.uv  = p * 0.5 + 0.5;
        return o;
    }

    struct WaveDrawParams {   // fragment
        uint  waveBins;
        uint  valueBins;
        float gain;
        uint  mode;   // 0 = luma, 1 = parade, 2 = rgb overlay
    };

    static inline float sampleWave(device const uint* wave, float2 uv, int ch,
                                   uint waveBins, uint valueBins) {
        float fx = clamp(uv.x, 0.0, 1.0) * float(waveBins)  - 0.5;
        float fy = clamp(uv.y, 0.0, 1.0) * float(valueBins) - 0.5;
        int x0 = int(floor(fx)), y0 = int(floor(fy));
        float tx = fx - float(x0), ty = fy - float(y0);
        int xa = clamp(x0,     0, int(waveBins)  - 1), xb = clamp(x0 + 1, 0, int(waveBins)  - 1);
        int ya = clamp(y0,     0, int(valueBins) - 1), yb = clamp(y0 + 1, 0, int(valueBins) - 1);
        float c00 = float(wave[(uint(ya) * waveBins + uint(xa)) * 4u + uint(ch)]);
        float c10 = float(wave[(uint(ya) * waveBins + uint(xb)) * 4u + uint(ch)]);
        float c01 = float(wave[(uint(yb) * waveBins + uint(xa)) * 4u + uint(ch)]);
        float c11 = float(wave[(uint(yb) * waveBins + uint(xb)) * 4u + uint(ch)]);
        return mix(mix(c00, c10, tx), mix(c01, c11, tx), ty);
    }

    fragment float4 waveFragment(
        WaveVSOut                in   [[stage_in]],
        device const uint*       wave [[buffer(0)]],
        constant WaveDrawParams& p    [[buffer(1)]])
    {
        if (p.mode == 1u) {                 // RGB parade — three panels side by side
            float x3 = in.uv.x * 3.0;
            int   ch = min(int(floor(x3)), 2);
            float lx = x3 - float(ch);
            float count = sampleWave(wave, float2(lx, in.uv.y), ch, p.waveBins, p.valueBins);
            float v = clamp(log(1.0 + count * p.gain), 0.0, 1.0);
            if (v <= 0.002) { discard_fragment(); return float4(0.0); }
            float3 base = (ch == 0) ? float3(1.0, 0.28, 0.28)
                        : (ch == 1) ? float3(0.28, 1.0, 0.38)
                                    : float3(0.38, 0.55, 1.0);
            return float4(base * v, 1.0);
        }
        if (p.mode == 2u) {                 // RGB overlay
            float vr = clamp(log(1.0 + sampleWave(wave, in.uv, 0, p.waveBins, p.valueBins) * p.gain), 0.0, 1.0);
            float vg = clamp(log(1.0 + sampleWave(wave, in.uv, 1, p.waveBins, p.valueBins) * p.gain), 0.0, 1.0);
            float vb = clamp(log(1.0 + sampleWave(wave, in.uv, 2, p.waveBins, p.valueBins) * p.gain), 0.0, 1.0);
            if (vr + vg + vb <= 0.004) { discard_fragment(); return float4(0.0); }
            return float4(vr, vg, vb, 1.0);
        }
        // luma waveform
        float count = sampleWave(wave, in.uv, 3, p.waveBins, p.valueBins);
        float v = clamp(log(1.0 + count * p.gain), 0.0, 1.0);
        if (v <= 0.002) { discard_fragment(); return float4(0.0); }
        return float4(float3(0.85, 0.92, 0.85) * v, 1.0);
    }
    """
}
