/*
 RAVEDeviceSetup - the QR code, drawn and read back

 Drawing is Core Image's QR generator, available everywhere including tvOS.
 Reading is Vision's barcode detector over an image the user picked, which
 is what lets a sender avoid camera and photo-library permissions (see
 `RAVESetupScanPhotoButton`).
 */

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import SwiftUI
import Vision

public enum RAVESetupQRCode {
    /// The code as a bitmap, one pixel per module plus a four-module quiet
    /// zone, black on white. Scale it up with `.interpolation(.none)`.
    public static func cgImage(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let modules = filter.outputImage else { return nil }
        let quiet: CGFloat = 4
        let padded = modules
            .transformed(by: CGAffineTransform(translationX: quiet, y: quiet))
            .composited(over: CIImage(color: .white))
            .cropped(to: modules.extent.insetBy(dx: -quiet, dy: -quiet).offsetBy(dx: quiet, dy: quiet))
        return CIContext().createCGImage(padded, from: padded.extent)
    }

    /// Every setup code for `service` found in an image's bytes (any format
    /// Image I/O reads, HEIC photos included).
    public static func codes(inImageData data: Data, service: RAVESetupService) -> [RAVESetupCode] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return [] }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? UInt32
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up)
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            observation.payloadStringValue.flatMap(URL.init(string:)).flatMap { RAVESetupCode(url: $0, service: service) }
        }
    }
}

/// The receiver's QR code, sharp at any size.
public struct RAVESetupQRCodeView: View {
    private let image: CGImage?

    public init(code: RAVESetupCode) {
        image = RAVESetupQRCode.cgImage(for: code.url)
    }

    public var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
        }
    }
}
