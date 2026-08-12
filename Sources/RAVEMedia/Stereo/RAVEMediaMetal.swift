/*
 RAVEMedia - Metal context and stereo warp resources.

 One place that owns the device, the package's shader library, and every GPU
 object the pseudo-3D pipeline builds once and reuses forever (pipeline states,
 the depth-test state, the two warp grids).

 **On sharing a device with the host app.** This creates its own
 `MTLCreateSystemDefaultDevice()` rather than taking one by injection. That is
 safe, not sloppy: on every Apple platform the call returns the one system
 default device object, so a texture the app makes and a pipeline this package
 builds are on the same device by construction. Injection would have to thread
 a device through seven files and two singletons to arrive at the same object.

 The command queue is deliberately *not* shared with anything: `StereoPump`
 makes its own, because per-frame warp work must never queue behind the app's
 image uploads.
 */

import Metal
import os

/// Device + shader library for everything in RAVEMedia that touches the GPU.
public final class RAVEMediaMetal: Sendable {
    /// `nil` only on a device with no Metal support (the simulator's software
    /// renderer included) or if the package's shader library failed to load —
    /// callers treat that the same as "fake-3D unavailable".
    public static let shared = RAVEMediaMetal()

    public let device: MTLDevice
    /// The package's own default library, compiled from
    /// `Resources/RAVEStereoShaders.metal`. Distinct from the app's — a
    /// `makeDefaultLibrary()` with no bundle would find the app's functions and
    /// none of ours.
    public let library: MTLLibrary

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let bundle = Self.resourceBundle,
              let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            return nil
        }
        self.device = device
        self.library = library
    }

    /// The package's resource bundle, found by hand rather than through
    /// `Bundle.module`.
    ///
    /// `Bundle.module` only exists when SwiftPM synthesises it, and SwiftPM
    /// only does that for *declared* resources. A `.metal` file is neither: the
    /// SwiftPM CLI ignores it entirely (so `swift build` cannot resolve
    /// `.module` at all and the whole package stops compiling on the test host),
    /// while Xcode compiles it into `default.metallib` inside a bundle it names
    /// after the package and target. Locating that bundle ourselves is what the
    /// synthesised accessor does anyway, and it lets the same source build both
    /// ways — the CLI simply finds nothing and every caller degrades to
    /// "fake-3D unavailable", which on a Mac test host is the truth.
    private static let resourceBundle: Bundle? = {
        let name = "RAVESDK_RAVEMedia.bundle"
        let candidates = [
            Bundle.main.resourceURL,                      // package linked into an app
            Bundle(for: BundleToken.self).resourceURL,     // …or into a framework
            Bundle.main.bundleURL,
        ]
        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(name),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }()

    private final class BundleToken {}

    /// Compute pipeline for one of the package's kernels, or nil if the
    /// function is missing (a shader that failed to compile).
    public func computePipeline(_ function: String) -> MTLComputePipelineState? {
        guard let fn = library.makeFunction(name: function) else { return nil }
        return try? device.makeComputePipelineState(function: fn)
    }
}

/// The render pipelines and geometry the per-eye warp needs. Built once; every
/// `StereoPump` shares them.
public final class RAVEStereoWarpResources: Sendable {
    /// `nil` when Metal or the shader library is unavailable, which callers
    /// treat as "fake-3D unavailable" rather than an error.
    public static let shared = RAVEStereoWarpResources()

    public let device: MTLDevice
    /// Per-pixel backward warp (heuristic fallback; the real-depth path always
    /// takes the mesh pipeline).
    public let eyePipelineState: MTLRenderPipelineState
    /// Depth-displaced mesh pipeline (occlusion-correct, used whenever a real
    /// depth map is available). Renders into bgra8 with a depth attachment,
    /// multisampled at `msaaSampleCount` and resolved into the eye buffer.
    public let meshPipelineState: MTLRenderPipelineState
    /// Depth-test state for the mesh pipeline (nearer geometry wins).
    public let meshDepthState: MTLDepthStencilState
    /// Mesh-pass multisample count. The displaced mesh's occlusion boundaries
    /// (near geometry covering far after displacement) are rasterized edges with
    /// no texture-side AA — without MSAA they stairstep, worst on crisp CG
    /// silhouettes. 4× is effectively free on Apple TBDR tile memory.
    public let msaaSampleCount: Int

    /// Fake-3D warp grid density (vertices per axis). Two densities:
    /// - Moderate (193×109): realtime depth. Denser grids rendered the model's
    ///   high-frequency depth detail as visible per-vertex wobble, so the live
    ///   (gaussian-stabilized but unrefined) path stays moderate.
    /// - Dense (769×433): cached depth. Pre-processed depth is edge-aware
    ///   (joint-bilateral) + lookahead-smoothed, so the wobble objection doesn't
    ///   apply — and a coarse grid's cell pitch quantizes sharp depth edges into
    ///   visible stairsteps along smooth silhouettes (per-grid-row steps, worst
    ///   on CG content at high strength). 769 columns oversample the 518-wide
    ///   depth map (~0.67 texel/cell), so the grid stops being the limiter and
    ///   silhouettes are bounded by the depth map's own (bilinear-smoothed)
    ///   resolution. ~333k verts/eye at 60fps is trivial vertex load on Apple
    ///   Silicon. (385×217 still stepped visibly at 1080p on Blender renders.)
    public static let gridColumns = 193
    public static let gridRows = 109
    public static let denseGridColumns = 769
    public static let denseGridRows = 433

    /// Shared grid geometry for the mesh warp ([0,1] positions + triangle
    /// indices). `MTLBuffer` isn't declared Sendable (unlike the pipeline/device
    /// types), but these are immutable thread-safe GPU resource handles.
    public nonisolated(unsafe) let gridPositions: MTLBuffer
    public nonisolated(unsafe) let gridIndices: MTLBuffer
    public let gridIndexCount: Int
    public nonisolated(unsafe) let denseGridPositions: MTLBuffer
    public nonisolated(unsafe) let denseGridIndices: MTLBuffer
    public let denseGridIndexCount: Int

    private init?() {
        guard let metal = RAVEMediaMetal.shared else { return nil }
        let device = metal.device
        let library = metal.library
        self.device = device

        guard let vertexFunction = library.makeFunction(name: "stereoQuadVertex"),
              let stereoEyeFn = library.makeFunction(name: "videoPseudo3DEyeFragmentShader"),
              let meshVertexFn = library.makeFunction(name: "videoStereoMeshVertex"),
              let meshFragmentFn = library.makeFunction(name: "videoStereoMeshFragment"),
              let meshDepthState = device.makeDepthStencilState(descriptor: {
                  let d = MTLDepthStencilDescriptor()
                  // lessEqual, not less: the farthest geometry (sky) sits at
                  // ndcZ == 1.0 == the cleared far value; `.less` would reject it
                  // (1.0 < 1.0 is false), dropping sky fragments to the black
                  // clear — speckled differently per eye → binocular rivalry.
                  d.depthCompareFunction = .lessEqual
                  d.isDepthWriteEnabled = true
                  return d
              }()) else {
            return nil
        }
        self.meshDepthState = meshDepthState

        // Build both displaced-grid geometries once (see the density rationale
        // on the constants above). Vertex cost is trivial either way.
        guard let moderate = Self.makeWarpGrid(
            nx: Self.gridColumns, ny: Self.gridRows, device: device
        ), let dense = Self.makeWarpGrid(
            nx: Self.denseGridColumns, ny: Self.denseGridRows, device: device
        ) else {
            return nil
        }
        self.gridPositions = moderate.positions
        self.gridIndices = moderate.indices
        self.gridIndexCount = moderate.indexCount
        self.denseGridPositions = dense.positions
        self.denseGridIndices = dense.indices
        self.denseGridIndexCount = dense.indexCount

        do {
            // Pseudo-3D eye warp: opaque write into a bgra8 IOSurface-backed eye
            // texture (no blending — each eye is a full opaque frame).
            let stereoDesc = MTLRenderPipelineDescriptor()
            stereoDesc.vertexFunction = vertexFunction
            stereoDesc.fragmentFunction = stereoEyeFn
            stereoDesc.colorAttachments[0].isBlendingEnabled = false
            stereoDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.eyePipelineState = try device.makeRenderPipelineState(descriptor: stereoDesc)

            // Depth-displaced mesh pipeline: opaque bgra8 color + depth
            // attachment, multisampled (resolved into the eye buffer by the
            // render pass).
            let msaa = device.supportsTextureSampleCount(4) ? 4 : 1
            self.msaaSampleCount = msaa
            let meshDesc = MTLRenderPipelineDescriptor()
            meshDesc.vertexFunction = meshVertexFn
            meshDesc.fragmentFunction = meshFragmentFn
            meshDesc.colorAttachments[0].isBlendingEnabled = false
            meshDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            meshDesc.depthAttachmentPixelFormat = .depth32Float
            meshDesc.rasterSampleCount = msaa
            self.meshPipelineState = try device.makeRenderPipelineState(descriptor: meshDesc)
        } catch {
            return nil
        }
    }

    /// Build one fake-3D warp grid: [0,1]² positions row-major, two triangles
    /// per cell.
    private static func makeWarpGrid(
        nx: Int, ny: Int, device: MTLDevice
    ) -> (positions: MTLBuffer, indices: MTLBuffer, indexCount: Int)? {
        var gridPositions = [SIMD2<Float>](); gridPositions.reserveCapacity(nx * ny)
        for j in 0..<ny {
            for i in 0..<nx {
                gridPositions.append(SIMD2(Float(i) / Float(nx - 1), Float(j) / Float(ny - 1)))
            }
        }
        var gridIndices = [UInt32](); gridIndices.reserveCapacity((nx - 1) * (ny - 1) * 6)
        for j in 0..<(ny - 1) {
            for i in 0..<(nx - 1) {
                let a = UInt32(j * nx + i), b = a + 1
                let c = UInt32((j + 1) * nx + i), d = c + 1
                gridIndices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        guard let posBuf = device.makeBuffer(bytes: gridPositions, length: gridPositions.count * MemoryLayout<SIMD2<Float>>.stride),
              let idxBuf = device.makeBuffer(bytes: gridIndices, length: gridIndices.count * MemoryLayout<UInt32>.stride) else {
            return nil
        }
        return (posBuf, idxBuf, gridIndices.count)
    }
}
