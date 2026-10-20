# Gloam

A native macOS menu-bar app that warms and dims displays in the evening, timed to sunset and a
bedtime (23:00 by default), grounded in circadian research (melanopic light, CIE S 026). An
open-source, better-looking alternative to the usual screen-warming apps. Why every default is what it is: `docs/science.md`.

## Map

- `Sources/GloamCore/` — pure logic, no AppKit, fully unit-tested: `Schedule` (stages → `Tint`;
  `evening(around:)` gives the night as dates, DST-safe; bedtime/wake as `ClockTime`),
  `ColorTemperature` (Kelvin → gains, `Tint`), `SolarPosition`, `Melanopic` ("blue" light),
  `Smear` (the floor that stops built-in LCDs smearing), `BacklightDim` (backlight dimming as a
  fraction of the level found), `Location` (zone.tab), `EnginePolicy` (gamma vs overlay per chip),
  `Command` (`gloam://` toggle/on/off/open), `DisplayIdentity` (reused ids, EDID pairing).
- `Sources/Gloam/App/` — `GloamApp` (`@main`: single instance, `--uninstall`, `Windows`, URLs, debug
  flags: see `Debug`), `MenuBarPanel` (status item: click popover, right-click menu), `Updates` (Sparkle), `Intents` (Shortcuts, Focus filter;
  `build-app.sh` builds their metadata), `ToggleShortcut` (global hotkey). `Model/AppModel` — settings, clock, target tint.
- `Sources/Gloam/Display/` — `DisplayController` (fades and reapply), `GammaEngine`, `OverlayEngine`,
  `Displays`, `RoomLight` (sensor), `Backlight`, `SavedDims` (crash recovery), `Redraw` (a frame now),
  `DDC` (monitors over DDC/CI, paired by EDID via core `DisplayIdentity`; verified on one monitor).
- `Sources/Gloam/UI/` — the "light as material" design: `PopoverView`, `Lamp` (orb dial, dimming
  ladder, small parts), `GloamGlyph` (menu-bar mark), `WelcomeView`, `SettingsView`,
  `EveningGraph` (Settings' evening, also its control), `CitySearch`, `Theme` (colours, names, formats),
  `Wordmark` (the logo, drawn from the SVG's path).
- `.github/workflows/` — `ci` (tests, disk image), `release` (a pushed `v*` tag → signed GitHub release).
- `Tests/GloamCoreTests/` — Swift Testing suites; `scripts/` — `build-app.sh` (app + dmg),
  `make-icon.swift`, `make-dmg-background.swift`, `scrub-dmg-layout.swift`, `make-social-preview.swift`, `snapshots.sh`; `Resources/Info.plist` (template; `build-app.sh` fills `__VERSION__`), `Resources/dmg-layout` (the disk image's Finder layout, made once and scrubbed by `build-app.sh`); `docs/` (science, screenshots);
  `assets/` (icon, wordmark SVGs on dark and light, which `UI/Wordmark` draws too; the social preview).

## Commands

```sh
swift test                             # core tests
swift run Gloam --showcase --at 22:30  # popover in a window at 22:30 (debug; never tints)
swift run Gloam --film DIR             # popover frames while switching off and on (--capture: stills)
./scripts/snapshots.sh                 # regenerate docs/screenshots (never tints the screen)
./scripts/build-app.sh                 # .build/Gloam.app + Gloam.dmg, Apple silicon, ad-hoc signed
```

## Constraints

- macOS 14+, Apple silicon only (arm64), Xcode 27 (26.6 crashes compiling the UI);
  app on MainActor, `GloamCore` nonisolated, notifications via `for await`.
- One dependency, Sparkle (updates, `App/Updates`); no telemetry, no location permission (update checks and
  a city search are the only network use).
  Wording stays non-medical; defaults change only with evidence in `docs/science.md`. English only,
  but every user-facing string goes through `String(localized:)` (whole sentences, `Format` numbers).
- Onboarding asks nothing; Welcome is a draft until Start (closing it first quits, unsaved; the
  menu-bar icon appears with Start). Bedtime and wake are clock times, never stages, set only in
  Settings (bedtime 20:00–03:00, wake 04:00–12:00, quarter hours: a night-time sleep, ≥ 8 h awake);
  dimming never starts before sunset. Stages are fixed; only Warmest and Dimmest (where Night goes)
  are settings. The popover's dial and ladder override until the next morning (first of sunrise
  and wake) or evening (first of sunset and bedtime); per-stage values were cut ("Auto" got unclear).
- Popover controls are positions on the schedule's fixed scales, so they never move under the
  user's brightness keys; no notices. Dimming: each screen takes the position the same share of
  the way to its own darkest (`Stage.brightness(_:darkest:)`, from where tonight began), so a
  dimmer screen is dimmed less. Warmth isn't mapped (a built-in's night went 4100 K): each
  screen shows it up to its smear limit, so steps past that limit change nothing there.
- Tint gains use each display's own colour space (sRGB on P3 turns warm white red); private APIs
  (`RoomLight`/`Backlight`) return nil for "no change".
- Built-in, Apple and DDC/CI displays are dimmed by backlight as a fraction of the level found
  (`BacklightDim`): key presses and auto-brightness are adopted, never fought; quitting (or, after a
  crash, the next launch) restores. The rest: signal, never below 30%.
- A built-in LCD never draws a white under `DisplayController.smearFloor` of daylight white's light,
  scaled by the user's slider (all from 85 %, none ≤ 50 %, measured): dimming goes first, then warmth. Past
  the recommended night the user consents: this floor and the 8 % light floor ease off (`consent`).
  Monitors opt in (`smearGuarded`): macOS reports nothing about their panels.
- Every window is ours and AppKit-hosted: the popover is a borderless panel, not `MenuBarExtra`
  (unstylable, can't be opened or captured); Settings isn't a SwiftUI `Settings` scene. Dark. One
  app owns the gamma table; interference is detected generically, never by app name.
- Ticks (5 s; 60 s when nothing is due, the screens sleep, every screen is switched off in
  Settings, or a pause holds a hand setting; early for a pause or hand setting that ends,
  `nextExpiry`) write the tint and read backlights; 2 Hz only while the popover is open. A read
  before writing keeps key presses adopted; a monitor is read with nothing sent until it answers
  (`readFirst`), before a step once its reading is a few seconds old (in a fade, once at its start).
  Ticks write at once, apart from a brief glide over a visible step; launches, wakes and clock
  changes ease. The gamma table is rewritten only if something overwrote it. A timed pause (right-click "Pause",
  Shortcuts' Pause Gloam) ends itself (`resumeAt`); app and Focus pauses don't.
- Deliberately absent: an "Always" mode, presets, a daytime tint, per-stage tuning, a timeline or
  Kelvin numbers shown in the popover (only its tooltip and VoiceOver give them; Settings has the
  graph), naming rival apps in the app.
- The brand avoids eyes, sun-over-horizon and plain discs (other apps' marks). Anything
  launched locally must be quit and checked with `pgrep -lx Gloam` (snapshot/capture/film runs exit).
