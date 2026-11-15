import AppKit
import Common

/// Widths are in macOS points, not Retina pixels. One window always remains usable,
/// even when the monitor itself is narrower than the configured minimum.
func dynamicTilingCapacity(width: CGFloat, gap: CGFloat, minimumWidth: Int, maximum: Int, minimums: [CGFloat] = []) -> Int {
    let limit = max(1, min(3, maximum))
    return (1 ... limit).reversed().first { count in
        let widths = minimums.prefix(count)
        let missing = max(0, count - widths.count)
        return widths.reduce(0, +) + CGFloat(missing) * CGFloat(max(1, minimumWidth)) + CGFloat(count - 1) * gap <= width
    } ?? 1
}

func dynamicColumnWidths(width: CGFloat, gap: CGFloat, minimums: [CGFloat]) -> [CGFloat] {
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
private func capacity(_ workspace: Workspace, adding window: Window? = nil) -> Int {
    let monitor = workspace.workspaceMonitorInfo
    let gaps = ResolvedGaps(gaps: config.gaps, monitor: monitor)
    let windows = dynamicTilingWindows(workspace) + (window.map { [$0] } ?? [])
    return dynamicTilingCapacity(width: monitor.visibleRectPaddedByOuterGaps.width,
                                gap: CGFloat(gaps.inner.horizontal),
                                minimumWidth: config.dynamicTiling.minimumWindowWidth,
                                maximum: config.dynamicTiling.maxWindows,
                                minimums: windows.map(requiredWidth))
}

/// An opt-in policy: stable left-to-right order, equal columns, bounded occupancy.
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

    for workspace in visibleWorkspaces + overflowWorkspaces {
        let root = workspace.rootTilingContainer
        let windows = dynamicTilingWindows(workspace)
        guard !windows.contains(where: \.isFullscreen) else { continue }
        // Don't rebind on every AX refresh: that would churn MRU and native-tab state.
        if windows.contains(where: { $0.parent !== root }) {
            for window in windows { window.bind(to: root, adaptiveWeight: 1, index: INDEX_BIND_LAST) }
            for child in root.children where child is TilingContainer && child.isEffectivelyEmpty { child.unbindFromParent() }
        }
        root.layout = .tiles
        root.changeOrientation(.h)
        let monitor = workspace.workspaceMonitorInfo
        let gap = CGFloat(ResolvedGaps(gaps: config.gaps, monitor: monitor).inner.horizontal)
        let widths = dynamicColumnWidths(width: monitor.visibleRectPaddedByOuterGaps.width, gap: gap, minimums: windows.map(requiredWidth))
        for (index, window) in windows.enumerated() {
            let gapCharge = windows.count == 1 ? 0 : (index == 0 || index == windows.count - 1 ? gap / 2 : gap)
            window.setWeight(.h, widths[index] + gapCharge)
        }
    }
    // Follow a newly focused window if it overflowed. Other moves don't steal focus.
    if let focusedWindow, focusedWindow.nodeWorkspace != globalFocus.workspace { _ = focusedWindow.focusWindow() }
    focusedWindow?.markAsMostRecentChild()
}

/// Called after a completed AX resize, not while the user's mouse is resizing.
/// Some apps silently clamp requested sizes instead of reporting an AX error.
@MainActor
@discardableResult
func recordDynamicTilingMinimumWidth(_ window: Window, requested: CGFloat, actual: CGFloat) -> Bool {
    guard config.dynamicTiling.enabled, !window.isFloating, !window.isFullscreen,
          window.windowParentCases?.kind == .tilingContainer,
          window.lastAppliedLayoutPhysicalRect?.width == requested,
          actual > requested + 2, actual > window.minimumTilingWidth,
          currentlyManipulatedWithMouseWindowId != window.windowId else { return false }
    window.minimumTilingWidth = ceil(actual)
    return true
}
