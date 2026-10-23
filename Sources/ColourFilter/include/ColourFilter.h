// The system Color Filter (Accessibility › Display › Color Filters) as the matrix macOS shows it,
// for `ColourLayer` to carry it into its own: a display's matrix replaces the filter on it.
// In C because MediaAccessibility returns the matrix as a C struct of nine doubles, returned in
// memory, which Swift can't declare for a function it only finds at run time.

#include <stdbool.h>

/// The filter's matrix, row-major, into `out`; false (and `out` untouched) when no filter is on,
/// or this macOS lacks the calls.
bool gloamSystemColourFilter(float out[9]);
