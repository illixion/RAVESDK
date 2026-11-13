"""ONNX → PyTorch → Core ML for the three Face Landmarker models. See README.md.

    python convert.py <dir with detector.onnx, mesh.onnx, blend.onnx> <output dir>
"""
import sys

import coremltools as ct
import onnx
import torch
from onnx2torch import convert
from onnx2torch.node_converters.activations import OnnxPReLU

source, out = sys.argv[1], sys.argv[2]

# onnx2torch's PReLU traces into a scatter/gather tangle that Core ML runs a
# hundred times slower (60 ms a frame instead of 2); the plain op is the same
# function.
OnnxPReLU.forward = lambda self, x, slope: torch.nn.functional.prelu(x, slope.reshape(-1))

# The originals' weights are float16 already. The blend shape model squares
# pixel coordinates, which half precision cannot hold, so it computes in float32.
PRECISION = {
    "FaceDetector": ct.precision.FLOAT16,
    "FaceMesh": ct.precision.FLOAT16,
    "FaceBlendshapes": ct.precision.FLOAT32,
}


def load(name):
    return convert(onnx.load(f"{source}/{name}.onnx")).eval()


class Detector(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, x):
        regressors, scores = self.model(x)
        return regressors.reshape(896, 16), scores.reshape(896)


class Mesh(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, x):
        landmarks, presence, tongue = self.model(x)
        return landmarks.reshape(478, 3), presence.reshape(1), tongue.reshape(1)


class Blend(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, x):
        return self.model(x).reshape(52)


def save(module, example, inputs, outputs, name, description):
    with torch.no_grad():
        traced = torch.jit.trace(module, example)
    model = ct.convert(
        traced,
        inputs=inputs,
        outputs=[ct.TensorType(name=o) for o in outputs],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=PRECISION[name],
        convert_to="mlprogram",
    )
    model.author = "Google (MediaPipe Face Landmarker); Core ML conversion for RAVEFaceTracking"
    model.license = "Apache-2.0"
    model.short_description = description
    model.save(f"{out}/{name}.mlpackage")


save(
    Detector(load("detector")),
    torch.rand(1, 3, 128, 128) * 2 - 1,
    [ct.ImageType(name="image", shape=(1, 3, 128, 128), scale=1 / 127.5, bias=[-1, -1, -1],
                  color_layout=ct.colorlayout.RGB)],
    ["regressors", "scores"],
    "FaceDetector",
    "BlazeFace short-range face detector (MediaPipe face_detector.tflite)",
)
save(
    Mesh(load("mesh")),
    torch.rand(1, 3, 256, 256),
    [ct.ImageType(name="image", shape=(1, 3, 256, 256), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
    ["landmarks", "presence", "tongue"],
    "FaceMesh",
    "478-point face mesh with irises (MediaPipe face_landmarks_detector.tflite)",
)
save(
    Blend(load("blend")),
    torch.rand(1, 146, 2) * 256,
    [ct.TensorType(name="points", shape=(1, 146, 2))],
    ["blendshapes"],
    "FaceBlendshapes",
    "52 ARKit-style blend shape scores from 146 mesh points (MediaPipe face_blendshapes.tflite)",
)
