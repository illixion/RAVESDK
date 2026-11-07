/*
 RAVE SDK — retain a window's live SwiftUI hierarchy across scene shells.

 On a push, keep the app-owned UIKit window and hosting hierarchy in memory,
 remove the window from its scene, and close the empty scene shell. Return
 opens a fresh UUID shell at the user and moves the same UIKit window into it.
 No scene or compositor placement remains alive while the content is parked.
 Create the hosting root outside SwiftUI's update transaction: otherwise its
 state graph belongs to the source and is invalidated when that scene closes.
 */

#if os(visionOS)
import SwiftUI
import UIKit

@MainActor
@Observable
/// The current scene attachment of retained content, without retaining the
/// source scene or its SwiftUI environment graph.
public final class RAVEWindowShell {
    /// Changes only when retained content is presented in a replacement shell.
    public fileprivate(set) var presentationID = UUID()
    public fileprivate(set) var openWindow: OpenWindowAction
    public fileprivate(set) var dismissWindow: DismissWindowAction
    public fileprivate(set) weak var scene: UIWindowScene?
    fileprivate var push: RAVEPushWindowAction
    fileprivate var detach: RAVEDetachFromStackAction
    fileprivate var dismiss: RAVEDismissWindowAction?
    fileprivate var phase: ScenePhase
    fileprivate var away: Bool
    fileprivate var pushed: Bool
    fileprivate var token: UUID?
    fileprivate var scope: RAVEWindowScope

    fileprivate init(_ values: EnvironmentValues) {
        openWindow = values.openWindow
        dismissWindow = values.dismissWindow
        push = values.ravePushWindow
        detach = values.raveDetachFromStack
        dismiss = values.raveDismissWindow
        phase = values.scenePhase
        away = values.raveIsPushedAway
        pushed = values.raveIsPushedWindow
        token = values.raveWindowToken
        scope = values.raveWindowScope
    }

    fileprivate func update(_ values: EnvironmentValues) {
        openWindow = values.openWindow
        dismissWindow = values.dismissWindow
        push = values.ravePushWindow
        detach = values.raveDetachFromStack
        dismiss = values.raveDismissWindow
        phase = values.scenePhase
        away = values.raveIsPushedAway
        pushed = values.raveIsPushedWindow
        token = values.raveWindowToken
        scope = values.raveWindowScope
    }
}

private struct WindowShellKey: EnvironmentKey {
    static let defaultValue: RAVEWindowShell? = nil
}

public extension EnvironmentValues {
    /// Scene actions for retained content. Native SwiftUI actions are scoped
    /// to a hosting root; use these to address the current outer scene shell.
    var raveWindowShell: RAVEWindowShell? {
        get { self[WindowShellKey.self] }
        set { self[WindowShellKey.self] = newValue }
    }
}

private struct RetainedWindowRoot<Content: View>: View {
    let content: Content
    let environment: RAVEWindowShell

    var body: some View {
        // Never copy EnvironmentValues wholesale across hosting roots: it
        // carries SwiftUI graph and scene-storage references from the source.
        content
            .environment(\.raveWindowShell, environment)
            .environment(\.ravePushWindow, environment.push)
            .environment(\.raveDetachFromStack, environment.detach)
            .environment(\.raveDismissWindow, environment.dismiss)
            .environment(\.raveIsPushedAway, environment.away)
            .environment(\.raveIsPushedWindow, environment.pushed)
            .environment(\.scenePhase, environment.phase)
            .environment(\.raveWindowToken, environment.token)
            .environment(\.raveWindowScope, environment.scope)
    }
}

@MainActor
private final class RetainedWindowContent {
    private var controller: UIHostingController<AnyView>?
    private let root: AnyView
    let environment: RAVEWindowShell
    private var window: UIWindow?
    private(set) var returnSize: CGSize?

    init<Content: View>(content: Content, environment: EnvironmentValues) {
        let environment = RAVEWindowShell(environment)
        self.environment = environment
        root = AnyView(RetainedWindowRoot(content: content, environment: environment))
    }

    func attach(to scene: UIWindowScene) {
        if window != nil, window?.windowScene !== scene {
            environment.presentationID = UUID()
        }
        environment.scene = scene
        if let window {
            window.windowScene = scene
        } else {
            let window = UIWindow(windowScene: scene)
            let controller = UIHostingController(rootView: root)
            self.controller = controller
            window.backgroundColor = .clear
            window.rootViewController = controller
            controller.view.backgroundColor = .clear
            self.window = window
        }
        resize(in: scene)
        window?.makeKeyAndVisible()
    }

    func resize(in scene: UIWindowScene) {
        window?.frame = scene.coordinateSpace.bounds
    }

    func park() {
        returnSize = window?.bounds.size
        window?.isHidden = true
        // The window and hosting hierarchy remain owned by this object, but
        // no UIScene/compositor placement is kept alive for them.
        window?.windowScene = nil
        environment.scene = nil
        environment.phase = .inactive
    }
}

@MainActor
private enum RetainedWindowHandoff {
    struct Entry {
        let content: RetainedWindowContent
        let ready: () -> Void
    }
    static var pending: [UUID: Entry] = [:]

    static func deposit(_ content: RetainedWindowContent, id: UUID, ready: @escaping () -> Void) {
        pending[id] = Entry(content: content, ready: ready)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            pending[id] = nil
        }
    }
}

private struct RetainedWindowContainer<WindowContent: View>: UIViewControllerRepresentable {
    let sceneID: String
    let value: UUID
    let content: WindowContent

    func makeUIViewController(context: Context) -> Container {
        let handoff = RetainedWindowHandoff.pending.removeValue(forKey: value)
        let retained = handoff?.content ?? RetainedWindowContent(content: content, environment: context.environment)
        return Container(retained: retained, ready: handoff?.ready)
    }

    func updateUIViewController(_ container: Container, context: Context) {
        guard !container.parked else { return }
        container.retained.environment.update(context.environment)
        let environment = context.environment
        guard let token = environment.ravePushWindow.source else { return }
        let open = environment.openWindow
        let dismiss = environment.dismissWindow
        let retained = container.retained
        RAVEWindowPushCoordinator.shared.retainSource(.init(
            park: { [weak container] in
                container?.park()
                dismiss(id: sceneID, value: value)
            },
            restore: { ready in
                let replacement = UUID()
                RAVEWindowPushCoordinator.shared.restoreSize(sceneID: sceneID, value: replacement, size: retained.returnSize)
                RetainedWindowHandoff.deposit(retained, id: replacement, ready: ready)
                open(id: sceneID, value: replacement)
            }
        ), token: token)
    }

    final class Container: UIViewController {
        let retained: RetainedWindowContent
        private(set) var parked = false
        private var ready: (() -> Void)?

        init(retained: RetainedWindowContent, ready: (() -> Void)?) {
            self.retained = retained
            self.ready = ready
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !parked else { return }
            if let scene = view.window?.windowScene {
                // Create an independent hosting root outside SwiftUI's update
                // transaction; it must not inherit the source's state graph.
                DispatchQueue.main.async { [weak self, weak scene] in
                    guard let self, !self.parked, let scene else { return }
                    self.retained.attach(to: scene)
                    let ready = self.ready
                    self.ready = nil
                    ready?()
                }
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if !parked, let scene = view.window?.windowScene { retained.resize(in: scene) }
        }

        func park() {
            guard !parked else { return }
            parked = true
            retained.park()
        }
    }
}

public extension View {
    /// Retain a live hierarchy in an app-owned UIKit window across scene shells.
    /// Apply inside `raveWindowPushHost`, after app-specific environment values.
    /// Keep shell lifecycle modifiers outside this modifier. The scene must be
    /// UUID keyed. Use `raveWindowShell` for native scene actions and geometry.
    func raveRetainedWindowContent(sceneID: String, value: UUID) -> some View {
        RetainedWindowContainer(sceneID: sceneID, value: value, content: self)
    }
}
#endif
