# Development

Everything you need to build, hack on and release Vectorscope.

## Requirements

macOS 14 or later and the Xcode **Command Line Tools** — that's it. The Metal
shaders are compiled at runtime from a Swift string
(`Metal/ShaderSource.swift`), so there are no `.metal` files and no offline
`metal` compiler is needed. There is no Xcode project either; it's a plain
SwiftPM executable wrapped into a `.app`.

```bash
xcode-select --install
```

## Build & run

```bash
./build-app.sh                  # → build/Vectorscope.app (signed)
open build/Vectorscope.app
```

Use the **bundled** app rather than `swift run`: Screen Recording permission is
attributed to the running bundle, so `swift run` grants it to your *terminal*
instead. First launch prompts for permission — grant it, then relaunch.

For a fast inner loop:

```bash
swift build                             # debug build
swift run Vectorscope                   # unbundled (permission → terminal)
swift run Vectorscope --check-shaders   # compile all shaders, verify entry points, exit 0/1
```

`--check-shaders` is the quickest correctness gate after touching a shader — it
runs headless and needs no permission.

## Signing & the Screen Recording grant

Screen Recording (TCC) permission is bound to the app's **code signature**.
Ad-hoc signatures change on every rebuild, so the grant would be lost each time.
The repo therefore uses a stable self-signed identity, **"Vectorscope Dev"**:

```bash
./scripts/make-signing-cert.sh   # one-time
```

The first `codesign` after import pops a keychain dialog — click **Always
Allow** once, and it's silent from then on. `build-app.sh` picks the identity up
automatically, falling back to ad-hoc signing (which breaks grant persistence).

If the signing identity ever changes, the old grant goes stale. Reset it:

```bash
tccutil reset ScreenCapture co.vectorscope.picker
```

## Releasing

Push a tag; CI does the rest.

```bash
git tag v0.2.0 && git push origin v0.2.0
```

`.github/workflows/release.yml` runs `scripts/release.sh` on a macOS runner,
which builds a universal (arm64 + x86_64) bundle, stamps the version from the
tag into `Info.plist`, ad-hoc signs it and zips it with `ditto` (a plain `zip`
mangles the signature and yields an app macOS won't launch). The zip is attached
to a GitHub release along with install notes and a SHA-256.

To produce the same artifact locally:

```bash
./scripts/release.sh 0.2.0      # → build/Vectorscope-0.2.0-universal.zip
```

Two deliberate choices:

- Release builds are **ad-hoc signed**, not signed with "Vectorscope Dev". That
  cert only exists on one machine, so it does nothing for downloaders and can't
  be notarised. Ad-hoc is stable for a given binary, so users keep their grant
  until they update.
- The release bundle is staged in `build/release/`, *not* `build/`, so it can't
  clobber the dev bundle's signature.

Releases are **not notarised** (that needs a paid Apple Developer account), so
downloads arrive quarantined and macOS refuses to open them until the user runs
`xattr -dr com.apple.quarantine` or approves the app under System Settings ▸
Privacy & Security. A quarantined app is also subject to App Translocation —
macOS runs it from a randomised read-only path, which makes Screen Recording
grants fail to stick until the quarantine flag is cleared.

## Frame pipeline

```
ScreenCaptureKit  →  CVPixelBuffer (IOSurface)  →  MTLTexture (zero-copy)
   (region via                                          │
    sourceRect)                                          ▼
                       Metal compute: per-pixel RGB→Y'CbCr,
                       atomic accumulate into a 256×256 (Cb,Cr) histogram
                       plus a per-column waveform histogram
                                                          │
                                                          ▼
                       Fragment shaders: colourise density  +  graticule passes
                                                          │
                                                          ▼
                       MTKView in a floating, always-on-top window
```

Three invariants hold this together; each one encodes a bug that was
specifically fixed:

1. **Frames are consumed in the capture callback, not in `draw()`.**
   ScreenCaptureKit's IOSurface is only valid during the callback — its pool
   recycles the surface afterwards. `renderer.process(pixelBuffer:)` builds the
   histograms on the capture queue; `draw()` only renders from a finished,
   double-buffered histogram, which also decouples display rate from capture
   rate. Reading the pixel buffer in `draw()` means plotting a recycled surface.
2. **Keep the `CVMetalTexture` wrapper alive until the GPU finishes.** Releasing
   it early can invalidate the `MTLTexture` it vends.
3. **Exclude our own windows from capture.** The scope floats above the captured
   display, so the `SCContentFilter` excludes our own PID — otherwise the live
   trace is recaptured and feeds back into itself.

## Metal notes

- **Uniform structs must match byte-for-byte** between the Swift `private
  struct` in `VectorscopeRenderer` and the corresponding shader struct
  (`ScopeParams`, `TraceParams`, `WaveParams`, `WaveDrawParams`). Change one,
  change both, or you get silent garbage.
- **Two histograms, one compute step.** Each frame fills the vectorscope
  histogram (`bins×bins` Cb/Cr counts) and the waveform histogram
  (`waveBins×valueBins×4`, per-column value counts for R/G/B/luma) in the same
  compute encoder, published together by flipping `frontIndex`.
- **One MTKView, two viewports.** The vectorscope renders into a square top
  viewport and the waveform into a wide bottom one, each with a matching
  **scissor rect** — required, or the full-screen triangle rasterises into the
  other panel.
- **When adding or renaming a shader entry point**, update the `expected` list
  in `main.swift` so `--check-shaders` validates it.

## Colorimetry

`Model/Colorimetry.swift` converts RGB→Y'CbCr on the **gamma-encoded** screen
values, with no linearisation — that's what a broadcast scope does, and the
capture texture is `.bgra8Unorm`, not `_srgb`. Rec.709 (default) and Rec.601
differ only in their `kr`/`kb` luma weights. `displayScale` (2.0) maps Cb/Cr
into the scope's [-1, 1] space so 75% bars land on the target boxes. The
graticule's target boxes and skin-tone line are derived from the same transform,
so they stay consistent with the trace.

## Code layout

| File | Responsibility |
|---|---|
| `Capture/CaptureManager.swift` | ScreenCaptureKit stream → `CVPixelBuffer`s |
| `Metal/ShaderSource.swift` | Metal kernels/shaders (runtime-compiled) |
| `Metal/VectorscopeRenderer.swift` | Histogram compute + trace/graticule render |
| `Model/Colorimetry.swift` | Rec.601/709 math, target positions |
| `UI/RegionPicker.swift` | Drag-select overlay |
| `UI/AppDelegate.swift` | Window, menu, wiring |
