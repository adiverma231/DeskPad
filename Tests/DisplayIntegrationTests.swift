import Cocoa
import IOSurface

@main
enum DisplayIntegrationTests {
    struct Failure: Error {
        let message: String
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func pump(for interval: TimeInterval = 0.5) {
        let deadline = Date(timeIntervalSinceNow: interval)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
        }
    }

    static func frame(in controller: ScreenViewController) throws -> IOSurfaceRef {
        let deadline = Date(timeIntervalSinceNow: 3)
        while controller.view.layer?.contents == nil, Date() < deadline {
            pump(for: 0.05)
        }
        guard let surface = controller.view.layer?.contents else {
            throw Failure(message: "The preview did not receive a captured frame (display \(controller.displayID ?? 0))")
        }
        return surface as! IOSurfaceRef
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
            do {
                try run()
                exit(0)
            } catch {
                print("Integration check failed: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    static func run() throws {
        guard CGPreflightScreenCaptureAccess() else {
            print("Integration checks need Screen Recording access for the test executable")
            exit(2)
        }
        let existingDisplays = Set(NSScreen.screens.map(\.displayID))
        let originalMouseLocation = CGEvent(source: nil)?.location
        defer {
            if let location = originalMouseLocation {
                CGWarpMouseCursorPosition(location)
            }
        }

        // A unique serial keeps checks independent of an already-running DeskPad instance.
        let controller = ScreenViewController(serialNumber: UInt32(ProcessInfo.processInfo.processIdentifier))
        let window = NSWindow(contentViewController: controller)
        window.delegate = controller
        window.styleMask.insert(.resizable)
        window.contentMinSize = CGSize(width: 400, height: 300)
        window.contentMaxSize = CGSize(width: 5120, height: 2160)
        window.makeKeyAndOrderFront(nil)
        defer {
            controller.stop()
            window.close()
            pump()
        }
        pump(for: 2)
        guard let display = NSScreen.screens.first(where: { !existingDisplays.contains($0.displayID) }) else {
            throw Failure(message: "The virtual display was not created")
        }
        let displayID = display.displayID
        let modes = CGDisplayCopyAllDisplayModes(displayID, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as! [CGDisplayMode]
        try check(modes.contains { $0.pixelWidth == 5120 && $0.pixelHeight == 1440 }, "Missing ultrawide mode")
        try check(modes.contains { $0.pixelWidth == 3840 && $0.pixelHeight == 2160 }, "Missing 4K mode")
        try check(modes.contains { $0.pixelWidth == 1280 && $0.pixelHeight == 800 }, "Missing 16:10 mode")
        let availableRates = Set(modes.filter { $0.width == 1280 && $0.height == 800 }.map(\.refreshRate))
        try check(availableRates.isSuperset(of: [60, 90, 120, 144]), "Missing selectable refresh rates")
        let marker = NSWindow(contentRect: CGRect(x: display.frame.minX + 50, y: display.frame.minY + 50, width: 300, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        marker.backgroundColor = .red
        marker.isReleasedWhenClosed = false
        marker.orderFrontRegardless()
        defer { marker.close() }
        pump()
        _ = try frame(in: controller)

        // The capture follows the preview's backing pixels, without changing the virtual monitor mode.
        let initialMode = CGDisplayCopyDisplayMode(displayID)!
        let largeSize = controller.view.bounds.size
        let smallSize = CGSize(width: largeSize.width / 2, height: largeSize.height / 2)
        window.setContentSize(smallSize)
        pump()
        let smallFrame = try frame(in: controller)
        let expectedSize = DisplayGeometry.captureSize(
            resolution: display.frame.size,
            scaleFactor: display.backingScaleFactor,
            previewSize: controller.view.convertToBacking(controller.view.bounds).size
        )!
        try check(IOSurfaceGetWidth(smallFrame) == Int(expectedSize.width), "Capture width does not match preview")
        try check(IOSurfaceGetHeight(smallFrame) == Int(expectedSize.height), "Capture height does not match preview")
        try check(CGDisplayCopyDisplayMode(displayID)!.ioDisplayModeID == initialMode.ioDisplayModeID, "Resizing changed the virtual display mode")
        print("Resized preview captures \(IOSurfaceGetWidth(smallFrame))×\(IOSurfaceGetHeight(smallFrame)) pixels")

        // Resizing repeatedly must retire old streams and release their last displayed surfaces.
        let oldUseCount = IOSurfaceGetUseCount(smallFrame)
        window.setContentSize(largeSize)
        pump()
        try check(IOSurfaceGetUseCount(smallFrame) < oldUseCount, "Old capture surface is still in use")
        for _ in 0 ..< 5 {
            window.setContentSize(smallSize)
            pump(for: 0.15)
            window.setContentSize(largeSize)
            pump(for: 0.15)
        }
        _ = try frame(in: controller)

        // Exercise a real macOS display-mode switch and its screen-parameter notification.
        let otherMode = modes.first { $0.width == 1280 && $0.height == 800 && $0.refreshRate == 60 }!
        try check(CGDisplaySetDisplayMode(displayID, otherMode, nil) == .success, "Mode switch failed")
        pump(for: 1)
        try check(window.contentAspectRatio == CGSize(width: 1280, height: 800), "Window did not follow the new display mode")
        _ = try frame(in: controller)

        // A refresh-only change must restart capture without resetting the preview's size or position.
        window.setContentSize(CGSize(width: 800, height: 500))
        pump()
        let previewFrame = window.frame
        for rate in [90.0, 120.0, 144.0, 60.0] {
            guard let mode = modes.first(where: {
                $0.width == otherMode.width && $0.height == otherMode.height
                    && $0.pixelWidth == otherMode.pixelWidth && $0.pixelHeight == otherMode.pixelHeight
                    && $0.refreshRate == rate
            }) else { throw Failure(message: "Missing \(rate) Hz mode at the current pixel density") }
            try check(CGDisplaySetDisplayMode(displayID, mode, nil) == .success, "Refresh rate switch failed")
            pump()
            try check(CGDisplayCopyDisplayMode(displayID)?.refreshRate == rate, "macOS did not select \(rate) Hz")
            try check(window.frame == previewFrame, "Refresh-only change moved or resized the preview")
            _ = try frame(in: controller)
        }
        print("Verified macOS mode switching at 60, 90, 120, and 144 Hz")

        // Cursor polling must still raise the window when entering the virtual display.
        CGDisplayMoveCursorToPoint(CGMainDisplayID(), CGPoint(x: 100, y: 100))
        pump()
        window.orderBack(nil)
        try check(CGDisplayMoveCursorToPoint(displayID, CGPoint(x: 100, y: 100)) == .success, "Cursor move failed")
        pump()
        let currentDisplay = NSScreen.screens.first { $0.displayID == displayID }!
        try check(NSMouseInRect(NSEvent.mouseLocation, currentDisplay.frame, false),
                  "Cursor did not reach virtual display (mouse \(NSEvent.mouseLocation), screen \(currentDisplay.frame), Quartz \(CGDisplayBounds(displayID)))")
        try check(NSApp.orderedWindows.first === window, "Cursor entry did not bring the preview to the front")

        let lastFrame = try frame(in: controller)
        let lastUseCount = IOSurfaceGetUseCount(lastFrame)
        controller.stop()
        pump()
        try check(controller.view.layer?.contents == nil, "Stopping must clear the preview")
        try check(IOSurfaceGetUseCount(lastFrame) < lastUseCount, "Stopping must release the last surface")
        try check(!NSScreen.screens.contains { $0.displayID == displayID }, "Stopping must disconnect the virtual display")
        window.close()
        print("Passed live capture, preview resizing, mode switching, cursor movement, and surface cleanup checks")
        try checkDisplayMenu()
    }

    static func checkDisplayMenu() throws {
        let existingDisplays = Set(NSScreen.screens.map(\.displayID))
        try check(!existingDisplays.contains {
            CGDisplayVendorNumber($0) == 0x3456 && [1, 2].contains(CGDisplaySerialNumber($0))
        }, "Quit the installed DeskPad before running menu lifecycle checks")

        func displayWindow(serial: UInt32) -> NSWindow? {
            NSApp.windows.first { window in
                guard let id = (window.contentViewController as? ScreenViewController)?.displayID else { return false }
                return CGDisplayVendorNumber(id) == 0x3456 && CGDisplaySerialNumber(id) == serial
            }
        }

        func stop(_ delegate: AppDelegate) {
            let windows = [displayWindow(serial: 1), displayWindow(serial: 2)].compactMap { $0 }
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            windows.forEach { $0.close() }
            pump()
        }

        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { stop(delegate) }
        pump()
        guard let first = displayWindow(serial: 1), let firstController = first.contentViewController as? ScreenViewController,
              let menuItem = NSApp.mainMenu?.items.last?.submenu?.items.last
        else { throw Failure(message: "First display or display menu missing") }
        let firstID = firstController.displayID!
        try check(displayWindow(serial: 2) == nil && menuItem.state == .off, "Second display must be off at launch")
        try check(NSApp.sendAction(menuItem.action!, to: menuItem.target, from: menuItem), "Second display menu action failed")
        pump()
        guard let second = displayWindow(serial: 2), let secondController = second.contentViewController as? ScreenViewController else {
            throw Failure(message: "Second display was not enabled")
        }
        let secondID = secondController.displayID!
        try check(firstID != secondID && menuItem.state == .on, "Displays must have distinct identities")
        // macOS remembers mirror groups for stable display identities across launches.
        // The independent-display checks need both displays explicitly extended.
        for id in [firstID, secondID] where CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay {
            try setMirror(id, source: kCGNullDirectDisplay)
        }
        pump(for: 1)
        try check(NSScreen.screens.first { $0.displayID == secondID }?.localizedName == "DeskPad Display 2",
                  "Second display name is ambiguous (ID \(secondID), active \(CGDisplayIsActive(secondID)), mirror \(CGDisplayMirrorsDisplay(secondID)), screens \(NSScreen.screens.map { "\($0.displayID): \($0.localizedName)" }))")
        _ = try frame(in: firstController)
        _ = try frame(in: secondController)

        // Independent refresh selection and cursor-driven fronting on both displays.
        let modes = CGDisplayCopyAllDisplayModes(secondID, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as! [CGDisplayMode]
        let fastMode = modes.first { $0.width == 1280 && $0.height == 800 && $0.refreshRate == 144 }!
        let firstMode = CGDisplayCopyDisplayMode(firstID)!
        try check(CGDisplaySetDisplayMode(secondID, fastMode, nil) == .success, "Second display could not select 144 Hz")
        pump()
        try check(CGDisplayCopyDisplayMode(firstID)?.ioDisplayModeID == firstMode.ioDisplayModeID, "Second display changed the first display's mode")
        try check(CGDisplayCopyDisplayMode(secondID)?.refreshRate == 144, "Second display did not select 144 Hz")
        for (id, window) in [(firstID, first), (secondID, second)] {
            CGDisplayMoveCursorToPoint(CGMainDisplayID(), CGPoint(x: 100, y: 100))
            pump()
            CGDisplayMoveCursorToPoint(id, CGPoint(x: 100, y: 100))
            pump()
            try check(NSApp.orderedWindows.first === window,
                      "Wrong preview raised for cursor entry (target \(id), mirror \(CGDisplayMirrorsDisplay(id)), mouse \(NSEvent.mouseLocation))")
        }

        try checkMirroring(follower: firstController, source: secondController)
        try checkMirroring(follower: secondController, source: firstController)

        // Losing the mirror source must resume capture of the surviving virtual desktop.
        try setMirror(firstID, source: secondID)
        pump(for: 1)
        second.close()
        pump(for: 1)
        try check(menuItem.state == .off && displayWindow(serial: 2) == nil, "Closing second preview must disable it")
        try check(firstController.displayID == firstID, "Closing second display disconnected the first")
        try check(DisplayConfiguration(displayID: firstID)?.captureDisplayID == firstID, "Preview did not recover after its mirror source disconnected")
        _ = try frame(in: firstController)
        delegate.toggleSecondDisplay()
        pump()
        delegate.toggleSecondDisplay()
        pump()
        try check(menuItem.state == .off && displayWindow(serial: 2) == nil, "Menu must toggle second display off")
        delegate.toggleSecondDisplay()
        pump()
        first.close()
        pump()
        try check(displayWindow(serial: 2) != nil, "Closing first display disconnected second")
        delegate.showFirstDisplay()
        pump()
        try check(displayWindow(serial: 1) != nil, "First display could not be reopened")
        stop(delegate)
        try check(Set(NSScreen.screens.map(\.displayID)) == existingDisplays, "Quit leaked a virtual display")

        // Relaunch with the previous session ending with both displays enabled.
        let relaunched = AppDelegate()
        relaunched.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { stop(relaunched) }
        pump()
        try check(displayWindow(serial: 1) != nil && displayWindow(serial: 2) == nil, "Second display was remembered across launches")
        print("Passed second-display menu, independent refresh/cursor handling, close/reopen, quit, and default-off relaunch checks")
    }

    static func setMirror(_ follower: CGDirectDisplayID, source: CGDirectDisplayID) throws {
        var configuration: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&configuration) == .success, "Could not begin mirror configuration")
        guard let configuration = configuration else { throw Failure(message: "Missing mirror configuration") }
        guard CGConfigureDisplayMirrorOfDisplay(configuration, follower, source) == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw Failure(message: "Could not configure mirroring")
        }
        try check(CGCompleteDisplayConfiguration(configuration, .forSession) == .success, "Could not apply mirroring")
    }

    static func checkMirroring(follower: ScreenViewController, source: ScreenViewController) throws {
        let followerID = follower.displayID!
        let sourceID = source.displayID!
        try setMirror(followerID, source: sourceID)
        defer {
            try? setMirror(followerID, source: kCGNullDirectDisplay)
            pump(for: 1)
        }
        pump(for: 2)
        try check(CGDisplayMirrorsDisplay(followerID) == sourceID, "macOS did not enable the requested mirror")
        guard let configuration = DisplayConfiguration(displayID: followerID) else {
            throw Failure(message: "Mirrored display has no capture configuration")
        }
        try check(configuration.captureDisplayID == sourceID, "Mirrored preview is capturing the inactive follower")

        let cocoaBounds = CGRect(x: configuration.bounds.minX,
                                 y: CGDisplayBounds(CGMainDisplayID()).height - configuration.bounds.maxY,
                                 width: configuration.bounds.width, height: configuration.bounds.height)
        let marker = NSWindow(contentRect: CGRect(x: cocoaBounds.minX + 50, y: cocoaBounds.minY + 50, width: 200, height: 150),
                              styleMask: .borderless, backing: .buffered, defer: false)
        marker.isReleasedWhenClosed = false
        marker.level = .floating
        defer { marker.close() }

        for color in [NSColor.red, .green] {
            marker.backgroundColor = color
            marker.orderFrontRegardless()
            pump()
            for controller in [follower, source] {
                let surface = try frame(in: controller)
                let x = Int((marker.frame.midX - cocoaBounds.minX) / cocoaBounds.width * CGFloat(IOSurfaceGetWidth(surface)))
                let y = Int((cocoaBounds.maxY - marker.frame.midY) / cocoaBounds.height * CGFloat(IOSurfaceGetHeight(surface)))
                IOSurfaceLock(surface, .readOnly, nil)
                let address = IOSurfaceGetBaseAddress(surface)
                let pixel = address.advanced(by: y * IOSurfaceGetBytesPerRow(surface) + x * 4).assumingMemoryBound(to: UInt8.self)
                let matches = color == .red ? pixel[2] > 200 && pixel[1] < 80 : pixel[1] > 200 && pixel[2] < 80
                IOSurfaceUnlock(surface, .readOnly, nil)
                try check(matches, "Mirrored preview is black, stale, or capturing the wrong desktop")
            }
        }
        print("Passed live mirrored capture and fresh-frame checks (\(followerID) → \(sourceID))")
    }
}
