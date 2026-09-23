//
//  SpliceKitTranscriptPanel+Clips.m
//  Collecting the timeline clips to transcribe (primary storyline and connected
//  clips, trims, volume) and finding each clip's media file.
//

#import "SpliceKitTranscriptPanel+Private.h"

@implementation SpliceKitTranscriptPanel (Clips)

// Walks the spine (primary storyline) and also pulls in anchoredItems from each
// spine item so connected clips on higher/lower lanes are transcribable.
// Primary storyline timing still advances sequentially, but connected clips use
// absolute positions via effectiveRangeOfObject: so they do not perturb spine time.
- (void)collectClipsFrom:(NSArray *)items
            primaryObject:(id)primaryObject
               atTimeline:(double *)timelinePos
                     into:(NSMutableArray *)clipInfos {
    for (id item in items) {
        NSString *className = NSStringFromClass([item class]);
        double itemTimelineStart = *timelinePos;

        double clipDuration = 0;
        if ([item respondsToSelector:@selector(duration)]) {
            CMTime d = ((CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
            clipDuration = SpliceKit_secondsFromTime(d);
        }

        BOOL isMedia = [className containsString:@"MediaComponent"];
        BOOL isCollection = [className containsString:@"Collection"] || [className containsString:@"AnchoredClip"];
        BOOL isTransition = [className containsString:@"Transition"];

        if (isMedia && clipDuration > 0) {
            [self addTimelineObject:item
                   defaultTimeline:itemTimelineStart
                      primaryObject:primaryObject
                               into:clipInfos];

        } else if (isCollection && clipDuration > 0) {
            [self addTimelineObject:item
                   defaultTimeline:itemTimelineStart
                      primaryObject:primaryObject
                               into:clipInfos];
        }

        // Connected clips (B-roll, music, a muted reference take) are left out when
        // only the primary storyline is wanted — the cut is judged on the spine.
        if (!self.primaryStorylineOnly) {
            for (id anchoredItem in [self anchoredItemsForTimelineItem:item]) {
                NSUInteger before = clipInfos.count;
                [self addTimelineObject:anchoredItem
                       defaultTimeline:itemTimelineStart
                          primaryObject:primaryObject
                                   into:clipInfos];
                for (NSUInteger i = before; i < clipInfos.count; i++) {
                    clipInfos[i][@"connected"] = @YES;
                }
            }
        }

        if (!isTransition) {
            *timelinePos += clipDuration;
        }
    }
}

- (NSArray *)anchoredItemsForTimelineItem:(id)item {
    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    if (![item respondsToSelector:anchoredSel]) return @[];

    id anchoredRaw = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
    if ([anchoredRaw isKindOfClass:[NSArray class]]) return anchoredRaw;
    if ([anchoredRaw isKindOfClass:[NSSet class]]) return [(NSSet *)anchoredRaw allObjects];
    return @[];
}

- (BOOL)effectiveRangeForTimelineObject:(id)item
                          primaryObject:(id)primaryObject
                                  start:(double *)startOut
                               duration:(double *)durationOut {
    if (startOut) *startOut = 0;
    if (durationOut) *durationOut = 0;
    if (!item || !primaryObject) return NO;

    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (![primaryObject respondsToSelector:erSel]) return NO;

    @try {
        CMTimeRange range =
            ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(primaryObject, erSel, item);
        double start = SpliceKit_secondsFromTime(range.start);
        double duration = SpliceKit_secondsFromTime(range.duration);
        if (duration <= 0) return NO;
        if (startOut) *startOut = start;
        if (durationOut) *durationOut = duration;
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

- (double)anchoredOffsetForTimelineObject:(id)item {
    SEL offsetSel = NSSelectorFromString(@"anchoredOffset");
    if (![item respondsToSelector:offsetSel]) return -1;

    @try {
        CMTime offset =
            ((CMTime (*)(id, SEL))STRET_MSG)(item, offsetSel);
        return SpliceKit_secondsFromTime(offset);
    } @catch (__unused NSException *e) {
        return -1;
    }
}

- (void)addTimelineObject:(id)item
          defaultTimeline:(double)defaultTimelinePos
             primaryObject:(id)primaryObject
                      into:(NSMutableArray *)clipInfos {
    if (!item) return;

    NSString *className = NSStringFromClass([item class]) ?: @"";
    BOOL isMedia = [className containsString:@"MediaComponent"];
    BOOL isCollection = [className containsString:@"Collection"];
    // FFAnchoredClip is an FFAnchoredMediaRef (has media/clipRef directly) — not a
    // container. Treat it as a media clip, not a collection to dig into.
    BOOL isMediaRef = [className containsString:@"AnchoredClip"] || [className containsString:@"MediaRef"];
    if (!isMedia && !isCollection && !isMediaRef) return;

    double clipDuration = 0;
    if ([item respondsToSelector:@selector(duration)]) {
        CMTime d = ((CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
        clipDuration = SpliceKit_secondsFromTime(d);
    }
    if (clipDuration <= 0) return;

    double timelineStart = defaultTimelinePos;
    double effectiveDuration = clipDuration;
    if (![self effectiveRangeForTimelineObject:item
                                  primaryObject:primaryObject
                                          start:&timelineStart
                                       duration:&effectiveDuration]) {
        double anchoredOffset = [self anchoredOffsetForTimelineObject:item];
        if (anchoredOffset >= 0) timelineStart = anchoredOffset;
    }

    if (isMedia || isMediaRef) {
        [self addMediaClip:item
              timelineObject:item
                   duration:effectiveDuration
                 atTimeline:timelineStart
                       into:clipInfos];
        return;
    }

    SpliceKit_log(@"[Transcript] Collection: %@ (%.2fs) at %.2fs", className, effectiveDuration, timelineStart);

    id innerMedia = [self findFirstMediaInContainer:item];
    if (!innerMedia) return;

    double collTrimStart = 0;
    CMTimeRange collClipped;
    if ([self readTimeRange:@"clippedRange" of:item into:&collClipped]) {
        collTrimStart = SpliceKit_secondsFromTime(collClipped.start);
        SpliceKit_log(@"[Transcript]   collection clippedRange: start=%.2fs dur=%.2fs",
                      collTrimStart, SpliceKit_secondsFromTime(collClipped.duration));
    }

    // A clip whose frame rate FCP conforms to the project's (30 fps media in a 29.97
    // project) keeps the collection's ranges in conformed time and the media
    // component's in the file's own time: 30 fps media starting at timecode 74435 s
    // reads 74509.435 s on the collection. Subtracting one from the other put the
    // transcript window 74 s into a 45 s file, so the clip got no words. The two
    // full (unclipped) ranges give the factor between the spaces.
    // Only for a collection that wraps one clip's media (an asset-clip). A compound
    // or multicam clip holds a whole timeline, so its range against its first inner
    // clip's says nothing about rate: a 120 s compound over a 40 s clip read as 3x.
    // FCP's automatic rate conform only joins close rates (23.98/24/25, 29.97/30),
    // so a real factor is within a few percent of 1.
    double rateFactor = 1.0;
    BOOL isContainerOfClips = NO;
    for (NSString *flag in @[@"isReferenceClip", @"isCompoundClip", @"isMultiAngle", @"isMulticam"]) {
        SEL sel = NSSelectorFromString(flag);
        NSMethodSignature *sig = [item respondsToSelector:sel] ? [item methodSignatureForSelector:sel] : nil;
        if (sig && sig.methodReturnLength == sizeof(BOOL) && sig.numberOfArguments == 2) {
            @try {
                if (((BOOL (*)(id, SEL))objc_msgSend)(item, sel)) { isContainerOfClips = YES; break; }
            } @catch (__unused NSException *e) {}
        }
    }
    CMTimeRange collFull, mediaFull;
    if (!isContainerOfClips &&
        [self readTimeRange:@"unclippedRange" of:item into:&collFull] &&
        [self readTimeRange:@"unclippedRange" of:innerMedia into:&mediaFull]) {
        double collStart = SpliceKit_secondsFromTime(collFull.start), collDur = SpliceKit_secondsFromTime(collFull.duration);
        double mediaStart = SpliceKit_secondsFromTime(mediaFull.start), mediaDur = SpliceKit_secondsFromTime(mediaFull.duration);
        if (collDur > 0 && mediaDur > 0) {
            double factor = collDur / mediaDur;
            BOOL spacesDiffer = fabs(factor - 1.0) > 1e-5 || fabs(collStart - mediaStart) > 0.001;
            if (spacesDiffer && isfinite(factor) && factor > 0.95 && factor < 1.05) {
                double mediaTrim = mediaStart + (collTrimStart - collStart) / factor;
                SpliceKit_log(@"[Transcript]   rate conform: collection %.3fs+%.3fs vs media %.3fs+%.3fs "
                              @"(factor %.6f); trim %.3fs -> %.3fs in media time",
                              collStart, collDur, mediaStart, mediaDur, factor, collTrimStart, mediaTrim);
                collTrimStart = mediaTrim;
                rateFactor = factor;
            }
        }
    }

    NSUInteger before = clipInfos.count;
    [self addMediaClip:innerMedia
          timelineObject:item
               duration:effectiveDuration
              trimStart:collTrimStart
             atTimeline:timelineStart
                   into:clipInfos];
    if (rateFactor != 1.0) {
        for (NSUInteger i = before; i < clipInfos.count; i++) clipInfos[i][@"rateFactor"] = @(rateFactor);
    }
}

- (BOOL)readTimeRange:(NSString *)selectorName of:(id)object into:(CMTimeRange *)out {
    SEL sel = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:sel]) return NO;
    @try {
        NSMethodSignature *sig = [object methodSignatureForSelector:sel];
        if (!sig || [sig methodReturnLength] != sizeof(CMTimeRange)) return NO;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:object];
        [inv setSelector:sel];
        [inv invoke];
        [inv getReturnValue:out];
        return out->start.timescale > 0 && out->duration.timescale > 0;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

- (id)findFirstMediaInContainer:(id)container {
    id subItems = nil;
    if ([container respondsToSelector:@selector(containedItems)]) {
        subItems = ((id (*)(id, SEL))objc_msgSend)(container, @selector(containedItems));
    }
    if ((!subItems || ![subItems isKindOfClass:[NSArray class]] || [(NSArray *)subItems count] == 0) &&
        [container respondsToSelector:@selector(primaryObject)]) {
        id primary = ((id (*)(id, SEL))objc_msgSend)(container, @selector(primaryObject));
        if (primary && [primary respondsToSelector:@selector(containedItems)]) {
            subItems = ((id (*)(id, SEL))objc_msgSend)(primary, @selector(containedItems));
        }
    }
    if (!subItems || ![subItems isKindOfClass:[NSArray class]]) return nil;

    for (id sub in (NSArray *)subItems) {
        NSString *cls = NSStringFromClass([sub class]);
        if ([cls containsString:@"MediaComponent"]) return sub;
        if ([cls containsString:@"Collection"] || [cls containsString:@"AnchoredClip"]) {
            id found = [self findFirstMediaInContainer:sub];
            if (found) return found;
        }
    }
    return nil;
}

- (void)addMediaClip:(id)clip timelineObject:(id)timelineObject duration:(double)clipDuration atTimeline:(double)timelinePos into:(NSMutableArray *)clipInfos {
    double trimStart = 0;
    CMTimeRange unclipped;
    if ([self readTimeRange:@"unclippedRange" of:clip into:&unclipped]) {
        trimStart = SpliceKit_secondsFromTime(unclipped.start);
    }
    [self addMediaClip:clip
          timelineObject:timelineObject
               duration:clipDuration
              trimStart:trimStart
             atTimeline:timelinePos
                   into:clipInfos];
}

// The clip's volume in dB, or NAN when the object has no readable volume. The
// Volume channel (CHChannelDecibel) holds linear gain: 1.0 is 0 dB and -96 dB, FCP's
// floor, reads as ~0. A clip that FCP wraps in a collection (an asset-clip with
// connected clips, most imported clips) keeps it on -audioEffects; a bare media
// component on -effectStack. Verified on FCP 12.3.
- (double)volumeDBForTimelineObject:(id)item {
    if (!item) return NAN;
    for (NSString *stackName in @[@"audioEffects", @"effectStack"]) {
        @try {
            SEL stackSel = NSSelectorFromString(stackName);
            id stack = [item respondsToSelector:stackSel] ? ((id (*)(id, SEL))objc_msgSend)(item, stackSel) : nil;
            SEL volSel = NSSelectorFromString(@"audioLevelChannel");
            id channel = [stack respondsToSelector:volSel] ? ((id (*)(id, SEL))objc_msgSend)(stack, volSel) : nil;
            if (!channel) continue;
            CMTime indefinite = {0, 0, 17, 0};
            double gain = NAN;
            SEL curveSel = NSSelectorFromString(@"curveDoubleValueAtTime:");
            SEL valSel = NSSelectorFromString(@"doubleValueAtTime:");
            if ([channel respondsToSelector:curveSel]) {
                gain = ((double (*)(id, SEL, CMTime))objc_msgSend)(channel, curveSel, indefinite);
            } else if ([channel respondsToSelector:valSel]) {
                gain = ((double (*)(id, SEL, CMTime))objc_msgSend)(channel, valSel, indefinite);
            }
            if (!isfinite(gain)) continue;
            return gain > 1e-6 ? 20.0 * log10(gain) : -INFINITY;
        } @catch (__unused NSException *e) {
        }
    }
    return NAN;
}

- (void)addMediaClip:(id)clip timelineObject:(id)timelineObject duration:(double)clipDuration trimStart:(double)trimStart
          atTimeline:(double)timelinePos into:(NSMutableArray *)clipInfos {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    // The wrapper and the component can each carry a level; the quieter one wins.
    double volumeDB = [self volumeDBForTimelineObject:timelineObject];
    if (clip != timelineObject) {
        double inner = [self volumeDBForTimelineObject:clip];
        if (!isnan(inner) && (isnan(volumeDB) || inner < volumeDB)) volumeDB = inner;
    }
    if (!isnan(volumeDB)) info[@"volumeDB"] = @(isinf(volumeDB) ? -200.0 : volumeDB);
    info[@"timelineStart"] = @(timelinePos);
    info[@"duration"] = @(clipDuration);
    info[@"handle"] = SpliceKit_storeHandle(clip);
    info[@"className"] = NSStringFromClass([clip class]);
    info[@"trimStart"] = @(trimStart);
    if (timelineObject) info[@"timelineObject"] = timelineObject;
    if (clip) info[@"mediaObject"] = clip;

    // Get the media's timecode origin (unclippedRange.start) for coordinate conversion.
    // FCP stores times in the source media's timecode space, but external ASR tools
    // like Parakeet return file-relative timestamps starting from 0.
    double mediaOrigin = 0;
    CMTimeRange originRange;
    if ([self readTimeRange:@"unclippedRange" of:clip into:&originRange]) {
        mediaOrigin = SpliceKit_secondsFromTime(originRange.start);
    }
    info[@"mediaOrigin"] = @(mediaOrigin);

    if ([clip respondsToSelector:@selector(displayName)]) {
        id name = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
        info[@"name"] = name ?: @"Untitled";
    }

    NSURL *mediaURL = [self getMediaURLForClip:clip];
    if (mediaURL) {
        info[@"mediaURL"] = mediaURL;
    }

    SpliceKit_log(@"[Transcript] Clip at %.2fs (dur=%.2fs, trim=%.2fs, mediaOrigin=%.2fs): %@ -> %@",
                  timelinePos, clipDuration, trimStart, mediaOrigin, info[@"name"],
                  mediaURL ? [mediaURL path] : @"(no URL)");

    [clipInfos addObject:info];
}

- (NSArray *)collectClipInfosForSequence:(id)sequence primaryObject:(id)primaryObject errorMessage:(NSString **)errorMessageOut {
    if (errorMessageOut) *errorMessageOut = nil;
    if (!sequence) {
        if (errorMessageOut) *errorMessageOut = @"No sequence in timeline.";
        return nil;
    }
    if (!primaryObject) {
        if (errorMessageOut) *errorMessageOut = @"No primary object in sequence.";
        return nil;
    }

    id items = nil;
    if ([primaryObject respondsToSelector:@selector(containedItems)]) {
        items = ((id (*)(id, SEL))objc_msgSend)(primaryObject, @selector(containedItems));
    }
    if (!items || ![items isKindOfClass:[NSArray class]]) {
        if (errorMessageOut) *errorMessageOut = @"No items on timeline.";
        return nil;
    }

    NSMutableArray *clipInfos = [NSMutableArray array];
    double timelinePos = 0;
    [self collectClipsFrom:(NSArray *)items primaryObject:primaryObject atTimeline:&timelinePos into:clipInfos];
    return [clipInfos copy];
}

- (void)performTimelineTranscription {
    if (self.engine == SpliceKitTranscriptEngineFCPNative) {
        [self performFCPNativeTranscription];
    } else if (self.engine == SpliceKitTranscriptEngineParakeet) {
        [self performParakeetTranscription];
    } else {
        [self performAppleSpeechTranscription];
    }
}

- (id)transcriptAssetCandidateForClipInfo:(NSDictionary *)clipInfo assetsSelector:(SEL)assetsSel {
    id candidate = clipInfo[@"timelineObject"] ?: clipInfo[@"mediaObject"];
    if (![candidate respondsToSelector:assetsSel]) {
        candidate = clipInfo[@"mediaObject"];
    }
    return [candidate respondsToSelector:assetsSel] ? candidate : nil;
}

- (NSString *)mediaPathForTranscriptAsset:(id)asset {
    if (!asset) return nil;

    NSArray<NSString *> *pathsToTry = @[
        @"resolvedURL",
        @"originalMediaURL",
        @"URL",
        @"assetMediaReference.resolvedURL",
        @"media.originalMediaURL",
        @"originalMediaRep.URL",
    ];

    for (NSString *keyPath in pathsToTry) {
        @try {
            id value = [asset valueForKeyPath:keyPath];
            if ([value isKindOfClass:[NSURL class]]) {
                return [(NSURL *)value path];
            }
        } @catch (__unused NSException *e) {
        }
    }

    return nil;
}

#pragma mark - Media URL Discovery

- (NSURL *)getMediaURLForClip:(id)clip {
    // Chain 1: clip.media.originalMediaURL
    @try {
        if ([clip respondsToSelector:NSSelectorFromString(@"media")]) {
            id media = ((id (*)(id, SEL))objc_msgSend)(clip, NSSelectorFromString(@"media"));
            if (media) {
                SEL omSel = NSSelectorFromString(@"originalMediaURL");
                if ([media respondsToSelector:omSel]) {
                    id url = ((id (*)(id, SEL))objc_msgSend)(media, omSel);
                    if (url && [url isKindOfClass:[NSURL class]]) return url;
                }

                SEL omrSel = NSSelectorFromString(@"originalMediaRep");
                if ([media respondsToSelector:omrSel]) {
                    id rep = ((id (*)(id, SEL))objc_msgSend)(media, omrSel);
                    if (rep) {
                        SEL fuSel = NSSelectorFromString(@"fileURLs");
                        if ([rep respondsToSelector:fuSel]) {
                            id urls = ((id (*)(id, SEL))objc_msgSend)(rep, fuSel);
                            if ([urls isKindOfClass:[NSArray class]] && [(NSArray *)urls count] > 0) {
                                id url = [(NSArray *)urls firstObject];
                                if ([url isKindOfClass:[NSURL class]]) return url;
                            }
                        }
                        SEL urlSel = NSSelectorFromString(@"URL");
                        if ([rep respondsToSelector:urlSel]) {
                            id url = ((id (*)(id, SEL))objc_msgSend)(rep, urlSel);
                            if ([url isKindOfClass:[NSURL class]]) return url;
                        }
                    }
                }

                SEL crSel = NSSelectorFromString(@"currentRep");
                if ([media respondsToSelector:crSel]) {
                    id rep = ((id (*)(id, SEL))objc_msgSend)(media, crSel);
                    if (rep) {
                        SEL fuSel = NSSelectorFromString(@"fileURLs");
                        if ([rep respondsToSelector:fuSel]) {
                            id urls = ((id (*)(id, SEL))objc_msgSend)(rep, fuSel);
                            if ([urls isKindOfClass:[NSArray class]] && [(NSArray *)urls count] > 0) {
                                id url = [(NSArray *)urls firstObject];
                                if ([url isKindOfClass:[NSURL class]]) return url;
                            }
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Transcript] Exception getting media URL (chain 1): %@", e.reason);
    }

    // Chain 1b: FFAnchoredClip -> clipRef (FFClipRef) -> assets -> FFAsset -> originalMediaURL
    // FFAnchoredClip is a media reference, not a container. Its .media returns FFClipRef
    // which doesn't have file URLs directly, but its .assets set contains FFAsset objects.
    @try {
        SEL clipRefSel = NSSelectorFromString(@"clipRef");
        if ([clip respondsToSelector:clipRefSel]) {
            id clipRef = ((id (*)(id, SEL))objc_msgSend)(clip, clipRefSel);
            if (clipRef) {
                SEL assetsSel = NSSelectorFromString(@"assets");
                if ([clipRef respondsToSelector:assetsSel]) {
                    id assets = ((id (*)(id, SEL))objc_msgSend)(clipRef, assetsSel);
                    NSArray *assetArray = nil;
                    if ([assets isKindOfClass:[NSSet class]]) assetArray = [(NSSet *)assets allObjects];
                    else if ([assets isKindOfClass:[NSArray class]]) assetArray = assets;
                    for (id asset in assetArray) {
                        SEL omSel = NSSelectorFromString(@"originalMediaURL");
                        if ([asset respondsToSelector:omSel]) {
                            id url = ((id (*)(id, SEL))objc_msgSend)(asset, omSel);
                            if ([url isKindOfClass:[NSURL class]]) return url;
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Transcript] Exception getting media URL (chain 1b clipRef): %@", e.reason);
    }

    // Chain 2: clip.assetMediaReference -> resolvedURL
    @try {
        SEL amrSel = NSSelectorFromString(@"assetMediaReference");
        if ([clip respondsToSelector:amrSel]) {
            id ref = ((id (*)(id, SEL))objc_msgSend)(clip, amrSel);
            if (ref) {
                SEL ruSel = NSSelectorFromString(@"resolvedURL");
                if ([ref respondsToSelector:ruSel]) {
                    id url = ((id (*)(id, SEL))objc_msgSend)(ref, ruSel);
                    if ([url isKindOfClass:[NSURL class]]) return url;
                }
            }
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Transcript] Exception getting media URL (chain 2): %@", e.reason);
    }

    // Chain 3: KVC path clip.media.fileURL
    @try {
        id url = [clip valueForKeyPath:@"media.fileURL"];
        if ([url isKindOfClass:[NSURL class]]) return url;
    } @catch (NSException *e) {}

    // Chain 4: KVC path clip.clipInPlace.asset.originalMediaURL
    @try {
        id url = [clip valueForKeyPath:@"clipInPlace.asset.originalMediaURL"];
        if ([url isKindOfClass:[NSURL class]]) return url;
    } @catch (NSException *e) {}

    // Chain 5: iterate properties looking for NSURL
    @try {
        if ([clip respondsToSelector:NSSelectorFromString(@"media")]) {
            id media = ((id (*)(id, SEL))objc_msgSend)(clip, NSSelectorFromString(@"media"));
            if (media) {
                unsigned int propCount = 0;
                Class cls = [media class];
                while (cls && cls != [NSObject class]) {
                    objc_property_t *props = class_copyPropertyList(cls, &propCount);
                    for (unsigned int i = 0; i < propCount; i++) {
                        NSString *propName = @(property_getName(props[i]));
                        if ([propName.lowercaseString containsString:@"url"] ||
                            [propName.lowercaseString containsString:@"path"] ||
                            [propName.lowercaseString containsString:@"file"]) {
                            @try {
                                id val = [media valueForKey:propName];
                                if ([val isKindOfClass:[NSURL class]]) {
                                    free(props);
                                    return val;
                                }
                                if ([val isKindOfClass:[NSString class]] &&
                                    [(NSString *)val hasPrefix:@"/"]) {
                                    NSURL *url = [NSURL fileURLWithPath:val];
                                    if ([[NSFileManager defaultManager] fileExistsAtPath:val]) {
                                        free(props);
                                        return url;
                                    }
                                }
                            } @catch (NSException *e) {}
                        }
                    }
                    free(props);
                    cls = class_getSuperclass(cls);
                }
            }
        }
    } @catch (NSException *e) {}

    return nil;
}

@end
