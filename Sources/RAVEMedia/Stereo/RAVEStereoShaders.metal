/*
 RAVEMedia - Stereo Warp and Depth Shaders

 The pseudo-3D half of what used to be Spatial Stash's single Shaders.metal:
 the per-eye warp (backward and depth-displaced-mesh), realtime depth
 stabilization, and the offline conversion kernels. The image-display shaders
 (RCAS, FXAA, tonal) stayed in the app — they serve the photo path and have
 nothing to do with video depth.

 Compiled into the package's own default library, reached via
 `device.makeDefaultLibrary(bundle: .module)`. The app's `makeDefaultLibrary()`
 sees only the app's own functions, so the two never collide.

 `stereoQuadVertex` is the app's `imageVertexShader` carried over verbatim (a
 procedural fullscreen quad, UVs flipped vertically so a Metal top-left origin
 reads a bottom-left-origin source). It is duplicated rather than shared
 because a Metal library cannot span module boundaries; keep the two in sync
 only in the sense that both must keep producing a top-left-origin quad.
 */

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen quad: 6 vertices (2 triangles), no vertex buffer needed.
// Uses vertex_id to generate positions and UVs procedurally.
vertex VertexOut stereoQuadVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[] = {
        float2(-1, -1), // bottom-left
        float2( 1, -1), // bottom-right
        float2(-1,  1), // top-left
        float2(-1,  1), // top-left
        float2( 1, -1), // bottom-right
        float2( 1,  1)  // top-right
    };

    const float2 texCoords[] = {
        float2(0, 1), // bottom-left (UV flipped vertically)
        float2(1, 1), // bottom-right
        float2(0, 0), // top-left
        float2(0, 0), // top-left
        float2(1, 1), // bottom-right
        float2(1, 0)  // top-right
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0, 1);
    out.texCoord = texCoords[vertexID];
    return out;
}

// MARK: - Pseudo-3D Eye Warp
//
// Real-time "fake 3D": synthesize one eye of a stereo pair from a single mono
// frame, with no pre-compute. A cheap heuristic depth estimate (lower-of-frame
// = nearer, brighter = nearer, edges = slightly nearer) drives a horizontal
// parallax shift. Rendered once per eye into a full-frame eye texture; the eye
// is selected by `eyeSign` (+1 left, -1 right). Brightness/contrast/saturation
// are folded in here so the windowed RealityKit VideoPlayerComponent path keeps
// the same look as the flat MetalKit player.
//
// The depth heuristic is intentionally isolated in `pseudo3DHeuristicDepth` so a
// future Core ML depth provider can replace it (sample a supplied depth texture
// instead) without touching the warp/tonal math.

struct VideoStereoUniforms {
    float brightness;
    float contrast;
    float saturation;
    float depthStrength;  // max horizontal disparity in UV (fraction of width)
    float convergence;    // depth put on the window plane. Inverse depth, so 1
                          // is NEAR: raising this pushes the scene BACK (at 1.0
                          // nothing crosses in front of the window frame).
    float eyeSign;        // +1 = left eye, -1 = right eye
    float mirror;         // 1 = mirror horizontally (flip), 0 = normal
    float useDepth;       // 1 = sample real depth from depthTex, 0 = heuristic
    // Maps frame UV into the content region of the depth map. Vision letterboxes
    // the frame into the model's square input (.scaleFit), so the depth for
    // frame UV lives at uv * scale + offset; identity when aspects match.
    float2 depthUVScale;
    float2 depthUVOffset;
    // Maps the stored depth sample to display-normalized depth (near≈1):
    // d = sample * valueScale + valueBias. Identity (1, 0) for realtime depth;
    // cached depth bakes each frame's encode range + the lookahead-smoothed
    // display range into this per-frame affine.
    float depthValueScale;
    float depthValueBias;
};

// Stereo-window guard: feather disparity to zero over the outer few percent of
// frame width. Without it, near (popped-out) content cut by the frame edge is a
// classic window violation, and the warp's clamp_to_edge sampling paints
// per-eye-different strips along the borders — both read as binocular rivalry
// and get markedly worse at higher depth strengths. Applied in display space
// (pre-mirror), symmetric so the flip doesn't matter.
static inline float pseudo3DEdgeFeather(float x) {
    const float feather = 0.05;
    return smoothstep(0.0, feather, x) * (1.0 - smoothstep(1.0 - feather, 1.0, x));
}

static inline float pseudo3DHeuristicDepth(texture2d<float> tex, sampler s, float2 uv) {
    float2 px = float2(1.0) / float2(tex.get_width(0), tex.get_height(0));
    float3 c  = tex.sample(s, uv).rgb;
    float l   = dot(c, float3(0.2126, 0.7152, 0.0722));
    float lL  = dot(tex.sample(s, uv + float2(-px.x, 0.0)).rgb, float3(0.2126, 0.7152, 0.0722));
    float lR  = dot(tex.sample(s, uv + float2( px.x, 0.0)).rgb, float3(0.2126, 0.7152, 0.0722));
    float lU  = dot(tex.sample(s, uv + float2(0.0, -px.y)).rgb, float3(0.2126, 0.7152, 0.0722));
    float lD  = dot(tex.sample(s, uv + float2(0.0,  px.y)).rgb, float3(0.2126, 0.7152, 0.0722));
    float edge       = saturate((abs(lR - lL) + abs(lD - lU)) * 1.2);
    float lowerNear  = smoothstep(0.10, 0.95, uv.y); // uv.y=1 is bottom of frame
    float brightNear = smoothstep(0.25, 0.85, l);
    return saturate(lowerNear * 0.70 + brightNear * 0.25 + edge * 0.05);
}

fragment float4 videoPseudo3DEyeFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    texture2d<float> depthTex [[texture(1)]],
    constant VideoStereoUniforms &u [[buffer(0)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 uv = in.texCoord;
    if (u.mirror > 0.5) { uv.x = 1.0 - uv.x; }

    // Real Core ML depth when available (normalized inverse depth: near≈1,
    // far≈0), otherwise the cheap heuristic. (The useDepth branch is currently
    // unreachable — a real depth map always takes the mesh-warp path — but is
    // kept consistent with videoStereoMeshVertex's letterbox remap.)
    float depth = u.useDepth > 0.5
        ? saturate(depthTex.sample(texSampler, uv * u.depthUVScale + u.depthUVOffset).r
                   * u.depthValueScale + u.depthValueBias)
        : pseudo3DHeuristicDepth(tex, texSampler, uv);
    // Near objects (depth high) must get CROSSED disparity to read as "in front":
    // the left eye sees them shifted right, the right eye left. That means
    // sampling the source toward the OPPOSITE side of the shift — hence the
    // minus. (The previous `+` gave uncrossed disparity, pushing near objects
    // behind = inverted/weak depth that won't fuse.)
    float disparity = (depth - u.convergence) * u.depthStrength
                      * pseudo3DEdgeFeather(in.texCoord.x);
    float2 warpedUV = float2(uv.x - u.eyeSign * disparity, uv.y);

    float4 color = tex.sample(texSampler, warpedUV);

    color.rgb += u.brightness;
    color.rgb = (color.rgb - 0.5) * u.contrast + 0.5;
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luminance), color.rgb, u.saturation);
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    color.a = 1.0;
    return color;
}

// MARK: - Packed Stereo Eye
//
// Real stereo, no synthesis: a side-by-side or over/under video already holds
// both eyes, so each eye is a crop of the decoded frame, stretched to the eye
// buffer (which also undoes a half-resolution squeeze). `region` places the
// eye in the frame, origin top left: sample = uv * scale + offset. Mirroring
// flips within the eye; the CPU side swaps which eye is sampled, since a
// mirrored pair is only a pair with the eyes exchanged. Tonal adjustments
// match the fake-3D warp so the two modes look the same.

struct PackedEyeUniforms {
    float brightness;
    float contrast;
    float saturation;
    float mirror;
    float2 regionScale;
    float2 regionOffset;
};

fragment float4 videoPackedEyeFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant PackedEyeUniforms &u [[buffer(0)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 uv = in.texCoord;
    if (u.mirror > 0.5) { uv.x = 1.0 - uv.x; }
    // Keep the bilinear footprint inside this eye's half, or the seam column
    // blends in the other eye's edge pixels.
    float2 halfTexel = 0.5 / float2(tex.get_width(0), tex.get_height(0));
    float2 lo = u.regionOffset + halfTexel;
    float2 hi = u.regionOffset + u.regionScale - halfTexel;
    float2 sampleUV = clamp(uv * u.regionScale + u.regionOffset, lo, hi);

    float4 color = tex.sample(texSampler, sampleUV);
    color.rgb += u.brightness;
    color.rgb = (color.rgb - 0.5) * u.contrast + 0.5;
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luminance), color.rgb, u.saturation);
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    color.a = 1.0;
    return color;
}

// MARK: - Pseudo-3D Mesh Warp (depth-displaced grid, occlusion-correct)
//
// When a real depth map is available, render the frame as a displaced grid
// instead of a per-pixel backward warp. Each vertex shifts horizontally by its
// disparity (parallax) and takes a clip-space Z from its depth; with depth
// testing, nearer geometry occludes farther geometry, so foreground/background
// boundaries stay clean instead of smearing into halos. Disocclusions become
// stretched triangles rather than edge smears. Reuses VideoStereoUniforms.

struct MeshVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex MeshVertexOut videoStereoMeshVertex(
    uint vid [[vertex_id]],
    const device float2 *gridPositions [[buffer(0)]],
    constant VideoStereoUniforms &u [[buffer(1)]],
    texture2d<float> depthTex [[texture(0)]]
) {
    constexpr sampler depthSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 grid = gridPositions[vid];           // [0,1] across the frame
    float2 uv = grid;
    if (u.mirror > 0.5) { uv.x = 1.0 - uv.x; }

    // uv already indexes the source pixel being displayed (post-mirror), and
    // depth was inferred on the unmirrored frame, so the letterbox remap applies
    // after the flip.
    float2 duv = uv * u.depthUVScale + u.depthUVOffset;
    // near≈1 after the per-frame value mapping (identity for realtime depth)
    float depth = saturate(depthTex.sample(depthSampler, duv, level(0)).r
                           * u.depthValueScale + u.depthValueBias);
    float disparity = (depth - u.convergence) * u.depthStrength
                      * pseudo3DEdgeFeather(grid.x);

    float ndcX = grid.x * 2.0 - 1.0 + u.eyeSign * disparity * 2.0;
    float ndcY = 1.0 - grid.y * 2.0;
    float ndcZ = clamp(1.0 - depth, 0.0, 1.0);   // near (depth 1) → 0 → wins depth test

    MeshVertexOut out;
    out.position = float4(ndcX, ndcY, ndcZ, 1.0);
    out.texCoord = uv;
    return out;
}

fragment float4 videoStereoMeshFragment(
    MeshVertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant VideoStereoUniforms &u [[buffer(0)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 color = tex.sample(texSampler, in.texCoord);
    color.rgb += u.brightness;
    color.rgb = (color.rgb - 0.5) * u.contrast + 0.5;
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luminance), color.rgb, u.saturation);
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    color.a = 1.0;
    return color;
}

// MARK: - Depth Stabilization (spatial band-limit + motion-adaptive temporal EMA)
//
// Two depth artifacts feed the warp:
//  1. Spatial: the depth model (esp. Base) carries detail finer than the warp
//     grid can sample, so the grid *aliases* it into rippling standing waves
//     across the frame. A gaussian low-pass band-limits the depth to the grid's
//     sampling rate, removing the ripples (at the cost of slightly softer
//     silhouettes — the same trade the smoother low-res depth used to make).
//  2. Temporal: monocular depth jitters frame-to-frame, wobbling subjects. A
//     motion-adaptive EMA smooths hard where depth is stable (kills flicker) but
//     trusts the new map where it changed a lot (no ghosting on motion).
// Both run at the depth's native resolution.

struct DepthStabilizeParams {
    int   blurRadius;  // spatial low-pass radius in depth texels (0 = no blur)
    float blurSigma;   // gaussian sigma for the low-pass
    float baseAlpha;   // temporal blend toward new map where depth is stable
    float motionGain;  // how fast the blend trusts the new map as depth changes
    uint  hasPrev;     // 1 when emaPrev holds a valid previous frame
    float sigmaLuma;   // joint-bilateral luma sigma (bilateral kernels only)
};

// The gaussian is separable, so it runs as two 1D passes (H into a scratch
// texture, then V) — 2·(2r+1) taps per texel instead of (2r+1)², a 6.5× tap
// reduction at the default radius 6. The EMA rides the tail of the V pass so
// the whole stabilization is still one command buffer.

static inline float depthGaussian1D(
    texture2d<float, access::sample> src, sampler s,
    float2 uv, float2 texelStep, constant DepthStabilizeParams &p
) {
    if (p.blurRadius <= 0) { return src.sample(s, uv).r; }
    const float inv2s2 = 1.0 / (2.0 * p.blurSigma * p.blurSigma);
    float sum = 0.0, wsum = 0.0;
    for (int d = -p.blurRadius; d <= p.blurRadius; ++d) {
        const float w = exp(-float(d * d) * inv2s2);
        sum += w * src.sample(s, uv + texelStep * float(d)).r;
        wsum += w;
    }
    return wsum > 1e-5 ? (sum / wsum) : src.sample(s, uv).r;
}

kernel void depthBlurH(
    texture2d<float, access::sample> rawDepth [[texture(0)]],
    texture2d<float, access::write>  blurred  [[texture(1)]],
    constant DepthStabilizeParams &p          [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint W = blurred.get_width();
    const uint H = blurred.get_height();
    if (gid.x >= W || gid.y >= H) { return; }

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const float2 size = float2(W, H);
    const float2 uv = (float2(gid) + 0.5) / size;
    const float raw = depthGaussian1D(rawDepth, s, uv, float2(1.0 / size.x, 0.0), p);
    blurred.write(float4(raw, 0.0, 0.0, 1.0), gid);
}

kernel void depthBlurVEMA(
    texture2d<float, access::sample> blurredH [[texture(0)]],
    texture2d<float, access::sample> emaPrev  [[texture(1)]],
    texture2d<float, access::write>  emaNext  [[texture(2)]],
    constant DepthStabilizeParams &p          [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint W = emaNext.get_width();
    const uint H = emaNext.get_height();
    if (gid.x >= W || gid.y >= H) { return; }

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const float2 size = float2(W, H);
    const float2 uv = (float2(gid) + 0.5) / size;
    const float raw = depthGaussian1D(blurredH, s, uv, float2(0.0, 1.0 / size.y), p);

    float out = raw;
    if (p.hasPrev != 0) {
        const float prev = emaPrev.sample(s, uv).r;
        const float alpha = clamp(p.baseAlpha + p.motionGain * abs(raw - prev), p.baseAlpha, 1.0);
        out = mix(prev, raw, alpha);
    }
    emaNext.write(float4(out, 0.0, 0.0, 1.0), gid);
}

// MARK: - Edge-Aware Depth Refinement (joint bilateral, offline conversion)
//
// Monocular depth edges rarely align exactly with image edges, and a plain
// gaussian band-limit smears them further — visible as halos around crisp
// silhouettes (worst on synthetic/CG content). The joint bilateral filter
// weights each spatial tap by luma similarity to the center pixel, so depth
// smooths within regions but snaps to image edges. Run as two 1D passes — an
// approximation of the true 2D bilateral, standard for this use.

struct DepthGuideParams {
    // Letterbox transform: guide texel UV → source-video UV (the inverse of the
    // warp's depthUVScale/Offset), so the guide aligns with the depth map.
    float2 uvScale;
    float2 uvOffset;
};

/// Downsample the video frame into a luma guide at depth resolution, laid out
/// in the depth map's (letterboxed) UV space.
kernel void depthGuideLuma(
    texture2d<float, access::sample> video [[texture(0)]],
    texture2d<float, access::write>  guide [[texture(1)]],
    constant DepthGuideParams &p           [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint W = guide.get_width();
    const uint H = guide.get_height();
    if (gid.x >= W || gid.y >= H) { return; }
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const float2 uv = (float2(gid) + 0.5) / float2(W, H);
    const float2 videoUV = clamp((uv - p.uvOffset) / max(p.uvScale, float2(1e-5)), 0.0, 1.0);
    const float luma = dot(video.sample(s, videoUV).rgb, float3(0.2126, 0.7152, 0.0722));
    guide.write(float4(luma, 0.0, 0.0, 1.0), gid);
}

static inline float depthJointBilateral1D(
    texture2d<float, access::sample> src,
    texture2d<float, access::sample> guide,
    sampler s, float2 uv, float2 texelStep, constant DepthStabilizeParams &p
) {
    if (p.blurRadius <= 0) { return src.sample(s, uv).r; }
    const float inv2ss = 1.0 / (2.0 * p.blurSigma * p.blurSigma);
    const float inv2sl = 1.0 / (2.0 * p.sigmaLuma * p.sigmaLuma);
    const float g0 = guide.sample(s, uv).r;
    float sum = 0.0, wsum = 0.0;
    for (int d = -p.blurRadius; d <= p.blurRadius; ++d) {
        const float2 tuv = uv + texelStep * float(d);
        const float dg = guide.sample(s, tuv).r - g0;
        const float w = exp(-float(d * d) * inv2ss - dg * dg * inv2sl);
        sum += w * src.sample(s, tuv).r;
        wsum += w;
    }
    return wsum > 1e-5 ? (sum / wsum) : src.sample(s, uv).r;
}

kernel void depthJointBilateralH(
    texture2d<float, access::sample> rawDepth [[texture(0)]],
    texture2d<float, access::sample> guide    [[texture(1)]],
    texture2d<float, access::write>  dst      [[texture(2)]],
    constant DepthStabilizeParams &p          [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint W = dst.get_width();
    const uint H = dst.get_height();
    if (gid.x >= W || gid.y >= H) { return; }
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const float2 size = float2(W, H);
    const float2 uv = (float2(gid) + 0.5) / size;
    const float v = depthJointBilateral1D(rawDepth, guide, s, uv, float2(1.0 / size.x, 0.0), p);
    dst.write(float4(v, 0.0, 0.0, 1.0), gid);
}

kernel void depthJointBilateralV(
    texture2d<float, access::sample> blurredH [[texture(0)]],
    texture2d<float, access::sample> guide    [[texture(1)]],
    texture2d<float, access::write>  dst      [[texture(2)]],
    constant DepthStabilizeParams &p          [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint W = dst.get_width();
    const uint H = dst.get_height();
    if (gid.x >= W || gid.y >= H) { return; }
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const float2 size = float2(W, H);
    const float2 uv = (float2(gid) + 0.5) / size;
    const float v = depthJointBilateral1D(blurredH, guide, s, uv, float2(0.0, 1.0 / size.y), p);
    dst.write(float4(v, 0.0, 0.0, 1.0), gid);
}

// MARK: - Offline Depth Conversion (per-frame stats + temporal encode)
//
// The offline "Convert to 3D" pre-processing pass computes robust per-frame
// depth statistics on the GPU (min/max reduction feeding a 256-bin histogram
// for percentiles/median), then encodes a lookahead-smoothed depth frame into
// the cache video's luma plane. Raw model output has an arbitrary per-frame
// scale, so all stats are in raw units; DepthConverter turns them into a
// temporally stable display mapping in its post-pass.

/// One (min, max) pair per 16×16 threadgroup; the CPU folds the partials.
/// Must be dispatched with threadsPerThreadgroup = 16×16 (256 threads).
kernel void depthMinMaxReduce(
    texture2d<float, access::read> src [[texture(0)]],
    device float2 *partials            [[buffer(0)]],
    uint2 gid  [[thread_position_in_grid]],
    uint  tix  [[thread_index_in_threadgroup]],
    uint2 tgid [[threadgroup_position_in_grid]],
    uint2 tgPerGrid [[threadgroups_per_grid]]
) {
    threadgroup float sMin[256];
    threadgroup float sMax[256];
    float lo = INFINITY;
    float hi = -INFINITY;
    if (gid.x < src.get_width() && gid.y < src.get_height()) {
        const float d = src.read(gid).r;
        if (isfinite(d)) { lo = d; hi = d; }
    }
    sMin[tix] = lo;
    sMax[tix] = hi;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = 128; stride > 0; stride >>= 1) {
        if (tix < stride) {
            sMin[tix] = min(sMin[tix], sMin[tix + stride]);
            sMax[tix] = max(sMax[tix], sMax[tix + stride]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tix == 0) {
        partials[tgid.y * tgPerGrid.x + tgid.x] = float2(sMin[0], sMax[0]);
    }
}

struct DepthHistogramParams {
    float lo;      // histogram range start (raw units)
    float invSpan; // 1 / (hi - lo)
};

kernel void depthHistogram256(
    texture2d<float, access::read> src [[texture(0)]],
    device atomic_uint *bins           [[buffer(0)]],
    constant DepthHistogramParams &p   [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) { return; }
    const float d = src.read(gid).r;
    if (!isfinite(d)) { return; }
    const uint bin = uint(clamp((d - p.lo) * p.invSpan, 0.0f, 0.999999f) * 256.0f);
    atomic_fetch_add_explicit(&bins[bin], 1u, memory_order_relaxed);
}

struct DepthEncodeParams {
    float rangeLo;        // center frame's robust lo (raw units)
    float rangeInvSpan;   // 1 / (hi - lo)
    float weights[5];     // temporal window weights, normalized; 0 for unused slots
    float motionSigmaInv; // depth-similarity gate: 1/(2σ²), raw units; 0 = ungated
};

/// Weighted temporal average of up to 5 refined raw-depth maps (the center
/// frame ±2, truncated at scene cuts), normalized into the center frame's
/// robust range and written to the cache video's luma plane. Unused slots must
/// still be bound (weight 0).
///
/// Each neighbor's weight is additionally gated by its depth similarity to the
/// center frame at this texel. The window has no motion compensation, so at a
/// moving silhouette the neighbors disagree with the center by ~the edge's
/// depth jump; averaging them in paints ghost bands that scroll with the
/// motion — invisible when the encode was soft, but a visible edge shimmer at
/// the sharp 2x guided-upsample encode. The gate collapses those taps toward
/// zero while depths within σ of the center (stable regions and genuine slow
/// drift — the jitter this window exists to smooth) keep ~full weight.
kernel void depthTemporalEncode(
    array<texture2d<float, access::sample>, 5> maps [[texture(0)]],
    texture2d<float, access::write> outLuma [[texture(5)]],
    constant DepthEncodeParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint W = outLuma.get_width();
    const uint H = outLuma.get_height();
    if (gid.x >= W || gid.y >= H) { return; }

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const float2 uv = (float2(gid) + 0.5) / float2(W, H);
    const float center = maps[2].sample(s, uv).r; // window is centered on slot 2
    float acc = 0.0;
    float wsum = 0.0;
    for (uint i = 0; i < 5; ++i) {
        const float d = maps[i].sample(s, uv).r;
        const float delta = d - center;
        const float w = p.weights[i] * exp(-delta * delta * p.motionSigmaInv);
        acc += w * d;
        wsum += w;
    }
    const float v = wsum > 1e-6 ? (acc / wsum) : center;
    outLuma.write(float4(saturate((v - p.rangeLo) * p.rangeInvSpan), 0.0, 0.0, 1.0), gid);
}

// MARK: - Subtitles in the Stereo Picture
//
// See StereoSubtitles.swift. A subtitle image is drawn over each finished eye
// image, shifted sideways by that eye's share of the text's disparity.

struct SubtitleQuadUniforms {
    float2 rectOrigin;   // eye UV, origin top left, before the shift
    float2 rectSize;
    float shift;         // this eye's horizontal shift in eye UV
    float transfer;      // 0 = SDR, 1 = PQ, 2 = HLG
    float whiteNits;     // the text's white on an HDR picture
    float padding;
};

vertex VertexOut stereoSubtitleVertex(
    uint vertexID [[vertex_id]],
    constant SubtitleQuadUniforms &u [[buffer(0)]]
) {
    const float2 corners[] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(0, 0), float2(1, 1), float2(1, 0)
    };
    float2 corner = corners[vertexID];
    float2 uv = u.rectOrigin + corner * u.rectSize + float2(u.shift, 0);
    VertexOut out;
    out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0, 1);
    out.texCoord = corner;   // the image's rows run top down
    return out;
}

static inline float3 subtitleSRGBToLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

// SMPTE ST 2084 inverse EOTF: absolute luminance in nits to the PQ signal.
static inline float3 subtitlePQEncode(float3 nits) {
    const float m1 = 0.1593017578125, m2 = 78.84375;
    const float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float3 y = pow(clamp(nits / 10000.0, 0.0, 1.0), m1);
    return pow((c1 + c2 * y) / (1.0 + c3 * y), m2);
}

// BT.2100 HLG: display luminance on the nominal 1000-nit display (system
// gamma 1.2) back to scene light, then the OETF. 203 nits lands on 75 %,
// BT.2408's reference white.
static inline float3 subtitleHLGEncode(float3 nits) {
    const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
    float3 e = pow(clamp(nits / 1000.0, 0.0, 1.0), 1.0 / 1.2);
    return select(a * log(max(12.0 * e - b, 1e-6)) + c, sqrt(3.0 * e), e <= 1.0 / 12.0);
}

fragment float4 stereoSubtitleFragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant SubtitleQuadUniforms &u [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_zero);
    float4 c = tex.sample(s, in.texCoord);   // premultiplied sRGB
    if (c.a <= 0.0) { discard_fragment(); }
    // SDR eyes are BT.709-coded, close enough to sRGB to write as is.
    if (u.transfer < 0.5) { return c; }
    float3 nits = subtitleSRGBToLinear(c.rgb / c.a) * u.whiteNits;
    float3 coded = u.transfer < 1.5 ? subtitlePQEncode(nits) : subtitleHLGEncode(nits);
    return float4(coded * c.a, c.a);
}

// Disparity behind the subtitle text in a real stereo pair. One threadgroup
// per patch of the region, one thread per candidate disparity d: the left
// eye's 8×8 patch against the right eye's patch d pixels to the left
// (xL - xR = d, so positive d is crossed: in front of the screen), compared
// mean-removed so the eyes' exposure needn't match. A patch answers only if
// it has texture and one candidate clearly wins; flat sky or a repeating
// pattern answers nothing rather than something wrong.
struct SubtitleMatchParams {
    float2 regionOrigin;   // eye pixels
    float2 regionSize;
    uint2 patchGrid;
    int candidateStep;     // pixels between candidates
    int sampleStep;        // pixels between patch samples
};

static inline float subtitleLuma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

kernel void stereoSubtitleMatch(
    texture2d<float, access::read> left [[texture(0)]],
    texture2d<float, access::read> right [[texture(1)]],
    constant SubtitleMatchParams &p [[buffer(0)]],
    device float2 *results [[buffer(1)]],
    uint2 group [[threadgroup_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]]
) {
    constexpr int kCandidates = 128;   // = threads per group, StereoSubtitleCompositor.candidateCount
    constexpr int kSamples = 64;       // 8×8
    threadgroup float leftLuma[kSamples];
    threadgroup float cost[kCandidates];

    int2 limit = int2(left.get_width(), left.get_height()) - 1;
    float2 cell = p.regionSize / float2(p.patchGrid);
    int2 origin = int2(p.regionOrigin + (float2(group) + 0.5) * cell) - 4 * p.sampleStep;

    if (tid < uint(kSamples)) {
        int2 at = clamp(origin + int2(tid % 8, tid / 8) * p.sampleStep, int2(0), limit);
        leftLuma[tid] = subtitleLuma(left.read(uint2(at)).rgb);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float leftMean = 0;
    for (int i = 0; i < kSamples; i++) { leftMean += leftLuma[i]; }
    leftMean /= kSamples;

    int d = (int(tid) - kCandidates / 2) * p.candidateStep;
    float rightMean = 0;
    for (int i = 0; i < kSamples; i++) {
        int2 at = clamp(origin + int2(i % 8 * p.sampleStep - d, i / 8 * p.sampleStep), int2(0), limit);
        rightMean += subtitleLuma(right.read(uint2(at)).rgb);
    }
    rightMean /= kSamples;
    float sad = 0;
    for (int i = 0; i < kSamples; i++) {
        int2 at = clamp(origin + int2(i % 8 * p.sampleStep - d, i / 8 * p.sampleStep), int2(0), limit);
        sad += abs((leftLuma[i] - leftMean) - (subtitleLuma(right.read(uint2(at)).rgb) - rightMean));
    }
    cost[tid] = sad;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tid != 0) { return; }
    int best = 0;
    for (int k = 1; k < kCandidates; k++) { if (cost[k] < cost[best]) { best = k; } }
    float runnerUp = 1e30;   // not INFINITY: the library builds with fast math
    for (int k = 0; k < kCandidates; k++) {
        if (abs(k - best) > 2) { runnerUp = min(runnerUp, cost[k]); }
    }
    float texture = 0;
    for (int i = 0; i < kSamples; i++) { texture += abs(leftLuma[i] - leftMean); }
    texture /= kSamples;
    bool valid = texture > 0.02 && best > 0 && best < kCandidates - 1 && cost[best] < 0.8 * runnerUp;
    results[group.y * p.patchGrid.x + group.x] =
        float2(float((best - kCandidates / 2) * p.candidateStep), valid ? 1.0 : 0.0);
}
