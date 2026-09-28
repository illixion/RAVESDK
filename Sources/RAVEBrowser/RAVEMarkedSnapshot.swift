//
//  RAVEMarkedSnapshot.swift
//  RAVEBrowser
//
//  Scales a page snapshot to the width a vision model wants and draws each
//  element's box and ref on it — set-of-marks, the trick that lets a model
//  point at things by number instead of by coordinate. Drawn here rather
//  than into the page so nothing flashes up on the screen the user is
//  looking at, and in Core Graphics so it is the same on every platform.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum RAVEMarkedSnapshot {

    /// Distinct, saturated, readable under white text.
    static let palette: [(CGFloat, CGFloat, CGFloat)] = [
        (0.90, 0.10, 0.30), (0.10, 0.45, 0.90), (0.05, 0.60, 0.30),
        (0.85, 0.40, 0.00), (0.55, 0.20, 0.80), (0.00, 0.55, 0.60),
    ]

    /// `image` covers the viewport, whose width in CSS pixels is
    /// `viewportWidth`; mark boxes are in the same CSS pixels.
    public static func jpeg(_ image: CGImage, width: Int, viewportWidth: Double,
                            marks: [RAVEPageElement], quality: Double = 0.75) -> Data? {
        guard let drawn = draw(image, width: width, viewportWidth: viewportWidth, marks: marks) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, drawn,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    public static func draw(_ image: CGImage, width: Int, viewportWidth: Double, marks: [RAVEPageElement]) -> CGImage? {
        let w = max(1, min(width, image.width))
        let h = max(1, Int((Double(image.height) * Double(w) / Double(image.width)).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard !marks.isEmpty, viewportWidth > 0 else { return context.makeImage() }

        // Page coordinates from here on: origin top-left, CSS pixels scaled.
        let scale = CGFloat(Double(w) / viewportWidth)
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let fontSize = max(11, 13 * scale)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        for mark in marks {
            let (r, g, b) = palette[mark.ref % palette.count]
            let color = CGColor(red: r, green: g, blue: b, alpha: 1)
            let box = CGRect(x: mark.x * scale, y: mark.y * scale, width: mark.w * scale, height: mark.h * scale)
                .intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard !box.isNull, box.width > 0, box.height > 0 else { continue }
            context.setStrokeColor(color)
            context.setLineWidth(max(1.5, 2 * scale))
            context.stroke(box.insetBy(dx: 0.5, dy: 0.5))

            let label = NSAttributedString(string: "\(mark.ref)", attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: white,
            ])
            let line = CTLineCreateWithAttributedString(label)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            let pad: CGFloat = 2 * max(1, scale / 1.5)
            let tag = CGSize(width: textWidth + pad * 2, height: ascent + descent + pad)
            // Above the box's top-left corner, or inside it when there is no
            // room above.
            let origin = CGPoint(x: min(box.minX, CGFloat(w) - tag.width),
                                 y: box.minY >= tag.height ? box.minY - tag.height : box.minY)
            context.setFillColor(color)
            context.fill(CGRect(origin: origin, size: tag))
            context.textPosition = CGPoint(x: origin.x + pad, y: origin.y + pad / 2 + ascent)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }
}
