//
//  SpliceKitFeatureEffectDrag.m
//  SpliceKit - Effect drag as adjustment clip: dropping a video effect on empty
//  timeline space creates an adjustment clip carrying it.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Effect Drag as Adjustment Clip

// When a video filter is dragged from the Effects Browser to empty timeline space
// (above/below clips), create an adjustment clip with that effect instead of rejecting.
// connectAdjustmentClip: gives us the right drop placement, but during a drag the
// active-browser selection is unreliable, so we capture the dragged effect ID
// ourselves and apply/rename the new clip after it is created.

static NSString * const kSpliceKitEffectDragAsAdjustmentClip = @"SpliceKitEffectDragAsAdjustmentClip";
static BOOL sEffectDropOnEmptySpace = NO;
static IMP sOrigValidateEffectsDrop = NULL;
static IMP sOrigTLKPerformDragOp = NULL;
static IMP sOrigKeyWindowActiveModule = NULL;
static NSString *sDraggedEffectID = nil;
static NSString *sDraggedEffectName = nil;
static NSString *sEffectDragKeyWindowSelectedEffectID = nil;
static BOOL sEffectDragInstallRetryScheduled = NO;
static NSInteger sEffectDragInstallAttempts = 0;

static void SpliceKit_scheduleEffectDragInstallRetry(void);

@interface SpliceKitEffectDragModuleProxy : NSProxy {
    id _target;
}
+ (instancetype)proxyWithTarget:(id)target;
- (id)selectedEffectID;
@end

@implementation SpliceKitEffectDragModuleProxy
+ (instancetype)proxyWithTarget:(id)target {
    SpliceKitEffectDragModuleProxy *proxy = [SpliceKitEffectDragModuleProxy alloc];
    proxy->_target = target;
    return proxy;
}

- (id)selectedEffectID {
    return sEffectDragKeyWindowSelectedEffectID;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (selector == @selector(selectedEffectID)) {
        return [NSMethodSignature signatureWithObjCTypes:"@@:"];
    }
    return _target ? [_target methodSignatureForSelector:selector]
                   : [NSObject instanceMethodSignatureForSelector:@selector(init)];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    if (_target) {
        [invocation invokeWithTarget:_target];
    }
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return aSelector == @selector(selectedEffectID) || [_target respondsToSelector:aSelector];
}

- (Class)class {
    return _target ? [_target class] : [NSObject class];
}

- (BOOL)isKindOfClass:(Class)aClass {
    return _target ? [_target isKindOfClass:aClass] : [super isKindOfClass:aClass];
}

- (NSString *)description {
    return _target ? [_target description] : @"<SpliceKitEffectDragModuleProxy>";
}
@end

static id SpliceKit_swizzled_keyWindowActiveModule(id self, SEL _cmd) {
    id original = sOrigKeyWindowActiveModule
        ? ((id (*)(id, SEL))sOrigKeyWindowActiveModule)(self, _cmd)
        : nil;

    if (sEffectDragKeyWindowSelectedEffectID.length > 0) {
        return [SpliceKitEffectDragModuleProxy proxyWithTarget:original];
    }

    return original;
}

static void SpliceKit_clearDraggedEffectState(void) {
    sEffectDropOnEmptySpace = NO;
    sDraggedEffectID = nil;
    sDraggedEffectName = nil;
}

BOOL SpliceKit_isEffectDragAsAdjustmentClipEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id storedValue = [defaults objectForKey:kSpliceKitEffectDragAsAdjustmentClip];
    if (!storedValue) {
        return YES;
    }
    return [defaults boolForKey:kSpliceKitEffectDragAsAdjustmentClip];
}

void SpliceKit_setEffectDragAsAdjustmentClipEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kSpliceKitEffectDragAsAdjustmentClip];
    if (enabled) {
        SpliceKit_log(@"[EffectDrag] Enabled");
        SpliceKit_installEffectDragAsAdjustmentClip();
    } else {
        SpliceKit_log(@"[EffectDrag] Disabled");
        sEffectDragKeyWindowSelectedEffectID = nil;
        SpliceKit_clearDraggedEffectState();
    }
}

Class SpliceKit_findLoadedClassNamed(const char *wantedName) {
    if (!wantedName) return Nil;

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return Nil;

    Class foundClass = Nil;
    for (unsigned int i = 0; i < classCount; i++) {
        const char *className = class_getName(classes[i]);
        if (className && strcmp(className, wantedName) == 0) {
            foundClass = classes[i];
            break;
        }
    }

    free(classes);
    return foundClass;
}

static void SpliceKit_effectDragExtractEffectInfo(
    id pasteboard, id timelineModule, NSString **outEffectID, NSString **outEffectName)
{
    NSString *effectID = nil;
    NSString *effectName = nil;

    if (pasteboard && timelineModule) {
        SEL seqSel = NSSelectorFromString(@"sequence");
        id sequence = [timelineModule respondsToSelector:seqSel]
            ? ((id (*)(id, SEL))objc_msgSend)(timelineModule, seqSel)
            : nil;
        SEL newMediaSel = NSSelectorFromString(@"newMediaWithSequence:fromURL:options:");
        if (sequence && [pasteboard respondsToSelector:newMediaSel]) {
            id items = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
                pasteboard, newMediaSel, sequence, nil, nil);
            for (id item in items) {
                id object = item;
                SEL objectSel = NSSelectorFromString(@"object");
                if ([item respondsToSelector:objectSel]) {
                    id inner = ((id (*)(id, SEL))objc_msgSend)(item, objectSel);
                    if (inner) object = inner;
                }
                if ([object respondsToSelector:@selector(effectID)]) {
                    id resolvedEffectID = ((id (*)(id, SEL))objc_msgSend)(object, @selector(effectID));
                    if ([resolvedEffectID isKindOfClass:[NSString class]] &&
                        [(NSString *)resolvedEffectID length] > 0) {
                        effectID = resolvedEffectID;
                        break;
                    }
                }
            }
        }
    }

    if (effectID) {
        Class ffEffect = objc_getClass("FFEffect");
        if (ffEffect && [ffEffect respondsToSelector:@selector(displayNameForEffectID:)]) {
            id displayName = ((id (*)(id, SEL, id))objc_msgSend)(
                (id)ffEffect, @selector(displayNameForEffectID:), effectID);
            if ([displayName isKindOfClass:[NSString class]] && [(NSString *)displayName length] > 0) {
                effectName = displayName;
            }
        }
    }

    if (outEffectID) *outEffectID = effectID;
    if (outEffectName) *outEffectName = effectName;
}

id SpliceKit_effectDragVideoEffectsTarget(id clip) {
    if (!clip) return nil;

    SEL veSel = NSSelectorFromString(@"videoEffects");
    if ([clip respondsToSelector:veSel]) {
        id videoEffects = ((id (*)(id, SEL))objc_msgSend)(clip, veSel);
        if (videoEffects) return videoEffects;
    }

    SEL toolSel = NSSelectorFromString(@"representedToolObject");
    if ([clip respondsToSelector:toolSel]) {
        id toolObj = ((id (*)(id, SEL))objc_msgSend)(clip, toolSel);
        if (toolObj && [toolObj respondsToSelector:veSel]) {
            return ((id (*)(id, SEL))objc_msgSend)(toolObj, veSel);
        }
    }

    return nil;
}

// Swizzled -[FFAnchoredTimelineModule _validateEffectsDrop:onItem:atIndex:]
// Original rejects drops when item is the root (empty space). We accept those
// for video filters so the user gets a green "+" cursor.
static unsigned long long SpliceKit_swizzled_validateEffectsDrop(
    id self, SEL _cmd, id pasteboard, id item, long long index)
{
    unsigned long long result = ((unsigned long long (*)(id, SEL, id, id, long long))
        sOrigValidateEffectsDrop)(self, _cmd, pasteboard, item, index);

    if (!SpliceKit_isEffectDragAsAdjustmentClipEnabled()) {
        SpliceKit_clearDraggedEffectState();
        return result;
    }

    if (result != 0) {
        // Original accepted (drop on a valid clip) — normal behavior
        SpliceKit_clearDraggedEffectState();
        return result;
    }

    // Original rejected. Check if this is a video filter over empty space.
    SEL hasTypeSel = NSSelectorFromString(@"hasEffectsWithType:");
    if (![pasteboard respondsToSelector:hasTypeSel]) {
        SpliceKit_clearDraggedEffectState();
        return 0;
    }
    BOOL hasVideoFilter = ((BOOL (*)(id, SEL, id))objc_msgSend)(
        pasteboard, hasTypeSel, @"effect.video.filter");
    if (!hasVideoFilter) {
        SpliceKit_clearDraggedEffectState();
        return 0;
    }

    // Check if item is the root item (empty timeline space)
    SEL rootSel = NSSelectorFromString(@"rootItem");
    if (![self respondsToSelector:rootSel]) {
        SpliceKit_clearDraggedEffectState();
        return 0;
    }
    id rootItem = ((id (*)(id, SEL))objc_msgSend)(self, rootSel);
    if (item != rootItem) {
        SpliceKit_clearDraggedEffectState();
        return 0;
    }

    NSString *effectID = nil;
    NSString *effectName = nil;
    SpliceKit_effectDragExtractEffectInfo(pasteboard, self, &effectID, &effectName);

    // Accept the drop — we'll create an adjustment clip in performDragOperation:
    sEffectDropOnEmptySpace = YES;
    sDraggedEffectID = [effectID copy];
    sDraggedEffectName = [effectName copy];
    SpliceKit_log(@"[EffectDrag] Accepting empty-space drop for %@ (%@) at index %lld",
                  sDraggedEffectName ?: @"<unknown effect>",
                  sDraggedEffectID ?: @"<no effect id>",
                  index);
    return 1; // NSDragOperationCopy
}

// Swizzled -[TLKTimelineView performDragOperation:]
// Intercepts the drop before FCP's normal handling. When our flag is set,
// temporarily overrides NSApp.keyWindowActiveModule.selectedEffectID so
// connectAdjustmentClip: takes FCP's normal "effect browser selection" path.
static char SpliceKit_swizzled_TLKPerformDragOp(id self, SEL _cmd, id draggingInfo) {
    if (!SpliceKit_isEffectDragAsAdjustmentClipEnabled()) {
        SpliceKit_clearDraggedEffectState();
        goto fallback;
    }

    if (sEffectDropOnEmptySpace) {
        id timelineModule = SpliceKit_getActiveTimelineModule();
        if (!timelineModule) {
            SpliceKit_clearDraggedEffectState();
            goto fallback;
        }

        NSString *effectID = [sDraggedEffectID copy];
        NSString *effectName = [sDraggedEffectName copy];
        if (effectID.length == 0) {
            id handlerPb = nil;
            @try { handlerPb = [timelineModule valueForKey:@"handlerPasteboard"]; } @catch (NSException *e) {}
            SpliceKit_effectDragExtractEffectInfo(handlerPb, timelineModule, &effectID, &effectName);
        }

        SpliceKit_log(@"[EffectDrag] Creating adjustment clip with effect: %@ (%@)",
                      effectName ?: @"<none>", effectID ?: @"<none>");

        // Step 1: Create the adjustment clip at the validated drop position.
        SEL adjSel = NSSelectorFromString(@"connectAdjustmentClip:");
        if (![timelineModule respondsToSelector:adjSel]) {
            SpliceKit_clearDraggedEffectState();
            goto fallback;
        }
        if (effectID.length > 0) {
            sEffectDragKeyWindowSelectedEffectID = [effectID copy];
        }
        ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, adjSel, nil);
        sEffectDragKeyWindowSelectedEffectID = nil;

        // FCP's native path should have applied the effect and set the clip name.
        SpliceKit_clearDraggedEffectState();
        return 1; // YES — drop handled
    }

fallback:
    if (!sOrigTLKPerformDragOp) {
        return 0;
    }
    return ((char (*)(id, SEL, id))sOrigTLKPerformDragOp)(self, _cmd, draggingInfo);
}

static void SpliceKit_scheduleEffectDragInstallRetry(void) {
    if ((sOrigValidateEffectsDrop && sOrigTLKPerformDragOp) || sEffectDragInstallRetryScheduled) {
        return;
    }
    if (sEffectDragInstallAttempts >= 30) {
        if (sEffectDragInstallAttempts == 30) {
            SpliceKit_log(@"[EffectDrag] Giving up on swizzle install after %ld attempts",
                          (long)sEffectDragInstallAttempts);
            sEffectDragInstallAttempts++;
        }
        return;
    }

    sEffectDragInstallRetryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sEffectDragInstallRetryScheduled = NO;
        sEffectDragInstallAttempts++;
        SpliceKit_installEffectDragSwizzlesNow();
    });
}

void SpliceKit_installEffectDragSwizzlesNow(void) {
    // Use async dispatch to avoid deadlocking the bridge when the main thread
    // is busy (e.g., loading CompressorKit during startup). The swizzles will
    // be installed on the next main thread run loop iteration.
    if (sOrigValidateEffectsDrop && sOrigTLKPerformDragOp) return; // Already installed
    SpliceKit_executeOnMainThreadAsync(^{
        // Wrap in safeInstall — the getActiveTimelineModule() call can crash on
        // platforms where the editor container class layout has changed.
        SpliceKit_safeInstall("EffectDragSwizzles", ^{
            if (sOrigValidateEffectsDrop && sOrigTLKPerformDragOp) {
                sEffectDragInstallRetryScheduled = NO;
                return;
            }

            Class tlmClass = Nil;
            Class tlkClass = Nil;

            id activeModule = SpliceKit_getActiveTimelineModule();
            if (activeModule) {
                tlmClass = [activeModule class];
                SEL tvSel = NSSelectorFromString(@"timelineView");
                if ([activeModule respondsToSelector:tvSel]) {
                    id timelineView = ((id (*)(id, SEL))objc_msgSend)(activeModule, tvSel);
                    if (timelineView) {
                        tlkClass = [timelineView class];
                    }
                }
            }

            if (!tlmClass) tlmClass = SpliceKit_findLoadedClassNamed("FFAnchoredTimelineModule");
            if (!tlkClass) tlkClass = SpliceKit_findLoadedClassNamed("TLKTimelineView");

            if (!tlmClass || !tlkClass) {
                if (sEffectDragInstallAttempts == 0) {
                    SpliceKit_log(@"[EffectDrag] Timeline classes not available yet; waiting to install swizzles");
                }
                SpliceKit_scheduleEffectDragInstallRetry();
                return;
            }

            SEL valSel = NSSelectorFromString(@"_validateEffectsDrop:onItem:atIndex:");
            Method valMethod = class_getInstanceMethod(tlmClass, valSel);
            if (!sOrigValidateEffectsDrop && valMethod) {
                sOrigValidateEffectsDrop = method_setImplementation(
                    valMethod, (IMP)SpliceKit_swizzled_validateEffectsDrop);
                SpliceKit_log(@"[EffectDrag] Swizzled -[%@ _validateEffectsDrop:onItem:atIndex:]",
                              NSStringFromClass(tlmClass));
            }

            SEL perfSel = @selector(performDragOperation:);
            Method perfMethod = class_getInstanceMethod(tlkClass, perfSel);
            if (!sOrigTLKPerformDragOp && perfMethod) {
                sOrigTLKPerformDragOp = method_setImplementation(
                    perfMethod, (IMP)SpliceKit_swizzled_TLKPerformDragOp);
                SpliceKit_log(@"[EffectDrag] Swizzled -[%@ performDragOperation:]",
                              NSStringFromClass(tlkClass));
            }

            Class appClass = [NSApplication class];
            SEL keyWindowActiveModuleSel = NSSelectorFromString(@"keyWindowActiveModule");
            Method keyWindowActiveModuleMethod = class_getInstanceMethod(appClass, keyWindowActiveModuleSel);
            if (!sOrigKeyWindowActiveModule && keyWindowActiveModuleMethod) {
                sOrigKeyWindowActiveModule = method_setImplementation(
                    keyWindowActiveModuleMethod, (IMP)SpliceKit_swizzled_keyWindowActiveModule);
                SpliceKit_log(@"[EffectDrag] Swizzled -[NSApplication keyWindowActiveModule]");
            }

            if (!sOrigValidateEffectsDrop || !sOrigTLKPerformDragOp || !sOrigKeyWindowActiveModule) {
                SpliceKit_log(@"[EffectDrag] Waiting for swizzles: validate=%@ perform=%@ keyWindowActiveModule=%@",
                              sOrigValidateEffectsDrop ? @"ok" : @"missing",
                              sOrigTLKPerformDragOp ? @"ok" : @"missing",
                              sOrigKeyWindowActiveModule ? @"ok" : @"missing");
                SpliceKit_scheduleEffectDragInstallRetry();
                return;
            }

            sEffectDragInstallRetryScheduled = NO;
            sEffectDragInstallAttempts = 0;
        });
    });
}

void SpliceKit_installEffectDragAsAdjustmentClip(void) {
    if (!SpliceKit_isEffectDragAsAdjustmentClipEnabled()) {
        SpliceKit_log(@"[EffectDrag] Install skipped because option is disabled");
        return;
    }
    SpliceKit_log(@"[EffectDrag] Scheduling install");
    SpliceKit_executeOnMainThreadAsync(^{
        SpliceKit_installEffectDragSwizzlesNow();
    });
}
