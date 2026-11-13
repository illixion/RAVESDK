#if os(visionOS)
import RealityKit
import SwiftUI
import UIKit

/// One live viewer tree, mounted either in its window or in the head-following
/// space. Moving the hosting view preserves @State and player instances.
@MainActor @Observable
public final class RAVEViewerHUDPortal {
    public static let spaceID = "rave-viewer-hud"
    public private(set) var isInHUD = false
    public private(set) var isChangingPresentation = false
    public fileprivate(set) var error: String?
    public var width: Float = 1
    public var offset = SIMD3<Float>(0, 0, -1.3)
    public fileprivate(set) var openSpace: OpenImmersiveSpaceAction?
    public fileprivate(set) var dismissSpace: DismissImmersiveSpaceAction?
    /// The window still owns scene actions and geometry while its view is lent.
    public var windowScene: UIWindowScene? { home?.window?.windowScene }
    fileprivate var returnGeneration = 0
    fileprivate var controls: HUDControlsValue?
    fileprivate var hudPhase: ScenePhase = .active
    fileprivate var size = CGSize(width: 1200, height: 900)
    weak var source: UIView?
    weak var home: UIView?
    fileprivate static var active: RAVEViewerHUDPortal?

    fileprivate func present(open: OpenImmersiveSpaceAction) async {
        guard !isChangingPresentation else { return }
        guard Self.active == nil else {
            error = "Another viewer is already in HUD. Return it to its window first."
            return
        }
        isChangingPresentation = true
        error = nil
        Self.active = self
        switch await open(id: Self.spaceID) {
        case .opened:
            if home == nil, let dismissSpace {
                await dismissSpace()
                restore()
            }
        case .userCancelled:
            restore()
        case .error:
            error = "HUD could not open. Close the other immersive presentation and try again."
            restore()
        @unknown default:
            restore()
        }
        isChangingPresentation = false
    }

    fileprivate func returnToWindow(dismiss: DismissImmersiveSpaceAction) async {
        guard !isChangingPresentation else { return }
        isChangingPresentation = true
        await dismiss()
        restore()
        isChangingPresentation = false
    }

    func mount(in container: UIView) {
        guard let source else { return }
        isInHUD = true
        source.removeFromSuperview()
        container.addSubview(source)
        source.frame = container.bounds
        source.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    func restore() {
        let wasInHUD = isInHUD
        if let source, let home {
            source.removeFromSuperview()
            home.addSubview(source)
            source.frame = home.bounds
            source.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        isInHUD = false
        if wasInHUD { returnGeneration += 1 }
        if Self.active === self { Self.active = nil }
    }
}

private struct ViewerHUDPortalKey: EnvironmentKey {
    static let defaultValue: RAVEViewerHUDPortal? = nil
}

extension EnvironmentValues {
    public var raveViewerHUD: RAVEViewerHUDPortal? {
        get { self[ViewerHUDPortalKey.self] }
        set { self[ViewerHUDPortalKey.self] = newValue }
    }
}

/// Install once around a viewer scene's root, after the app's environment.
public struct RAVEViewerHUDWindow<Content: View>: View {
    private let content: Content
    @State private var portal = RAVEViewerHUDPortal()
    @Environment(\.dismissImmersiveSpace) private var dismissSpace

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        ZStack {
            ViewerWindowMount(portal: portal, content: content)
            if portal.isInHUD {
                VStack(spacing: 16) {
                    Label("Showing in HUD", systemImage: "vision.pro")
                    Button("Return to Window") {
                        Task { await portal.returnToWindow(dismiss: dismissSpace) }
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityIdentifier("rave.hud.window.return")
                    .disabled(portal.isChangingPresentation)
                }
                .padding(32)
                .glassBackgroundEffect()
            }
        }
        .ornament(visibility: portal.controls?.visible == true && !portal.isInHUD ? .visible : .hidden,
                  attachmentAnchor: .scene(.bottomFront), contentAlignment: .top) {
            if let controls = portal.controls {
                controls.view.environment(\.raveViewerHUD, portal)
            }
        }
        .onDisappear {
            portal.controls = nil
            guard RAVEViewerHUDPortal.active === portal else { return }
            Task { await portal.returnToWindow(dismiss: dismissSpace) }
        }
    }
}

private struct HostedViewer<Content: View>: View {
    let content: Content
    let portal: RAVEViewerHUDPortal
    let shell: RAVEWindowShell
    let phase: ScenePhase
    let push: RAVEPushWindowAction
    let detach: RAVEDetachFromStackAction
    let dismiss: RAVEDismissWindowAction?
    let pushed: Bool
    let away: Bool
    let scope: RAVEWindowScope
    let token: UUID?

    init(content: Content, portal: RAVEViewerHUDPortal, values: EnvironmentValues) {
        self.content = content
        self.portal = portal
        shell = values.raveWindowShell ?? RAVEWindowShell(values)
        phase = values.scenePhase
        push = values.ravePushWindow
        detach = values.raveDetachFromStack
        dismiss = values.raveDismissWindow
        pushed = values.raveIsPushedWindow
        away = values.raveIsPushedAway
        scope = values.raveWindowScope
        token = values.raveWindowToken
    }

    var body: some View {
        content
            .environment(\.raveWindowShell, shell)
            .environment(\.scenePhase, portal.isInHUD ? portal.hudPhase : phase)
            .environment(\.ravePushWindow, push)
            .environment(\.raveDetachFromStack, detach)
            .environment(\.raveDismissWindow, dismiss)
            .environment(\.raveIsPushedWindow, pushed)
            .environment(\.raveIsPushedAway, away)
            .environment(\.raveWindowScope, scope)
            .environment(\.raveWindowToken, token)
            .environment(\.raveViewerHUD, portal)
            .onPreferenceChange(HUDControlsKey.self) { value in
                // Detaching a hosting view temporarily clears preferences.
                // Keep the last controls until the source scene closes.
                if let value { portal.controls = value }
            }
    }
}

private struct SourceSceneState: Equatable {
    let phase: ScenePhase
    let pushed: Bool
    let away: Bool
    let scope: RAVEWindowScope
    let token: UUID?
    init(_ values: EnvironmentValues) {
        phase = values.scenePhase
        pushed = values.raveIsPushedWindow
        away = values.raveIsPushedAway
        scope = values.raveWindowScope
        token = values.raveWindowToken
    }
}

private struct ViewerWindowMount<Content: View>: UIViewRepresentable {
    let portal: RAVEViewerHUDPortal
    let content: Content

    final class Coordinator {
        var controller: UIHostingController<HostedViewer<Content>>?
        var root: HostedViewer<Content>?
        var sceneState: SourceSceneState?
        var returnGeneration = 0
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        portal.openSpace = context.environment.openImmersiveSpace
        portal.dismissSpace = context.environment.dismissImmersiveSpace
        container.backgroundColor = .clear
        let coordinator = context.coordinator
        coordinator.root = HostedViewer(content: content, portal: portal, values: context.environment)
        portal.home = container
        // A new hosting root must be created outside the source SwiftUI graph's
        // update transaction; otherwise its state belongs to that source graph.
        DispatchQueue.main.async { [weak container, weak coordinator] in
            guard let container, let coordinator, let root = coordinator.root else { return }
            let controller = UIHostingController(rootView: root)
            controller.view.backgroundColor = .clear
            controller.view.frame = container.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            // Containment gives SwiftUI a real scene for ornaments, sheets,
            // accessibility and responder routing. The controller stays owned
            // by this window while only its live view is lent to the HUD.
            var responder: UIResponder? = container
            while let current = responder, !(current is UIViewController) { responder = current.next }
            if let parent = responder as? UIViewController { parent.addChild(controller) }
            container.addSubview(controller.view)
            controller.didMove(toParent: controller.parent)
            coordinator.controller = controller
            portal.source = controller.view
            if container.bounds.width > 0 { portal.size = container.bounds.size }
        }
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        portal.openSpace = context.environment.openImmersiveSpace
        portal.dismissSpace = context.environment.dismissImmersiveSpace
        let root = HostedViewer(content: content, portal: portal, values: context.environment)
        context.coordinator.root = root
        // Chrome preferences cross back to the source scene. Updating the
        // hosting root for that notification would feed the preference back
        // indefinitely, and would rebind media during a handoff.
        let state = SourceSceneState(context.environment)
        if context.coordinator.sceneState != state || context.coordinator.returnGeneration != portal.returnGeneration {
            context.coordinator.sceneState = state
            context.coordinator.returnGeneration = portal.returnGeneration
            context.coordinator.controller?.rootView = root
        }
        if !portal.isInHUD, container.bounds.width > 0, container.bounds.height > 0 {
            portal.size = container.bounds.size
        }
    }

    static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        coordinator.controller?.willMove(toParent: nil)
        coordinator.controller?.view.removeFromSuperview()
        coordinator.controller?.removeFromParent()
        coordinator.controller = nil
    }
}

private struct ViewerHUDMount: UIViewRepresentable {
    let portal: RAVEViewerHUDPortal
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.frame.size = portal.size
        DispatchQueue.main.async { [weak view] in
            guard let view, RAVEViewerHUDPortal.active === portal else { return }
            portal.mount(in: view)
        }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}

/// Declare this alongside the app's other immersive spaces. A system dismissal
/// returns the live view to its source window as well.
public struct RAVEViewerHUDScene: SwiftUI.Scene {
    public init() {}
    public var body: some SwiftUI.Scene {
        ImmersiveSpace(id: RAVEViewerHUDPortal.spaceID) {
            ViewerHUDSpace()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(.hidden)
        .immersiveEnvironmentBehavior(.coexist)
    }
}

private struct ViewerHUDSpace: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var dragOrigin: SIMD3<Float>?
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    var body: some View {
        Group {
            if let portal = RAVEViewerHUDPortal.active {
                RealityView { content, attachments in
                    let head = AnchorEntity(.head)
                    head.anchoring.trackingMode = .continuous
                    guard let screen = attachments.entity(for: "viewer") else { return }
                    screen.position = portal.offset
                    head.addChild(screen)
                    content.add(head)
                } update: { content, _ in
                    guard let head = content.entities.first,
                          let screen = head.children.first else { return }
                    screen.position = portal.offset
                    // Attachments use points at a fixed physical scale. Use their
                    // measured bounds so the chosen width is independent of DPI.
                    let bounds = screen.visualBounds(relativeTo: screen)
                    if bounds.extents.x > 0 { screen.scale = SIMD3(repeating: portal.width / bounds.extents.x) }
                } attachments: {
                    Attachment(id: "viewer") {
                        hudContent(portal)
                    }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in portal.hudPhase = phase }
                .onDisappear { portal.restore() }
            }
        }
    }
    private func hudContent(_ portal: RAVEViewerHUDPortal) -> some View {
        VStack(spacing: 12) {
            Capsule().fill(.white.opacity(0.8))
                .frame(width: 180, height: 14)
                .padding(16)
                .contentShape(.rect)
                .accessibilityLabel("Move HUD")
                .gesture(DragGesture().onChanged { value in
                    if dragOrigin == nil { dragOrigin = portal.offset }
                    guard let origin = dragOrigin else { return }
                    let scale = portal.width / Float(max(portal.size.width, 1))
                    portal.offset.x = min(0.6, max(-0.6, origin.x + Float(value.translation.width) * scale))
                    portal.offset.y = min(0.5, max(-0.5, origin.y - Float(value.translation.height) * scale))
                }.onEnded { _ in dragOrigin = nil })
            ViewerHUDMount(portal: portal)
                .frame(width: portal.size.width, height: portal.size.height)
            HStack {
                Button("Return to Window", systemImage: "rectangle.on.rectangle") {
                    Task { await portal.returnToWindow(dismiss: dismissSpace) }
                }
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityIdentifier("rave.hud.return")
                .disabled(portal.isChangingPresentation)
                Slider(value: Binding(get: { Double(portal.width) }, set: { portal.width = Float($0) }), in: 0.4...1.8)
                    .frame(width: 180)
                    .accessibilityLabel("HUD size")
                Button("Recenter", systemImage: "scope") { portal.offset = SIMD3(0, 0, -1.3) }
            }
            .padding(12)
            .glassBackgroundEffect()
        }
    }

}

public struct RAVEViewerHUDButton: View {
    @Environment(\.raveViewerHUD) private var portal
    @Environment(\.openImmersiveSpace) private var openSpace
    public init() {}
    public var body: some View {
        if let portal, !portal.isInHUD {
            Button {
                Task { await portal.present(open: portal.openSpace ?? openSpace) }
            } label: {
                Label("HUD", systemImage: "vision.pro")
            }
            .accessibilityIdentifier("rave.hud.enter")
            .disabled(portal.isChangingPresentation)
            .help("Show this viewer in a head-following HUD")
            .alert("HUD Unavailable", isPresented: Binding(get: { portal.error != nil }, set: { if !$0 { portal.error = nil } })) {
                Button("OK") { portal.error = nil }
            } message: { Text(portal.error ?? "") }
        }
    }
}

private struct HUDControlsValue: Equatable {
    let identity = UUID()
    let view: AnyView
    let visible: Bool
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
}

private struct HUDControlsKey: PreferenceKey {
    static var defaultValue: HUDControlsValue? { nil }
    static func reduce(value: inout HUDControlsValue?, nextValue: () -> HUDControlsValue?) {
        if let next = nextValue() { value = next }
    }
}

private struct ViewerControls<Controls: View>: ViewModifier {
    @Environment(\.raveViewerHUD) private var portal
    let visible: Bool
    let controls: Controls
    func body(content: Content) -> some View {
        content
            .preference(key: HUDControlsKey.self, value: HUDControlsValue(view: AnyView(controls), visible: visible))
            .overlay(alignment: .bottom) {
                if portal?.isInHUD == true, visible { controls.padding(.bottom, 12) }
            }
    }
}

extension View {
    /// The same controls float below a window and sit inside the HUD attachment.
    public func raveViewerHUDWindow() -> some View { RAVEViewerHUDWindow { self } }

    public func raveViewerControls<Controls: View>(visible: Bool, @ViewBuilder controls: () -> Controls) -> some View {
        modifier(ViewerControls(visible: visible, controls: controls()))
    }
}
#endif
