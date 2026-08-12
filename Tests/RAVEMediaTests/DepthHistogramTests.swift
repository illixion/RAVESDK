import Testing
@testable import RAVEMedia

/// The offline converter encodes every frame against a robust p2–p98 range read
/// out of a 256-bin GPU histogram. Get this wrong and depth still *looks*
/// plausible per frame while the range wanders between frames — which reads on
/// device as the pumping the lookahead post-pass exists to prevent. None of it
/// had coverage.
@Suite("Depth histogram percentiles")
struct DepthHistogramTests {
    /// One sample in one bin: the quantile lands inside that bin, interpolated.
    @Test func singleBinInterpolatesWithinItsBucket() {
        var bins = [UInt32](repeating: 0, count: 256)
        bins[128] = 1
        // q=1 puts the target at the far edge of bin 128 → (128+1)/256.
        #expect(DepthHistogram.percentile(bins, total: 1, q: 1, lo: 0, hi: 1) == 129.0 / 256.0)
        // q=0 lands at the bin's near edge.
        #expect(DepthHistogram.percentile(bins, total: 1, q: 0, lo: 0, hi: 1) == 128.0 / 256.0)
    }

    /// A uniform histogram should return roughly the quantile itself — the
    /// property that makes p2/p98 a *robust range* rather than an arbitrary pair
    /// of bin edges.
    @Test(arguments: [Float(0.02), 0.25, 0.5, 0.75, 0.98])
    func uniformHistogramApproximatesTheQuantile(q: Float) {
        let bins = [UInt32](repeating: 4, count: 256)
        let value = DepthHistogram.percentile(bins, total: 256 * 4, q: q, lo: 0, hi: 1)
        #expect(abs(value - q) < 1.0 / 256.0)
    }

    /// The range is affine in (lo, hi): the converter feeds raw model units,
    /// which have an arbitrary per-frame scale, so the reduction must not
    /// assume a normalised domain.
    @Test func rescalesIntoTheGivenRange() {
        let bins = [UInt32](repeating: 4, count: 256)
        let unit = DepthHistogram.percentile(bins, total: 1024, q: 0.5, lo: 0, hi: 1)
        let shifted = DepthHistogram.percentile(bins, total: 1024, q: 0.5, lo: 10, hi: 20)
        #expect(abs(shifted - (10 + unit * 10)) < 1e-4)
    }

    /// A flat frame — every texel identical — collapses p2 and p98 into the same
    /// bin. The caller widens the span afterwards; what matters here is that
    /// both ends land in that bin rather than at the range extremes.
    @Test func flatFrameCollapsesBothPercentilesIntoOneBin() {
        var bins = [UInt32](repeating: 0, count: 256)
        bins[64] = 10_000
        let lo = DepthHistogram.percentile(bins, total: 10_000, q: 0.02, lo: 0, hi: 1)
        let hi = DepthHistogram.percentile(bins, total: 10_000, q: 0.98, lo: 0, hi: 1)
        #expect(lo >= 64.0 / 256.0)
        #expect(hi <= 65.0 / 256.0)
        #expect(hi - lo < 1.0 / 256.0)
    }

    /// Outliers are what p2/p98 exists to clip: a speckle of far-off values must
    /// not drag the robust range out to meet them.
    @Test func outlierSpeckleDoesNotDragTheRobustRange() {
        var bins = [UInt32](repeating: 0, count: 256)
        for i in 100...150 { bins[i] = 100 }   // the body: 5100 samples
        bins[0] = 20                            // speckle at both extremes
        bins[255] = 20
        let total = 5100 + 40
        let lo = DepthHistogram.percentile(bins, total: total, q: 0.02, lo: 0, hi: 1)
        let hi = DepthHistogram.percentile(bins, total: total, q: 0.98, lo: 0, hi: 1)
        #expect(lo > 99.0 / 256.0)
        #expect(hi < 152.0 / 256.0)
    }

    /// `total` is the texture's pixel count, not `bins.sum()` — the kernel skips
    /// non-finite depth. Skipped texels therefore pull the quantile *down*, and
    /// enough of them push it off the end of the histogram, where `hi` is the
    /// only honest answer.
    @Test func skippedTexelsPullTheQuantileDownAndThenOffTheEnd() {
        var bins = [UInt32](repeating: 0, count: 256)
        bins[200] = 50

        // Half the frame skipped: the median target (50 of 100) sits at the very
        // end of the only populated bin rather than its middle.
        let halfSkipped = DepthHistogram.percentile(bins, total: 100, q: 0.5, lo: 0, hi: 1)
        #expect(halfSkipped == 201.0 / 256.0)

        // More skipped than counted: the cumulative count never reaches the
        // target at all, and the reduction degrades to `hi`.
        #expect(DepthHistogram.percentile(bins, total: 1000, q: 0.5, lo: 0, hi: 1) == 1)
    }

    /// An empty histogram must not divide by zero or return a bin index.
    @Test func emptyHistogramReturnsLo() {
        let bins = [UInt32](repeating: 0, count: 256)
        #expect(DepthHistogram.percentile(bins, total: 0, q: 0.5, lo: 7, hi: 9) == 7)
        // Non-zero total but no counts: nothing ever reaches the target.
        #expect(DepthHistogram.percentile(bins, total: 100, q: 0.5, lo: 7, hi: 9) == 9)
    }

    /// Monotonic in q. The converter reads three quantiles from one histogram
    /// (p2, median, p98) and assumes p2 ≤ median ≤ p98 when it builds the
    /// per-frame affine; a violation would invert the mapping.
    @Test func monotonicInQuantile() {
        var bins = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 { bins[i] = UInt32(i % 7) }
        let total = bins.reduce(0) { $0 + Int($1) }
        var previous = -Float.infinity
        for step in 0...100 {
            let value = DepthHistogram.percentile(bins, total: total, q: Float(step) / 100, lo: 0, hi: 1)
            #expect(value >= previous)
            previous = value
        }
    }
}
