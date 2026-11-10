import ApplicationServices
import Cocoa

/// Routes normal system input to the displayed desktop while its pointer is visible in the preview.
/// Disassociating the mouse lets preview-sized movement drive a full-resolution remote desktop.
final class PreviewControl {
    enum StartResult {
        case started, accessibilityRequired, unavailable
    }

    private weak var view: NSView?
    private var input: PreviewInput
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isControlling = false
    private var returnLocation: CGPoint?
    private let eventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Replaying the first click must not suppress the following physical mouse-up.
        source?.localEventsSuppressionInterval = 0
        let filter: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source?.setLocalEventsFilterDuringSuppressionState(filter, state: .eventSuppressionStateSuppressionInterval)
        source?.setLocalEventsFilterDuringSuppressionState(filter, state: .eventSuppressionStateRemoteMouseDrag)
        return source
    }()

    init(view: NSView, displayBounds: CGRect, point: CGPoint) {
        self.view = view
        input = PreviewInput(displayBounds: displayBounds, point: point)
    }

    func start(with event: NSEvent) -> StartResult {
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            return .accessibilityRequired
        }
        returnLocation = event.cgEvent?.location
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context = context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<PreviewControl>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return .unavailable }

        self.tap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        guard CGAssociateMouseAndMouseCursorPosition(0) == .success else {
            stop()
            return .unavailable
        }
        isControlling = true
        CGEvent.tapEnable(tap: tap, enable: true)

        // AppKit already consumed the initiating down event. Replay it at the target so the
        // very first click both activates the target app and operates its controls normally.
        guard let original = event.cgEvent, let location = targetPoint,
              let click = CGEvent(mouseEventSource: eventSource, mouseType: original.type, mouseCursorPosition: location,
                                  mouseButton: CGMouseButton(rawValue: UInt32(event.buttonNumber)) ?? .left)
        else {
            stop()
            return .unavailable
        }
        click.flags = original.flags
        click.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount))
        guard let view = view, input.route(click, in: view.bounds) else {
            stop()
            return .unavailable
        }
        click.setIntegerValueField(.eventSourceUserData, value: Self.replayedEvent)
        CGWarpMouseCursorPosition(location)
        click.post(tap: .cgSessionEventTap)
        return .started
    }

    private static let replayedEvent: Int64 = 0x4465736B506164

    private var targetPoint: CGPoint? {
        guard let view = view else { return nil }
        return input.targetPoint(in: view.bounds)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Never leave the hardware mouse disconnected if macOS disables the tap.
            stop()
            return Unmanaged.passUnretained(event)
        }
        guard isControlling else { return Unmanaged.passUnretained(event) }
        guard let view = view, view.window?.isVisible == true else {
            stop()
            return nil
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayedEvent {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                stop()
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard input.route(event, in: view.bounds) else {
            stop()
            return nil
        }
        CGWarpMouseCursorPosition(event.location)
        return Unmanaged.passUnretained(event)
    }

    func stop() {
        if isControlling {
            isControlling = false
            // Balance button downs when Esc, a display change, or closing interrupts a drag.
            if let location = targetPoint {
                for button in input.releaseButtons() {
                    let type: CGEventType = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
                    if let up = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: location,
                                        mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .left) {
                        up.setIntegerValueField(.eventSourceUserData, value: Self.replayedEvent)
                        up.post(tap: .cgSessionEventTap)
                    }
                }
            }
            _ = input.releaseButtons()
            CGAssociateMouseAndMouseCursorPosition(1)
            var restoreLocation = returnLocation
            if let view = view, let window = view.window {
                var screenPoint = window.convertPoint(toScreen: view.convert(input.point, to: nil))
                if let screen = window.screen {
                    screenPoint.x = min(max(screenPoint.x, screen.frame.minX), screen.frame.maxX - 1)
                    screenPoint.y = min(max(screenPoint.y, screen.frame.minY), screen.frame.maxY - 1)
                }
                restoreLocation = CGPoint(x: screenPoint.x, y: CGDisplayBounds(CGMainDisplayID()).height - screenPoint.y)
            }
            if let location = restoreLocation {
                CGWarpMouseCursorPosition(location)
            }
        }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    deinit {
        stop()
    }
}

final class PreviewView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func rightMouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func otherMouseDown(with event: NSEvent) { onMouseDown?(event) }
}
