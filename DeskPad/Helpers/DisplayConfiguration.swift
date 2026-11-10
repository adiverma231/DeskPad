import CoreGraphics

/// A mirrored display can be online without having its own NSScreen or capture surface.
struct DisplayConfiguration {
    let captureDisplayID: CGDirectDisplayID
    let bounds: CGRect
    let scaleFactor: CGFloat

    static func captureDisplayID(
        for displayID: CGDirectDisplayID,
        mirrors: (CGDirectDisplayID) -> CGDirectDisplayID = CGDisplayMirrorsDisplay
    ) -> CGDirectDisplayID? {
        var current = displayID
        var visited = Set<CGDirectDisplayID>()
        while current != kCGNullDirectDisplay, visited.insert(current).inserted {
            let source = mirrors(current)
            if source == kCGNullDirectDisplay { return current }
            current = source
        }
        return nil
    }

    init?(displayID: CGDirectDisplayID) {
        guard CGDisplayIsOnline(displayID) != 0,
              let source = Self.captureDisplayID(for: displayID),
              CGDisplayIsActive(source) != 0,
              let mode = CGDisplayCopyDisplayMode(source)
        else { return nil }
        let bounds = CGDisplayBounds(source)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        captureDisplayID = source
        self.bounds = bounds
        scaleFactor = CGFloat(mode.pixelWidth) / bounds.width
    }
}
