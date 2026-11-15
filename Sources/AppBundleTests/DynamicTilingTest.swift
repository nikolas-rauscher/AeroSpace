@testable import AppBundle
import Common
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct DynamicTilingTest {
    init() {
        setUpWorkspacesForTests()
        config.dynamicTiling.enabled = true
    }

    @Test func capacityAccountsForGapsAndRetinaPoints() {
        #expect(dynamicTilingCapacity(width: 1774, gap: 13, minimumWidth: 560, maximum: 3) == 3)
        #expect(dynamicTilingCapacity(width: 1414, gap: 13, minimumWidth: 560, maximum: 3) == 2)
        #expect(dynamicTilingCapacity(width: 1100, gap: 13, minimumWidth: 560, maximum: 3) == 1)
        #expect(dynamicTilingCapacity(width: 400, gap: 13, minimumWidth: 560, maximum: 3) == 1)
        #expect(dynamicTilingCapacity(width: 6000, gap: 13, minimumWidth: 560, maximum: 3) == 3)
        #expect(dynamicTilingCapacity(width: 1774, gap: 13, minimumWidth: 560, maximum: 2) == 2)
    }

    @Test func flattensVerticalTreeAndEqualizesColumns() {
        let workspace = Workspace.get(byName: "a")
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)
        let nested = TilingContainer.newVTiles(parent: root, adaptiveWeight: 20, index: INDEX_BIND_LAST)
        let first = TestWindow.new(id: 1, parent: nested)
        let second = TestWindow.new(id: 2, parent: nested)
        let third = TestWindow.new(id: 3, parent: root, adaptiveWeight: 80)
        #expect(second.focusWindow())
        applyDynamicTiling(to: [workspace])
        #expect(root.orientation == .h)
        #expect(root.layout == .tiles)
        #expect(root.children == [first, second, third])
        #expect(root.children.allSatisfy { $0.getWeight(.h) == first.getWeight(.h) })
        #expect(globalFocus.windowOrNil === second)
        applyDynamicTiling(to: [workspace])
        #expect(root.children == [first, second, third])
    }

    @Test func overflowUsesAnotherVisibleWorkspaceBeforeCreatingOne() {
        let source = Workspace.get(byName: "a")
        let other = Workspace.get(byName: "b")
        for id: OpaqueWindowId in [1, 2, 3, 4] { TestWindow.new(id: id, parent: source.rootTilingContainer) }
        TestWindow.new(id: 5, parent: other.rootTilingContainer)
        #expect(Window.get(byId: 4)?.focusWindow() == true)
        applyDynamicTiling(to: [source, other])
        #expect(dynamicTilingWindows(source).map(\.windowId) == [1, 2, 3])
        #expect(dynamicTilingWindows(other).map(\.windowId) == [5, 4])
        #expect(globalFocus.windowOrNil?.windowId == 4)
        #expect(globalFocus.workspace === other)
    }

    @Test func overflowCreatesWorkspaceAndPreservesEveryWindow() {
        let workspace = Workspace.get(byName: "a")
        for id: OpaqueWindowId in [1, 2, 3, 4, 5, 6, 7] { TestWindow.new(id: id, parent: workspace.rootTilingContainer) }
        #expect(Window.get(byId: 7)?.focusWindow() == true)
        applyDynamicTiling(to: [workspace])
        #expect(dynamicTilingWindows(workspace).map(\.windowId) == [1, 2, 3])
        #expect(dynamicTilingWindows(Workspace.get(byName: "auto-1")).map(\.windowId) == [4, 5, 6])
        #expect(dynamicTilingWindows(Workspace.get(byName: "auto-2")).map(\.windowId) == [7])
        #expect(globalFocus.workspace.name == "auto-2")
    }

    @Test func smallerCapacityAndFloatingWindows() {
        config.dynamicTiling.minimumWindowWidth = 800
        let workspace = Workspace.get(byName: "a")
        for id: OpaqueWindowId in [1, 2, 3] { TestWindow.new(id: id, parent: workspace.rootTilingContainer) }
        let floating = TestWindow.new(id: 4, parent: workspace.floatingWindowsContainer)
        applyDynamicTiling(to: [workspace])
        #expect(dynamicTilingWindows(workspace).count == 2)
        #expect(floating.isFloating)
        #expect(floating.nodeWorkspace === workspace)
    }

    @Test func fullscreenOverrideAndDisabledModePreserveManualLayout() {
        let workspace = Workspace.get(byName: "a")
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)
        let first = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        first.isFullscreen = true
        applyDynamicTiling(to: [workspace])
        #expect(root.orientation == .v)
        first.isFullscreen = false
        config.dynamicTiling.enabled = false
        applyDynamicTiling(to: [workspace])
        #expect(root.orientation == .v)
    }

    @Test func parsesOptionsAndRejectsUnsafeValues() {
        let good = parseConfig("""
            fast-app-switching = true
            [dynamic-tiling]
            enabled = true
            max-windows = 2
            minimum-window-width = 650
            """)
        #expect(good.errors.isEmpty)
        #expect(good.config.dynamicTiling.maxWindows == 2)
        #expect(good.config.fastAppSwitching)
        #expect(!parseConfig("dynamic-tiling.max-windows = 4").errors.isEmpty)
        #expect(!parseConfig("dynamic-tiling.minimum-window-width = 0").errors.isEmpty)
        #expect(parseConfig("dynamic-tiling.app-minimum-widths.'net.whatsapp.WhatsApp' = 800").config.dynamicTiling.appMinimumWidths["net.whatsapp.WhatsApp"] == 800)
        #expect(!parseConfig("dynamic-tiling.app-minimum-widths.'example.app' = -1").errors.isEmpty)
    }

    @Test func wideWindowGetsSpaceInsteadOfOverlappingItsNeighbour() {
        #expect(dynamicColumnWidths(width: 1774, gap: 13, minimums: [1000, 560]) == [1000, 761])
        let equalWidths = Array(repeating: CGFloat(1748) / 3, count: 3)
        #expect(dynamicColumnWidths(width: 1774, gap: 13, minimums: [560, 560, 560]) == equalWidths)
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let wide = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        wide.minimumTilingWidth = 1400
        applyDynamicTiling(to: [workspace])
        #expect(dynamicTilingWindows(workspace).map(\.windowId) == [1, 2])
        #expect(wide.nodeWorkspace?.name == "auto-1")
    }

    @Test func learnsRejectedWidthButIgnoresStaleOrFloatingResize() {
        let workspace = Workspace.get(byName: "a")
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        window.lastAppliedLayoutPhysicalRect = .init(topLeftX: 0, topLeftY: 0, width: 580, height: 1000)
        #expect(recordDynamicTilingMinimumWidth(window, requested: 580, actual: 800))
        #expect(window.minimumTilingWidth == 800)
        #expect(!recordDynamicTilingMinimumWidth(window, requested: 590, actual: 900))
        #expect(!recordDynamicTilingMinimumWidth(window, requested: 580, actual: 700))
        window.bindAsFloatingWindow(to: workspace)
        #expect(!recordDynamicTilingMinimumWidth(window, requested: 580, actual: 900))
    }
}
