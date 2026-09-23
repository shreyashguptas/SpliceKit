//
//  SpliceKitServerInspector.m
//  SpliceKit - Effect stacks and keyframe targets of the selected clip, channel reads and
//  writes, inspector.get / inspector.set, and title text inspection.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Effect Parameter Helpers
//
// FCP's effect parameters live in a channel tree: clip -> effectStack -> channels
// (groups) -> sub-channels (individual params like position.x, opacity, etc).
//

// Get the selected clip's effect stack, creating it if needed
id SpliceKit_getSelectedTimelineItem(id timeline) {
    if (!timeline) return nil;

    // Get selected items
    NSArray *selected = nil;
    SEL selSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
    if ([timeline respondsToSelector:selSel]) {
        id r = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, selSel, NO, YES);
        if ([r isKindOfClass:[NSArray class]]) selected = (NSArray *)r;
    }
    if ((!selected || selected.count == 0) && [timeline respondsToSelector:@selector(selectedItems)]) {
        id r = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(selectedItems));
        if ([r isKindOfClass:[NSArray class]]) selected = (NSArray *)r;
    }
    if (!selected || selected.count == 0) return nil;

    return selected[0];
}

id SpliceKit_getSelectedClipEffectStack(id timeline, id *outClip) {
    if (!timeline) return nil;

    id clip = SpliceKit_getSelectedTimelineItem(timeline);
    if (!clip) return nil;

    if (outClip) *outClip = clip;

    // If clip is a collection (compound/storyline), get the first media component's effectStack
    if ([clip isKindOfClass:objc_getClass("FFAnchoredCollection")]) {
        @try {
            id items = [clip valueForKey:@"containedItems"];
            if ([items isKindOfClass:[NSArray class]] && [(NSArray *)items count] > 0) {
                id firstItem = [(NSArray *)items firstObject];
                if ([firstItem respondsToSelector:@selector(effectStack)]) {
                    id es = ((id (*)(id, SEL))objc_msgSend)(firstItem, @selector(effectStack));
                    if (es) { if (outClip) *outClip = firstItem; return es; }
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

static id SpliceKit_getClipAudioEffectStack(id clip) {
    if (!clip) return nil;
    @try {
        SEL aeSel = NSSelectorFromString(@"audioEffectsForIdentifier:");
        if ([clip respondsToSelector:aeSel]) {
            return ((id (*)(id, SEL, unsigned long long))objc_msgSend)(clip, aeSel, 0ULL);
        }
    } @catch (NSException *e) {}
    return nil;
}

static void SpliceKit_addUniqueKeyframeTarget(id target,
                                              NSMutableArray *targets,
                                              NSMutableSet<NSString *> *seen,
                                              NSString *label) {
    if (!target) return;
    NSString *key = [NSString stringWithFormat:@"%p", (__bridge void *)target];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObject:target forKey:@"target"];
    if (label.length > 0) entry[@"label"] = label;
    [targets addObject:entry];
}

static void SpliceKit_addKeyframeTargetsFromOwner(id owner,
                                                  NSArray<NSString *> *selectors,
                                                  NSMutableArray *targets,
                                                  NSMutableSet<NSString *> *seen,
                                                  NSString *ownerLabel) {
    if (!owner) return;
    for (NSString *selName in selectors) {
        @try {
            SEL sel = NSSelectorFromString(selName);
            if (![owner respondsToSelector:sel]) continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(owner, sel);
            if (!value) continue;
            NSString *label = ownerLabel.length > 0
                ? [NSString stringWithFormat:@"%@.%@", ownerLabel, selName]
                : selName;
            SpliceKit_addUniqueKeyframeTarget(value, targets, seen, label);
        } @catch (NSException *e) {}
    }
}

static void SpliceKit_addInspectableKeyframeTargets(id owner,
                                                    NSMutableArray *targets,
                                                    NSMutableSet<NSString *> *seenTargets,
                                                    NSString *ownerLabel) {
    if (!owner) return;

    @try {
        SEL idsSel = NSSelectorFromString(@"inspectorTabIdentifiers");
        SEL channelsSel = NSSelectorFromString(@"inspectableChannelsForIdentifier:");
        if (![owner respondsToSelector:idsSel] || ![owner respondsToSelector:channelsSel]) return;

        id identifiers = ((id (*)(id, SEL))objc_msgSend)(owner, idsSel);
        if (![identifiers isKindOfClass:[NSArray class]]) return;

        for (id identifier in (NSArray *)identifiers) {
            if (!identifier) continue;
            id inspectable = ((id (*)(id, SEL, id))objc_msgSend)(owner, channelsSel, identifier);
            if ([inspectable isKindOfClass:[NSArray class]]) {
                NSUInteger idx = 0;
                for (id channel in (NSArray *)inspectable) {
                    NSString *label = [NSString stringWithFormat:@"%@.inspectable[%@][%lu]",
                                       ownerLabel ?: @"clip",
                                       [identifier description],
                                       (unsigned long)idx++];
                    SpliceKit_addUniqueKeyframeTarget(channel, targets, seenTargets, label);
                }
            } else if (inspectable) {
                NSString *label = [NSString stringWithFormat:@"%@.inspectable[%@]",
                                   ownerLabel ?: @"clip",
                                   [identifier description]];
                SpliceKit_addUniqueKeyframeTarget(inspectable, targets, seenTargets, label);
            }
        }
    } @catch (NSException *e) {}
}

static NSArray *SpliceKit_childClipsForKeyframeTraversal(id clip) {
    if (!clip) return @[];

    for (NSString *selName in @[@"descendentCompositedObjects", @"containedItems", @"allContainedItems"]) {
        @try {
            SEL sel = NSSelectorFromString(selName);
            if (![clip respondsToSelector:sel]) continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(clip, sel);
            if ([value isKindOfClass:[NSArray class]]) return value;
            if ([value isKindOfClass:[NSSet class]]) return [(NSSet *)value allObjects];
        } @catch (NSException *e) {}
    }
    return @[];
}

static void SpliceKit_collectKeyframeTargetsForClipRecursive(id clip,
                                                            NSMutableArray *targets,
                                                            NSMutableSet<NSString *> *seenTargets,
                                                            NSMutableSet<NSString *> *seenClips,
                                                            NSString *clipLabel) {
    if (!clip) return;

    NSString *clipKey = [NSString stringWithFormat:@"%p", (__bridge void *)clip];
    if ([seenClips containsObject:clipKey]) return;
    [seenClips addObject:clipKey];

    NSString *baseLabel = clipLabel.length > 0 ? clipLabel : @"clip";

    id videoTarget = SpliceKit_effectDragVideoEffectsTarget(clip);
    SpliceKit_addUniqueKeyframeTarget(
        videoTarget, targets, seenTargets, [baseLabel stringByAppendingString:@".videoEffects"]);

    id clipEffectStack = SpliceKit_getClipEffectStack(clip);
    SpliceKit_addUniqueKeyframeTarget(
        clipEffectStack, targets, seenTargets, [baseLabel stringByAppendingString:@".effectStack"]);

    id clipAudioEffectStack = SpliceKit_getClipAudioEffectStack(clip);
    SpliceKit_addUniqueKeyframeTarget(
        clipAudioEffectStack,
        targets,
        seenTargets,
        [baseLabel stringByAppendingString:@".audioEffectsForIdentifier"]);

    SpliceKit_addKeyframeTargetsFromOwner(
        clip,
        @[@"videoEffects", @"audioEffects", @"localAudioEffects", @"effectStack"],
        targets,
        seenTargets,
        baseLabel);
    SpliceKit_addInspectableKeyframeTargets(clip, targets, seenTargets, baseLabel);

    id toolObj = nil;
    @try {
        SEL toolSel = NSSelectorFromString(@"representedToolObject");
        if ([clip respondsToSelector:toolSel]) {
            toolObj = ((id (*)(id, SEL))objc_msgSend)(clip, toolSel);
        }
    } @catch (NSException *e) {}
    if (toolObj && toolObj != clip) {
        SpliceKit_addKeyframeTargetsFromOwner(
            toolObj,
            @[@"videoEffects", @"audioEffects", @"localAudioEffects", @"effectStack"],
            targets,
            seenTargets,
            [baseLabel stringByAppendingString:@".representedToolObject"]);
        SpliceKit_addInspectableKeyframeTargets(
            toolObj,
            targets,
            seenTargets,
            [baseLabel stringByAppendingString:@".representedToolObject"]);
    }

    NSArray *children = SpliceKit_childClipsForKeyframeTraversal(clip);
    for (NSUInteger idx = 0; idx < children.count; idx++) {
        id child = children[idx];
        NSString *childLabel = [NSString stringWithFormat:@"%@.containedItems[%lu]",
                                baseLabel,
                                (unsigned long)idx];
        SpliceKit_collectKeyframeTargetsForClipRecursive(
            child, targets, seenTargets, seenClips, childLabel);
    }
}

NSArray<id> *SpliceKit_keyframeTargetsForClip(id clip) {
    NSMutableArray *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *seenTargets = [NSMutableSet set];
    NSMutableSet<NSString *> *seenClips = [NSMutableSet set];
    if (!clip) return @[];

    SpliceKit_collectKeyframeTargetsForClipRecursive(
        clip, entries, seenTargets, seenClips, @"clip");

    NSMutableArray *targets = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSDictionary *entry in entries) {
        id target = entry[@"target"];
        if (!target) continue;
        [targets addObject:target];
    }
    return targets;
}

static void SpliceKit_collectKeyframedChannelsFromNode(id obj,
                                                       NSMutableArray *channels,
                                                       NSMutableSet<NSString *> *seen,
                                                       NSInteger depth) {
    if (!obj || depth > 10) return;

    if ([obj isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)obj) {
            SpliceKit_collectKeyframedChannelsFromNode(child, channels, seen, depth + 1);
        }
        return;
    }
    if ([obj isKindOfClass:[NSSet class]]) {
        for (id child in [(NSSet *)obj allObjects]) {
            SpliceKit_collectKeyframedChannelsFromNode(child, channels, seen, depth + 1);
        }
        return;
    }

    NSString *nodeKey = [NSString stringWithFormat:@"%p", (__bridge void *)obj];
    if ([seen containsObject:nodeKey]) return;
    [seen addObject:nodeKey];

    @try {
        SEL countSel = NSSelectorFromString(@"keyframeCount");
        if ([obj respondsToSelector:countSel]) {
            NSInteger keyframeCount = ((NSInteger (*)(id, SEL))objc_msgSend)(obj, countSel);
            if (keyframeCount > 0) [channels addObject:obj];
        }
    } @catch (NSException *e) {}

    NSArray<NSString *> *arraySelectors = @[@"channels", @"children", @"visibleEffects"];
    for (NSString *selName in arraySelectors) {
        @try {
            SEL sel = NSSelectorFromString(selName);
            if (![obj respondsToSelector:sel]) continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
            if (![value isKindOfClass:[NSArray class]]) continue;
            for (id child in (NSArray *)value) {
                SpliceKit_collectKeyframedChannelsFromNode(child, channels, seen, depth + 1);
            }
        } @catch (NSException *e) {}
    }

    NSArray<NSString *> *childSelectors = @[
        @"rootChannel",
        @"effectChannels",
        @"propertyChannels",
        @"objectChannels",
        @"stackPropertyChannels",
        @"audioPropertyChannels",
        @"intrinsicChannels",
        @"intrinsicCompositeEffect",
        @"xform3DEffect",
        @"cropEffect",
        @"audioLevelChannel",
        @"positionChannel3D",
        @"scaleChannel3D",
        @"rotationChannel3D",
        @"anchorChannel3D",
        @"opacityChannel",
        @"blendModeChannel",
        @"xChannel",
        @"yChannel",
        @"zChannel",
        @"leftChannel",
        @"rightChannel",
        @"topChannel",
        @"bottomChannel"
    ];
    for (NSString *selName in childSelectors) {
        @try {
            SEL sel = NSSelectorFromString(selName);
            if (![obj respondsToSelector:sel]) continue;
            id child = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
            if (!child) continue;
            if ([child isKindOfClass:[NSArray class]]) {
                for (id item in (NSArray *)child) {
                    SpliceKit_collectKeyframedChannelsFromNode(item, channels, seen, depth + 1);
                }
            } else {
                SpliceKit_collectKeyframedChannelsFromNode(child, channels, seen, depth + 1);
            }
        } @catch (NSException *e) {}
    }
}

NSDictionary *SpliceKit_removeAllKeyframesFromEffectStack(id effectStack, NSString *actionName) {
    if (!effectStack) {
        return @{@"channelsCleared": @0, @"keyframesRemoved": @0};
    }

    NSMutableArray *channels = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    SpliceKit_collectKeyframedChannelsFromNode(effectStack, channels, seen, 0);

    if (channels.count == 0) {
        return @{@"channelsCleared": @0, @"keyframesRemoved": @0};
    }

    @try {
        SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
        if ([effectStack respondsToSelector:beginSel]) {
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                effectStack, beginSel, actionName ?: @"Remove All Keyframes", nil, YES);
        }
    } @catch (NSException *e) {}

    NSUInteger channelsCleared = 0;
    NSUInteger keyframesRemoved = 0;
    for (id channel in channels) {
        @try {
            SEL countSel = NSSelectorFromString(@"keyframeCount");
            NSInteger count = [channel respondsToSelector:countSel]
                ? ((NSInteger (*)(id, SEL))objc_msgSend)(channel, countSel) : 0;
            if (count <= 0) continue;
            if (SpliceKit_removeChannelKeyframes(channel)) {
                channelsCleared++;
                keyframesRemoved += (NSUInteger)count;
            }
        } @catch (NSException *e) {}
    }

    @try {
        SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
        if ([effectStack respondsToSelector:endSel]) {
            ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                effectStack, endSel, actionName ?: @"Remove All Keyframes", YES, nil);
        }
    } @catch (NSException *e) {}

    return @{
        @"channelsCleared": @(channelsCleared),
        @"keyframesRemoved": @(keyframesRemoved),
    };
}

// Read a channel's value at a given time (seconds)
static NSDictionary *SpliceKit_readChannel(id channel, double timeSeconds) {
    if (!channel) return nil;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"class"] = NSStringFromClass([channel class]);

    @try {
        // Get name
        SEL nameSel = NSSelectorFromString(@"name");
        if ([channel respondsToSelector:nameSel]) {
            id name = ((id (*)(id, SEL))objc_msgSend)(channel, nameSel);
            if (name) info[@"name"] = [name description];
        }
    } @catch (NSException *e) {}

    // Read value at time
    @try {
        SEL valSel = NSSelectorFromString(@"doubleValueAtTime:");
        if ([channel respondsToSelector:valSel]) {
            SpliceKit_CMTime t = {(int64_t)(timeSeconds * 600), 600, 1, 0};
            double val = ((double (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(channel, valSel, t);
            info[@"value"] = @(val);
        }
    } @catch (NSException *e) {}

    // Read default
    @try {
        SEL defSel = NSSelectorFromString(@"defaultCurveDoubleValue");
        if ([channel respondsToSelector:defSel]) {
            double def = ((double (*)(id, SEL))objc_msgSend)(channel, defSel);
            info[@"default"] = @(def);
        }
    } @catch (NSException *e) {}

    // Read min/max
    @try {
        SEL minSel = NSSelectorFromString(@"minCurveDoubleValue");
        SEL maxSel = NSSelectorFromString(@"maxCurveDoubleValue");
        if ([channel respondsToSelector:minSel])
            info[@"min"] = @(((double (*)(id, SEL))objc_msgSend)(channel, minSel));
        if ([channel respondsToSelector:maxSel])
            info[@"max"] = @(((double (*)(id, SEL))objc_msgSend)(channel, maxSel));
    } @catch (NSException *e) {}

    return info;
}

// Get all channels from an effect recursively
static void SpliceKit_collectChannels(id obj, NSMutableArray *channels, NSString *prefix, int depth) {
    if (!obj || depth > 8) return;

    // If this is itself a channel with a double value, add it
    if ([obj respondsToSelector:NSSelectorFromString(@"doubleValueAtTime:")]) {
        NSString *name = prefix ?: @"";
        @try {
            SEL nSel = NSSelectorFromString(@"name");
            if ([obj respondsToSelector:nSel]) {
                id n = ((id (*)(id, SEL))objc_msgSend)(obj, nSel);
                if (n) name = [n description];
            }
        } @catch (NSException *e) {}

        NSMutableDictionary *ch = [NSMutableDictionary dictionary];
        ch[@"name"] = name;
        ch[@"handle"] = SpliceKit_storeHandle(obj);

        NSDictionary *vals = SpliceKit_readChannel(obj, 0);
        if (vals[@"value"]) ch[@"value"] = vals[@"value"];
        if (vals[@"min"]) ch[@"min"] = vals[@"min"];
        if (vals[@"max"]) ch[@"max"] = vals[@"max"];
        if (vals[@"default"]) ch[@"default"] = vals[@"default"];
        [channels addObject:ch];
    }

    // Try to get sub-channels
    @try {
        SEL subSel = NSSelectorFromString(@"channels");
        if ([obj respondsToSelector:subSel]) {
            id subs = ((id (*)(id, SEL))objc_msgSend)(obj, subSel);
            if ([subs isKindOfClass:[NSArray class]]) {
                for (id sub in (NSArray *)subs) {
                    SpliceKit_collectChannels(sub, channels, nil, depth + 1);
                }
            }
        }
    } @catch (NSException *e) {}
}

#pragma mark - Inspector Handlers
//
// Read and write clip properties (transform, compositing, audio volume, etc.)
// by walking FCP's channel-based parameter model.
//

// Helper: read a double from a channel at time=0 (kCMTimeIndefinite for constant)
double SpliceKit_channelValue(id channel) {
    if (!channel) return 0;
    @try {
        // Use kCMTimeIndefinite: {0, 0, 17, 0} for constant (non-keyframed) value
        SpliceKit_CMTime t = {0, 0, 17, 0};
        SEL sel = NSSelectorFromString(@"curveDoubleValueAtTime:");
        if ([channel respondsToSelector:sel]) {
            return ((double (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(channel, sel, t);
        }
        sel = NSSelectorFromString(@"doubleValueAtTime:");
        if ([channel respondsToSelector:sel]) {
            return ((double (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(channel, sel, t);
        }
    } @catch (NSException *e) {}
    return 0;
}

// Read channel value at a specific time (for keyframed parameters)
double SpliceKit_channelValueAtTime(id channel, SpliceKit_CMTime time) {
    if (!channel) return 0;
    @try {
        SEL sel = NSSelectorFromString(@"curveDoubleValueAtTime:");
        if ([channel respondsToSelector:sel]) {
            return ((double (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(channel, sel, time);
        }
        sel = NSSelectorFromString(@"doubleValueAtTime:");
        if ([channel respondsToSelector:sel]) {
            return ((double (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(channel, sel, time);
        }
    } @catch (NSException *e) {}
    return 0;
}

// How many keyframes a channel carries; -1 when the channel cannot report it.
// This is what makes an animated parameter visible: the value readers below return
// a single number, so without a count there is no way to tell a static 0 from a
// channel carrying hundreds of keyframes (stabilize_subject writes one per frame).
static NSInteger SpliceKit_channelKeyframeCount(id channel) {
    if (!channel) return -1;
    @try {
        SEL countSel = NSSelectorFromString(@"keyframeCount");
        if ([channel respondsToSelector:countSel]) {
            return ((NSInteger (*)(id, SEL))objc_msgSend)(channel, countSel);
        }
    } @catch (NSException *e) {}
    return -1;
}

// Remove all existing keyframes so a constant write takes effect.
BOOL SpliceKit_removeChannelKeyframes(id channel) {
    if (!channel) return NO;
    @try {
        SEL countSel = NSSelectorFromString(@"keyframeCount");
        if (![channel respondsToSelector:countSel]) return NO;

        NSInteger count = ((NSInteger (*)(id, SEL))objc_msgSend)(channel, countSel);
        if (count <= 0) return YES;

        SEL removeAllSel = NSSelectorFromString(@"removeAllKeyframes:");
        if ([channel respondsToSelector:removeAllSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(channel, removeAllSel, YES);
            return YES;
        }
    } @catch (NSException *e) {}
    return NO;
}

BOOL SpliceKit_setChannelValueAtTimeWithOptions(id channel, double value, SpliceKit_CMTime time, unsigned int options) {
    if (!channel) return NO;
    @try {
        SEL sel = NSSelectorFromString(@"setCurveDoubleValue:atTime:options:");
        if ([channel respondsToSelector:sel]) {
            ((void (*)(id, SEL, double, SpliceKit_CMTime, unsigned int))objc_msgSend)(
                channel, sel, value, time, options);
            return YES;
        }
    } @catch (NSException *e) {}
    return NO;
}

BOOL SpliceKit_setChannelValueAtTime(id channel, double value, SpliceKit_CMTime time) {
    return SpliceKit_setChannelValueAtTimeWithOptions(channel, value, time, 0);
}

// Helper: set a double on a channel
BOOL SpliceKit_setChannelValue(id channel, double value) {
    SpliceKit_CMTime t = {0, 0, 17, 0}; // kCMTimeIndefinite
    return SpliceKit_setChannelValueAtTime(channel, value, t);
}

// Static mixer drags need the same channel operation bracketing FCP uses for live edits,
// otherwise playback can cache the old gain until transport is restarted.
BOOL SpliceKit_mixerSetStaticChannelValue(id channel, double value) {
    if (!channel) return NO;

    BOOL beganOperation = NO;
    @try {
        SEL beginSel = NSSelectorFromString(@"operationBegin");
        if ([channel respondsToSelector:beginSel]) {
            ((void (*)(id, SEL))objc_msgSend)(channel, beginSel);
            beganOperation = YES;
        }
    } @catch (NSException *e) {}

    // Match FCP's own control flow: touch the current value before updating.
    (void)SpliceKit_channelValue(channel);
    BOOL ok = SpliceKit_setChannelValue(channel, value);

    @try {
        SEL endSel = NSSelectorFromString(@"operationEnd");
        if (beganOperation && [channel respondsToSelector:endSel]) {
            ((void (*)(id, SEL))objc_msgSend)(channel, endSel);
        }
    } @catch (NSException *e) {}

    return ok;
}

// Helper: get sub-channel by name (xChannel, yChannel, zChannel)
static id SpliceKit_subChannel(id parentChannel, NSString *axis) {
    if (!parentChannel) return nil;
    @try {
        NSString *selName = [NSString stringWithFormat:@"%@Channel", axis];
        SEL sel = NSSelectorFromString(selName);
        if ([parentChannel respondsToSelector:sel]) {
            return ((id (*)(id, SEL))objc_msgSend)(parentChannel, sel);
        }
    } @catch (NSException *e) {}
    return nil;
}

NSDictionary *SpliceKit_handleInspectorGet(NSDictionary *params) {
    NSString *property = params[@"property"]; // "all", "compositing", "transform", "audio", "crop", "info", "channels"

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id clip = nil;
            id effectStack = SpliceKit_getSelectedClipEffectStack(timeline, &clip);
            if (!clip) { result = @{@"error": @"No clips selected"}; return; }

            NSMutableDictionary *props = [NSMutableDictionary dictionary];

            // Clip info (always included)
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"class"] = NSStringFromClass([clip class]);
            @try {
                if ([clip respondsToSelector:@selector(displayName)]) {
                    id n = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
                    if (n) info[@"name"] = [n description];
                }
            } @catch (NSException *e) {}
            info[@"hasEffectStack"] = @(effectStack != nil);
            props[@"info"] = info;

            if (!effectStack) {
                result = @{@"properties": props, @"note": @"Clip has no effect stack"};
                return;
            }

            NSString *esHandle = SpliceKit_storeHandle(effectStack);
            props[@"effectStackHandle"] = esHandle;

            // COMPOSITING (opacity, blend mode)
            if (!property || [property isEqualToString:@"all"] || [property isEqualToString:@"compositing"]) {
                NSMutableDictionary *comp = [NSMutableDictionary dictionary];
                @try {
                    SEL blendSel = NSSelectorFromString(@"intrinsicCompositeEffect");
                    id blendEffect = [effectStack respondsToSelector:blendSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(effectStack, blendSel) : nil;
                    if (blendEffect) {
                        id opChan = ((id (*)(id, SEL))objc_msgSend)(blendEffect, NSSelectorFromString(@"opacityChannel"));
                        id bmChan = ((id (*)(id, SEL))objc_msgSend)(blendEffect, NSSelectorFromString(@"blendModeChannel"));
                        if (opChan) {
                            comp[@"opacity"] = @(SpliceKit_channelValue(opChan));
                            comp[@"opacityHandle"] = SpliceKit_storeHandle(opChan);
                        }
                        if (bmChan) comp[@"blendModeHandle"] = SpliceKit_storeHandle(bmChan);
                    } else {
                        comp[@"opacity"] = @(1.0); // default
                    }
                } @catch (NSException *e) { comp[@"error"] = e.reason; }
                props[@"compositing"] = comp;
            }

            // TRANSFORM (position, rotation, scale, anchor)
            if (!property || [property isEqualToString:@"all"] || [property isEqualToString:@"transform"]) {
                NSMutableDictionary *xform = [NSMutableDictionary dictionary];
                @try {
                    SEL xfSel = NSSelectorFromString(@"xform3DEffect");
                    id xfEffect = [effectStack respondsToSelector:xfSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(effectStack, xfSel) : nil;
                    if (xfEffect) {
                        // Every value below is a single number. When a parameter is
                        // animated that number says nothing, so record the keyframe count
                        // alongside it: that is the only way the tool surface can show
                        // what stabilize_subject (one keyframe per frame) actually did.
                        NSMutableDictionary *kf = [NSMutableDictionary dictionary];
                        void (^recordKeyframes)(NSString *, id) = ^(NSString *label, id axisChannel) {
                            NSInteger n = SpliceKit_channelKeyframeCount(axisChannel);
                            if (n > 0) kf[label] = @(n);
                        };
                        // Position
                        id posCh = nil;
                        @try { posCh = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(@"positionChannel3D")); } @catch(NSException *e) {}
                        if (posCh) {
                            id px = SpliceKit_subChannel(posCh, @"x");
                            id py = SpliceKit_subChannel(posCh, @"y");
                            id pz = SpliceKit_subChannel(posCh, @"z");
                            xform[@"positionX"] = @(SpliceKit_channelValue(px));
                            xform[@"positionY"] = @(SpliceKit_channelValue(py));
                            xform[@"positionZ"] = @(SpliceKit_channelValue(pz));
                            recordKeyframes(@"positionX", px);
                            recordKeyframes(@"positionY", py);
                            recordKeyframes(@"positionZ", pz);
                        }
                        // Scale
                        id scaCh = nil;
                        @try { scaCh = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(@"scaleChannel3D")); } @catch(NSException *e) {}
                        if (scaCh) {
                            id sx = SpliceKit_subChannel(scaCh, @"x");
                            id sy = SpliceKit_subChannel(scaCh, @"y");
                            xform[@"scaleX"] = @(SpliceKit_channelValue(sx));
                            xform[@"scaleY"] = @(SpliceKit_channelValue(sy));
                            recordKeyframes(@"scaleX", sx);
                            recordKeyframes(@"scaleY", sy);
                        }
                        // Rotation
                        id rotCh = nil;
                        @try { rotCh = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(@"rotationChannel3D")); } @catch(NSException *e) {}
                        if (rotCh) {
                            id rz = SpliceKit_subChannel(rotCh, @"z");
                            xform[@"rotation"] = @(SpliceKit_channelValue(rz));
                            recordKeyframes(@"rotation", rz);
                        }
                        // Anchor
                        id ancCh = nil;
                        @try { ancCh = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(@"anchorChannel3D")); } @catch(NSException *e) {}
                        if (ancCh) {
                            id ax = SpliceKit_subChannel(ancCh, @"x");
                            id ay = SpliceKit_subChannel(ancCh, @"y");
                            xform[@"anchorX"] = @(SpliceKit_channelValue(ax));
                            xform[@"anchorY"] = @(SpliceKit_channelValue(ay));
                            recordKeyframes(@"anchorX", ax);
                            recordKeyframes(@"anchorY", ay);
                        }
                        if (kf.count > 0) xform[@"keyframes"] = kf;
                    } else {
                        xform[@"positionX"] = @(0); xform[@"positionY"] = @(0);
                        xform[@"scaleX"] = @(100); xform[@"scaleY"] = @(100);
                        xform[@"rotation"] = @(0);
                    }
                } @catch (NSException *e) { xform[@"error"] = e.reason; }
                props[@"transform"] = xform;
            }

            // AUDIO (volume)
            if (!property || [property isEqualToString:@"all"] || [property isEqualToString:@"audio"]) {
                NSMutableDictionary *audio = [NSMutableDictionary dictionary];
                @try {
                    SEL volSel = NSSelectorFromString(@"audioLevelChannel");
                    id volChan = [effectStack respondsToSelector:volSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(effectStack, volSel) : nil;
                    if (volChan) {
                        audio[@"volume"] = @(SpliceKit_channelValue(volChan));
                        audio[@"volumeHandle"] = SpliceKit_storeHandle(volChan);
                        NSInteger volKf = SpliceKit_channelKeyframeCount(volChan);
                        if (volKf > 0) audio[@"keyframes"] = @{@"volume": @(volKf)};
                    }
                } @catch (NSException *e) { audio[@"error"] = e.reason; }
                props[@"audio"] = audio;
            }

            // CROP
            if (!property || [property isEqualToString:@"all"] || [property isEqualToString:@"crop"]) {
                NSMutableDictionary *crop = [NSMutableDictionary dictionary];
                @try {
                    id cropEff = nil;
                    SEL cropSel = NSSelectorFromString(@"cropEffect");
                    if ([effectStack respondsToSelector:cropSel])
                        cropEff = ((id (*)(id, SEL))objc_msgSend)(effectStack, cropSel);
                    if (cropEff) {
                        id (^getCh)(NSString *) = ^id(NSString *name) {
                            @try {
                                SEL s = NSSelectorFromString([NSString stringWithFormat:@"%@Channel", name]);
                                if ([cropEff respondsToSelector:s])
                                    return ((id (*)(id, SEL))objc_msgSend)(cropEff, s);
                            } @catch (NSException *e) {}
                            return nil;
                        };
                        id lCh = getCh(@"left"); if (lCh) crop[@"left"] = @(SpliceKit_channelValue(lCh));
                        id rCh = getCh(@"right"); if (rCh) crop[@"right"] = @(SpliceKit_channelValue(rCh));
                        id tCh = getCh(@"top"); if (tCh) crop[@"top"] = @(SpliceKit_channelValue(tCh));
                        id bCh = getCh(@"bottom"); if (bCh) crop[@"bottom"] = @(SpliceKit_channelValue(bCh));
                    }
                } @catch (NSException *e) { crop[@"error"] = e.reason; }
                props[@"crop"] = crop;
            }

            // ALL EFFECT CHANNELS (for advanced access)
            if ([property isEqualToString:@"channels"]) {
                NSMutableArray *channels = [NSMutableArray array];
                // Get all effects and their channels
                @try {
                    SEL efSel = NSSelectorFromString(@"visibleEffects");
                    if ([effectStack respondsToSelector:efSel]) {
                        NSArray *effects = ((id (*)(id, SEL))objc_msgSend)(effectStack, efSel);
                        for (id effect in effects) {
                            SpliceKit_collectChannels(effect, channels, nil, 0);
                        }
                    }
                    // Also get intrinsic channels
                    SEL icSel = NSSelectorFromString(@"intrinsicChannels");
                    if ([effectStack respondsToSelector:icSel]) {
                        id intrinsic = ((id (*)(id, SEL))objc_msgSend)(effectStack, icSel);
                        if (intrinsic) SpliceKit_collectChannels(intrinsic, channels, @"intrinsic", 0);
                    }
                } @catch (NSException *e) {}
                props[@"channels"] = channels;
            }

            result = @{@"properties": props};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Inspector get failed"};
}

// Concrete keys SpliceKit_handleInspectorSet will actually write. A prefix such as
// "position" is not enough: only these names map onto a channel. Inspector labels
// ("Position X") are not keys.
static BOOL SpliceKit_inspectorTransformChannel(NSString *property,
                                                NSString **outMethod,
                                                NSString **outAxis) {
    NSString *channelMethod = nil;
    NSString *axis = nil;
    if ([property isEqualToString:@"positionX"]) { channelMethod = @"positionChannel3D"; axis = @"x"; }
    else if ([property isEqualToString:@"positionY"]) { channelMethod = @"positionChannel3D"; axis = @"y"; }
    else if ([property isEqualToString:@"positionZ"]) { channelMethod = @"positionChannel3D"; axis = @"z"; }
    else if ([property isEqualToString:@"scaleX"]) { channelMethod = @"scaleChannel3D"; axis = @"x"; }
    else if ([property isEqualToString:@"scaleY"]) { channelMethod = @"scaleChannel3D"; axis = @"y"; }
    else if ([property isEqualToString:@"rotation"]) { channelMethod = @"rotationChannel3D"; axis = @"z"; }
    else if ([property isEqualToString:@"anchorX"]) { channelMethod = @"anchorChannel3D"; axis = @"x"; }
    else if ([property isEqualToString:@"anchorY"]) { channelMethod = @"anchorChannel3D"; axis = @"y"; }
    else return NO;
    if (outMethod) *outMethod = channelMethod;
    if (outAxis) *outAxis = axis;
    return YES;
}

static NSString *SpliceKit_inspectorSetUnknownPropertyError(NSString *property) {
    return [NSString stringWithFormat:
        @"Unknown inspector property '%@'. "
        @"Accepted names: opacity, positionX, positionY, positionZ, scaleX, scaleY, "
        @"rotation, anchorX, anchorY, volume, handle:<object handle>. "
        @"These are keys like positionX, not inspector labels like Position X.",
        property ?: @""];
}

NSDictionary *SpliceKit_handleInspectorSet(NSDictionary *params) {
    NSString *property = params[@"property"]; // "opacity", "positionX", "positionY", "rotation", "scaleX", "scaleY", "volume", etc.
    NSNumber *value = params[@"value"];
    if (!property || !value) return @{@"error": @"property and value parameters required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id clip = nil;
            id effectStack = SpliceKit_getSelectedClipEffectStack(timeline, &clip);
            if (!effectStack) { result = @{@"error": @"No clip selected or clip has no effect stack"}; return; }

            double val = [value doubleValue];
            NSString *transformMethod = nil;
            NSString *transformAxis = nil;
            BOOL setOpacity = [property isEqualToString:@"opacity"];
            BOOL setTransform = SpliceKit_inspectorTransformChannel(property, &transformMethod, &transformAxis);
            BOOL setVolume = [property isEqualToString:@"volume"];
            BOOL setHandle = [property hasPrefix:@"handle:"];
            // Recognise the name before opening an undo scope. An unrecognised name
            // (an inspector label such as "Position X", or a prefix that maps to no
            // channel) used to begin and end "Set <property>" with nothing inside it.
            if (!setOpacity && !setTransform && !setVolume && !setHandle) {
                result = @{@"error": SpliceKit_inspectorSetUnknownPropertyError(property)};
                return;
            }

            BOOL success = NO;
            NSString *desc = [NSString stringWithFormat:@"Set %@", property];

            // Begin undo action only once a branch below will run.
            @try {
                SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
                if ([effectStack respondsToSelector:beginSel]) {
                    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                        effectStack, beginSel, desc, nil, YES);
                }
            } @catch (NSException *e) {}

            // OPACITY
            if (setOpacity) {
                @try {
                    SEL bSel = NSSelectorFromString(@"intrinsicCompositeEffectCreateIfAbsent:");
                    id blendEffect = ((id (*)(id, SEL, BOOL))objc_msgSend)(effectStack, bSel, YES);
                    id opChan = ((id (*)(id, SEL))objc_msgSend)(blendEffect, NSSelectorFromString(@"opacityChannel"));
                    success = SpliceKit_setChannelValue(opChan, val);
                } @catch (NSException *e) {}
            }
            // TRANSFORM: positionX/Y/Z, scaleX/Y, rotation, anchorX/Y
            else if (setTransform) {
                @try {
                    // Get or create xform3D effect
                    id xfEffect = nil;
                    SEL xfSel = NSSelectorFromString(@"xform3DEffect");
                    if ([effectStack respondsToSelector:xfSel])
                        xfEffect = ((id (*)(id, SEL))objc_msgSend)(effectStack, xfSel);
                    // Create if absent using the known effect ID
                    if (!xfEffect) {
                        SEL addSel = NSSelectorFromString(@"addIntrinsicEffectForEffectID:");
                        if ([effectStack respondsToSelector:addSel]) {
                            xfEffect = ((id (*)(id, SEL, id))objc_msgSend)(
                                effectStack, addSel, @"HEXForm3D");
                        }
                    }
                    if (xfEffect) {
                        id ch3d = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(transformMethod));
                        id axisCh = SpliceKit_subChannel(ch3d, transformAxis);
                        success = SpliceKit_setChannelValue(axisCh, val);
                    }
                } @catch (NSException *e) {}
            }
            // VOLUME
            else if (setVolume) {
                @try {
                    SEL volSel = NSSelectorFromString(@"audioLevelChannel");
                    id volChan = [effectStack respondsToSelector:volSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(effectStack, volSel) : nil;
                    if (volChan) success = SpliceKit_setChannelValue(volChan, val);
                } @catch (NSException *e) {}
            }
            // CHANNEL BY HANDLE (generic - set any channel by its handle)
            else if ([property hasPrefix:@"handle:"]) {
                NSString *handle = [property substringFromIndex:7];
                id channel = SpliceKit_resolveHandle(handle);
                if (channel) success = SpliceKit_setChannelValue(channel, val);
                else result = @{@"error": @"Handle not found"};
            }

            // End undo action
            @try {
                SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
                if ([effectStack respondsToSelector:endSel]) {
                    ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                        effectStack, endSel, desc, YES, nil);
                }
            } @catch (NSException *e) {}

            if (!result) {
                result = success
                    ? @{@"status": @"ok", @"property": property, @"value": @(val)}
                    : @{@"error": [NSString stringWithFormat:@"Failed to set '%@'", property]};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Inspector set failed"};
}

#pragma mark - Title Text Inspection

// Walk CHChannelFolder tree to find CHChannelText instances and read their content.
// Returns text string, font info (from NSAttributedString), and channel metadata.
void SpliceKit_collectTitleText(id folder, NSMutableArray *results, int depth) {
    if (!folder || depth > 12) return;

    // Check if this is a CHChannelText (has -string and -attributedString)
    Class chTextClass = objc_getClass("CHChannelText");
    if (chTextClass && [folder isKindOfClass:chTextClass]) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];

        @try {
            SEL strSel = NSSelectorFromString(@"string");
            if ([folder respondsToSelector:strSel]) {
                id str = ((id (*)(id, SEL))objc_msgSend)(folder, strSel);
                if (str) entry[@"text"] = [str description];
            }
        } @catch (NSException *e) {}

        // Extract font info from NSAttributedString
        @try {
            SEL asSel = NSSelectorFromString(@"attributedString");
            if ([folder respondsToSelector:asSel]) {
                NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(folder, asSel);
                if (attrStr && attrStr.length > 0) {
                    NSDictionary *attrs = [attrStr attributesAtIndex:0 effectiveRange:NULL];
                    NSFont *font = attrs[NSFontAttributeName];
                    if (font) {
                        entry[@"fontName"] = font.fontName;
                        entry[@"fontFamily"] = font.familyName;
                        entry[@"fontSize"] = @(font.pointSize);
                    }
                    NSColor *color = attrs[NSForegroundColorAttributeName];
                    if (color) {
                        NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
                        if (rgb) {
                            entry[@"textColor"] = [NSString stringWithFormat:@"%.3f %.3f %.3f %.3f",
                                rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent];
                        }
                    }
                }
            }
        } @catch (NSException *e) {}

        // Channel metadata
        @try {
            SEL nameSel = NSSelectorFromString(@"name");
            if ([folder respondsToSelector:nameSel]) {
                id name = ((id (*)(id, SEL))objc_msgSend)(folder, nameSel);
                if (name) entry[@"channelName"] = [name description];
            }
            SEL idSel = NSSelectorFromString(@"channelID");
            if ([folder respondsToSelector:idSel]) {
                long long cid = ((long long (*)(id, SEL))objc_msgSend)(folder, idSel);
                entry[@"channelID"] = @(cid);
            }
        } @catch (NSException *e) {}

        entry[@"handle"] = SpliceKit_storeHandle(folder);
        [results addObject:entry];
    }

    // Recurse into children (CHChannelFolder)
    @try {
        SEL childrenSel = NSSelectorFromString(@"children");
        if ([folder respondsToSelector:childrenSel]) {
            NSArray *children = ((id (*)(id, SEL))objc_msgSend)(folder, childrenSel);
            if ([children isKindOfClass:[NSArray class]]) {
                for (id child in children) {
                    SpliceKit_collectTitleText(child, results, depth + 1);
                }
            }
        }
    } @catch (NSException *e) {}
}

NSDictionary *SpliceKit_handleInspectorGetTitle(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id clip = nil;
            id effectStack = SpliceKit_getSelectedClipEffectStack(timeline, &clip);
            if (!clip) { result = @{@"error": @"No clips selected"}; return; }

            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"class"] = NSStringFromClass([clip class]);
            @try {
                if ([clip respondsToSelector:@selector(displayName)]) {
                    id n = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
                    if (n) info[@"name"] = [n description];
                }
            } @catch (NSException *e) {}

            // Walk the generator's own effect for text channels first.
            // Motion titles: text is on clip.effect.channelFolder, not effectStack.visibleEffects.
            NSMutableArray *textChannels = [NSMutableArray array];
            NSMutableArray *effectNames = [NSMutableArray array];

            // Primary path: clip.effect (FFAnchoredEffectComponent)
            @try {
                SEL effectSel = NSSelectorFromString(@"effect");
                id genEffect = [clip respondsToSelector:effectSel]
                    ? ((id (*)(id, SEL))objc_msgSend)(clip, effectSel) : nil;
                if (genEffect) {
                    SEL cfSel = NSSelectorFromString(@"channelFolder");
                    id cf = [genEffect respondsToSelector:cfSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(genEffect, cfSel) : nil;
                    if (cf) SpliceKit_collectTitleText(cf, textChannels, 0);
                }
            } @catch (NSException *e) {}

            // Fallback: effectStack.visibleEffects
            if (textChannels.count == 0 && effectStack) {
                @try {
                    SEL efSel = NSSelectorFromString(@"visibleEffects");
                    if ([effectStack respondsToSelector:efSel]) {
                        NSArray *effects = ((id (*)(id, SEL))objc_msgSend)(effectStack, efSel);
                        for (id effect in effects) {
                            NSString *efName = @"(unknown)";
                            @try {
                                if ([effect respondsToSelector:@selector(displayName)])
                                    efName = [((id (*)(id, SEL))objc_msgSend)(effect, @selector(displayName)) description];
                            } @catch (NSException *e) {}
                            [effectNames addObject:efName];

                            SEL cfSel = NSSelectorFromString(@"channelFolder");
                            if ([effect respondsToSelector:cfSel]) {
                                id cf = ((id (*)(id, SEL))objc_msgSend)(effect, cfSel);
                                if (cf) SpliceKit_collectTitleText(cf, textChannels, 0);
                            }
                        }
                    }
                } @catch (NSException *e) {}
            }

            info[@"effectNames"] = effectNames;
            info[@"textChannelCount"] = @(textChannels.count);

            NSMutableDictionary *res = [NSMutableDictionary dictionary];
            res[@"info"] = info;
            if (textChannels.count > 0) {
                res[@"textChannels"] = textChannels;
                // Convenience: surface first text channel's data at top level
                NSDictionary *first = textChannels.firstObject;
                if (first[@"text"]) res[@"text"] = first[@"text"];
                if (first[@"fontSize"]) res[@"fontSize"] = first[@"fontSize"];
                if (first[@"fontFamily"]) res[@"fontFamily"] = first[@"fontFamily"];
                if (first[@"fontName"]) res[@"fontName"] = first[@"fontName"];
            }
            result = res;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Title inspection failed"};
}
