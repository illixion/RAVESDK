# The face mesh reader's models

`../Models/` holds three compiled Core ML models, converted from Google's MediaPipe Face
Landmarker. This directory is not part of the build: it records where they came from and how to
make them again.

| Model | From (inside `face_landmarker.task`) | Input | Output | Size |
|---|---|---|---|---|
| `FaceDetector` | `face_detector.tflite` (BlazeFace short-range) | 128×128 picture | 896 boxes with six points, 896 scores | 0.3 MB |
| `FaceMesh` | `face_landmarks_detector.tflite` (Face Mesh V2) | 256×256 crop of the face | 478 points (x, y, z), a presence score | 2.6 MB |
| `FaceBlendshapes` | `face_blendshapes.tflite` (Blendshape V2) | 146 of the points, x and y | 52 scores: a "neutral" and ARKit's shapes but `tongueOut` | 1.8 MB |

4.9 MB together.

## Source and licence

- `https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task`
  (version 1, 2023-05-03, 3,758,596 bytes, SHA-256
  `64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff`). It is a zip of the three
  TFLite files.
- Documentation and model cards: `https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker`.
- Licence: Apache-2.0 (MediaPipe and its models). A copy ships beside the models
  (`../Models/LICENSE`); the models were converted, not retrained, and their weights are Google's.
- The numbers round the models (anchors, the crop's scale of 1.5, the 146 points, the output
  order) are MediaPipe's, from `mediapipe/tasks/cc/vision/face_detector` and `face_landmarker` in
  `github.com/google-ai-edge/mediapipe`, also Apache-2.0. They are in `../FaceMesh.swift`.

No Core ML conversion of these three was found to reuse (Hugging Face, 2026-11-13: the one Core
ML set found, `watzon/wormhole-mediapipe-coreml`, has a face detector, `face_landmark` and an iris
model but no blend shape model; the current models exist there as ONNX and PyTorch ports only).

## Converting

In a throwaway Python 3.11 environment (`uv venv --python 3.11`), with `tensorflow==2.16.2`,
`tf2onnx==1.17.0`, `onnx==1.16.2`, `onnx2torch==1.5.15`, `torch==2.15.0`, `coremltools==9.0`,
`numpy<2`:

```sh
unzip face_landmarker.task -d task
python -m tf2onnx.convert --tflite task/face_landmarks_detector.tflite --output onnx/mesh.onnx --opset 13 --inputs-as-nchw input_12
python -m tf2onnx.convert --tflite task/face_detector.tflite --output onnx/detector.onnx --opset 13 --inputs-as-nchw input
python -m tf2onnx.convert --tflite task/face_blendshapes.tflite --output onnx/blend.onnx --opset 13
python convert.py onnx coreml
for m in FaceDetector FaceMesh FaceBlendshapes; do xcrun coremlcompiler compile coreml/$m.mlpackage ../Models/; done
```

The models are checked in compiled (`.mlmodelc`) because `swift build` compiles no Core ML
models; a compiled model is the same for every platform.

Two things in `convert.py` matter:

- **PReLU.** `onnx2torch` turns the mesh model's 69 PReLUs into something that traces to
  `non_zero` / `scatter_nd` chains. Core ML then takes 60 ms a frame on the CPU (300 ms through
  the Neural Engine) instead of 2. The script swaps in `torch.nn.functional.prelu`.
- **Precision.** The detector and the mesh compute in float16 (the originals' weights are
  float16; float32 would double their size and keep them off the Neural Engine). The blend shape
  model computes in float32: it takes pixel coordinates and squares them. `FaceMesh.blendShapeInput`
  also hands it the points about their own middle, which the model's first step does anyway.

## How closely it matches the original

Each Core ML model against its TFLite original (TensorFlow Lite 2.16.2) on the same input, the
largest difference over ten photographs, on an M2 Max:

| | float16 as shipped | all float32 |
|---|---|---|
| Detector, box and points (pixels of 128) | 0.59 | 0.0002 |
| Detector, score (logit) | 1.6 | 0.001 |
| Mesh, any coordinate (pixels of 256) | 0.41, mean 0.18 | 0.0002 |
| Mesh, presence (logit) | 0.07 | 0.00003 |
| Blend shapes, any score (0…1) | 0.002 (float32) | 0.002 |

End to end (detector, crop, mesh, blend shapes) against the TFLite models in the same pipeline,
six photographs: the largest blend shape difference 0.028, the largest landmark difference 0.35
pixels of 256.

Against MediaPipe's own `FaceLandmarker` task on a still picture the landmarks agree to 0.2 to 0.8
pixels of 256 on average, but single blend shape scores differ by up to 0.3 (the brows most). That
is the pipeline, not the conversion: the reader crops from the mesh's own points as MediaPipe does
on video, the task on a still crops from the detector's box, and the blend shape model is that
sensitive to the crop.

Time a frame on an M2 Max, CPU only, debug build, crop included: about 3 ms (Vision's landmarks:
9 ms). The mesh model alone is 2.4 ms on the CPU, 1.1 ms on the Neural Engine.

## Checking a change

`FACE_DIR=/path/to/pictures swift test --filter FaceReaderComparisonTests` reads the same pictures
with Vision and with these models and prints each eye's lid, the brows, and how far each wanders on
a still face. No pictures are kept in the repository.
