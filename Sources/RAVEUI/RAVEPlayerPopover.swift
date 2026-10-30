import SwiftUI

#if os(visionOS)
/// Routes player popovers into a RealityKit attachment when the controls
/// are hosted in an immersive attachment.
@MainActor @Observable
public final class RAVEImmersivePlayerPresentation {
    public nonisolated static let coordinateSpace = "raveImmersivePlayerControls"
    public var controlsSize: CGSize = .zero
    private var entries: [Entry] = []

    private struct Entry: Identifiable {
        let id: UUID
        let content: AnyView
        let sourceFrame: CGRect
        let onDismiss: () -> Void
    }

    public var isPresented: Bool { !entries.isEmpty }
    public var presentationID: UUID? { entries.last?.id }
    public var sourceFrame: CGRect? { entries.last?.sourceFrame }
    public var content: AnyView? {
        guard isPresented else { return nil }
        return AnyView(ZStack(alignment: .bottom) {
            ForEach(entries) { entry in
                let active = entry.id == self.presentationID
                entry.content
                    .frame(height: active ? nil : 0)
                    .clipped()
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
            }
        })
    }

    public init() {}

    public func present<Content: View>(_ content: Content, id: UUID, sourceFrame: CGRect,
                                      parentID: UUID? = nil, onDismiss: @escaping () -> Void) {
        // Keep More mounted under a nested choice: removing it destroys the
        // binding that owns that choice and can leave the chrome stuck.
        let parent = parentID.flatMap { parent in entries.firstIndex { $0.id == parent } }
        let frame = parent.map { entries[$0].sourceFrame } ?? sourceFrame
        removeEntries(from: parent.map { $0 + 1 } ?? 0)
        entries.append(Entry(
            id: id,
            content: AnyView(content
                .environment(\.raveImmersivePlayerPresentation, self)
                .environment(\.raveImmersivePlayerParentID, id)),
            sourceFrame: frame,
            onDismiss: onDismiss
        ))
    }

    public func dismiss(id: UUID? = nil) {
        if let id {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            removeEntries(from: index)
        } else {
            removeEntries(from: 0)
        }
    }

    private func removeEntries(from index: Int) {
        let removed = Array(entries.dropFirst(index))
        entries.removeSubrange(index...)
        for entry in removed.reversed() { entry.onDismiss() }
    }
}

public extension EnvironmentValues {
    @Entry var raveImmersivePlayerPresentation: RAVEImmersivePlayerPresentation? = nil
    @Entry var raveImmersivePlayerParentID: UUID? = nil
}
#endif

private struct RAVEPlayerPopoverModifier<Popover: View>: ViewModifier {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let popup: Popover
    #if os(visionOS)
    @Environment(\.raveImmersivePlayerPresentation) private var immersivePresentation
    @Environment(\.raveImmersivePlayerParentID) private var parentID
    @State private var presentationID = UUID()
    @State private var sourceFrame = CGRect.zero
    #endif

    @ViewBuilder func body(content: Content) -> some View {
        #if os(visionOS)
        if let immersivePresentation {
            content
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(RAVEImmersivePlayerPresentation.coordinateSpace))
                } action: { sourceFrame = $0 }
                .onChange(of: isPresented) { _, shown in
                    if shown {
                        immersivePresentation.present(popup, id: presentationID, sourceFrame: sourceFrame,
                                                      parentID: parentID) { isPresented = false }
                    } else {
                        immersivePresentation.dismiss(id: presentationID)
                    }
                }
                .onDisappear {
                    if isPresented { immersivePresentation.dismiss(id: presentationID) }
                }
        } else {
            content.popover(isPresented: $isPresented, arrowEdge: arrowEdge) { popup }
        }
        #elseif os(tvOS)
        content
        #else
        content.popover(isPresented: $isPresented, arrowEdge: arrowEdge) { popup }
        #endif
    }
}

public extension View {
    /// A normal player popover, or a RealityKit attachment when its host
    /// supplies an immersive player presentation coordinator.
    func ravePlayerPopover<Content: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .bottom,
                                          @ViewBuilder content: () -> Content) -> some View {
        modifier(RAVEPlayerPopoverModifier(isPresented: isPresented, arrowEdge: arrowEdge, popup: content()))
    }
}
