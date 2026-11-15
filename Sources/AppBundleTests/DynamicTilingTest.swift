@testable import AppBundle
import AppKit
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

    private func frames(_ count: Int, width: CGFloat = 1800, height: CGFloat = 1100,
                        minimumWidths: [CGFloat]? = nil, minimumHeights: [CGFloat]? = nil) -> [Rect]?
    {
        dynamicTilingFrames(width: width, height: height, horizontalGap: 12, verticalGap: 10,
                            minimumWidths: minimumWidths ?? Array(repeating: 560, count: count),
                            minimumHeights: minimumHeights ?? Array(repeating: 320, count: count))
    }

    private func expectFrame(_ frame: Rect, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        #expect(abs(frame.minX - x) < 0.0001)
        #expect(abs(frame.minY - y) < 0.0001)
        #expect(abs(frame.width - width) < 0.0001)
        #expect(abs(frame.height - height) < 0.0001)
    }

    private func treeShape(_ node: TreeNode) -> String {
        if let window = node as? Window { return window.windowId.description }
        guard let container = node as? TilingContainer else { return "unexpected" }
        let axis = container.orientation == .h ? "h" : "v"
        return axis + "[" + container.children.map(treeShape).joined(separator: ",") + "]"
    }

    @Test func singletonAndPairUseFullHeightAndRetinaPoints() throws {
        #expect(frames(0)?.isEmpty == true)
        let single = try #require(frames(1, width: 400, height: 250))
        expectFrame(single[0], x: 0, y: 0, width: 400, height: 250)
        let pair = try #require(frames(2))
        expectFrame(pair[0], x: 0, y: 0, width: 894, height: 1100)
        expectFrame(pair[1], x: 906, y: 0, width: 894, height: 1100)
        #expect(frames(2, width: 1100) == nil)
    }

    @Test func threeWindowsGiveMasterLeftAndTwoStackedRight() throws {
        let result = try #require(frames(3))
        #expect(result.count == 3)
        expectFrame(result[0], x: 0, y: 0, width: 894, height: 1100)
        expectFrame(result[1], x: 906, y: 0, width: 894, height: 545)
        expectFrame(result[2], x: 906, y: 555, width: 894, height: 545)
    }

    @Test func fourWindowsUseEveryCornerWithStableColumnMajorOrder() throws {
        let result = try #require(frames(4))
        #expect(result.count == 4)
        expectFrame(result[0], x: 0, y: 0, width: 894, height: 545)
        expectFrame(result[1], x: 0, y: 555, width: 894, height: 545)
        expectFrame(result[2], x: 906, y: 0, width: 894, height: 545)
        expectFrame(result[3], x: 906, y: 555, width: 894, height: 545)
        #expect(frames(5) == nil)
    }

    @Test func plannedFramesStayInsideDisplayWithoutOverlap() throws {
        for count in 1 ... 4 {
            let result = try #require(frames(count))
            for (index, frame) in result.enumerated() {
                #expect(frame.minX >= 0)
                #expect(frame.minY >= 0)
                #expect(frame.maxX <= 1800)
                #expect(frame.maxY <= 1100)
                for other in result.dropFirst(index + 1) {
                    let separated = frame.maxX <= other.minX || other.maxX <= frame.minX ||
                        frame.maxY <= other.minY || other.maxY <= frame.minY
                    #expect(separated)
                }
            }
        }
    }

    @Test func nativeLayoutWritesThePlannedFramesWithBothGaps() async throws {
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 12), outer: .zero)
        let workspace = Workspace.get(byName: "physical-frames")
        var windows: [FrameProbeWindow] = []
        for id: OpaqueWindowId in [1, 2, 3, 4] {
            windows.append(FrameProbeWindow(id: id, parent: workspace.rootTilingContainer))
            applyDynamicTiling(to: [workspace])
            try await workspace.layoutWorkspace()
            let planned = try #require(frames(windows.count, width: 1920, height: 1079))
            for (window, expected) in zip(windows, planned) {
                let actual = try #require(window.appliedFrame)
                expectFrame(actual, x: expected.minX, y: expected.minY, width: expected.width, height: expected.height)
                #expect(window.lastAppliedLayoutVirtualRect != nil)
            }
        }
    }

    @Test func rebuildingGridPreservesInvisibleTabsAndRetiresStaleAncestors() async throws {
        for flatten in [false, true] {
            for oppositeOrientation in [false, true] {
                setUpWorkspacesForTests()
                config.dynamicTiling.enabled = true
                config.enableNormalizationFlattenContainers = flatten
                config.enableNormalizationOppositeOrientationForNestedContainers = oppositeOrientation
                config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 12), outer: .zero)
                let workspace = Workspace.get(byName: "native-tab-tombstones")
                let root = workspace.rootTilingContainer
                root.changeOrientation(.v)
                root.layout = .accordion
                let oldStack = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                let oldTabs = TilingContainer.newHTiles(parent: oldStack, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                let firstInvisible = TestWindow.new(id: 90, parent: oldTabs)
                let secondInvisible = TestWindow.new(id: 91, parent: oldTabs)
                firstInvisible.lifeStatus = .invisible
                secondInvisible.lifeStatus = .invisible
                let live = [
                    FrameProbeWindow(id: 1, parent: oldTabs),
                    FrameProbeWindow(id: 2, parent: oldTabs),
                    FrameProbeWindow(id: 3, parent: root),
                    FrameProbeWindow(id: 4, parent: root),
                ]
                #expect(live[1].focusWindow())
                // These ancestors still look alive until the rebuild moves
                // their live children out and normalization refreshes them.
                #expect(oldStack.lifeStatus == .alive)
                #expect(oldTabs.lifeStatus == .alive)

                applyDynamicTiling(to: [workspace])
                try await workspace.layoutWorkspace()
                #expect(root.layout == .tiles)
                #expect(root.orientation == .h)
                #expect(root.inhabitedChildren.map(treeShape) == ["v[1,2]", "v[3,4]"])
                #expect(dynamicTilingWindows(workspace).map(\.windowId) == [1, 2, 3, 4])
                #expect(firstInvisible.parent != nil)
                #expect(secondInvisible.parent != nil)
                #expect(firstInvisible.nodeWorkspace === workspace)
                #expect(secondInvisible.nodeWorkspace === workspace)
                #expect(firstInvisible.lifeStatus == .invisible)
                #expect(secondInvisible.lifeStatus == .invisible)
                #expect(globalFocus.windowOrNil === live[1])
                let planned = try #require(frames(4, width: 1920, height: 1079))
                for (window, expected) in zip(live, planned) {
                    let actual = try #require(window.appliedFrame)
                    expectFrame(actual, x: expected.minX, y: expected.minY, width: expected.width, height: expected.height)
                }
                let activeColumns = root.inhabitedChildren
                applyDynamicTiling(to: [workspace])
                #expect(root.inhabitedChildren == activeColumns)
                #expect(firstInvisible.nodeWorkspace === workspace)
                #expect(secondInvisible.nodeWorkspace === workspace)
            }
        }
    }

    @Test func widthAndHeightConstraintsAreCheckedPerSharedColumn() throws {
        let wideMaster = try #require(frames(3, minimumWidths: [1000, 560, 560]))
        expectFrame(wideMaster[0], x: 0, y: 0, width: 1000, height: 1100)
        expectFrame(wideMaster[1], x: 1012, y: 0, width: 788, height: 545)
        // Right-hand windows share a column, so use its maximum width rather
        // than adding both widths as though they were separate columns.
        #expect(frames(3, minimumWidths: [560, 800, 800]) != nil)
        #expect(frames(3, minimumWidths: [1000, 900, 900]) == nil)
        // Capacity is not monotonic: two wide windows can share the left
        // column of a grid even when this three-window prefix cannot fit.
        #expect(frames(3, minimumWidths: [1000, 1000, 560]) == nil)
        #expect(frames(4, minimumWidths: [1000, 1000, 560, 560]) != nil)
        #expect(frames(3, minimumHeights: [900, 600, 600]) == nil)
        #expect(frames(4, minimumHeights: [600, 600, 320, 320]) == nil)
        let tallerTop = try #require(frames(3, minimumHeights: [320, 650, 320]))
        expectFrame(tallerTop[1], x: 906, y: 0, width: 894, height: 650)
        expectFrame(tallerTop[2], x: 906, y: 660, width: 894, height: 440)
        let alignedGrid = try #require(frames(4, minimumHeights: [650, 320, 320, 400]))
        #expect(alignedGrid[0].height == alignedGrid[2].height)
        #expect(alignedGrid[1].minY == alignedGrid[3].minY)
        #expect(alignedGrid[0].height >= 650)
        #expect(alignedGrid[3].height >= 400)
    }

    @Test func inactiveOnlyWorkspaceKeepsItsTabsWithoutCreatingTiles() {
        let workspace = Workspace.get(byName: "inactive-only")
        let stack = TilingContainer.newVTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let tab = TestWindow.new(id: 90, parent: stack)
        tab.lifeStatus = .invisible
        applyDynamicTiling(to: [workspace])
        #expect(dynamicTilingWindows(workspace).isEmpty)
        #expect(workspace.rootTilingContainer.inhabitedChildren.isEmpty)
        #expect(tab.nodeWorkspace === workspace)
        #expect(tab.lifeStatus == .invisible)
    }

    @Test func changingWindowCountRebuildsTreeAndPreservesFocusAndOrder() async {
        let workspace = Workspace.get(byName: "a")
        let root = workspace.rootTilingContainer
        root.changeOrientation(.v)
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        #expect(second.focusWindow())
        applyDynamicTiling(to: [workspace])
        #expect(treeShape(root) == "h[1,2]")

        let third = TestWindow.new(id: 3, parent: root)
        applyDynamicTiling(to: [workspace])
        #expect(treeShape(root) == "h[1,v[2,3]]")
        #expect(globalFocus.windowOrNil === second)
        let tripleChildren = root.children
        applyDynamicTiling(to: [workspace])
        #expect(root.children == tripleChildren)
        #expect(dynamicTilingWindows(workspace).map(\.windowId) == [1, 2, 3])
        await parseCommand("focus down").cmdOrDie.run(.defaultEnv, .emptyStdin)
        #expect(globalFocus.windowOrNil === third)
        await parseCommand("focus up").cmdOrDie.run(.defaultEnv, .emptyStdin)
        #expect(globalFocus.windowOrNil === second)
        await parseCommand("focus left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        #expect(globalFocus.windowOrNil === first)

        let fourth = TestWindow.new(id: 4, parent: root)
        applyDynamicTiling(to: [workspace])
        #expect(treeShape(root) == "h[v[1,2],v[3,4]]")
        let gridChildren = root.children
        applyDynamicTiling(to: [workspace])
        #expect(root.children == gridChildren)
        #expect(dynamicTilingWindows(workspace).map(\.windowId) == [1, 2, 3, 4])
        await parseCommand("focus down").cmdOrDie.run(.defaultEnv, .emptyStdin)
        #expect(globalFocus.windowOrNil === second)

        fourth.closeAxWindow()
        applyDynamicTiling(to: [workspace])
        #expect(treeShape(root) == "h[1,v[2,3]]")
        third.closeAxWindow()
        applyDynamicTiling(to: [workspace])
        #expect(treeShape(root) == "h[1,2]")
        #expect(globalFocus.windowOrNil === second)
    }

    @Test func fifthWindowUsesAnotherWorkspaceAndFollowsFocusedWindow() {
        let source = Workspace.get(byName: "a")
        let other = Workspace.get(byName: "b")
        for id: OpaqueWindowId in [1, 2, 3, 4, 5] { TestWindow.new(id: id, parent: source.rootTilingContainer) }
        TestWindow.new(id: 6, parent: other.rootTilingContainer)
        #expect(Window.get(byId: 5)?.focusWindow() == true)
        applyDynamicTiling(to: [source, other])
        #expect(dynamicTilingWindows(source).map(\.windowId) == [1, 2, 3, 4])
        #expect(dynamicTilingWindows(other).map(\.windowId) == [6, 5])
        #expect(globalFocus.windowOrNil?.windowId == 5)
        #expect(globalFocus.workspace === other)
    }

    @Test func overflowCreatesWorkspaceAndPreservesEveryWindow() {
        let workspace = Workspace.get(byName: "a")
        for id: OpaqueWindowId in [1, 2, 3, 4, 5, 6, 7] { TestWindow.new(id: id, parent: workspace.rootTilingContainer) }
        #expect(Window.get(byId: 7)?.focusWindow() == true)
        applyDynamicTiling(to: [workspace])
        #expect(dynamicTilingWindows(workspace).map(\.windowId) == [1, 2, 3, 4])
        #expect(dynamicTilingWindows(Workspace.get(byName: "auto-1")).map(\.windowId) == [5, 6, 7])
        #expect(globalFocus.workspace.name == "auto-1")
    }

    @Test func rejectedHeightSpillsInsteadOfCreatingShortOverlappingTiles() {
        let workspace = Workspace.get(byName: "a")
        for id: OpaqueWindowId in [1, 2, 3] {
            TestWindow.new(id: id, parent: workspace.rootTilingContainer).minimumTilingHeight = 700
        }
        let floating = TestWindow.new(id: 4, parent: workspace.floatingWindowsContainer)
        applyDynamicTiling(to: [workspace])
        #expect(dynamicTilingWindows(workspace).count == 2)
        #expect(dynamicTilingWindows(Workspace.get(byName: "auto-1")).count == 1)
        #expect(floating.isFloating)
        #expect(floating.nodeWorkspace === workspace)
    }

    @Test func wideWindowCanOverflowWhileTwoNarrowWindowsRemain() {
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let wide = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        wide.minimumTilingWidth = 1400
        applyDynamicTiling(to: [workspace])
        #expect(dynamicTilingWindows(workspace).map(\.windowId) == [1, 2])
        #expect(wide.nodeWorkspace?.name == "auto-1")
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

    @Test func parsesFourWindowLimitAndBothMinimumDimensions() {
        let good = parseConfig("""
            fast-app-switching = true
            [dynamic-tiling]
            enabled = true
            max-windows = 4
            minimum-window-width = 650
            minimum-window-height = 350
            app-minimum-widths = { 'net.whatsapp.WhatsApp' = 800 }
            app-minimum-heights = { 'net.whatsapp.WhatsApp' = 600 }
            """)
        #expect(good.errors.isEmpty)
        #expect(good.config.dynamicTiling.maxWindows == 4)
        #expect(good.config.dynamicTiling.minimumWindowHeight == 350)
        #expect(good.config.dynamicTiling.appMinimumWidths["net.whatsapp.WhatsApp"] == 800)
        #expect(good.config.dynamicTiling.appMinimumHeights["net.whatsapp.WhatsApp"] == 600)
        #expect(good.config.fastAppSwitching)
        #expect(!parseConfig("dynamic-tiling.max-windows = 5").errors.isEmpty)
        #expect(!parseConfig("dynamic-tiling.minimum-window-width = 0").errors.isEmpty)
        #expect(!parseConfig("dynamic-tiling.minimum-window-height = 0").errors.isEmpty)
        #expect(!parseConfig("dynamic-tiling.app-minimum-heights.'example.app' = -1").errors.isEmpty)
    }

    @Test func learnsRejectedDimensionsButIgnoresStaleOrFloatingResize() {
        let workspace = Workspace.get(byName: "a")
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let requested = CGSize(width: 580, height: 450)
        window.lastAppliedLayoutPhysicalRect = .init(topLeftX: 0, topLeftY: 0, width: requested.width, height: requested.height)
        #expect(recordDynamicTilingMinimumSize(window, requested: requested, actual: CGSize(width: 800, height: 600)))
        #expect(window.minimumTilingWidth == 800)
        #expect(window.minimumTilingHeight == 600)
        #expect(!recordDynamicTilingMinimumSize(window, requested: CGSize(width: 590, height: 450), actual: CGSize(width: 900, height: 700)))
        #expect(!recordDynamicTilingMinimumSize(window, requested: requested, actual: CGSize(width: 700, height: 500)))
        #expect(recordDynamicTilingMinimumSize(window, requested: requested, actual: CGSize(width: 700, height: 700)))
        #expect(window.minimumTilingWidth == 800)
        #expect(window.minimumTilingHeight == 700)
        window.isFullscreen = true
        #expect(!recordDynamicTilingMinimumSize(window, requested: requested, actual: CGSize(width: 900, height: 700)))
        window.isFullscreen = false
        for status in [WindowLifeStatus.invisible, .dead] {
            window.lifeStatus = status
            #expect(!recordDynamicTilingMinimumSize(window, requested: requested, actual: CGSize(width: 900, height: 700)))
        }
        window.lifeStatus = .alive
        window.bindAsFloatingWindow(to: workspace)
        #expect(!recordDynamicTilingMinimumSize(window, requested: requested, actual: CGSize(width: 900, height: 700)))
    }
}

private final class FrameProbeWindow: Window {
    var appliedFrame: Rect?

    @MainActor init(id: OpaqueWindowId, parent: NonLeafTreeNodeObject) {
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }

    @MainActor override func setAxFrame(_ topLeft: Point?, _ size: CGSize?) {
        let origin = topLeft ?? appliedFrame?.topLeftCorner ?? .zero
        let size = size ?? appliedFrame?.size ?? .zero
        appliedFrame = Rect(topLeftX: origin.x, topLeftY: origin.y, width: size.width, height: size.height)
    }
}
