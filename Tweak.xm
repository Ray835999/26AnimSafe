// 26AnimSafe — crash-proof reimplementation of the iOS 26-style app open/close zoom,
// ported to the REAL animation surface that exists on iOS 13..15.
//
// ============================================================================
// ROOT-CAUSE OF THE "v3 installed but did nothing" BUG (now fixed):
// ============================================================================
// The duration / scale / cornerRadius do NOT live on SBHIconZoomSettings. The real
// class hierarchy (verified against the iOS 13/14/15 SpringBoardHome headers) is:
//
//   PTSettings
//    └─ SBHIconAnimationSettings        (has centralAnimationSettings : SBFAnimationSettings*)
//        └─ SBHIconZoomSettings         (only labelAlphaWithZoom)
//            ├─ SBHScaleZoomSettings     (crossfadeSettings / iconGridFadeSettings / outerFolderFadeSettings : SBFAnimationSettings*)
//            │   ├─ SBHCrossfadeZoomSettings (morphSettings : SBFAnimationSettings*)
//            │   └─ SBHFolderZoomSettings    (innerFolderFadeSettings : SBFAnimationSettings*)
//            └─ SBHCenterZoomSettings
//                └─ SBHCenterAppZoomSettings (appZoomSettings / appFadeSettings : SBFAnimationSettings*)
//
// The actual timing lives on SBFAnimationSettings (it has `duration`, `delay`, `curve`,
// `damping`, `stiffness`, `mass`, `speed`). SBFAnimationSettings is reached through
// DIFFERENT sub-objects depending on the settings subclass:
//   * SBHScaleZoomSettings        -> centralAnimationSettings.duration        (plain icon zoom)
//   * SBHCenterAppZoomSettings    -> appZoomSettings.duration + appFadeSettings.duration  (APP OPEN/CLOSE)
//   * SBHCrossfadeZoomSettings    -> morphSettings.duration
//   * SBHFolderZoomSettings       -> innerFolderFadeSettings.duration (+ central)
//
// v3 set `duration` via KVC directly on the SBHIconZoomSettings/SBHScaleZoomSettings
// object, where NO such property exists -> NSUnknownKeyException -> swallowed by
// @try/@catch -> 100% silent no-op (no crash, no effect). That is exactly what you saw.
//
// FIX: swizzle `-settings` on every concrete *IconZoomAnimator (each overrides `-settings`
// and returns a subclass-typed settings object), then generically walk EVERY candidate
// SBFAnimationSettings sub-object and set `duration`. We also emit ONE throttled syslog
// line per launch so you can EMPIRICALLY verify the hook fired and which keys were set:
//   log stream --predicate 'process == "SpringBoard"' | grep 26Anim
//
// All class/method lookups are runtime-only (NSString selectors), so it compiles against
// the public SDK and simply skips anything missing at runtime. Every mutation is guarded
// so SpringBoard can never abort -> no safe mode, ever.
//
// ============================================================================
// Preferences (read from BOTH the legacy 26Anim domain and this package's domain):
//   /var/jb/var/mobile/Library/Preferences/com.ngkhoi.26anim.plist
//   /var/jb/var/mobile/Library/Preferences/com.you.26animsafe.plist
//     enabled   (BOOL, default YES)
//     animSpeed ("Original..." disables the tweak; anything else -> enabled)
//     duration  (double seconds; the zoom duration. default 0.6)
//     delay     (double seconds; >=0 overrides the zoom delay; default -1 = keep system)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

// ---------- tunables (read from the prefs domains above) ----------
static BOOL   gEnabled  = YES;
static double gDuration = 0.6;    // zoom duration (s); stock iOS 15 ~0.3-0.4 -> clearly longer/smoother
static double gDelay    = -1.0;   // zoom delay (s); <0 keeps system value

// ---------- preferences ----------
static void loadPrefsFrom(NSString *path, BOOL *didRead) {
    @try {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!d) return;
        *didRead = YES;
        if ([d objectForKey:@"enabled"] != nil)
            gEnabled = [[d objectForKey:@"enabled"] boolValue];
        NSString *sp = [d objectForKey:@"animSpeed"];
        if ([sp isKindOfClass:[NSString class]] &&
            [sp rangeOfString:@"Original" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            gEnabled = NO; // user picked the native iOS animation
        }
        if ([d objectForKey:@"duration"] != nil) gDuration = [[d objectForKey:@"duration"] doubleValue];
        if ([d objectForKey:@"delay"]    != nil) gDelay    = [[d objectForKey:@"delay"]    doubleValue];
    } @catch (...) { /* ignore */ }
}

static void loadPrefs(void) {
    BOOL read = NO;
    loadPrefsFrom(@"/var/jb/var/mobile/Library/Preferences/com.ngkhoi.26anim.plist", &read);
    loadPrefsFrom(@"/var/mobile/Library/Preferences/com.ngkhoi.26anim.plist", &read);
    loadPrefsFrom(@"/var/jb/var/mobile/Library/Preferences/com.you.26animsafe.plist", &read);
    loadPrefsFrom(@"/var/mobile/Library/Preferences/com.you.26animsafe.plist", &read);
    if (!read) { /* no plist yet -> use defaults already set above */ }
}

static void prefsChanged(CFNotificationCenterRef center, void *observer,
                         CFStringRef name, const void *object, CFDictionaryRef info) {
    loadPrefs();
}

// ---------- candidate SBFAnimationSettings sub-objects on the various zoom settings classes ----------
// We try each; if present and KVC-settable, we set duration (+ optional delay). Missing
// ones are silently skipped. This generically covers every settings subclass above.
static NSArray<NSString *> *durationKeys(void) {
    return @[@"centralAnimationSettings",
             @"appZoomSettings",
             @"appFadeSettings",
             @"crossfadeSettings",
             @"iconGridFadeSettings",
             @"outerFolderFadeSettings",
             @"innerFolderFadeSettings",
             @"morphSettings"];
}

// Walk every candidate sub-object and set duration. Logs ONCE per launch (throttled) so
// the user can confirm empirically that the hook fired and which keys were mutated.
static void applyDurationToSettings(id settings, id animator) {
    if (!settings) return;
    NSMutableArray *hit = [NSMutableArray array];
    for (NSString *key in durationKeys()) {
        @try {
            id sub = [settings valueForKey:key];
            if (sub && [sub respondsToSelector:@selector(setDuration:)]) {
                [sub setValue:@(gDuration) forKey:@"duration"];
                if (gDelay >= 0.0 && [sub respondsToSelector:@selector(setDelay:)])
                    [sub setValue:@(gDelay) forKey:@"delay"];
                [hit addObject:key];
            }
        } @catch (...) { /* unknown key -> skip */ }
    }
    static BOOL gDidLog = NO;
    if (!gDidLog) {
        gDidLog = YES;
        NSLog(@"[26Anim] applied duration=%.2f delay=%.2f -> animator=<%@> settings=<%@> mutatedKeys=%@",
              gDuration, gDelay, NSStringFromClass([animator class]),
              NSStringFromClass([settings class]), hit);
    }
}

// ---------- the safe modifier for OBJECT-returning getters (animator -settings) ----------
static id modifySettings(id self, SEL _cmd, IMP origImp) {
    id (*origf)(id, SEL) = (id (*)(id, SEL))origImp;
    id orig = origf(self, _cmd);          // original settings object
    if (!gEnabled) return orig;
    @try {
        if (orig) applyDurationToSettings(orig, self);
    } @catch (...) { /* never re-invoke original from inside catch */ }
    return orig;
}

// ---------- guarded object-getter swizzle ----------
// Captures the ORIGINAL IMP directly inside the block (per class+sel). NEVER key originals
// through a shared dictionary by selector name: several animator classes share -settings,
// and cross-wiring their originals made SpringBoard call the wrong class's IMP -> crash loop
// (the v1.0.0-2 bug). Per-block capture eliminates that entirely.
static void safeSwizzle(const char *clsName, const char *selName) {
    Class cls = objc_getClass(clsName);
    if (cls == Nil) return;                       // class absent on this iOS -> skip
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) return;                        // getter absent -> skip
    IMP orig = method_getImplementation(m);
    IMP repl = imp_implementationWithBlock(^id(id s, SEL c) {
        return modifySettings(s, c, orig);
    });
    method_setImplementation(m, repl);
}

%ctor {
    @autoreleasepool {
        loadPrefs();

        // Live reload when the user toggles in Settings (the pane posts this Darwin note).
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChanged,
            CFSTR("com.ngkhoi.26anim/settingschanged"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChanged,
            CFSTR("com.you.26animsafe/settingschanged"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);

        double v = kCFCoreFoundationVersionNumber;
        NSLog(@"[26Anim] ctor: CFVersion=%.1f enabled=%d duration=%.2f delay=%.2f",
              v, gEnabled, gDuration, gDelay);

        // Only touch iOS 13..17. iOS 18+ already has its own animation and these legacy
        // classes may be absent (safeSwizzle also skips any missing class below).
        if (v < 1665.0) return;     // older than iOS 13
        if (v >= 2150.0) return;    // iOS 18+

        @try {
            // Hook -settings on EVERY concrete icon-zoom animator. Each overrides -settings
            // and returns a subclass-typed settings object that carries SBFAnimationSettings
            // sub-objects holding the real `duration`. Swizzling -settings (not the base
            // class) is required because the subclasses redeclare `settings` with their own
            // type, so the base-class Method would NOT be the one the subclass dispatches to.
            safeSwizzle("SBIconZoomAnimator",            "settings"); // base (covers any non-overriding subclass)
            safeSwizzle("SBScaleIconZoomAnimator",       "settings"); // plain icon zoom (open/close)
            safeSwizzle("SBCrossfadeIconZoomAnimator",    "settings"); // icon->app crossfade zoom
            safeSwizzle("SBFolderIconZoomAnimator",       "settings"); // folder zoom
            safeSwizzle("SBHCenterIconZoomAnimator",      "settings"); // center / app-from-grid zoom
            safeSwizzle("SBCenterAppIconZoomAnimator",    "settings"); // APP OPEN/CLOSE (SpringBoard.framework)
        } @catch (...) {
            // If anything unexpected happens while installing hooks, bail safely (no safe mode).
        }
    }
}
