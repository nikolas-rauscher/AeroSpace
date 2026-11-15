# Automatic layouts and native app switching

This fork adds two opt-in behaviours. Both are disabled by default, so an existing
configuration keeps AeroSpace's upstream behaviour.

```toml
fast-app-switching = true

[dynamic-tiling]
enabled = true
max-windows = 4
minimum-window-width = 560
minimum-window-height = 320
app-minimum-widths = { 'net.whatsapp.WhatsApp' = 800 }
```

All widths are macOS points, not physical Retina pixels.

## Automatic layouts

The window count determines the native tiling tree automatically:

- One window fills the usable display.
- Two windows are side by side.
- Three windows use a full-height master on the left and two stacked windows on the right.
- Four windows form a 2x2 grid.

The master starts at half the display width, giving it twice the area of either
stacked window. Column widths and row heights adapt to app minima when necessary.
The four-window grid keeps a shared row boundary across both columns. Window
order is stable and column-major; normal focus changes do not change the master.
Matching containers are reused across refreshes, so navigation, dragging, and
window placement use the same native tree as the visible layout.

When the windows do not fit, excess windows move to a visible workspace on another
display that has room. If none does, the policy creates `auto-1`, `auto-2`, etc.
on the source display. The focused window is followed if it moves. Workspaces
with explicit fullscreen windows, floating windows, native minimized/hidden
windows, and popups retain their existing behaviour. Closing a window expands the
remaining layout; it does not pull windows back from other workspaces.

The policy reads back a completed AX resize. If an app silently refuses to become
as narrow or short as requested, the observed width or height is retained for
that window's lifetime and layout is retried. Per-app overrides can anticipate known limits.
An app whose minimum exceeds the whole display still cannot be made to fit
by a window manager. A transient minimum may be conservative until the app's
window is reopened.

## Keep the native Cmd+Tab switcher

This fork does not replace or intercept Cmd+Tab. With `fast-app-switching`, an app
activation can reveal the workspace of its last known focused window before
waiting on that app's AX queue. The usual full refresh then verifies the actual
focused window. Unknown, closed, minimized, or stale cached windows use the normal
path. This changes AeroSpace's response to activation, not macOS's switcher UI or
its animations.

Before hiding the previous workspace, the fast path also waits for the new
workspace's queued frame writes to finish. The apps' AX queues otherwise execute
independently, so a fast old app could hide its window before a slower new app
has moved its window into view. This FIFO barrier adds no extra AX query. It
reduces that source of desktop flashes; rendering and system animations remain
under macOS and app control.

## Development and trial runs

Build with the matching Swift toolchain (`swift test` also builds the debug app).
The debug binary has a separate socket and app ID. Upstream's debug lifecycle
temporarily disables the release server on startup and re-enables it on a normal
exit. Pass a separate configuration with `--config-path` for a trial run. Do not
commit personal configs, runtime snapshots, or backups to this public repository.

`DynamicTilingTest` covers 1–4 window geometry, gaps, native tree transitions,
directional focus, overflow, floating/fullscreen exclusions, app overrides, and
measured minimum sizes in both dimensions. Multi-display policy needs a real
display test in addition to the workspace-level tests. Native Cmd+Tab latency needs manual comparison;
passing unit tests is not a latency measurement.

## Personal app bundle and menu bar

The personal bundle launches the Swift executable directly through
`CFBundleExecutable`. Its optional `AeroSpacePersonalConfig` Info.plist value
resolves a config path relative to the app bundle's parent directory. An explicit
`--config-path` takes precedence. When the bundled default is used, the process
writes `aerospace-personal.pid` beside the bundle for the trial stop script.

The enabled menu-bar label uses a native SwiftUI grid symbol followed by
`AS <workspace>`, making the personal version and current workspace identifiable.
The permission and disabled states retain their existing warning labels.
