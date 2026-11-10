import Foundation

@main
enum DisplayGeometryTests {
    static func main() {
        let cases: [(String, CGSize, CGFloat, CGSize, CGSize?)] = [
            ("4K display in a 1080p preview", CGSize(width: 3840, height: 2160), 1,
             CGSize(width: 1920, height: 1080), CGSize(width: 1920, height: 1080)),
            ("Retina preview keeps native detail", CGSize(width: 1920, height: 1080), 2,
             CGSize(width: 3840, height: 2160), CGSize(width: 3840, height: 2160)),
            ("1x preview of a HiDPI display", CGSize(width: 1920, height: 1080), 2,
             CGSize(width: 1920, height: 1080), CGSize(width: 1920, height: 1080)),
            ("ultrawide preview", CGSize(width: 5120, height: 1440), 1,
             CGSize(width: 1280, height: 360), CGSize(width: 1280, height: 360)),
            ("larger preview does not upscale capture buffers", CGSize(width: 1280, height: 800), 1,
             CGSize(width: 2560, height: 1600), CGSize(width: 1280, height: 800)),
            ("round up fractional pixels", CGSize(width: 1366, height: 768), 1,
             CGSize(width: 683, height: 384.5), CGSize(width: 684, height: 385)),
            ("display not ready", .zero, 1, CGSize(width: 800, height: 600), nil),
            ("preview not laid out", CGSize(width: 1920, height: 1080), 2, .zero, nil),
        ]
        for (name, resolution, scale, preview, expected) in cases {
            precondition(DisplayGeometry.captureSize(resolution: resolution, scaleFactor: scale, previewSize: preview) == expected, name)
        }

        let resolution = CGSize(width: 3840, height: 2160)
        let bounds = CGRect(x: 10, y: 20, width: 960, height: 540)
        let points: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 490, y: 290), CGPoint(x: 1920, y: 1080)),
            (CGPoint(x: 10, y: 560), .zero),
            (CGPoint(x: 970, y: 20), CGPoint(x: 3839, y: 2159)),
            (CGPoint(x: -100, y: 700), .zero),
        ]
        for (point, expected) in points {
            precondition(DisplayGeometry.displayPoint(for: point, in: bounds, resolution: resolution) == expected,
                         "Click mapping must use display points, flip Y, and stay inside the display")
        }
        precondition(DisplayGeometry.displayPoint(for: .zero, in: .zero, resolution: resolution) == nil)
        precondition(DisplayGeometry.displayPoint(for: .zero, in: bounds, resolution: .zero) == nil)
        let mirrors: [UInt32: UInt32] = [2: 1, 3: 2]
        precondition(DisplayConfiguration.captureDisplayID(for: 1, mirrors: { mirrors[$0] ?? 0 }) == 1,
                     "An extended display captures itself")
        precondition(DisplayConfiguration.captureDisplayID(for: 2, mirrors: { mirrors[$0] ?? 0 }) == 1,
                     "A mirrored virtual display captures the mirror source")
        precondition(DisplayConfiguration.captureDisplayID(for: 3, mirrors: { mirrors[$0] ?? 0 }) == 1,
                     "Resolve the entire mirror chain")
        precondition(DisplayConfiguration.captureDisplayID(for: 0, mirrors: { _ in 0 }) == nil,
                     "Do not capture the null display")
        precondition(DisplayConfiguration.captureDisplayID(for: 1, mirrors: { $0 == 1 ? 2 : 1 }) == nil,
                     "A transient cyclic mirror configuration must not hang")
        print("Passed 19 capture-size, cursor-mapping, and mirror-source checks")
    }
}
