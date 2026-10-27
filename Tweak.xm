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
// ON by default. Hooks SBFullscreenZoomView -setTransform: and, while the app-open
// (and close) zoom is mid-flight (scale < 1.0), re-applies the transform with a
// perspective (m34) plus a decaying rotateY so the icon swings in on a 3D plane,
// fading to flat as it reaches fullscreen (no lingering tilt). If your device's
// app-open path does NOT use SBFullscreenZoomView, this is a safe no-op.
static BOOL   gSkewEnabled  = YES;    // DEFAULT ON — the iOS 26 app open/close tilt
static double gSkewAngle    = 8.0;    // peak tilt in degrees at the start of the zoom

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

// ---------- experimental skew swizzle (type-safe) ----------
// ROOT CAUSE OF v1.0.2 SAFE MODE:
//   SBFullscreenZoomView may declare -setTransform: with EITHER a CGAffineTransform
//   (the stock UIView affine setter) OR a CATransform3D (a 3D override). v1.0.2
//   assumed the affine signature unconditionally. On iOS 15.8.8 the class uses the
//   3D signature, so the C block read the wrong registers -> ABI mismatch ->
//   crash -> SafeMode.
//
// FIX:
//   (1) Only hook if the method is OWNED by SBFullscreenZoomView (never inherit and
//       globally mutate UIView's setTransform:).
//   (2) Inspect method_getTypeEncoding and install a repl whose block argument type
//       matches the real signature (CGAffineTransform vs CATransform3D). The wrong
//       type can therefore never be installed -> no ABI crash.
//   Pure no-op when gSkewEnabled = NO, so it still cannot by itself cause SafeMode.
static BOOL classOwnsSelector(Class cls, SEL sel) {
    if (cls == Nil) return NO;
    unsigned n = 0;
    Method *list = class_copyMethodList(cls, &n);
    BOOL found = NO;
    for (unsigned i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { found = YES; break; }
    }
    if (list) free(list);
    return found;
}

static void swizzleSkew(void) {
    Class cls = objc_getClass("SBFullscreenZoomView");
    if (cls == Nil) {
        NSLog(@"[26Anim] skew: SBFullscreenZoomView not found, skip");
        return;
    }
    SEL sel = sel_registerName("setTransform:");
    if (!classOwnsSelector(cls, sel)) {
        // setTransform: is inherited from UIView; do NOT globally mutate UIView.
        NSLog(@"[26Anim] skew: setTransform: not owned by SBFullscreenZoomView, skip (safe)");
        return;
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) {
        NSLog(@"[26Anim] skew: setTransform: null, skip");
        return;
    }
    const char *enc = method_getTypeEncoding(m);
    BOOL is3D = NO;
    if (enc) {
        NSString *e = [NSString stringWithUTF8String:enc];
        is3D = [e containsString:@"CATransform3D"];
    }
    IMP orig = method_getImplementation(m);
    IMP repl;
    if (is3D) {
        repl = imp_implementationWithBlock(^void(id s, SEL c, CATransform3D t) {
            typedef void (*SetT)(id, SEL, CATransform3D);
            SetT o = (SetT)orig;
            o(s, c, t);                        // original 3D transform applied first
            if (!gSkewEnabled) return;
            CGFloat sc = (CGFloat)fabs(t.m11);
            if (sc <= 0.001f || sc >= 1.0f) return;   // only mid-flight zoom
            CGFloat ang = gSkewAngle * (1.0f - sc) * (CGFloat)(3.141592653589793 / 180.0);
            CATransform3D p = CATransform3DIdentity;
            p.m34 = -1.0f / 700.0f;            // perspective (near-bigger)
            CATransform3D r = CATransform3DRotate(p, ang, 0.0f, 1.0f, 0.0f);
            ((UIView *)s).layer.transform = CATransform3DConcat(r, t);
        });
        NSLog(@"[26Anim] skew: swizzled setTransform: (CATransform3D)");
    } else {
        repl = imp_implementationWithBlock(^void(id s, SEL c, CGAffineTransform t) {
            typedef void (*SetT)(id, SEL, CGAffineTransform);
            SetT o = (SetT)orig;
            o(s, c, t);                        // original affine transform applied first
            if (!gSkewEnabled) return;
            CGFloat sc = (CGFloat)fabs(t.a);
            if (sc <= 0.001f || sc >= 1.0f) return;   // only mid-flight zoom
            CGFloat ang = gSkewAngle * (1.0f - sc) * (CGFloat)(3.141592653589793 / 180.0);
            CATransform3D base = CATransform3DMakeAffineTransform(t);
            CATransform3D p = CATransform3DIdentity;
            p.m34 = -1.0f / 700.0f;            // perspective (near-bigger)
            CATransform3D r = CATransform3DRotate(p, ang, 0.0f, 1.0f, 0.0f);
            ((UIView *)s).layer.transform = CATransform3DConcat(r, base);
        });
        NSLog(@"[26Anim] skew: swizzled setTransform: (CGAffineTransform)");
    }
    method_setImplementation(m, repl);
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
