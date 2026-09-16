# Spike results

Device facts that cannot be re-derived by reading code or building. The harness
for each section is named so the numbers can be re-taken when the OS or the
hardware changes.

## Depth pipeline — lookahead realtime fake-3D (2026-09-13)

Measured on Apple Vision Pro, visionOS 27, with `DepthPipelineSpike`
(RAVEMedia; run from Hypnos → Settings → Developer → Depth Pipeline Spike).
Source: Raven's 1080p60 H.264 test clip. Model: Apple's Depth Anything V2
Small F16 (518×392 input), the only one installed at the time.

| Question | Result |
|---|---|
| Raw inference, full 1080p frame handed to Vision | **32.9 ms median**, p95 38.5, max 41.0 |
| Shipping live call (inference + gaussian stabilize, synchronous) | **39.4 ms median**, p95 42.0, max 44.0 |
| Model load + compile (cached `.mlmodelc`) | 6.5 s |
| Offline refine chain run live, GPU time (luma guide + joint bilateral r12 + guided ×2 upsample r6) | **3.0 ms median**, p95 9.7 |
| Same without the ×2 upsample | 0.6 ms median |
| Robust p2–p98 range (min/max reduce + 256-bin histogram + CPU percentile), wall | 0.7 ms median |
| `AVPlayerItemVideoOutput` lead ahead of the current item time | **p10 28.5 frames, median 42.5, max 58** (= the 1 s probe cap) |
| Frames with ≥2 frames of lead | 100% |

### Reference: Apple's published latency for the same model

From the `apple/coreml-depth-anything-v2-small` model card (Small F16, Neural
Engine, Core ML performance report):

| Device | OS | Latency |
|---|---|---|
| iPhone 12 Pro Max | 18.0 | 31.1 ms |
| iPhone 15 Pro Max | 17.4 | 33.9 ms |
| MacBook Pro (M1 Max) | 15.0 | 32.8 ms |
| MacBook Pro (M3 Max) | 15.0 | 24.6 ms |

The 32.9 ms raw figure on the Vision Pro (M2) is that number. Vision's input
rescale is therefore not where the time goes; 33 ms is what the Neural Engine
needs for a 518×392 ViT-S forward pass on this generation of silicon.

### What they mean

**The realtime path is inference-bound at roughly 25 Hz, not 30.** Every
frame of the shipping live call costs ~39 ms, and the pump is synchronous, so
on 60 fps content the video renders at ~24 fps with a fresh map each frame.
The "infer at 30 Hz, hold for the in-between frame" design in
`RealtimeDepthSource` only engages when inference finishes inside 1/35 s; at
39 ms it never does, and every tick re-infers. The Small model does not fit a
30 Hz budget on this device with a synchronous tick. Apple's
own numbers (above) say the 33 ms is the ANE itself, so the remaining headroom
is in *overlap*, not in the model call: the tick serializes inference, the
stabilize wait, the warp wait and the pixel transfer. The spike's second round
measures pure `MLModel.prediction` per compute-unit setting, where each op is
planned to run (`MLComputePlan`), and the effective per-frame time with two
and three requests in flight; the pump now logs its own per-stage times every
5 s on real content.

**Edge-aware refinement and robust normalization are essentially free.** The
whole offline refine chain is ~3 ms of GPU time per frame, and the percentile
range under 1 ms. Both can move to the live path regardless of any buffering
decision; they were withheld from realtime on a cost assumption that turned
out wrong. With edge-snapped depth the live path can also use the dense warp
grid.

**Lookahead in Hypnos costs nothing in audio work.** The video output keeps
around 0.5–1 s of decoded frames ahead of the playhead and hands them out on
request. A pump that pulls N frames ahead, infers on them, and warps the
frame at the playhead with a centered window has its future depth already in
hand; AVPlayer stays the clock and the audio source untouched. The exact
queue depth is above the 1 s probe cap; the spike now probes 4 s.

**The 6.5 ms stabilize cost is latency, not work.** Two tiny dispatches and a
`waitUntilCompleted` on the inference thread. In a pipelined design (GPU
post-processing of frame k overlapping ANE inference of frame k+1, as the
converter already does) it leaves the critical path entirely.

### Design consequence

Lookahead does not raise inference throughput, so it cannot by itself make
60 fps content get 60 Hz depth. What it enables is decoupling display rate
from inference rate without a trailing hold: infer on every frame the ANE can
keep up with (~25–30 Hz), and for every displayed frame use depth
interpolated between the nearest inferred frames *before and after* it. Depth
is then never stale and never lags — it is bracketed — which keeps the
bounded-age policy that rejected the async-decoupled pump.

Raven cannot pull ahead (frames arrive as the page presents them), so for
Raven lookahead is a presentation delay with page-side audio compensation;
that measurement is still to be taken.
