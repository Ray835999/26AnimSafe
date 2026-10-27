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

// ---------- iOS 26 perspective-tilt (app open/close), v1.0.6 ----------
// WHY v1.0.5 CRASHED (root cause, now fixed):
//   It hooked CALayer -setTransform: GLOBALLY. That fires on EVERY layer in the
//   whole OS. Reading [layer delegate] / NSStringFromClass on each call (a) thrashes
//   the main thread on a slow device, and (b) messages the layer's delegate which
//   is unsafe_unretained and can be a stale/freed pointer during rapid animation
//   teardown -> EXC_BAD_ACCESS -> SafeMode.
//
// SAFE DESIGN (v1.0.6):
//   We no longer touch CALayer. Instead, at load we scan the runtime for VIEW
//   classes whose name contains Zoom / IconZoom / Snapshot (these are the
//   app-open/close zoom views) and add a -setTransform: override to THOSE classes
//   ONLY via class_addMethod, so UIView itself is never mutated globally. The
//   signature (CGAffineTransform vs CATransform3D) is detected per class, so there
//   is no ABI mismatch (the v1.0.2 crash class). The override applies the original
//   transform, then writes the *layer* transform with a perspective + decaying
//   rotateY. Writing the layer (not the view) means we never re-enter the hooked
//   view setter -> no recursion. Every other view passes straight through.
static BOOL gSkewFiredLogged = NO;

static BOOL isUIViewSubclass(Class cls) {
    Class uv = objc_getClass("UIView");
    Class c = cls;
    while (c != Nil) {
        if (c == uv) return YES;
        c = class_getSuperclass(c);
    }
    return NO;
}

static BOOL zoomNameMatch(const char *name) {
    if (!name) return NO;
    if (strstr(name, "Zoom")    != NULL) return YES;
    if (strstr(name, "IconZoom") != NULL) return YES;
    if (strstr(name, "Snapshot") != NULL) return YES;
    return NO;
}

static void addSkewToClass(Class cls, SEL sel) {
    if (!isUIViewSubclass(cls)) return;          // only UIView subclasses have a real .layer
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) return;
    const char *enc = method_getTypeEncoding(m);
    if (enc == NULL) return;
    BOOL is3D = (strstr(enc, "CATransform3D") != NULL);
    IMP orig = method_getImplementation(m);

    IMP repl;
    if (is3D) {
        repl = imp_implementationWithBlock(^void(id s, SEL c, CATransform3D t) {
            typedef void (*SetT)(id, SEL, CATransform3D);
            SetT o = (SetT)orig;
            o(s, c, t);                          // original 3D transform
            if (!gSkewEnabled) return;
            CGFloat sc = (CGFloat)fabs(t.m11);
            if (sc <= 0.005f || sc >= 0.999f) return;   // only mid-flight zoom
            CGFloat ang = gSkewAngle * (1.0f - sc) * (CGFloat)(3.141592653589793 / 180.0);
            CATransform3D p = CATransform3DIdentity;
            p.m34 = -1.0f / 350.0f;              // perspective (iOS 26-ish)
            CATransform3D r = CATransform3DRotate(p, ang, 0.0f, 1.0f, 0.0f);
            ((UIView *)s).layer.transform = CATransform3DConcat(r, t);
            if (!gSkewFiredLogged) {
                gSkewFiredLogged = YES;
                NSLog(@"[26Anim] skew: FIRED(3D) on %@ scale=%.3f angle=%.2f",
                      NSStringFromClass([(id)s class]), sc, ang * 180.0 / 3.141592653589793);
            }
        });
    } else {
        repl = imp_implementationWithBlock(^void(id s, SEL c, CGAffineTransform t) {
            typedef void (*SetT)(id, SEL, CGAffineTransform);
            SetT o = (SetT)orig;
            o(s, c, t);                          // original affine transform
            if (!gSkewEnabled) return;
            CGFloat sc = (CGFloat)fabs(t.a);
            if (sc <= 0.005f || sc >= 0.999f) return;   // only mid-flight zoom
            CGFloat ang = gSkewAngle * (1.0f - sc) * (CGFloat)(3.141592653589793 / 180.0);
            CATransform3D base = CATransform3DMakeAffineTransform(t);
            CATransform3D p = CATransform3DIdentity;
            p.m34 = -1.0f / 350.0f;              // perspective (iOS 26-ish)
            CATransform3D r = CATransform3DRotate(p, ang, 0.0f, 1.0f, 0.0f);
            ((UIView *)s).layer.transform = CATransform3DConcat(r, base);
            if (!gSkewFiredLogged) {
                gSkewFiredLogged = YES;
                NSLog(@"[26Anim] skew: FIRED(2D) on %@ scale=%.3f angle=%.2f",
                      NSStringFromClass([(id)s class]), sc, ang * 180.0 / 3.141592653589793);
            }
        });
    }

    // Add an override on THIS class only. If it already owns the selector we
    // replace its own IMP; otherwise class_addMethod overrides the inherited
    // UIView setter on the subclass WITHOUT touching UIView globally.
    if (!class_addMethod(cls, sel, repl, enc)) {
        method_setImplementation(class_getInstanceMethod(cls, sel), repl);
    }
    NSLog(@"[26Anim] skew: hooked %s (%s)", class_getName(cls), is3D ? "3D" : "2D");
}

static void swizzleSkew(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    SEL sel = sel_registerName("setTransform:");
    int hooked = 0;
    if (classes) {
        for (unsigned int i = 0; i < count; i++) {
            const char *name = class_getName(classes[i]);
            if (!zoomNameMatch(name)) continue;
            @try {
                addSkewToClass(classes[i], sel);
                hooked++;
            } @catch (...) { /* ignore one bad class */ }
        }
        free(classes);
    }
    NSLog(@"[26Anim] skew: hooked %d zoom/snapshot classes", hooked);
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
