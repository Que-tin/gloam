# Contributing to Gloam

Thanks for helping. Bug reports from real display setups are especially valuable: screen
tinting depends on hardware nobody can test all of.

## Build and run

Runs on Apple silicon Macs with macOS 14+. Building needs Xcode 27 (Xcode 26.6's compiler crashes on the UI code).

```sh
swift test                      # core logic: colour science, sun, schedule
swift run Gloam                 # run from source (Welcome first, then the menu-bar icon)
./scripts/build-app.sh          # release Gloam.app in .build/
./scripts/snapshots.sh          # popover at four times of day, Welcome and Settings
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
- No telemetry, no network calls beyond Sparkle's update check and a user-initiated city search.
- Health wording stays honest: Gloam reduces evening melanopic light; it doesn't claim to
  improve sleep or treat anything.

## Reporting a display problem

Please include your Mac model and chip, macOS version, the display's name (System Settings ›
Displays shows it), whether HDR is on, and which method is in use. If the screen doesn't
change at all, say whether switching the method to Overlay helps.

## Releasing

Push a tag: `git tag v0.9.1 && git push origin v0.9.1`. The Release workflow tests and builds that
commit, signs the disk image for Sparkle and publishes it with its `appcast.xml`, which installed
copies check about once a day (`releases/latest/download/appcast.xml`). Edit the generated notes on
GitHub afterwards if you like.

It needs the update signing key as the repository secret `SPARKLE_PRIVATE_KEY`. The key was made
once with Sparkle's `generate_keys` and lives in the maintainer's login Keychain; export it with
`generate_keys -x <file>`, keep a copy somewhere safe (a GitHub secret can't be read back, and
without the key installed copies can never be updated again), then
`gh secret set SPARKLE_PRIVATE_KEY < <file>` and delete the file.
