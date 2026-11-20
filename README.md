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
- **Just watch**: snow only piles up.
- **Mitten**: move the cursor over drifts to sweep snow away.
- **Shovel: clear everything**: remove all drifts at once.
- **Call the tractor**: send the tractor across the bottom of the screen. It also comes out on its own once the ground is about 60% full.
- **Quit**.

## Sharing

Send `build/Sugrob.zip`. The app is not notarized by Apple, so macOS blocks the first launch. The recipient has to, once:

1. Unzip the archive and try to open the app.
2. Open System Settings → Privacy & Security and press "Open Anyway" at the bottom.

Or run `xattr -cr /path/to/Sugrob.app` in Terminal.

## Tuning

The numbers in the `Config` block at the top of `Sources/main.swift` control snow density, drift height, accumulation speed, mitten radius and the tractor. Rebuild after changing them.

## Limitations

- Snow piles along the very bottom of the screen over the Dock; the Dock itself gets no drift.
- Snow from a minimized window falls only when the window has disappeared, not when the minimize button is pressed.
- Windows that touch the menu bar get no snow, so the menu stays readable.

## Changelog

### Iteration 2

- Hand-drawn red and white mitten instead of an emoji.
- Snow falls down when its window is closed or minimized; it stays put when the Space changes.
- Deeper ground layer at the bottom of the screen.
- Tractor that plows the ground snow, automatically or from the menu.

### Iteration 1

- Transparent click-through overlay on every screen.
- Snowfall, drifts on window top edges and on the ground.
- Mitten and shovel tools, pause, menu bar icon.
