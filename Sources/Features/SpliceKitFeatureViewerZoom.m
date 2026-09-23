//
//  SpliceKitFeatureViewerZoom.m
//  SpliceKit - Trackpad pinch-to-zoom on the Viewer (FFPlayerView swizzles) and
//  the viewer.getZoom / viewer.setZoom handlers.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Viewer Pinch-to-Zoom

// Injects magnifyWithEvent: into FFPlayerView so trackpad pinch gestures zoom the viewer.
// Gated by NSUserDefaults key "SpliceKitViewerPinchZoom".

static NSString * const kSpliceKitViewerPinchZoom = @"SpliceKitViewerPinchZoom";
static BOOL sViewerPinchZoomInstalled = NO;

// The injected magnifyWithEvent: handler for FFPlayerView
static void SpliceKit_FFPlayerView_magnifyWithEvent(id self, SEL _cmd, NSEvent *event) {
    // Get playerVideoModule from the view
    SEL pvmSel = NSSelectorFromString(@"playerVideoModule");
    if (![self respondsToSelector:pvmSel]) return;
    id videoModule = ((id (*)(id, SEL))objc_msgSend)(self, pvmSel);
    if (!videoModule) return;

    // Read current zoom factor
    SEL zfSel = NSSelectorFromString(@"zoomFactor");
    if (![videoModule respondsToSelector:zfSel]) return;
    float currentZoom = ((float (*)(id, SEL))objc_msgSend)(videoModule, zfSel);

    // If zoom is 0 (Fit mode), read the reported zoom to get the actual scale
    if (currentZoom == 0.0f) {
        SEL reportedSel = NSSelectorFromString(@"reportedZoomFactor");
        if ([videoModule respondsToSelector:reportedSel]) {
            currentZoom = ((float (*)(id, SEL))objc_msgSend)(videoModule, reportedSel);
        }
        if (currentZoom == 0.0f) currentZoom = 1.0f;
    }

    // Compute new zoom: magnification is the pinch delta (-1 to +1 range per gesture)
    CGFloat magnification = event.magnification;
    float newZoom = currentZoom * (1.0f + (float)magnification);

    // Clamp to reasonable range (6.25% to 800%)
    if (newZoom < 0.0625f) newZoom = 0.0625f;
    if (newZoom > 8.0f) newZoom = 8.0f;

    // Apply
    SEL setSel = NSSelectorFromString(@"setZoomFactor:");
    if ([videoModule respondsToSelector:setSel]) {
        ((void (*)(id, SEL, float))objc_msgSend)(videoModule, setSel, newZoom);
    }
}

// Swizzled scrollWheel: — pans the viewer when zoomed in, falls through to original otherwise
static IMP sOrigScrollWheel = NULL;

static void SpliceKit_FFPlayerView_scrollWheel(id self, SEL _cmd, NSEvent *event) {
    // Get playerVideoModule
    SEL pvmSel = NSSelectorFromString(@"playerVideoModule");
    id videoModule = [self respondsToSelector:pvmSel]
        ? ((id (*)(id, SEL))objc_msgSend)(self, pvmSel) : nil;

    if (videoModule) {
        SEL zfSel = NSSelectorFromString(@"zoomFactor");
        float zoom = [videoModule respondsToSelector:zfSel]
            ? ((float (*)(id, SEL))objc_msgSend)(videoModule, zfSel) : 0.0f;

        // Only pan when actually zoomed in (zoomFactor > 0 means not in Fit mode)
        if (zoom > 0.0f) {
            SEL originSel = NSSelectorFromString(@"origin");
            SEL setOriginSel = NSSelectorFromString(@"setOrigin:");
            if ([videoModule respondsToSelector:originSel] &&
                [videoModule respondsToSelector:setOriginSel]) {

                CGPoint origin = ((CGPoint (*)(id, SEL))objc_msgSend)(videoModule, originSel);

                // scrollingDeltaX/Y give trackpad two-finger scroll deltas
                CGFloat dx = event.scrollingDeltaX;
                CGFloat dy = event.scrollingDeltaY;

                // If hasPreciseScrollingDeltas (trackpad), use directly;
                // otherwise (mouse wheel), scale up
                if (!event.hasPreciseScrollingDeltas) {
                    dx *= 10.0;
                    dy *= 10.0;
                }

                origin.x += dx;
                origin.y -= dy; // flip Y — scroll down should pan down (move origin up)

                ((void (*)(id, SEL, CGPoint))objc_msgSend)(videoModule, setOriginSel, origin);
                return; // consumed — don't pass to original
            }
        }
    }

    // Not zoomed in or couldn't get module — call original handler
    if (sOrigScrollWheel) {
        ((void (*)(id, SEL, NSEvent *))sOrigScrollWheel)(self, _cmd, event);
    }
}

static IMP sOrigMagnifyWithEvent = NULL;

void SpliceKit_installViewerPinchZoom(void) {
    if (sViewerPinchZoomInstalled) return;

    Class playerView = objc_getClass("FFPlayerView");
    if (!playerView) {
        SpliceKit_log(@"[ViewerZoom] FFPlayerView not found — skipping pinch-to-zoom install");
        return;
    }

    SEL magnifySel = @selector(magnifyWithEvent:);

    // class_addMethod only adds if the class itself doesn't directly implement it
    // (it won't be fooled by superclass methods like NSResponder's default)
    BOOL added = class_addMethod(playerView, magnifySel,
                                 (IMP)SpliceKit_FFPlayerView_magnifyWithEvent,
                                 "v@:@"); // void, self, _cmd, NSEvent*
    if (added) {
        SpliceKit_log(@"[ViewerZoom] Added magnifyWithEvent: to FFPlayerView — pinch-to-zoom enabled");
    } else {
        // FFPlayerView directly implements magnifyWithEvent: — swizzle it
        Method m = class_getInstanceMethod(playerView, magnifySel);
        if (m) {
            sOrigMagnifyWithEvent = method_setImplementation(m, (IMP)SpliceKit_FFPlayerView_magnifyWithEvent);
            SpliceKit_log(@"[ViewerZoom] Swizzled magnifyWithEvent: on FFPlayerView — pinch-to-zoom enabled");
        } else {
            SpliceKit_log(@"[ViewerZoom] Failed to install magnifyWithEvent: on FFPlayerView");
        }
    }

    // Swizzle scrollWheel: for two-finger panning when zoomed in
    SEL scrollSel = @selector(scrollWheel:);
    Method scrollMethod = class_getInstanceMethod(playerView, scrollSel);
    if (scrollMethod) {
        sOrigScrollWheel = method_setImplementation(scrollMethod, (IMP)SpliceKit_FFPlayerView_scrollWheel);
        SpliceKit_log(@"[ViewerZoom] Swizzled scrollWheel: on FFPlayerView — two-finger pan enabled");
    }

    sViewerPinchZoomInstalled = YES;
}

void SpliceKit_removeViewerPinchZoom(void) {
    if (!sViewerPinchZoomInstalled) return;

    Class playerView = objc_getClass("FFPlayerView");
    if (!playerView) return;

    // Restore magnifyWithEvent:
    SEL magnifySel = @selector(magnifyWithEvent:);
    Method m = class_getInstanceMethod(playerView, magnifySel);
    if (m) {
        if (sOrigMagnifyWithEvent) {
            method_setImplementation(m, sOrigMagnifyWithEvent);
            sOrigMagnifyWithEvent = NULL;
        } else {
            Class nsResponder = [NSResponder class];
            Method superMethod = class_getInstanceMethod(nsResponder, magnifySel);
            if (superMethod) {
                method_setImplementation(m, method_getImplementation(superMethod));
            }
        }
    }

    // Restore scrollWheel:
    if (sOrigScrollWheel) {
        SEL scrollSel = @selector(scrollWheel:);
        Method sm = class_getInstanceMethod(playerView, scrollSel);
        if (sm) {
            method_setImplementation(sm, sOrigScrollWheel);
        }
        sOrigScrollWheel = NULL;
    }

    sViewerPinchZoomInstalled = NO;
    SpliceKit_log(@"[ViewerZoom] Disabled pinch-to-zoom and pan on FFPlayerView");
}

void SpliceKit_setViewerPinchZoomEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kSpliceKitViewerPinchZoom];
    if (enabled) {
        SpliceKit_installViewerPinchZoom();
    } else {
        SpliceKit_removeViewerPinchZoom();
    }
}

BOOL SpliceKit_isViewerPinchZoomEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kSpliceKitViewerPinchZoom];
}

#pragma mark - Viewer Zoom RPC Handlers

NSDictionary *SpliceKit_handleViewerGetZoom(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id player = SpliceKit_getPlayerModule();
            if (!player) { result = @{@"error": @"No player module found"}; return; }

            SEL vmSel = NSSelectorFromString(@"videoModule");
            if (![player respondsToSelector:vmSel]) { result = @{@"error": @"No videoModule on player"}; return; }
            id videoModule = ((id (*)(id, SEL))objc_msgSend)(player, vmSel);
            if (!videoModule) { result = @{@"error": @"videoModule is nil"}; return; }

            SEL zfSel = NSSelectorFromString(@"zoomFactor");
            float zoom = ((float (*)(id, SEL))objc_msgSend)(videoModule, zfSel);

            float reportedZoom = zoom;
            SEL reportedSel = NSSelectorFromString(@"reportedZoomFactor");
            if ([videoModule respondsToSelector:reportedSel]) {
                reportedZoom = ((float (*)(id, SEL))objc_msgSend)(videoModule, reportedSel);
            }

            result = @{
                @"zoomFactor": @(zoom),
                @"reportedZoomFactor": @(reportedZoom),
                @"percentage": @(reportedZoom * 100.0f),
                @"isFitMode": @(zoom == 0.0f),
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

NSDictionary *SpliceKit_handleViewerSetZoom(NSDictionary *params) {
    NSNumber *zoomNum = params[@"zoom"];
    if (!zoomNum) return @{@"error": @"'zoom' parameter required (float: 0.0=fit, 1.0=100%, etc.)"};
    float zoom = [zoomNum floatValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id player = SpliceKit_getPlayerModule();
            if (!player) { result = @{@"error": @"No player module found"}; return; }

            SEL vmSel = NSSelectorFromString(@"videoModule");
            if (![player respondsToSelector:vmSel]) { result = @{@"error": @"No videoModule on player"}; return; }
            id videoModule = ((id (*)(id, SEL))objc_msgSend)(player, vmSel);
            if (!videoModule) { result = @{@"error": @"videoModule is nil"}; return; }

            SEL setSel = NSSelectorFromString(@"setZoomFactor:");
            if (![videoModule respondsToSelector:setSel]) { result = @{@"error": @"setZoomFactor: not available"}; return; }

            ((void (*)(id, SEL, float))objc_msgSend)(videoModule, setSel, zoom);

            result = @{
                @"status": @"ok",
                @"zoomFactor": @(zoom),
                @"percentage": zoom == 0.0f ? @"fit" : @(zoom * 100.0f),
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}
