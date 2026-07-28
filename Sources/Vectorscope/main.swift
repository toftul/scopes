import AppKit
import Metal

// `--check-shaders`: compile the Metal source and verify every entry point
// exists, then exit. Lets us validate the runtime-compiled shaders in CI /
// headless without opening the GUI or needing Screen Recording permission.
if CommandLine.arguments.contains("--check-shaders") {
    guard let device = MTLCreateSystemDefaultDevice() else {
        FileHandle.standardError.write(Data("no Metal device\n".utf8)); exit(2)
    }
    do {
        let lib = try device.makeLibrary(source: ShaderSource.metal, options: nil)
        let expected = ["accumulateHistogram", "traceVertex", "traceFragment",
                        "gratVertex", "gratFragment"]
        let missing = expected.filter { lib.makeFunction(name: $0) == nil }
        if missing.isEmpty {
            print("shader OK — all \(expected.count) entry points compiled")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("missing functions: \(missing)\n".utf8)); exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data("shader compile error: \(error)\n".utf8)); exit(1)
    }
}

// Entry point. A plain SwiftPM executable that boots an AppKit app so it runs
// with just the Command Line Tools (no Xcode project required).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
