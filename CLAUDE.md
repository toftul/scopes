# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A native macOS realtime colour vectorscope + waveform/parade. Pick a screen
region (or whole display) and see a live, GPU-driven scope. Swift + AppKit +
ScreenCaptureKit (capture) + Metal (analysis & drawing). No Xcode project — it's
a plain SwiftPM executable wrapped into a `.app`.

## Commands

```bash
swift build                              # debug build
swift run Vectorscope                    # run unbundled (permission attaches to the TERMINAL, not the app)
swift run Vectorscope --check-shaders    # compile the runtime Metal shaders and verify every entry point; exits 0/1
./build-app.sh [debug|release]           # build + wrap into build/Vectorscope.app (signed) — the normal way to run
./scripts/make-signing-cert.sh           # one-time: create the stable signing identity (see below)
./scripts/release.sh [version]           # universal (arm64+x86_64) .app + ditto zip for a GitHub release
```

There is no test target. After any shader change, the fastest correctness gate
is `swift run Vectorscope --check-shaders`; to see it live you must run the
**bundled** app (`./build-app.sh` then `open build/Vectorscope.app`) so Screen
Recording permission is attributed to the app rather than your terminal.

## Signing & Screen Recording permission (important, non-obvious)

Screen Recording (TCC) permission is bound to the app's **code signature**.
Ad-hoc signatures change every rebuild, so the grant is lost each time. The repo
therefore uses a stable self-signed identity **"Vectorscope Dev"**:

- Create it once with `./scripts/make-signing-cert.sh`. The first `codesign`
  after import pops a keychain dialog → click **Always Allow** once, then silent.
- `build-app.sh` auto-signs with it (falling back to ad-hoc, which breaks
  permission persistence). It looks it up via `find-identity -p codesigning`
  **without `-v`** because the cert is untrusted-but-usable.
- If the signature identity ever changes, reset with
  `tccutil reset ScreenCapture co.vectorscope.picker` and re-grant.

**Release artifacts are ad-hoc signed on purpose.** `scripts/release.sh` does not
use "Vectorscope Dev" — that cert is local-only, so it helps no downloader and
can't be notarised. Ad-hoc is still stable per-binary, so users keep their TCC
grant until they update. Pushing a `v*` tag runs `.github/workflows/release.yml`,
which calls the same script and publishes the zip.

## Architecture — the frame pipeline

Data flows: `CaptureManager` (ScreenCaptureKit) → `CVPixelBuffer` →
`VectorscopeRenderer` (Metal compute + render) → `MTKView`. Wiring lives in
`UI/AppDelegate.swift`.

Three invariants drive the design — violating any of them reintroduces bugs that
were specifically fixed:

1. **Frames are consumed in the capture callback, not in `draw()`.**
   ScreenCaptureKit's IOSurface is only valid during the callback; its pool
   recycles the surface afterward. `renderer.process(pixelBuffer:)` runs on the
   capture queue and builds the histograms there. `draw()` only renders from a
   finished, **double-buffered** histogram (`histograms`/`waveHistograms` indexed
   by `frontIndex`), decoupling display rate from capture rate. Reading the
   pixel buffer in `draw()` at 60fps = plotting a recycled surface = "random
   noise" on a static screen.

2. **Keep the `CVMetalTexture` wrapper alive until the GPU finishes.** `process()`
   holds `cvTex` across `commit()` + `waitUntilCompleted()`; releasing it early
   can invalidate the `MTLTexture` it vends.

3. **Exclude our own windows from capture.** The scope window floats on the
   captured display, so `CaptureManager` builds the `SCContentFilter` with
   `excludingApplications:` = our own PID. Otherwise the live trace is recaptured
   and feeds back into itself (shimmering noise).

## Architecture — Metal specifics

- **Shaders are compiled at runtime** from the `ShaderSource.metal` string
  (`Metal/ShaderSource.swift`) via `device.makeLibrary(source:)`. This is why the
  project builds with just the Command Line Tools (no offline `metal` compiler).
  There are no `.metal` files.
- **Uniform structs must match byte-for-byte** between the Swift `private struct`
  in `VectorscopeRenderer` and the corresponding `struct` in the shader string
  (`ScopeParams`, `TraceParams`, `WaveParams`, `WaveDrawParams`). Change one, change
  both, or you get silent garbage.
- **Two histograms, one compute step.** Per frame, `process()` clears and fills:
  the vectorscope histogram (`bins×bins`, a 2D Cb/Cr count) and the waveform
  histogram (`waveBins×valueBins×4`, per source-column value counts for R/G/B/luma).
  Both are built in the same `MTLComputeCommandEncoder` and published together via
  `frontIndex`.
- **One MTKView, two viewports.** `draw()` renders the vectorscope into a square
  top viewport and the waveform into a wide bottom viewport of the same drawable,
  each with a matching **scissor rect** (required — the full-screen triangle would
  otherwise rasterise into the other panel). Trace/waveform fragments read their
  histogram buffer directly and colourise it (log-scaled, bilinear-sampled);
  graticules are line-primitive passes.
- **When adding/renaming a shader entry point**, also update the `expected` list
  in `main.swift` so `--check-shaders` validates it.

## Colorimetry

`Model/Colorimetry.swift` converts RGB→Y'CbCr on the **gamma-encoded** screen
values (no linearisation — that's what a broadcast scope does; the texture is
`.bgra8Unorm`, not `_srgb`). Rec.709 (default) and Rec.601 differ only in the
`kr`/`kb` luma weights. `displayScale` (2.0) maps Cb/Cr into the scope's [-1,1]
space so 75% bars land on the target boxes. Vectorscope target-box and skin-line
positions are derived from this same transform, so they stay consistent with the
trace.
