import Cocoa
import QuartzCore

final class ScreenViewController: NSViewController, NSWindowDelegate {
    var onClose: (() -> Void)?

    var displayID: CGDirectDisplayID? { display?.displayID }

    override func loadView() {
        view = NSView()
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.isOpaque = true
        view.wantsLayer = true
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(didClickOnScreen)))
    }

    private var display: CGVirtualDisplay?
    private var displaySerialNumber: UInt32 = 0x0001
    private var displayName = "DeskPad Display"
    private var stream: DisplayStream?
    private var mouseTimer: Timer?
    private var displayFrame = CGRect.zero
    private var displayScaleFactor: CGFloat = 1
    private var displayRefreshRate: Double = 0
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
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateScreenConfiguration()

        if mouseTimer == nil {
            // Polling avoids a global event tap and its permissions/high-frequency mouse events.
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
        guard let window = view.window, let display = display else { return }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else {
            displayFrame = .zero
            stream = nil
            updateMouseLocation()
            return
        }

        let resolutionChanged = displayFrame.size != screen.frame.size || displayScaleFactor != screen.backingScaleFactor
        let refreshRate = CGDisplayCopyDisplayMode(display.displayID)?.refreshRate ?? 60
        if resolutionChanged || refreshRate != displayRefreshRate {
            stream = nil
        }
        displayFrame = screen.frame
        displayScaleFactor = screen.backingScaleFactor
        displayRefreshRate = refreshRate
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
            let display = display,
            let window = view.window,
            !window.inLiveResize,
            let layer = view.layer,
            let size = DisplayGeometry.captureSize(
                resolution: displayFrame.size,
                scaleFactor: displayScaleFactor,
                previewSize: view.convertToBacking(view.bounds).size
            ),
            stream?.size != size
        else { return }

        // Reuse the current stream during live resize, then allocate only the pixels we can show.
        stream = nil
        stream = DisplayStream(displayID: display.displayID, size: size, layer: layer)
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

    @objc private func didClickOnScreen(_ gestureRecognizer: NSGestureRecognizer) {
        guard let display = display, let point = DisplayGeometry.displayPoint(
            for: gestureRecognizer.location(in: view),
            in: view.bounds,
            resolution: displayFrame.size
        ) else { return }
        CGDisplayMoveCursorToPoint(display.displayID, point)
        updateMouseLocation()
    }

    func windowWillClose(_: Notification) {
        stop()
        onClose?()
    }

    func stop() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        NotificationCenter.default.removeObserver(self)
        displayFrame = .zero
        stream = nil
        display = nil
    }

    deinit {
        mouseTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}
