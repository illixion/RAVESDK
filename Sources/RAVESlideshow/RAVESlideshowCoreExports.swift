/*
 RAVESlideshow - core re-export

 The lifecycle engine, models and local sync live in RAVESlideshowCore, which
 is Foundation-only and also builds on Linux (RoboFrame's Pi kiosk). This
 target adds the SwiftUI surfaces and RAVEMedia adapters on top, and
 re-exports the core so `import RAVESlideshow` reaches all of it.
 */

@_exported import RAVESlideshowCore
