import AppKit
import Common

/// Physical rectangles in stable column-major order, matching the native tree.
func dynamicTilingFrames(width: CGFloat, height: CGFloat, horizontalGap: CGFloat, verticalGap: CGFloat,
                         minimumWidths: [CGFloat], minimumHeights: [CGFloat]) -> [Rect]? {
    let count = minimumWidths.count
    guard count == minimumHeights.count, count <= 4 else { return nil }
    if count == 0 { return [] }
    if count == 1 { return [Rect(topLeftX: 0, topLeftY: 0, width: max(1, width), height: max(1, height))] }
    let left = count == 4 ? [0, 1] : [0]
    let right = count == 4 ? [2, 3] : Array(1 ..< count)
    let columnMinimums = [left.map { minimumWidths[$0] }.max()!, right.map { minimumWidths[$0] }.max()!]
    guard columnMinimums.reduce(0, +) + horizontalGap <= width else { return nil }
    let columns = dynamicTileLengths(width: width, gap: horizontalGap, minimums: columnMinimums)
    let rightX = columns[0] + horizontalGap
    if count == 2 {
        guard minimumHeights.allSatisfy({ $0 <= height }) else { return nil }
        return [Rect(topLeftX: 0, topLeftY: 0, width: columns[0], height: height),
                Rect(topLeftX: rightX, topLeftY: 0, width: columns[1], height: height)]
    }
    let rowMinimums = count == 3 ? [minimumHeights[1], minimumHeights[2]] :
        [max(minimumHeights[0], minimumHeights[2]), max(minimumHeights[1], minimumHeights[3])]
    guard rowMinimums.reduce(0, +) + verticalGap <= height,
          count != 3 || minimumHeights[0] <= height else { return nil }
    let rows = dynamicTileLengths(width: height, gap: verticalGap, minimums: rowMinimums)
    let bottomY = rows[0] + verticalGap
    if count == 3 {
        return [Rect(topLeftX: 0, topLeftY: 0, width: columns[0], height: height),
                Rect(topLeftX: rightX, topLeftY: 0, width: columns[1], height: rows[0]),
                Rect(topLeftX: rightX, topLeftY: bottomY, width: columns[1], height: rows[1])]
    }
    return [Rect(topLeftX: 0, topLeftY: 0, width: columns[0], height: rows[0]),
            Rect(topLeftX: 0, topLeftY: bottomY, width: columns[0], height: rows[1]),
            Rect(topLeftX: rightX, topLeftY: 0, width: columns[1], height: rows[0]),
            Rect(topLeftX: rightX, topLeftY: bottomY, width: columns[1], height: rows[1])]
}

func dynamicTileLengths(width: CGFloat, gap: CGFloat, minimums: [CGFloat]) -> [CGFloat] {
    guard !minimums.isEmpty else { return [] }
    var remaining = max(1, width - CGFloat(minimums.count - 1) * gap)
    var pending = Array(minimums.indices)
    var result = Array(repeating: CGFloat(0), count: minimums.count)
    while !pending.isEmpty {
        let share = remaining / CGFloat(pending.count)
        let constrained = pending.filter { minimums[$0] > share }
        if constrained.isEmpty || pending.count == 1 {
            for index in pending { result[index] = max(1, share) }
            break
        }
        for index in constrained { result[index] = minimums[index]; remaining -= minimums[index] }
        pending.removeAll { constrained.contains($0) }
    }
    return result
}

@MainActor
func dynamicTilingWindows(_ workspace: Workspace) -> [Window] {
    workspace.rootTilingContainer.allLeafWindowsRecursive.filter { $0.lifeStatus == .alive }
}

@MainActor
private func requiredWidth(_ window: Window) -> CGFloat {
    max(CGFloat(config.dynamicTiling.minimumWindowWidth), window.minimumTilingWidth,
        CGFloat(window.app.rawAppBundleId.flatMap { config.dynamicTiling.appMinimumWidths[$0] } ?? 0))
}

@MainActor
private func requiredHeight(_ window: Window) -> CGFloat {
    max(CGFloat(config.dynamicTiling.minimumWindowHeight), window.minimumTilingHeight,
        CGFloat(window.app.rawAppBundleId.flatMap { config.dynamicTiling.appMinimumHeights[$0] } ?? 0))
}

@MainActor
private func frames(_ workspace: Workspace, windows: [Window]) -> [Rect]? {
    let monitor = workspace.workspaceMonitorInfo
    let rect = monitor.visibleRectPaddedByOuterGaps
    let gaps = ResolvedGaps(gaps: config.gaps, monitor: monitor)
    return dynamicTilingFrames(width: rect.width, height: max(1, rect.height - 1),
                               horizontalGap: CGFloat(gaps.inner.horizontal), verticalGap: CGFloat(gaps.inner.vertical),
                               minimumWidths: windows.map(requiredWidth), minimumHeights: windows.map(requiredHeight))
}

@MainActor
private func capacity(_ workspace: Workspace, adding window: Window? = nil) -> Int {
    let windows = dynamicTilingWindows(workspace) + (window.map { [$0] } ?? [])
    let limit = max(1, min(4, config.dynamicTiling.maxWindows, windows.count))
    return (1 ... limit).reversed().first { frames(workspace, windows: Array(windows.prefix($0))) != nil } ?? 1
}

@MainActor
private func hasLayout(_ root: TilingContainer, windows: [Window]) -> Bool {
    let children = root.inhabitedChildren
    func stackMatches(_ node: TreeNode, _ expected: [Window]) -> Bool {
        guard let stack = node as? TilingContainer, stack.layout == .tiles, stack.orientation == .v else { return false }
        return stack.inhabitedChildren == expected.map { $0 as TreeNode }
    }
    switch windows.count {
        case 0 ... 2: return children == windows.map { $0 as TreeNode }
        case 3: return children.count == 2 && children[0] === windows[0] && stackMatches(children[1], Array(windows[1 ... 2]))
        case 4: return children.count == 2 && stackMatches(children[0], Array(windows[0 ... 1])) && stackMatches(children[1], Array(windows[2 ... 3]))
        default: return false
    }
}

@MainActor
private func applyLayout(_ workspace: Workspace) {
    let root = workspace.rootTilingContainer
    let windows = dynamicTilingWindows(workspace)
    guard !windows.contains(where: \.isFullscreen), let rectangles = frames(workspace, windows: windows) else { return }
    root.layout = .tiles
    root.changeOrientation(.h)
    if !hasLayout(root, windows: windows) {
        for window in windows { window.bind(to: root, adaptiveWeight: 1, index: INDEX_BIND_LAST) }
        for child in root.children where child is TilingContainer && child.isEffectivelyEmpty { child.unbindFromParent() }
        if windows.count == 3 {
            let stack = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            for window in windows[1 ... 2] { window.bind(to: stack, adaptiveWeight: 1, index: INDEX_BIND_LAST) }
        } else if windows.count == 4 {
            for group in [0 ... 1, 2 ... 3] {
                let stack = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                for window in windows[group] { window.bind(to: stack, adaptiveWeight: 1, index: INDEX_BIND_LAST) }
            }
        }
        // Rebinding can leave ancestors containing only invisible native tabs.
        // Refresh their lifeStatus before deriving the active column indexes.
        workspace.normalizeContainers()
    }
    let gaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitorInfo)
    let hGap = CGFloat(gaps.inner.horizontal)
    let vGap = CGFloat(gaps.inner.vertical)
    for (columnIndex, child) in root.inhabitedChildren.enumerated() {
        let firstIndex = windows.count == 4 ? columnIndex * 2 : columnIndex
        child.setWeight(.h, rectangles[firstIndex].width + (windows.count > 1 ? hGap / 2 : 0))
        if let stack = child as? TilingContainer {
            for (row, window) in stack.inhabitedChildren.enumerated() {
                window.setWeight(.v, rectangles[firstIndex + row].height + vGap / 2)
            }
        }
    }
}

/// Opt-in layouts: one full window, two columns, master + stack, or a 2x2 grid.
/// Floating windows and native fullscreen/minimized/hidden windows stay untouched.
@MainActor
func applyDynamicTiling(to visibleWorkspaces: [Workspace]) {
    guard config.dynamicTiling.enabled else { return }
    let focusedWindow = globalFocus.windowOrNil
    var overflowWorkspaces: [Workspace] = []

    for workspace in visibleWorkspaces {
        let windows = dynamicTilingWindows(workspace)
        // Explicit fullscreen is a user override, not an invitation to rearrange.
        guard !windows.contains(where: \.isFullscreen) else { continue }
        while dynamicTilingWindows(workspace).count > capacity(workspace) {
            // Recompute after each move. Moving one wide window may make all the
            // remaining narrow windows fit, avoiding unnecessary extra moves.
            let excess = dynamicTilingWindows(workspace).dropFirst(capacity(workspace))
            guard let first = excess.first else { break }
            let window = excess.dropFirst().reduce(first) { requiredWidth($1) > requiredWidth($0) ? $1 : $0 }
            let candidates = visibleWorkspaces.filter { $0 !== workspace } + overflowWorkspaces
            let destination = candidates.first {
                let occupants = dynamicTilingWindows($0)
                return !occupants.contains(where: \.isFullscreen) && occupants.count < capacity($0, adding: window)
            } ?? {
                let destination = (1 ... Int.max).lazy.map { Workspace.get(byName: "auto-\($0)") }.first {
                    $0.isEffectivelyEmpty && !$0.isVisible && $0.forceAssignedMonitorInfo == nil &&
                        !config.persistentWorkspaces.contains($0.name)
                }.orDie()
                check(workspace.workspaceMonitorInfo.toMonitorOrRearrangeMonitors().getWorkspacesContainerOrCreate().bindWorkspace(destination))
                overflowWorkspaces.append(destination)
                return destination
            }()
            window.bind(to: destination.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
    }

    for workspace in visibleWorkspaces + overflowWorkspaces { applyLayout(workspace) }
    // Follow a newly focused window if it overflowed. Other moves don't steal focus.
    if let focusedWindow, focusedWindow.nodeWorkspace != globalFocus.workspace { _ = focusedWindow.focusWindow() }
    focusedWindow?.markAsMostRecentChild()
}

/// Called after a completed AX resize, not while the user's mouse is resizing.
/// Some apps silently clamp requested sizes instead of reporting an AX error.
@MainActor
@discardableResult
func recordDynamicTilingMinimumSize(_ window: Window, requested: CGSize, actual: CGSize) -> Bool {
    guard config.dynamicTiling.enabled, window.lifeStatus == .alive, !window.isFloating, !window.isFullscreen,
          window.windowParentCases?.kind == .tilingContainer,
          window.lastAppliedLayoutPhysicalRect?.width == requested.width,
          window.lastAppliedLayoutPhysicalRect?.height == requested.height,
          currentlyManipulatedWithMouseWindowId != window.windowId else { return false }
    var changed = false
    if actual.width > requested.width + 2 && actual.width > window.minimumTilingWidth {
        window.minimumTilingWidth = ceil(actual.width)
        changed = true
    }
    if actual.height > requested.height + 2 && actual.height > window.minimumTilingHeight {
        window.minimumTilingHeight = ceil(actual.height)
        changed = true
    }
    return changed
}
