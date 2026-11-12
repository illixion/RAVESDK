# Support card artwork

Add pre-made images here, named after the slot they fill (PNG or JPG):

| File | Where it appears |
|---|---|
| `welcome.png` | top of the one-time "Hi, I'm Ixion" sheet |
| `nudge.png` | top of the one-time "Enjoying this app?" nudge, 24 hours after first use |
| `card.png` | the inline card in Settings / About |

Missing files are fine; the card simply shows no picture. Every app that links `RAVESupport` picks the
art up on its next build. Keep each under ~300 KB: it ships inside every app.

## Transparent depth artwork from Mirror

In spatial-ai-character, open Mirror, enter mirror mode, frame yourself, and enable
**Transparent PNG pictures** and **Save depth for spatial artwork**. Take a picture
(the self-timer works), then use **Share PNG + depth** on the capture row. The colour
image has real alpha; it does not use a green screen or a background-removal model.
The separate grayscale PNG is rendered from the same frozen avatar pose and lens.

Copy both files into this directory and rename them as a pair, for example:

- `welcome.png` + `welcome.depth.png`
- `nudge.png` + `nudge.depth.png`
- `card.png` + `card.depth.png`

On visionOS the card uses RAVEMedia's transparent relief-image view, backed by
Vergence's `StillDepthMap`. It displaces a textured grid so both eyes see depth.
Other platforms show only the flat colour PNG. Missing, malformed, or differently
sized depth falls back to the flat image. The flat PNG remains visible until the
relief is ready, then yields so its silhouette does not appear twice.

Depth is 8-bit grayscale, exactly the colour image's dimensions and orientation:
0 = far, 255 = near, normalized inverse distance over the subject's bounds. It is
raw data; do not colour-correct it. Resize/crop both images identically if optimizing
bundle size, and preserve alpha in the colour image. No model, rig, or animation
is bundled. These are **custom depth artwork**, not Apple's spatial HEIC format;
Photos receives only the flat PNG. Share/copy both files to retain the depth.
