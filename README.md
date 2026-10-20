<p align="center">
  <img src="assets/icon.png" alt="Gloam" width="128" height="128">
</p>

<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/wordmark-on-dark.svg">
    <img src="assets/wordmark-on-light.svg" alt="Gloam" width="220">
  </picture>
</h1>

<p align="center">
  <strong>A blue light filter for your Mac: warms and dims the screen from sunset to bedtime,<br>
  so evenings are easier on your eyes.</strong><br>
  Free and open source · no account · no tracking
</p>

<p align="center">
  <img src="docs/screenshots/popover-2115.png" alt="Gloam during wind-down" width="340">
</p>

## Install

1. Download **Gloam.dmg** from [Releases](https://github.com/Que-tin/gloam/releases/latest), open it and
   drag Gloam into Applications.
2. Open Gloam. The first time, macOS asks you to confirm it: open **System Settings › Privacy &
   Security**, scroll down and click **Open Anyway**. You only do this once. (Gloam isn't part of
   Apple's paid developer program, so macOS can't check it for you.)

Or with [Homebrew](https://brew.sh): `brew install --cask que-tin/tap/gloam`.

Needs a Mac with Apple silicon and macOS 14 or later. Gloam updates itself (see below). To remove it,
quit Gloam and drag it to the Bin (with Homebrew: `brew uninstall --cask gloam`).

## What it does

- **Warms, then dims.** Warm colour alone cuts only about half the light that keeps you alert;
  dimming does the rest.
- **Follows the sun and your bedtime.** Warm from sunset, deepest an hour before bed (23:00 unless
  you change it), daylight again in the morning. Nothing to set up.
- **Dims the backlight itself** on Mac screens, Apple displays and DDC/CI monitors, like the
  brightness keys do. Other monitors are dimmed in software.
- **Shows the effect.** The lamp in its menu-bar popover estimates how much blue light still
  reaches you.
- **Pauses** for an hour, until morning, or while an app like Lightroom is in front.

Settings shows your evening as a graph: drag bedtime, wake and how warm and dim the night gets.

<details>
  <summary>Welcome and Settings</summary>
  <p align="center">
    <img src="docs/screenshots/welcome.png" alt="The welcome window" width="415">
    <img src="docs/screenshots/settings.png" alt="Settings" width="380">
  </p>
</details>

## How it compares

|  | Gloam | f.lux | Night Shift |
|---|---|---|---|
| Warms the screen on a schedule | ✓ | ✓ | ✓ |
| Dims as part of the schedule | ✓ | – (dim by hand) | – |
| Follows the sun | ✓ | ✓ | ✓ |
| Deepens toward bedtime | ✓ | ✓ (from wake time) | – |
| Shows how much blue light reaches you | ✓ | – | – |
| Scripting | Shortcuts, URL scheme | – | Shortcuts |
| Dims external monitors in hardware (DDC/CI) | ✓ | – | – |
| Open source | ✓ (MIT) | – | – |

## Good to know

- **Updates itself.** Gloam checks GitHub for new versions about once a day and installs them when
  you say so (switch it off in Settings, or use **Check for Updates…** in the right-click menu).
- **Shortcuts, Spotlight and Focus:** "Set Gloam" and "Pause Gloam" actions in Shortcuts, and a Focus
  filter that pauses Gloam while a Focus is on (System Settings › Focus; a Focus with it starts
  Gloam if it isn't running). A keyboard shortcut to turn it on or off can be set in Settings, and
  `open gloam://toggle` (or `on`, `off`, `open`) works too.

## Questions

<details>
<summary><b>Can I use Gloam together with Night Shift, f.lux or similar apps?</b></summary>

Better not: they all change your screen's colours, and two at the same time could make the screen
flicker. Turn the other one off while using Gloam.
</details>

<details>
<summary><b>My external monitor doesn't dim properly</b></summary>

Many monitors let Gloam turn their brightness down directly, just like their own buttons do. Some
don't, especially when they're connected through a hub, dock or adapter, and most TVs. Gloam then
darkens the picture instead, but not all the way, so dark scenes stay visible. Connecting the
monitor straight to your Mac often helps. If yours still doesn't dim, please open an
[issue](https://github.com/Que-tin/gloam/issues).
</details>

<details>
<summary><b>Colours look off in photo editing apps or videos</b></summary>

That's the warm tint. To pause Gloam for one app, right-click the Gloam icon in the menu bar while
that app is open and choose **Always Pause for …**. Gloam then steps aside whenever that app is in
front. You can also pause Gloam for an hour or until morning from the same menu.
</details>

<details>
<summary><b>Text leaves a blurry trail when I scroll</b></summary>

Some screens get sluggish when they're very dim, and light text on a dark background smears. Gloam
never dims your Mac's own screen that far, unless you set Warmest past the recommended night in
Settings (it tells you then). On a monitor, make the night a little lighter in Gloam's
Settings (drag the dashed lines in the graph down), or turn on **Avoid smearing** for that monitor:
Gloam then tries to keep out of the range where it smears. If text still smears, please open an
[issue](https://github.com/Que-tin/gloam/issues).
</details>

<details>
<summary><b>Will Gloam help me sleep?</b></summary>

Gloam isn't a medical product, so it doesn't promise better sleep. What it does: in the evening it
reduces the kind of screen light that tells your body it's still daytime. A dimmer room and less
screen time before bed help even more. The research behind it is in [docs/science.md](docs/science.md).
</details>

<details>
<summary><b>Does Gloam collect any data?</b></summary>

No. There's no account and no tracking. Gloam only goes online to check for updates (you can turn
that off in Settings) and, if you search for a city (when setting up, or in Settings), to look that
city up with Apple Maps. It never asks for your location: it works out sunset from your Mac's time zone.
</details>

## Build from source

Needs Xcode 27. See [CONTRIBUTING.md](CONTRIBUTING.md).

```sh
git clone https://github.com/Que-tin/gloam && cd gloam
./scripts/build-app.sh && open .build/Gloam.app
```

## License

[MIT](LICENSE). The license covers the code; the Gloam name, icon and wordmark are not part of it:
forks are welcome, but please give yours its own name and icon.
