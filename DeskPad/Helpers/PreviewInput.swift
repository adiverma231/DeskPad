import CoreGraphics

/// Preview-space pointer state, independent of the system cursor and event-tap lifetime.
struct PreviewInput {
    let displayBounds: CGRect
    private(set) var point: CGPoint
    private(set) var pressedButtons = Set<Int64>()

    init(displayBounds: CGRect, point: CGPoint) {
        self.displayBounds = displayBounds
        self.point = point
    }

    func targetPoint(in bounds: CGRect) -> CGPoint? {
        guard let local = DisplayGeometry.displayPoint(for: point, in: bounds, resolution: displayBounds.size) else { return nil }
        return CGPoint(x: displayBounds.minX + local.x, y: displayBounds.minY + local.y)
    }

    /// False releases control. During a drag, clamp to the target rather than losing its mouse-up.
    mutating func route(_ event: CGEvent, in bounds: CGRect) -> Bool {
        let previous = targetPoint(in: bounds)
        let movesPointer: Bool
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            movesPointer = true
            point.x += event.getDoubleValueField(.mouseEventDeltaX)
            point.y -= event.getDoubleValueField(.mouseEventDeltaY)
            if pressedButtons.isEmpty, !bounds.contains(point) { return false }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            movesPointer = false
            pressedButtons.insert(event.getIntegerValueField(.mouseEventButtonNumber))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            movesPointer = false
            pressedButtons.remove(event.getIntegerValueField(.mouseEventButtonNumber))
        default:
            movesPointer = false
        }
        guard let location = targetPoint(in: bounds) else { return false }
        event.location = location
        if movesPointer, let previous = previous {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64((location.x - previous.x).rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64((location.y - previous.y).rounded()))
        }
        return true
    }

    mutating func releaseButtons() -> Set<Int64> {
        let buttons = pressedButtons
        pressedButtons.removeAll()
        return buttons
    }
}
