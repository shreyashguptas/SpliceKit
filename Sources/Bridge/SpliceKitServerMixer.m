//
//  SpliceKitServerMixer.m
//  SpliceKit - Audio mixer handlers (mixer.*): per-role volume, solo, mute, managed bus
//  effects, the skimming hooks and the meter peak read.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

static void SpliceKit_searchLayerTreeForMeterPeak(CALayer *layer,
                                                  Class meterLayerClass,
                                                  ptrdiff_t maskRatioOffset,
                                                  double *maxPeak) {
    if (!layer || !meterLayerClass || !maxPeak) return;

    if ([layer isKindOfClass:meterLayerClass]) {
        double ratio = *(double *)((char *)(__bridge void *)layer + maskRatioOffset);
        if (ratio > *maxPeak) *maxPeak = ratio;
    }

    for (CALayer *subLayer in layer.sublayers) {
        SpliceKit_searchLayerTreeForMeterPeak(subLayer, meterLayerClass, maskRatioOffset, maxPeak);
    }
}

static NSInteger SpliceKit_mixerIndexOfEffectInStack(id effectStack, id effect);

#pragma mark - Mixer Handlers

// Helper: get effectStack from a clip, handling compound clips
id SpliceKit_getClipEffectStack(id clip) {
    if (!clip) return nil;

    // Role-bearing collections have their own audio effect stack. Prefer that over
    // the first contained media component so connected stems keep separate gain.
    if ([clip isKindOfClass:objc_getClass("FFAnchoredCollection")]) {
        @try {
            SEL audioEffectsSel = NSSelectorFromString(@"audioEffects");
            if ([clip respondsToSelector:audioEffectsSel]) {
                id audioES = ((id (*)(id, SEL))objc_msgSend)(clip, audioEffectsSel);
                if (audioES) return audioES;
            }

            id items = [clip valueForKey:@"containedItems"];
            if ([items isKindOfClass:[NSArray class]] && [(NSArray *)items count] > 0) {
                id firstItem = [(NSArray *)items firstObject];
                if ([firstItem respondsToSelector:@selector(effectStack)]) {
                    id es = ((id (*)(id, SEL))objc_msgSend)(firstItem, @selector(effectStack));
                    if (es) return es;
                }
            }
        } @catch (NSException *e) {}
    }

    // Direct effectStack access
    if ([clip respondsToSelector:@selector(effectStack)]) {
        return ((id (*)(id, SEL))objc_msgSend)(clip, @selector(effectStack));
    }
    return nil;
}

// Helper: read volume (dB and linear) from a clip.
// FCP stores audio effects in a separate effectStack accessed via audioEffectsForIdentifier:
// (not the main effectStack which is for video effects).
// Mixer state for volume reads — set before calling readVolume
static CMTime sMixerPlayheadTime = {0, 0, 17, 0}; // default: kCMTimeIndefinite
static id sMixerContainer = nil; // primaryObject for containerToLocalTime conversion

static BOOL SpliceKit_refreshMixerTimelineState(void) {
    id timeline = SpliceKit_getActiveTimelineModule();
    if (!timeline) return NO;

    id sequence = nil;
    @try {
        SEL seqSel = @selector(sequence);
        if ([timeline respondsToSelector:seqSel]) {
            sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
        }
    } @catch (NSException *e) {}
    if (!sequence) return NO;

    CMTime playhead = {0, 1, 0, 0};
    @try {
        SEL playheadSel = @selector(playheadTime);
        if ([timeline respondsToSelector:playheadSel]) {
            playhead = ((CMTime (*)(id, SEL))STRET_MSG)(timeline, playheadSel);
        }
    } @catch (NSException *e) {}

    id primaryObj = nil;
    @try {
        SEL primarySel = @selector(primaryObject);
        if ([sequence respondsToSelector:primarySel]) {
            primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, primarySel);
        }
    } @catch (NSException *e) {}

    if (!primaryObj || playhead.timescale <= 0) return NO;

    sMixerPlayheadTime = playhead;
    sMixerContainer = primaryObj;
    return YES;
}

// Convert absolute timeline time to clip-local time for keyframe reads
static CMTime SpliceKit_clipLocalTime(id clip, CMTime absTime, id container) {
    if (!clip || !container) return absTime;
    @try {
        SEL sel = NSSelectorFromString(@"containerToLocalTime:container:");
        if ([clip respondsToSelector:sel]) {
            return ((CMTime (*)(id, SEL, CMTime, id))STRET_MSG)(
                clip, sel, absTime, container);
        }
    } @catch (NSException *e) {}
    return absTime;
}

// Write one automation point to the mixer's volume channel at the live playhead.
// The current timeline state is refreshed here so drag writes do not depend on UI poll cadence.
BOOL SpliceKit_mixerWriteAutomationPoint(id clip, id channel, double value) {
    if (!clip || !channel) return NO;
    if (!SpliceKit_refreshMixerTimelineState()) return NO;

    CMTime localTime = SpliceKit_clipLocalTime(clip, sMixerPlayheadTime, sMixerContainer);
    BOOL beganOperation = NO;

    @try {
        SEL beginSel = NSSelectorFromString(@"operationBegin");
        if ([channel respondsToSelector:beginSel]) {
            ((void (*)(id, SEL))objc_msgSend)(channel, beginSel);
            beganOperation = YES;
        }
    } @catch (NSException *e) {}

    // Match FCP's inspector/slider behavior: read current value first, then write
    // a timed curve value with the auto-keyframe option enabled.
    (void)SpliceKit_channelValueAtTime(channel, localTime);
    BOOL ok = SpliceKit_setChannelValueAtTimeWithOptions(channel, value, localTime, 1);

    @try {
        SEL endSel = NSSelectorFromString(@"operationEnd");
        if (beganOperation && [channel respondsToSelector:endSel]) {
            ((void (*)(id, SEL))objc_msgSend)(channel, endSel);
        }
    } @catch (NSException *e) {}

    return ok;
}

static NSNumber *SpliceKit_mixerJSONDBNumberFromLinear(double linear, double floorDB);
static NSArray<NSDictionary *> *SpliceKit_mixerRecordDebugState(NSDictionary *state);
void SpliceKit_installMixerSkimHooks(void);

static BOOL sMixerSkimmingLatched = NO;
static CFAbsoluteTime sMixerLastSkimBeginTime = 0;
static CFAbsoluteTime sMixerLastSkimEndTime = 0;
static CFAbsoluteTime sMixerLastSkimUpdateTime = 0;
static IMP sOrigFFPlayerBeginSkimming = NULL;
static IMP sOrigFFPlayerEndSkimming = NULL;
static IMP sOrigTimelineHandlerDidUpdateSkimming = NULL;

static void SpliceKit_readVolume(id clip, id effectStack, NSMutableDictionary *out) {
    if (!clip && !effectStack) return;

    // Strategy 1: Use audioEffectsForIdentifier: on the clip (correct FCP pattern)
    if (clip) {
        @try {
            SEL aeSel = NSSelectorFromString(@"audioEffectsForIdentifier:");
            if ([clip respondsToSelector:aeSel]) {
                id audioES = ((id (*)(id, SEL, unsigned long long))objc_msgSend)(clip, aeSel, 0ULL);
                if (audioES) {
                    out[@"audioEffectStackHandle"] = SpliceKit_storeHandle(audioES);
                    SEL volSel = NSSelectorFromString(@"audioLevelChannel");
                    if ([audioES respondsToSelector:volSel]) {
                        id volChan = ((id (*)(id, SEL))objc_msgSend)(audioES, volSel);
                        if (volChan) {
                            out[@"volumeChannelHandle"] = SpliceKit_storeHandle(volChan);
                            // Convert playhead time to clip-local time for keyframe reads
                            CMTime localTime = SpliceKit_clipLocalTime(clip, sMixerPlayheadTime, sMixerContainer);
                            double linear = SpliceKit_channelValueAtTime(volChan, localTime);
                            out[@"volumeLinear"] = @(linear);
                            out[@"volumeDB"] = SpliceKit_mixerJSONDBNumberFromLinear(linear, -96.0);
                            return;
                        }
                    }
                }
            }
        } @catch (NSException *e) {}
    }

    // Strategy 2: Fallback to effectStack.audioLevelChannel (for clips where the above doesn't work)
    if (effectStack) {
        @try {
            SEL volSel = NSSelectorFromString(@"audioLevelChannel");
            if ([effectStack respondsToSelector:volSel]) {
                id volChan = ((id (*)(id, SEL))objc_msgSend)(effectStack, volSel);
                if (volChan) {
                    CMTime localTime = SpliceKit_clipLocalTime(clip, sMixerPlayheadTime, sMixerContainer);
                    double linear = SpliceKit_channelValueAtTime(volChan, localTime);
                    out[@"volumeLinear"] = @(linear);
                    out[@"volumeDB"] = SpliceKit_mixerJSONDBNumberFromLinear(linear, -96.0);
                    out[@"volumeChannelHandle"] = SpliceKit_storeHandle(volChan);
                    return;
                }
            }
        } @catch (NSException *e) {}
    }
}

static NSNumber *SpliceKit_mixerJSONDBNumberFromLinear(double linear, double floorDB) {
    if (!isfinite(linear) || linear <= 0.000001) return @(floorDB);
    double db = 20.0 * log10(linear);
    if (!isfinite(db) || db < floorDB) db = floorDB;
    return @(db);
}

static void SpliceKit_swizzled_FFPlayer_beginSkimming(id self, SEL _cmd) {
    sMixerSkimmingLatched = YES;
    sMixerLastSkimBeginTime = CFAbsoluteTimeGetCurrent();
    sMixerLastSkimUpdateTime = sMixerLastSkimBeginTime;
    SpliceKit_log(@"[MixerSkim] beginSkimming");
    if (sOrigFFPlayerBeginSkimming) {
        ((void (*)(id, SEL))sOrigFFPlayerBeginSkimming)(self, _cmd);
    }
}

static void SpliceKit_swizzled_FFPlayer_endSkimming(id self, SEL _cmd) {
    sMixerSkimmingLatched = NO;
    sMixerLastSkimEndTime = CFAbsoluteTimeGetCurrent();
    SpliceKit_log(@"[MixerSkim] endSkimming");
    if (sOrigFFPlayerEndSkimming) {
        ((void (*)(id, SEL))sOrigFFPlayerEndSkimming)(self, _cmd);
    }
}

static void SpliceKit_swizzled_Timeline_handlerDidUpdateSkimming(id self, SEL _cmd, id info) {
    sMixerLastSkimUpdateTime = CFAbsoluteTimeGetCurrent();
    if (sOrigTimelineHandlerDidUpdateSkimming) {
        ((void (*)(id, SEL, id))sOrigTimelineHandlerDidUpdateSkimming)(self, _cmd, info);
    }
}

void SpliceKit_installMixerSkimHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class playerCls = NSClassFromString(@"FFPlayer");
        if (playerCls) {
            Method beginMethod = class_getInstanceMethod(playerCls, @selector(beginSkimming));
            if (beginMethod && !sOrigFFPlayerBeginSkimming) {
                sOrigFFPlayerBeginSkimming = SpliceKit_swizzleMethod(
                    playerCls, @selector(beginSkimming), (IMP)SpliceKit_swizzled_FFPlayer_beginSkimming);
            }
            Method endMethod = class_getInstanceMethod(playerCls, @selector(endSkimming));
            if (endMethod && !sOrigFFPlayerEndSkimming) {
                sOrigFFPlayerEndSkimming = SpliceKit_swizzleMethod(
                    playerCls, @selector(endSkimming), (IMP)SpliceKit_swizzled_FFPlayer_endSkimming);
            }
        }

        Class timelineCls = NSClassFromString(@"FFAnchoredTimelineModule");
        SEL updateSel = NSSelectorFromString(@"handlerDidUpdateSkimming:");
        if (timelineCls && class_getInstanceMethod(timelineCls, updateSel) && !sOrigTimelineHandlerDidUpdateSkimming) {
            sOrigTimelineHandlerDidUpdateSkimming = SpliceKit_swizzleMethod(
                timelineCls, updateSel, (IMP)SpliceKit_swizzled_Timeline_handlerDidUpdateSkimming);
        }

        SpliceKit_log(@"[MixerSkim] Hooks installed: begin=%@ end=%@ update=%@",
                      sOrigFFPlayerBeginSkimming ? @"yes" : @"no",
                      sOrigFFPlayerEndSkimming ? @"yes" : @"no",
                      sOrigTimelineHandlerDidUpdateSkimming ? @"yes" : @"no");
    });
}

static NSArray<NSDictionary *> *SpliceKit_mixerRecordDebugState(NSDictionary *state) {
    static NSMutableArray<NSDictionary *> *history = nil;
    static NSString *lastSignature = nil;

    if (!history) history = [NSMutableArray array];
    if (![state isKindOfClass:[NSDictionary class]]) return [history copy];

    double roundedTime = floor([state[@"activeTimeSeconds"] doubleValue] * 4.0) / 4.0;
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@|%.2f",
                           state[@"toolSkimming"] ?: @NO,
                           state[@"transportPlaying"] ?: @NO,
                           state[@"meteringLive"] ?: @NO,
                           state[@"usedPlayerMetering"] ?: @NO,
                           state[@"usedLayerFallback"] ?: @NO,
                           state[@"skimmedRole"] ?: @"",
                           state[@"skimmedName"] ?: @"",
                           roundedTime];
    if ([lastSignature isEqualToString:signature]) {
        return [history copy];
    }

    lastSignature = [signature copy];
    NSMutableDictionary *entry = [state mutableCopy];
    entry[@"wallTime"] = @([[NSDate date] timeIntervalSince1970]);
    entry[@"roundedActiveTimeSeconds"] = @(roundedTime);
    [history addObject:entry];
    while (history.count > 20) {
        [history removeObjectAtIndex:0];
    }
    return [history copy];
}

// Helper: read audio role info from a clip — returns name and color.
// Uses audioRoleIdentifier → library lookup → displayName, and
// FFColorForRole colorSchemeForRolesOfObject: → baseColor for the actual FCP role color.
NSString *SpliceKit_readClipRole(id clip) {
    if (!clip) return nil;

    @try {
        SEL ariSel = NSSelectorFromString(@"audioRoleIdentifier");
        if (![clip respondsToSelector:ariSel]) return nil;

        id roleUID = ((id (*)(id, SEL))objc_msgSend)(clip, ariSel);
        if (!roleUID || ![roleUID isKindOfClass:[NSString class]]) return nil;

        id libs = ((id (*)(Class, SEL))objc_msgSend)(
            objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
        if (!libs || ![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) return nil;

        for (id library in (NSArray *)libs) {
            SEL findSel = NSSelectorFromString(@"findRoleWithUID:");
            if (![library respondsToSelector:findSel]) continue;

            id role = ((id (*)(id, SEL, id))objc_msgSend)(library, findSel, roleUID);
            if (!role) continue;

            if ([role respondsToSelector:@selector(displayName)]) {
                id name = ((id (*)(id, SEL))objc_msgSend)(role, @selector(displayName));
                if ([name isKindOfClass:[NSString class]] && [(NSString *)name length] > 0)
                    return (NSString *)name;
            }
        }
    } @catch (NSException *e) {}

    // Fallback: known built-in UUIDs
    @try {
        SEL guessSel = NSSelectorFromString(@"guessAudioBuiltInMainRoleUID");
        if ([clip respondsToSelector:guessSel]) {
            id uid = ((id (*)(id, SEL))objc_msgSend)(clip, guessSel);
            if ([uid isKindOfClass:[NSString class]]) {
                if ([uid isEqualToString:@"AzxbPvadwQbKPP4kwdFxLVg"]) return @"Dialogue";
                if ([uid isEqualToString:@"A4bkI8U6kRJmBTQDqKJcJrg"]) return @"Music";
                if ([uid isEqualToString:@"ASw2gOhIuSd2wQ8jgLyN3Ew"]) return @"Effects";
            }
        }
    } @catch (NSException *e) {}

    return nil;
}

static NSString *SpliceKit_rawClipRoleUID(id clip) {
    if (!clip) return nil;
    @try {
        SEL ariSel = NSSelectorFromString(@"audioRoleIdentifier");
        if ([clip respondsToSelector:ariSel]) {
            id roleUID = ((id (*)(id, SEL))objc_msgSend)(clip, ariSel);
            if ([roleUID isKindOfClass:[NSString class]] && [roleUID length] > 0) {
                return roleUID;
            }
        }

        SEL guessSel = NSSelectorFromString(@"guessAudioBuiltInMainRoleUID");
        if ([clip respondsToSelector:guessSel]) {
            id roleUID = ((id (*)(id, SEL))objc_msgSend)(clip, guessSel);
            if ([roleUID isKindOfClass:[NSString class]] && [roleUID length] > 0) {
                return roleUID;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

// Helper: read the FCP role color for a clip as RGB hex string (e.g. "#3A7D44")
static NSString *SpliceKit_readClipRoleColor(id clip) {
    if (!clip) return nil;
    @try {
        Class colorForRole = objc_getClass("FFColorForRole");
        if (!colorForRole) return nil;
        SEL csSel = NSSelectorFromString(@"colorSchemeForRolesOfObject:");
        if (![colorForRole respondsToSelector:csSel]) return nil;

        id scheme = ((id (*)(Class, SEL, id))objc_msgSend)(colorForRole, csSel, clip);
        if (!scheme) return nil;

        // Use itemForegroundColor for bright text, fall back to baseColor
        SEL fgSel = NSSelectorFromString(@"itemForegroundColor");
        SEL baseSel = NSSelectorFromString(@"baseColor");
        NSColor *color = nil;
        if ([scheme respondsToSelector:fgSel])
            color = ((id (*)(id, SEL))objc_msgSend)(scheme, fgSel);
        if (!color && [scheme respondsToSelector:baseSel])
            color = ((id (*)(id, SEL))objc_msgSend)(scheme, baseSel);
        if (!color) return nil;

        // Convert to sRGB and extract components
        NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        if (!rgb) return nil;
        CGFloat r, g, b, a;
        [rgb getRed:&r green:&g blue:&b alpha:&a];
        return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)(r * 255), (int)(g * 255), (int)(b * 255)];
    } @catch (NSException *e) {}
    return nil;
}

NSArray *SpliceKit_mixerArrayFromContainer(id value) {
    if (!value) return nil;
    if ([value isKindOfClass:[NSArray class]]) return value;
    if ([value isKindOfClass:[NSSet class]]) return [(NSSet *)value allObjects];
    SEL allObjectsSel = NSSelectorFromString(@"allObjects");
    if ([value respondsToSelector:allObjectsSel]) {
        @try {
            id arr = ((id (*)(id, SEL))objc_msgSend)(value, allObjectsSel);
            if ([arr isKindOfClass:[NSArray class]]) return arr;
        } @catch (NSException *e) {}
    }
    return nil;
}

BOOL SpliceKit_mixerIsCollectionLike(id item) {
    if (!item) return NO;
    NSString *cls = NSStringFromClass([item class]) ?: @"";
    return [cls containsString:@"Collection"] ||
           [cls containsString:@"Storyline"] ||
           [cls containsString:@"Sequence"] ||
           [cls containsString:@"Container"];
}

BOOL SpliceKit_mixerIsSkippableItem(id item) {
    NSString *cls = NSStringFromClass([item class]) ?: @"";
    return [cls containsString:@"Gap"] || [cls containsString:@"Transition"];
}

static BOOL SpliceKit_mixerHasExplicitAudioRole(id item) {
    NSString *roleUID = SpliceKit_rawClipRoleUID(item);
    return roleUID.length > 0;
}

static BOOL SpliceKit_mixerHasAudio(id item) {
    if (!item) return NO;
    @try {
        SEL hasAudioSel = NSSelectorFromString(@"hasAudio");
        if ([item respondsToSelector:hasAudioSel]) {
            return ((BOOL (*)(id, SEL))objc_msgSend)(item, hasAudioSel);
        }
    } @catch (NSException *e) {}
    return NO;
}

static BOOL SpliceKit_mixerIsAudioCarrier(id item) {
    if (!item || SpliceKit_mixerIsSkippableItem(item)) return NO;

    NSString *cls = NSStringFromClass([item class]) ?: @"";
    if (SpliceKit_mixerIsCollectionLike(item)) {
        return NO;
    }

    SEL aeSel = NSSelectorFromString(@"audioEffectsForIdentifier:");
    SEL ariSel = NSSelectorFromString(@"audioRoleIdentifier");
    SEL volSel = NSSelectorFromString(@"audioLevelChannel");
    return [item respondsToSelector:aeSel] ||
           [item respondsToSelector:ariSel] ||
           [item respondsToSelector:volSel] ||
           [cls containsString:@"MediaComponent"];
}

static BOOL SpliceKit_mixerTryReadEffectiveRange(id primaryObj, SEL erSel, id item,
                                                 double *outStartSec, double *outEndSec) {
    if (!primaryObj || !item || !erSel || !outStartSec || !outEndSec) return NO;
    @try {
        CMTimeRange range = ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(
            primaryObj, erSel, item);
        if (range.start.timescale <= 0 || range.duration.timescale <= 0) return NO;
        double startSec = (double)range.start.value / range.start.timescale;
        double durSec = (double)range.duration.value / range.duration.timescale;
        if (!isfinite(startSec) || !isfinite(durSec) || durSec <= 0.0) return NO;
        *outStartSec = startSec;
        *outEndSec = startSec + durSec;
        return YES;
    } @catch (NSException *e) {}
    return NO;
}

static void SpliceKit_mixerCollectClipEntries(id item,
                                              id primaryObj,
                                              SEL erSel,
                                              BOOL canGetRange,
                                              NSInteger inheritedLane,
                                              double inheritedStartSec,
                                              double inheritedEndSec,
                                              NSMutableArray *out,
                                              NSMutableSet<NSString *> *visited) {
    if (!item || !out || !visited) return;

    NSString *visitKey = SpliceKit_handlePointerKey(item);
    if (visitKey.length == 0 || [visited containsObject:visitKey]) return;
    [visited addObject:visitKey];

    if (SpliceKit_mixerIsSkippableItem(item)) return;

    NSInteger lane = inheritedLane;
    @try {
        SEL laneSel = NSSelectorFromString(@"anchoredLane");
        if ([item respondsToSelector:laneSel]) {
            lane = (NSInteger)((long long (*)(id, SEL))objc_msgSend)(item, laneSel);
        }
    } @catch (NSException *e) {}

    double startSec = inheritedStartSec;
    double endSec = inheritedEndSec;
    if (canGetRange) {
        double rangeStart = 0.0;
        double rangeEnd = 0.0;
        if (SpliceKit_mixerTryReadEffectiveRange(primaryObj, erSel, item, &rangeStart, &rangeEnd)) {
            startSec = rangeStart;
            endSec = rangeEnd;
        }
    }

    SEL containedSel = NSSelectorFromString(@"containedItems");
    NSArray *contained = [item respondsToSelector:containedSel]
        ? SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, containedSel))
        : nil;

    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    NSArray *anchored = [item respondsToSelector:anchoredSel]
        ? SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, anchoredSel))
        : nil;

    BOOL collectionRoleCarrier = SpliceKit_mixerIsCollectionLike(item) &&
                                 SpliceKit_mixerHasExplicitAudioRole(item) &&
                                 SpliceKit_mixerHasAudio(item);
    if ((collectionRoleCarrier || SpliceKit_mixerIsAudioCarrier(item)) &&
        endSec > startSec + 0.0001) {
        NSString *role = SpliceKit_readClipRole(item) ?: @"Dialogue";
        NSString *roleUID = SpliceKit_rawClipRoleUID(item) ?: @"";
        NSString *roleColor = SpliceKit_readClipRoleColor(item) ?: @"";
        [out addObject:@{
            @"item": item,
            @"role": role,
            @"roleUID": roleUID,
            @"roleColor": roleColor,
            @"start": @(startSec),
            @"end": @(endSec),
            @"lane": @(lane),
        }];
    }

    if (!collectionRoleCarrier) {
        for (id child in contained) {
            SpliceKit_mixerCollectClipEntries(child, primaryObj, erSel, canGetRange,
                                              lane, startSec, endSec, out, visited);
        }
    }
    for (id child in anchored) {
        SpliceKit_mixerCollectClipEntries(child, primaryObj, erSel, canGetRange,
                                          lane, startSec, endSec, out, visited);
    }
}

static NSMutableOrderedSet *SpliceKit_mixerRoleOrderFromClips(NSArray<NSDictionary *> *allClips) {
    NSMutableOrderedSet *roleOrder = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *clip in allClips) {
        NSString *r = clip[@"role"];
        if ([r containsString:@"Dialogue"]) [roleOrder addObject:r];
    }
    for (NSDictionary *clip in allClips) {
        NSString *r = clip[@"role"];
        if ([r containsString:@"Music"]) [roleOrder addObject:r];
    }
    for (NSDictionary *clip in allClips) {
        NSString *r = clip[@"role"];
        if ([r containsString:@"Effects"]) [roleOrder addObject:r];
    }
    for (NSDictionary *clip in allClips) {
        NSString *r = clip[@"role"];
        if (r.length > 0) [roleOrder addObject:r];
    }
    return roleOrder;
}

static NSArray *SpliceKit_mixerObjectsForRole(NSArray<NSDictionary *> *allClips, NSString *role) {
    if (role.length == 0) return @[];
    NSMutableArray *objects = [NSMutableArray array];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    for (NSDictionary *clip in allClips) {
        if (![clip[@"role"] isEqualToString:role]) continue;
        id item = clip[@"item"];
        if (!item) continue;
        NSString *key = SpliceKit_handlePointerKey(item);
        if (key.length > 0 && [visited containsObject:key]) continue;
        if (key.length > 0) [visited addObject:key];
        [objects addObject:item];
    }
    return objects;
}

static id SpliceKit_mixerBusEffectStackForObject(id object) {
    if (!object) return nil;

    @try {
        SEL localSel = NSSelectorFromString(@"localAudioEffects");
        if ([object respondsToSelector:localSel]) {
            id stack = ((id (*)(id, SEL))objc_msgSend)(object, localSel);
            if (stack) return stack;
        }
    } @catch (NSException *e) {}

    @try {
        SEL aeSel = NSSelectorFromString(@"audioEffectsForIdentifier:");
        if ([object respondsToSelector:aeSel]) {
            id stack = ((id (*)(id, SEL, unsigned long long))objc_msgSend)(object, aeSel, 0ULL);
            if (stack) return stack;
        }
    } @catch (NSException *e) {}

    @try {
        SEL audioEffectsSel = NSSelectorFromString(@"audioEffects");
        if ([object respondsToSelector:audioEffectsSel]) {
            id stack = ((id (*)(id, SEL))objc_msgSend)(object, audioEffectsSel);
            if (stack) return stack;
        }
    } @catch (NSException *e) {}

    return nil;
}

static NSArray *SpliceKit_mixerEffectsInStack(id effectStack) {
    if (!effectStack) return @[];
    for (NSString *selectorName in @[@"visibleEffects", @"effects"]) {
        @try {
            SEL sel = NSSelectorFromString(selectorName);
            if (![effectStack respondsToSelector:sel]) continue;
            id effects = ((id (*)(id, SEL))objc_msgSend)(effectStack, sel);
            NSArray *array = SpliceKit_mixerArrayFromContainer(effects);
            if (array) return array;
        } @catch (NSException *e) {}
    }
    return @[];
}

static NSDictionary *SpliceKit_mixerEffectSummary(id effect, NSUInteger index) {
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    summary[@"index"] = @(index);
    summary[@"handle"] = effect ? (SpliceKit_storeHandle(effect) ?: @"") : @"";
    summary[@"class"] = effect ? (NSStringFromClass([effect class]) ?: @"") : @"";

    @try {
        SEL displayNameSel = NSSelectorFromString(@"displayName");
        if (effect && [effect respondsToSelector:displayNameSel]) {
            id displayName = ((id (*)(id, SEL))objc_msgSend)(effect, displayNameSel);
            if (displayName) summary[@"name"] = [displayName description];
        }
    } @catch (NSException *e) {}

    @try {
        SEL effectIDSel = NSSelectorFromString(@"effectID");
        if (effect && [effect respondsToSelector:effectIDSel]) {
            id effectID = ((id (*)(id, SEL))objc_msgSend)(effect, effectIDSel);
            if (effectID) summary[@"effectID"] = [effectID description];
        }
    } @catch (NSException *e) {}

    BOOL enabled = YES;
    @try {
        SEL enabledSel = NSSelectorFromString(@"enabled");
        if (effect && [effect respondsToSelector:enabledSel]) {
            enabled = ((BOOL (*)(id, SEL))objc_msgSend)(effect, enabledSel);
        }
    } @catch (NSException *e) {}
    summary[@"enabled"] = @(enabled);

    if (![summary[@"name"] isKindOfClass:[NSString class]] || [summary[@"name"] length] == 0) {
        summary[@"name"] = summary[@"effectID"] ?: summary[@"class"] ?: @"Effect";
    }
    if (![summary[@"effectID"] isKindOfClass:[NSString class]]) {
        summary[@"effectID"] = @"";
    }
    return summary;
}

static NSDictionary *SpliceKit_mixerBusTargetSummary(id object, id effectStack) {
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    if (object) {
        summary[@"objectHandle"] = SpliceKit_storeHandle(object) ?: @"";
        summary[@"objectClass"] = NSStringFromClass([object class]) ?: @"";
        @try {
            SEL displayNameSel = NSSelectorFromString(@"displayName");
            if ([object respondsToSelector:displayNameSel]) {
                id displayName = ((id (*)(id, SEL))objc_msgSend)(object, displayNameSel);
                if (displayName) summary[@"name"] = [displayName description];
            }
        } @catch (NSException *e) {}
    }
    if (effectStack) {
        summary[@"effectStackHandle"] = SpliceKit_storeHandle(effectStack) ?: @"";
        summary[@"effectStackClass"] = NSStringFromClass([effectStack class]) ?: @"";

        NSArray *effects = SpliceKit_mixerEffectsInStack(effectStack);
        summary[@"effectCount"] = @(effects.count);
        NSMutableArray *effectNames = [NSMutableArray array];
        NSMutableArray *effectSummaries = [NSMutableArray arrayWithCapacity:effects.count];
        for (NSUInteger i = 0; i < effects.count; i++) {
            NSDictionary *effectSummary = SpliceKit_mixerEffectSummary(effects[i], i);
            NSString *name = effectSummary[@"name"];
            if (name.length > 0) [effectNames addObject:name];
            [effectSummaries addObject:effectSummary];
        }
        summary[@"effectNames"] = effectNames;
        summary[@"effects"] = effectSummaries;
    }
    return summary;
}

static NSArray<NSDictionary *> *SpliceKit_mixerBusTargetsForRoleObjects(NSArray *roleObjects,
                                                                        BOOL allowObjectFallback) {
    NSMutableArray *targets = [NSMutableArray array];
    NSMutableSet<NSString *> *seenStacks = [NSMutableSet set];

    for (id object in roleObjects) {
        if (!object) continue;
        BOOL collectionBacked = SpliceKit_mixerIsCollectionLike(object);
        if (!collectionBacked && !allowObjectFallback) continue;

        id effectStack = SpliceKit_mixerBusEffectStackForObject(object);
        if (!effectStack) continue;

        NSString *stackKey = SpliceKit_handlePointerKey(effectStack);
        if (stackKey.length > 0 && [seenStacks containsObject:stackKey]) continue;
        if (stackKey.length > 0) [seenStacks addObject:stackKey];

        [targets addObject:@{
            @"object": object,
            @"effectStack": effectStack,
            @"collectionBacked": @(collectionBacked),
        }];
    }

    return targets;
}

static NSMutableDictionary<NSString *, NSMutableArray<NSMutableDictionary *> *> *sMixerManagedBusEffects = nil;
static BOOL sMixerManagedBusReconciling = NO;

static NSString *SpliceKit_mixerManagedBusScopeKey(id sequence, id rootObject) {
    NSString *sequenceKey = SpliceKit_handlePointerKey(sequence) ?: @"";
    NSString *rootKey = SpliceKit_handlePointerKey(rootObject) ?: @"";
    if (sequenceKey.length == 0 && rootKey.length == 0) return @"";
    return [NSString stringWithFormat:@"seq:%@|root:%@", sequenceKey, rootKey.length > 0 ? rootKey : sequenceKey];
}

static BOOL SpliceKit_mixerManagedBusEntryMatchesScope(NSDictionary *entry, NSString *scopeKey) {
    NSString *entryScope = [entry[@"scopeKey"] isKindOfClass:[NSString class]] ? entry[@"scopeKey"] : @"";
    return entryScope.length > 0 && scopeKey.length > 0 && [entryScope isEqualToString:scopeKey];
}

static NSMutableDictionary<NSString *, NSMutableArray<NSMutableDictionary *> *> *SpliceKit_mixerManagedBusRegistry(void) {
    if (!sMixerManagedBusEffects) sMixerManagedBusEffects = [NSMutableDictionary dictionary];
    return sMixerManagedBusEffects;
}

static NSMutableArray<NSMutableDictionary *> *SpliceKit_mixerManagedBusEntriesForRole(NSString *role, BOOL create) {
    if (role.length == 0) return nil;
    NSMutableDictionary *registry = SpliceKit_mixerManagedBusRegistry();
    NSMutableArray *entries = registry[role];
    if (!entries && create) {
        entries = [NSMutableArray array];
        registry[role] = entries;
    }
    return entries;
}

static NSArray<NSMutableDictionary *> *SpliceKit_mixerManagedBusEntriesForRoleInScope(NSString *role, NSString *scopeKey) {
    NSMutableArray *entries = SpliceKit_mixerManagedBusEntriesForRole(role, NO);
    if (entries.count == 0 || scopeKey.length == 0) return @[];

    NSMutableArray *scoped = [NSMutableArray array];
    for (NSMutableDictionary *entry in [entries copy]) {
        if (SpliceKit_mixerManagedBusEntryMatchesScope(entry, scopeKey)) {
            [scoped addObject:entry];
        }
    }
    return scoped;
}

static BOOL SpliceKit_mixerManagedBusRegistryHasEntriesForScope(NSString *scopeKey) {
    if (scopeKey.length == 0 || sMixerManagedBusEffects.count == 0) return NO;
    for (NSString *role in [[sMixerManagedBusEffects allKeys] copy]) {
        if (SpliceKit_mixerManagedBusEntriesForRoleInScope(role, scopeKey).count > 0) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *SpliceKit_mixerManagedBusRolesForScope(NSString *scopeKey) {
    if (scopeKey.length == 0 || sMixerManagedBusEffects.count == 0) return @[];
    NSMutableArray<NSString *> *roles = [NSMutableArray array];
    for (NSString *role in [[[sMixerManagedBusEffects allKeys] copy] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        if (SpliceKit_mixerManagedBusEntriesForRoleInScope(role, scopeKey).count > 0) {
            [roles addObject:role];
        }
    }
    return roles;
}

static void SpliceKit_mixerAddManagedBusRolesToRoleOrder(NSMutableOrderedSet *roleOrder, NSString *scopeKey) {
    if (!roleOrder || scopeKey.length == 0) return;
    for (NSString *role in SpliceKit_mixerManagedBusRolesForScope(scopeKey)) {
        if (role.length > 0) [roleOrder addObject:role];
    }
}

static void SpliceKit_mixerPruneManagedBusRole(NSString *role) {
    if (role.length == 0 || !sMixerManagedBusEffects) return;
    NSMutableArray *entries = sMixerManagedBusEffects[role];
    if (entries.count == 0) [sMixerManagedBusEffects removeObjectForKey:role];
}

static NSString *SpliceKit_mixerEffectStringValue(id effect, NSString *selectorName) {
    if (!effect || selectorName.length == 0) return @"";
    @try {
        SEL sel = NSSelectorFromString(selectorName);
        if ([effect respondsToSelector:sel]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(effect, sel);
            return value ? [value description] : @"";
        }
    } @catch (NSException *e) {}
    return @"";
}

static BOOL SpliceKit_mixerEffectMatchesManagedEntry(id effect, NSDictionary *entry) {
    if (!effect || !entry) return NO;
    NSString *entryEffectID = [entry[@"effectID"] isKindOfClass:[NSString class]] ? entry[@"effectID"] : @"";
    NSString *entryName = [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : @"";
    NSString *effectID = SpliceKit_mixerEffectStringValue(effect, @"effectID");
    if (entryEffectID.length > 0 && effectID.length > 0) {
        return [entryEffectID isEqualToString:effectID];
    }
    NSString *name = SpliceKit_mixerEffectStringValue(effect, @"displayName");
    return entryName.length > 0 && name.length > 0 && [entryName isEqualToString:name];
}

static NSMutableDictionary *SpliceKit_mixerNewManagedBusEntry(NSString *role,
                                                              NSString *scopeKey,
                                                              NSDictionary *effect) {
    NSString *effectID = [effect[@"effectID"] isKindOfClass:[NSString class]] ? effect[@"effectID"] : @"";
    NSString *name = [effect[@"name"] isKindOfClass:[NSString class]] ? effect[@"name"] : effectID;
    if (name.length == 0) name = @"Effect";

    NSMutableDictionary *entry = [@{
        @"busEffectID": [[NSUUID UUID] UUIDString],
        @"role": role ?: @"",
        @"scopeKey": scopeKey ?: @"",
        @"effectID": effectID ?: @"",
        @"name": name,
        @"enabled": @YES,
        @"instances": [NSMutableArray array],
    } mutableCopy];
    NSMutableArray *entries = SpliceKit_mixerManagedBusEntriesForRole(role, YES);
    [entries addObject:entry];
    return entry;
}

static NSDictionary *SpliceKit_mixerRememberManagedInstance(NSMutableDictionary *entry,
                                                            id object,
                                                            id effectStack,
                                                            id effect) {
    if (!entry || !object || !effectStack || !effect) return nil;

    NSString *objectKey = SpliceKit_handlePointerKey(object) ?: @"";
    NSMutableArray *instances = [entry[@"instances"] isKindOfClass:[NSMutableArray class]]
        ? entry[@"instances"]
        : nil;
    if (!instances) {
        instances = [NSMutableArray array];
        entry[@"instances"] = instances;
    }

    if (objectKey.length > 0) {
        for (NSDictionary *instance in [instances copy]) {
            NSString *existingObjectKey = [instance[@"objectKey"] isKindOfClass:[NSString class]]
                ? instance[@"objectKey"]
                : @"";
            if ([existingObjectKey isEqualToString:objectKey]) {
                [instances removeObject:instance];
            }
        }
    }

    NSInteger effectIndex = SpliceKit_mixerIndexOfEffectInStack(effectStack, effect);
    NSMutableDictionary *instance = [NSMutableDictionary dictionary];
    instance[@"objectKey"] = objectKey;
    instance[@"objectHandle"] = SpliceKit_storeHandle(object) ?: @"";
    instance[@"stackKey"] = SpliceKit_handlePointerKey(effectStack) ?: @"";
    instance[@"effectKey"] = SpliceKit_handlePointerKey(effect) ?: @"";
    instance[@"effectHandle"] = SpliceKit_storeHandle(effect) ?: @"";
    instance[@"effectStackHandle"] = SpliceKit_storeHandle(effectStack) ?: @"";
    if (effectIndex != NSNotFound) instance[@"effectIndex"] = @(effectIndex);
    [instances addObject:instance];
    return instance;
}

static NSDictionary *SpliceKit_mixerCaptureManagedInstanceAfterApply(NSMutableDictionary *entry,
                                                                     id object,
                                                                     NSUInteger beforeCount) {
    if (!entry || !object) return nil;
    id effectStack = SpliceKit_mixerBusEffectStackForObject(object);
    if (!effectStack) return nil;

    NSArray *effects = SpliceKit_mixerEffectsInStack(effectStack);
    id chosenEffect = nil;
    NSUInteger start = MIN(beforeCount, effects.count);
    for (NSUInteger idx = start; idx < effects.count; idx++) {
        id effect = effects[idx];
        if (SpliceKit_mixerEffectMatchesManagedEntry(effect, entry)) {
            chosenEffect = effect;
            break;
        }
    }
    if (!chosenEffect) {
        for (NSUInteger idx = effects.count; idx > 0; idx--) {
            id effect = effects[idx - 1];
            if (SpliceKit_mixerEffectMatchesManagedEntry(effect, entry)) {
                chosenEffect = effect;
                break;
            }
        }
    }
    if (!chosenEffect) return nil;

    NSDictionary *instance = SpliceKit_mixerRememberManagedInstance(entry, object, effectStack, chosenEffect);
    BOOL enabled = ![entry[@"enabled"] isKindOfClass:[NSNumber class]] || [entry[@"enabled"] boolValue];
    if (!enabled) {
        SEL setEnabledSel = NSSelectorFromString(@"setEnabled:");
        if ([chosenEffect respondsToSelector:setEnabledSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(chosenEffect, setEnabledSel, NO);
        }
    }
    return instance;
}

static BOOL SpliceKit_mixerApplyAudioEffectIDToObjects(NSString *effectID,
                                                       NSArray *targetObjects,
                                                       NSString **outError) {
    if (effectID.length == 0) {
        if (outError) *outError = @"effectID is required";
        return NO;
    }
    if (targetObjects.count == 0) {
        if (outError) *outError = @"No target objects for audio effect";
        return NO;
    }

    Class cmdClass = objc_getClass("FFAddEffectCommand");
    if (!cmdClass) {
        if (outError) *outError = @"FFAddEffectCommand class not found";
        return NO;
    }

    id command = ((id (*)(id, SEL))objc_msgSend)((id)cmdClass, @selector(alloc));
    SEL initSel = NSSelectorFromString(@"initWithEffectID:items:");
    if (![command respondsToSelector:initSel]) {
        if (outError) *outError = @"FFAddEffectCommand does not expose initWithEffectID:items:";
        return NO;
    }
    command = ((id (*)(id, SEL, id, id))objc_msgSend)(command, initSel, effectID, targetObjects);

    Class selMgr = objc_getClass("PESelectionManager");
    id manager = selMgr ? ((id (*)(id, SEL))objc_msgSend)((id)selMgr, @selector(defaultSelectionManager)) : nil;
    if (manager && [manager respondsToSelector:@selector(timelineContext)] &&
        [command respondsToSelector:@selector(setContext:)]) {
        id context = ((id (*)(id, SEL))objc_msgSend)(manager, @selector(timelineContext));
        if (context) ((void (*)(id, SEL, id))objc_msgSend)(command, @selector(setContext:), context);
    }

    if (![command respondsToSelector:@selector(execute)]) {
        if (outError) *outError = @"FFAddEffectCommand does not expose execute";
        return NO;
    }
    BOOL ok = ((BOOL (*)(id, SEL))objc_msgSend)(command, @selector(execute));
    if (!ok && outError) *outError = [NSString stringWithFormat:@"Failed to apply audio effect '%@'", effectID];
    return ok;
}

static BOOL SpliceKit_mixerSetEffectEnabledInStack(id effect, id effectStack, BOOL enabled) {
    if (!effect || !effectStack) return NO;
    SEL setEnabledSel = NSSelectorFromString(@"setEnabled:");
    if (![effect respondsToSelector:setEnabledSel]) return NO;

    @try {
        SEL enabledSel = NSSelectorFromString(@"enabled");
        if ([effect respondsToSelector:enabledSel]) {
            BOOL currentEnabled = ((BOOL (*)(id, SEL))objc_msgSend)(effect, enabledSel);
            if (currentEnabled == enabled) return YES;
        }
    } @catch (NSException *e) {}

    @try {
        SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
        if ([effectStack respondsToSelector:beginSel]) {
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                effectStack, beginSel, enabled ? @"Enable Audio Effect" : @"Disable Audio Effect", nil, NO);
        }
    } @catch (NSException *e) {}

    ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setEnabledSel, enabled);

    @try {
        SEL respondSel = NSSelectorFromString(@"_respondToEffectActivationOrEnabledStateChange");
        if ([effect respondsToSelector:respondSel]) {
            ((void (*)(id, SEL))objc_msgSend)(effect, respondSel);
        }
    } @catch (NSException *e) {}

    @try {
        SEL postSel = NSSelectorFromString(@"postEffectsChangedNotification");
        if ([effectStack respondsToSelector:postSel]) {
            ((void (*)(id, SEL))objc_msgSend)(effectStack, postSel);
        }
    } @catch (NSException *e) {}

    @try {
        SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
        if ([effectStack respondsToSelector:endSel]) {
            id err = nil;
            ((BOOL (*)(id, SEL, id, BOOL, id *))objc_msgSend)(
                effectStack, endSel, enabled ? @"Enable Audio Effect" : @"Disable Audio Effect", YES, &err);
        }
    } @catch (NSException *e) {}
    return YES;
}

static BOOL SpliceKit_mixerRemoveEffectFromStackAtIndex(id effectStack, NSInteger effectIndex) {
    if (!effectStack || effectIndex == NSNotFound || effectIndex < 0) return NO;
    BOOL ok = NO;
    @try {
        SEL opRemoveSel = NSSelectorFromString(@"operationRemoveEffectAtIndex:error:");
        if ([effectStack respondsToSelector:opRemoveSel]) {
            id err = nil;
            ok = ((BOOL (*)(id, SEL, NSUInteger, id *))objc_msgSend)(
                effectStack, opRemoveSel, (NSUInteger)effectIndex, &err);
        }
    } @catch (NSException *e) {}

    if (!ok) {
        @try {
            SEL removeSel = NSSelectorFromString(@"removeEffectAtIndex:");
            if ([effectStack respondsToSelector:removeSel]) {
                ((void (*)(id, SEL, NSUInteger))objc_msgSend)(effectStack, removeSel, (NSUInteger)effectIndex);
                ok = YES;
            }
        } @catch (NSException *e) {}
    }

    if (ok) {
        @try {
            SEL postSel = NSSelectorFromString(@"postEffectsChangedNotification");
            if ([effectStack respondsToSelector:postSel]) {
                ((void (*)(id, SEL))objc_msgSend)(effectStack, postSel);
            }
        } @catch (NSException *e) {}
    }
    return ok;
}

static void SpliceKit_mixerUpdateObjectAfterBusEffectMutation(id object) {
    if (!object) return;
    id effectStack = SpliceKit_mixerBusEffectStackForObject(object);
    NSArray *effects = SpliceKit_mixerEffectsInStack(effectStack);
    if (effects.count == 0) {
        @try {
            SEL setMixdownSel = NSSelectorFromString(@"setMixdownRoleGroup:");
            if ([object respondsToSelector:setMixdownSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(object, setMixdownSel, nil);
            }
        } @catch (NSException *e) {}
    } else {
        @try {
            SEL updateSel = NSSelectorFromString(@"_updateMixdownRoleGroup");
            if ([object respondsToSelector:updateSel]) {
                ((void (*)(id, SEL))objc_msgSend)(object, updateSel);
            }
        } @catch (NSException *e) {}
    }
}

static id SpliceKit_mixerFindManagedEffectOnObject(NSMutableDictionary *entry,
                                                   id object,
                                                   id *outStack,
                                                   NSInteger *outEffectIndex) {
    if (!entry || !object) return nil;
    id effectStack = SpliceKit_mixerBusEffectStackForObject(object);
    if (!effectStack) return nil;

    NSArray *effects = SpliceKit_mixerEffectsInStack(effectStack);
    for (NSUInteger idx = 0; idx < effects.count; idx++) {
        id effect = effects[idx];
        if (!SpliceKit_mixerEffectMatchesManagedEntry(effect, entry)) continue;

        SpliceKit_mixerRememberManagedInstance(entry, object, effectStack, effect);
        if (outStack) *outStack = effectStack;
        if (outEffectIndex) *outEffectIndex = (NSInteger)idx;
        return effect;
    }

    return nil;
}

static id SpliceKit_mixerTrackedEffectForObject(NSMutableDictionary *entry,
                                                id object,
                                                id *outStack,
                                                NSInteger *outEffectIndex) {
    if (!entry || !object) return nil;
    NSString *objectKey = SpliceKit_handlePointerKey(object) ?: @"";
    NSMutableArray *instances = [entry[@"instances"] isKindOfClass:[NSMutableArray class]]
        ? entry[@"instances"]
        : nil;
    if (!instances) return nil;

    for (NSDictionary *instance in [instances copy]) {
        NSString *instanceObjectKey = [instance[@"objectKey"] isKindOfClass:[NSString class]]
            ? instance[@"objectKey"]
            : @"";
        if (objectKey.length > 0 && ![instanceObjectKey isEqualToString:objectKey]) continue;

        NSString *effectHandle = [instance[@"effectHandle"] isKindOfClass:[NSString class]] ? instance[@"effectHandle"] : @"";
        NSString *stackHandle = [instance[@"effectStackHandle"] isKindOfClass:[NSString class]] ? instance[@"effectStackHandle"] : @"";
        id effect = effectHandle.length > 0 ? SpliceKit_resolveHandle(effectHandle) : nil;
        id stack = stackHandle.length > 0 ? SpliceKit_resolveHandle(stackHandle) : nil;
        NSInteger effectIndex = SpliceKit_mixerIndexOfEffectInStack(stack, effect);
        if (effect && stack && effectIndex != NSNotFound) {
            if (outStack) *outStack = stack;
            if (outEffectIndex) *outEffectIndex = effectIndex;
            return effect;
        }
        [instances removeObject:instance];
    }

    return SpliceKit_mixerFindManagedEffectOnObject(entry, object, outStack, outEffectIndex);
}

static id SpliceKit_mixerFirstManagedEffectInstance(NSMutableDictionary *entry,
                                                    id *outStack,
                                                    NSInteger *outEffectIndex) {
    if (!entry) return nil;
    NSMutableArray *instances = [entry[@"instances"] isKindOfClass:[NSMutableArray class]]
        ? entry[@"instances"]
        : nil;
    if (!instances) return nil;

    for (NSDictionary *instance in [instances copy]) {
        NSString *effectHandle = [instance[@"effectHandle"] isKindOfClass:[NSString class]] ? instance[@"effectHandle"] : @"";
        NSString *stackHandle = [instance[@"effectStackHandle"] isKindOfClass:[NSString class]] ? instance[@"effectStackHandle"] : @"";
        id effect = effectHandle.length > 0 ? SpliceKit_resolveHandle(effectHandle) : nil;
        id stack = stackHandle.length > 0 ? SpliceKit_resolveHandle(stackHandle) : nil;
        NSInteger effectIndex = SpliceKit_mixerIndexOfEffectInStack(stack, effect);
        if (effect && stack && effectIndex != NSNotFound) {
            if (outStack) *outStack = stack;
            if (outEffectIndex) *outEffectIndex = effectIndex;
            return effect;
        }
        NSString *objectHandle = [instance[@"objectHandle"] isKindOfClass:[NSString class]] ? instance[@"objectHandle"] : @"";
        id object = objectHandle.length > 0 ? SpliceKit_resolveHandle(objectHandle) : nil;
        id recovered = SpliceKit_mixerFindManagedEffectOnObject(entry, object, outStack, outEffectIndex);
        if (recovered) return recovered;
        [instances removeObject:instance];
    }
    return nil;
}

static NSSet<NSString *> *SpliceKit_mixerObjectKeysForBusTargets(NSArray<NSDictionary *> *busTargets) {
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (NSDictionary *target in busTargets) {
        NSString *objectKey = SpliceKit_handlePointerKey(target[@"object"]) ?: @"";
        if (objectKey.length > 0) [keys addObject:objectKey];
    }
    return keys;
}

static NSSet<NSString *> *SpliceKit_mixerObjectKeysForManagedEntry(NSDictionary *entry) {
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    NSArray *instances = [entry[@"instances"] isKindOfClass:[NSArray class]] ? entry[@"instances"] : @[];
    for (NSDictionary *instance in instances) {
        NSString *objectKey = [instance[@"objectKey"] isKindOfClass:[NSString class]] ? instance[@"objectKey"] : @"";
        if (objectKey.length > 0) [keys addObject:objectKey];
    }
    return keys;
}

static BOOL SpliceKit_mixerManagedBusRoleNeedsReconcile(NSString *role,
                                                        NSArray<NSDictionary *> *allClips,
                                                        NSString *scopeKey) {
    NSArray<NSMutableDictionary *> *entries = SpliceKit_mixerManagedBusEntriesForRoleInScope(role, scopeKey);
    if (entries.count == 0) return NO;

    NSArray *roleObjects = SpliceKit_mixerObjectsForRole(allClips, role);
    NSArray<NSDictionary *> *busTargets = SpliceKit_mixerBusTargetsForRoleObjects(roleObjects, NO);
    NSSet<NSString *> *currentObjectKeys = SpliceKit_mixerObjectKeysForBusTargets(busTargets);

    for (NSDictionary *entry in entries) {
        NSSet<NSString *> *trackedObjectKeys = SpliceKit_mixerObjectKeysForManagedEntry(entry);
        if (![trackedObjectKeys isEqualToSet:currentObjectKeys]) {
            return YES;
        }
    }
    return NO;
}

static BOOL SpliceKit_mixerManagedBusNeedsReconcile(NSArray<NSDictionary *> *allClips, NSString *scopeKey) {
    if (!SpliceKit_mixerManagedBusRegistryHasEntriesForScope(scopeKey)) return NO;
    for (NSString *role in SpliceKit_mixerManagedBusRolesForScope(scopeKey)) {
        if (SpliceKit_mixerManagedBusRoleNeedsReconcile(role, allClips, scopeKey)) {
            return YES;
        }
    }
    return NO;
}

static NSMutableDictionary *SpliceKit_mixerManagedBusEntryForID(NSString *busEffectID,
                                                                NSString **outRole,
                                                                NSUInteger *outEntryIndex) {
    if (busEffectID.length == 0 || !sMixerManagedBusEffects) return nil;
    for (NSString *role in [[sMixerManagedBusEffects allKeys] copy]) {
        NSMutableArray *entries = sMixerManagedBusEffects[role];
        for (NSUInteger idx = 0; idx < entries.count; idx++) {
            NSMutableDictionary *entry = entries[idx];
            NSString *entryID = [entry[@"busEffectID"] isKindOfClass:[NSString class]] ? entry[@"busEffectID"] : @"";
            if ([entryID isEqualToString:busEffectID]) {
                if (outRole) *outRole = role;
                if (outEntryIndex) *outEntryIndex = idx;
                return entry;
            }
        }
    }
    return nil;
}

static BOOL SpliceKit_mixerBuildRoleSnapshot(id timeline,
                                             id *outSequence,
                                             id *outRootObject,
                                             NSMutableArray **outAllClips,
                                             NSMutableOrderedSet **outRoleOrder,
                                             NSString **outError);

static NSMutableDictionary *SpliceKit_mixerManagedBusEntryForRoleDisplayIndex(NSString *role,
                                                                               NSInteger displayIndex,
                                                                               NSUInteger *outEntryIndex) {
    if (role.length == 0 || displayIndex < 0) return nil;

    id timeline = SpliceKit_getActiveTimelineModule();
    id sequence = nil;
    id rootObject = nil;
    NSMutableArray *allClips = nil;
    NSMutableOrderedSet *roleOrder = nil;
    NSString *snapshotError = nil;
    if (!SpliceKit_mixerBuildRoleSnapshot(timeline, &sequence, &rootObject, &allClips, &roleOrder, &snapshotError)) {
        return nil;
    }

    NSString *scopeKey = SpliceKit_mixerManagedBusScopeKey(sequence, rootObject);
    NSArray<NSMutableDictionary *> *scopedEntries = SpliceKit_mixerManagedBusEntriesForRoleInScope(role, scopeKey);
    if ((NSUInteger)displayIndex >= scopedEntries.count) return nil;

    NSMutableDictionary *entry = scopedEntries[(NSUInteger)displayIndex];
    NSMutableArray *entries = SpliceKit_mixerManagedBusEntriesForRole(role, NO);
    NSUInteger actualIndex = [entries indexOfObjectIdenticalTo:entry];
    if (outEntryIndex) *outEntryIndex = actualIndex == NSNotFound ? (NSUInteger)displayIndex : actualIndex;
    return entry;
}

static NSArray<NSDictionary *> *SpliceKit_mixerManagedBusEffectSummariesForRole(NSString *role, NSString *scopeKey) {
    NSArray<NSMutableDictionary *> *entries = SpliceKit_mixerManagedBusEntriesForRoleInScope(role, scopeKey);
    if (entries.count == 0) return @[];

    NSMutableArray *summaries = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSUInteger entryIndex = 0; entryIndex < entries.count; entryIndex++) {
        NSMutableDictionary *entry = entries[entryIndex];
        id stack = nil;
        NSInteger actualEffectIndex = NSNotFound;
        id effect = SpliceKit_mixerFirstManagedEffectInstance(entry, &stack, &actualEffectIndex);

        NSMutableDictionary *summary = effect
            ? [SpliceKit_mixerEffectSummary(effect, actualEffectIndex == NSNotFound ? 0 : (NSUInteger)actualEffectIndex) mutableCopy]
            : [@{
                @"index": @(entryIndex),
                @"handle": @"",
                @"class": @"",
                @"name": [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : @"Effect",
                @"effectID": [entry[@"effectID"] isKindOfClass:[NSString class]] ? entry[@"effectID"] : @"",
                @"enabled": [entry[@"enabled"] isKindOfClass:[NSNumber class]] ? entry[@"enabled"] : @YES,
            } mutableCopy];

        summary[@"index"] = @(entryIndex);
        if (actualEffectIndex != NSNotFound) summary[@"actualEffectIndex"] = @(actualEffectIndex);
        summary[@"busEffectID"] = [entry[@"busEffectID"] isKindOfClass:[NSString class]] ? entry[@"busEffectID"] : @"";
        summary[@"managedBus"] = @YES;
        summary[@"role"] = role ?: @"";
        summary[@"scopeKey"] = scopeKey ?: @"";
        summary[@"targetName"] = @"Role Bus";
        if (stack) summary[@"effectStackHandle"] = SpliceKit_storeHandle(stack) ?: @"";
        [summaries addObject:summary];
    }
    return summaries;
}

static void SpliceKit_mixerReconcileManagedBusEffects(NSArray<NSDictionary *> *allClips, NSString *scopeKey) {
    if (sMixerManagedBusReconciling || !SpliceKit_mixerManagedBusRegistryHasEntriesForScope(scopeKey)) return;
    sMixerManagedBusReconciling = YES;
    @try {
        for (NSString *role in [[sMixerManagedBusEffects allKeys] copy]) {
            NSArray<NSMutableDictionary *> *entries = SpliceKit_mixerManagedBusEntriesForRoleInScope(role, scopeKey);
            NSArray *roleObjects = SpliceKit_mixerObjectsForRole(allClips, role);
            NSArray<NSDictionary *> *busTargets = SpliceKit_mixerBusTargetsForRoleObjects(roleObjects, NO);

            NSMutableSet<NSString *> *currentObjectKeys = [NSMutableSet set];
            for (NSDictionary *target in busTargets) {
                NSString *objectKey = SpliceKit_handlePointerKey(target[@"object"]);
                if (objectKey.length > 0) [currentObjectKeys addObject:objectKey];
            }

            for (NSMutableDictionary *entry in [entries copy]) {
                NSMutableArray *instances = [entry[@"instances"] isKindOfClass:[NSMutableArray class]]
                    ? entry[@"instances"]
                    : nil;
                if (!instances) {
                    instances = [NSMutableArray array];
                    entry[@"instances"] = instances;
                }

                for (NSDictionary *instance in [instances copy]) {
                    NSString *objectKey = [instance[@"objectKey"] isKindOfClass:[NSString class]] ? instance[@"objectKey"] : @"";
                    if (objectKey.length == 0 || [currentObjectKeys containsObject:objectKey]) continue;

                    NSString *effectHandle = [instance[@"effectHandle"] isKindOfClass:[NSString class]] ? instance[@"effectHandle"] : @"";
                    NSString *stackHandle = [instance[@"effectStackHandle"] isKindOfClass:[NSString class]] ? instance[@"effectStackHandle"] : @"";
                    NSString *objectHandle = [instance[@"objectHandle"] isKindOfClass:[NSString class]] ? instance[@"objectHandle"] : @"";
                    id effect = effectHandle.length > 0 ? SpliceKit_resolveHandle(effectHandle) : nil;
                    id stack = stackHandle.length > 0 ? SpliceKit_resolveHandle(stackHandle) : nil;
                    NSInteger effectIndex = SpliceKit_mixerIndexOfEffectInStack(stack, effect);
                    id object = objectHandle.length > 0 ? SpliceKit_resolveHandle(objectHandle) : nil;
                    if ((!stack || effectIndex == NSNotFound) && object) {
                        effect = SpliceKit_mixerFindManagedEffectOnObject(entry, object, &stack, &effectIndex);
                    }
                    if (stack && effectIndex != NSNotFound) {
                        SpliceKit_mixerRemoveEffectFromStackAtIndex(stack, effectIndex);
                    }
                    SpliceKit_mixerUpdateObjectAfterBusEffectMutation(object);
                    for (NSDictionary *candidate in [instances copy]) {
                        NSString *candidateObjectKey = [candidate[@"objectKey"] isKindOfClass:[NSString class]]
                            ? candidate[@"objectKey"]
                            : @"";
                        if (candidateObjectKey.length == 0 || [candidateObjectKey isEqualToString:objectKey]) {
                            [instances removeObject:candidate];
                        }
                    }
                }

                NSString *effectID = [entry[@"effectID"] isKindOfClass:[NSString class]] ? entry[@"effectID"] : @"";
                BOOL enabled = ![entry[@"enabled"] isKindOfClass:[NSNumber class]] || [entry[@"enabled"] boolValue];
                for (NSDictionary *target in busTargets) {
                    id object = target[@"object"];
                    id stack = nil;
                    NSInteger effectIndex = NSNotFound;
                    id existingEffect = SpliceKit_mixerTrackedEffectForObject(entry, object, &stack, &effectIndex);
                    if (existingEffect && stack) {
                        SpliceKit_mixerSetEffectEnabledInStack(existingEffect, stack, enabled);
                        continue;
                    }

                    id effectStack = target[@"effectStack"];
                    NSUInteger beforeCount = SpliceKit_mixerEffectsInStack(effectStack).count;
                    NSString *applyError = nil;
                    if (!SpliceKit_mixerApplyAudioEffectIDToObjects(effectID, @[object], &applyError)) {
                        SpliceKit_log(@"[Mixer] Failed to reconcile role bus effect %@ for %@: %@",
                                      entry[@"name"] ?: effectID,
                                      role,
                                      applyError ?: @"unknown error");
                        continue;
                    }
                    SpliceKit_mixerCaptureManagedInstanceAfterApply(entry, object, beforeCount);
                    SpliceKit_mixerUpdateObjectAfterBusEffectMutation(object);
                }
            }

            SpliceKit_mixerPruneManagedBusRole(role);
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Mixer] Managed bus reconcile exception: %@", e.reason);
    }
    sMixerManagedBusReconciling = NO;
}

static NSArray<NSString *> *SpliceKit_mixerRoleUIDsForRole(NSArray<NSDictionary *> *allClips, NSString *role) {
    if (role.length == 0) return @[];
    NSMutableOrderedSet<NSString *> *roleUIDs = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *clip in allClips) {
        if (![clip[@"role"] isEqualToString:role]) continue;
        NSString *roleUID = clip[@"roleUID"];
        if (roleUID.length > 0) [roleUIDs addObject:roleUID];
    }
    return [roleUIDs array];
}

static BOOL SpliceKit_mixerSetIntersectsObjects(NSSet *set, NSArray *objects) {
    if (set.count == 0 || objects.count == 0) return NO;
    for (id object in objects) {
        if ([set containsObject:object]) return YES;
    }
    return NO;
}

static BOOL SpliceKit_mixerBuildRoleSnapshot(id timeline,
                                             id *outSequence,
                                             id *outRootObject,
                                             NSMutableArray **outAllClips,
                                             NSMutableOrderedSet **outRoleOrder,
                                             NSString **outError) {
    if (!timeline) {
        if (outError) *outError = @"No active timeline module. Is a project open?";
        return NO;
    }

    id sequence = nil;
    @try {
        if ([timeline respondsToSelector:@selector(sequence)]) {
            sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
        }
    } @catch (NSException *e) {}
    if (!sequence) {
        if (outError) *outError = @"No sequence in timeline.";
        return NO;
    }

    id primaryObj = nil;
    @try {
        if ([sequence respondsToSelector:@selector(primaryObject)]) {
            primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
        }
    } @catch (NSException *e) {}
    if (!primaryObj) {
        if (outError) *outError = @"No primary object on sequence";
        return NO;
    }

    id spineItems = nil;
    @try {
        if ([primaryObj respondsToSelector:@selector(containedItems)]) {
            spineItems = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
        }
    } @catch (NSException *e) {}
    if (!spineItems || ![spineItems isKindOfClass:[NSArray class]]) {
        if (outError) *outError = @"No spine items found";
        return NO;
    }

    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    BOOL canGetRange = [primaryObj respondsToSelector:erSel];
    NSMutableArray *allClips = [NSMutableArray array];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    for (id item in (NSArray *)spineItems) {
        SpliceKit_mixerCollectClipEntries(item, primaryObj, erSel, canGetRange,
                                          0, 0.0, 0.0, allClips, visited);
    }

    if (outSequence) *outSequence = sequence;
    if (outRootObject) *outRootObject = primaryObj;
    if (outAllClips) *outAllClips = allClips;
    if (outRoleOrder) *outRoleOrder = SpliceKit_mixerRoleOrderFromClips(allClips);
    return YES;
}

static NSString *SpliceKit_mixerRoleFromParams(NSDictionary *params,
                                               NSMutableOrderedSet *roleOrder,
                                               NSInteger *outIndex) {
    NSString *role = [params[@"role"] isKindOfClass:[NSString class]] ? params[@"role"] : nil;
    NSInteger index = NSNotFound;
    if (role.length == 0 && params[@"index"]) {
        index = [params[@"index"] integerValue];
        if (index >= 0 && (NSUInteger)index < roleOrder.count) {
            role = [roleOrder objectAtIndex:(NSUInteger)index];
        }
    } else if (role.length > 0) {
        NSUInteger found = [roleOrder indexOfObject:role];
        if (found != NSNotFound) index = (NSInteger)found;
    }
    if (outIndex) *outIndex = index;
    return role;
}

static NSSet *SpliceKit_mixerSoloedObjects(id sequence) {
    @try {
        SEL soloedObjectsSel = NSSelectorFromString(@"soloedObjects");
        if ([sequence respondsToSelector:soloedObjectsSel]) {
            id rawSoloed = ((id (*)(id, SEL))objc_msgSend)(sequence, soloedObjectsSel);
            if ([rawSoloed isKindOfClass:[NSSet class]]) return rawSoloed;
        }
    } @catch (NSException *e) {}
    return nil;
}

static NSSet *SpliceKit_mixerDisabledAudioRoleUIDs(id sequence) {
    @try {
        SEL disabledSel = NSSelectorFromString(@"roleUIDsForDisabledAVRolesOfType:");
        if ([sequence respondsToSelector:disabledSel]) {
            id disabled = ((id (*)(id, SEL, int))objc_msgSend)(sequence, disabledSel, 0);
            if ([disabled isKindOfClass:[NSSet class]]) return disabled;
        }
    } @catch (NSException *e) {}
    return nil;
}

static NSSet *SpliceKit_mixerDisabledAudioRoleUIDsForRootObject(id rootObject, id sequence) {
    @try {
        Class playbackRolesClass = objc_getClass("FFTimelinePlaybackRoles");
        SEL disabledMapSel = NSSelectorFromString(@"disabledRoleUIDsMapForRootItem:");
        if (playbackRolesClass && rootObject && [playbackRolesClass respondsToSelector:disabledMapSel]) {
            id map = ((id (*)(Class, SEL, id))objc_msgSend)(playbackRolesClass, disabledMapSel, rootObject);
            if ([map respondsToSelector:@selector(objectForKey:)]) {
                id disabledAudio = ((id (*)(id, SEL, id))objc_msgSend)(map, @selector(objectForKey:), @0);
                if ([disabledAudio isKindOfClass:[NSSet class]]) return disabledAudio;
            }
        }
    } @catch (NSException *e) {}
    return SpliceKit_mixerDisabledAudioRoleUIDs(sequence);
}

static NSUInteger SpliceKit_mixerCountDisabledRoleUIDs(NSArray<NSString *> *roleUIDs, NSSet *disabledRoleUIDs) {
    if (roleUIDs.count == 0 || disabledRoleUIDs.count == 0) return 0;
    NSUInteger count = 0;
    for (NSString *roleUID in roleUIDs) {
        if ([disabledRoleUIDs containsObject:roleUID]) count++;
    }
    return count;
}

static BOOL SpliceKit_mixerSetAudioRolesEnabled(id rootObject,
                                                id sequence,
                                                NSSet<NSString *> *roleUIDs,
                                                BOOL enabled,
                                                NSString **outError) {
    if (roleUIDs.count == 0) {
        if (outError) *outError = @"No audio role UIDs found for this mixer fader";
        return NO;
    }

    Class playbackRolesClass = objc_getClass("FFTimelinePlaybackRoles");
    SEL setRolesSel = NSSelectorFromString(@"setAudioVideoEnabledState:forAudioRoles:forVideoRoles:inRootItem:");
    if (playbackRolesClass && [playbackRolesClass respondsToSelector:setRolesSel] && rootObject) {
        ((void (*)(Class, SEL, BOOL, id, id, id))objc_msgSend)(
            playbackRolesClass, setRolesSel, enabled, roleUIDs, [NSSet set], rootObject);
        return YES;
    }

    SEL setDisabledSel = NSSelectorFromString(@"setRoleUIDsForDisabledAudio:video:");
    if (![sequence respondsToSelector:setDisabledSel]) {
        if (outError) *outError = @"FCP sequence does not expose disabled audio role controls";
        return NO;
    }

    NSMutableSet *nextDisabled = [NSMutableSet setWithSet:(SpliceKit_mixerDisabledAudioRoleUIDs(sequence) ?: [NSSet set])];
    if (enabled) {
        [nextDisabled minusSet:roleUIDs];
    } else {
        [nextDisabled unionSet:roleUIDs];
    }

    NSSet *disabledVideo = nil;
    @try {
        SEL disabledSel = NSSelectorFromString(@"roleUIDsForDisabledAVRolesOfType:");
        if ([sequence respondsToSelector:disabledSel]) {
            id rawDisabledVideo = ((id (*)(id, SEL, int))objc_msgSend)(sequence, disabledSel, 1);
            if ([rawDisabledVideo isKindOfClass:[NSSet class]]) disabledVideo = rawDisabledVideo;
        }
    } @catch (NSException *e) {}

    ((void (*)(id, SEL, id, id))objc_msgSend)(
        sequence, setDisabledSel, nextDisabled, disabledVideo ?: [NSSet set]);
    return YES;
}

// mixer.getState — enumerate clips at playhead with volumes, lanes, roles
NSDictionary *SpliceKit_handleMixerGetState(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module. Is a project open?"};
                return;
            }

            id sequence = nil;
            if ([timeline respondsToSelector:@selector(sequence)]) {
                sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            }
            if (!sequence) {
                result = @{@"error": @"No sequence in timeline."};
                return;
            }

            // Get playhead time
            CMTime playhead = {0, 1, 0, 0};
            if ([timeline respondsToSelector:@selector(playheadTime)]) {
                playhead = ((CMTime (*)(id, SEL))STRET_MSG)(timeline, @selector(playheadTime));
            }
            double playheadSec = SpliceKit_secondsFromTime(playhead);
            BOOL transportPlaying = NO;
            double transportRate = 0.0;
            double frameRate = 0.0;

            // Set global playhead time for volume reads (picks up keyframed values)
            sMixerPlayheadTime = playhead;

            // Get primaryObject (spine container) — also used for time conversion
            id primaryObj = nil;
            if ([sequence respondsToSelector:@selector(primaryObject)]) {
                primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
            }
            if (!primaryObj) {
                result = @{@"error": @"No primary object on sequence"};
                return;
            }
            sMixerContainer = primaryObj; // For clip-local time conversion in readVolume

            SEL isPlayingSel = NSSelectorFromString(@"isPlaying");
            if ([timeline respondsToSelector:isPlayingSel]) {
                transportPlaying = ((BOOL (*)(id, SEL))objc_msgSend)(timeline, isPlayingSel);
            }

            CMTime frameDuration = SpliceKit_sequenceFrameDuration(sequence);
            if (frameDuration.timescale > 0 && frameDuration.value > 0) {
                frameRate = (double)frameDuration.timescale / frameDuration.value;
            }

            id timelinePlayer = nil;
            SEL playerSel = NSSelectorFromString(@"player");
            if ([timeline respondsToSelector:playerSel]) {
                timelinePlayer = ((id (*)(id, SEL))objc_msgSend)(timeline, playerSel);
            }
            SEL rateSel = NSSelectorFromString(@"rate");
            if (timelinePlayer && [timelinePlayer respondsToSelector:rateSel]) {
                transportRate = ((double (*)(id, SEL))objc_msgSend)(timelinePlayer, rateSel);
            }

            BOOL toolSkimming = NO;
            BOOL rawToolSkimming = NO;
            id skimmedItem = nil;
            NSString *skimmedRole = nil;
            NSString *skimmedName = nil;
            double activeTimeSec = playheadSec;
            if (!transportPlaying) {
                CFTimeInterval now = CFAbsoluteTimeGetCurrent();
                SEL isToolSkimmingSel = NSSelectorFromString(@"isToolSkimming");
                if ([timeline respondsToSelector:isToolSkimmingSel]) {
                    rawToolSkimming = ((BOOL (*)(id, SEL))objc_msgSend)(timeline, isToolSkimmingSel);
                }
                BOOL recentlyUpdatedSkimming = (sMixerLastSkimUpdateTime > 0) && ((now - sMixerLastSkimUpdateTime) < 0.35);
                toolSkimming = rawToolSkimming || sMixerSkimmingLatched || recentlyUpdatedSkimming;
                if (toolSkimming) {
                    SEL skimmingTimeSel = NSSelectorFromString(@"skimmingTime");
                    if ([timeline respondsToSelector:skimmingTimeSel]) {
                        CMTime skimTime = ((CMTime (*)(id, SEL))STRET_MSG)(timeline, skimmingTimeSel);
                        if (skimTime.timescale > 0) {
                            activeTimeSec = (double)skimTime.value / skimTime.timescale;
                        }
                    }
                    SEL skimmingItemSel = NSSelectorFromString(@"skimmingItem");
                    if ([timeline respondsToSelector:skimmingItemSel]) {
                        skimmedItem = ((id (*)(id, SEL))objc_msgSend)(timeline, skimmingItemSel);
                    }
                    if (!skimmedItem) {
                        SEL skimmingItemComponentSel = NSSelectorFromString(@"skimmingItemComponent");
                        if ([timeline respondsToSelector:skimmingItemComponentSel]) {
                            skimmedItem = ((id (*)(id, SEL))objc_msgSend)(timeline, skimmingItemComponentSel);
                        }
                    }
                    if (skimmedItem) {
                        skimmedRole = SpliceKit_readClipRole(skimmedItem);
                        if ([skimmedItem respondsToSelector:@selector(displayName)]) {
                            id skimNameObj = ((id (*)(id, SEL))objc_msgSend)(skimmedItem, @selector(displayName));
                            if ([skimNameObj isKindOfClass:[NSString class]]) {
                                skimmedName = skimNameObj;
                            }
                        }
                    }
                }
            }
            else if (sMixerSkimmingLatched) {
                sMixerSkimmingLatched = NO;
                sMixerLastSkimEndTime = CFAbsoluteTimeGetCurrent();
            }

            // Get spine items
            id spineItems = nil;
            if ([primaryObj respondsToSelector:@selector(containedItems)]) {
                spineItems = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
            }
            if (!spineItems || ![spineItems isKindOfClass:[NSArray class]]) {
                result = @{@"error": @"No spine items found"};
                return;
            }

            SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
            BOOL canGetRange = [primaryObj respondsToSelector:erSel];

            // Role-based mixer: one fader per audio role used in the timeline.
            // For each role, find the clip at the playhead with that role and show its volume.
            // This gives a mixing-console view where roles are persistent faders.

            // Step 1: Collect ALL audio-bearing clips (including nested collection contents)
            // with their roles and time ranges.
            NSMutableArray *allClips = [NSMutableArray array]; // {item, role, startSec, endSec, lane}
            NSMutableSet<NSString *> *visited = [NSMutableSet set];

            for (id item in (NSArray *)spineItems) {
                SpliceKit_mixerCollectClipEntries(item, primaryObj, erSel, canGetRange,
                                                  0, 0.0, 0.0, allClips, visited);
            }

            // Step 2: Collect unique roles (ordered: Dialogue first, then Music, Effects, others)
            NSMutableOrderedSet *roleOrder = SpliceKit_mixerRoleOrderFromClips(allClips);
            NSSet *soloedObjects = SpliceKit_mixerSoloedObjects(sequence);
            BOOL soloActive = (soloedObjects.count > 0);
            NSSet *disabledAudioRoleUIDs = SpliceKit_mixerDisabledAudioRoleUIDsForRootObject(primaryObj, sequence);

            NSNumber *maxFadersParam = [params[@"maxFaders"] isKindOfClass:[NSNumber class]] ? params[@"maxFaders"] : nil;
            NSUInteger maxFaders = maxFadersParam ? [maxFadersParam unsignedIntegerValue] : 12;
            if (maxFaders < 1) maxFaders = 1;
            if (maxFaders > 64) maxFaders = 64;

            // Step 3: For each role, find the clip at the playhead and build fader data
            NSMutableArray *indexed = [NSMutableArray array];
            NSInteger faderIdx = 0;
            NSString *scopeKey = SpliceKit_mixerManagedBusScopeKey(sequence, primaryObj);
            if (SpliceKit_mixerManagedBusNeedsReconcile(allClips, scopeKey)) {
                SpliceKit_mixerReconcileManagedBusEffects(allClips, scopeKey);
            }
            SpliceKit_mixerAddManagedBusRolesToRoleOrder(roleOrder, scopeKey);

            for (NSString *role in roleOrder) {
                if ((NSUInteger)faderIdx >= maxFaders) break;

                // Get the role color from the first clip with this role
                NSString *roleColor = @"";
                for (NSDictionary *clip in allClips) {
                    if ([clip[@"role"] isEqualToString:role] && [clip[@"roleColor"] length] > 0) {
                        roleColor = clip[@"roleColor"];
                        break;
                    }
                }

                // Find clip with this role at the playhead
                id bestClip = nil;
                double bestStart = 0, bestEnd = 0;
                NSInteger bestLane = 0;
                for (NSDictionary *clip in allClips) {
                    if (![clip[@"role"] isEqualToString:role]) continue;
                    double s = [clip[@"start"] doubleValue];
                    double e = [clip[@"end"] doubleValue];
                    if (activeTimeSec >= s - 0.001 && activeTimeSec <= e + 0.001) {
                        bestClip = clip[@"item"];
                        bestStart = s;
                        bestEnd = e;
                        bestLane = [clip[@"lane"] integerValue];
                        break;
                    }
                }

                NSMutableDictionary *fader = [NSMutableDictionary dictionary];
                fader[@"index"] = @(faderIdx);
                fader[@"role"] = role;
                if (roleColor.length > 0) fader[@"roleColor"] = roleColor;

                NSArray *roleObjects = SpliceKit_mixerObjectsForRole(allClips, role);
                BOOL roleSoloed = SpliceKit_mixerSetIntersectsObjects(soloedObjects, roleObjects);
                fader[@"soloed"] = @(roleSoloed);
                fader[@"soloActive"] = @(soloActive);
                fader[@"soloMuted"] = @(soloActive && !roleSoloed);
                fader[@"soloObjectCount"] = @(roleObjects.count);

                NSArray<NSDictionary *> *busTargets = SpliceKit_mixerBusTargetsForRoleObjects(roleObjects, NO);
                fader[@"busKind"] = busTargets.count > 0 ? @"collection" : @"none";
                fader[@"busObjectCount"] = @(busTargets.count);
                NSArray<NSDictionary *> *managedBusEffects = SpliceKit_mixerManagedBusEffectSummariesForRole(role, scopeKey);
                if (managedBusEffects.count > 0) {
                    NSMutableArray *managedNames = [NSMutableArray arrayWithCapacity:managedBusEffects.count];
                    for (NSDictionary *effect in managedBusEffects) {
                        NSString *effectName = [effect[@"name"] isKindOfClass:[NSString class]] ? effect[@"name"] : @"";
                        if (effectName.length > 0) [managedNames addObject:effectName];
                    }
                    NSDictionary *firstBusSummary = busTargets.count > 0
                        ? SpliceKit_mixerBusTargetSummary(busTargets.firstObject[@"object"], busTargets.firstObject[@"effectStack"])
                        : @{};
                    fader[@"busKind"] = @"managedRole";
                    fader[@"busHandle"] = firstBusSummary[@"objectHandle"] ?: @"";
                    fader[@"busClass"] = @"SpliceKitRoleBus";
                    fader[@"busEffectStackHandle"] = firstBusSummary[@"effectStackHandle"] ?: @"";
                    fader[@"busEffectCount"] = @(managedBusEffects.count);
                    fader[@"busEffectNames"] = managedNames;
                    fader[@"busEffects"] = managedBusEffects;
                } else if (busTargets.count > 0) {
                    NSMutableArray *allEffectNames = [NSMutableArray array];
                    NSMutableArray *allEffects = [NSMutableArray array];
                    NSDictionary *firstBusSummary = nil;

                    for (NSUInteger targetIdx = 0; targetIdx < busTargets.count; targetIdx++) {
                        NSDictionary *busTarget = busTargets[targetIdx];
                        NSDictionary *busSummary = SpliceKit_mixerBusTargetSummary(busTarget[@"object"],
                                                                                   busTarget[@"effectStack"]);
                        if (!firstBusSummary) firstBusSummary = busSummary;

                        NSArray *effects = [busSummary[@"effects"] isKindOfClass:[NSArray class]]
                            ? busSummary[@"effects"]
                            : @[];
                        for (NSDictionary *effect in effects) {
                            NSMutableDictionary *effectWithTarget = [effect mutableCopy];
                            effectWithTarget[@"targetIndex"] = @(targetIdx);
                            effectWithTarget[@"targetHandle"] = busSummary[@"objectHandle"] ?: @"";
                            effectWithTarget[@"targetName"] = busSummary[@"name"] ?: @"";
                            effectWithTarget[@"effectStackHandle"] = busSummary[@"effectStackHandle"] ?: @"";
                            [allEffects addObject:effectWithTarget];

                            NSString *effectName = effectWithTarget[@"name"];
                            if (effectName.length > 0) [allEffectNames addObject:effectName];
                        }
                    }

                    fader[@"busHandle"] = firstBusSummary[@"objectHandle"] ?: @"";
                    fader[@"busClass"] = firstBusSummary[@"objectClass"] ?: @"";
                    fader[@"busEffectStackHandle"] = firstBusSummary[@"effectStackHandle"] ?: @"";
                    fader[@"busEffectCount"] = @(allEffects.count);
                    fader[@"busEffectNames"] = allEffectNames;
                    fader[@"busEffects"] = allEffects;
                } else {
                    fader[@"busEffectCount"] = @0;
                    fader[@"busEffectNames"] = @[];
                    fader[@"busEffects"] = @[];
                }

                NSArray<NSString *> *roleUIDs = SpliceKit_mixerRoleUIDsForRole(allClips, role);
                NSUInteger mutedUIDCount = SpliceKit_mixerCountDisabledRoleUIDs(roleUIDs, disabledAudioRoleUIDs);
                fader[@"muted"] = @(roleUIDs.count > 0 && mutedUIDCount == roleUIDs.count);
                fader[@"muteMixed"] = @(mutedUIDCount > 0 && mutedUIDCount < roleUIDs.count);
                fader[@"mutedRoleUIDCount"] = @(mutedUIDCount);
                fader[@"roleUIDCount"] = @(roleUIDs.count);

                if (bestClip) {
                    // Active: clip with this role is at the playhead
                    fader[@"clipHandle"] = SpliceKit_storeHandle(bestClip);
                    fader[@"lane"] = @(bestLane);
                    fader[@"startSeconds"] = @(bestStart);
                    fader[@"endSeconds"] = @(bestEnd);
                    fader[@"class"] = NSStringFromClass([bestClip class]);
                    fader[@"playing"] = @YES;

                    if ([bestClip respondsToSelector:@selector(displayName)]) {
                        id name = ((id (*)(id, SEL))objc_msgSend)(bestClip, @selector(displayName));
                        fader[@"name"] = name ?: @"";
                    }

                    id es = SpliceKit_getClipEffectStack(bestClip);
                    if (es) fader[@"effectStackHandle"] = SpliceKit_storeHandle(es);
                    SpliceKit_readVolume(bestClip, es, fader);
                } else {
                    // Not playing: no clip at playhead, but show first clip with this role for info
                    fader[@"playing"] = @NO;
                    id firstClip = nil;
                    for (NSDictionary *clip in allClips) {
                        if ([clip[@"role"] isEqualToString:role]) {
                            firstClip = clip[@"item"];
                            fader[@"lane"] = clip[@"lane"];
                            break;
                        }
                    }
                    if (firstClip) {
                        fader[@"clipHandle"] = SpliceKit_storeHandle(firstClip);
                        if ([firstClip respondsToSelector:@selector(displayName)]) {
                            id name = ((id (*)(id, SEL))objc_msgSend)(firstClip, @selector(displayName));
                            fader[@"name"] = name ?: @"";
                        }
                        id es = SpliceKit_getClipEffectStack(firstClip);
                        if (es) fader[@"effectStackHandle"] = SpliceKit_storeHandle(es);
                        SpliceKit_readVolume(firstClip, es, fader);
                    } else {
                        fader[@"name"] = @"";
                        fader[@"lane"] = @(0);
                        fader[@"volumeDB"] = @(0);
                        fader[@"volumeLinear"] = @(1);
                    }
                }

                [indexed addObject:fader];
                faderIdx++;
            }

            if (toolSkimming && skimmedItem && skimmedRole.length == 0) {
                for (NSDictionary *clip in allClips) {
                    if (clip[@"item"] == skimmedItem) {
                        skimmedRole = clip[@"role"];
                        if (skimmedName.length == 0 && [clip[@"item"] respondsToSelector:@selector(displayName)]) {
                            id skimNameObj = ((id (*)(id, SEL))objc_msgSend)(clip[@"item"], @selector(displayName));
                            if ([skimNameObj isKindOfClass:[NSString class]]) {
                                skimmedName = skimNameObj;
                            }
                        }
                        break;
                    }
                }
            }

            if (!transportPlaying && toolSkimming && skimmedRole.length > 0) {
                for (NSMutableDictionary *fader in indexed) {
                    BOOL roleMatches = [fader[@"role"] isEqualToString:skimmedRole];
                    fader[@"playing"] = @(roleMatches);
                    if (roleMatches && skimmedName.length > 0) {
                        fader[@"name"] = skimmedName;
                    }
                }
            }

            BOOL meteringLive = NO;
            BOOL usedPlayerMetering = NO;
            BOOL usedLayerFallback = NO;
            double layerFallbackPeak = 0.0;
            BOOL playerMeteringEnabled = NO;

            // Audio metering: call FFPlayer.meterAudioLevelsForRole: directly.
            // The C++ FFAudioPlayer has a metering enable byte at offset 291 that gates
            // all level reporting. We flip it to 1 so metering works without the Audio
            // Meters panel being visible. Peak values are returned as linear amplitudes.
            @try {
                id player = nil;
                if ([timeline respondsToSelector:@selector(player)])
                    player = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(player));

                if (player && (transportPlaying || toolSkimming)) {
                    playerMeteringEnabled = YES;
                    // Enable metering on the C++ FFAudioPlayer (byte at offset 291)
                    Ivar apIvar = class_getInstanceVariable([player class], "_audioPlayer");
                    void *audioPlayer = NULL;
                    if (apIvar) {
                        audioPlayer = *(void **)((char *)(__bridge void *)player + ivar_getOffset(apIvar));
                        if (audioPlayer) {
                            *(uint8_t *)((char *)audioPlayer + 291) = 1;
                        }
                    }

                    SEL meterSel = NSSelectorFromString(@"meterAudioLevelsForRole:channels:peakValues:loudnessValues:");
                    typedef struct { float a, b, c, d; } LoudnessValues;

                    if ([player respondsToSelector:meterSel]) {
                        for (NSMutableDictionary *fader in indexed) {
                            id clipHandle = fader[@"clipHandle"];
                            id clip = clipHandle ? SpliceKit_resolveHandle(clipHandle) : nil;
                            if (!clip) continue;

                            NSMutableArray *candidates = [NSMutableArray array];
                            @try {
                                SEL ariSel = NSSelectorFromString(@"audioRoleIdentifier");
                                if ([clip respondsToSelector:ariSel]) {
                                    id ari = ((id (*)(id, SEL))objc_msgSend)(clip, ariSel);
                                    if (ari) [candidates addObject:ari];
                                }
                            } @catch (NSException *e) {}

                            NSString *roleName = fader[@"role"];
                            if (roleName) [candidates addObject:roleName];

                            float maxPeak = 0;
                            for (id roleUID in candidates) {
                                if (maxPeak > 0) break;
                                float peakValues[32] = {0};
                                LoudnessValues loudness = {0, 0, 0, 0};
                                @try {
                                    unsigned int filled = ((unsigned int (*)(id, SEL, id, unsigned int, float *, LoudnessValues *))objc_msgSend)(
                                        player, meterSel, roleUID, 32, peakValues, &loudness);
                                    for (unsigned int ch = 0; ch < filled && ch < 32; ch++) {
                                        if (peakValues[ch] > maxPeak) maxPeak = peakValues[ch];
                                    }
                                } @catch (NSException *e) {}
                            }

                            if (maxPeak > 0.0001) {
                                double dB = 20.0 * log10((double)maxPeak);
                                double ratio = (dB + 96.0) / 102.0;
                                if (ratio < 0) ratio = 0;
                                if (ratio > 1) ratio = 1;
                                fader[@"meterLinear"] = @(maxPeak);
                                fader[@"meterDB"] = @(dB);
                                fader[@"meterPeak"] = @(ratio);
                                fader[@"meterClipping"] = @((maxPeak >= 0.995f) || (dB >= -0.1));
                                meteringLive = YES;
                                usedPlayerMetering = YES;
                            }
                        }
                    }
                }
            } @catch (NSException *e) {}

            // Fallback: find PEMeterLayer instances anywhere in the CALayer tree.
            // This finds the mini audio meters in the transport bar (always visible)
            // as well as the full Audio Meters panel if open.
            @try {
                BOOL anyMeter = NO;
                for (NSDictionary *f in indexed) {
                    if ([f[@"meterPeak"] doubleValue] > 0.0001) {
                        anyMeter = YES;
                        break;
                    }
                }
                BOOL shouldUseLayerFallback = transportPlaying || toolSkimming;
                if (!anyMeter && shouldUseLayerFallback) {
                    Class mlc = NSClassFromString(@"PEMeterLayer");
                    Ivar mrIvar = mlc ? class_getInstanceVariable(mlc, "_maskRatio") : NULL;
                    if (mlc && mrIvar) {
                        ptrdiff_t off = ivar_getOffset(mrIvar);
                        double maxPeak = 0;

                        for (NSWindow *win in [NSApp windows]) {
                            if (!win.contentView) continue;
                            CALayer *rootLayer = win.contentView.layer;
                            if (rootLayer) {
                                SpliceKit_searchLayerTreeForMeterPeak(rootLayer, mlc, off, &maxPeak);
                            }
                            if (maxPeak > 0.001) break;
                        }

                        if (maxPeak > 0.001) {
                            usedLayerFallback = YES;
                            layerFallbackPeak = maxPeak;
                            if (!transportPlaying && toolSkimming) {
                                BOOL matchedSpecificSkimTarget = NO;
                                for (NSMutableDictionary *f in indexed) {
                                    BOOL roleMatches = NO;
                                    if (skimmedRole.length > 0) {
                                        roleMatches = [f[@"role"] isEqualToString:skimmedRole];
                                    } else if (skimmedName.length > 0) {
                                        roleMatches = [f[@"name"] isEqualToString:skimmedName];
                                    }
                                    if (roleMatches) matchedSpecificSkimTarget = YES;
                                    if (roleMatches) {
                                        f[@"meterPeak"] = @(maxPeak);
                                        f[@"meterLinear"] = @(maxPeak);
                                        f[@"meterDB"] = @((20.0 * log10(fmax(maxPeak, 0.000001))));
                                        f[@"meterClipping"] = @(maxPeak >= 0.98);
                                    } else {
                                        f[@"meterPeak"] = @(0.0);
                                        f[@"meterLinear"] = @(0.0);
                                        f[@"meterDB"] = @(-96.0);
                                        f[@"meterClipping"] = @NO;
                                    }
                                }
                                if (!matchedSpecificSkimTarget) {
                                    double totalVol = 0;
                                    for (NSMutableDictionary *f in indexed) {
                                        if ([f[@"playing"] boolValue]) totalVol += [f[@"volumeLinear"] doubleValue];
                                    }
                                    for (NSMutableDictionary *f in indexed) {
                                        if ([f[@"playing"] boolValue]) {
                                            double share = (totalVol > 0) ? [f[@"volumeLinear"] doubleValue] / totalVol : 1.0;
                                            double ratio = maxPeak * fmin(share * 1.5, 1.0);
                                            f[@"meterPeak"] = @(ratio);
                                            f[@"meterLinear"] = @(maxPeak);
                                            f[@"meterDB"] = @(ratio * 102.0 - 96.0);
                                            f[@"meterClipping"] = @(maxPeak >= 0.98);
                                        }
                                    }
                                }
                            } else {
                                double totalVol = 0;
                                for (NSMutableDictionary *f in indexed)
                                    if ([f[@"playing"] boolValue]) totalVol += [f[@"volumeLinear"] doubleValue];
                                for (NSMutableDictionary *f in indexed) {
                                    if ([f[@"playing"] boolValue]) {
                                        double share = (totalVol > 0) ? [f[@"volumeLinear"] doubleValue] / totalVol : 1.0;
                                        double ratio = maxPeak * fmin(share * 1.5, 1.0);
                                        f[@"meterPeak"] = @(ratio);
                                        f[@"meterLinear"] = @(maxPeak);
                                        f[@"meterDB"] = @(ratio * 102.0 - 96.0);
                                        f[@"meterClipping"] = @(maxPeak >= 0.98);
                                    }
                                }
                            }
                            meteringLive = YES;
                        }
                    }
                }
            } @catch (NSException *e) {}

            if (!meteringLive) {
                for (NSMutableDictionary *fader in indexed) {
                    fader[@"meterLinear"] = @(0.0);
                    fader[@"meterDB"] = @(-96.0);
                    fader[@"meterPeak"] = @(0.0);
                    fader[@"meterClipping"] = @NO;
                }
            }

            NSMutableDictionary *masterFader = nil;
            @try {
                id audioDest = SpliceKit_getMasterAudioDest();
                SEL outputVolumeSel = NSSelectorFromString(@"outputVolume");
                if (audioDest && [audioDest respondsToSelector:outputVolumeSel]) {
                    double masterLinear = ((float (*)(id, SEL))objc_msgSend)(audioDest, outputVolumeSel);
                    if (!isfinite(masterLinear) || masterLinear < 0.0) masterLinear = 0.0;
                    if (masterLinear > 1.0) masterLinear = 1.0;

                    double masterDB = (masterLinear > 0.000001) ? 20.0 * log10(masterLinear) : -96.0;
                    if (!isfinite(masterDB) || masterDB < -96.0) masterDB = -96.0;

                    double masterPeak = 0.0;
                    BOOL masterClipping = NO;
                    for (NSDictionary *fader in indexed) {
                        double peak = [fader[@"meterPeak"] doubleValue];
                        if (peak > masterPeak) masterPeak = peak;
                        if ([fader[@"meterClipping"] boolValue]) masterClipping = YES;
                    }

                    double masterMeterDB = masterPeak * 102.0 - 96.0;

                    masterFader = [@{
                        @"handle": SpliceKit_storeHandle(audioDest) ?: @"",
                        @"name": @"Playback",
                        @"role": @"Master",
                        @"volumeLinear": @(masterLinear),
                        @"volumeDB": @(masterDB),
                        @"minDB": @(-96.0),
                        @"maxDB": @(0.0),
                        @"meterLinear": @(masterPeak),
                        @"meterDB": @(masterMeterDB),
                        @"meterPeak": @(masterPeak),
                        @"meterClipping": @(masterClipping),
                        @"playing": @(transportPlaying || meteringLive)
                    } mutableCopy];
                }
            } @catch (NSException *e) {}

            NSMutableDictionary *payload = [@{
                @"playheadSeconds": @(playheadSec),
                @"playheadTime": SpliceKit_serializeCMTime(playhead),
                @"isPlaying": @(transportPlaying),
                @"isMeteringLive": @(meteringLive),
                @"playbackRate": @(transportRate),
                @"frameRate": @(frameRate),
                @"faders": indexed,
                @"count": @(indexed.count),
                @"maxFaders": @(maxFaders),
                @"totalRoles": @(roleOrder.count),
                @"roles": [roleOrder array],
                @"soloActive": @(soloActive),
                @"soloObjectCount": @(soloedObjects.count),
                @"mutedRoleUIDCount": @(disabledAudioRoleUIDs.count)
            } mutableCopy];
            NSMutableArray *resolvedClipPreview = [NSMutableArray array];
            NSUInteger previewCount = MIN((NSUInteger)20, allClips.count);
            for (NSUInteger i = 0; i < previewCount; i++) {
                NSDictionary *clipInfo = allClips[i];
                id clip = clipInfo[@"item"];
                NSString *name = @"";
                @try {
                    if ([clip respondsToSelector:@selector(displayName)]) {
                        id nameObj = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
                        if ([nameObj isKindOfClass:[NSString class]]) name = nameObj;
                    }
                } @catch (NSException *e) {}
                [resolvedClipPreview addObject:@{
                    @"class": NSStringFromClass([clip class]) ?: @"",
                    @"name": name ?: @"",
                    @"role": clipInfo[@"role"] ?: @"",
                    @"rawRoleUID": SpliceKit_rawClipRoleUID(clip) ?: @"",
                    @"lane": clipInfo[@"lane"] ?: @(0),
                    @"start": clipInfo[@"start"] ?: @(0),
                    @"end": clipInfo[@"end"] ?: @(0),
                }];
            }

            NSMutableDictionary *debugPayload = [@{
                @"buildStamp": [NSString stringWithFormat:@"%s %s", __DATE__, __TIME__],
                @"maxFaders": @(maxFaders),
                @"handleCount": @(sHandleMap.count),
                @"resolvedClipCount": @(allClips.count),
                @"resolvedClipPreview": resolvedClipPreview,
                @"toolSkimming": @(toolSkimming),
                @"rawToolSkimming": @(rawToolSkimming),
                @"latchedSkimming": @(sMixerSkimmingLatched),
                @"skimmedRole": skimmedRole ?: @"",
                @"skimmedName": skimmedName ?: @"",
                @"skimmedItemClass": skimmedItem ? NSStringFromClass([skimmedItem class]) : @"",
                @"activeTimeSeconds": @(activeTimeSec),
                @"transportPlaying": @(transportPlaying),
                @"playbackRate": @(transportRate),
                @"meteringLive": @(meteringLive),
                @"playerMeteringEnabled": @(playerMeteringEnabled),
                @"usedPlayerMetering": @(usedPlayerMetering),
                @"usedLayerFallback": @(usedLayerFallback),
                @"layerFallbackPeak": @(layerFallbackPeak),
                @"secondsSinceSkimBegin": @(sMixerLastSkimBeginTime > 0 ? CFAbsoluteTimeGetCurrent() - sMixerLastSkimBeginTime : -1),
                @"secondsSinceSkimEnd": @(sMixerLastSkimEndTime > 0 ? CFAbsoluteTimeGetCurrent() - sMixerLastSkimEndTime : -1),
                @"secondsSinceSkimUpdate": @(sMixerLastSkimUpdateTime > 0 ? CFAbsoluteTimeGetCurrent() - sMixerLastSkimUpdateTime : -1),
            } mutableCopy];
            debugPayload[@"recentStates"] = SpliceKit_mixerRecordDebugState(debugPayload);
            payload[@"debug"] = debugPayload;
            if (masterFader) payload[@"masterFader"] = masterFader;
            result = payload;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

// mixer.setVolume — set volume on a specific channel handle
NSDictionary *SpliceKit_handleMixerSetVolume(NSDictionary *params) {
    NSString *handle = params[@"handle"];
    if (!handle) return @{@"error": @"handle parameter required (volumeChannelHandle from mixer.getState)"};

    // Accept either dB or linear
    NSNumber *dbVal = params[@"volumeDB"];
    NSNumber *linearVal = params[@"volumeLinear"];
    if (!dbVal && !linearVal) return @{@"error": @"volumeDB or volumeLinear parameter required"};

    double linear;
    if (linearVal) {
        linear = [linearVal doubleValue];
    } else {
        double db = [dbVal doubleValue];
        linear = (db <= -144.0) ? 0.0 : pow(10.0, db / 20.0);
    }

    // Clamp to FCP's valid range (0.0 to ~12 dB = ~3.98)
    if (linear < 0.0) linear = 0.0;
    if (linear > 3.98) linear = 3.98;

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id channel = SpliceKit_resolveHandle(handle);
            if (!channel) {
                result = @{@"error": @"Handle not found — clip may have changed. Call mixer.getState to refresh."};
                return;
            }

            SpliceKit_removeChannelKeyframes(channel);

            BOOL ok = SpliceKit_mixerSetStaticChannelValue(channel, linear);
            if (ok) {
                double readback = SpliceKit_channelValue(channel);
                result = @{
                    @"ok": @YES,
                    @"volumeLinear": @(readback),
                    @"volumeDB": SpliceKit_mixerJSONDBNumberFromLinear(readback, -96.0)
                };
            } else {
                result = @{@"error": @"Failed to set channel value"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

// mixer.setSolo — solo role faders by writing FCP's native sequence solo set
NSDictionary *SpliceKit_handleMixerSetSolo(NSDictionary *params) {
    NSString *mode = [params[@"mode"] isKindOfClass:[NSString class]] ? params[@"mode"] : @"toggle";

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            id sequence = nil;
            id rootObject = nil;
            NSMutableArray *allClips = nil;
            NSMutableOrderedSet *roleOrder = nil;
            NSString *snapshotError = nil;
            if (!SpliceKit_mixerBuildRoleSnapshot(timeline, &sequence, &rootObject, &allClips, &roleOrder, &snapshotError)) {
                result = @{@"error": snapshotError ?: @"Unable to inspect mixer roles"};
                return;
            }

            SEL setSoloedSel = NSSelectorFromString(@"setSoloedObjects:");
            if (![sequence respondsToSelector:setSoloedSel]) {
                result = @{@"error": @"FCP sequence does not expose solo controls"};
                return;
            }

            if ([mode isEqualToString:@"clear"]) {
                ((void (*)(id, SEL, id))objc_msgSend)(sequence, setSoloedSel, nil);
                result = @{
                    @"ok": @YES,
                    @"mode": mode,
                    @"soloed": @NO,
                    @"soloActive": @NO,
                    @"soloObjectCount": @(0)
                };
                return;
            }

            NSInteger index = NSNotFound;
            NSString *role = SpliceKit_mixerRoleFromParams(params, roleOrder, &index);
            if (role.length == 0) {
                result = @{@"error": @"role or index parameter required"};
                return;
            }

            NSArray *roleObjects = SpliceKit_mixerObjectsForRole(allClips, role);
            if (roleObjects.count == 0) {
                result = @{@"error": @"No timeline objects found for this mixer role"};
                return;
            }

            NSSet *currentSoloed = SpliceKit_mixerSoloedObjects(sequence) ?: [NSSet set];
            NSMutableSet *nextSoloed = [NSMutableSet setWithSet:currentSoloed];
            BOOL currentlySoloed = SpliceKit_mixerSetIntersectsObjects(currentSoloed, roleObjects);

            BOOL hasExplicitSolo = (params[@"solo"] != nil);
            BOOL targetSoloed = hasExplicitSolo ? [params[@"solo"] boolValue] : !currentlySoloed;
            if ([mode isEqualToString:@"add"]) {
                targetSoloed = YES;
            } else if ([mode isEqualToString:@"remove"]) {
                targetSoloed = NO;
            } else if ([mode isEqualToString:@"exclusive"]) {
                if (!hasExplicitSolo) targetSoloed = YES;
                [nextSoloed removeAllObjects];
            } else if (![mode isEqualToString:@"toggle"]) {
                result = @{@"error": @"mode must be toggle, exclusive, add, remove, or clear"};
                return;
            }

            if (targetSoloed) {
                [nextSoloed addObjectsFromArray:roleObjects];
            } else {
                [nextSoloed minusSet:[NSSet setWithArray:roleObjects]];
            }

            NSSet *nextSet = nextSoloed.count > 0 ? [NSSet setWithSet:nextSoloed] : nil;
            ((void (*)(id, SEL, id))objc_msgSend)(sequence, setSoloedSel, nextSet);

            BOOL roleSoloed = SpliceKit_mixerSetIntersectsObjects(nextSet, roleObjects);
            result = @{
                @"ok": @YES,
                @"mode": mode,
                @"role": role,
                @"index": @(index),
                @"soloed": @(roleSoloed),
                @"soloActive": @(nextSet.count > 0),
                @"roleObjectCount": @(roleObjects.count),
                @"soloObjectCount": @(nextSet.count)
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

// mixer.setMute — mute role faders through FCP's disabled audio-role playback map
NSDictionary *SpliceKit_handleMixerSetMute(NSDictionary *params) {
    NSString *mode = [params[@"mode"] isKindOfClass:[NSString class]] ? params[@"mode"] : @"toggle";

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            id sequence = nil;
            id rootObject = nil;
            NSMutableArray *allClips = nil;
            NSMutableOrderedSet *roleOrder = nil;
            NSString *snapshotError = nil;
            if (!SpliceKit_mixerBuildRoleSnapshot(timeline, &sequence, &rootObject, &allClips, &roleOrder, &snapshotError)) {
                result = @{@"error": snapshotError ?: @"Unable to inspect mixer roles"};
                return;
            }

            id playbackRoot = rootObject ? rootObject : sequence;

            if ([mode isEqualToString:@"clear"]) {
                NSMutableOrderedSet *allRoleUIDs = [NSMutableOrderedSet orderedSet];
                for (NSString *role in roleOrder) {
                    [allRoleUIDs addObjectsFromArray:SpliceKit_mixerRoleUIDsForRole(allClips, role)];
                }
                if (allRoleUIDs.count > 0) {
                    NSString *setError = nil;
                    BOOL ok = SpliceKit_mixerSetAudioRolesEnabled(
                        playbackRoot, sequence, [NSSet setWithArray:[allRoleUIDs array]], YES, &setError);
                    if (!ok) {
                        result = @{@"error": setError ?: @"Failed to clear mixer role mutes"};
                        return;
                    }
                }
                result = @{
                    @"ok": @YES,
                    @"mode": mode,
                    @"muted": @NO,
                    @"roleUIDCount": @(allRoleUIDs.count)
                };
                return;
            }

            NSInteger index = NSNotFound;
            NSString *role = SpliceKit_mixerRoleFromParams(params, roleOrder, &index);
            if (role.length == 0) {
                result = @{@"error": @"role or index parameter required"};
                return;
            }

            NSArray<NSString *> *roleUIDs = SpliceKit_mixerRoleUIDsForRole(allClips, role);
            if (roleUIDs.count == 0) {
                result = @{@"error": @"No audio role UIDs found for this mixer fader"};
                return;
            }

            NSSet *disabledAudioRoleUIDs = SpliceKit_mixerDisabledAudioRoleUIDsForRootObject(rootObject, sequence);
            NSUInteger mutedUIDCount = SpliceKit_mixerCountDisabledRoleUIDs(roleUIDs, disabledAudioRoleUIDs);
            BOOL currentlyMuted = (roleUIDs.count > 0 && mutedUIDCount == roleUIDs.count);

            BOOL hasExplicitMuted = (params[@"muted"] != nil);
            BOOL targetMuted = hasExplicitMuted ? [params[@"muted"] boolValue] : !currentlyMuted;
            if ([mode isEqualToString:@"mute"]) {
                targetMuted = YES;
            } else if ([mode isEqualToString:@"unmute"]) {
                targetMuted = NO;
            } else if (![mode isEqualToString:@"toggle"]) {
                result = @{@"error": @"mode must be toggle, mute, unmute, or clear"};
                return;
            }

            NSString *setError = nil;
            BOOL ok = SpliceKit_mixerSetAudioRolesEnabled(
                playbackRoot, sequence, [NSSet setWithArray:roleUIDs], !targetMuted, &setError);
            if (!ok) {
                result = @{@"error": setError ?: @"Failed to update mixer role mute"};
                return;
            }

            result = @{
                @"ok": @YES,
                @"mode": mode,
                @"role": role,
                @"index": @(index),
                @"muted": @(targetMuted),
                @"roleUIDCount": @(roleUIDs.count)
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
	    return result;
}

// mixer.applyBusEffect — add an audio effect to the collection-backed bus for a role.
// This mirrors FCP's compound-clip behavior: audio on child items flows through the
// parent FFAnchoredCollection.localAudioEffects stack, so the effect is shared after
// the role's contained audio has been grouped by that collection.
NSDictionary *SpliceKit_handleMixerApplyBusEffect(NSDictionary *params) {
    NSString *effectID = [params[@"effectID"] isKindOfClass:[NSString class]] ? params[@"effectID"] : nil;
    NSString *name = [params[@"name"] isKindOfClass:[NSString class]] ? params[@"name"] : nil;
    BOOL dryRun = [params[@"dryRun"] boolValue];
    BOOL allowObjectFallback = [params[@"allowObjectFallback"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            id sequence = nil;
            id rootObject = nil;
            NSMutableArray *allClips = nil;
            NSMutableOrderedSet *roleOrder = nil;
            NSString *snapshotError = nil;
            if (!SpliceKit_mixerBuildRoleSnapshot(timeline, &sequence, &rootObject, &allClips, &roleOrder, &snapshotError)) {
                result = @{@"error": snapshotError ?: @"Unable to inspect mixer roles"};
                return;
            }

            NSInteger index = NSNotFound;
            NSString *role = SpliceKit_mixerRoleFromParams(params, roleOrder, &index);
            if (role.length == 0) {
                result = @{@"error": @"role or index parameter required"};
                return;
            }

            NSDictionary *effect = SpliceKit_resolveEffectDescriptor(effectID, name, @"effect.audio.effect");
            if (effect[@"error"]) {
                result = effect;
                return;
            }

            NSArray *roleObjects = SpliceKit_mixerObjectsForRole(allClips, role);
            if (roleObjects.count == 0) {
                result = @{@"error": @"No timeline objects found for this mixer role"};
                return;
            }

            NSArray<NSDictionary *> *busTargets = SpliceKit_mixerBusTargetsForRoleObjects(roleObjects, allowObjectFallback);
            if (busTargets.count == 0) {
                result = @{
                    @"error": allowObjectFallback
                        ? @"No audio effect stack found for this mixer role"
                        : @"No collection-backed bus found for this mixer role. This first bus path requires a role-bearing collection or compound clip.",
                    @"role": role,
                    @"roleObjectCount": @(roleObjects.count),
                };
                return;
            }

            NSMutableArray *targetObjects = [NSMutableArray arrayWithCapacity:busTargets.count];
            NSMutableArray *beforeSummaries = [NSMutableArray arrayWithCapacity:busTargets.count];
            for (NSDictionary *target in busTargets) {
                id object = target[@"object"];
                id stack = target[@"effectStack"];
                if (object) [targetObjects addObject:object];
                [beforeSummaries addObject:SpliceKit_mixerBusTargetSummary(object, stack)];
            }

            if (dryRun) {
                result = @{
                    @"ok": @YES,
                    @"dryRun": @YES,
                    @"role": role,
                    @"index": @(index),
                    @"effect": effect,
                    @"busMode": allowObjectFallback ? @"objectFallback" : @"collection",
                    @"busObjectCount": @(busTargets.count),
                    @"targets": beforeSummaries,
                };
                return;
            }

            NSString *scopeKey = SpliceKit_mixerManagedBusScopeKey(sequence, rootObject);
            NSMutableDictionary *managedEntry = SpliceKit_mixerNewManagedBusEntry(role, scopeKey, effect);
            NSMutableDictionary<NSString *, NSNumber *> *beforeCountsByObject = [NSMutableDictionary dictionary];
            for (NSDictionary *target in busTargets) {
                id object = target[@"object"];
                id stack = target[@"effectStack"];
                NSString *objectKey = SpliceKit_handlePointerKey(object);
                if (objectKey.length > 0) {
                    beforeCountsByObject[objectKey] = @(SpliceKit_mixerEffectsInStack(stack).count);
                }
            }

            NSString *applyError = nil;
            BOOL ok = SpliceKit_mixerApplyAudioEffectIDToObjects(effect[@"effectID"], targetObjects, &applyError);
            if (!ok) {
                NSMutableArray *entries = SpliceKit_mixerManagedBusEntriesForRole(role, NO);
                [entries removeObject:managedEntry];
                result = @{
                    @"error": applyError ?: [NSString stringWithFormat:@"Failed to apply audio bus effect '%@'",
                                             effect[@"name"] ?: effect[@"effectID"]],
                    @"role": role,
                    @"effect": effect,
                };
                return;
            }

            NSMutableArray *afterSummaries = [NSMutableArray arrayWithCapacity:busTargets.count];
            for (NSDictionary *target in busTargets) {
                id object = target[@"object"];
                NSString *objectKey = SpliceKit_handlePointerKey(object);
                NSUInteger beforeCount = objectKey.length > 0 ? [beforeCountsByObject[objectKey] unsignedIntegerValue] : 0;
                SpliceKit_mixerCaptureManagedInstanceAfterApply(managedEntry, object, beforeCount);
                SpliceKit_mixerUpdateObjectAfterBusEffectMutation(object);
                [afterSummaries addObject:SpliceKit_mixerBusTargetSummary(object, target[@"effectStack"])];
            }

            result = @{
                @"ok": @YES,
                @"role": role,
                @"index": @(index),
                @"effect": effect,
                @"busEffectID": managedEntry[@"busEffectID"] ?: @"",
                @"busMode": allowObjectFallback ? @"objectFallback" : @"collection",
                @"busObjectCount": @(busTargets.count),
                @"beforeTargets": beforeSummaries,
                @"targets": afterSummaries,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to apply mixer bus effect"};
}

static id SpliceKit_mixerTimelineContext(void) {
    @try {
        Class selMgr = objc_getClass("PESelectionManager");
        id manager = selMgr ? ((id (*)(id, SEL))objc_msgSend)((id)selMgr, @selector(defaultSelectionManager)) : nil;
        if (manager && [manager respondsToSelector:@selector(timelineContext)]) {
            return ((id (*)(id, SEL))objc_msgSend)(manager, @selector(timelineContext));
        }
    } @catch (NSException *e) {}
    return nil;
}

static id SpliceKit_mixerEffectAtIndex(id effectStack, NSInteger effectIndex) {
    if (effectIndex < 0) return nil;
    NSArray *effects = SpliceKit_mixerEffectsInStack(effectStack);
    if ((NSUInteger)effectIndex >= effects.count) return nil;
    return effects[(NSUInteger)effectIndex];
}

static id SpliceKit_mixerEffectStackForEffect(id effect) {
    if (!effect) return nil;
    @try {
        SEL effectStackSel = NSSelectorFromString(@"effectStack");
        if ([effect respondsToSelector:effectStackSel]) {
            return ((id (*)(id, SEL))objc_msgSend)(effect, effectStackSel);
        }
    } @catch (NSException *e) {}
    return nil;
}

static NSInteger SpliceKit_mixerIndexOfEffectInStack(id effectStack, id effect) {
    if (!effectStack || !effect) return NSNotFound;
    NSArray *effects = SpliceKit_mixerEffectsInStack(effectStack);
    for (NSUInteger idx = 0; idx < effects.count; idx++) {
        if (effects[idx] == effect) return (NSInteger)idx;
    }
    return NSNotFound;
}

static BOOL SpliceKit_mixerResolveEffectHandleParams(NSDictionary *params,
                                                     id *outEffect,
                                                     id *outStack,
                                                     NSInteger *outIndex,
                                                     NSString **outError) {
    NSString *effectHandle = [params[@"effectHandle"] isKindOfClass:[NSString class]] ? params[@"effectHandle"] : @"";
    if (effectHandle.length == 0) return NO;

    id effect = SpliceKit_resolveHandle(effectHandle);
    if (!effect) {
        if (outError) *outError = [NSString stringWithFormat:@"Effect handle not found: %@", effectHandle];
        return YES;
    }

    NSString *stackHandle = [params[@"effectStackHandle"] isKindOfClass:[NSString class]] ? params[@"effectStackHandle"] : @"";
    id stack = stackHandle.length > 0 ? SpliceKit_resolveHandle(stackHandle) : nil;
    if (!stack) stack = SpliceKit_mixerEffectStackForEffect(effect);
    if (!stack) {
        if (outError) *outError = @"Unable to resolve effect stack for effect handle";
        return YES;
    }

    NSInteger effectIndex = NSNotFound;
    NSNumber *effectIndexNumber = [params[@"effectIndex"] isKindOfClass:[NSNumber class]] ? params[@"effectIndex"] : nil;
    if (effectIndexNumber) effectIndex = [effectIndexNumber integerValue];
    if (effectIndex == NSNotFound) effectIndex = SpliceKit_mixerIndexOfEffectInStack(stack, effect);

    if (outEffect) *outEffect = effect;
    if (outStack) *outStack = stack;
    if (outIndex) *outIndex = effectIndex;
    return YES;
}

static BOOL SpliceKit_mixerBusTargetsFromParams(NSDictionary *params,
                                                BOOL allowObjectFallback,
                                                NSString **outRole,
                                                NSInteger *outIndex,
                                                NSArray<NSDictionary *> **outBusTargets,
                                                NSString **outError) {
    id timeline = SpliceKit_getActiveTimelineModule();
    id sequence = nil;
    id rootObject = nil;
    NSMutableArray *allClips = nil;
    NSMutableOrderedSet *roleOrder = nil;
    NSString *snapshotError = nil;
    if (!SpliceKit_mixerBuildRoleSnapshot(timeline, &sequence, &rootObject, &allClips, &roleOrder, &snapshotError)) {
        if (outError) *outError = snapshotError ?: @"Unable to inspect mixer roles";
        return NO;
    }

    NSInteger index = NSNotFound;
    NSString *role = SpliceKit_mixerRoleFromParams(params, roleOrder, &index);
    if (role.length == 0) {
        if (outError) *outError = @"role or index parameter required";
        return NO;
    }

    NSArray *roleObjects = SpliceKit_mixerObjectsForRole(allClips, role);
    if (roleObjects.count == 0) {
        if (outError) *outError = @"No timeline objects found for this mixer role";
        return NO;
    }

    NSArray<NSDictionary *> *busTargets = SpliceKit_mixerBusTargetsForRoleObjects(roleObjects, allowObjectFallback);
    if (busTargets.count == 0) {
        if (outError) *outError = allowObjectFallback
            ? @"No audio effect stack found for this mixer role"
            : @"No collection-backed bus found for this mixer role";
        return NO;
    }

    if (outRole) *outRole = role;
    if (outIndex) *outIndex = index;
    if (outBusTargets) *outBusTargets = busTargets;
    return YES;
}

static NSArray<NSDictionary *> *SpliceKit_mixerCurrentBusTargetsForManagedEntry(NSMutableDictionary *entry,
                                                                                NSString *role,
                                                                                BOOL allowObjectFallback,
                                                                                NSString **outError) {
    if (!entry || role.length == 0) {
        if (outError) *outError = @"Managed bus effect is missing its role";
        return nil;
    }

    id timeline = SpliceKit_getActiveTimelineModule();
    id sequence = nil;
    id rootObject = nil;
    NSMutableArray *allClips = nil;
    NSMutableOrderedSet *roleOrder = nil;
    NSString *snapshotError = nil;
    if (!SpliceKit_mixerBuildRoleSnapshot(timeline, &sequence, &rootObject, &allClips, &roleOrder, &snapshotError)) {
        if (outError) *outError = snapshotError ?: @"Unable to inspect mixer roles";
        return nil;
    }

    NSString *entryScope = [entry[@"scopeKey"] isKindOfClass:[NSString class]] ? entry[@"scopeKey"] : @"";
    NSString *currentScope = SpliceKit_mixerManagedBusScopeKey(sequence, rootObject);
    if (entryScope.length > 0 && currentScope.length > 0 && ![entryScope isEqualToString:currentScope]) {
        if (outError) *outError = @"Managed bus effect belongs to a different timeline";
        return nil;
    }

    NSArray *roleObjects = SpliceKit_mixerObjectsForRole(allClips, role);
    if (roleObjects.count == 0) {
        if (outError) *outError = @"No timeline objects found for this managed bus role";
        return nil;
    }

    NSArray<NSDictionary *> *busTargets = SpliceKit_mixerBusTargetsForRoleObjects(roleObjects, allowObjectFallback);
    if (busTargets.count == 0) {
        if (outError) *outError = allowObjectFallback
            ? @"No audio effect stack found for this managed bus role"
            : @"No collection-backed bus found for this managed bus role";
        return nil;
    }

    return busTargets;
}

NSDictionary *SpliceKit_handleMixerSetBusEffectEnabled(NSDictionary *params) {
    NSNumber *effectIndexNumber = [params[@"effectIndex"] isKindOfClass:[NSNumber class]] ? params[@"effectIndex"] : nil;
    NSString *busEffectID = [params[@"busEffectID"] isKindOfClass:[NSString class]] ? params[@"busEffectID"] : @"";
    if (!effectIndexNumber && busEffectID.length == 0) return @{@"error": @"effectIndex or busEffectID parameter required"};
    if (!params[@"enabled"]) return @{@"error": @"enabled parameter required"};
    NSInteger effectIndex = effectIndexNumber ? [effectIndexNumber integerValue] : NSNotFound;
    BOOL enabled = [params[@"enabled"] boolValue];
    BOOL allowObjectFallback = [params[@"allowObjectFallback"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSString *role = nil;
            NSInteger index = NSNotFound;
            NSArray<NSDictionary *> *busTargets = nil;
            NSString *error = nil;
            id handleEffect = nil;
            id handleStack = nil;
            NSInteger handleEffectIndex = NSNotFound;
            if (busEffectID.length > 0) {
                NSString *managedRole = nil;
                NSUInteger managedIndex = NSNotFound;
                NSMutableDictionary *entry = SpliceKit_mixerManagedBusEntryForID(busEffectID, &managedRole, &managedIndex);
                if (!entry) {
                    result = @{@"error": @"Managed bus effect not found", @"busEffectID": busEffectID};
                    return;
                }

                entry[@"enabled"] = @(enabled);
                NSMutableArray *updated = [NSMutableArray array];
                NSString *managedTargetError = nil;
                NSArray<NSDictionary *> *managedTargets = SpliceKit_mixerCurrentBusTargetsForManagedEntry(
                    entry, managedRole, allowObjectFallback, &managedTargetError);
                if (!managedTargets) {
                    result = @{@"error": managedTargetError ?: @"Unable to resolve managed bus targets"};
                    return;
                }

                for (NSDictionary *target in managedTargets) {
                    id object = target[@"object"];
                    id stack = nil;
                    NSInteger trackedIndex = NSNotFound;
                    id effect = SpliceKit_mixerTrackedEffectForObject(entry, object, &stack, &trackedIndex);
                    if (!effect || !stack) continue;
                    if (SpliceKit_mixerSetEffectEnabledInStack(effect, stack, enabled)) {
                        [updated addObject:SpliceKit_mixerBusTargetSummary(object, stack)];
                    }
                }

                result = @{
                    @"ok": @YES,
                    @"role": managedRole ?: @"",
                    @"index": managedIndex == NSNotFound ? @(-1) : @(managedIndex),
                    @"busEffectID": busEffectID,
                    @"enabled": @(enabled),
                    @"busObjectCount": @(updated.count),
                    @"targets": updated,
                };
                return;
            }

            if (SpliceKit_mixerResolveEffectHandleParams(params, &handleEffect, &handleStack, &handleEffectIndex, &error)) {
                if (!handleEffect || !handleStack) {
                    result = @{@"error": error ?: @"Unable to resolve mixer bus effect handle"};
                    return;
                }

                if (!SpliceKit_mixerSetEffectEnabledInStack(handleEffect, handleStack, enabled)) {
                    result = @{@"error": @"Resolved effect does not support enabling/disabling"};
                    return;
                }

                result = @{
                    @"ok": @YES,
                    @"effectIndex": @(handleEffectIndex),
                    @"enabled": @(enabled),
                    @"busObjectCount": @1,
                    @"effect": SpliceKit_mixerEffectSummary(handleEffect,
                                                            handleEffectIndex == NSNotFound ? 0 : (NSUInteger)handleEffectIndex),
                    @"targets": @[SpliceKit_mixerBusTargetSummary(nil, handleStack)],
                };
                return;
            }

            if (!SpliceKit_mixerBusTargetsFromParams(params, allowObjectFallback, &role, &index, &busTargets, &error)) {
                result = @{@"error": error ?: @"Unable to resolve mixer bus"};
                return;
            }

            NSUInteger managedIndex = NSNotFound;
            NSMutableDictionary *managedEntry = SpliceKit_mixerManagedBusEntryForRoleDisplayIndex(role, effectIndex, &managedIndex);
            if (managedEntry) {
                managedEntry[@"enabled"] = @(enabled);
                NSMutableArray *updated = [NSMutableArray array];
                NSString *managedTargetError = nil;
                NSArray<NSDictionary *> *managedTargets = SpliceKit_mixerCurrentBusTargetsForManagedEntry(
                    managedEntry, role, allowObjectFallback, &managedTargetError);
                if (!managedTargets) {
                    result = @{@"error": managedTargetError ?: @"Unable to resolve managed bus targets"};
                    return;
                }

                for (NSDictionary *target in managedTargets) {
                    id object = target[@"object"];
                    id stack = nil;
                    NSInteger trackedIndex = NSNotFound;
                    id effect = SpliceKit_mixerTrackedEffectForObject(managedEntry, object, &stack, &trackedIndex);
                    if (!effect || !stack) continue;
                    if (SpliceKit_mixerSetEffectEnabledInStack(effect, stack, enabled)) {
                        [updated addObject:SpliceKit_mixerBusTargetSummary(object, stack)];
                    }
                }

                result = @{
                    @"ok": @YES,
                    @"role": role ?: @"",
                    @"index": managedIndex == NSNotFound ? @(-1) : @(managedIndex),
                    @"busEffectID": [managedEntry[@"busEffectID"] isKindOfClass:[NSString class]] ? managedEntry[@"busEffectID"] : @"",
                    @"enabled": @(enabled),
                    @"busObjectCount": @(updated.count),
                    @"targets": updated,
                };
                return;
            }

            NSMutableArray *updated = [NSMutableArray array];
            for (NSDictionary *target in busTargets) {
                id stack = target[@"effectStack"];
                id effect = SpliceKit_mixerEffectAtIndex(stack, effectIndex);
                if (!stack || !effect) continue;

                if (SpliceKit_mixerSetEffectEnabledInStack(effect, stack, enabled)) {
                    [updated addObject:SpliceKit_mixerBusTargetSummary(target[@"object"], stack)];
                }
            }

            if (updated.count == 0) {
                result = @{@"error": @"No bus effect found at that index", @"effectIndex": @(effectIndex)};
                return;
            }

            result = @{
                @"ok": @YES,
                @"role": role,
                @"index": @(index),
                @"effectIndex": @(effectIndex),
                @"enabled": @(enabled),
                @"busObjectCount": @(updated.count),
                @"targets": updated,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to set mixer bus effect enabled state"};
}

NSDictionary *SpliceKit_handleMixerRemoveBusEffect(NSDictionary *params) {
    NSNumber *effectIndexNumber = [params[@"effectIndex"] isKindOfClass:[NSNumber class]] ? params[@"effectIndex"] : nil;
    NSString *busEffectID = [params[@"busEffectID"] isKindOfClass:[NSString class]] ? params[@"busEffectID"] : @"";
    if (!effectIndexNumber && busEffectID.length == 0) return @{@"error": @"effectIndex or busEffectID parameter required"};
    NSInteger effectIndex = effectIndexNumber ? [effectIndexNumber integerValue] : NSNotFound;
    BOOL allowObjectFallback = [params[@"allowObjectFallback"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSString *role = nil;
            NSInteger index = NSNotFound;
            NSArray<NSDictionary *> *busTargets = nil;
            NSString *error = nil;
            id handleEffect = nil;
            id handleStack = nil;
            NSInteger handleEffectIndex = NSNotFound;
            if (busEffectID.length > 0) {
                NSString *managedRole = nil;
                NSUInteger managedIndex = NSNotFound;
                NSMutableDictionary *entry = SpliceKit_mixerManagedBusEntryForID(busEffectID, &managedRole, &managedIndex);
                if (!entry) {
                    result = @{@"error": @"Managed bus effect not found", @"busEffectID": busEffectID};
                    return;
                }

                NSMutableArray *updated = [NSMutableArray array];
                NSString *managedTargetError = nil;
                NSArray<NSDictionary *> *managedTargets = SpliceKit_mixerCurrentBusTargetsForManagedEntry(
                    entry, managedRole, allowObjectFallback, &managedTargetError);
                if (!managedTargets) {
                    result = @{@"error": managedTargetError ?: @"Unable to resolve managed bus targets"};
                    return;
                }

                for (NSDictionary *target in managedTargets) {
                    id object = target[@"object"];
                    id stack = nil;
                    NSInteger trackedIndex = NSNotFound;
                    id effect = SpliceKit_mixerTrackedEffectForObject(entry, object, &stack, &trackedIndex);
                    if (stack && effect && trackedIndex != NSNotFound &&
                        SpliceKit_mixerRemoveEffectFromStackAtIndex(stack, trackedIndex)) {
                        [updated addObject:SpliceKit_mixerBusTargetSummary(object, stack)];
                    }
                    SpliceKit_mixerUpdateObjectAfterBusEffectMutation(object);
                }

                NSMutableArray *entries = SpliceKit_mixerManagedBusEntriesForRole(managedRole, NO);
                [entries removeObject:entry];
                SpliceKit_mixerPruneManagedBusRole(managedRole);

                result = @{
                    @"ok": @YES,
                    @"role": managedRole ?: @"",
                    @"index": managedIndex == NSNotFound ? @(-1) : @(managedIndex),
                    @"busEffectID": busEffectID,
                    @"busObjectCount": @(updated.count),
                    @"targets": updated,
                };
                return;
            }

            if (SpliceKit_mixerResolveEffectHandleParams(params, &handleEffect, &handleStack, &handleEffectIndex, &error)) {
                if (!handleEffect || !handleStack) {
                    result = @{@"error": error ?: @"Unable to resolve mixer bus effect handle"};
                    return;
                }
                if (handleEffectIndex == NSNotFound) {
                    result = @{@"error": @"Unable to locate effect in its stack"};
                    return;
                }

                if (!SpliceKit_mixerRemoveEffectFromStackAtIndex(handleStack, handleEffectIndex)) {
                    result = @{@"error": @"Failed to remove resolved mixer bus effect"};
                    return;
                }

                result = @{
                    @"ok": @YES,
                    @"effectIndex": @(handleEffectIndex),
                    @"busObjectCount": @1,
                    @"targets": @[SpliceKit_mixerBusTargetSummary(nil, handleStack)],
                };
                return;
            }

            if (!SpliceKit_mixerBusTargetsFromParams(params, allowObjectFallback, &role, &index, &busTargets, &error)) {
                result = @{@"error": error ?: @"Unable to resolve mixer bus"};
                return;
            }

            NSUInteger managedIndex = NSNotFound;
            NSMutableDictionary *managedEntry = SpliceKit_mixerManagedBusEntryForRoleDisplayIndex(role, effectIndex, &managedIndex);
            if (managedEntry) {
                NSMutableArray *updated = [NSMutableArray array];
                NSString *managedTargetError = nil;
                NSArray<NSDictionary *> *managedTargets = SpliceKit_mixerCurrentBusTargetsForManagedEntry(
                    managedEntry, role, allowObjectFallback, &managedTargetError);
                if (!managedTargets) {
                    result = @{@"error": managedTargetError ?: @"Unable to resolve managed bus targets"};
                    return;
                }

                for (NSDictionary *target in managedTargets) {
                    id object = target[@"object"];
                    id stack = nil;
                    NSInteger trackedIndex = NSNotFound;
                    id effect = SpliceKit_mixerTrackedEffectForObject(managedEntry, object, &stack, &trackedIndex);
                    if (stack && effect && trackedIndex != NSNotFound &&
                        SpliceKit_mixerRemoveEffectFromStackAtIndex(stack, trackedIndex)) {
                        [updated addObject:SpliceKit_mixerBusTargetSummary(object, stack)];
                    }
                    SpliceKit_mixerUpdateObjectAfterBusEffectMutation(object);
                }

                NSMutableArray *entries = SpliceKit_mixerManagedBusEntriesForRole(role, NO);
                [entries removeObject:managedEntry];
                SpliceKit_mixerPruneManagedBusRole(role);

                result = @{
                    @"ok": @YES,
                    @"role": role ?: @"",
                    @"index": managedIndex == NSNotFound ? @(-1) : @(managedIndex),
                    @"busEffectID": [managedEntry[@"busEffectID"] isKindOfClass:[NSString class]] ? managedEntry[@"busEffectID"] : @"",
                    @"busObjectCount": @(updated.count),
                    @"targets": updated,
                };
                return;
            }

            NSMutableArray *updated = [NSMutableArray array];
            for (NSDictionary *target in busTargets) {
                id stack = target[@"effectStack"];
                id effect = SpliceKit_mixerEffectAtIndex(stack, effectIndex);
                if (!stack || !effect) continue;

                if (SpliceKit_mixerRemoveEffectFromStackAtIndex(stack, effectIndex)) {
                    [updated addObject:SpliceKit_mixerBusTargetSummary(target[@"object"], stack)];
                }
            }

            if (updated.count == 0) {
                result = @{@"error": @"No bus effect found at that index", @"effectIndex": @(effectIndex)};
                return;
            }

            result = @{
                @"ok": @YES,
                @"role": role,
                @"index": @(index),
                @"effectIndex": @(effectIndex),
                @"busObjectCount": @(updated.count),
                @"targets": updated,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to remove mixer bus effect"};
}

NSDictionary *SpliceKit_handleMixerOpenBusEffect(NSDictionary *params) {
    NSNumber *effectIndexNumber = [params[@"effectIndex"] isKindOfClass:[NSNumber class]] ? params[@"effectIndex"] : nil;
    NSString *busEffectID = [params[@"busEffectID"] isKindOfClass:[NSString class]] ? params[@"busEffectID"] : @"";
    NSString *effectHandleParam = [params[@"effectHandle"] isKindOfClass:[NSString class]] ? params[@"effectHandle"] : @"";
    if (!effectIndexNumber && busEffectID.length == 0 && effectHandleParam.length == 0) {
        return @{@"error": @"effectIndex, effectHandle, or busEffectID parameter required"};
    }
    NSInteger effectIndex = effectIndexNumber ? [effectIndexNumber integerValue] : NSNotFound;
    BOOL allowObjectFallback = [params[@"allowObjectFallback"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSString *role = nil;
            NSInteger index = NSNotFound;
            NSArray<NSDictionary *> *busTargets = nil;
            NSString *error = nil;
            id effect = nil;
            id sourceStack = nil;
            NSInteger resolvedEffectIndex = effectIndex;
            id handleEffect = nil;
            id handleStack = nil;
            NSInteger handleEffectIndex = NSNotFound;
            if (SpliceKit_mixerResolveEffectHandleParams(params, &handleEffect, &handleStack, &handleEffectIndex, &error)) {
                if (!handleEffect || !handleStack) {
                    result = @{@"error": error ?: @"Unable to resolve mixer bus effect handle"};
                    return;
                }
                effect = handleEffect;
                sourceStack = handleStack;
                if (handleEffectIndex != NSNotFound) resolvedEffectIndex = handleEffectIndex;
            } else if (busEffectID.length > 0) {
                NSString *managedRole = nil;
                NSMutableDictionary *entry = SpliceKit_mixerManagedBusEntryForID(busEffectID, &managedRole, NULL);
                if (!entry) {
                    result = @{@"error": @"Managed bus effect not found", @"busEffectID": busEffectID};
                    return;
                }
                role = managedRole;
                NSString *managedTargetError = nil;
                NSArray<NSDictionary *> *managedTargets = SpliceKit_mixerCurrentBusTargetsForManagedEntry(
                    entry, managedRole, allowObjectFallback, &managedTargetError);
                if (!managedTargets) {
                    result = @{@"error": managedTargetError ?: @"Unable to resolve managed bus targets"};
                    return;
                }
                for (NSDictionary *target in managedTargets) {
                    effect = SpliceKit_mixerTrackedEffectForObject(entry, target[@"object"], &sourceStack, &resolvedEffectIndex);
                    if (effect) break;
                }
            } else {
                if (!SpliceKit_mixerBusTargetsFromParams(params, allowObjectFallback, &role, &index, &busTargets, &error)) {
                    result = @{@"error": error ?: @"Unable to resolve mixer bus"};
                    return;
                }

                NSUInteger managedIndex = NSNotFound;
                NSMutableDictionary *managedEntry = SpliceKit_mixerManagedBusEntryForRoleDisplayIndex(role, effectIndex, &managedIndex);
                if (managedEntry) {
                    NSString *managedTargetError = nil;
                    NSArray<NSDictionary *> *managedTargets = SpliceKit_mixerCurrentBusTargetsForManagedEntry(
                        managedEntry, role, allowObjectFallback, &managedTargetError);
                    if (!managedTargets) {
                        result = @{@"error": managedTargetError ?: @"Unable to resolve managed bus targets"};
                        return;
                    }
                    for (NSDictionary *target in managedTargets) {
                        effect = SpliceKit_mixerTrackedEffectForObject(managedEntry, target[@"object"], &sourceStack, &resolvedEffectIndex);
                        if (effect) break;
                    }
                    index = managedIndex == NSNotFound ? NSNotFound : (NSInteger)managedIndex;
                } else {
                    for (NSDictionary *target in busTargets) {
                        sourceStack = target[@"effectStack"];
                        effect = SpliceKit_mixerEffectAtIndex(sourceStack, effectIndex);
                        if (effect) break;
                    }
                }
            }
            if (!effect) {
                result = @{@"error": @"No bus effect found at that index", @"effectIndex": @(effectIndex)};
                return;
            }

            Class editorClass = objc_getClass("FFAudioEffectEditorWindowController");
            if (!editorClass || ![editorClass respondsToSelector:NSSelectorFromString(@"showWindowControllerForEffect:context:")]) {
                result = @{@"error": @"FCP audio effect editor window controller is unavailable"};
                return;
            }

            id context = SpliceKit_mixerTimelineContext();
            if (!context) {
                result = @{@"error": @"No timeline context available for audio effect editor"};
                return;
            }

            ((void (*)(id, SEL, id, id))objc_msgSend)(
                (id)editorClass,
                NSSelectorFromString(@"showWindowControllerForEffect:context:"),
                effect,
                context);

            result = @{
                @"ok": @YES,
                @"role": role ?: @"",
                @"index": index == NSNotFound ? @(-1) : @(index),
                @"effectIndex": @(resolvedEffectIndex),
                @"effect": SpliceKit_mixerEffectSummary(effect, resolvedEffectIndex == NSNotFound ? 0 : (NSUInteger)resolvedEffectIndex),
                @"effectStackHandle": sourceStack ? (SpliceKit_storeHandle(sourceStack) ?: @"") : @"",
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to open mixer bus effect editor"};
}

// Active undo transactions for mixer fader drags
static NSMutableDictionary *sMixerUndoTransactions = nil;

// mixer.volumeBegin — open undo transaction for a fader drag
NSDictionary *SpliceKit_handleMixerVolumeBegin(NSDictionary *params) {
    NSString *effectStackHandle = params[@"effectStackHandle"];
    // Also accept audioEffectStackHandle (preferred for mixer)
    if (!effectStackHandle) effectStackHandle = params[@"audioEffectStackHandle"];
    if (!effectStackHandle) return @{@"error": @"effectStackHandle or audioEffectStackHandle parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id effectStack = SpliceKit_resolveHandle(effectStackHandle);
            if (!effectStack) {
                result = @{@"error": @"effectStackHandle not found"};
                return;
            }

            // Open undo transaction
            SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
            if ([effectStack respondsToSelector:beginSel]) {
                ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                    effectStack, beginSel, @"Adjust Volume", nil, YES);
            }

            // Track this transaction
            if (!sMixerUndoTransactions) sMixerUndoTransactions = [NSMutableDictionary dictionary];
            sMixerUndoTransactions[effectStackHandle] = @YES;

            result = @{@"ok": @YES, @"effectStackHandle": effectStackHandle};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

// mixer.volumeEnd — close undo transaction for a fader drag
NSDictionary *SpliceKit_handleMixerVolumeEnd(NSDictionary *params) {
    NSString *effectStackHandle = params[@"effectStackHandle"];
    if (!effectStackHandle) effectStackHandle = params[@"audioEffectStackHandle"];
    if (!effectStackHandle) return @{@"error": @"effectStackHandle or audioEffectStackHandle parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id effectStack = SpliceKit_resolveHandle(effectStackHandle);
            if (!effectStack) {
                result = @{@"error": @"effectStackHandle not found"};
                return;
            }

            // Close undo transaction
            SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
            if ([effectStack respondsToSelector:endSel]) {
                ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                    effectStack, endSel, @"Adjust Volume", YES, nil);
            }

            // Remove from tracking
            [sMixerUndoTransactions removeObjectForKey:effectStackHandle];

            result = @{@"ok": @YES};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

// mixer.setAllVolumes — batch set multiple fader volumes in one undo transaction
NSDictionary *SpliceKit_handleMixerSetAllVolumes(NSDictionary *params) {
    NSArray *volumes = params[@"volumes"]; // [{handle, volumeDB or volumeLinear}, ...]
    if (!volumes || ![volumes isKindOfClass:[NSArray class]] || volumes.count == 0) {
        return @{@"error": @"volumes array required: [{handle, volumeDB or volumeLinear}, ...]"};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSMutableArray *results = [NSMutableArray array];
            for (NSDictionary *entry in volumes) {
                NSString *handle = entry[@"handle"];
                if (!handle) { [results addObject:@{@"error": @"missing handle"}]; continue; }

                id channel = SpliceKit_resolveHandle(handle);
                if (!channel) { [results addObject:@{@"error": @"handle not found"}]; continue; }

                NSNumber *dbVal = entry[@"volumeDB"];
                NSNumber *linearVal = entry[@"volumeLinear"];
                double linear;
                if (linearVal) {
                    linear = [linearVal doubleValue];
                } else if (dbVal) {
                    double db = [dbVal doubleValue];
                    linear = (db <= -144.0) ? 0.0 : pow(10.0, db / 20.0);
                } else {
                    [results addObject:@{@"error": @"volumeDB or volumeLinear required"}];
                    continue;
                }

                if (linear < 0.0) linear = 0.0;
                if (linear > 3.98) linear = 3.98;

                SpliceKit_removeChannelKeyframes(channel);
                BOOL ok = SpliceKit_mixerSetStaticChannelValue(channel, linear);
                double readback = ok ? SpliceKit_channelValue(channel) : 0;
                [results addObject:@{
                    @"handle": handle,
                    @"ok": @(ok),
                    @"volumeLinear": @(readback),
                    @"volumeDB": SpliceKit_mixerJSONDBNumberFromLinear(readback, -96.0)
                }];
            }
            result = @{@"ok": @YES, @"results": results};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}
