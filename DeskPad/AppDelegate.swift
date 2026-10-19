import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [Int: NSWindow] = [:]
    private var secondDisplayMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_: Notification) {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "DeskPad")
        appMenu.addItem(withTitle: "Quit DeskPad", action: #selector(NSApp.terminate), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let displaysMenuItem = NSMenuItem()
        let displaysMenu = NSMenu(title: "Displays")
        let firstDisplayItem = displaysMenu.addItem(withTitle: "Show First Display", action: #selector(showFirstDisplay), keyEquivalent: "1")
        firstDisplayItem.target = self
        let secondDisplayItem = displaysMenu.addItem(withTitle: "Enable Second Display", action: #selector(toggleSecondDisplay), keyEquivalent: "2")
        secondDisplayItem.target = self
        secondDisplayMenuItem = secondDisplayItem
        displaysMenuItem.submenu = displaysMenu
        mainMenu.addItem(displaysMenuItem)
        NSApplication.shared.mainMenu = mainMenu

        // The second display is deliberately session-only: every launch starts with one display.
        showFirstDisplay()
    }

    @objc func showFirstDisplay() {
        showDisplay(number: 1)
    }

    @objc func toggleSecondDisplay() {
        if let window = windows[2] {
            window.close()
        } else {
            showDisplay(number: 2)
        }
    }

    private func showDisplay(number: Int) {
        if let window = windows[number] {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let name = number == 1 ? "DeskPad Display" : "DeskPad Display 2"
        let viewController = ScreenViewController(serialNumber: UInt32(number), name: name)
        let window = NSWindow(contentViewController: viewController)
        guard viewController.displayID != nil else {
            let alert = NSAlert()
            alert.messageText = "Could not create \(name)"
            alert.informativeText = "macOS could not create or configure the virtual display. Close any other running copy of DeskPad and try again."
            alert.runModal()
            return
        }
        window.delegate = viewController
        window.isReleasedWhenClosed = false
        window.title = number == 1 ? "DeskPad" : "DeskPad 2"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.titleVisibility = .visible
        window.backgroundColor = .white
        window.contentMinSize = CGSize(width: 400, height: 300)
        window.contentMaxSize = CGSize(width: 5120, height: 2160)
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenNone)

        viewController.onClose = { [weak self] in
            self?.windows.removeValue(forKey: number)
            self?.secondDisplayMenuItem?.state = self?.windows[2] == nil ? .off : .on
        }
        windows[number] = window
        secondDisplayMenuItem?.state = windows[2] == nil ? .off : .on
        window.makeKeyAndOrderFront(nil)
        if number == 2, let firstWindow = windows[1] {
            window.cascadeTopLeft(from: CGPoint(x: firstWindow.frame.minX + 30, y: firstWindow.frame.maxY - 30))
        }
    }

    func applicationWillTerminate(_: Notification) {
        for window in windows.values {
            (window.contentViewController as? ScreenViewController)?.stop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        return true
    }
}
