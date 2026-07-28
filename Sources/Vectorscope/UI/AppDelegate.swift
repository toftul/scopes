import AppKit
import MetalKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var mtkView: MTKView!
    private var renderer: VectorscopeRenderer!
    private let capture = CaptureManager()
    private let picker = RegionPicker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = VectorscopeRenderer(device: device) else {
            fatalError("Metal is unavailable on this machine.")
        }
        self.renderer = renderer

        mtkView = MTKView(frame: NSRect(x: 0, y: 0, width: 480, height: 480), device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.delegate = renderer
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.framebufferOnly = true

        window = NSWindow(contentRect: mtkView.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Vectorscope"
        window.contentView = mtkView
        window.contentAspectRatio = NSSize(width: 1, height: 1)  // keep it square
        window.level = .floating                                 // always-on-top
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        window.makeKeyAndOrderFront(nil)

        buildMenu()

        // Route captured frames into the renderer, and surface errors.
        capture.onFrame = { [weak renderer] pb in renderer?.process(pixelBuffer: pb) }
        capture.onError = { [weak self] error in self?.presentCaptureError(error) }

        NSApp.activate(ignoringOtherApps: true)
        startCapture(region: nil)
    }

    // MARK: - Capture control

    private func startCapture(region: CGRect?) {
        Task { @MainActor in
            do {
                try await capture.start(region: region)
            } catch {
                presentCaptureError(error)
            }
        }
    }

    private func presentCaptureError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Screen capture unavailable"
        alert.informativeText = """
        \(error.localizedDescription)

        If this is a permissions issue, grant Screen Recording to this app in
        System Settings ▸ Privacy & Security ▸ Screen Recording, then relaunch.
        """
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Menu & actions

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Vectorscope", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Vectorscope",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let scopeItem = NSMenuItem()
        let scopeMenu = NSMenu(title: "Scope")
        scopeMenu.addItem(withTitle: "Pick Region…",
                          action: #selector(pickRegion), keyEquivalent: "r").target = self
        scopeMenu.addItem(withTitle: "Scope Whole Display",
                          action: #selector(scopeFullDisplay), keyEquivalent: "d").target = self
        scopeMenu.addItem(.separator())
        scopeMenu.addItem(withTitle: "Toggle Rec.709 / Rec.601",
                          action: #selector(toggleColorSpace), keyEquivalent: "c").target = self
        scopeMenu.addItem(withTitle: "Cycle Colorize / Mono / Heatmap",
                          action: #selector(toggleMode), keyEquivalent: "m").target = self
        scopeMenu.addItem(withTitle: "Brighter Trace",
                          action: #selector(brighter), keyEquivalent: "=").target = self
        scopeMenu.addItem(withTitle: "Dimmer Trace",
                          action: #selector(dimmer), keyEquivalent: "-").target = self
        scopeMenu.addItem(withTitle: "More Saturated",
                          action: #selector(moreSaturated), keyEquivalent: "]").target = self
        scopeMenu.addItem(withTitle: "More Pale",
                          action: #selector(morePale), keyEquivalent: "[").target = self
        scopeItem.submenu = scopeMenu
        mainMenu.addItem(scopeItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func pickRegion() {
        picker.present { [weak self] rect in
            guard let self, let rect else { return }
            self.startCapture(region: rect)
        }
    }

    @objc private func scopeFullDisplay() { startCapture(region: nil) }

    @objc private func toggleColorSpace() {
        renderer.colorSpace = (renderer.colorSpace == .rec709) ? .rec601 : .rec709
        window.title = "Vectorscope — \(renderer.colorSpace.label)"
    }

    @objc private func toggleMode() {
        renderer.mode = (renderer.mode + 1) % 3   // colorize → mono → heatmap
    }

    @objc private func brighter() { renderer.gain = min(renderer.gain * 1.5, 100) }
    @objc private func dimmer()   { renderer.gain = max(renderer.gain / 1.5, 0.001) }
    @objc private func moreSaturated() { renderer.saturation = min(renderer.saturation + 0.1, 1.0) }
    @objc private func morePale()      { renderer.saturation = max(renderer.saturation - 0.1, 0.0) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
