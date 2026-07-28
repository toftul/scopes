import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

/// Wraps a ScreenCaptureKit stream. Captures either a whole display or a picked
/// region (via `sourceRect`) and delivers BGRA `CVPixelBuffer`s to `onFrame`.
final class CaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {

    /// Called on `sampleQueue` for every complete frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on the main queue if the stream stops unexpectedly / errors.
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private var region: CGRect?          // global, bottom-left origin (AppKit)
    private let sampleQueue = DispatchQueue(label: "co.vectorscope.frames", qos: .userInteractive)

    enum CaptureError: Error { case noDisplay }

    /// Start (or restart) capture. Pass `nil` to scope the whole main display.
    func start(region: CGRect?) async throws {
        await stopIfRunning()
        self.region = region

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        // Exclude our OWN windows from the capture. The scope window floats on
        // the same display we're capturing, so without this its live trace gets
        // recaptured and feeds back into itself — a shimmering feedback loop
        // that looks like random noise even on an otherwise-static screen.
        let myPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == myPID }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: ownApps,
                                     exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 5
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // cap at 60 fps

        if let region {
            // AppKit rect (bottom-left) -> SCK sourceRect (top-left, in points).
            let screenH = NSScreen.main?.frame.height ?? CGFloat(display.height)
            config.sourceRect = CGRect(x: region.minX,
                                       y: screenH - region.maxY,
                                       width: region.width,
                                       height: region.height)
            config.width = max(2, Int(region.width))
            config.height = max(2, Int(region.height))
        } else {
            config.width = display.width
            config.height = display.height
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stopIfRunning() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Only forward frames the compositor marked complete (skip idle/blank).
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else { return }

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pb)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }
}
