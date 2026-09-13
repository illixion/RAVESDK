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

### What they mean

**The realtime path is inference-bound at roughly 25 Hz, not 30.** Every
frame of the shipping live call costs ~39 ms, and the pump is synchronous, so
on 60 fps content the video renders at ~24 fps with a fresh map each frame.
The "infer at 30 Hz, hold for the in-between frame" design in
`RealtimeDepthSource` only engages when inference finishes inside 1/35 s; at
39 ms it never does, and every tick re-infers. The Small model does not fit a
30 Hz budget on this device once Vision's preprocessing is counted. Whether
the 33 ms raw figure is the ANE or Vision rescaling a 1080p frame is the
follow-up measurement (the spike now decodes at 1036 and 518 px and re-times).

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
