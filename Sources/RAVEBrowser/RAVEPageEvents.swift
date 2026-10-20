//
//  RAVEPageEvents.swift
//  RAVEBrowser
//
//  What WebKit asks a tab's delegate that a page feature may want to answer:
//  a JavaScript dialog, a download, a file chooser, a response arriving, a
//  link opening a new window. `RAVEBrowserTab` puts each to its features
//  that conform to `RAVEPageEventHandler`, in their order, and takes the
//  first answer; with none, it does what a browser should (see the tab).
//
//  This is how `RAVEPageSupport` lets an agent drive pages that open
//  dialogs and downloads without anything modal ever appearing, while the
//  same tab in a person's hands would show them.
//

#if canImport(WebKit)
import Foundation
import WebKit

/// A JavaScript dialog the page opened: `alert`, `confirm` or `prompt`.
public struct RAVEPageDialog: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case alert, confirm, prompt }

    public var kind: Kind
    public var message: String
    /// `prompt`'s default answer.
    public var defaultText: String?
    /// The frame that opened it.
    public var url: String

    public init(kind: Kind, message: String, defaultText: String? = nil, url: String) {
        self.kind = kind
        self.message = message
        self.defaultText = defaultText
        self.url = url
    }
}

/// How a dialog is answered.
public enum RAVEPageDialogAnswer: Sendable, Equatable {
    /// OK: `confirm` returns true, `prompt` returns `text` (its default text
    /// when nil).
    case accept(text: String?)
    /// Cancel: `confirm` returns false, `prompt` returns null. An `alert` has
    /// only OK, so either answer closes it.
    case dismiss
}

/// A response WebKit is about to show, or to download: a document, a frame's
/// document. Subresources never come through here.
public struct RAVEPageResponse: Sendable, Equatable {
    public var url: URL?
    /// HTTP status, when the response was HTTP.
    public var status: Int?
    public var mimeType: String?
    public var isMainFrame: Bool
}

/// A download about to be saved.
public struct RAVEPageDownload: Sendable, Equatable {
    public var url: URL?
    public var suggestedFilename: String
    public var mimeType: String?
}

public enum RAVEPageDownloadDecision: Sendable, Equatable {
    case save(to: URL)
    case cancel
}

/// A page asking for files (an `<input type=file>` was activated).
public struct RAVEPageFileRequest: Sendable, Equatable {
    public var allowsMultiple: Bool
    public var allowsDirectories: Bool
}

public enum RAVEPageFileChoice: Sendable, Equatable {
    case files([URL])
    case cancel
}

/// A page feature that answers some of what WebKit asks a tab. Every method
/// is optional; returning nil means "not mine", and the next handler (then
/// the tab's default) is asked.
@MainActor
public protocol RAVEPageEventHandler: AnyObject {
    func answer(_ dialog: RAVEPageDialog) async -> RAVEPageDialogAnswer?
    func decide(_ download: RAVEPageDownload) -> RAVEPageDownloadDecision?
    /// A download ended: saved at `file`, or failed with `error`.
    func downloadEnded(_ download: RAVEPageDownload, file: URL?, error: String?)
    func choose(_ request: RAVEPageFileRequest) async -> RAVEPageFileChoice?
    func received(_ response: RAVEPageResponse)
    /// The page opened a new window on `url` (a `target="_blank"` link,
    /// `window.open`), before the tab hands it to the app.
    func openedWindow(_ url: URL)
}

public extension RAVEPageEventHandler {
    func answer(_ dialog: RAVEPageDialog) async -> RAVEPageDialogAnswer? { nil }
    func decide(_ download: RAVEPageDownload) -> RAVEPageDownloadDecision? { nil }
    func downloadEnded(_ download: RAVEPageDownload, file: URL?, error: String?) {}
    func choose(_ request: RAVEPageFileRequest) async -> RAVEPageFileChoice? { nil }
    func received(_ response: RAVEPageResponse) {}
    func openedWindow(_ url: URL) {}
}
#endif
