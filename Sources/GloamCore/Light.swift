// The two scales Gloam's controls and graph share: warmth and dimming as positions, 0 (daylight,
// full brightness) to 1 (the warmest, the dimmest there is). Warmth is even in mired, where equal
// steps are equal visible steps; dimming is linear in brightness.

public enum Light {
    /// Warmth as a position on a fixed scale, 0 (daylight) … 1 (ember), even in mired, where
    /// equal steps are equal visible steps. The graph and the popover's dial both use it; each
    /// screen shows as much of it as its smear limit allows.
    public static func warmth(_ kelvin: Double) -> Double {
        let (cool, warm) = (Kelvin.mired(Stage.kelvinRange.upperBound), Kelvin.mired(Stage.kelvinRange.lowerBound))
        return min(1, max(0, (Kelvin.mired(kelvin) - cool) / (warm - cool)))
    }

    public static func kelvin(warmth w: Double) -> Double {
        let (cool, warm) = (Kelvin.mired(Stage.kelvinRange.upperBound), Kelvin.mired(Stage.kelvinRange.lowerBound))
        return 1e6 / (cool + (warm - cool) * min(1, max(0, w)))
    }

    /// Dimming as a position, 0 (full brightness) … 1 (the deepest there is), on the schedule's
    /// scale: the graph's and the ladder's alike. Each screen takes it the same share of the way to
    /// its own darkest (`DisplayController.adjusted`), so the scale never moves when the user's
    /// brightness changes (a key press moves the ladder by the press alone).
    public static func dimming(_ brightness: Double) -> Double {
        let darkest = Stage.brightnessRange.lowerBound
        return min(1, max(0, (1 - brightness) / (1 - darkest)))
    }

    public static func brightness(dimming d: Double) -> Double {
        1 - min(1, max(0, d)) * (1 - Stage.brightnessRange.lowerBound)
    }
}
