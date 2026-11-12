//
//  RAVESupportConfig.swift
//  RAVESupport
//
//  What the support card says and where it points. Every app passes its own
//  name; everything else has a default in the maker's voice.
//

import Foundation

public struct RAVESupportConfig: Sendable {
    /// The app's display name, used in the card's body copy.
    public var appName: String
    /// Stable key for "already shown" (a bundle id works).
    public var appID: String
    public var sponsorURL: URL
    public var title: String
    public var message: String
    public var nudgeTitle: String
    public var nudgeMessage: String

    public static let defaultSponsorURL = URL(string: "https://github.com/sponsors/illixion")!

    public init(
        appName: String,
        appID: String,
        sponsorURL: URL = RAVESupportConfig.defaultSponsorURL,
        title: String = "Hi, I'm Ixion",
        message: String? = nil,
        nudgeTitle: String = "Thank you for staying",
        nudgeMessage: String? = nil
    ) {
        self.appName = appName
        self.appID = appID
        self.sponsorURL = sponsorURL
        self.title = title
        self.message = message ?? """
            I make \(appName), and everything else I publish, as free and open-source \
            software, and I don't expect anything in return. If it's useful to you and \
            you'd like to help me keep building, sponsoring me on GitHub is the best way. \
            If not, I hope you enjoy it all the same.
            """
        self.nudgeTitle = nudgeTitle
        self.nudgeMessage = nudgeMessage ?? """
            Thank you for still using \(appName) after a day. It means a lot that it has earned a \
            place on your device. If you'd like to help me keep making free software, sponsoring me \
            on GitHub is the best way, and there's no pressure either way. This is the last reminder \
            I'll ever send.
            """
    }
}
