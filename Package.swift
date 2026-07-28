// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vectorscope",
    platforms: [
        // ScreenCaptureKit's `sourceRect` region cropping needs macOS 14+.
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Vectorscope",
            path: "Sources/Vectorscope"
            // System frameworks (AppKit, Metal, MetalKit, ScreenCaptureKit,
            // CoreVideo, CoreMedia) are auto-linked on `import`.
        )
    ]
)
