# Sugrob

Snow on top of your macOS desktop. It falls in front of every window, piles up on the top edges of windows and at the bottom of the screen, and the drift travels with its window. Clicks pass straight through the snow.

"Sugrob" (сугроб) is Russian for snowdrift. The idea is inspired by the Flake app; this project is not affiliated with it and shares no code or artwork.

## Features

- Snowfall over all screens; snow settles on visible window top edges and on the bottom of the screen.
- Mitten: sweep snow off with the cursor.
- Shovel: clear every drift at once.
- Pause and resume from the menu bar.
- Closing or minimizing a window makes its snow fall down onto whatever is below.
- A tractor drives along the bottom of the screen and plows the ground snow away.
- Dragging a window makes its snow slide; fast drags and jerks knock it off in clumps.
- The plain cursor pushes snow into a heap; the mitten is wider and sweeps most of it away.
- With Accessibility access: snow falls the moment a window is minimized, and a drift forms on the Dock itself.
- Falling clumps land on lower windows, the Dock or the ground instead of disappearing.

## Build

Requires macOS 12 or later and the Apple developer tools (`xcode-select --install`).

```bash
bash build.sh
open build/Sugrob.app
```

The script builds a universal binary (Apple Silicon and Intel), ad-hoc signs it and also produces `build/Sugrob.zip`.

## Controls

Everything is under the ❄️ icon in the menu bar:

- **Pause / Resume snowfall**: hide the snow and bring it back.
- **Just watch**: the plain cursor only nudges snow around.
- **Mitten**: a wider sweep that throws most of the snow off.
- **Shovel: clear everything**: remove all drifts at once.
- **Call the tractor**: send the tractor across the bottom of the screen. It also comes out on its own once the ground is about 60% full.
- **Accessibility**: shows whether access is granted; opens the system settings pane if it is not.
- **Quit**.

## Accessibility permission

Optional. With it, snow falls as soon as a window is minimized and a drift forms on the Dock. Without it the app still works: snow from a minimized window falls when the window disappears, and the Dock gets no drift of its own.

1. On first launch macOS shows a prompt; choose "Open System Settings". If there was no prompt, use ❄️ → "Grant Accessibility access…".
2. In System Settings → Privacy & Security → Accessibility, turn on the switch next to Sugrob. If it is not listed, press "+" and pick `Sugrob.app`.
3. Within a couple of seconds the menu shows "Accessibility: enabled ✓". If it does not, quit and relaunch the app.

The app is ad-hoc signed, so every rebuild counts as a new app: after `bash build.sh`, remove Sugrob from the list with "−", launch the new build and grant access again. People who receive a ready-made archive only do this once.

The permission is used only to learn about window minimize events and the Dock bounds. The app never reads window contents.

## Sharing

Send `build/Sugrob.zip`. The app is not notarized by Apple, so macOS blocks the first launch. The recipient has to, once:

1. Unzip the archive and try to open the app.
2. Open System Settings → Privacy & Security and press "Open Anyway" at the bottom.

Or run `xattr -cr /path/to/Sugrob.app` in Terminal.

## Tuning

The numbers in the `Config` block at the top of `Sources/main.swift` control snow density, drift height, accumulation speed, shake thresholds, cursor and mitten radius, and the tractor. Rebuild after changing them.

## Limitations

- The Dock drift needs Accessibility access and a Dock at the bottom of the screen.
- No power-saving mode yet: the overlay redraws 30 times per second, also on battery and over full-screen apps.
- Windows that touch the menu bar get no snow, so the menu stays readable.

## Changelog

### Iteration 3

- Accessibility integration: instant snow fall on minimize, drift on the Dock.
- Window physics: snow slides while a window is dragged and sheds on fast drags and jerks.
- The cursor always pushes snow into a heap; the mitten sweeps more.
- Snow that falls off a window, off its edges or off a full drift keeps falling and lands below.

### Iteration 2

- Hand-drawn red and white mitten instead of an emoji.
- Snow falls down when its window is closed or minimized; it stays put when the Space changes.
- Deeper ground layer at the bottom of the screen.
- Tractor that plows the ground snow, automatically or from the menu.

### Iteration 1

- Transparent click-through overlay on every screen.
- Snowfall, drifts on window top edges and on the ground.
- Mitten and shovel tools, pause, menu bar icon.
