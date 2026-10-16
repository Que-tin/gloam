# Contributing to Gloam

Thanks for helping. Bug reports from real display setups are especially valuable: screen
tinting depends on hardware nobody can test all of.

## Build and run

Runs on macOS 14+. Building needs Xcode 26+ (Swift 6.2 tools, macOS 26 SDK).

```sh
swift test                      # core logic: colour science, sun, schedule
swift run Gloam                 # run from source (menu-bar icon appears)
./scripts/build-app.sh          # release Gloam.app in .build/
./scripts/snapshots.sh          # popover at four times of day, plus the welcome window
```

`swift run Gloam --showcase --at 22:30` opens the popover in a normal window with the clock
set to 22:30 (debug builds only; showcase runs never tint the screen). `--showcase welcome`
shows the first-run window instead. Add `--snapshot out.png` to render to a file and quit.
`--capture DIR` photographs the real popover panel, Welcome and Settings windows, chrome
included, and quits. Anything you launch yourself keeps running until you quit it: check with `pgrep -lx Gloam`.

## Guidelines

- Keep `GloamCore` free of AppKit so it stays unit-testable; put logic there when you can.
- Changes to defaults or to the colour and melanopic maths should cite evidence and update
  [docs/science.md](docs/science.md).
- No telemetry, no network calls beyond a user-initiated city search.
- Health wording stays honest: Gloam reduces evening melanopic light; it doesn't claim to
  improve sleep or treat anything.

## Reporting a display problem

Please include your Mac model and chip, macOS version, the display's name (Settings →
Displays shows it), whether HDR is on, and which method is in use. If the screen doesn't
change at all, say whether switching the method to Overlay helps.
