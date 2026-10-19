# DeskPad Optimized

A lighter fork of [DeskPad](https://github.com/Stengo/DeskPad), a virtual monitor for screen sharing on macOS. Move apps onto the virtual display and share it in your meeting app. DeskPad shows a live preview in its own window.

## Changes from the original

- **Smaller capture buffers.** Capture matches the preview window's pixel size, capped at native resolution. Shrinking the preview reduces capture work without changing the shared display's resolution.
- **Simpler internals.** Removed ReSwift and its state-management layers. Cursor tracking uses cached display bounds and updates the window only when the cursor enters or leaves.
- **Proper cleanup.** Capture streams, frame surfaces, and virtual displays are released when replaced or closed.
- **Optional second display.** Each display has its own preview, resolution, refresh rate, and cursor highlighting. The second display is off on every launch.
- **Refresh-rate selection.** Both displays offer 60, 90, 120, and 144 Hz in macOS Display settings, instead of only 60 Hz.
- **Leaner builds.** Formatting runs explicitly rather than on every build. Added geometry and live integration checks.

The original resolution options, HiDPI support, click-to-move cursor behavior, and blue title-bar highlighting are preserved.

## Use

- Launch DeskPad to connect the first virtual display.
- Choose **Displays → Enable Second Display** (**⌘2**) to toggle the second. Closing its preview also disconnects it.
- Use **Displays → Show First Display** (**⌘1**) to show or reopen the first preview.
- Set each display's resolution and refresh rate in **System Settings → Displays**.
- Grant **Screen Recording** access under **Privacy & Security**, then restart DeskPad.

Capture continues while a preview is covered. Actual preview and screen-sharing frame rates depend on your physical screen and sharing app; selecting 144 Hz does not guarantee 144 fps throughout.

## Build

Requires macOS 13 or later and Xcode. Open `DeskPad.xcodeproj`, select your development team under **Signing & Capabilities**, and build. Copy the signed `DeskPad.app` to `/Applications`.

Use the same signing identity for updates. Unsigned or ad-hoc replacements can cause repeated Screen Recording prompts. If this happens, quit DeskPad, install a properly signed build, and reset its permission:

```sh
tccutil reset ScreenCapture com.stengo.DeskPad
```

Open DeskPad, grant access again, and restart it.

## Checks

```sh
sh Tests/run.sh                # Capture sizing and cursor mapping
sh Tests/run.sh --integration  # Live capture, two displays, refresh rates, and cleanup
```

For integration checks, quit DeskPad and use an unlocked desktop session with Screen Recording access for the terminal/test executable.

## Credits

Based on DeskPad by Bastian Andelefski. [MIT license](LICENSE.md).
