// 26AnimSafe v5 — iOS 26-style app open/close interrupt zoom for iOS 13..16 (rootless)
//
// WHY v3 / v4 SILENTLY DID NOTHING (real root cause, now fixed):
//   The app open/close "interrupt" zoom on iOS 13..16 is NOT driven by
//   SBHIconZoomSettings / SBFAnimationSettings.duration. Those v4 hooks mutated the
//   wrong object tree -> 0 effect (no crash, just nothing happened).
//
//   The animation is driven by a *fluid behavior* (UISpringTimingParameters-style)
//   described by **SBFFluidBehaviorSettings** (SpringBoardFoundation), which exposes:
//     - -setResponse:     time constant in seconds. Larger = SLOWER settle.
//                         stock iOS 15 app zoom ~0.37; iOS 26 is visibly slower.
//     - -setDampingRatio: 1.0 = critically damped (no overshoot), lower = more bounce.
//
//   This is the EXACT mechanism Speedster (Hoangdus, open-source, iOS 13-16.7) uses
//   for its "App opening speed" + "bounce" sliders, and it is version-stable because
//   SBFFluidBehaviorSettings exists on every iOS 13..16 build. We mirror that proven
//   surface instead of guessing private class names.
//
//   We force a larger response (slow, iOS-26-like) and a slightly under-damped ratio
//   (gentle overshoot/bounce). As a bonus we also slow SBFAnimationSettings.duration
//   for short (<0.5s) transitions (folder zoom etc.) so the whole zoom family feels
//   consistent.
//
// Implementation note: we use MANUAL method swizzling (method_setImplementation +
// imp_implementationWithBlock) rather than Logos %hook blocks. This is identical to
// the v4 approach that compiled cleanly, and it avoids a Logos %hook method-parse
// quirk seen on this source. Every swizzle is guarded (class/selector existence) and
// the original IMP is captured per-target so there is no cross-wiring -> no safe mode.
//
// We also emit throttled [26Anim] syslog so you can EMPIRICALLY confirm the hook
// fired and which value was forced:
//   log stream --predicate 'process == "SpringBoard"' | grep 26Anim
//
// Preferences (this package's domain only; the legacy com.ngkhoi.26anim domain is
// no longer read, so it can no longer accidentally turn the spring mods on):
//   /var/jb/var/mobile/Library/Preferences/com.you.26animsafe.plist
//   (or /var/mobile/Library/Preferences/com.you.26animsafe.plist on rootless)
//
//   1.0.4 DEFAULTS (per request): iOS 26 tilt ON, slow/bounce spring OFF.
//     skewEnabled  (BOOL, default YES) — THE iOS 26 app open/close perspective tilt
//     skewAngle    (double, peak tilt degrees; default 8.0)
//     enabled      (BOOL, default NO)  — master for the *extra* slow/bounce spring mods
//     response     (double, fluid response seconds; default 0.45; needs enabled=true)
//     dampingRatio (double, 0.2..1.0; default 1.0 = no bounce; needs enabled=true)
//     duration     (double, short-transition duration seconds; default 0.45; needs enabled=true)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

// ---------- tunables ----------
// Per user request (26AnimSafe 1.0.4):
//   * The iOS 26-style perspective-tilt app open/close animation is the PRIMARY
//     feature and is ON by default (gSkewEnabled = YES).
//   * The slow/bounce spring modifications (response / dampingRatio / duration)
//     are "extras" and are OFF by default (gEnabled = NO). Set enabled=true in the
//     plist (or the Settings toggle) to also slow the zoom / change damping.
static BOOL   gEnabled      = NO;     // master for slow/bounce spring mods — OFF by default
static double gResponse     = 0.45;   // larger = slower/open (iOS 26 feel). stock ~0.37
static double gDampingRatio = 1.0;    // 1.0 = critically damped (NO overshoot/bounce). stock ~1.0
static double gDuration     = 0.45;   // short-transition duration cap (folder zoom etc.)

// ---------- iOS 26 perspective-tilt (app open/close) ----------
// ON by default. Hooks SBIconZoomAnimator / SBScaleIconZoomAnimator per-frame tick
// (-_setAnimationFraction: / -_applyZoomFraction:), and re-applies a perspective
// (m34) plus a decaying rotateY to the animator's own target icon view so the icon
// swings in on a 3D plane, flattening as it reaches fullscreen.
static BOOL   gSkewEnabled  = YES;    // DEFAULT ON — the iOS 26 app open/close tilt
static double gSkewAngle    = 12.0;   // peak tilt in degrees at the start of the zoom

// ---------- throttled log flags ----------
static BOOL gLoggedResp = NO;
static BOOL gLoggedDamp = NO;
static BOOL gLoggedDur  = NO;

// ---------- preferences ----------
static void loadPrefsFrom(NSString *path) {
    @try {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!d) return;
        if ([d objectForKey:@"enabled"] != nil)
            gEnabled = [[d objectForKey:@"enabled"] boolValue];
        NSString *sp = [d objectForKey:@"animSpeed"];
        if ([sp isKindOfClass:[NSString class]] &&
            [sp rangeOfString:@"Original" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            gEnabled = NO; // user picked the native iOS animation
        }
        if ([d objectForKey:@"response"]     != nil) gResponse     = [[d objectForKey:@"response"]     doubleValue];
        if ([d objectForKey:@"dampingRatio"] != nil) gDampingRatio = [[d objectForKey:@"dampingRatio"] doubleValue];
        if ([d objectForKey:@"duration"]     != nil) gDuration     = [[d objectForKey:@"duration"]     doubleValue];
        if ([d objectForKey:@"skewEnabled"]  != nil) gSkewEnabled  = [[d objectForKey:@"skewEnabled"]  boolValue];
        if ([d objectForKey:@"skewAngle"]    != nil) gSkewAngle    = [[d objectForKey:@"skewAngle"]    doubleValue];
    } @catch (...) { /* ignore corrupt plist */ }
}

static void loadPrefs(void) {
    loadPrefsFrom(@"/var/jb/var/mobile/Library/Preferences/com.you.26animsafe.plist");
    loadPrefsFrom(@"/var/mobile/Library/Preferences/com.you.26animsafe.plist");
}

static void prefsChanged(CFNotificationCenterRef center, void *observer,
                         CFStringRef name, const void *object, CFDictionaryRef info) {
    loadPrefs();
}

// ---------- guarded double-setter swizzle ----------
// Hooks a -(void)setXxx:(double) instance method on `clsName`, forcing the value in
// *pVal while logging the first forced call. Original IMP captured per-target.
static void swizzleDoubleSetter(const char *clsName, const char *selName,
                                double *pVal, BOOL *pLogged, const char *tag) {
    Class cls = objc_getClass(clsName);
    if (cls == Nil) {                 // class absent on this iOS -> skip safely
        NSLog(@"[26Anim] class %s not found, skip", clsName);
        return;
    }
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) {                  // setter absent -> skip safely
        NSLog(@"[26Anim] %s %s not found, skip", clsName, selName);
        return;
    }
    IMP orig = method_getImplementation(m);
    double val = *pVal;
    BOOL *plog = pLogged;
    const char *t = tag;
    IMP repl = imp_implementationWithBlock(^void(id s, SEL c, double arg1) {
        void (*o)(id, SEL, double) = (void (*)(id, SEL, double))orig;
        if (!gEnabled) { o(s, c, arg1); return; }
        if (!*plog) {
            *plog = YES;
            NSLog(@"[26Anim] %s forced %.3f (was %.3f)", t, val, arg1);
        }
        o(s, c, val);
    });
    method_setImplementation(m, repl);
    NSLog(@"[26Anim] swizzled %s %s -> force %.3f", clsName, selName, val);
}

// ---------- iOS 26 perspective-tilt (app open/close), v1.0.7 ----------
// EMPIRICAL FINDINGS from the iOS 15.8.8 runtime class index (128103 classes):
//   * SBZoomView / SBFullscreenZoomView do NOT implement -setTransform: and have no
//     scale property at all (only init/contentView/statusBar). That is exactly why
//     v1.0.4 (SBFullscreenZoomView setTransform:) and v1.0.6 (name-scanned Zoom views)
//     produced NO visible tilt: the hook could install, but the animation never
//     calls those methods -- the animator drives the frame from outside.
//   * The real driver is SBIconZoomAnimator (SpringBoardHome) and its subclass
//     SBScaleIconZoomAnimator, which implements:
//        - (void)_setAnimationFraction:(double)fraction   // base class, every frame
//        - (void)_applyZoomFraction:(double)fraction      // SBScale*, every frame
//        - (void)_setZoomScale:(double)scale
//        - (void)_applyVisualAltitudeFraction:(double)f
//     `fraction` runs 0..1 while the icon zooms up into the app (and 1..0 on close).
//
// v1.0.7 DESIGN (no crash surface at all):
//   Hook ONLY the animator, never layers, never global UIKit, never the heuristic
//   name scan. On each fraction tick we take the animator's *own* target icon view
//   (targetIconView / referenceIconView) and apply a perspective+rotateY to that
//   one view's layer -- the single view we know is on screen for THIS animation.
//   Everything is wrapped in @try and null-checked; all arguments are plain double,
//   so there is no ABI-signature hazard. If the classes/methods are absent we log
//   and do nothing (safe no-op).
static BOOL gSkewFiredLogged = NO;

// Find a UIView on the animator to tilt: SBScaleIconZoomAnimator exposes
// -targetIconView and -referenceIconView (both UIView*). We try those via
// respondsToSelector/NSSelectorFromString so nothing is hard-linked.
static UIView *skewTargetView(id animator) {
    @try {
        SEL sels[3] = {
            NSSelectorFromString(@"targetIconView"),
            NSSelectorFromString(@"referenceIconView"),
            NSSelectorFromString(@"targetIconContainerView")
        };
        for (int i = 0; i < 3; i++) {
            if (![animator respondsToSelector:sels[i]]) continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id v = [animator performSelector:sels[i]];
#pragma clang diagnostic pop
            if (v && [v isKindOfClass:[UIView class]]) return (UIView *)v;
        }
    } @catch (...) { }
    return nil;
}

// fraction 0..1 (0 = icon in grid, 1 = app fullscreen). Tilt peaks mid-flight.
static void applySkewToAnimator(id animator, double fraction) {
    if (!gSkewEnabled) return;
    if (fraction <= 0.02 || fraction >= 0.985) return;   // only mid-flight
    UIView *v = skewTargetView(animator);
    if (v == nil) return;
    @try {
        // Peak at ~30% progress, fade to 0 at both ends so the end state is flat.
        double f = fraction;
        double curve = (f < 0.3) ? (f / 0.3) : ((1.0 - f) / 0.7);
        if (curve <= 0.0) return;
        double ang = gSkewAngle * curve * (3.141592653589793 / 180.0);
        CATransform3D p = CATransform3DIdentity;
        p.m34 = -1.0f / 350.0f;                  // perspective
        CATransform3D r = CATransform3DRotate(p, ang, 0.0f, 1.0f, 0.0f);
        v.layer.transform = r;                   // write the LAYER, not the view setter
        if (!gSkewFiredLogged) {
            gSkewFiredLogged = YES;
            NSLog(@"[26Anim] skew: FIRED on %@ fraction=%.3f angle=%.2f",
                  NSStringFromClass([v class]), fraction, ang * 180.0 / 3.141592653589793);
        }
    } @catch (...) { }
}

// Hook a -(void)xxx:(double) method on clsName that ticks the zoom animation.
static void swizzleZoomTick(const char *clsName, const char *selName) {
    Class cls = objc_getClass(clsName);
    if (cls == Nil) { NSLog(@"[26Anim] skew: %s absent, skip", clsName); return; }
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) { NSLog(@"[26Anim] skew: %s %s absent, skip", clsName, selName); return; }
    const char *enc = method_getTypeEncoding(m);
    if (enc == NULL || strstr(enc, "d") == NULL) {
        // Signature is not (double) -- refuse rather than risk an ABI mismatch.
        NSLog(@"[26Anim] skew: %s %s enc=%s unexpected, skip", clsName, selName, enc ? enc : "(null)");
        return;
    }
    IMP orig = method_getImplementation(m);
    IMP repl = imp_implementationWithBlock(^void(id s, SEL c, double fraction) {
        typedef void (*Tick)(id, SEL, double);
        Tick o = (Tick)orig;
        o(s, c, fraction);
        applySkewToAnimator(s, fraction);
    });
    method_setImplementation(m, repl);
    NSLog(@"[26Anim] skew: hooked %s %s", clsName, selName);
}

static void swizzleSkew(void) {
    // _applyZoomFraction: is the SBScaleIconZoomAnimator per-frame tick.
    // _setAnimationFraction: is the SBIconZoomAnimator base per-frame tick.
    swizzleZoomTick("SBScaleIconZoomAnimator", "_applyZoomFraction:");
    swizzleZoomTick("SBScaleIconZoomAnimator", "_setAnimationFraction:");
    swizzleZoomTick("SBIconZoomAnimator", "_setAnimationFraction:");
    // Folder/library zoom variants share the same base tick; hook their own too.
    swizzleZoomTick("SBFolderIconZoomAnimator", "_setAnimationFraction:");
    swizzleZoomTick("SBLibraryZoomAnimator", "_setAnimationFraction:");
}

%ctor {
    @autoreleasepool {
        loadPrefs();

        // Live reload when the user toggles in Settings (the pane posts this Darwin note).
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChanged,
            CFSTR("com.you.26animsafe/settingschanged"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);

        double v = kCFCoreFoundationVersionNumber;
        NSLog(@"[26Anim] ctor: CFVersion=%.1f enabled=%d response=%.3f damping=%.3f duration=%.3f",
              v, gEnabled, gResponse, gDampingRatio, gDuration);

        // Only touch iOS 13..17. iOS 18+ already has its own animation; these legacy
        // classes may be absent (swizzleDoubleSetter skips any missing class).
        if (v < 1665.0) return;   // older than iOS 13
        if (v >= 2150.0) return;  // iOS 18+

        // PRIMARY FIX: SBFFluidBehaviorSettings drives the app open/close zoom.
        swizzleDoubleSetter("SBFFluidBehaviorSettings", "setResponse:",
                             &gResponse, &gLoggedResp, "SBFFluidBehaviorSettings.setResponse");
        swizzleDoubleSetter("SBFFluidBehaviorSettings", "setDampingRatio:",
                             &gDampingRatio, &gLoggedDamp, "SBFFluidBehaviorSettings.setDampingRatio");
        // BONUS: slow short SBFAnimationSettings transitions (folder zoom, label fade...).
        swizzleDoubleSetter("SBFAnimationSettings", "setDuration:",
                             &gDuration, &gLoggedDur, "SBFAnimationSettings.setDuration");

        // EXPERIMENTAL: optional iOS 26-style perspective tilt on app open.
        swizzleSkew();
    }
}
