//
//  RAVESupportPose.swift
//  RAVESupport
//
//  The artwork slots. Drop a PNG or JPG named after the slot into
//  Sources/RAVESupport/Poses (welcome.png, thanks.png, card.png) and every app
//  picks it up on its next build. A missing file just means no picture: the
//  card is complete without one.
//

import SwiftUI

public enum RAVESupportPose: String, CaseIterable, Sendable {
    /// Top of the one-time welcome sheet.
    case welcome
    /// Shown after the person taps Sponsor.
    case thanks
    /// The inline card in an app's Settings or About screen.
    case card

    static let extensions = ["png", "jpg", "jpeg"]

    /// URL of the artwork for this slot, nil when none has been added.
    public var url: URL? {
        for ext in Self.extensions {
            if let u = Bundle.module.url(forResource: rawValue, withExtension: ext, subdirectory: "Poses") { return u }
        }
        return nil
    }

    var image: Image? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #elseif canImport(AppKit)
        guard let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
        #else
        return nil
        #endif
    }
}
