import CoreGraphics

@main
enum PreviewInputTests {
    static func near(_ point: CGPoint, _ expected: CGPoint) -> Bool {
        abs(point.x - expected.x) < 0.001 && abs(point.y - expected.y) < 0.001
    }

    static func mouse(_ type: CGEventType, button: CGMouseButton = .left, dx: Double = 0, dy: Double = 0) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: button)!
        event.setDoubleValueField(.mouseEventDeltaX, value: dx)
        event.setDoubleValueField(.mouseEventDeltaY, value: dy)
        return event
    }

    static func main() {
        let bounds = CGRect(x: 10, y: 20, width: 960, height: 540)
        let display = CGRect(x: -3840, y: -500, width: 3840, height: 2160)
        var input = PreviewInput(displayBounds: display, point: CGPoint(x: 490, y: 290))
        precondition(input.targetPoint(in: bounds) == CGPoint(x: -1920, y: 580), "Map into global Quartz coordinates, including negative origins")

        let down = mouse(.leftMouseDown)
        down.flags = [.maskShift, .maskCommand]
        down.setIntegerValueField(.mouseEventClickState, value: 2)
        precondition(input.route(down, in: bounds) && input.pressedButtons == [0], "Track the initiating button down")
        precondition(down.location == CGPoint(x: -1920, y: 580), "First click reaches the target desktop")
        precondition(down.flags == [.maskShift, .maskCommand] && down.getIntegerValueField(.mouseEventClickState) == 2,
                     "Preserve modifiers and double clicks")

        let drag = mouse(.leftMouseDragged, dx: 12, dy: 8)
        precondition(input.route(drag, in: bounds), "Continue a drag")
        precondition(near(input.point, CGPoint(x: 502, y: 282)) && near(drag.location, CGPoint(x: -1872, y: 612)), "Scale pointer movement and flip preview Y")
        precondition(abs(drag.getDoubleValueField(.mouseEventDeltaX) - 48) < 0.001 && abs(drag.getDoubleValueField(.mouseEventDeltaY) - 32) < 0.001,
                     "Target apps receive full-resolution movement deltas")

        let beyondEdge = mouse(.leftMouseDragged, dx: 2000, dy: 2000)
        precondition(input.route(beyondEdge, in: bounds), "Do not abandon a drag at the preview edge")
        precondition(beyondEdge.location == CGPoint(x: -1, y: 1659), "Clamp dragging to the target desktop")
        let up = mouse(.leftMouseUp)
        precondition(input.route(up, in: bounds) && input.pressedButtons.isEmpty, "Deliver the final mouse up before releasing control")
        precondition(!input.route(mouse(.mouseMoved), in: bounds), "Release at the edge once the drag is complete")

        input = PreviewInput(displayBounds: display, point: CGPoint(x: 490, y: 290))
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -15, wheel2: 7, wheel3: 0)!
        let delta = scroll.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        precondition(input.route(scroll, in: bounds) && scroll.location == CGPoint(x: -1920, y: 580), "Route scrolling to the target")
        precondition(scroll.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) == delta && input.point == CGPoint(x: 490, y: 290),
                     "Scrolling must not move the pointer or change its scroll delta")

        precondition(input.route(mouse(.rightMouseDown, button: .right), in: bounds), "Route right click")
        precondition(input.route(mouse(.otherMouseDown, button: .center), in: bounds), "Route middle click")
        precondition(input.releaseButtons() == [1, 2] && input.pressedButtons.isEmpty, "Release all held buttons on cancellation")
        precondition(input.releaseButtons().isEmpty, "Repeated cleanup is safe")
        precondition(input.targetPoint(in: .zero) == nil, "Do not route into an unavailable preview")
        print("Passed 18 preview-input mapping, drag, scroll, modifier, and cleanup checks")
    }
}
