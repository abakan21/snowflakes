# Sugrob

Snow on top of your macOS desktop. It falls in front of every window, piles up on the top edges of windows and at the bottom of the screen, and the drift travels with its window. Clicks pass straight through the snow.

## Features

- Snowfall over all screens; snow settles on visible window top edges and on the bottom of the screen.
- Mitten: sweep snow off with the cursor.
- Shovel: clear every drift at once.
- Pause and resume from the menu bar.

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
- **Quit**.

## Sharing

Send `build/Sugrob.zip`. The app is not notarized by Apple, so macOS blocks the first launch. The recipient has to, once:

1. Unzip the archive and try to open the app.
2. Open System Settings → Privacy & Security and press "Open Anyway" at the bottom.

Or run `xattr -cr /path/to/Sugrob.app` in Terminal.

## Tuning

The numbers in the `Config` block at the top of `Sources/main.swift` control snow density, drift height, accumulation speed and mitten radius. Rebuild after changing them.

## Limitations

- Only a thin layer of snow lies along the bottom of the screen over the Dock; the Dock itself gets no drift.
- Windows that touch the menu bar get no snow, so the menu stays readable.

## Changelog

### Iteration 1

- Transparent click-through overlay on every screen.
- Snowfall, drifts on window top edges and on the ground.
- Mitten and shovel tools, pause, menu bar icon.
