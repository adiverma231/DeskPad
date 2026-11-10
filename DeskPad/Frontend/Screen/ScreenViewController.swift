import Cocoa
import QuartzCore

final class ScreenViewController: NSViewController, NSWindowDelegate {
    var onClose: (() -> Void)?

    var displayID: CGDirectDisplayID? { display?.displayID }

    override func loadView() {
        let preview = PreviewView()
        preview.onMouseDown = { [weak self] event in self?.controlPreview(with: event) }
        view = preview
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.isOpaque = true
        view.wantsLayer = true
    }

    private var display: CGVirtualDisplay?
    private var displaySerialNumber: UInt32 = 0x0001
    private var displayName = "DeskPad Display"
    private var stream: DisplayStream?
    private var mouseTimer: Timer?
    private var displayFrame = CGRect.zero
    private var displayScaleFactor: CGFloat = 1
    private var configuration: DisplayConfiguration?
    private var configurationRetry: DispatchWorkItem?
    private var previewControl: PreviewControl?
    private var isWindowHighlighted: Bool?
    private var isUpdatingScreenConfiguration = false

    convenience init(serialNumber: UInt32, name: String = "DeskPad Display") {
        self.init(nibName: nil, bundle: nil)
        displaySerialNumber = serialNumber
        displayName = name
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = displayName
        descriptor.maxPixelsWide = 5120
        descriptor.maxPixelsHigh = 2160
        descriptor.sizeInMillimeters = CGSize(width: 1600, height: 1000)
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x3456
        descriptor.serialNum = displaySerialNumber

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return }
        self.display = display

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        let resolutions: [(width: Int, height: Int)] = [
            // 32:9
            (5120, 1440),
            // 21:9 (239:100, 12:5)
            (5120, 2160),
            (3840, 1600),
            (3440, 1440),
            // 16:9
            (3840, 2160),
            (2560, 1440),
            (1920, 1080),
            (1600, 900),
            (1366, 768),
            (1280, 720),
            // 16:10
            (2560, 1600),
            (1920, 1200),
            (1680, 1050),
            (1440, 900),
            (1280, 800),
        ]
        // System Settings only offers refresh rates advertised as modes of the same resolution.
        let refreshRates: [CGFloat] = [60, 90, 120, 144]
        settings.modes = resolutions.flatMap { resolution in
            refreshRates.map { refreshRate in
                CGVirtualDisplayMode(width: UInt(resolution.width), height: UInt(resolution.height), refreshRate: refreshRate)
            }
        }
        guard display.apply(settings) else {
            self.display = nil
            return
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateScreenConfiguration),
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApplication.shared
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(releasePreviewControl),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(releasePreviewControl),
            name: NSWorkspace.willSleepNotification, object: nil
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateScreenConfiguration()

        if mouseTimer == nil {
            // Highlighting stays lightweight even when interactive control is not enabled.
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.updateMouseLocation()
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            mouseTimer = timer
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateStream()
    }

    @objc private func updateScreenConfiguration() {
        releasePreviewControl()
        configurationRetry?.cancel()
        applyScreenConfiguration()
        scheduleConfigurationRetry()
    }

    private func scheduleConfigurationRetry(attempt: Int = 0) {
        // AirPlay can announce a mirror change before its capture surface is ready.
        // Always restart once after settling, then retry only a blank/missing stream.
        let retry = DispatchWorkItem { [weak self] in
            guard let self = self, self.display != nil else { return }
            self.configurationRetry = nil
            guard attempt == 0 || self.view.layer?.contents == nil else { return }
            self.applyScreenConfiguration()
            if attempt < 3, self.view.layer?.contents == nil {
                self.scheduleConfigurationRetry(attempt: attempt + 1)
            }
        }
        configurationRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * pow(2, Double(attempt)), execute: retry)
    }

    private func applyScreenConfiguration() {
        releasePreviewControl()
        guard let window = view.window, let display = display else { return }
        // Mirrored followers disappear from NSScreen.screens. Capture their mirror source,
        // which may be the AirPlay display rather than the original virtual display.
        guard let configuration = DisplayConfiguration(displayID: display.displayID) else {
            self.configuration = nil
            displayFrame = .zero
            stream = nil
            updateMouseLocation()
            return
        }

        let resolutionChanged = displayFrame.size != configuration.bounds.size || displayScaleFactor != configuration.scaleFactor
        // Recreate even at identical dimensions: the compositor can replace the surface
        // during a mirror change without changing the display ID, size, or refresh rate.
        stream = nil
        self.configuration = configuration
        displayFrame = CGRect(x: configuration.bounds.minX,
                              y: CGDisplayBounds(CGMainDisplayID()).height - configuration.bounds.maxY,
                              width: configuration.bounds.width, height: configuration.bounds.height)
        displayScaleFactor = configuration.scaleFactor
        if resolutionChanged {
            isUpdatingScreenConfiguration = true
            window.contentAspectRatio = displayFrame.size
            window.setContentSize(displayFrame.size)
            window.center()
            isUpdatingScreenConfiguration = false
        }
        updateStream()
        updateMouseLocation()
    }

    private func updateStream() {
        guard
            !isUpdatingScreenConfiguration,
            let configuration = configuration,
            let window = view.window,
            !window.inLiveResize,
            let layer = view.layer,
            let size = DisplayGeometry.captureSize(
                resolution: displayFrame.size,
                scaleFactor: displayScaleFactor,
                previewSize: view.convertToBacking(view.bounds).size
            ),
            stream?.size != size || stream?.displayID != configuration.captureDisplayID
        else { return }

        // Reuse the current stream during live resize, then allocate only the pixels we can show.
        stream = nil
        stream = DisplayStream(displayID: configuration.captureDisplayID, size: size, layer: layer)
    }

    private func updateMouseLocation() {
        let isWithinScreen = NSMouseInRect(NSEvent.mouseLocation, displayFrame, false)
        guard isWithinScreen != isWindowHighlighted else { return }
        isWindowHighlighted = isWithinScreen
        view.window?.backgroundColor = NSColor(named: isWithinScreen ? "TitleBarActive" : "TitleBarInactive")
        if isWithinScreen {
            view.window?.orderFrontRegardless()
        }
    }

    func windowDidEndLiveResize(_: Notification) {
        updateStream()
    }

    func windowDidChangeBackingProperties(_: Notification) {
        updateStream()
    }

    func windowWillResize(_ window: NSWindow, to frameSize: NSSize) -> NSSize {
        let snappingOffset: CGFloat = 30
        let contentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let screenResolution = displayFrame.size
        guard
            screenResolution != .zero,
            abs(contentSize.width - screenResolution.width) < snappingOffset
        else {
            return frameSize
        }
        return window.frameRect(forContentRect: NSRect(origin: .zero, size: screenResolution)).size
    }

    private func controlPreview(with event: NSEvent) {
        guard let configuration = configuration else { return }
        releasePreviewControl()
        if let screen = view.window?.screen,
           DisplayConfiguration.captureDisplayID(for: screen.displayID) == configuration.captureDisplayID {
            let alert = NSAlert()
            alert.messageText = "Move the preview to a separate display"
            alert.informativeText = "The DeskPad window must be on a display outside the mirror group, such as your built-in display. Otherwise it would capture and control itself."
            alert.runModal()
            return
        }
        let control = PreviewControl(view: view, displayBounds: configuration.bounds,
                                     point: view.convert(event.locationInWindow, from: nil))
        switch control.start(with: event) {
        case .started:
            previewControl = control
        case .accessibilityRequired:
            let alert = NSAlert()
            alert.messageText = "Allow DeskPad to control the preview"
            alert.informativeText = "Enable DeskPad in System Settings → Privacy & Security → Accessibility, then click the preview again. While controlling, press Esc or move past the preview’s edge to return to your built-in display."
            alert.runModal()
        case .unavailable:
            let alert = NSAlert()
            alert.messageText = "Could not start preview control"
            alert.informativeText = "macOS could not enable input forwarding. Check DeskPad’s Accessibility permission, quit and reopen DeskPad, then try again."
            alert.runModal()
        }
    }

    @objc private func releasePreviewControl() {
        previewControl?.stop()
        previewControl = nil
    }

    func windowWillClose(_: Notification) {
        stop()
        onClose?()
    }

    func stop() {
        releasePreviewControl()
        configurationRetry?.cancel()
        configurationRetry = nil
        mouseTimer?.invalidate()
        mouseTimer = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        configuration = nil
        displayFrame = .zero
        stream = nil
        display = nil
    }

    deinit {
        previewControl?.stop()
        configurationRetry?.cancel()
        mouseTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
