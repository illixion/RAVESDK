import Testing
@testable import RAVEUI

@Suite("RAVEWindowScope")
struct RAVEWindowScopeTests {
    @Test("The process scope takes every window, an unknown id included")
    func process() {
        #expect(RAVEWindowScope.process.contains(sceneID: "orbit.main"))
        #expect(RAVEWindowScope.process.contains(sceneID: nil))
    }

    @Test("A prefix scope takes only its own windows and never an unknown one")
    func prefix() {
        let scope = RAVEWindowScope.prefix("convolution.")
        #expect(scope.contains(sceneID: "convolution.main"))
        #expect(scope.contains(sceneID: "convolution.photo"))
        #expect(!scope.contains(sceneID: "nexus.home"))
        #expect(!scope.contains(sceneID: "main"))
        #expect(!scope.contains(sceneID: nil))
    }

    @Test("An id scope matches exactly")
    func ids() {
        let scope = RAVEWindowScope.ids(["orbit.main"])
        #expect(scope.contains(sceneID: "orbit.main"))
        #expect(!scope.contains(sceneID: "orbit.main.2"))
        #expect(!scope.contains(sceneID: nil))
    }

    @Test("A module's registry counts apart from the shared one and opens its own main window id")
    @MainActor
    func moduleRegistry() {
        let module = RAVEWindowSessionRegistry(mainWindowID: "convolution.main")
        let before = RAVEWindowSessionRegistry.shared.mainWindowCount
        module.registerMainWindow()
        #expect(module.mainWindowCount == 1)
        #expect(module.mainWindowID == "convolution.main")
        #expect(RAVEWindowSessionRegistry.shared.mainWindowCount == before)
        module.unregisterMainWindow()
        #expect(module.mainWindowCount == 0)
    }
}
