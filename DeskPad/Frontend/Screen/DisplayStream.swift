import CoreGraphics
import CoreVideo
import IOSurface
import QuartzCore

/// Owns one zero-copy capture stream and the surface currently presented by its layer.
final class DisplayStream {
    let displayID: CGDirectDisplayID
    let size: CGSize

    private var stream: CGDisplayStream?
    private let layer: CALayer
    private var surface: IOSurfaceRef?

    init?(displayID: CGDirectDisplayID, size: CGSize, layer: CALayer) {
        self.displayID = displayID
        self.size = size
        self.layer = layer

        // CGDisplayStream must remain alive until its asynchronous .stopped callback.
        let lifetime = StreamLifetime()
        let stream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: Int(size.width),
            outputHeight: Int(size.height),
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: [CGDisplayStream.showCursor: true] as CFDictionary,
            queue: .main
        ) { [weak self] status, _, surface, _ in
            switch status {
            case .stopped:
                lifetime.stream = nil
            case .frameComplete:
                if let surface = surface {
                    self?.present(surface)
                }
            case .frameBlank:
                self?.present(nil)
            case .frameIdle:
                break
            @unknown default:
                break
            }
        }
        guard let stream = stream else { return nil }
        self.stream = stream
        lifetime.stream = stream
        guard stream.start() == .success else {
            lifetime.stream = nil
            self.stream = nil
            return nil
        }
    }

    private func present(_ surface: IOSurfaceRef?) {
        // Retaining alone does not prevent the producer from recycling an IOSurface.
        if self.surface === surface { return }
        if let surface = surface {
            IOSurfaceIncrementUseCount(surface)
        }
        let previousSurface = self.surface
        self.surface = surface
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = surface
        CATransaction.commit()
        if let previousSurface = previousSurface {
            IOSurfaceDecrementUseCount(previousSurface)
        }
    }

    deinit {
        stream?.stop()
        present(nil)
    }
}

private final class StreamLifetime {
    var stream: CGDisplayStream?
}
