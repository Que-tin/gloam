# Gloam

A native macOS menu-bar app that warms and dims displays in the evening, timed to sunset and a
bedtime (23:00 by default), grounded in circadian research (melanopic light, CIE S 026). An
open-source, better-looking alternative to the usual screen-warming apps. Why every default is what it is: `docs/science.md`.

## Map

- `Sources/GloamCore/` — pure logic, no AppKit, fully unit-tested: `Schedule` (stages → `Tint`;
  `evening(around:)` gives the night as dates, DST-safe; bedtime/wake as `ClockTime`),
  `ColorTemperature` (Kelvin → gains, `Tint`), `Light` (the controls' warmth and dimming scales), `SolarPosition`, `Melanopic` ("blue" light),
  `Smear` (the floor that stops built-in LCDs smearing), `BacklightDim` (a screen's backlight:
  position ↔ light from its day level, readings as moves), `BacklightReports` (what
  macOS's reports on one backlight mean: echoes, holds, whose move), `Shift` (a hand-set move from the plan
  and when it ends, `ShiftClock`), `Location` (zone.tab), `EnginePolicy` (gamma vs overlay per
  chip), `Command` (`gloam://` toggle/on/off/open), `DisplayIdentity` (reused ids, EDID pairing).
- `Sources/Gloam/App/` — `GloamApp` (`@main`: single instance, `--uninstall`, `Windows`, URLs, debug
  flags: see `Debug`), `MenuBarPanel` (status item: click popover, right-click menu), `Updates` (Sparkle), `Intents` (Shortcuts, Focus filter;
  `build-app.sh` builds their metadata). `Model/AppModel` — settings, clock, target tint.
- `Sources/Gloam/Display/` — `DisplayController` (fades and reapply), `GammaEngine`, `OverlayEngine`,
  `Displays`, `RoomLight` (the sensor's lux as macOS reports it), `Backlight`, `BrightnessEvents` (macOS's reports of backlight moves and who made them), `SavedDims` (crash recovery), `Redraw` (a frame now),
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
swift run Gloam --onboarded --at 21:00 --speed 60  # really tints, clock from 21:00 at 60× (quit installed Gloam first)
swift run Gloam --capture DIR          # photographs of the real popover, Welcome and Settings
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
  are settings; per-stage values were cut ("Auto" got unclear).
- By hand, a screen shows the plan plus its shift (`Shift`): the brightness keys or a monitor's
  buttons shift that screen, the popover's ladder the screen it opens on, the dial every screen's
  warmth. The last move wins; the shift keeps its distance from the plan all evening (never past
  the floor unless chosen there) and shrinks by the clock in the morning, ending 10 min after the
  plan (longer for a far or late one: 30 min per ladder unit), whether or not Gloam saw it; pauses
  fade it out and back, a crash or an update keeps it, "Auto" or switching off by hand clears it
  (on again is Auto), and Settings' preview shows it. A key press sets the day level instead in the
  evening's first minutes (under 10 % shown) and once the morning's plan is done; above the day
  level it becomes the day level. Never written back. Holding a press until morning, bending the
  night's curve through it, or shrinking it with the plan's fall (room light amplified it) were
  tried and dropped. A move by day is held until the plan reaches 10 %, then rides from there
  (worked out, not settled when seen). A move onto the plan stores nothing; bedtime or wake moved
  tonight move tonight's shifts' end with them; a pause ending in the morning drops a shrinking one.
- Popover controls are positions: the ladder's scale never moves under the brightness keys (a
  press moves it only by the press); no notices. Dimming: each screen takes the position the same
  share of the way to its own darkest (its light floor against its day level; past 1, key presses
  only, on to black), so a dimmer screen is dimmed less. Warmth: the dial spans the popover
  screen's own warm range (100 % = its smear limit at the user's brightness; a monitor without one,
  the whole scale), the plan at its share of it, at most 100 %, so the plan looks as clamped
  before; the dial's shift is that share's distance, taken on each screen's own range. On the fixed
  scale a MacBook's limit sat a quarter of the way along and the rest did nothing. The knob moves
  with brightness only while the plan sits below the limit. Off or paused, the controls show 0 %
  and daylight, and a move switches on from there by hand (every other screen at 0: nothing jumps).
- Tint gains use each display's own colour space (sRGB on P3 turns warm white red); private APIs
  (`RoomLight`/`Backlight`/`BrightnessEvents`) return nil (or false) for "no change", and are called only with
  the argument types measured.
- Built-in, Apple and DDC/CI displays are dimmed by backlight relative to the level found
  (`BacklightDim`): moves made elsewhere are adopted, never fought; quitting (or, after a crash,
  the next launch) restores. macOS reports its backlights' moves and who made them
  (`BrightnessEvents`, read by `BacklightReports`): the user's become shifts, auto-brightness's the
  new day level (the evening eases back down from it). Gloam's light writes come back as plain
  steps with no settled report and teach auto-brightness nothing; a slider-level write is reported
  as the user's, so only the release uses one. Without reports (none on that macOS, or Gloam's
  writes stopped being echoed; tried again at each display change) a screen with no
  auto-brightness is read on the tick (any change not Gloam's is the user's); one with it is
  dimmed by signal: guessed from readings, ramps became shifts and presses were undone. The room's
  lux is watched, never read on its report: a read reports to every watcher, so that looped.
  The rest: signal, never below 30%.
- A built-in LCD never draws a white under `DisplayController.smearFloor` of daylight white's light,
  scaled by the user's slider (all from 85 %, none ≤ 50 %, measured): dimming goes first, then warmth. Past
  the recommended night the user consents: this floor and the 8 % light floor ease off (`consent`).
  Monitors opt in (`smearGuarded`): macOS reports nothing about their panels.
- Every window is ours and AppKit-hosted: the popover is a borderless panel, not `MenuBarExtra`
  (unstylable, can't be opened or captured); Settings isn't a SwiftUI `Settings` scene. Dark. One
  app owns the gamma table; interference is detected generically, never by app name.
- Ticks (5 s; 60 s when nothing is due, the screens sleep, every screen is switched off in
  Settings, Gloam is held, or only held shifts show; early for a timed pause that ends,
  `nextExpiry`; `--speed` divides them, to 1.25 s at least) write the tint, read monitors and retry failed writes; a reported backlight is read only when
  macOS reports a move, and nothing is written over one under way. A monitor is read with nothing sent until it answers
  (`readFirst`), before a step once its reading is a few seconds old (in a fade, once at its
  start). Ticks write at once, apart from a brief glide over a visible step; launches, wakes and
  clock changes ease. The gamma table is rewritten only if something overwrote it or left it black
  (`repairBlank`). A timed pause
  (right-click "Pause", Shortcuts' Pause Gloam) ends itself (`resumeAt`); app and Focus pauses don't.
- Deliberately absent: an "Always" mode, presets, a scheduled daytime tint, per-stage tuning, a timeline or
  Kelvin numbers shown in the popover (only its tooltip and VoiceOver give them; Settings has the
  graph), naming rival apps in the app.
- The brand avoids eyes, sun-over-horizon and plain discs (other apps' marks). Anything
  launched locally must be quit and checked with `pgrep -lx Gloam` (snapshot/capture/film runs exit).
