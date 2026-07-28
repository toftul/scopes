# Vectorscope

A lightweight, real-time colour vectorscope for macOS. Pick a screen region and
watch its chroma distribution live — a native, GPU-driven alternative to
tools like [vectorscope.co](https://vectorscope.co).

Native Swift + **ScreenCaptureKit** (capture) + **Metal** (analysis & drawing).
Everything runs on the GPU each frame, so it stays smooth and low-power.

## Install

Grab the latest `Vectorscope-*-universal.zip` from
[**Releases**](https://github.com/toftul/scopes/releases/latest) — universal
(Apple Silicon + Intel), macOS 14 or later. Unzip, drag **Vectorscope.app** to
`/Applications`, then:

```bash
xattr -dr com.apple.quarantine /Applications/Vectorscope.app
```

That step is needed because the app is signed but **not notarised** (that needs a
paid Apple Developer account) — without it macOS refuses to open a downloaded
build. Equivalently: try to open it, then allow it under System Settings ▸
Privacy & Security ▸ *Open Anyway*.

First launch prompts for **Screen Recording** permission — grant it and relaunch.
If you'd rather not trust a binary, [build from source](#build--run); it takes
about 15 seconds and needs no Xcode.

## Pipeline

```
ScreenCaptureKit  →  CVPixelBuffer (IOSurface)  →  MTLTexture (zero-copy)
   (region via                                          │
    sourceRect)                                          ▼
                       Metal compute: per-pixel RGB→Y'CbCr,
                       atomic accumulate into a 256×256 (Cb,Cr) histogram
                                                          │
                                                          ▼
                       Fragment shader: colourise density  +  graticule pass
                                                          │
                                                          ▼
                       MTKView in a floating, always-on-top window
```

## Build & run

No Xcode required — the Metal shaders are compiled **at runtime**, so the
Command Line Tools are enough.

```bash
# Build a proper .app bundle (so Screen Recording permission attaches to it)
./build-app.sh
open build/Vectorscope.app
```

First launch prompts for **Screen Recording** permission
(System Settings ▸ Privacy & Security ▸ Screen Recording). Grant it and relaunch.

To produce a distributable universal build + zip (what CI ships on a tag):

```bash
./scripts/release.sh 0.1.0      # → build/Vectorscope-0.1.0-universal.zip
```

For a quick dev loop without bundling:

```bash
swift run                       # runs, but permission attaches to your terminal
swift run Vectorscope --check-shaders   # just verify shaders compile, then exit
```

## Controls (menu ▸ Scope, plus shortcuts)

| Action | Shortcut |
|---|---|
| Pick region to scope | ⌘R |
| Scope whole display | ⌘D |
| Toggle Rec.709 / Rec.601 | ⌘C |
| Cycle vectorscope colorize / mono / heatmap | ⌘M |
| Cycle waveform: luma / parade / RGB overlay | ⌘W |
| Brighter / dimmer trace | ⌘= / ⌘- |
| More saturated / more pale | ⌘] / ⌘[ |

## Layout of the code

| File | Responsibility |
|---|---|
| `Capture/CaptureManager.swift` | ScreenCaptureKit stream → `CVPixelBuffer`s |
| `Metal/ShaderSource.swift` | Metal kernels/shaders (runtime-compiled) |
| `Metal/VectorscopeRenderer.swift` | Histogram compute + trace/graticule render |
| `Model/Colorimetry.swift` | Rec.601/709 math, target positions |
| `UI/RegionPicker.swift` | Drag-select overlay |
| `UI/AppDelegate.swift` | Window, menu, wiring |

## Status & roadmap

Working now: whole-display + region capture (own windows excluded to avoid a
capture feedback loop), vectorscope with graticule (rings, crosshair, 75%
target boxes, skin-tone line) in colorize/mono/heatmap, plus a bottom panel with
luma waveform / RGB parade / RGB overlay. Rec.709/601, adjustable gain and
saturation. What's next:

- [ ] Region resize handles / live re-pick
- [ ] "Follow this window" capture mode
- [ ] RGB-tinted vectorscope trace (colour points by their source pixel)
- [ ] Menu-bar presence (`LSUIElement`) + preferences
- [x] Waveform / RGB parade
- [ ] Precompiled `.metallib` once Xcode is installed
- [ ] Notarize releases (needs a paid Apple Developer account — until then,
      downloads need the `xattr` step above)
- [x] Tagged universal builds published to Releases by CI

## License

[MIT](LICENSE) © 2026 Ivan Toftul
