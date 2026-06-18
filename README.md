# Panes

Panes brings a handful of Windows desktop habits to macOS. I moved to a Mac and kept reaching for small things that weren't there, so I built them into one little menu bar app instead of installing five separate utilities.

It's native Swift and AppKit. No Electron, no web views, and it doesn't phone home. Everything happens on your machine.

## What it does

Each feature is its own thing, and you can turn any of them on or off from the menu bar. Turn on the ones you want and ignore the rest.

- **Window snapping.** Drag a window to a screen edge to snap it: the top maximizes, the sides take halves, the corners take quarters. Drag to the top center for a layout palette, including your own custom zones that you draw on the screen. Snap a window to one half and Panes shows your other windows so you can fill the other half with a click.
- **Keyboard snapping.** Ctrl+Option+Arrow snaps the window you're using without dragging.
- **Move to display.** Send the focused window to your next monitor and keep its place and size.
- **Dock previews.** Hover a Dock icon to see live previews of that app's windows. Scroll over the icon to step through them, then click to open the one you want.
- **Click a Dock icon to minimize.** Click the icon of the app you're in to minimize it, click again to bring it back.
- **Minimize into the app icon.** Minimized windows fold into the app's Dock icon instead of piling up as separate tiles.
- **Clipboard history.** A searchable history of the text, images, and files you copy. Pin the ones you use often, exclude apps you don't want recorded, and paste as plain text when you need it.
- **Screenshot to clipboard.** Grab part of the screen straight to the clipboard, with an optional freeze-frame mode for capturing menus.
- **Finder cut and paste.** Cmd+X then Cmd+V moves files in Finder instead of copying them.
- **Shake to minimize.** Shake a window to minimize everything else, shake again to bring it all back.
- **Window switcher.** Option+Tab steps through individual windows, not just apps, with a live preview of each. It can group windows by app if you prefer.

Every shortcut can be changed in Settings, and there's a reset button for each one.

## Installing

With Homebrew:

```sh
brew tap zach-shattuck/panes
brew install --cask panes
```

The `tap` line just points Homebrew at this project once. After that, `panes` is all you need.

Panes is signed for local use but not notarized by Apple, so the first time you open it macOS will say it can't verify the developer. You clear that once, whichever you prefer:

- Open System Settings, go to Privacy and Security, scroll down, and click Open Anyway, or
- run `xattr -dr com.apple.quarantine /Applications/Panes.app` once in Terminal.

Prefer to download it directly? Grab the latest build from the [Releases](https://github.com/zach-shattuck/panes/releases) page, drag Panes into your Applications folder, and do the same one-time step above.

If you would rather not trust a stranger's binary at all, building it yourself (below) sidesteps the whole thing.

## Permissions

A few features need macOS permissions, and Panes asks for them only when you turn those features on:

- **Accessibility** lets Panes move and read other apps' windows. Snapping, the switcher, and Dock click-to-minimize use it.
- **Screen Recording** is what makes the live window previews possible (Dock previews, the switcher, and Snap Assist).

That's the whole list. Panes uses these for the features you enable and nothing else. Nothing leaves your Mac, there's no analytics, and the code is right here if you want to check.

## Building it yourself

Requirements: macOS 14 or later and a Swift 6.2 toolchain (Xcode 16 or the matching command line tools).

```sh
swift build
swift run Panes        # run the dev build
bash Scripts/bundle.sh # build a real Panes.app and install it to /Applications
```

If you grant permissions to a plain `swift build` binary and they seem to stop working after a rebuild, that's macOS tying the permission to the exact build. `Scripts/setup-signing.sh` sets up a stable local signing identity so grants stick across rebuilds.

## How it's built

I'll be straight about this: I build Panes with AI coding tools. I'm not going to pretend a lone genius hand-typed every line. I use them the way I'd use any good tool, to move quickly and try a lot of ideas. What goes in, what gets cut, and when something actually feels right is my call. Every feature here is one I wanted on my own Mac and kept using until it stopped annoying me. If something feels off, that's on me, and I would rather hear about it.

## Support

Panes is free, and nothing is locked behind a paywall. If it earns a spot on your Mac and you want to throw a few dollars my way, you can do that here: [paypal.biz/zachsoftworks](https://www.paypal.biz/zachsoftworks). No pressure either way.

## License

MIT. See [LICENSE](LICENSE).
