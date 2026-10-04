// 26AnimSafe — crash-proof reimplementation of the iOS 26-style app open/close zoom,
// ported to the REAL animation surface that exists on iOS 13..15.
//
// Why the previous build did nothing visible:
//   The original 26Anim (and the first cut of this tweak) hooks SpringBoard classes that
//   only exist on iOS 26: SBIconZoomAnimator, SBHomeGesture*Zoom*Settings, etc. On
//   iOS 15.8.8 those classes are absent, so objc_getClass() returns Nil and every
//   safeSwizzle() call silently no-ops -> zero hooks installed. SpringBoard never
//   aborts (good) but the animation is also completely unchanged (the bug you saw).
//
// What this build hooks instead (iOS 13..15, SpringBoardHome.framework):
//   * SBHIconZoomSettings        -> base settings object (duration / scale / cornerRadius)
//   * SBScaleIconZoomAnimator    -> app open/close zoom animator
//   * SBCrossfadeIconZoomAnimator -> app open (icon->app) crossfade zoom animator
//   * SBIconZoomAnimator         -> iOS 26 class, kept as a harmless guarded no-op
//
// All class/method lookups are runtime-only (NSString selectors), so it compiles
// against the public SDK and simply skips anything missing at runtime. Every mutation
// is guarded so SpringBoard can never abort -> no safe mode, ever.
//
// Preferences (reuses the original 26Anim domain so the shipped Settings pane works):
//   ~/Library/Preferences/com.ngkhoi.26anim.plist
//     enabled   (BOOL, default YES)
//     animSpeed ("Original (iOS native)" disables; "iOS 26" enables; default iOS 26)
//     duration  (double seconds; 0/negative = keep system)
//     corner    (double pt; 0 = keep system)
//     scale     (double multiplier; 1.0 = keep system)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

// ---------- tunables (read from the 26Anim prefs domain) ----------
static BOOL   gEnabled  = YES;
static double gDuration = 0.55;   // zoom duration (s); <=0 keeps system value
static double gCorner   = 0.0;    // corner radius applied during zoom (pt); 0 = native
static double gScale    = 1.0;    // extra scale multiplier (1.0 = native)

static NSMutableDictionary<NSString *, NSValue *> *gOrig = nil;

// ---------- preferences ----------
static void loadPrefs(void) {
    @try {
        NSArray *cands = @[
            @"/var/jb/var/mobile/Library/Preferences/com.ngkhoi.26anim.plist",
            @"/var/mobile/Library/Preferences/com.ngkhoi.26anim.plist"
        ];
        NSDictionary *d = nil;
        for (NSString *p in cands) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
                d = [NSDictionary dictionaryWithContentsOfFile:p];
                if (d) break;
            }
        }
        if (!d) return;
        if ([d objectForKey:@"enabled"] != nil)
            gEnabled = [[d objectForKey:@"enabled"] boolValue];
        // honour the original "Animation Speed" segment
        NSString *sp = [d objectForKey:@"animSpeed"];
        if ([sp isKindOfClass:[NSString class]] &&
            [sp rangeOfString:@"Original" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            gEnabled = NO; // user picked the native iOS animation
        }
        if ([d objectForKey:@"duration"] != nil) gDuration = [[d objectForKey:@"duration"] doubleValue];
        if ([d objectForKey:@"corner"]   != nil) gCorner  = [[d objectForKey:@"corner"]   doubleValue];
        if ([d objectForKey:@"scale"]    != nil) gScale   = [[d objectForKey:@"scale"]    doubleValue];
    } @catch (...) { /* ignore */ }
}

static void prefsChanged(CFNotificationCenterRef center, void *observer,
                         CFStringRef name, const void *object, CFDictionaryRef info) {
    loadPrefs();
}

// ---------- the safe modifier for OBJECT-returning getters (e.g. animator -settings) ----------
static id modifySettings(id self, SEL _cmd, IMP origImp) {
    id (*origf)(id, SEL) = (id (*)(id, SEL))origImp;
    if (!gEnabled) return origf(self, _cmd);

    @try {
        id orig = origf(self, _cmd);
        if (orig == nil) return nil;

        // Nudge well-known, safe-to-set properties via KVC; missing setter -> swallowed.
        if (gDuration > 0.0) {
            @try { [orig setValue:@(gDuration) forKey:@"duration"]; } @catch (...) {}
        }
        if (gCorner >= 0.0) {
            @try { [orig setValue:@(gCorner) forKey:@"cornerRadius"]; } @catch (...) {}
        }
        if (gScale > 0.0 && gScale != 1.0) {
            @try {
                NSNumber *cur = [orig valueForKey:@"scale"];
                if (cur) [orig setValue:@([cur doubleValue] * gScale) forKey:@"scale"];
            } @catch (...) {}
        }
        return orig;
    } @catch (...) {
        return origf(self, _cmd);
    }
}

// ---------- guarded object-getter swizzle ----------
static void safeSwizzle(const char *clsName, const char *selName) {
    Class cls = objc_getClass(clsName);
    if (cls == Nil) return;                       // class absent on this iOS -> skip
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) return;                        // getter absent -> skip
    IMP orig = method_getImplementation(m);
    NSString *key = [NSString stringWithUTF8String:selName];
    gOrig[key] = [NSValue valueWithPointer:(void *)orig];
    IMP repl = imp_implementationWithBlock(^id(id s, SEL c) {
        IMP o = (IMP)[gOrig[key] pointerValue];
        return modifySettings(s, c, o);
    });
    method_setImplementation(m, repl);
}

// ---------- guarded SCALAR getter swizzle (for duration/scale/cornerRadius) ----------
// compute(orig) lets each property decide how to combine the system value with ours.
// Takes a block (not a C function pointer) because Clang won't implicitly convert a
// block literal to a function pointer.
typedef double (^ScalarComputeBlock)(double);
static void safeSwizzleScalar(const char *clsName, const char *selName, ScalarComputeBlock compute) {
    Class cls = objc_getClass(clsName);
    if (cls == Nil) return;
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) return;
    double (*origf)(id, SEL) = (double (*)(id, SEL))method_getImplementation(m);
    NSString *key = [NSString stringWithUTF8String:selName];
    gOrig[key] = [NSValue valueWithPointer:(void *)origf];
    IMP repl = imp_implementationWithBlock(^double(id s, SEL c) {
        double o = origf(s, c);
        if (!gEnabled) return o;
        return compute(o);
    });
    method_setImplementation(m, repl);
}

%ctor {
    @autoreleasepool {
        gOrig = [NSMutableDictionary new];
        loadPrefs();

        // Live reload when the user toggles in Settings (the pane posts this Darwin note).
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChanged,
            CFSTR("com.ngkhoi.26anim/settingschanged"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);

        // Only touch iOS 13..15. iOS 16+ already has the native animation; the classes
        // below (SBHIconZoomSettings, SB*IconZoomAnimator) are iOS 13..15 era.
        double v = kCFCoreFoundationVersionNumber;
        if (v < 1750.0) return;     // older than iOS 13
        if (v >= 2150.0) return;    // iOS 16+

        @try {
            // --- iOS 13..15 home-screen zoom SETTINGS (SpringBoardHome.framework) ---
            // Retune the base settings object so every icon zoom (open/close/switcher)
            // picks up our duration / cornerRadius / scale.
            safeSwizzleScalar("SBHIconZoomSettings", "duration", ^double(double o){ return gDuration > 0.0 ? gDuration : o; });
            safeSwizzleScalar("SBHIconZoomSettings", "cornerRadius", ^double(double o){ return gCorner  > 0.0 ? gCorner  : o; });
            safeSwizzleScalar("SBHIconZoomSettings", "scale", ^double(double o){ return (gScale > 0.0 && gScale != 1.0) ? o * gScale : o; });

            // --- iOS 13..15 app open/close ZOOM ANIMATORS ---
            // Mutate the settings object each animator returns (defense in depth).
            safeSwizzle("SBScaleIconZoomAnimator", "settings");
            safeSwizzle("SBCrossfadeIconZoomAnimator", "settings");
            safeSwizzle("SBIconZoomAnimator", "settings");   // iOS 26 class; no-op on iOS 15

            // --- original iOS 26 hook surface (kept as harmless guards; no-op on iOS 15) ---
            safeSwizzle("SBIconZoomAnimator", "zoomUpSettings");
            safeSwizzle("SBIconZoomAnimator", "zoomDownSettings");
            safeSwizzle("SBIconZoomAnimator", "centerZoomSettings");
            safeSwizzle("SBIconZoomAnimator", "switcherToHomeSettings");
            safeSwizzle("SBIconZoomAnimator", "iconZoomDownSettings");
            safeSwizzle("SBHomeGestureCenterRowZoomUpSettings", "homeGestureCenterRowZoomUpSettings");
            safeSwizzle("SBHomeGestureEdgeRowZoomUpSettings",   "homeGestureEdgeRowZoomUpSettings");
            safeSwizzle("SBHomeGestureBottomRowZoomDownSettings","homeGestureBottomRowZoomDownSettings");
            safeSwizzle("SBHomeGestureTopRowZoomDownSettings",  "homeGestureTopRowZoomDownSettings");
            safeSwizzle("SBHomeGestureLargeWidgetZoomDownSettings","homeGestureLargeWidgetZoomDownLayoutSettings");
            safeSwizzle("SBHomeGestureLargeWidgetZoomDownSettings","homeGestureLargeWidgetZoomDownPositionSettings");
            safeSwizzle("SBHomeGestureLargeWidgetZoomDownSettings","homeGestureLargeWidgetZoomDownScaleSettings");
            safeSwizzle("SBHomeGestureMediumWidgetZoomDownSettings","homeGestureMediumWidgetZoomDownLayoutSettings");
            safeSwizzle("SBHomeGestureMediumWidgetZoomDownSettings","homeGestureMediumWidgetZoomDownPositionSettings");
            safeSwizzle("SBHomeGestureMediumWidgetZoomDownSettings","homeGestureMediumWidgetZoomDownScaleSettings");
            safeSwizzle("SBHomeGestureSmallWidgetZoomDownSettings", "homeGestureSmallWidgetZoomDownLayoutSettings");
            safeSwizzle("SBHomeGestureSmallWidgetZoomDownSettings", "homeGestureSmallWidgetZoomDownPositionSettings");
            safeSwizzle("SBHomeGestureSmallWidgetZoomDownSettings", "homeGestureSmallWidgetZoomDownScaleSettings");
        } @catch (...) {
            // If anything unexpected happens while installing hooks, bail safely.
        }
    }
}
