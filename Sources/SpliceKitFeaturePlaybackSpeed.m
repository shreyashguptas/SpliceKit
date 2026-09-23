//
//  SpliceKitFeaturePlaybackSpeed.m
//  SpliceKit - Configurable J/L playback speed ladders: the ladder settings,
//  playback.setRate / playback.shuttle, and the fastForward/rewind swizzle.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Playback Speed Configuration

static NSString * const kSpliceKitLLadder = @"SpliceKitLLadder";
static NSString * const kSpliceKitJLadder = @"SpliceKitJLadder";

NSArray<NSNumber *> *SpliceKit_getLLadder(void) {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kSpliceKitLLadder];
    if (stored.count > 0) return stored;
    return @[@1, @2, @4, @8, @16, @32];
}

void SpliceKit_setLLadder(NSArray<NSNumber *> *speeds) {
    [[NSUserDefaults standardUserDefaults] setObject:speeds forKey:kSpliceKitLLadder];
    SpliceKit_log(@"[Speed] L ladder set to: %@", speeds);
}

NSArray<NSNumber *> *SpliceKit_getJLadder(void) {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kSpliceKitJLadder];
    if (stored.count > 0) return stored;
    return @[@1, @2, @4, @8, @16, @32];
}

void SpliceKit_setJLadder(NSArray<NSNumber *> *speeds) {
    [[NSUserDefaults standardUserDefaults] setObject:speeds forKey:kSpliceKitJLadder];
    SpliceKit_log(@"[Speed] J ladder set to: %@", speeds);
}

// Helper to set playback rate via responder chain (always works)
void SpliceKit_setPlaybackRate(float rate) {
    SpliceKit_executeOnMainThread(^{
        // playRate selectors go through the responder chain and route to FFPlayerModule
        NSDictionary *rateSelectors = @{
            @(0.5f): @"playRateHalf:", @(1.0f): @"playRate1X:",
            @(2.0f): @"playRate2X:", @(4.0f): @"playRate4X:",
            @(8.0f): @"playRate8X:", @(16.0f): @"playRate16X:",
            @(32.0f): @"playRate32X:", @(-1.0f): @"playRateMinus1X:",
            @(-2.0f): @"playRateMinus2X:", @(-32.0f): @"playRateMinus32X:",
        };
        NSString *sel = rateSelectors[@(rate)];
        if (sel) {
            SpliceKit_sendAppAction(sel);
        } else {
            // For non-standard rates, use fastForward/rewind which will use our swizzled ladder
            // Or try direct _playWithRate: on player module
            id playerModule = SpliceKit_getPlayerModule();
            if (playerModule) {
                SEL pwrSel = NSSelectorFromString(@"_playWithRate:");
                if ([playerModule respondsToSelector:pwrSel]) {
                    ((void (*)(id, SEL, float))objc_msgSend)(playerModule, pwrSel, rate);
                    return;
                }
            }
            // Last resort: closest standard rate
            float best = 1.0f;
            float bestDist = HUGE_VALF;
            for (NSNumber *key in rateSelectors) {
                float dist = fabsf([key floatValue] - rate);
                if (dist < bestDist) { bestDist = dist; best = [key floatValue]; }
            }
            SpliceKit_sendAppAction(rateSelectors[@(best)]);
        }
    });
}

NSDictionary *SpliceKit_handlePlaybackSetRate(NSDictionary *params) {
    NSNumber *rateNum = params[@"rate"];
    if (!rateNum) return @{@"error": @"rate parameter required"};
    float rate = [rateNum floatValue];
    SpliceKit_setPlaybackRate(rate);
    return @{@"status": @"ok", @"requestedRate": @(rate)};
}

NSDictionary *SpliceKit_handlePlaybackShuttle(NSDictionary *params) {
    NSString *direction = params[@"direction"];
    if (!direction) return @{@"error": @"direction parameter required (faster/slower/stop)"};
    if ([direction isEqualToString:@"stop"]) return SpliceKit_sendAppAction(@"stopPlaying:");
    // Just trigger the (swizzled) fastForward/rewind via responder chain
    if ([direction isEqualToString:@"faster"]) return SpliceKit_sendAppAction(@"fastForward:");
    return SpliceKit_sendAppAction(@"rewind:");
}

#pragma mark - Playback Speed Swizzle (J/L ladder)
//
// Swizzle fastForward: and rewind: on FFPlayerModule to use configurable speed
// ladders instead of the hardcoded 1→2→4→8→16→32 progression.
//
// The original logic: get current rate, find next power-of-two up/down, call _playWithRate:.
// Our replacement: same structure, but walk our configurable array instead.
//

static IMP sOrigFastForward = NULL;
static IMP sOrigRewind = NULL;

// Read a BOOL ivar from an object by name
static BOOL SpliceKit_readBoolIvar(id obj, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return NO;
    return *(BOOL *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(ivar));
}

// Given a sorted ascending ladder and a current rate, find the next step up.
// Returns the first ladder value strictly greater than currentRate.
// If currentRate >= max, returns max (stay at top).
static float SpliceKit_nextLadderUp(NSArray<NSNumber *> *ladder, double currentRate) {
    for (NSNumber *speed in ladder) {
        if ([speed floatValue] > currentRate + 0.01f) return [speed floatValue];
    }
    return [ladder.lastObject floatValue];
}

// Given a sorted ascending ladder and a current rate (negative), find the next step down.
// ladder is stored positive, currentRate is negative.
// Returns the next more-negative value.
static float SpliceKit_nextLadderDown(NSArray<NSNumber *> *ladder, double currentRate) {
    // currentRate is negative (e.g. -2.0). Walk ladder to find next bigger absolute value.
    double absRate = fabs(currentRate);
    for (NSNumber *speed in ladder) {
        if ([speed floatValue] > absRate + 0.01f) return -[speed floatValue];
    }
    return -[ladder.lastObject floatValue];
}

static void SpliceKit_swizzled_fastForward(id self, SEL _cmd, id sender) {
    // Replicate K+L = step forward, and key-repeat filtering
    BOOL stopIsDown = SpliceKit_readBoolIvar(self, "_stopPlayingIsDown");

    if ([sender respondsToSelector:@selector(repeatCount)]) {
        NSInteger rc = ((NSInteger (*)(id, SEL))objc_msgSend)(sender, @selector(repeatCount));
        if (stopIsDown) {
            ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(stepForward:), sender);
            return;
        }
        if (rc > 0) return; // ignore key repeats
    } else if (stopIsDown) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(stepForward:), sender);
        return;
    }

    // End any step playback
    SEL endStepSel = NSSelectorFromString(@"_endStepPlayback");
    if ([self respondsToSelector:endStepSel])
        ((void (*)(id, SEL))objc_msgSend)(self, endStepSel);

    // Get current rate from FFPlayer
    double currentRate = 0.0;
    SEL playerSel = @selector(player);
    if ([self respondsToSelector:playerSel]) {
        id player = ((id (*)(id, SEL))objc_msgSend)(self, playerSel);
        if (player) {
            SEL rateSel = NSSelectorFromString(@"rate");
            if ([player respondsToSelector:rateSel])
                currentRate = ((double (*)(id, SEL))objc_msgSend)(player, rateSel);
        }
    }

    // Set loop range if not currently playing (required for playback to start)
    SEL isPlayingSel = NSSelectorFromString(@"isPlaying");
    BOOL playing = [self respondsToSelector:isPlayingSel]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(self, isPlayingSel) : NO;
    if (!playing) {
        // Call original just for loop range setup, then override rate
        // Actually — just call playAtTime:rate: which _playWithRate: does internally.
        // The loop range is set by the original. Let's call original and override.
    }

    // Find next speed in the L ladder
    NSArray *ladder = SpliceKit_getLLadder();
    float nextRate;
    if (currentRate < 0.0) {
        // Playing in reverse → jump to first L speed
        nextRate = [ladder.firstObject floatValue];
    } else {
        nextRate = SpliceKit_nextLadderUp(ladder, currentRate);
    }

    if (fabsf(nextRate - (float)currentRate) > 0.01f) {
        SEL pwrSel = NSSelectorFromString(@"_playWithRate:");
        if ([self respondsToSelector:pwrSel])
            ((void (*)(id, SEL, float))objc_msgSend)(self, pwrSel, nextRate);
    }
}

static void SpliceKit_swizzled_rewind(id self, SEL _cmd, id sender) {
    BOOL stopIsDown = SpliceKit_readBoolIvar(self, "_stopPlayingIsDown");

    if ([sender respondsToSelector:@selector(repeatCount)]) {
        NSInteger rc = ((NSInteger (*)(id, SEL))objc_msgSend)(sender, @selector(repeatCount));
        if (stopIsDown) {
            ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(stepBackward:), sender);
            return;
        }
        if (rc > 0) return;
    } else if (stopIsDown) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(stepBackward:), sender);
        return;
    }

    SEL endStepSel = NSSelectorFromString(@"_endStepPlayback");
    if ([self respondsToSelector:endStepSel])
        ((void (*)(id, SEL))objc_msgSend)(self, endStepSel);

    double currentRate = 0.0;
    SEL playerSel = @selector(player);
    if ([self respondsToSelector:playerSel]) {
        id player = ((id (*)(id, SEL))objc_msgSend)(self, playerSel);
        if (player) {
            SEL rateSel = NSSelectorFromString(@"rate");
            if ([player respondsToSelector:rateSel])
                currentRate = ((double (*)(id, SEL))objc_msgSend)(player, rateSel);
        }
    }

    NSArray *ladder = SpliceKit_getJLadder();
    float nextRate;
    if (currentRate > 0.0) {
        // Playing forward → jump to first J speed (negative)
        nextRate = -[ladder.firstObject floatValue];
    } else {
        // Already in reverse → go deeper
        nextRate = SpliceKit_nextLadderDown(ladder, currentRate);
    }

    if (fabsf(nextRate - (float)currentRate) > 0.01f) {
        SEL pwrSel = NSSelectorFromString(@"_playWithRate:");
        if ([self respondsToSelector:pwrSel])
            ((void (*)(id, SEL, float))objc_msgSend)(self, pwrSel, nextRate);
    }
}

void SpliceKit_installPlaybackSpeedSwizzle(void) {
    Class cls = objc_getClass("FFPlayerModule");
    if (!cls) {
        SpliceKit_log(@"[Speed] FFPlayerModule not found — swizzle skipped");
        return;
    }

    Method ffMethod = class_getInstanceMethod(cls, @selector(fastForward:));
    if (ffMethod) {
        sOrigFastForward = method_setImplementation(ffMethod, (IMP)SpliceKit_swizzled_fastForward);
        SpliceKit_log(@"[Speed] Swizzled fastForward: on FFPlayerModule");
    }

    Method rwMethod = class_getInstanceMethod(cls, @selector(rewind:));
    if (rwMethod) {
        sOrigRewind = method_setImplementation(rwMethod, (IMP)SpliceKit_swizzled_rewind);
        SpliceKit_log(@"[Speed] Swizzled rewind: on FFPlayerModule");
    }
}
