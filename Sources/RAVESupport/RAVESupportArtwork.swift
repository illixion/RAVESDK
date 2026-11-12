import SwiftUI
#if os(visionOS)
import CoreGraphics
import ImageIO
#endif

/// The PNG owns the layout and fallback. Only visionOS loads the optional
/// depth raster, through RAVESupport's own copy of the transparent
/// relief-photo renderer (`RAVESupportReliefView`), so it needs no RAVEMedia.
struct RAVESupportArtwork: View {
    let pose: RAVESupportPose
    var maxHeight: CGFloat = 220
    /// Fixes the picture at `maxHeight` and its own aspect's width, for a row where nothing
    /// proposes it a width (the wide sheets).
    var fixedSize = false
    #if os(visionOS)
    @State private var spatial: Artwork?
    @State private var spatialReady = false
    #endif

    var body: some View {
        if let image = pose.image {
            image.resizable().scaledToFit()
                .frame(width: fixedSize ? pose.aspectRatio.map { $0 * maxHeight } : nil,
                       height: fixedSize ? maxHeight : nil)
                .frame(maxHeight: maxHeight)
                #if os(visionOS)
                .opacity(spatialReady ? 0 : 1)
                .overlay {
                    if let spatial {
                        RAVESupportReliefView(image: spatial.image, depth: spatial.depth, contentID: pose.rawValue,
                                              onReady: { spatialReady = $0 })
                            .allowsHitTesting(false)
                    }
                }
                .task(id: pose) {
                    spatial = nil
                    spatialReady = false
                    guard let colourURL = pose.url, let depthURL = pose.depthURL else { return }
                    spatial = await Task.detached(priority: .utility) {
                        Artwork.load(colour: colourURL, depth: depthURL)
                    }.value
                }
                #endif
        }
    }

    #if os(visionOS)
    private struct Artwork: @unchecked Sendable {
        let image: CGImage
        let depth: RAVESupportDepthMap

        static func load(colour: URL, depth: URL) -> Artwork? {
            guard let colourSource = CGImageSourceCreateWithURL(colour as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(colourSource, 0, nil),
                  let depthSource = CGImageSourceCreateWithURL(depth as CFURL, nil),
                  let map = CGImageSourceCreateImageAtIndex(depthSource, 0, nil),
                  let values = RAVESupportDepthRaster.samples(map, width: image.width, height: image.height),
                  let alpha = RAVESupportDepthRaster.alpha(image) else { return nil }
            // Bytes, not normalized floats: the relief mesh softens a byte map before building,
            // which hides the steps a stretched 8-bit map has.
            let stretched = RAVESupportDepthRaster.stretched(values, alpha: alpha, width: image.width, height: image.height)
            return Artwork(image: image, depth: RAVESupportDepthMap(width: map.width, height: map.height, values: stretched))
        }
    }
    #endif
}
