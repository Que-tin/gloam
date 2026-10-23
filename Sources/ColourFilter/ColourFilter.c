#include "ColourFilter.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>

typedef struct { double m[9]; } Matrix;

bool gloamSystemColourFilter(float out[9]) {
    static bool (*enabled)(long);
    static CFTypeRef (*copy)(long, long, long);
    static Matrix (*matrix)(CFTypeRef);
    static dispatch_once_t loaded;
    dispatch_once(&loaded, ^{
        void *ma = dlopen("/System/Library/Frameworks/MediaAccessibility.framework/MediaAccessibility", RTLD_LAZY);
        if (ma) {
            enabled = dlsym(ma, "MADisplayFilterPrefGetCategoryEnabled");
            copy = dlsym(ma, "MADisplayFilterCopySystemFilter");
            matrix = dlsym(ma, "MADisplayFilterGetMatrix");
        }
    });
    // Category 1 is the Color Filters (as universalaccessd asks for it).
    if (!enabled || !copy || !matrix || !enabled(1)) return false;
    CFTypeRef filter = copy(0, 1, 0);
    if (!filter) return false;
    Matrix m = matrix(filter);
    CFRelease(filter);
    for (int i = 0; i < 9; i++) out[i] = (float)m.m[i];
    return true;
}
