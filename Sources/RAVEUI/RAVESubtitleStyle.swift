import Foundation

#if canImport(SwiftUI)
import SwiftUI

/// How text subtitles look: size, lettering, colours, the plate behind the
/// text and the edge around it. The defaults are the look the renderers always
/// had (white semibold on a 60% black plate), so a host that never sets one
/// sees no change.
///
/// Codable, so a host keeps it as one JSON string in its settings
/// (`json`); `RAVESubtitleText`, `RAVESubtitleOverlay` and
/// `RAVESubtitlePanel` read it from `\.raveSubtitleStyle`. Bitmap subtitles
/// (a disc's PGS) are pictures and are not restyled.
public struct RAVESubtitleStyle: Codable, Equatable, Sendable {
    /// An sRGB colour that survives encoding.
    public struct RGB: Codable, Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        public init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red; self.green = green; self.blue = blue
        }
        public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

        public static let white = RGB(1, 1, 1)
        public static let black = RGB(0, 0, 0)
        public static let yellow = RGB(1, 0.92, 0.2)
        public static let cyan = RGB(0.35, 0.9, 1)
        public static let green = RGB(0.45, 1, 0.45)
        public static let pink = RGB(1, 0.5, 0.8)
        public static let orange = RGB(1, 0.65, 0.2)
        public static let gray = RGB(0.5, 0.5, 0.5)
        /// The colours a host offers as swatches.
        public static let swatches: [RGB] = [.white, .yellow, .cyan, .green, .pink, .orange, .gray, .black]
    }

    public enum Weight: String, Codable, CaseIterable, Sendable {
        case regular, medium, semibold, bold
        var swiftUI: Font.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    public enum Design: String, Codable, CaseIterable, Sendable {
        case standard, serif, rounded, monospaced
        var swiftUI: Font.Design {
            switch self {
            case .standard: .default
            case .serif: .serif
            case .rounded: .rounded
            case .monospaced: .monospaced
            }
        }
    }

    public enum Edge: String, Codable, CaseIterable, Sendable {
        case none, dropShadow, outline
    }

    /// Text size relative to the standard (a twentieth of the picture's height).
    public var sizeScale: Double = 1
    public var weight: Weight = .semibold
    public var design: Design = .standard
    public var textColor: RGB = .white
    public var textOpacity: Double = 1
    public var backgroundColor: RGB = .black
    /// 0 draws no plate.
    public var backgroundOpacity: Double = 0.6
    public var edge: Edge = .none
    public var edgeColor: RGB = .black
    /// How far from the picture's edge the text sits, relative to the
    /// standard margin (a twentieth of the picture's height).
    public var marginScale: Double = 1

    public static let standard = RAVESubtitleStyle()
    public static let sizeRange: ClosedRange<Double> = 0.5 ... 2.5
    public static let marginRange: ClosedRange<Double> = 0 ... 4

    public init() {}

    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let style = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = style
    }

    public var json: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // Decoding tolerates fields a later version adds or an earlier one lacks.
    private enum CodingKeys: String, CodingKey {
        case sizeScale, weight, design, textColor, textOpacity, backgroundColor, backgroundOpacity
        case edge, edgeColor, marginScale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        sizeScale = Self.sizeRange.clamp(try c.decodeIfPresent(Double.self, forKey: .sizeScale) ?? d.sizeScale)
        weight = try c.decodeIfPresent(Weight.self, forKey: .weight) ?? d.weight
        design = try c.decodeIfPresent(Design.self, forKey: .design) ?? d.design
        textColor = try c.decodeIfPresent(RGB.self, forKey: .textColor) ?? d.textColor
        textOpacity = min(max(try c.decodeIfPresent(Double.self, forKey: .textOpacity) ?? d.textOpacity, 0.1), 1)
        backgroundColor = try c.decodeIfPresent(RGB.self, forKey: .backgroundColor) ?? d.backgroundColor
        backgroundOpacity = min(max(try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? d.backgroundOpacity, 0), 1)
        edge = try c.decodeIfPresent(Edge.self, forKey: .edge) ?? d.edge
        edgeColor = try c.decodeIfPresent(RGB.self, forKey: .edgeColor) ?? d.edgeColor
        marginScale = Self.marginRange.clamp(try c.decodeIfPresent(Double.self, forKey: .marginScale) ?? d.marginScale)
    }
}

private extension ClosedRange where Bound == Double {
    func clamp(_ value: Double) -> Double { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

private struct RAVESubtitleStyleKey: EnvironmentKey {
    static let defaultValue = RAVESubtitleStyle.standard
}

public extension EnvironmentValues {
    /// The look text subtitles are drawn in below this view.
    var raveSubtitleStyle: RAVESubtitleStyle {
        get { self[RAVESubtitleStyleKey.self] }
        set { self[RAVESubtitleStyleKey.self] = newValue }
    }
}

extension RAVESubtitleStyle {
    /// `view` with this style's edge drawn around it.
    @ViewBuilder
    func edged<V: View>(_ view: V, fontSize: CGFloat) -> some View {
        switch edge {
        case .none:
            view
        case .dropShadow:
            view.shadow(color: edgeColor.color.opacity(0.9), radius: fontSize * 0.08, x: 0, y: fontSize * 0.05)
        case .outline:
            let r = max(fontSize * 0.035, 0.75)
            view
                .shadow(color: edgeColor.color, radius: 0, x: r, y: 0)
                .shadow(color: edgeColor.color, radius: 0, x: -r, y: 0)
                .shadow(color: edgeColor.color, radius: 0, x: 0, y: r)
                .shadow(color: edgeColor.color, radius: 0, x: 0, y: -r)
        }
    }
}
#endif
