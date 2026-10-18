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
  `Command` (`gloam://` toggle/on/off/open).
- `Sources/Gloam/App/` — `GloamApp` (`@main`: single instance, `--uninstall`, `Windows`, URLs, debug
  flags `--showcase --at --snapshot --capture --film --onboarded --off --floor`), `MenuBarPanel`
  (status item: click popover, right-click menu). `Model/AppModel` — settings, clock, target tint.
- `Sources/Gloam/Display/` — `DisplayController` (fades and reapply), `GammaEngine`,
  `OverlayEngine`, `Displays`, `RoomLight` (sensor), `Backlight` (read and dimmed), `DDC`
  (third-party monitors over DDC/CI, on a background queue; unverified on hardware).
- `Sources/Gloam/UI/` — the "light as material" design: `PopoverView`, `Lamp` (orb dial, dimming
  ladder, small parts), `GloamGlyph` (menu-bar mark), `WelcomeView`, `SettingsView`,
  `EveningGraph` (Settings' evening, also its control), `CitySearch`, `Theme` (colours, names, formats).
- `Tests/GloamCoreTests/` — Swift Testing suites; `scripts/` — `build-app.sh`, `make-icon.swift`,
  `snapshots.sh`; `Resources/Info.plist` (template; `build-app.sh` fills `__VERSION__`); `docs/`.

## Commands

```sh
swift test                             # core tests
swift run Gloam --showcase --at 22:30  # popover in a window at 22:30 (debug; never tints)
swift run Gloam --film DIR             # popover frames while switching off and on (--capture: stills)
./scripts/snapshots.sh                 # regenerate docs/screenshots (never tints the screen)
./scripts/build-app.sh                 # .build/Gloam.app, universal, ad-hoc signed
```

## Constraints

- macOS 14+, universal (Intel Macs on 14/15 are a core audience); macOS 26 SDK. Swift 6.2: the app
  defaults to MainActor, `GloamCore` stays nonisolated; notifications via `for await`.
- No dependencies, no telemetry, no location permission (a city search is the only network use).
  Wording stays non-medical; defaults change only with evidence in `docs/science.md`. English only,
  but every user-facing string goes through `String(localized:)` (whole sentences, `Format` numbers).
- Onboarding asks nothing; Welcome is a draft until Start (closing it first quits, unsaved; the
  menu-bar icon appears with Start). Bedtime and wake are clock times, never stages, set only in
  Settings (bedtime 20:00–03:00, wake 04:00–12:00, quarter hours: a night-time sleep, ≥ 8 h awake);
  dimming never starts before sunset. Stages are fixed; only the Warmth and Dimming caps are
  settings. The popover's dial and ladder override until the next stage (per-stage values and
  global strengths were tried and cut: "back to automatic" got unclear).
- Popover controls span fixed ranges and show what was asked; the screen stops at its limits, with a
  notice only for a hand setting (ends that moved with the limits made dimming move the warmth knob).
- Tint gains use each display's own colour space (sRGB gains on P3 turn warm white bloomy red);
  `RoomLight`/`Backlight` are private API: nil means no change.
- Built-in, Apple and DDC/CI displays are dimmed by backlight as a fraction of the level found
  (`BacklightDim`): key presses and auto-brightness are adopted, never fought; quitting (or, after a
  crash, the next launch) restores. The rest: signal, never below 30%.
- A built-in LCD never draws a white under `DisplayController.smearFloor` of daylight white's light
  (light-on-dark text smears below it; a warm tint is a dim white): dimming goes first, then warmth.
  Monitors opt in (`smearGuarded`): macOS reports nothing about their panels.
- One app owns the gamma table; interference is detected generically, never by app name.
- Every window is ours and AppKit-hosted: the popover is a borderless panel, not `MenuBarExtra`
  (unstylable, can't be opened or captured); Settings isn't a SwiftUI `Settings` scene. Dark.
- Ticks (5 s; 60 s untinted with nothing due) write the tint directly; only user actions fade, and
  a new target retargets a running fade. Backlights are polled at 2 Hz while tinted (DDC 20 s),
  else once a minute; the gamma table is rewritten only if something overwrote it.
- Timed off (right-click "Turn Off Temporarily": an hour, until morning) ends by itself
  (`AppModel.resumeAt`); the switch is untimed; an app exception ("True Colour for X") is permanent.
- Deliberately absent, cut after review: an "Always" mode, presets, a daytime tint, per-stage
  tuning, an evening timeline or "next" strip in the popover (Settings has the graph), Kelvin
  numbers in the popover, naming rival apps in the app.
- The brand avoids eyes, sun-over-horizon and plain discs (other apps' marks). Anything
  launched locally must be quit and checked with `pgrep -lx Gloam` (snapshot/capture/film runs exit).
