// The stereo pipeline itself (depth providers, the converter and its cache,
// the stereo pump, the Metal warp) lives in Vergence, the public package at
// ../vergence. RAVEMedia keeps the RealityKit/SwiftUI player around it and
// re-exports Vergence, so `import RAVEMedia` still reaches all of it.
@_exported import VergenceApple
