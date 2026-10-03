# LSNowPlayingRepeat

Turns the Favorite (⭐) button on the Lock Screen Now Playing controls into a Repeat button.

- **Tap**: cycle Repeat Off → All → One
- **Long-press**: toggle Favorite (when the app supports it)

Works with **Apple Music** and **YouTube Music**. Other apps, Control Center, the Dynamic Island and StandBy keep the stock controls.

| Icon | Mode |
|---|---|
| `repeat` | Off |
| `repeat.circle.fill` | Repeat All |
| `repeat.1.circle.fill` | Repeat One |

## Requirements

- iOS 17.1 or later (tested on 17.1.1)
- roothide jailbreak

## Building

Requires [Theos with roothide support](https://github.com/roothide/theos).

```bash
make package
```

The package is written to `packages/`. Installing or removing it restarts MediaRemoteUI, so no respring is needed.

## How it works

On iOS 17.1 the Lock Screen Now Playing platter is drawn by **MediaRemoteUI**, not SpringBoard, so the tweak only loads there. It builds a Repeat item next to Apple's Favorite item in `-[MRUTransportControls leadingItemFromResponse:]`, and returns it from `-leadingItem` only while the Lock Screen's transport controls view is configuring or handling a tap. The repeat change is sent with the player's own `repeatCommand`, the same path Siri uses.
