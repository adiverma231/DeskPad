import CoreGraphics
import Foundation

enum DisplayGeometry {
    static func captureSize(resolution: CGSize, scaleFactor: CGFloat, previewSize: CGSize) -> CGSize? {
        guard resolution.width > 0, resolution.height > 0, scaleFactor > 0,
              previewSize.width > 0, previewSize.height > 0
        else { return nil }

        let width = resolution.width * scaleFactor
        let height = resolution.height * scaleFactor
        // Preserve aspect ratio and native detail without capturing pixels the preview cannot show.
        let scale = min(1, max(previewSize.width / width, previewSize.height / height))
        return CGSize(width: ceil(width * scale), height: ceil(height * scale))
    }

    static func displayPoint(for point: CGPoint, in bounds: CGRect, resolution: CGSize) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0, resolution.width > 0, resolution.height > 0 else { return nil }
        return CGPoint(
            x: min(max((point.x - bounds.minX) / bounds.width * resolution.width, 0), resolution.width - 1),
            y: min(max((bounds.maxY - point.y) / bounds.height * resolution.height, 0), resolution.height - 1)
        )
    }
}
