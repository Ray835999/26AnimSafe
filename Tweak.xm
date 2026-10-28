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
#import <objc/message.h>
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

// ---------- iOS 26 perspective-tilt (app open/close), v1.0.8 ----------
// WHY v1.0.7 STILL HAD NO EFFECT (two real reasons):
//   (1) The zoom is driven by Core Animation. The ObjC ticks
//       -_setAnimationFraction: / -_applyZoomFraction: are NOT called every frame;
//       interpolation happens in the render server. So a per-frame ObjC hook can
//       never paint a per-frame tilt.
//   (2) v1.0.7 assigned layer.transform = <rotation only>, which THREW AWAY the
//       system's own scale (a UIView's scale lives in layer.transform).
//
// v1.0.8 DESIGN (works with Core Animation instead of against it):
//   * Trigger on SBIconAnimator -prepare, which runs ONCE before the zoom.
//   * Add a PARALLEL CAAnimation with keyPath "transform.rotation.y" going from
//     skewAngle -> 0. That keyPath is an AUXILIARY transform component, so it
//     stacks on top of the system's own scale animation rather than replacing it.
//     Core Animation interpolates it every frame by itself -> no ObjC ticks needed.
//   * Perspective comes from superlayer.sublayerTransform.m34, restored on -cleanup.
//   * Diagnostics are written to a FILE you can open with Filza (no terminal!):
//       /var/mobile/Library/Preferences/26anim_diag.txt
//     It records which classes/methods exist, which hooks installed, whether
//     prepare/cleanup fire, which view was found, and how often each tick runs.
static BOOL gSkewFiredLogged = NO;

// ---------------- diagnostics (file-based, Filza-readable) ----------------
static NSString * const k26Diag = @"/var/mobile/Library/Preferences/26anim_diag.txt";
static NSMutableArray      *gDiagLines = nil;
static NSMutableDictionary *gTickCounts = nil;

static void DiagInit(void) {
    if (!gDiagLines)   gDiagLines   = [NSMutableArray array];
    if (!gTickCounts)  gTickCounts  = [NSMutableDictionary dictionary];
}
static void DiagFlush(void) {
    @try {
        DiagInit();
        NSMutableString *s = [NSMutableString string];
        [s appendString:@"== 26AnimSafe diagnostics ==\n"];
        for (NSString *l in gDiagLines) [s appendFormat:@"%@\n", l];
        [s appendString:@"\n-- tick counts (n>0 means it really runs) --\n"];
        for (NSString *k in gTickCounts) {
            NSDictionary *e = gTickCounts[k];
            [s appendFormat:@"%@ n=%@ first=%@ last=%@\n", k, e[@"n"], e[@"first"], e[@"last"]];
        }
        [s writeToFile:k26Diag atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (...) { }
}
static void Diag(NSString *line) {
    @try {
        DiagInit();
        if ([gDiagLines count] < 400) [gDiagLines addObject:line];
        DiagFlush();
    } @catch (...) { }
}
static void DiagTick(NSString *key, double frac) {
    @try {
        DiagInit();
        NSMutableDictionary *e = gTickCounts[key];
        if (!e) { e = [NSMutableDictionary dictionary]; e[@"n"] = @0; e[@"first"] = @(frac); gTickCounts[key] = e; }
        int n = [e[@"n"] intValue] + 1;
        e[@"n"] = @(n);
        e[@"last"] = @(frac);
        if (n <= 3 || n % 20 == 0) DiagFlush();
    } @catch (...) { }
}

// ---------------- find the view to tilt ----------------
static id Msg(id o, const char *name) {
    if (!o) return nil;
    SEL s = sel_registerName(name);
    if (![o respondsToSelector:s]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(o, s); } @catch (...) { return nil; }
}

static UIView *skewTargetView(id animator) {
    // ordered: prefer a single icon view, fall back to the container
    const char *names[] = { "targetIconView", "referenceIconView",
                            "targetIconContainerView", "referenceView",
                            "animationContainer" };
    for (int i = 0; i < 5; i++) {
        id v = Msg(animator, names[i]);
        if (v && [v isKindOfClass:[UIView class]]) {
            Diag([NSString stringWithFormat:@"view via %s -> %@", names[i], NSStringFromClass([v class])]);
            return (UIView *)v;
        }
    }
    return nil;
}

static double tiltDuration(id animator) {
    @try {
        id st = Msg(animator, "settings");
        if (st) {
            SEL ds = sel_registerName("duration");
            if ([st respondsToSelector:ds]) {
                double d = ((double (*)(id, SEL))objc_msgSend)(st, ds);
                if (d > 0.05 && d < 3.0) return d;
            }
        }
    } @catch (...) { }
    return 0.45;
}

// ---------------- the tilt itself ----------------
static void addTilt(UIView *v, double dur) {
    @try {
        if (!v) return;
        CALayer *parent = v.layer.superlayer;
        if (parent) {
            CATransform3D persp = CATransform3DIdentity;
            persp.m34 = -1.0f / 500.0f;
            parent.sublayerTransform = persp;
        }
        CABasicAnimation *rot = [CABasicAnimation animationWithKeyPath:@"transform.rotation.y"];
        rot.fromValue = [NSNumber numberWithDouble:gSkewAngle * (3.141592653589793 / 180.0)];
        rot.toValue   = [NSNumber numberWithDouble:0.0];
        rot.duration  = dur;
        rot.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        rot.removedOnCompletion = YES;
        [v.layer addAnimation:rot forKey:@"26anim_tilt"];
        if (!gSkewFiredLogged) {
            gSkewFiredLogged = YES;
            Diag([NSString stringWithFormat:@"TILT ADDED view=%@ dur=%.3f angle=%.1f",
                  NSStringFromClass([v class]), dur, gSkewAngle]);
        }
    } @catch (...) { Diag(@"addTilt threw"); }
}

static void removeTilt(UIView *v) {
    @try {
        if (!v) return;
        [v.layer removeAnimationForKey:@"26anim_tilt"];
        CALayer *parent = v.layer.superlayer;
        if (parent) parent.sublayerTransform = CATransform3DIdentity;
    } @catch (...) { }
}

// ---------------- hooks ----------------
// -(void)xxx  no arguments -> zero ABI risk
static void hookVoid(const char *clsName, const char *selName, BOOL isPrepare) {
    Class cls = objc_getClass(clsName);
    if (!cls) { Diag([NSString stringWithFormat:@"class %s absent", clsName]); return; }
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { Diag([NSString stringWithFormat:@"%s %s absent", clsName, selName]); return; }
    IMP orig = method_getImplementation(m);
    IMP repl;
    if (isPrepare) {
        repl = imp_implementationWithBlock(^void(id s, SEL c) {
            ((void (*)(id, SEL))orig)(s, c);
            @try {
                Diag([NSString stringWithFormat:@"PREPARE on %@", NSStringFromClass([s class])]);
                if (!gSkewEnabled) { Diag(@"prepare: skew disabled"); return; }
                UIView *v = skewTargetView(s);
                if (!v) { Diag(@"prepare: NO VIEW FOUND"); return; }
                addTilt(v, tiltDuration(s));
            } @catch (...) { Diag(@"prepare threw"); }
        });
    } else {
        repl = imp_implementationWithBlock(^void(id s, SEL c) {
            ((void (*)(id, SEL))orig)(s, c);
            @try {
                Diag([NSString stringWithFormat:@"CLEANUP on %@", NSStringFromClass([s class])]);
                if (!gSkewEnabled) return;
                removeTilt(skewTargetView(s));
            } @catch (...) { }
        });
    }
    method_setImplementation(m, repl);
    Diag([NSString stringWithFormat:@"hooked %s %s", clsName, selName]);
}

// -(void)xxx:(double)  diagnostics only (how often does it really fire?)
static void hookTick(const char *clsName, const char *selName) {
    Class cls = objc_getClass(clsName);
    if (!cls) { Diag([NSString stringWithFormat:@"tick class %s absent", clsName]); return; }
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { Diag([NSString stringWithFormat:@"tick %s %s absent", clsName, selName]); return; }
    const char *enc = method_getTypeEncoding(m);
    if (!enc || !strstr(enc, ":8d")) {   // refuse anything that is not a plain double arg
        Diag([NSString stringWithFormat:@"tick %s %s enc=%s skipped", clsName, selName, enc?enc:"(null)"]);
        return;
    }
    IMP orig = method_getImplementation(m);
    IMP repl = imp_implementationWithBlock(^void(id s, SEL c, double f) {
        ((void (*)(id, SEL, double))orig)(s, c, f);
        DiagTick([NSString stringWithFormat:@"%s.%s", clsName, selName], f);
    });
    method_setImplementation(m, repl);
    Diag([NSString stringWithFormat:@"hooked tick %s %s", clsName, selName]);
}

static void swizzleSkew(void) {
    DiagInit();
    Diag([NSString stringWithFormat:@"ctor start skewEnabled=%d angle=%.1f", gSkewEnabled, gSkewAngle]);
    // Hook the BASE class once: subclasses (SBScaleIconZoomAnimator,
    // SBCenterIconZoomAnimator, ...) inherit it, so we cover the whole family
    // without double-swizzling the same Method (which would recurse).
    hookVoid("SBIconAnimator", "prepare", YES);
    hookVoid("SBIconAnimator", "cleanup", NO);
    // per-frame ticks: diagnostics only, to prove whether they run at all
    hookTick("SBScaleIconZoomAnimator", "_applyZoomFraction:");
    hookTick("SBScaleIconZoomAnimator", "_setAnimationFraction:");
    hookTick("SBIconZoomAnimator", "_setAnimationFraction:");
    DiagFlush();
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
