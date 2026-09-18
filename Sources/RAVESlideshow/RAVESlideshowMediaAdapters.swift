#if os(visionOS)

import RAVEMedia

public extension RAVESlideshowColorAdjustments {
    var raveMediaColorAdjustments: RAVEColorAdjustments {
        RAVEColorAdjustments(brightness: brightness, contrast: contrast, saturation: saturation)
    }
}

#endif
