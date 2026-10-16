# The science behind Gloam's defaults

Gloam's schedule and numbers come from the research below, not from habit. This page is the
reasoning; `Sources/GloamCore/Schedule.swift` and `Melanopic.swift` are the implementation.
Gloam is a general-wellness tool, not a medical device.

## What actually matters: melanopic light

The light that shifts the body clock and suppresses melatonin is sensed mainly by
melanopsin in intrinsically photosensitive retinal ganglion cells, peaking around 480–490 nm.
CIE S 026/E:2018 defines **melanopic EDI** (equivalent daylight illuminance) to measure it.
Across lab studies it predicts melatonin suppression and sleep effects better than photopic
lux or colour temperature (Cajochen et al. 2022, *Lighting Res. Technol.*; Giménez et al. 2022,
*J. Pineal Res.*).

**Consensus thresholds** (Brown et al. 2022, *PLOS Biology* 20(3):e3001571,
doi:10.1371/journal.pbio.3001571; reaffirmed in CIE TN 015:2023), measured at the eye:

| When | Melanopic EDI |
|---|---|
| Daytime | ≥ 250 lx |
| From 3 h before bedtime | ≤ 10 lx |
| Sleep environment | ≤ 1 lx |

Individual sensitivity varies more than 50-fold (Phillips et al. 2019, *PNAS*
doi:10.1073/pnas.1901824116), which is why Settings has two limits (warmest, darkest) that
hold the automatic tint back without replacing it.

## How much light a screen gives off

Illuminance at the eye ≈ screen luminance × the solid angle the screen fills. A 27″ monitor at
60 cm and 200 cd/m² delivers roughly 85 lx melanopic EDI showing white; a 14″ laptop at 50 cm
and 150 cd/m² about 28 lx. A bright white screen alone can be 3–10× over the evening ceiling,
before room lighting is counted.

## Brightness beats colour

- **Schöllhorn et al. 2023**, *Communications Biology* 6:228 (doi:10.1038/s42003-023-04598-4):
  colour-matched screens differing only in melanopic output (~5 vs ~150 lx) changed sleep
  latency, melatonin and its timing in proportion to melanopic dose. Dose = intensity × spectrum.
- **Nagare et al. 2019**, *Lighting Res. Technol.*: a built-in night mode at unchanged brightness did not
  significantly reduce melatonin suppression; the authors conclude brightness must drop too.
- **Duraccio et al. 2021**, *Sleep Health*: no measurable sleep difference from a built-in night mode alone
  in a 7-night field study.

- **Green et al. 2017**, *Chronobiol. Int.* 34:855: two hours of screen light; short-wavelength
  light disrupted sleep and melatonin at both intensities tested, intensity mattering less. The
  intensity range was narrow, so it doesn't contradict a dose model, but it is why Gloam warms
  as well as dims rather than dimming alone.
- **Heath et al. 2014**, *Chronobiol. Int.*: one hour of a warm-shift app on a tablet before bed in 16
  adolescents changed neither sleep onset nor sleep architecture. No controlled trial shows a
  screen app improving sleep; Gloam claims less light, not better sleep.

Takeaway: **warming alone removes only about 40–65% of melanopic light; dimming is the main
lever and warmth multiplies it.** Gloam therefore dims as well as warms from wind-down onward.

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
measured; blue is the least certain (±25%). Melanopic output relative to white, as Gloam
computes it (a single P3 panel modelled on its own comes out a few points higher at each step):

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
3 h before bedtime (Brown et al. 2022 never mention sunset). Sunset alone does little: 3400 K at
full brightness is still ~4× over the evening ceiling. So the dimming stages are clock-anchored,
but with two rules that keep the product light:

- **No setup question.** Settings outside onboarding are changed by roughly 2–5% of users (UIE;
  Firefox telemetry), while an onboarding question taxes everyone. A 23:00 default fits ~60% of
  adults within an hour (Withings, 117k adults: mean bedtime 23:30, SD 65 min), and people's own
  night-to-night variation (SD ~94 min) is larger than that error. Late sleepers set a
  gentler Darkest limit; an editable bedtime was cut (almost nobody would set it).
- **No dimming in daylight.** Wind-down and Night never start while the sun is up. At 52°N a fixed
  20:00 wind-down would otherwise dim the screen before sunset on ~170 days a year, which reads as
  broken, and anyone who wants it can lower brightness by hand. In summer they follow sunset.

| Stage | Starts | Default | ≈ Melanopic vs white |
|---|---|---|---|
| Sunset | sun 3° → −6° elevation | 3400 K, 100% | 44% |
| Wind-down | bedtime − 3 h, not before sundown (45 min ease) | 2700 K, 70% | 14% |
| Night | bedtime − 1 h, not before sundown (45 min ease) | 1900 K, 55% | 4% |
| Morning | back to daylight by wake time (20 min ease) | 6500 K, 100% | 100% |

Night stops at 55% rather than the ~35% the evidence would allow, because a first evening that
suddenly goes very dark reads as a broken display. People who want more can lower it.

Morning light should be bright: after waking Gloam ignores the sun for five hours (easing back
in afterwards), so a dark winter morning isn't left filtered.

## Colour temperature conversion

Kelvin → RGB uses Krystek's (1985) rational approximation of the Planckian locus in CIE 1960,
converted to the display's own linear RGB (its ColorSync profile: P3 for Mac screens, sRGB when
unreadable), white-balanced so 6500 K is identity, then gamma-encoded. In sRGB it agrees with
Ingo Thies' measured blackbody table (2013) within a few percent (3400 K ≈ 1.00 / 0.79 / 0.56) and stays
physically meaningful below 2000 K, where the common Tanner Helland fit drifts. The display's
own space matters below ~2000 K: the warm white lies outside sRGB, where blue clamps to zero;
sent to a P3 panel those numbers show a purer red than asked for (1900 K, encoded: 1.00 / 0.53
/ 0.02 in sRGB vs 1.00 / 0.61 / 0.23 for a MacBook Pro XDR panel), and white text blooms red.
The display's matrix is built from its profile's primaries: asking ColorSync to convert XYZ
straight to the display clips at 1 and silently weakens every warm tint.
Transitions interpolate in mireds (10⁶/K), where equal steps look equally large.

## Room light (optional)

With a MacBook's lid open, the ambient light sensor (read through a private IOKit interface;
no reading means no change) eases the dimming in a bright room: all of it at ≤ 10 lx, the
evening ceiling Brown et al. 2022 recommend, a third of it at ≥ 500 lx, log-linear between.
In a bright room the room dominates the light reaching the eye (Gooley et al. 2011, *JCEM*:
room light < 200 lx before bed delayed melatonin onset in nearly everyone), so a much darker
screen mostly costs readability. This is a reasoned default, not a trial result.

## What Gloam does not claim

No claim that it improves sleep, raises melatonin, treats any condition, reduces eye strain or
protects the eyes. Trials of colour shifting alone show small or no sleep effects, and a
Cochrane review (Singh et al. 2023, CD013244) found no eye-strain benefit from blue blocking.
Room lighting and total screen time matter more than screen colour; dim, warm lamps in the
evening do the most good.
