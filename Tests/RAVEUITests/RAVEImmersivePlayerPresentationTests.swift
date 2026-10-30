#if os(visionOS)
import SwiftUI
import Testing
@testable import RAVEUI

@MainActor
@Suite("Immersive player menus")
struct RAVEImmersivePlayerPresentationTests {
    @Test("Switching bar buttons dismisses the old binding without closing the new menu")
    func switchingButtons() {
        let presentation = RAVEImmersivePlayerPresentation()
        let first = UUID()
        let second = UUID()
        var closed = 0
        let source = CGRect(x: 700, y: 80, width: 44, height: 44)
        presentation.present(Text("Volume"), id: first, sourceFrame: .zero) { closed += 1 }
        presentation.present(Text("Quality"), id: second, sourceFrame: source) {}

        #expect(closed == 1)
        #expect(presentation.presentationID == second)
        #expect(presentation.sourceFrame == source)
        presentation.dismiss(id: first)
        #expect(presentation.presentationID == second)
    }

    @Test("A nested choice retains More and returns to it when closed")
    func nestedChoice() {
        let presentation = RAVEImmersivePlayerPresentation()
        let more = UUID()
        let child = UUID()
        let source = CGRect(x: 900, y: 80, width: 44, height: 44)
        var moreClosed = 0
        var childClosed = 0
        presentation.present(Text("More"), id: more, sourceFrame: source) { moreClosed += 1 }
        presentation.present(Text("Speed"), id: child, sourceFrame: .zero, parentID: more) { childClosed += 1 }

        #expect(moreClosed == 0)
        #expect(presentation.presentationID == child)
        #expect(presentation.sourceFrame == source)
        presentation.dismiss(id: child)
        #expect(childClosed == 1)
        #expect(moreClosed == 0)
        #expect(presentation.presentationID == more)
        #expect(presentation.isPresented)
    }

    @Test("Dismissal clears nested bindings deepest first and only once")
    func dismissingAll() {
        let presentation = RAVEImmersivePlayerPresentation()
        let more = UUID()
        let child = UUID()
        var closed: [String] = []
        presentation.present(Text("More"), id: more, sourceFrame: .zero) { closed.append("more") }
        presentation.present(Text("Speed"), id: child, sourceFrame: .zero, parentID: more) {
            presentation.dismiss(id: child)
            closed.append("child")
        }
        presentation.dismiss()
        presentation.dismiss()

        #expect(closed == ["child", "more"])
        #expect(!presentation.isPresented)
        #expect(presentation.content == nil)
        #expect(presentation.sourceFrame == nil)
    }

    @Test("A sibling submenu replaces descendants without dismissing their parent")
    func switchingSubmenus() {
        let presentation = RAVEImmersivePlayerPresentation()
        let more = UUID()
        let first = UUID()
        let second = UUID()
        var moreClosed = 0
        var firstClosed = 0
        presentation.present(Text("More"), id: more, sourceFrame: .zero) { moreClosed += 1 }
        presentation.present(Text("Speed"), id: first, sourceFrame: .zero, parentID: more) { firstClosed += 1 }
        presentation.present(Text("Audio"), id: second, sourceFrame: .zero, parentID: more) {}

        #expect(firstClosed == 1)
        #expect(moreClosed == 0)
        #expect(presentation.presentationID == second)
        presentation.dismiss(id: more)
        #expect(moreClosed == 1)
        #expect(!presentation.isPresented)
    }
}
#endif
