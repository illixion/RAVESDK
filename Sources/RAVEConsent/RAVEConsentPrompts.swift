//
//  RAVEConsentPrompts.swift
//  RAVEConsent
//
//  Where the question appears. Two lines adopt it:
//
//      RAVEConsentWindow(title: "Share with the Character")   // in the App's body (visionOS, macOS)
//      ContentView().raveConsentPrompts()                      // on a view that appears, once
//
//  visionOS and macOS show it in a window of the app's own, like DebugTrace's
//  approval window and for the same reason: with only an immersive space up
//  there is nothing a system alert could attach to, and visionOS puts a
//  utility panel in front of full immersion. iOS and tvOS always have a window,
//  so the same modifier presents a sheet and `RAVEConsentWindow` does not exist.
//

import SwiftUI

public extension View {
    /// Lets `RAVEConsentCenter.shared` show its questions. Put it on one view
    /// that is up whenever the app can ask: a second copy would show a second sheet.
    func raveConsentPrompts() -> some View { modifier(RAVEConsentPrompts()) }
}

#if os(visionOS) || os(macOS)

struct RAVEConsentPrompts: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear { RAVEConsentWindowPresenter.shared.attach(open: openWindow, dismiss: dismissWindow) }
    }
}

/// The scene the questions appear in. A single `Window`, so a question never
/// opens a second copy; that scene type's launch and restoration behaviour
/// needs macOS 15 (visionOS 26 is the package's floor already).
@available(macOS 15.0, *)
public struct RAVEConsentWindow: Scene {
    private let title: String

    public init(title: String = "Share Data") { self.title = title }

    public var body: some Scene {
        Window(title, id: RAVEConsentWindowPresenter.windowID) {
            RAVEConsentView()
                .onAppear { RAVEConsentWindowPresenter.shared.windowAppeared() }
                .onDisappear { RAVEConsentWindowPresenter.shared.windowDisappeared() }
        }
        .windowResizability(.contentSize)
        #if os(visionOS)
        // Close to the person and in front of the app's other windows, even
        // ones whose 3D content stands out toward the viewer.
        .defaultWindowPlacement { _, _ in WindowPlacement(.utilityPanel) }
        #endif
        // Only ever opened for a question: never at launch, never restored empty.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

@MainActor
final class RAVEConsentWindowPresenter: RAVEConsentPresenting {
    static let shared = RAVEConsentWindowPresenter()
    static let windowID = "rave-consent"

    private var openWindow: OpenWindowAction?
    private var dismissWindow: DismissWindowAction?
    private var windowVisible = false
    private var closeTask: Task<Void, Never>?
    /// We asked the window to close and it has not gone yet; its disappearance
    /// is then ours, not the person refusing the question.
    private var dismissing = false

    func attach(open: OpenWindowAction, dismiss: DismissWindowAction) {
        if openWindow == nil { openWindow = open }
        if dismissWindow == nil { dismissWindow = dismiss }
        RAVEConsentCenter.shared.presenter = self
    }

    func windowAppeared() { windowVisible = true }

    func windowDisappeared() {
        windowVisible = false
        // Closing the window with a question up is a no.
        guard !dismissing else { return }
        RAVEConsentCenter.shared.closedUnanswered()
    }

    func present(for center: RAVEConsentCenter) async -> Bool {
        guard let openWindow else {
            RAVEConsentLog.consent.error("Consent window was never attached: add raveConsentPrompts() to a view")
            return false
        }
        closeTask?.cancel()
        if dismissing {
            // A question that arrives after the grace period but before the
            // closing window is gone would sit in a window that disappears
            // under it. Let it go, then open a fresh one.
            await wait(until: { !self.windowVisible })
            dismissing = false
        }
        if !windowVisible {
            openWindow(id: Self.windowID)
            await wait(until: { self.windowVisible })
        }
        return windowVisible
    }

    func finished(for center: RAVEConsentCenter) {
        // The next question may follow at once; a moment's grace lets it reuse
        // this window instead of closing and reopening it.
        closeTask = Task { [weak self, weak center] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, let center, !Task.isCancelled, center.request == nil else { return }
            self.dismissing = true
            self.dismissWindow?(id: Self.windowID)
        }
    }

    private func wait(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

#else

struct RAVEConsentPrompts: ViewModifier {
    private var center = RAVEConsentCenter.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { center.request != nil },
                // Swiped away with a question up: a no.
                set: { if !$0 { center.closedUnanswered() } }
            )) {
                RAVEConsentView()
                    .presentationDetents([.medium, .large])
            }
            .onAppear { center.presenter = RAVEConsentSheetPresenter.shared }
    }
}

@MainActor
final class RAVEConsentSheetPresenter: RAVEConsentPresenting {
    static let shared = RAVEConsentSheetPresenter()

    /// The sheet follows `center.request` by itself.
    func present(for center: RAVEConsentCenter) async -> Bool { true }
    func finished(for center: RAVEConsentCenter) {}
}

#endif

// MARK: - The question

struct RAVEConsentView: View {
    private var center = RAVEConsentCenter.shared

    private var onDeviceSymbol: String {
        #if os(visionOS)
        "visionpro"
        #elseif os(iOS)
        "iphone"
        #elseif os(macOS)
        "laptopcomputer"
        #else
        "appletv"
        #endif
    }

    var body: some View {
        VStack(spacing: 16) {
            if let request = center.request {
                Text(request.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                preview(request.preview)
                Text(request.detail)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Label(request.destination.summary,
                      systemImage: request.destination.leavesDevice ? "arrow.up.forward.app" : onDeviceSymbol)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    Button(request.action) { center.respond(.once) }
                        .buttonStyle(.borderedProminent)
                    if request.offersGrant {
                        Button("\(request.action) for \(Int(center.grantDuration / 60)) Minutes") { center.respond(.forAWhile) }
                    }
                    Button("Don't \(request.action)", role: .cancel) { center.respond(.deny) }
                }
            } else {
                Text("Nothing is waiting.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        #if os(visionOS) || os(macOS)
        .frame(width: 580)
        #endif
    }

    @ViewBuilder
    private func preview(_ preview: RAVEConsentPreview) -> some View {
        switch preview {
        case .none:
            EmptyView()
        case .image(let image):
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 520, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        case .text(let text):
            ScrollView {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxWidth: 520, maxHeight: 200)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
