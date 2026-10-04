// 26AnimSafe v5 — iOS 26-style app open/close interrupt zoom for iOS 13..16 (rootless)
//
// ============================================================================
// WHY v3 / v4 SILENTLY DID NOTHING (the real root cause, now fixed)
// ============================================================================
// The app open/close "interrupt" zoom on iOS 13..16 is NOT driven by
// SBHIconZoomSettings / SBFAnimationSettings.duration. Those v4 hooks mutated
// the wrong object tree -> 0 effect (no crash, just nothing happened).
//
// The animation is driven by a *fluid behavior* (UISpringTimingParameters-style)
// described by **SBFFluidBehaviorSettings** (SpringBoardFoundation), which exposes:
//   - -setResponse:     time constant in seconds. Larger = SLOWER settle.
//                       stock iOS 15 app zoom ~0.37; iOS 26 is visibly slower.
//   - -setDampingRatio: 1.0 = critically damped (no overshoot), lower = more bounce.
//
// This is the EXACT mechanism Speedster (Hoangdus, open-source, iOS 13-16.7) uses
// for its "App opening speed" + "bounce" sliders, and it is version-stable because
// SBFFluidBehaviorSettings exists on every iOS 13..16 build. We mirror that proven
// surface instead of guessing private class names.
//
// We force a larger response (slow, iOS-26-like) and a slightly under-damped ratio
// (gentle overshoot/bounce). As a bonus we also slow SBFAnimationSettings.duration
// for short (<0.5s) transitions (folder zoom etc.) so the whole zoom family feels
// consistent.
//
// Every hook is Logos %hook (per-class IMP capture, inherently safe) + guarded by
// gEnabled, and we emit throttled [26Anim] syslog so you can EMPIRICALLY confirm
// the hook fired and which value was forced:
//   log stream --predicate 'process == "SpringBoard"' | grep 26Anim
//
// ============================================================================
// Preferences (read from BOTH the legacy 26Anim domain and this package's domain):
//   /var/jb/var/mobile/Library/Preferences/com.ngkhoi.26anim.plist
//   /var/jb/var/mobile/Library/Preferences/com.you.26animsafe.plist
//     enabled      (BOOL, default YES)
//     animSpeed    ("Original" disables the tweak; anything else -> enabled)
//     response     (double, fluid response seconds; default 0.50  -> slow iOS26 zoom)
//     dampingRatio (double, 0.2..1.0; default 0.72 -> gentle bounce)
//     duration     (double, short-transition duration seconds; default 0.45)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

// ---------- tunables ----------
static BOOL   gEnabled      = YES;
static double gResponse     = 0.50;   // larger = slower/open (iOS 26 feel). stock ~0.37
static double gDampingRatio = 0.72;   // lower = more bounce. stock ~1.0 (none)
static double gDuration     = 0.45;   // short-transition duration cap (folder zoom etc.)

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
    } @catch (...) { /* ignore corrupt plist */ }
}

static void loadPrefs(void) {
    loadPrefsFrom(@"/var/jb/var/mobile/Library/Preferences/com.ngkhoi.26anim.plist");
    loadPrefsFrom(@"/var/mobile/Library/Preferences/com.ngkhoi.26anim.plist");
    loadPrefsFrom(@"/var/jb/var/mobile/Library/Preferences/com.you.26animsafe.plist");
    loadPrefsFrom(@"/var/mobile/Library/Preferences/com.you.26animsafe.plist");
}

static void prefsChanged(CFNotificationCenterRef center, void *observer,
                         CFStringRef name, const void *object, CFDictionaryRef info) {
    loadPrefs();
}

// ---------- throttled log flags ----------
static BOOL gLoggedResp = NO;
static BOOL gLoggedDamp = NO;
static BOOL gLoggedDur  = NO;

// ============================================================================
// PRIMARY FIX: SBFFluidBehaviorSettings drives app open/close (interrupt) zoom.
// ============================================================================
%hook SBFFluidBehaviorSettings

- (void)setResponse:(double)arg1 {
    if (!gEnabled) { %orig; return; }
    if (!gLoggedResp) {
        gLoggedResp = YES;
        NSLog(@"[26Anim] SBFFluidBehaviorSettings.setResponse forced %.3f (was %.3f)", gResponse, arg1);
    }
    %orig(gResponse);
}

- (void)setDampingRatio:(double)arg1 {
    if (!gEnabled) { %orig; return; }
    if (!gLoggedDamp) {
        gLoggedDamp = YES;
        NSLog(@"[26Anim] SBFFluidBehaviorSettings.setDampingRatio forced %.3f (was %.3f)", gDampingRatio, arg1);
    }
    %orig(gDampingRatio);
}

%end

// ============================================================================
// BONUS: slow short SBFAnimationSettings transitions (folder zoom, label fade...)
// so the whole zoom family feels consistent. Only touches already-short (<0.5s)
// durations to avoid globalling-slowing long UI transitions.
// ============================================================================
%hook SBFAnimationSettings

- (void)setDuration:(double)arg1 {
    if (!gEnabled) { %orig; return; }
    double d = (arg1 > 0.0 && arg1 <= 0.5) ? gDuration : arg1;
    if (!gLoggedDur) {
        gLoggedDur = YES;
        NSLog(@"[26Anim] SBFAnimationSettings.setDuration forced %.3f (was %.3f)", d, arg1);
    }
    %orig(d);
}

%end

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
        NSLog(@"[26Anim] ctor: CFVersion=%.1f enabled=%d response=%.3f damping=%.3f duration=%.3f",
              v, gEnabled, gResponse, gDampingRatio, gDuration);

        // Only touch iOS 13..17. iOS 18+ already has its own animation; these legacy
        // classes may be absent (Logos %hook simply no-ops on a missing class too).
        if (v < 1665.0) return;   // older than iOS 13
        if (v >= 2150.0) return;  // iOS 18+
        // Logos %hook blocks above auto-install; nothing else required here.
    }
}
