# LSNowPlayingRepeat

Turns the Favorite (⭐) button on the Lock Screen and Control Center Now Playing controls into a Repeat button.

- **Tap**: cycle Repeat Off → All → One
- **Long-press**: toggle Favorite (when the app supports it)

Works with **Apple Music** and **YouTube Music**. Other apps, the Dynamic Island and StandBy keep the stock controls.

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

The package is written to `packages/`. Respring after installing or removing it so Control Center picks up the change (MediaRemoteUI is restarted automatically).

## How it works

On iOS 17.1 the Lock Screen Now Playing platter is drawn by **MediaRemoteUI**, while Control Center's media module lives in **SpringBoard**; the tweak loads into both. It builds a Repeat item next to Apple's Favorite item in `-[MRUTransportControls leadingItemFromResponse:]`, and returns it from `-leadingItem` only while a Lock Screen or Control Center transport controls view is configuring or handling a tap. The repeat change is sent with the player's own `repeatCommand`, the same path Siri uses.
