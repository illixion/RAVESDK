/*
 RAVE SDK — which windows belong to "this app" when it isn't alone in its process.

 RAVEUI's window helpers were written for one app per process: "close all
 windows" destroyed every window scene there was, and the manager listed every
 managed window. Nexus runs several apps as modules of one process (so they can
 share one immersive space), and there one module's "close all" would take the
 launcher and every other module's windows with it.

 A scope says which windows a caller owns, by SwiftUI window id. A module gives
 its scene ids a prefix (`convolution.main`, `convolution.photo`), sets
 `.raveWindowScope(.prefix("convolution."))` on its scenes' roots, and passes
 the same scope to `RAVEWindowScenes`. A standalone app does nothing: the
 default is `.process`, which is the old behavior.
 */

#if canImport(SwiftUI)

import SwiftUI

public struct RAVEWindowScope: Sendable, Equatable {
    private enum Rule: Sendable, Equatable {
        case process
        case prefix(String)
        case ids(Set<String>)
    }

    private let rule: Rule

    /// Every window in the process: the app is alone in it.
    public static let process = RAVEWindowScope(rule: .process)

    /// Windows whose scene id starts with `prefix`.
    public static func prefix(_ prefix: String) -> RAVEWindowScope {
        RAVEWindowScope(rule: .prefix(prefix))
    }

    /// Windows with exactly these scene ids.
    public static func ids(_ ids: Set<String>) -> RAVEWindowScope {
        RAVEWindowScope(rule: .ids(ids))
    }

    /// Whether a window with this scene id is in the scope. A window whose id
    /// isn't known is only in `.process`: a narrower scope never claims, and so
    /// never destroys, a window it can't show is its own.
    public func contains(sceneID: String?) -> Bool {
        switch rule {
        case .process: true
        case .prefix(let prefix): sceneID?.hasPrefix(prefix) ?? false
        case .ids(let ids): sceneID.map(ids.contains) ?? false
        }
    }
}

public extension EnvironmentValues {
    /// The windows the views here manage. `RAVEWindowManagerView` lists only
    /// these; pass the same scope to `RAVEWindowScenes`.
    @Entry var raveWindowScope: RAVEWindowScope = .process

    /// The main-window bookkeeping the views here register with. A module
    /// hosted beside others gives its scenes its own registry, so "is a main
    /// window up?" means its main window, not anyone's. Nil is `.shared` (the
    /// default can't name the main-actor singleton).
    @Entry var raveWindowSessions: RAVEWindowSessionRegistry? = nil
}

public extension View {
    func raveWindowScope(_ scope: RAVEWindowScope) -> some View {
        environment(\.raveWindowScope, scope)
    }

    func raveWindowSessions(_ registry: RAVEWindowSessionRegistry) -> some View {
        environment(\.raveWindowSessions, registry)
    }
}

#endif
