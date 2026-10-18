# Gloam

A native macOS menu-bar app that warms and dims displays in the evening, timed to sunset and a
fixed 23:00 bedtime, grounded in circadian research (melanopic light, CIE S 026). An
open-source, better-looking alternative to the usual screen-warming apps. Why every default is what it is: `docs/science.md`.

## Map

- `Sources/GloamCore/` — pure logic, no AppKit, fully unit-tested.
  - `ColorTemperature.swift`: Kelvin → display gains (Planckian locus) and `Tint` with
    mired-space mixing.
  - `SolarPosition.swift`: sun elevation, sunrise and sunset.
  - `Schedule.swift`: stages (sunset, wind-down, night) → `Tint` at any time; `evening(around:)`
    gives the night's timeline as calendar dates (DST-safe).
  - `Melanopic.swift`: estimated melanopic ("blue") light for a tint.
  - `Location.swift`: default coordinates from the system zone table.
  - `EnginePolicy.swift`: picks gamma vs overlay per chip.
  - `Smear.swift`: the luminance floor that stops built-in LCDs smearing (dimming goes before warmth).
  - `BacklightDim.swift`: backlight dimming as a fraction of the level found; outside moves adopted.
  - `Command.swift`: the `gloam://` URL scheme (toggle, on, off, open).
- `Sources/Gloam/App/GloamApp.swift` — entry point (`@main`): single-instance hand-over,
  `--uninstall`, the Settings and Welcome windows (`Windows`), URL handling, debug flags
  (`--showcase`, `--at`, `--snapshot`, `--capture`, `--onboarded`, `--off`, `--floor`).
- `Sources/Gloam/App/MenuBarPanel.swift` — status item (click: popover; right-click: menu).
- `Sources/Gloam/Model/AppModel.swift` — single source of truth: settings, clock, target tint.
- `Sources/Gloam/Display/` — `DisplayController` (fades and reapply), `GammaEngine`,
  `OverlayEngine`, `Displays` (screen info), `RoomLight` (sensor), `Backlight` (read and dimmed),
  `DDC` (third-party monitors' brightness over DDC/CI, on a background queue; unverified on hardware).
- `Sources/Gloam/UI/` — the "light as material" design: `PopoverView`, `Lamp` (orb dial,
  dimming ladder, small parts), `GloamGlyph` (menu-bar mark), `WelcomeView`, `SettingsView`,
  `CitySearch` (both), `Theme` (kelvin colours, stage and light names, formatting).
- `Tests/GloamCoreTests/` — Swift Testing suites for the core.
- `scripts/` — `build-app.sh` (release .app), `make-icon.swift` (app icon from code),
  `snapshots.sh` (README screenshots).
- `Resources/Info.plist` — bundle template; `__VERSION__` is filled in by `build-app.sh`.
- `docs/` — `science.md`, the icon and screenshots used by the README.

## Commands

```sh
swift test                                    # core tests
swift run Gloam                               # run from source
swift run Gloam --showcase --at 22:30         # popover in a window at 22:30 (debug; never tints)
swift run Gloam --capture DIR                 # photograph the real popover, Welcome, Settings; quit
./scripts/snapshots.sh                        # regenerate docs/screenshots (never tints the screen)
./scripts/build-app.sh                        # .build/Gloam.app, universal, ad-hoc signed
```

## Constraints

- macOS 14+, universal (Intel Macs stuck on 14/15 are a core audience); builds need the macOS 26
  SDK. Swift tools 6.2: the app target defaults to MainActor, `GloamCore` stays nonisolated.
  Observe notifications with `for await … in center.notifications(named:)`.
- No dependencies, no telemetry, no location permission (zone.tab or a city search, the only
  network use). Wording stays non-medical; defaults change only with evidence in
  `docs/science.md`.
- English only, but every user-facing string goes through `String(localized:)`/`LocalizedStringKey`
  (whole sentences with placeholders, never joined fragments; numbers via `Format`).
- Onboarding asks nothing; Welcome is a draft until Start (closing it first quits, unsaved; the
  menu-bar icon appears with Start). Bedtime is a fixed 23:00, a clock time, never a stage;
  dimming never starts before sunset. Stages are fixed; Warmth and Night brightness caps live in
  Settings and Welcome's preview. The popover's dial and ladder override until the next stage
  (per-stage values and global strengths were tried and cut: "back to automatic" got unclear).
- Tint gains use each display's own colour space (`GammaEngine.space`): sRGB gains on P3 panels
  turn warm white into bloomy pure red. `RoomLight`/`Backlight` are private API: nil means no change.
- Displays macOS can dim (built-in, Apple displays) and monitors that answer DDC/CI are dimmed by
  backlight, as a fraction of the level found there (`BacklightDim`): key presses and
  auto-brightness are adopted, never fought, and quitting restores (after a crash or kill, the
  next launch does, from the state saved while dimming). The rest: signal, never below 30%.
- A built-in LCD never draws a white under `DisplayController.smearFloor` of daylight white's light
  (light-on-dark text smears below it; a warm tint is a dim white): dimming goes first, then warmth.
  Monitors opt in per display (`smearGuarded`): macOS reports nothing about their panels.
- Only one app can own the gamma table. Interference is detected generically
  (`DisplayController.interference`), never by app name.
- Every window is ours and AppKit-hosted: the popover is a borderless panel (`MenuBarPanel`),
  not `MenuBarExtra` (unstylable grey chrome, can't be opened or captured); Settings is not a
  SwiftUI `Settings` scene (`openSettings` is unreliable from menu-bar apps). Dark by design.
- Clock ticks (5 s; 60 s while untinted with nothing due) write the tint directly, skipping
  unchanged values; only user actions fade, and a new target retargets a running fade (drags send
  ~120 a second). Each tick rewrites the gamma table only if something overwrote it. A backlight
  macOS controls is polled twice a second while tinted or dimmed; DDC monitors every 20 s; idle or
  with the screens asleep, once a minute (nothing is read or written to sleeping screens). Saves
  are debounced.
- Deliberately absent, cut after review: an "Always" mode, presets, a daytime tint, per-stage
  tuning, editable bedtime/wake, an evening timeline or "next" strip, Kelvin numbers in the
  popover, naming rival apps in the app.
- Timed off lives only in the menu-bar item's right-click menu ("Turn Off For": an hour, until
  morning, an app in front) and always ends by itself (`AppModel.resumeAt`); the switch is untimed.
- The brand avoids eyes, sun-over-horizon and plain discs (other apps' marks).
- Anything launched locally must be quit and checked with `pgrep -lx Gloam`; `snapshots.sh` and
  `--capture` exit by themselves.
