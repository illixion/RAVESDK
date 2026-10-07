/*
 RAVEMedia - Still Depth Map

 Depth for a single still image, on the CPU: the shape a caller that caches
 or slices depth per image wants (gallery thumbnails), as opposed to the
 GPU-resident, temporally stabilized map the video pump consumes.

 The map is cropped to the image's own content region (Vision letterboxes a
 non-square image into the model's square input, the padding is not depth),
 so it has the image's aspect and lines up with it under any aspect-preserving
 scale. Values are robustly normalized per image (p2 → 0, p98 → 255) over the
 model's inverse depth: 255 is the NEAR end, matching the fake-3D warp.
 */

import Accelerate
import CoreML
import CoreVideo
import Foundation

public struct StillDepthMap: Sendable {
    public let width: Int
    public let height: Int
    /// Row-major, `width * height` bytes. 0 = far, 255 = near.
    public let values: [UInt8]

    public init(width: Int, height: Int, values: [UInt8]) {
        self.width = width
        self.height = height
        self.values = values
    }
}

enum StillDepthExtraction {
    /// A model output plane as floats. `nil` for an unsupported format.
    static func floats(from pixelBuffer: CVPixelBuffer) -> (values: [Float], width: Int, height: Int)? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var values = [Float](repeating: 0, count: width * height)

        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_OneComponent8:
            values.withUnsafeMutableBufferPointer { dest in
                for y in 0..<height {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    vDSP_vfltu8(row, 1, dest.baseAddress! + y * width, 1, vDSP_Length(width))
                }
            }
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32:
            values.withUnsafeMutableBufferPointer { dest in
                for y in 0..<height {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                    (dest.baseAddress! + y * width).update(from: row, count: width)
                }
            }
        case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16:
            values.withUnsafeMutableBytes { destBytes in
                var source = vImage_Buffer(
                    data: base, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: rowBytes
                )
                var dest = vImage_Buffer(
                    data: destBytes.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.stride
                )
                vImageConvert_Planar16FtoPlanarF(&source, &dest, 0)
            }
        default:
            return nil
        }
        return (values, width, height)
    }

    /// The first H×W plane of a multi-array output (last two dimensions).
    static func floats(from array: MLMultiArray) -> (values: [Float], width: Int, height: Int)? {
        let shape = array.shape.map(\.intValue)
        guard shape.count >= 2 else { return nil }
        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]
        guard width > 0, height > 0 else { return nil }
        let count = width * height
        var values = [Float](repeating: 0, count: count)
        switch array.dataType {
        case .float32:
            let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)
            values.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: ptr, count: count) }
        case .float16:
            values.withUnsafeMutableBytes { destBytes in
                var source = vImage_Buffer(
                    data: array.dataPointer, height: 1,
                    width: vImagePixelCount(count), rowBytes: count * MemoryLayout<UInt16>.stride
                )
                var dest = vImage_Buffer(
                    data: destBytes.baseAddress, height: 1,
                    width: vImagePixelCount(count), rowBytes: count * MemoryLayout<Float>.stride
                )
                vImageConvert_Planar16FtoPlanarF(&source, &dest, 0)
            }
        case .double:
            let ptr = array.dataPointer.assumingMemoryBound(to: Double.self)
            values.withUnsafeMutableBufferPointer { vDSP_vdpsp(ptr, 1, $0.baseAddress!, 1, vDSP_Length(count)) }
        default:
            return nil
        }
        return (values, width, height)
    }

    /// Crop the letterboxed plane to the image's content region, then map its
    /// p2…p98 range onto 0…255. Percentiles rather than min/max so one stray
    /// texel (a specular highlight read as very near) can't flatten the rest.
    static func normalizedMap(
        _ plane: (values: [Float], width: Int, height: Int),
        imageWidth: Int, imageHeight: Int
    ) -> StillDepthMap? {
        let uv = CoreMLDepthProvider.letterboxUVTransform(
            videoWidth: imageWidth, videoHeight: imageHeight,
            depthWidth: plane.width, depthHeight: plane.height
        )
        let x0 = min(max(Int((uv.offset.x * Float(plane.width)).rounded()), 0), plane.width - 1)
        let y0 = min(max(Int((uv.offset.y * Float(plane.height)).rounded()), 0), plane.height - 1)
        let w = min(max(Int((uv.scale.x * Float(plane.width)).rounded()), 1), plane.width - x0)
        let h = min(max(Int((uv.scale.y * Float(plane.height)).rounded()), 1), plane.height - y0)

        var cropped = [Float](repeating: 0, count: w * h)
        plane.values.withUnsafeBufferPointer { src in
            cropped.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    (dst.baseAddress! + y * w).update(from: src.baseAddress! + (y0 + y) * plane.width + x0, count: w)
                }
            }
        }

        var minV: Float = 0, maxV: Float = 0
        vDSP_minv(cropped, 1, &minV, vDSP_Length(cropped.count))
        vDSP_maxv(cropped, 1, &maxV, vDSP_Length(cropped.count))
        guard maxV.isFinite, minV.isFinite, maxV > minV else { return nil }

        let bins = 1024
        var histogram = [Int](repeating: 0, count: bins)
        let binScale = Float(bins - 1) / (maxV - minV)
        for v in cropped where v.isFinite {
            histogram[min(max(Int((v - minV) * binScale), 0), bins - 1)] += 1
        }
        func percentile(_ p: Float) -> Float {
            let target = Int(Float(cropped.count) * p)
            var seen = 0
            for (i, n) in histogram.enumerated() {
                seen += n
                if seen > target { return minV + Float(i) / binScale }
            }
            return maxV
        }
        let lo = percentile(0.02)
        let hi = max(percentile(0.98), lo + (maxV - minV) * 1e-3)

        var scale = 255 / (hi - lo)
        var bias = -lo * scale
        vDSP_vsmsa(cropped, 1, &scale, &bias, &cropped, 1, vDSP_Length(cropped.count))
        var zero: Float = 0, top: Float = 255
        vDSP_vclip(cropped, 1, &zero, &top, &cropped, 1, vDSP_Length(cropped.count))
        var bytes = [UInt8](repeating: 0, count: cropped.count)
        vDSP_vfixru8(cropped, 1, &bytes, 1, vDSP_Length(cropped.count))
        return StillDepthMap(width: w, height: h, values: bytes)
    }
}
