<p align="center">
  <img src="docs/icon.png" alt="Gloam" width="128" height="128">
</p>

<h1 align="center">Gloam</h1>

<p align="center">
  <strong>A warm lamp for your Mac's evenings: it warms the screen from sunset and dims it before bed.</strong><br>
  Free and open source · no account · no tracking · native Swift
</p>

<p align="center">
  <img src="docs/screenshots/popover-2115.png" alt="Gloam during wind-down" width="300">
</p>

<details>
  <summary>Welcome and Settings</summary>
  <p align="center">
    <img src="docs/screenshots/welcome.png" alt="The welcome window" width="380">
    <img src="docs/screenshots/settings.png" alt="Settings" width="380">
  </p>
</details>

---

Gloam sits in your menu bar and turns your screen into something closer to lamplight in the
hours before bed, then brings full daylight back when you wake. It's built
around what sleep research says matters:

- **It dims as well as warms.** Warm colour on its own cuts only about half of the light that keeps
  you alert; lowering brightness does most of the work. Gloam does both.
- **It follows the sun, then winds you down.** It warms as the sun goes down, dims later in the
  evening (only once the sun is setting), goes deepest an hour before bed, and is back to
  daylight in the morning. Nothing to set up: the evening is timed from a 23:00 bedtime that
  suits most people (change bedtime and wake in Settings), where Warmest and Dimmest also set
  where the night goes, lighter or deeper.
- **It shows you the effect.** The lamp in the popover glows with your screen's current colour and
  estimates how much blue light still reaches you, compared with the same screen untinted at
  your daytime brightness (so turning brightness down in the evening counts too). On the built-in screen, Apple displays and monitors that support
  DDC/CI, it dims the backlight itself, the way the brightness keys do (by default never below
  about 40 cd/m² on a typical laptop screen, lower only past the recommended night); other monitors are dimmed in software, never below 30%, so shadows stay readable.

Room lighting and total screen time matter more than any screen app. Gloam helps with the part a
screen can.

## Using it

- **The lamp.** It glows with your screen's colour right now and shows how much blue light still
  reaches you. Its dial (warmth) and ladder (dimming) each run from nothing to as far as your screen
  goes, and show what the evening asks for; move them (or scroll, or use the arrow keys) to take
  over by hand until the next morning (in the evening) or the next evening (by day), and "Auto"
  hands back at once.
- **On, off, or off for a while.** The switch at the top turns Gloam off and on. Right-click the
  menu-bar icon to **Pause** for an hour or until morning; either ends by itself.
- **Paused where colour matters.** Right-click while using Lightroom, Photoshop or a video player
  and choose **Always Pause for** it (or add apps in Settings): Gloam pauses while it's in front.
- **Your evening, as a graph.** Settings shows tonight's warmth and dimming against sunset, bedtime
  and wake. Drag bedtime or wake sideways, or the dashed Warmest and Dimmest lines up and down:
  they set where the night goes, lighter or, past the recommended night, deeper. **Preview tonight** shows the night on
  your screen while you set it. "Adapt to room light" eases the dimming in a bright room (MacBook, lid open).
- **Settings** (gear, or right-click the menu-bar icon) also holds your location, which screens
  to tint, app exceptions and launch at login.

Everything works from the keyboard and with VoiceOver.

## Install

Download `Gloam.zip` from [Releases](https://github.com/Que-tin/gloam/releases), open it and
move `Gloam.app` to Applications. Builds aren't notarized (that needs a paid Apple developer
account), so macOS blocks the first launch:
open Gloam once, then **System Settings › Privacy & Security**, scroll down and click **Open
Anyway**. (On macOS 14 you can right-click Gloam.app and choose **Open** instead.) If neither
appears, run `xattr -dr com.apple.quarantine /Applications/Gloam.app` in Terminal.

To update, quit Gloam (right-click the menu-bar icon), replace the app in Applications with the
new one and open it; settings stay. Gloam doesn't check for updates itself: watch the repository's
releases to hear of new ones.

Or build it yourself (needs Xcode 26):

```sh
git clone https://github.com/Que-tin/gloam && cd gloam
./scripts/build-app.sh && open .build/Gloam.app
```

Requires macOS 14 or later, on Apple silicon or Intel.

To remove it completely, run `Gloam.app/Contents/MacOS/Gloam --uninstall` (clears its login item
and settings), then move the app to the Bin.

If another app (or macOS itself) also tints your screen in the evening, turn
that off. Two apps tinting the screen at
once make it flicker; Gloam tells you if something keeps changing the screen's colours.

## How it compares

|  | Gloam | f.lux | Night Shift |
|---|---|---|---|
| Warms the screen on a schedule | ✓ | ✓ | ✓ |
| Dims as part of the schedule | ✓ | – (dim by hand) | – |
| Follows the sun | ✓ | ✓ | ✓ |
| Deepens toward bedtime | ✓ | ✓ (from wake time) | – |
| Shows how much blue light reaches you | ✓ | – | – |
| Command line / scripting | URL scheme | – | – |
| Dims external monitors in hardware (DDC/CI) | ✓ | – | – |
| Open source | ✓ (MIT) | – | – |

## Under the hood

- **Colour accuracy.** Colours come from the physics of warm light, so 1900 K looks like a candle
  rather than a filter. Gloam also keeps your monitor's colour calibration.
- **Real tinting.** Gloam changes the colour signal itself, so blue is actually removed and blacks
  stay black. On the few Macs where macOS ignores that (M5 Pro and M5 Max MacBook Pros, and the
  MacBook Neo on external displays), it uses a screen overlay instead. You can choose the method
  in Settings.
- **No location permission.** Sunset is worked out from your time zone on the Mac, or from a city
  you pick.
- **Scriptable** with Shortcuts, Raycast, Alfred, cron or a shell:

  ```sh
  open gloam://toggle   # or gloam://on, gloam://off, gloam://open
  ```

The research behind every default, with sources: **[docs/science.md](docs/science.md)**.

## Privacy

Gloam makes no network requests, with one exception: if you search for a city in Settings, the
name is sent to Apple Maps. Settings stay in your Mac's user defaults.

## Health note

Gloam reduces the evening screen light that most affects your body clock (melanopic light, per
CIE S 026), following the 2022 expert recommendations. It is not a medical device and makes no
claim to improve sleep or treat any condition.

## Known issues

- **Not notarized**, so the first launch needs **Open Anyway** (see Install).
- **External monitors:** hardware brightness over DDC/CI is verified on one monitor so far. Hubs,
  docks, DisplayLink adapters, TVs and some picture modes don't answer; those screens are dimmed
  in software instead.
- **Private macOS interfaces** read the backlight, the light sensor and DDC/CI. A macOS update can
  break them; Gloam then falls back to dimming in software rather than failing.
- **Intel Macs and macOS 14–15** build and should work, but haven't been tested on hardware yet.
- **No update check**: new versions appear under Releases.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports from unusual display setups are especially
welcome.

## License

[MIT](LICENSE)

The MIT License covers the code. The Gloam name, icon and wordmark are not part of it: forks are
welcome, but please give yours its own name and icon.
