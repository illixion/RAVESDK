/*
 RAVEMedia - histogram reduction for the offline depth converter.

 Lifted out of `DepthConverter.PostStage` so it can be tested: it is pure
 arithmetic over 256 bin counts, and everything around it in that class needs a
 Metal device, a Core ML model and a decoded video to reach.

 The percentile is **interpolating**, not nearest-rank — deliberately different
 from `RAVEProfilerWindow`'s in RAVEEngine. These bins are a 256-bucket
 quantization of a continuous depth range, so the sub-bin position of the
 quantile carries real information; a frame-timing sample series has no such
 continuum between samples. Changing it would shift every converted frame's
 encode range and require a `DepthCacheStore.pipelineVersion` bump.
 */

import Foundation

enum DepthHistogram {
    /// Number of bins the `depthHistogram256` kernel writes.
    static let binCount = 256

    /// Value at quantile `q` over a histogram of `total` samples spanning
    /// `[lo, hi]`, linearly interpolated within the bin the quantile falls in.
    ///
    /// - Parameters:
    ///   - bins: raw counts, `binCount` of them, ascending in value.
    ///   - total: sample count the quantile is taken against. Callers pass the
    ///     texture's pixel count rather than `bins.sum()`, so non-finite depth
    ///     texels (which the kernel skips) pull the quantile toward `lo`.
    ///   - q: quantile in 0...1.
    /// - Returns: `lo` when there are no samples, `hi` when the cumulative
    ///   count never reaches the target — which is what an all-skipped or
    ///   short-counted histogram should degrade to rather than a bin index.
    static func percentile(_ bins: [UInt32], total: Int, q: Float, lo: Float, hi: Float) -> Float {
        guard total > 0 else { return lo }
        let target = Float(total) * q
        var cumulative: Float = 0
        for (i, count) in bins.enumerated() where count > 0 {
            let next = cumulative + Float(count)
            if next >= target {
                let frac = (target - cumulative) / Float(count)
                return lo + (Float(i) + frac) / Float(binCount) * (hi - lo)
            }
            cumulative = next
        }
        return hi
    }
}
