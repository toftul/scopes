# Vectorscope

A lightweight, real-time colour vectorscope for macOS. Pick a screen region and
watch its chroma distribution live — a native, GPU-driven alternative to
tools like [vectorscope.co](https://vectorscope.co).

Native Swift + **ScreenCaptureKit** (capture) + **Metal** (analysis & drawing).
Everything runs on the GPU each frame, so it stays smooth and low-power.

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
| Toggle trace / heatmap | ⌘M |
| Brighter / dimmer trace | ⌘= / ⌘- |

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

Working now: whole-display + region capture, 256×256 histogram trace, graticule
(rings, crosshair, 75% target boxes, skin-tone line), Rec.709/601, mono/heatmap,
gain. See the roadmap discussion for what's next:

- [ ] Region resize handles / live re-pick
- [ ] "Follow this window" capture mode
- [ ] RGB-tinted trace (colour points by their source pixel)
- [ ] Menu-bar presence (`LSUIElement`) + preferences
- [ ] Waveform / RGB parade (logic exists in `legacy/`)
- [ ] Precompiled `.metallib` once Xcode is installed
- [ ] Sign + notarize for distribution

The original Python/ffmpeg prototypes are preserved in `legacy/`.
