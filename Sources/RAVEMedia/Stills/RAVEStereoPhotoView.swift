#if os(visionOS)
import CoreImage
import ImageIO
import Observation
import Metal
import RealityKit
import SwiftUI
import UniformTypeIdentifiers
import VergenceApple
import VergenceCore

/// A still presented in stereo: both warped eyes on one plane, through a
/// Shader Graph material whose Camera Index Switch gives each eye its own
/// texture (`StereoStillMaterial`). The flat sizing/fallback layer is owned
/// by the caller; `onReady` tells it when to yield to the stereo plane,
/// including after navigation or failure.
///
/// Not `VideoPlayerComponent` (until 2026-11-02): its HLG rendering muted
/// HDR highlights the flat view shows, and its PQ rendering tone mapped to
/// the declared peak. A RealityKit unlit material with a half-float
/// `.hdrColor` texture showed the HDR test dots exactly as the flat EDR view
/// did, step for step past SDR white (device, `photoHDRTest flipRK`), so the
/// eyes are textures now and SDR white is the window's own white by
/// construction, with no transfer-function tagging to tune.
public struct RAVEStereoPhotoView: View {
    /// The image is on the window surface, so input needn't sit 64 pt forward
    /// as it did for the old relief mesh.
    public nonisolated static let inputTargetZ: CGFloat = 4
    let image: CGImage
    let depth: StillDepthMap
    let contentID: AnyHashable
    var adjustments: RAVEAIDepthPhotoView.Adjustments
    var cornerRadius: CGFloat
    var isFlipped: Bool
    var opacity: Double
    var fadeDuration: TimeInterval
    /// Brightest value in `image`, in multiples of SDR white (an HDR still the
    /// host has tone mapped to the display's headroom). The textures carry the
    /// values as they are; this only keys a rebuild when the source changes.
    var headroom: Float
    var onReady: (Bool) -> Void
    /// Debug A/B only until the disconnected renderer is checked on device.
    @AppStorage("aiPhotoSeparateBoundaries") private var separatesBoundaries = false
    @State private var presentation = Presentation()
    @Environment(\.physicalMetrics) private var metrics
    @Environment(\.scenePhase) private var scenePhase

    public init(image: CGImage, depth: StillDepthMap, contentID: AnyHashable,
                adjustments: RAVEAIDepthPhotoView.Adjustments = .neutral,
                cornerRadius: CGFloat = 0, isFlipped: Bool = false, opacity: Double = 1, fadeDuration: TimeInterval = 0.25,
                headroom: Float = 1, onReady: @escaping (Bool) -> Void = { _ in }) {
        self.image = image; self.depth = depth; self.contentID = contentID
        self.adjustments = adjustments; self.cornerRadius = cornerRadius
        self.isFlipped = isFlipped; self.opacity = opacity; self.fadeDuration = fadeDuration
        self.headroom = headroom; self.onReady = onReady
    }

    public var body: some View {
        GeometryReader { geometry in
            let widthMeters = Float(metrics.convert(geometry.size.width, to: .meters))
            let strength = Float(Pseudo3DSettings.default.depthStrength) / max(widthMeters, 1)
            // The mesh is aspect × 1 (scaled to the view's height), so the corner
            // radius is a fraction of the height.
            let corner = geometry.size.height > 1 ? Float(cornerRadius / geometry.size.height) : 0
            let key = Key(content: contentID, image: ObjectIdentifier(image), depth: depth.id, adjustments: adjustments,
                          strength: Int((strength * 100_000).rounded()), boundaries: separatesBoundaries, mirror: isFlipped,
                          headroom: Int((headroom * 100).rounded()))
            FadingPlane(entity: presentation.entity,
                aspect: Float(image.width) / Float(image.height),
                opacity: Float(opacity))
                .animation(.easeInOut(duration: fadeDuration), value: opacity)
                .task(id: key) {
                    if presentation.matches(key), presentation.ready {
                        presentation.setCorner(corner)
                        onReady(true)
                        return
                    }
                    if !presentation.ready { onReady(false) }
                    // Coalesce slider and window-size changes. A prepared picture
                    // stays visible while a replacement is built.
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    await presentation.load(image: image, depth: depth, adjustments: adjustments,
                                            strength: strength, separatesBoundaries: separatesBoundaries, mirror: isFlipped,
                                            corner: corner, key: key, onReady: onReady)
                }
                .onChange(of: corner) { _, value in presentation.setCorner(value) }
        }
        .allowsHitTesting(false)
    }

    /// Numeric render diagnostics for the host's debug surface (no pixels).
    public static func diagnosticState() -> [[String: String]] {
        Presentation.live.allObjects.map { p in
            let b = p.entity.visualBounds(relativeTo: nil)
            return ["ready": String(p.ready),
                    "eyeWidth": String(Int(p.eyeSize.width)), "eyeHeight": String(Int(p.eyeSize.height)),
                    "corner": String(p.corner),
                    "componentOpacity": String(p.entity.components[OpacityComponent.self]?.opacity ?? -1),
                    "scale": String(describing: p.entity.scale),
                    "position": String(describing: p.entity.position),
                    "boundsCenter": String(describing: b.center),
                    "boundsExtents": String(describing: b.extents)]
        }
    }

    /// OpacityComponent isn't driven by SwiftUI's opacity modifier. An
    /// animatable value feeds it on every transition step instead.
    nonisolated private struct FadingPlane: View, Animatable {
        let entity: Entity
        let aspect: Float
        var opacity: Float
        var animatableData: Float {
            get { opacity }
            set { opacity = newValue }
        }
        @MainActor var body: some View {
            // The mesh draws its own corners (square ones included), so no overscan.
            RAVEVideoPlaneView(entity: entity, aspect: aspect, squareCorners: false,
                              opacity: opacity, takesInput: false, placement: .windowSurface)
        }
    }

    fileprivate struct Key: Hashable {
        let content: AnyHashable
        let image: ObjectIdentifier
        let depth: UUID
        let adjustments: RAVEAIDepthPhotoView.Adjustments
        let strength: Int
        let boundaries: Bool
        let mirror: Bool
        let headroom: Int
    }

    @MainActor @Observable fileprivate final class Presentation {
        static let live = NSHashTable<RAVEStereoPhotoView.Presentation>.weakObjects()
        /// What `RAVEVideoPlaneView` places and scales; the eye plane is its child.
        let entity = Entity()
        @ObservationIgnored private let plane = ModelEntity()
        var ready = false
        @ObservationIgnored private(set) var eyeSize = CGSize.zero
        @ObservationIgnored private(set) var corner: Float = 0
        @ObservationIgnored private var aspect: Float = 1
        @ObservationIgnored private var material: ShaderGraphMaterial?
        private var generation = 0
        @ObservationIgnored private var cachedKey: RAVEStereoPhotoView.Key?

        init() {
            entity.addChild(plane)
        }

        func matches(_ key: RAVEStereoPhotoView.Key) -> Bool { cachedKey == key && material != nil }

        /// A new corner radius rebuilds the mesh only; the textures stay.
        func setCorner(_ value: Float) {
            guard abs(value - corner) > 0.0005 else { return }
            corner = value
            guard material != nil else { return }
            plane.model?.mesh = Self.mesh(aspect: aspect, corner: corner)
        }

        private static func mesh(aspect: Float, corner: Float) -> MeshResource {
            .generatePlane(width: aspect, height: 1, cornerRadius: max(0, min(corner, 0.5)))
        }

        func load(image: CGImage, depth: StillDepthMap, adjustments: RAVEAIDepthPhotoView.Adjustments,
                  strength: Float, separatesBoundaries: Bool, mirror: Bool, corner: Float,
                  key: RAVEStereoPhotoView.Key, onReady: @escaping (Bool) -> Void) async {
            Self.live.add(self)
            generation += 1
            let token = generation
            do {
                let eyes = try await RAVEStereoPhotoView.Worker.shared.prepareStill(image: image, depth: depth,
                    adjustments: adjustments, strength: strength, separatesBoundaries: separatesBoundaries, mirror: mirror)
                guard !Task.isCancelled, token == generation else { return }
                let options = TextureResource.CreateOptions(semantic: .hdrColor)
                let left = try await TextureResource(image: eyes.left, options: options)
                let right = try await TextureResource(image: eyes.right, options: options)
                var material = try await StereoStillMaterial.template()
                try material.setParameter(name: StereoStillMaterial.leftParameter, value: .textureResource(left))
                try material.setParameter(name: StereoStillMaterial.rightParameter, value: .textureResource(right))
                guard !Task.isCancelled, token == generation else { return }
                aspect = Float(image.width) / Float(image.height)
                self.corner = corner
                eyeSize = CGSize(width: eyes.left.width, height: eyes.left.height)
                plane.model = ModelComponent(mesh: Self.mesh(aspect: aspect, corner: corner), materials: [material])
                self.material = material
                cachedKey = key
                ready = true
                onReady(true)
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                ready = false
                cachedKey = nil
                material = nil
                plane.model = nil
                onReady(false)
                RAVEMediaLog.stills.error("Still stereo preparation failed")
            }
        }
    }

    fileprivate struct Eyes: @unchecked Sendable {
        let left: CGImage
        let right: CGImage
    }

    /// One bake at a time across windows: two simultaneous conversions mustn't
    /// multiply the source + eye working set. No work on the main actor.
    private actor Worker {
        static let shared = Worker()
        func prepareStill(image: CGImage, depth: StillDepthMap,
                     adjustments: RAVEAIDepthPhotoView.Adjustments, strength: Float, separatesBoundaries: Bool,
                     mirror: Bool) throws -> RAVEStereoPhotoView.Eyes {
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let engine = StillStereoRenderer() else { throw StillStereoRenderer.Failure.unavailable }
                let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
                let context = CIContext(options: [.workingColorSpace: cs, .cacheIntermediates: false])
                var input = CIImage(cgImage: image)
                let target = StillStereoResolution.longSide(width: image.width, height: image.height,
                    requested: Double(max(image.width, image.height)))
                if target < max(image.width, image.height) {
                    let scale = CGFloat(target) / CGFloat(max(image.width, image.height))
                    input = input.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
                }
                if adjustments.autoEnhance {
                    for filter in input.autoAdjustmentFilters(options: [.enhance: true, .redEye: false]) {
                        filter.setValue(input, forKey: kCIInputImageKey)
                        if let output = filter.outputImage { input = output }
                    }
                }
                input = input.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: adjustments.brightness,
                    kCIInputContrastKey: 1 + (adjustments.contrast - 1) * 0.12,
                    kCIInputSaturationKey: adjustments.saturation])
                guard let source = context.createCGImage(input, from: input.extent, format: .RGBAh, colorSpace: cs) else {
                    throw StillStereoRenderer.Failure.allocation
                }
                let result = try engine.render(image: source, depth: depth, strength: strength, separatesBoundaries: separatesBoundaries, mirror: mirror)
                try Task.checkCancellation()
                // Half-float, extended linear P3: values above 1 (an HDR still's
                // highlights) reach the texture as they are.
                func eye(_ texture: MTLTexture) throws -> CGImage {
                    guard let ci = CIImage(mtlTexture: texture, options: [.colorSpace: result.colorSpace]) else {
                        throw StillStereoRenderer.Failure.allocation
                    }
                    // The warp uses top-left texture UVs; Core Image uses bottom-left.
                    let oriented = ci.transformed(by: CGAffineTransform(translationX: 0,
                        y: CGFloat(texture.height)).scaledBy(x: 1, y: -1))
                    guard let image = context.createCGImage(oriented, from: oriented.extent, format: .RGBAh, colorSpace: cs) else {
                        throw StillStereoRenderer.Failure.allocation
                    }
                    return image
                }
                return RAVEStereoPhotoView.Eyes(left: try eye(result.left), right: try eye(result.right))
            }
        }
    }
}

/// The stereo still's material: two texture parameters and a Camera Index
/// Switch into an unlit surface with RealityKit's tone map off, as Apple's
/// "Displaying a stereoscopic image" sample builds it in Reality Composer Pro.
/// Written out as USDA on first use (with 1-pixel placeholder textures the
/// file needs to load), so the package carries no Reality Composer project.
@MainActor
enum StereoStillMaterial {
    static let leftParameter = "LeftTexture"
    static let rightParameter = "RightTexture"
    private static var loaded: ShaderGraphMaterial?

    static func template() async throws -> ShaderGraphMaterial {
        if let loaded { return loaded }
        let url = try writeFiles()
        let material = try await ShaderGraphMaterial(named: "/Root/StereoStill", from: url)
        loaded = material
        return material
    }

    private static func writeFiles() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RAVEStereoStill", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let placeholder = directory.appendingPathComponent("placeholder.png")
        if !FileManager.default.fileExists(atPath: placeholder.path) {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(placeholder as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        }
        let url = directory.appendingPathComponent("StereoStill.usda")
        try usda.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static let usda = """
    #usda 1.0
    (
        defaultPrim = "Root"
        metersPerUnit = 1
        upAxis = "Y"
    )

    def Xform "Root"
    {
        def Material "StereoStill"
        {
            asset inputs:LeftTexture = @placeholder.png@
            asset inputs:RightTexture = @placeholder.png@
            prepend token outputs:mtlx:surface.connect = </Root/StereoStill/Surface.outputs:out>
            token outputs:realitykit:vertex

            def Shader "Surface"
            {
                uniform token info:id = "ND_realitykit_unlit_surfaceshader"
                bool inputs:applyPostProcessToneMap = false
                color3f inputs:color.connect = </Root/StereoStill/Combine3.outputs:out>
                float inputs:opacity.connect = </Root/StereoStill/Separate4.outputs:outa>
                token outputs:out
            }

            def Shader "LeftImage"
            {
                uniform token info:id = "ND_image_color4"
                asset inputs:file.connect = </Root/StereoStill.inputs:LeftTexture>
                string inputs:uaddressmode = "clamp"
                string inputs:vaddressmode = "clamp"
                color4f outputs:out
            }

            def Shader "RightImage"
            {
                uniform token info:id = "ND_image_color4"
                asset inputs:file.connect = </Root/StereoStill.inputs:RightTexture>
                string inputs:uaddressmode = "clamp"
                string inputs:vaddressmode = "clamp"
                color4f outputs:out
            }

            def Shader "EyeSwitch"
            {
                uniform token info:id = "ND_realitykit_geometry_switch_cameraindex_color4"
                color4f inputs:left.connect = </Root/StereoStill/LeftImage.outputs:out>
                color4f inputs:mono.connect = </Root/StereoStill/LeftImage.outputs:out>
                color4f inputs:right.connect = </Root/StereoStill/RightImage.outputs:out>
                color4f outputs:out
            }

            def Shader "Separate4"
            {
                uniform token info:id = "ND_separate4_color4"
                color4f inputs:in.connect = </Root/StereoStill/EyeSwitch.outputs:out>
                float outputs:outa
                float outputs:outb
                float outputs:outg
                float outputs:outr
            }

            def Shader "Combine3"
            {
                uniform token info:id = "ND_combine3_color3"
                float inputs:in1.connect = </Root/StereoStill/Separate4.outputs:outr>
                float inputs:in2.connect = </Root/StereoStill/Separate4.outputs:outg>
                float inputs:in3.connect = </Root/StereoStill/Separate4.outputs:outb>
                color3f outputs:out
            }
        }
    }
    """
}
#endif
