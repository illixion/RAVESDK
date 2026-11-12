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

    /// The colour image's alpha, one byte per pixel, top row first.
    static func alpha(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
    }

    /// Stretches the subject's own depth over the whole byte range: its p2 becomes 1 and its p98 255,
    /// clamped. This is the per-image rule Vergence's `StillDepthMap` applies to a model's estimate
    /// (p2 → 0, p98 → 255), restricted to the pixels that show. It lives here rather than calling
    /// Vergence because RAVESupport builds on every platform without that package.
    ///
    /// Mirror normalizes depth over the avatar's whole bounds, tail and off-frame body included,
    /// so the part in the picture can span as few as 20 of the 256 levels. Shown as is, that
    /// reads as a flat cut-out lifted off the card; stretched, the relief is the figure's own.
    ///
    /// Only pixels at `opaque` alpha or more count, and only they keep their own depth. Everything
    /// else, the anti-aliased outline included, takes the depth of the nearest such pixel within
    /// `grow` pixels (about 1.5% of the long side by default) and 0 (far) beyond. Captures before
    /// 2026-11-12 averaged the outline's depth with the far background, and even a clean outline
    /// is pulled towards far by the relief mesh's softening blur: either way the mesh's edge
    /// triangles slid down to the card, stretching the faint outline pixels into a streaky fringe.
    /// Grown past the outline, the surface holds its depth to the silhouette and the transparent
    /// texels beyond it carry no picture.
    static func stretched(_ values: [UInt8], alpha: [UInt8], width: Int, height: Int,
                          opaque: UInt8 = 250, grow: Int? = nil) -> [UInt8] {
        guard values.count == alpha.count, values.count == width * height else { return values }
        let grown = grow ?? max(4, max(width, height) * 3 / 200)
        return dilated(stretchedCore(values, alpha: alpha, opaque: opaque), alpha: alpha,
                       width: width, height: height, opaque: opaque, steps: grown)
    }

    private static func stretchedCore(_ values: [UInt8], alpha: [UInt8], opaque: UInt8) -> [UInt8] {
        var bins = [Int](repeating: 0, count: 256)
        var total = 0
        for i in values.indices where alpha[i] >= opaque {
            bins[Int(values[i])] += 1
            total += 1
        }
        guard total > 0 else { return values }
        func percentile(_ q: Double) -> Double {
            let target = Double(total) * q
            var cumulative = 0.0
            for (level, count) in bins.enumerated() where count > 0 {
                let next = cumulative + Double(count)
                if next >= target { return Double(level) + (target - cumulative) / Double(count) }
                cumulative = next
            }
            return 255
        }
        let lo = percentile(0.02), hi = percentile(0.98)
        // A subject at one depth (a flat sticker) has nothing to stretch; keep its values.
        guard hi - lo >= 1 else {
            return values.indices.map { alpha[$0] >= opaque ? values[$0] : 0 }
        }
        return values.indices.map { i in
            guard alpha[i] >= opaque else { return 0 }
            let t = min(max((Double(values[i]) - lo) / (hi - lo), 0), 1)
            return UInt8((1 + t * 254).rounded())
        }
    }

    /// Grows the opaque core's depth outward one ring per step: each unfilled pixel next to filled
    /// ones takes their mean. Pixels more than `steps` away stay 0.
    private static func dilated(_ core: [UInt8], alpha: [UInt8], width: Int, height: Int,
                                opaque: UInt8, steps: Int) -> [UInt8] {
        var out = core
        var filled = alpha.map { $0 >= opaque }
        var frontier: [Int] = []
        for i in out.indices where !filled[i] {
            let x = i % width, y = i / width
            if (x > 0 && filled[i - 1]) || (x < width - 1 && filled[i + 1])
                || (y > 0 && filled[i - width]) || (y < height - 1 && filled[i + width]) { frontier.append(i) }
        }
        var step = 0
        while step < steps, !frontier.isEmpty {
            var ring: [(Int, UInt8)] = []
            ring.reserveCapacity(frontier.count)
            for i in frontier where !filled[i] {
                let x = i % width, y = i / width
                var sum = 0, n = 0
                if x > 0, filled[i - 1] { sum += Int(out[i - 1]); n += 1 }
                if x < width - 1, filled[i + 1] { sum += Int(out[i + 1]); n += 1 }
                if y > 0, filled[i - width] { sum += Int(out[i - width]); n += 1 }
                if y < height - 1, filled[i + width] { sum += Int(out[i + width]); n += 1 }
                if n > 0 { ring.append((i, UInt8((sum + n / 2) / n))) }
            }
            // Committed after the whole ring is read, so a ring grows from the one before it only.
            var next: [Int] = []
            for (i, value) in ring where !filled[i] {
                out[i] = value
                filled[i] = true
                let x = i % width, y = i / width
                if x > 0, !filled[i - 1] { next.append(i - 1) }
                if x < width - 1, !filled[i + 1] { next.append(i + 1) }
                if y > 0, !filled[i - width] { next.append(i - width) }
                if y < height - 1, !filled[i + width] { next.append(i + width) }
            }
            frontier = next
            step += 1
        }
        return out
    }
}
