/*
 RAVESupport - Relief

 The support art's depth on visionOS: the picture on a grid mesh pushed toward
 the viewer by its depth map, laid over the flat PNG. A trimmed copy of
 RAVEMedia's `RAVEAIDepthPhotoView` and `RAVEDepthMesh` (as of 1443a4e), kept
 here so RAVESupport needs neither RAVEMedia nor the vergence checkout RAVEMedia
 builds on: Apparition links RAVESupport and builds its releases without
 vergence. Only what the art uses is kept: one picture, byte depth, no colour
 adjustments, corner radius, flip or fade.

 The rules found on device (Hypnos's 3D Depth thumbnails, 2026-10-07) are the
 same as there, so a fix to one belongs in the other: clamp the texture (the
 default repeat pulled the opposite edge in as a 1-px line), soften the depth
 (a hard step lands on the grid as a staircase), fade it to zero at the edges
 (or the outline projects past itself off-axis), and keep 1 pt off the window
 plane (coplanar with anything there, it z-fights). A RealityView takes input
 even with `allowsHitTesting(false)`, so the art is never a tap target.
 */

#if os(visionOS)
import Accelerate
import RealityKit
import SwiftUI

/// A depth map as the relief reads it: 0…255 per pixel, row-major, near = 255.
struct RAVESupportDepthMap: Sendable {
    let width: Int
    let height: Int
    let values: [UInt8]
}

struct RAVESupportReliefView: View {
    let image: CGImage
    let depth: RAVESupportDepthMap
    /// Changes when the picture does. The mesh is rebuilt for a new one.
    let contentID: AnyHashable
    var onReady: (Bool) -> Void = { _ in }

    /// Deepest the nearest content gets, in points.
    nonisolated static let maxSpan: CGFloat = 64

    @Environment(\.physicalMetrics) private var metrics
    @State private var root = Entity()
    @State private var builtWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            RealityView { content in
                root.components.set(OpacityComponent(opacity: 0))
                content.add(root)
            } update: { _ in
                let scale = builtWidth > 0 ? Float(size.width / builtWidth) : 1
                root.scale = SIMD3(scale, scale, scale)
            }
            .task(id: BuildKey(content: contentID, sizeBucket: Self.sizeBucket(size))) {
                await build(size: size)
            }
        }
        .allowsHitTesting(false)
    }

    private struct BuildKey: Hashable {
        let content: AnyHashable
        let sizeBucket: Int
    }

    /// Steps of ~30% in width: a resize within one step only rescales.
    private static func sizeBucket(_ size: CGSize) -> Int {
        guard size.width > 1 else { return 0 }
        return Int((log(size.width) / log(1.3)).rounded())
    }

    /// Depth scales with the picture: 8% of its short side, so a small one
    /// isn't all relief and a large one isn't flat.
    nonisolated static func shape(for size: CGSize) -> Shape {
        let shortSide = min(size.width, size.height)
        return Shape(span: min(max(shortSide * 0.08, 24), maxSpan), edgeFalloff: min(max(shortSide * 0.02, 10), 24), gridLongSide: 192)
    }

    private func build(size: CGSize) async {
        guard size.width > 1, size.height > 1 else { return }
        let shape = Self.shape(for: size)
        let widthMeters = Float(metrics.convert(size.width, to: .meters))
        let heightMeters = Float(metrics.convert(size.height, to: .meters))
        let spanMeters = Float(metrics.convert(shape.span, to: .meters))
        let image = self.image, depth = self.depth
        let built = await Task.detached(priority: .userInitiated) { () -> Built? in
            let crop = Self.fillCrop(imageWidth: CGFloat(image.width), imageHeight: CGFloat(image.height), cell: size)
            guard let texture = Self.renderTexture(image, crop: crop, cell: size, maxPixels: 2560) else { return nil }
            let mesh = Self.meshDescriptor(depth: depth, crop: crop, cell: size, shape: shape,
                                           widthMeters: widthMeters, heightMeters: heightMeters, spanMeters: spanMeters)
            return Built(texture: texture, mesh: mesh)
        }.value
        guard !Task.isCancelled, let built, let model = await Self.makeModel(texture: built.texture, mesh: built.mesh),
              !Task.isCancelled else { return }
        // Swapped in place, so a rebuild at a new size never shows an empty frame.
        root.children.removeAll()
        root.addChild(model)
        builtWidth = size.width
        root.components.set(OpacityComponent(opacity: 1))
        onReady(true)
    }

    /// Built off the main actor, handed back once. `MeshDescriptor` isn't
    /// `Sendable`, but nothing touches it after the hand-off.
    private struct Built: @unchecked Sendable {
        let texture: CGImage
        let mesh: MeshDescriptor
    }

    // MARK: - The mesh and its texture (RAVEMedia's RAVEDepthMesh)

    /// How the picture is displaced, in points.
    struct Shape: Sendable {
        /// Displacement of the nearest content.
        var span: CGFloat
        /// Depth falls to zero over this distance from each edge, so the
        /// outline stays on the window plane.
        var edgeFalloff: CGFloat
        /// Vertices along the long edge.
        var gridLongSide: Int
    }

    /// The image-normalized rect a `scaledToFill` cell shows.
    nonisolated static func fillCrop(imageWidth: CGFloat, imageHeight: CGFloat, cell: CGSize) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let imageAspect = imageWidth / imageHeight
        let cellAspect = cell.width / cell.height
        if imageAspect > cellAspect {
            let w = cellAspect / imageAspect
            return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        } else {
            let h = imageAspect / cellAspect
            return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
    }

    /// The visible crop with its alpha kept, at up to 2 px per point and
    /// `maxPixels` on the long edge.
    nonisolated static func renderTexture(_ image: CGImage, crop: CGRect, cell: CGSize, maxPixels: CGFloat) -> CGImage? {
        let scale = min(2, maxPixels / max(cell.width, cell.height))
        let width = max(Int((cell.width * scale).rounded()), 1)
        let height = max(Int((cell.height * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        // Draw the whole image so the crop lands on the context bounds.
        let drawWidth = CGFloat(width) / crop.width
        let drawHeight = CGFloat(height) / crop.height
        // CG's origin is bottom-left; the crop's y is from the top.
        context.draw(image, in: CGRect(x: -crop.minX * drawWidth, y: -(1 - crop.maxY) * drawHeight, width: drawWidth, height: drawHeight))
        return context.makeImage()
    }

    /// The textured, displaced mesh as one entity, its texture clamped to the
    /// edge (the default repeat let the top row's filtering pull in the
    /// bottom row).
    @MainActor
    static func makeModel(texture: CGImage, mesh descriptor: MeshDescriptor) async -> ModelEntity? {
        guard let mesh = try? await MeshResource(from: [descriptor]),
              let resource = try? await TextureResource(image: texture, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
        else { return nil }
        let sampler = MTLSamplerDescriptor()
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.mipFilter = .linear
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: MaterialParameters.Texture(resource, sampler: .init(sampler)))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        material.faceCulling = .none
        return ModelEntity(mesh: mesh, materials: [material])
    }

    nonisolated static func meshDescriptor(
        depth: RAVESupportDepthMap, crop: CGRect, cell: CGSize, shape: Shape,
        widthMeters: Float, heightMeters: Float, spanMeters: Float
    ) -> MeshDescriptor {
        // Softened first: a hard depth step lands on the vertex grid as a
        // staircase along the subject's outline. Spread over a few texels, it
        // reads as a slope at any grid density.
        let depth = softened(depth)
        let longSide = shape.gridLongSide
        let cols = cell.width >= cell.height ? longSide : max(Int((CGFloat(longSide) * cell.width / cell.height).rounded()), 2)
        let rows = cell.height > cell.width ? longSide : max(Int((CGFloat(longSide) * cell.height / cell.width).rounded()), 2)

        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity(cols * rows)
        uvs.reserveCapacity(cols * rows)
        let falloff = Float(shape.edgeFalloff)
        // 1 pt off the window plane: coplanar with what's drawn there, the two z-fight.
        let baseMeters = spanMeters / Float(shape.span)
        for j in 0..<rows {
            let v = Float(j) / Float(rows - 1) // 0 at the top
            for i in 0..<cols {
                let u = Float(i) / Float(cols - 1)
                // Distance to the nearest edge, in points.
                let edge = min(min(u, 1 - u) * Float(cell.width), min(v, 1 - v) * Float(cell.height))
                let t = min(max(edge / falloff, 0), 1)
                let fade = t * t * (3 - 2 * t)
                let d = sample(depth, u: Float(crop.minX) + u * Float(crop.width), v: Float(crop.minY) + v * Float(crop.height))
                positions.append(SIMD3((u - 0.5) * widthMeters, (0.5 - v) * heightMeters, baseMeters + d * fade * spanMeters))
                uvs.append(SIMD2(u, 1 - v))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity((cols - 1) * (rows - 1) * 6)
        for j in 0..<(rows - 1) {
            for i in 0..<(cols - 1) {
                let a = UInt32(j * cols + i)
                let b = a + 1
                let c = a + UInt32(cols)
                let d = c + 1
                // Counter-clockwise seen from the front (+z).
                indices += [a, c, b, b, c, d]
            }
        }

        var descriptor = MeshDescriptor(name: "supportRelief")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }

    /// Tent blur over ~1% of the map's long edge (odd kernel, edges extended).
    nonisolated private static func softened(_ map: RAVESupportDepthMap) -> RAVESupportDepthMap {
        let kernel = max(max(map.width, map.height) / 100 * 2 + 1, 3)
        var source = map.values
        var output = [UInt8](repeating: 0, count: source.count)
        let error = source.withUnsafeMutableBytes { src in
            output.withUnsafeMutableBytes { dst in
                var srcBuffer = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(map.height),
                                              width: vImagePixelCount(map.width), rowBytes: map.width)
                var dstBuffer = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(map.height),
                                              width: vImagePixelCount(map.width), rowBytes: map.width)
                return vImageTentConvolve_Planar8(&srcBuffer, &dstBuffer, nil, 0, 0,
                                                  UInt32(kernel), UInt32(kernel), 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        guard error == kvImageNoError else { return map }
        return RAVESupportDepthMap(width: map.width, height: map.height, values: output)
    }

    /// Bilinear sample of the 0…255 map at image-normalized (u, v); 0…1, near = 1.
    nonisolated private static func sample(_ map: RAVESupportDepthMap, u: Float, v: Float) -> Float {
        let x = min(max(u * Float(map.width - 1), 0), Float(map.width - 1))
        let y = min(max(v * Float(map.height - 1), 0), Float(map.height - 1))
        let x0 = Int(x), y0 = Int(y)
        let x1 = min(x0 + 1, map.width - 1), y1 = min(y0 + 1, map.height - 1)
        let fx = x - Float(x0), fy = y - Float(y0)
        func at(_ x: Int, _ y: Int) -> Float { Float(map.values[y * map.width + x]) / 255 }
        let top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx
        let bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }
}
#endif
