// The portable half of the stereo pipeline (layouts, warp settings, depth
// maths) lives in Vergence's VergenceCore; apps keep reaching it through
// `import RAVEMedia` while the rest of the pipeline moves there too.
@_exported import VergenceCore
