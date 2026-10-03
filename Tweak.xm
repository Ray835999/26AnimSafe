// 26AnimSafe — crash-proof reimplementation of the iOS 26 app open/close zoom.
//
// Root cause of the original 26Anim crash (verified by disassembling the deb):
//   it hooks SpringBoard's icon-zoom animation surface (SBHomeGesture*Zoom*Settings,
//   SBIconZoom*Settings, the private meshTransformWithVertexCount:... warp and a
//   CADisplayLink loop driven by dictionaryWithContentsOfFile: config) with NO
//   existence/nil guards, so on iOS 15.8.8 a missing class/method/nil config makes
//   SpringBoard abort -> safe mode on every respring.
//
// This version hooks the SAME surface but is built so it CANNOT crash SpringBoard:
//   * every target class/getter is skipped if absent on the running iOS
//   * every mutation is wrapped in @try/@catch and falls back to the original
//   * the original implementation is ALWAYS callable as the fallback
//   * it only activates on iOS 13..15 and stays out of the way on iOS 16+
//
// It intentionally reuses the original 26Anim preference domain (com.ngkhoi.26anim)
// so the original Settings pane keeps working: "Enable Animations" toggles it, and
// the "Animation Speed" segment ("Original (iOS native)" vs "iOS 26") is honoured.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

// ---------- tunables (read from the 26Anim prefs domain) ----------
static BOOL   gEnabled  = YES;
static double gDuration = 0.42;   // zoom duration (s); <=0 keeps system value
static double gCorner   = 0.0;    // corner radius applied during zoom (pt)
static double gScale    = 1.0;    // extra scale multiplier (1.0 = native)

static NSMutableDictionary<NSString *, NSValue *> *gOrig = nil;

// ---------- preferences ----------
static void loadPrefs(void) {
    @try {
        // rootless path first, then fallback
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
    } @catch (...) { /* ignore */ }
}

// ---------- the safe modifier (called for every hooked getter) ----------
static id modifySettings(id self, SEL _cmd, IMP origImp) {
    // 1) always able to return the original unchanged
    id (*origf)(id, SEL) = (id (*)(id, SEL))origImp;
    if (!gEnabled) return origf(self, _cmd);

    @try {
        id orig = origf(self, _cmd);
        if (orig == nil) return nil;

        // 2) nudge a few well-known, safe-to-set properties via KVC.
        //    KVC throws NSUnknownKeyException when a setter is missing -> swallowed.
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
        // 3) any unexpected failure -> return original, never crash
        return origf(self, _cmd);
    }
}

// ---------- guarded swizzle ----------
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

%ctor {
    @autoreleasepool {
        gOrig = [NSMutableDictionary new];
        loadPrefs();

        // only touch iOS 13..15 (the icon-zoom surface we target).
        // kCFCoreFoundationVersionNumber: iOS13≈1751, iOS15≈2105, iOS16≈2150.
        double v = kCFCoreFoundationVersionNumber;
        if (v < 1750.0) return;     // older than iOS 13
        if (v >= 2150.0) return;    // iOS 16+ already has the native animation

        // Mirror 26Anim's hook surface, each guarded so a missing class/getter is a no-op.
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
    }
}
