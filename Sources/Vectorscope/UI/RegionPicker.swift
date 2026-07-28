import AppKit

/// A translucent full-screen overlay you drag a rectangle on. Reports the
/// selected rect in global AppKit coordinates (bottom-left origin), or `nil`
/// if cancelled with Esc.
final class RegionPicker {

    private var window: NSWindow?
    private var completion: ((CGRect?) -> Void)?

    func present(completion: @escaping (CGRect?) -> Void) {
        guard let screen = NSScreen.main else { completion(nil); return }
        self.completion = completion

        let window = NSWindow(contentRect: screen.frame,
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.20)
        window.ignoresMouseEvents = false
        window.hasShadow = false

        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] rect in self?.finish(rect, screen: screen) }
        window.contentView = view

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func finish(_ rectInView: CGRect?, screen: NSScreen) {
        window?.orderOut(nil)
        window = nil
        let done = completion
        completion = nil
        guard let r = rectInView else { done?(nil); return }
        // View is anchored at the screen origin, so add the screen offset to
        // get a global rect.
        done?(CGRect(x: screen.frame.minX + r.minX,
                     y: screen.frame.minY + r.minY,
                     width: r.width, height: r.height))
    }
}

/// Draws the dimmed backdrop and the live selection rectangle.
private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil; current = nil }
        guard let rect = selectionRect(), rect.width >= 4, rect.height >= 4 else {
            onFinish?(nil); return
        }
        onFinish?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) }   // Esc
        else { super.keyDown(with: event) }
    }

    private func selectionRect() -> CGRect? {
        guard let a = start, let b = current else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect = selectionRect() else { return }
        // Punch a clear "hole" so you can see what you're selecting.
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSColor.systemGreen.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.stroke()

        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ]
        label.draw(at: NSPoint(x: rect.minX, y: rect.maxY + 4), withAttributes: attrs)
    }
}
