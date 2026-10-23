# The science behind Gloam's defaults

Gloam's numbers come from the research below; the implementation is in `Sources/GloamCore/`
(`Schedule`, `Melanopic`, `ColorTemperature`, `Smear`, `BacklightDim`). A general-wellness tool, not a medical device.

## What actually matters: melanopic light

The light that shifts the body clock and suppresses melatonin is sensed mainly by
melanopsin in intrinsically photosensitive retinal ganglion cells, peaking around 480–490 nm.
CIE S 026/E:2018 defines **melanopic EDI** (equivalent daylight illuminance) to measure it.
It is the best single predictor of melatonin suppression across lab studies (Giménez et al.
2022, *J. Pineal Res.*) and shows dose-response for sleep latency at higher levels (Cajochen et
al. 2022, *Lighting Res. Technol.*).

**Consensus thresholds** (Brown et al. 2022, *PLOS Biology* 20(3):e3001571,
doi:10.1371/journal.pbio.3001571; also published as the workshop report CIE TN 015:2023, advisory, not a CIE position), measured at the eye:

| When | Melanopic EDI |
|---|---|
| Daytime | ≥ 250 lx |
| From 3 h before bedtime | ≤ 10 lx |
| Sleep environment | ≤ 1 lx |

Individual sensitivity varies more than 50-fold (Phillips et al. 2019, *PNAS*), which is why
Warmest and Dimmest (Settings) set where the night goes: lighter for some, deeper for the sensitive.

## How much light a screen gives off

Illuminance at the eye ≈ screen luminance × the solid angle it fills. Showing white, a 27″
monitor at 60 cm and 200 cd/m² delivers roughly 85 lx melanopic EDI, a 14″ laptop at 50 cm and
150 cd/m² about 28 lx: 3–10× the evening ceiling before room lighting is counted.

## Brightness beats colour

- **Schöllhorn et al. 2023**, *Communications Biology* 6:228 (doi:10.1038/s42003-023-04598-4):
  colour-matched screens differing only in melanopic output (about 2–3× within each of four
  intensity levels spanning ~5–150 lx) changed sleep latency, melatonin and its timing
  log-linearly with melanopic dose, with no threshold. Dose = intensity × spectrum.
- **Nagare et al. 2019**, *Lighting Res. Technol.*: a built-in night mode at unchanged brightness did not
  significantly reduce melatonin suppression; the authors conclude brightness must drop too.
- **Duraccio et al. 2021**, *Sleep Health*: no measurable sleep difference from a built-in night mode alone
  in a 7-night field study.
- **Green et al. 2017**, *Chronobiol. Int.* 34:855: short-wavelength screen light disrupted
  sleep and melatonin at both (narrowly spaced) intensities tested: why Gloam warms as well.
- **Heath et al. 2014**, *Chronobiol. Int.*: a warm-shift app on a tablet changed neither sleep onset nor
  architecture in 16 adolescents. We know of no controlled trial showing a screen app improving
  sleep; Gloam claims less light, not better sleep.

Takeaway: **warming to the usual 3400–2700 K removes only about half to two thirds of melanopic
light; dimming is the main lever and warmth multiplies it.** Gloam therefore dims as well as
warms from wind-down onward.

## Why blue filters underperform: per-channel weights

Modelling typical LCD and OLED primaries against the CIE S 026 action spectrum (balanced to
D65 white) gives these approximate shares of white's melanopic output, in linear light:

| Panel | Red | Green | Blue |
|---|---|---|---|
| sRGB white-LED LCD | 0.007 | 0.571 | 0.422 |
| P3 LCD (Apple-like) | 0.001 | 0.601 | 0.399 |
| P3 OLED | 0.001 | 0.53–0.55 | 0.45–0.47 |

Gloam uses (0.005, 0.57, 0.425), a blend across panel types. **Green carries over half the
signal**, so cutting only blue leaves most of it. These are modelled from typical spectra, not
measured; blue is the least certain (±25%). Melanopic output relative to white, computed in
sRGB (the popover computes in the screen's own space; on a P3 Mac screen the same tints keep
more green and blue and read 3–6 points higher, e.g. 3400 K 0.50, 1900 K 0.20):

| Colour temperature | Relative melanopic |
|---|---|
| 5000 K | 0.75 |
| 3400 K | 0.44 |
| 2700 K | 0.30 |
| 1900 K | 0.15 |
| 1200 K | 0.04 |

Gamma tables act on display-encoded values; light scales roughly as value^2.2, so Gloam's 50%
brightness is about 22% of the light. The estimate in the popover accounts for this.

## Timing: sunset leads, a bedtime default deepens it

Melatonin begins rising about 2 h before habitual sleep, and the consensus ceiling applies from
3 h before bedtime (Brown et al. 2022 never mention sunset). Sunset alone does little: on a 27″
monitor, 3400 K at full brightness is still ~4× over the evening ceiling. So the dimming stages
are clock-anchored, but with two rules that keep the product light:

- **No setup question.** An onboarding question taxes everyone, while settings are changed by
  few. A 23:00 default fits ~60% of adults within an hour (Withings, 117k adults: mean bedtime
  23:30, SD 65 min); the rest move bedtime and wake in Settings, within a night-time sleep.
- **No dimming in daylight.** Wind-down and Night fade in only as the sun sets (from 3° above to
  3° below the horizon). A fixed 20:00 wind-down would otherwise dim the screen in daylight on
  3½–5½ months a year at 52°N (depending on where in the time zone), which reads as broken.
  In summer they follow sunset.

| Stage | Starts | Default | ≈ Melanopic vs white |
|---|---|---|---|
| Sunset | sun 3° → −6° elevation | 3400 K, 100% | 44% |
| Wind-down | bedtime − 3 h, gated by sunset (45 min ease) | 2700 K, 70% | 14% |
| Night | bedtime − 1 h, gated by sunset (45 min ease) | 1900 K, 55% | 4% |
| Morning | back to daylight by wake time (20 min ease) | 6500 K, 100% | 100% |

(sRGB figures, as above. On a built-in screen with a bright backlight the smear floor below
caps Night's warmth, leaving it nearer 10%.)

Night stops at 55% by default rather than going deeper, because a first evening that suddenly
goes very dark reads as a broken display. Settings can take it to ember (1200 K) and 30 % for
sensitive people in dark rooms: about 4× less melanopic light from the screen each way. Below
~5 lx the dose-response is extrapolated, and in a lit room (homes average ~18 melanopic lux
before bed, Cain et al. 2020, *J. Pineal Res.*) the room outweighs it. Past the default the user
consents: the smear floor and the 8 % light floor ease off towards the ends (no smear floor at
ember, 3 % light at 30 %), and going warmer shows a note naming the cost.

Morning light should be bright: after waking Gloam ignores the sun for five hours (easing back
in afterwards), so a dark winter morning isn't left filtered.

## Colour temperature conversion

Kelvin → RGB uses Krystek's (1985) rational approximation of the Planckian locus in CIE 1960,
converted to the display's own linear RGB (its ColorSync profile: P3 for Mac screens, sRGB when
unreadable), white-balanced so 6500 K is identity, then gamma-encoded. In sRGB it matches
Ingo Thies' measured blackbody table (2013; 3400 K: 1.00 / 0.78 / 0.52 against its 1.00 / 0.77 / 0.52) and stays physical
below 2000 K, where that warm white lies outside sRGB: sRGB gains on a P3 panel show a purer
red than asked for (1900 K: 1.00 / 0.53 / 0.02 in sRGB vs 1.00 / 0.61 / 0.23 for a MacBook Pro
XDR panel). The matrix is built from the profile's primaries: asking ColorSync to convert XYZ
straight to the display clips at 1 and silently weakens every warm tint.
Transitions interpolate in mireds (10⁶/K), where equal steps look equally large.

## Dimming: the backlight where macOS allows it, the signal elsewhere

Where the brightness keys work (the built-in panel, Apple displays) Gloam dims the backlight
itself through the same call, the schedule's dimming going the same share of the way to that panel's
own floor, so a dim screen is dimmed less (with half the panel's light the night keeps 37 % of it,
not 27 %; at full brightness it barely changes). The floor is 8 % of the panel's maximum (easing to 3 % only past the recommended night, by choice): about 40 cd/m² on a 500-nit screen, within what is comfortable for sustained
smartphone reading in low room light (Na & Suk 2015, *Opt. Express* 23:16912) and inside the
21–75 cd/m² evening viewers preferred under 13–62 lx room light (Zhou et al. 2021, *Appl. Sci.*
11:4108; Gloam's dark-room case lies below that range, where the optimum trends lower). A key press shifts that screen from the plan for the night, fading out with the
morning (`Shift`); auto-brightness's own move (macOS says which) is the new day level. Why not
the signal: a dimmed signal leaves the backlight at full power,
crushes shadows below ~30 %, pushes the liquid crystal into its slow dark range (below), and
on M5 Pro and M5 Max MacBook Pros (and the MacBook Neo's external displays) macOS 26 and
later ignore gamma tables altogether, an open Apple bug. Third-party
monitors that answer a DDC/CI brightness read (most on a direct DisplayPort, USB-C or HDMI
link; rarely through hubs, never DisplayLink or most TVs) are dimmed the same way over that
channel, on their own scale (usually 0–100); the rest by signal, never below 30 %.

### Light text on a dark background smears when the panel's white is dim

Observed on a mini-LED laptop panel with the slider at 100 %, scrolling white-on-black text:
heavy trails with the whole signal scaled to 55 %, none at 80 %. Both slow parts of the panel
are slowest around black: the liquid crystal (Notebookcheck: ~41–43 ms on current MacBook Pro
panels, 67–80 ms on M2/M3, PWM-approximate; dark-grey transitions unmeasured) and the
mini-LED zones. Apple calls "a slight blur or color change while
scrolling against black backgrounds" normal behaviour of the dimming zones on the iPad Pro's
XDR display, the same mini-LED design (support.apple.com/HT212527). To the panel a warm tint is
a dim white: red stays at full drive, but green and blue carry three quarters of the light.
Relative to daylight white at the same slider position:

| Tint | Light of white |
|---|---|
| 6500 K at 80 % signal (clean) | 61 % |
| 1900 K | 47 % |
| 1900 K at 80 % signal | 29 % |
| 6500 K at 55 % signal (heavy trails) | 27 % |

So the floor is on the luminance of the tinted white (`Smear`; 61 % = 0.8^2.2, in the display's
own colour space), giving up dimming before warmth: of all tints at one luminance the warmest
has the least melanopic light. On a backlight-dimmed display the signal stays at full drive,
so the floor only caps warmth. It eases with the slider the user set (not Gloam's dimming):
none up to 50 %, all of it from 85 %. Measured on the same panel at the Night stage with no
floor and Gloam's backlight dimming in effect: no trails at a slider of 20–50 %, faint at 60 %,
stronger at 80 %, heavy at 100 %. (Contrast alone predicts no change, the backlight scales a
trail with the white around it; at low absolute luminance the trail evidently drops below what
the eye resolves.) Gloam doesn't lower the backlight to buy warmth: that fights the user's own
brightness. A monitor gets the floor, in full, once "Avoid smearing" is on for it in Settings
(macOS says nothing about its panel); a DDC-dimmed one, like the Mac's own, only in warmth. Measured: one panel, one
neutral threshold. That the same luminance predicts warm smearing is the model's claim, backed
by the physics and by iPad Pro XDR users finding the scrolling smear "more prominent when Night
Shift is on"; a floor on green's own drive would put the cap near 3000–3200 K instead.

## Adapting to room light (optional input)

**Room light** (the sensor as macOS reports it; none means no change): with a MacBook's lid
open, a bright room eases the dimming (all of it at ≤ 10 lx, a third at ≥ 500 lx, log-linear
between). The sensor reads photopic lux at the lid, a proxy
for the melanopic light at the eye that Brown et al. 2022's ≤ 10 lx ceiling refers to. In a bright
room the room dominates the light reaching the eye (Gooley et al. 2011, *JCEM*: < 200 lx before
bed delayed melatonin onset in nearly everyone), so a much darker screen mostly costs
readability. A reasoned default, not a trial result.

## What Gloam does not claim

No claim that it improves sleep, raises melatonin, treats any condition, reduces eye strain or
protects the eyes. Trials of colour shifting alone show small or no sleep effects, and a
Cochrane review of blue-filtering lenses (Singh et al. 2023, CD013244) found no eye-strain
benefit. Room lighting and total screen time matter more than screen colour; dim, warm lamps in
the evening do the most good.
