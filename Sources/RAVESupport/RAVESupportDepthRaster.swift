import CoreGraphics
import Foundation

enum RAVESupportDepthRaster {
    /// Depth PNG bytes are normalized inverse distance, not display luminance.
    /// Reject mismatched or colour images rather than silently misaligning them.
    static func samples(_ map: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard map.width == width, map.height == height,
              map.bitsPerComponent == 8, map.bitsPerPixel == 8,
              map.colorSpace?.model == .monochrome,
              let data = map.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= map.bytesPerRow * map.height else { return nil }
        var values = [UInt8]()
        values.reserveCapacity(width * height)
        for y in 0..<height {
            values.append(contentsOf: UnsafeBufferPointer(start: bytes + y * map.bytesPerRow, count: width))
        }
        return values
    }
}
