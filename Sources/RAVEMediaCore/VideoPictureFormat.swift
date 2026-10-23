import Foundation

/// What a player is showing: the decoded picture's size and frame rate, for
/// a readout such as "1920×1080 · 23.976 fps".
///
/// Frame rates come measured (a player's frame times, a track's nominal
/// rate) and are shown as the standard rate they are, so a measured
/// 23.9759 reads 23.976 and a 59.94 stream doesn't read 60.
public struct VideoPictureFormat: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var framesPerSecond: Double?

    public init(width: Int, height: Int, framesPerSecond: Double? = nil) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
    }

    /// "1920×1080 · 23.976 fps", or just the size until the rate is known.
    public var summary: String {
        let size = "\(width)×\(height)"
        guard let rate = framesPerSecond.flatMap(Self.rateLabel) else { return size }
        return "\(size) · \(rate) fps"
    }

    /// The broadcast and film rates, NTSC's 1000/1001 ones included.
    public static let standardRates: [Double] = [
        24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 48000.0 / 1001, 48, 50,
        60000.0 / 1001, 60, 100, 120000.0 / 1001, 120,
    ]

    /// The standard rate within 0.5% of `measured`, else `measured`.
    public static func snapped(_ measured: Double) -> Double {
        guard measured.isFinite, measured > 0 else { return measured }
        let nearest = standardRates.min { abs($0 - measured) < abs($1 - measured) } ?? measured
        return abs(nearest - measured) / nearest <= 0.005 ? nearest : measured
    }

    /// "23.976", "29.97", "24", "59.94"; nil for no rate.
    public static func rateLabel(_ measured: Double) -> String? {
        guard measured.isFinite, measured >= 1 else { return nil }
        let rate = snapped(measured)
        if abs(rate - rate.rounded()) < 0.0005 { return String(Int(rate.rounded())) }
        // 23.976 needs three places; 29.97 and 59.94 two.
        var text = String(format: "%.3f", rate)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}
