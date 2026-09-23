//
//  SpliceKitServerStructure.m
//  SpliceKit - Song structure blocks: structure captions and the structure storyline,
//  spine gap records, caption and title discovery on a sequence, and native caption removal.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Song structure blocks (captions + storyline removal / placement)

static NSString * const kSpliceKitStructureStorylineName = @"SpliceKit Structure";

static id SpliceKit_structurePrimaryObject(id sequence) {
    if (!sequence) return nil;
    SEL sel = NSSelectorFromString(@"primaryObject");
    if (![sequence respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(sequence, sel);
}

static NSUInteger SpliceKit_structureCountStorylinesNamed(id sequence, NSString *name) {
    id primary = SpliceKit_structurePrimaryObject(sequence);
    if (!primary) return 0;

    SEL itemsSel = NSSelectorFromString(@"containedItems");
    NSArray *items = [primary respondsToSelector:itemsSel]
        ? ((id (*)(id, SEL))objc_msgSend)(primary, itemsSel) : nil;
    if (![items isKindOfClass:[NSArray class]]) return 0;

    NSUInteger count = 0;
    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    SEL displayNameSel = NSSelectorFromString(@"displayName");

    for (id item in items) {
        if (![item respondsToSelector:anchoredSel]) continue;
        id anchoredRaw = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
        NSArray *anchored = SpliceKit_mixerArrayFromContainer(anchoredRaw);
        if (!anchored.count) continue;

        for (id obj in anchored) {
            NSString *className = NSStringFromClass([obj class]) ?: @"";
            if (![className containsString:@"Collection"]) continue;

            NSString *dn = nil;
            @try {
                if ([obj respondsToSelector:displayNameSel]) {
                    id n = ((id (*)(id, SEL))objc_msgSend)(obj, displayNameSel);
                    if ([n isKindOfClass:[NSString class]]) dn = n;
                }
            } @catch (NSException *e) {}

            if (name.length > 0 && [dn isEqualToString:name]) {
                count++;
            }
        }
    }
    return count;
}

static NSUInteger SpliceKit_structureRemoveStorylineNamed(id sequence, NSString *name) {
    id primary = SpliceKit_structurePrimaryObject(sequence);
    if (!primary) return 0;

    SEL itemsSel = NSSelectorFromString(@"containedItems");
    NSArray *items = [primary respondsToSelector:itemsSel]
        ? ((id (*)(id, SEL))objc_msgSend)(primary, itemsSel) : nil;
    if (![items isKindOfClass:[NSArray class]]) return 0;

    NSUInteger removed = 0;
    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    SEL displayNameSel = NSSelectorFromString(@"displayName");
    SEL removeSel1 = NSSelectorFromString(@"removeAnchoredItemsObject:");
    SEL removeSel2 = NSSelectorFromString(@"removeAnchoredObject:");

    for (id item in items) {
        if (![item respondsToSelector:anchoredSel]) continue;
        id anchoredRaw = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
        NSArray *anchored = SpliceKit_mixerArrayFromContainer(anchoredRaw);
        if (!anchored.count) continue;

        for (id obj in anchored) {
            NSString *className = NSStringFromClass([obj class]) ?: @"";
            if (![className containsString:@"Collection"]) continue;

            NSString *dn = nil;
            @try {
                if ([obj respondsToSelector:displayNameSel]) {
                    id n = ((id (*)(id, SEL))objc_msgSend)(obj, displayNameSel);
                    if ([n isKindOfClass:[NSString class]]) dn = n;
                }
            } @catch (NSException *e) {}

            if (name.length > 0 && ![dn isEqualToString:name]) continue;

            if ([item respondsToSelector:removeSel1]) {
                ((void (*)(id, SEL, id))objc_msgSend)(item, removeSel1, obj);
                removed++;
            } else if ([item respondsToSelector:removeSel2]) {
                ((void (*)(id, SEL, id))objc_msgSend)(item, removeSel2, obj);
                removed++;
            }
        }
    }
    return removed;
}

// Captions created by structure.generateCaptions (session registry, keyed by sequence).
static NSMutableDictionary<NSString *, NSHashTable<id> *> *SpliceKit_structureCaptionRegistry(void) {
    static NSMutableDictionary *registry = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        registry = [NSMutableDictionary dictionary];
    });
    return registry;
}

static NSString *SpliceKit_structureSequenceRegistryKey(id sequence) {
    if (!sequence) return nil;
    return [NSString stringWithFormat:@"%p", sequence];
}

static NSHashTable<id> *SpliceKit_structureCaptionTableForSequence(id sequence, BOOL create) {
    NSString *key = SpliceKit_structureSequenceRegistryKey(sequence);
    if (!key.length) return nil;
    NSMutableDictionary *registry = SpliceKit_structureCaptionRegistry();
    NSHashTable<id> *table = registry[key];
    if (!table && create) {
        table = [NSHashTable weakObjectsHashTable];
        registry[key] = table;
    }
    return table;
}

static void SpliceKit_structureRegisterCaptions(id sequence, NSArray *captions) {
    if (!sequence || captions.count == 0) return;
    NSHashTable<id> *table = SpliceKit_structureCaptionTableForSequence(sequence, YES);
    for (id caption in captions) {
        if (caption) [table addObject:caption];
    }
}

static void SpliceKit_structureUnregisterCaptions(id sequence, NSArray *captions) {
    if (!sequence || captions.count == 0) return;
    NSHashTable<id> *table = SpliceKit_structureCaptionTableForSequence(sequence, NO);
    if (!table) return;
    for (id caption in captions) {
        if (caption) [table removeObject:caption];
    }
}

// The gap Final Cut Pro appends when structure captions extend past the sequence
// end. A previous per-sequence weak NSHashTable of gap pointers stayed empty:
// the before-snapshot and the registration walk used the sequence pointer captured
// before the temp-project switch, while paste lands on whatever loadEditorForSequence:
// makes active afterwards, and the walk ran before that gap was on containedItems.
// Pointer identity also dies when Final Cut Pro quits. Record the pre-paste
// duration instead, keyed by stable sequence identity, in this process's defaults.
static NSString * const kSpliceKitStructureGapDefaultsKey = @"SpliceKitStructureAppendedSpineGaps";

static NSString *SpliceKit_structureIdentifierString(id value) {
    if (!value || value == (id)kCFNull) return nil;
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value length] ? value : nil;
    }
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    if ([value isKindOfClass:[NSUUID class]]) return [(NSUUID *)value UUIDString];
    if ([value respondsToSelector:@selector(UUIDString)]) {
        @try {
            id s = ((id (*)(id, SEL))objc_msgSend)(value, @selector(UUIDString));
            if ([s isKindOfClass:[NSString class]] && [(NSString *)s length]) return s;
        } @catch (NSException *e) {}
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        @try {
            id s = ((id (*)(id, SEL))objc_msgSend)(value, @selector(stringValue));
            if ([s isKindOfClass:[NSString class]] && [(NSString *)s length]) return s;
        } @catch (NSException *e) {}
    }
    return nil;
}

static NSString *SpliceKit_structureObjectIdentifier(id obj, NSArray<NSString *> *selectors) {
    if (!obj) return nil;
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        if (![obj respondsToSelector:sel]) continue;
        id value = nil;
        @try {
            value = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
        } @catch (NSException *e) {
            continue;
        }
        NSString *s = SpliceKit_structureIdentifierString(value);
        if (s.length) return s;
    }
    return nil;
}

static id SpliceKit_structureRelatedObject(id obj, NSArray<NSString *> *selectors) {
    if (!obj) return nil;
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        if (![obj respondsToSelector:sel]) continue;
        id value = nil;
        @try {
            value = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
        } @catch (NSException *e) {
            continue;
        }
        if (value) return value;
    }
    return nil;
}

// uid when the sequence answers one, plus library + event + name. Either key
// still matches after a relaunch; pointer keys do not.
static NSArray<NSString *> *SpliceKit_structureSequenceLookupKeys(id sequence) {
    if (!sequence) return @[];
    NSString *uid = SpliceKit_structureObjectIdentifier(sequence, @[
        @"uid", @"UID", @"persistentID", @"identifier", @"uniqueID", @"mediaIdentifier"
    ]);
    NSString *name = SpliceKit_structureObjectIdentifier(sequence, @[@"displayName"]);
    id event = SpliceKit_structureRelatedObject(sequence, @[@"event"]);
    NSString *eventName = SpliceKit_structureObjectIdentifier(event, @[@"displayName", @"uid", @"persistentID"]);
    id library = SpliceKit_structureRelatedObject(sequence, @[@"library", @"libraryDocument", @"document"]);
    if (!library) {
        library = SpliceKit_structureRelatedObject(event, @[@"library", @"libraryDocument", @"document"]);
    }
    NSString *libraryID = SpliceKit_structureObjectIdentifier(library, @[
        @"persistentID", @"uid", @"identifier", @"displayName"
    ]);

    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    if (uid.length) {
        [keys addObject:[NSString stringWithFormat:@"uid:%@|lib:%@", uid, libraryID ?: @""]];
    }
    if (name.length || eventName.length || libraryID.length) {
        [keys addObject:[NSString stringWithFormat:@"name:%@|event:%@|lib:%@",
                         name ?: @"", eventName ?: @"", libraryID ?: @""]];
    }
    return keys;
}

static NSDictionary *SpliceKit_structureGapRecordMap(void) {
    id stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSpliceKitStructureGapDefaultsKey];
    return [stored isKindOfClass:[NSDictionary class]] ? stored : @{};
}

static void SpliceKit_structureSaveGapRecordMap(NSDictionary *map) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (map.count == 0) {
        [defaults removeObjectForKey:kSpliceKitStructureGapDefaultsKey];
    } else {
        [defaults setObject:map forKey:kSpliceKitStructureGapDefaultsKey];
    }
    [defaults synchronize];
}

static NSDictionary *SpliceKit_structureCopyGapEntry(NSString *sequenceKey) {
    if (sequenceKey.length == 0) return nil;
    id entry = SpliceKit_structureGapRecordMap()[sequenceKey];
    return [entry isKindOfClass:[NSDictionary class]] ? [entry copy] : nil;
}

static void SpliceKit_structureSetGapEntry(NSString *sequenceKey, NSDictionary *entryOrNil) {
    if (sequenceKey.length == 0) return;
    NSMutableDictionary *map = [SpliceKit_structureGapRecordMap() mutableCopy];
    if (entryOrNil) {
        map[sequenceKey] = entryOrNil;
    } else {
        [map removeObjectForKey:sequenceKey];
    }
    SpliceKit_structureSaveGapRecordMap(map);
}

// Keep the earliest duration. A second paste must not move the mark forward
// onto a gap the first paste already appended.
static void SpliceKit_structureRememberGapDuration(NSString *sequenceKey, double durationSeconds) {
    if (sequenceKey.length == 0 || !isfinite(durationSeconds) || durationSeconds < 0) return;
    NSDictionary *existing = SpliceKit_structureCopyGapEntry(sequenceKey);
    double kept = durationSeconds;
    if (existing[@"durationSeconds"]) {
        double prev = [existing[@"durationSeconds"] doubleValue];
        if (isfinite(prev) && prev >= 0.0 && prev < kept) kept = prev;
    }
    SpliceKit_structureSetGapEntry(sequenceKey, @{@"durationSeconds": @(kept)});
    SpliceKit_log(@"[Structure] Recorded pre-paste duration %.3fs under %@", kept, sequenceKey);
}

static double SpliceKit_structureRecordedGapDuration(NSArray<NSString *> *keys, BOOL *outFound) {
    if (outFound) *outFound = NO;
    double best = 0;
    BOOL found = NO;
    NSDictionary *map = SpliceKit_structureGapRecordMap();
    for (NSString *key in keys) {
        NSDictionary *entry = [map[key] isKindOfClass:[NSDictionary class]] ? map[key] : nil;
        if (!entry[@"durationSeconds"]) continue;
        double duration = [entry[@"durationSeconds"] doubleValue];
        if (!isfinite(duration) || duration < 0.0) continue;
        if (!found || duration < best) best = duration;
        found = YES;
    }
    if (outFound) *outFound = found;
    return found ? best : 0;
}

static void SpliceKit_structureClearGapRecords(NSArray<NSString *> *keys) {
    if (keys.count == 0) return;
    NSMutableDictionary *map = [SpliceKit_structureGapRecordMap() mutableCopy];
    BOOL changed = NO;
    for (NSString *key in keys) {
        if (map[key]) {
            [map removeObjectForKey:key];
            changed = YES;
        }
    }
    if (changed) SpliceKit_structureSaveGapRecordMap(map);
}

static BOOL SpliceKit_structureItemIsSpineGap(id item) {
    NSString *className = item ? (NSStringFromClass([item class]) ?: @"") : @"";
    return [className containsString:@"GapGenerator"];
}

static NSDictionary *SpliceKit_structureGapSummary(id sequence, id gap) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"class"] = gap ? (NSStringFromClass([gap class]) ?: @"") : @"";
    NSString *name = SpliceKit_displayNameForItem(gap);
    info[@"name"] = name.length ? name : @"Gap";
    id primary = SpliceKit_structurePrimaryObject(sequence);
    CMTimeRange range = {{0, 0, 0, 0}, {0, 0, 0, 0}};
    if (primary && SpliceKit_tryReadTimelineRange(primary, gap, &range)) {
        double start = SpliceKit_secondsFromTime(range.start);
        double duration = SpliceKit_secondsFromTime(range.duration);
        info[@"startSeconds"] = @(start);
        info[@"endSeconds"] = @(start + duration);
        info[@"durationSeconds"] = @(duration);
    }
    return info;
}

// Primary-storyline gap generators that begin at or after the recorded duration.
// A gap that starts earlier is the user's own content and is left alone.
static NSArray *SpliceKit_structureTrailingSpineGaps(id sequence, double recordedDuration) {
    if (!sequence || !isfinite(recordedDuration) || recordedDuration < 0.0) return @[];
    id primary = SpliceKit_structurePrimaryObject(sequence);
    if (!primary) return @[];
    SEL itemsSel = NSSelectorFromString(@"containedItems");
    if (![primary respondsToSelector:itemsSel]) return @[];
    NSArray *items = nil;
    @try {
        items = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(primary, itemsSel));
    } @catch (NSException *e) {
        return @[];
    }
    NSMutableArray *gaps = [NSMutableArray array];
    for (id item in items) {
        if (!SpliceKit_structureItemIsSpineGap(item)) continue;
        CMTimeRange range = {{0, 0, 0, 0}, {0, 0, 0, 0}};
        if (!SpliceKit_tryReadTimelineRange(primary, item, &range)) continue;
        double start = SpliceKit_secondsFromTime(range.start);
        if (!isfinite(start)) continue;
        if (start + 0.001 < recordedDuration) continue;
        [gaps addObject:item];
    }
    return gaps;
}

static NSDictionary *SpliceKit_structureDeleteSpineGaps(id sequence, id timeline, NSArray *gaps) {
    if (gaps.count == 0) return nil;
    SEL deleteSel = NSSelectorFromString(
        @"_deleteAnchoredObjects:rootItem:preserveTime:preserveAnchors:playhead:error:");
    NSDictionary *missingDelete = SpliceKit_directActionMissingSelectorError(
        sequence, deleteSel, @"structure spine gap removal");
    if (missingDelete) return missingDelete;
    id rootItem = SpliceKit_structurePrimaryObject(sequence);
    if (!rootItem) return @{@"error": @"No primary storyline object on sequence"};

    CMTime playhead = {0, 1, 0, 0};
    if (timeline && [timeline respondsToSelector:@selector(playheadTime)]) {
        playhead = ((CMTime (*)(id, SEL))STRET_MSG)(timeline, @selector(playheadTime));
    }
    NSError *deleteError = nil;
    BOOL deleted = ((BOOL (*)(id, SEL, id, id, BOOL, BOOL, CMTime *, NSError **))objc_msgSend)(
        sequence, deleteSel, gaps, rootItem, NO, NO, &playhead, &deleteError);
    if (deleteError) {
        return @{@"error": deleteError.localizedDescription ?: @"Failed to delete appended spine gap"};
    }
    if (!deleted) return @{@"error": @"Failed to delete appended spine gap"};
    return nil;
}

// Captions anchor to spine clips (lane 1), not primaryObject.anchoredItems alone.
static void SpliceKit_collectCaptionsFromItem(id item,
                                              Class captionClass,
                                              NSMutableArray *found,
                                              NSMutableSet *visited,
                                              NSInteger depth) {
    if (!item || !found || !visited || depth > 32) return;

    NSString *pointerKey = SpliceKit_handlePointerKey(item);
    if (pointerKey.length == 0) return;
    NSString *walkKey = [@"walk:" stringByAppendingString:pointerKey];
    if ([visited containsObject:walkKey]) return;
    [visited addObject:walkKey];

    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    NSArray *anchored = nil;
    if ([item respondsToSelector:anchoredSel]) {
        @try {
            anchored = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, anchoredSel));
        } @catch (NSException *e) {
            anchored = nil;
        }
    }

    BOOL itemIsConnectedStoryline = SpliceKit_boolForSelector(item, @"isConnectedStoryline");
    BOOL itemHasVideo = SpliceKit_boolForSelector(item, @"hasVideo");
    BOOL walkContained = itemIsConnectedStoryline || (!itemHasVideo && SpliceKit_mixerIsCollectionLike(item));
    NSArray *contained = nil;
    SEL containedSel = NSSelectorFromString(@"containedItems");
    if (walkContained && [item respondsToSelector:containedSel]) {
        @try {
            contained = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, containedSel));
        } @catch (NSException *e) {
            contained = nil;
        }
    }

    for (NSInteger pass = 0; pass < 2; pass++) {
        NSArray *children = (pass == 1) ? contained : anchored;
        if (children.count == 0) continue;

        for (id child in children) {
            if (!child) continue;

            if (captionClass && [child isKindOfClass:captionClass]) {
                NSString *childKey = SpliceKit_handlePointerKey(child);
                if (childKey.length > 0 && ![visited containsObject:childKey]) {
                    [visited addObject:childKey];
                    [found addObject:child];
                }
                continue;
            }

            SpliceKit_collectCaptionsFromItem(child, captionClass, found, visited, depth + 1);
        }
    }
}

static void SpliceKit_collectMotionTitleCandidatesFromItem(id item,
                                                         NSMutableArray *found,
                                                         NSMutableSet *visited,
                                                         NSInteger depth) {
    if (!item || !found || !visited || depth > 32) return;

    NSString *pointerKey = SpliceKit_handlePointerKey(item);
    if (pointerKey.length == 0) return;
    NSString *walkKey = [@"walk:" stringByAppendingString:pointerKey];
    if ([visited containsObject:walkKey]) return;
    [visited addObject:walkKey];

    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    NSArray *anchored = nil;
    if ([item respondsToSelector:anchoredSel]) {
        @try {
            anchored = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, anchoredSel));
        } @catch (NSException *e) {
            anchored = nil;
        }
    }

    BOOL itemIsConnectedStoryline = SpliceKit_boolForSelector(item, @"isConnectedStoryline");
    BOOL itemHasVideo = SpliceKit_boolForSelector(item, @"hasVideo");
    BOOL walkContained = itemIsConnectedStoryline || (!itemHasVideo && SpliceKit_mixerIsCollectionLike(item));
    NSArray *contained = nil;
    SEL containedSel = NSSelectorFromString(@"containedItems");
    if (walkContained && [item respondsToSelector:containedSel]) {
        @try {
            contained = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, containedSel));
        } @catch (NSException *e) {
            contained = nil;
        }
    }

    for (NSInteger pass = 0; pass < 2; pass++) {
        NSArray *children = (pass == 1) ? contained : anchored;
        if (children.count == 0) continue;

        for (id child in children) {
            if (!child) continue;
            // Don't record a gap, and don't walk into it: its children are the
            // clips the gap holds, not captions.
            if (SpliceKit_itemIsGapGenerator(child)) continue;

            if (SpliceKit_itemIsMotionTitleVerifyCandidate(child)) {
                NSString *childKey = SpliceKit_handlePointerKey(child);
                if (childKey.length > 0 && ![visited containsObject:childKey]) {
                    [visited addObject:childKey];
                    [found addObject:child];
                }
                continue;
            }

            SpliceKit_collectMotionTitleCandidatesFromItem(child, found, visited, depth + 1);
        }
    }
}

NSArray *SpliceKit_allMotionTitleCandidatesOnSequence(id sequence) {
    if (!sequence) return @[];

    NSMutableArray *found = [NSMutableArray array];
    NSMutableSet *walkVisited = [NSMutableSet set];

    SEL primarySel = NSSelectorFromString(@"primaryObject");
    id primaryObject = [sequence respondsToSelector:primarySel]
        ? ((id (*)(id, SEL))objc_msgSend)(sequence, primarySel) : nil;
    if (primaryObject) {
        SEL itemsSel = NSSelectorFromString(@"containedItems");
        NSArray *spineItems = [primaryObject respondsToSelector:itemsSel]
            ? ((id (*)(id, SEL))objc_msgSend)(primaryObject, itemsSel) : nil;
        if ([spineItems isKindOfClass:[NSArray class]]) {
            for (id spineItem in spineItems) {
                SpliceKit_collectMotionTitleCandidatesFromItem(spineItem, found, walkVisited, 0);
            }
        }
    }

    return found;
}

NSArray *SpliceKit_allCaptionsOnSequence(id sequence) {
    if (!sequence) return @[];

    Class captionClass = NSClassFromString(@"FFAnchoredCaption");
    NSMutableArray *found = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    SEL allCaptionsSel = NSSelectorFromString(@"allCaptions");
    if ([sequence respondsToSelector:allCaptionsSel]) {
        id allCaptions = ((id (*)(id, SEL))objc_msgSend)(sequence, allCaptionsSel);
        NSArray *items = nil;
        if ([allCaptions isKindOfClass:[NSArray class]]) {
            items = allCaptions;
        } else if ([allCaptions isKindOfClass:[NSSet class]]) {
            items = [(NSSet *)allCaptions allObjects];
        }
        for (id item in items) {
            if (!captionClass || ![item isKindOfClass:captionClass]) continue;
            NSString *key = SpliceKit_handlePointerKey(item);
            if (key.length == 0 || [seen containsObject:key]) continue;
            [seen addObject:key];
            [found addObject:item];
        }
    }

    id primaryObject = SpliceKit_structurePrimaryObject(sequence);
    if (primaryObject) {
        SEL itemsSel = NSSelectorFromString(@"containedItems");
        NSArray *spineItems = [primaryObject respondsToSelector:itemsSel]
            ? ((id (*)(id, SEL))objc_msgSend)(primaryObject, itemsSel) : nil;
        if ([spineItems isKindOfClass:[NSArray class]]) {
            NSMutableSet *walkVisited = [NSMutableSet setWithSet:seen];
            for (id spineItem in spineItems) {
                SpliceKit_collectCaptionsFromItem(spineItem, captionClass, found, walkVisited, 0);
            }
        }
    }

    return found;
}

static NSHashTable *SpliceKit_structureCaptionPointerSet(NSArray *captions) {
    NSHashTable *set = [NSHashTable hashTableWithOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality];
    for (id caption in captions) {
        if (caption) [set addObject:caption];
    }
    return set;
}

static NSString *SpliceKit_structureCaptionText(id caption) {
    if (!caption) return nil;
    SEL textSel = NSSelectorFromString(@"text");
    if (![caption respondsToSelector:textSel]) return nil;
    id text = ((id (*)(id, SEL))objc_msgSend)(caption, textSel);
    return [text isKindOfClass:[NSString class]] ? text : nil;
}

// Exact uppercase labels written by structure.generateCaptions (see helpers/structure-analyzer.swift + paste).
static BOOL SpliceKit_structureCaptionTextIsToolGenerated(NSString *text) {
    if (text.length == 0) return NO;

    static NSSet<NSString *> *exactLabels = nil;
    static NSArray<NSString *> *numberedPrefixes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exactLabels = [NSSet setWithObjects:
            @"INTRO", @"OUTRO", @"BRIDGE", @"DROP", @"BREAKDOWN", @"SECTION", @"PRE-CHORUS", nil];
        numberedPrefixes = @[@"VERSE", @"CHORUS", @"BRIDGE"];
    });

    if ([exactLabels containsObject:text]) return YES;

    for (NSString *prefix in numberedPrefixes) {
        if (![text hasPrefix:prefix]) continue;
        NSString *suffix = [text substringFromIndex:prefix.length];
        if (suffix.length == 0) continue;
        NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        if ([suffix rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary *SpliceKit_structureCaptionSummary(id sequence, id caption) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    NSString *text = SpliceKit_structureCaptionText(caption);
    if (text) info[@"text"] = text;

    id primaryObject = SpliceKit_structurePrimaryObject(sequence);
    CMTimeRange range = {0};
    if (primaryObject && SpliceKit_tryReadTimelineRange(primaryObject, caption, &range)) {
        double start = SpliceKit_secondsFromTime(range.start);
        double end = start + SpliceKit_secondsFromTime(range.duration);
        info[@"startSeconds"] = @(start);
        info[@"endSeconds"] = @(end);
    }
    return info;
}

static NSArray *SpliceKit_structureCaptionsToRemove(id sequence, BOOL *outUsedRegistry) {
    if (outUsedRegistry) *outUsedRegistry = NO;
    if (!sequence) return @[];

    Class captionClass = NSClassFromString(@"FFAnchoredCaption");
    NSMutableArray *toRemove = [NSMutableArray array];
    NSHashTable *seen = SpliceKit_structureCaptionPointerSet(@[]);

    NSHashTable<id> *registry = SpliceKit_structureCaptionTableForSequence(sequence, NO);
    if (registry.count > 0) {
        if (outUsedRegistry) *outUsedRegistry = YES;
        for (id caption in registry) {
            if (!caption || (captionClass && ![caption isKindOfClass:captionClass])) continue;
            [toRemove addObject:caption];
            [seen addObject:caption];
        }
    }

    for (id caption in SpliceKit_allCaptionsOnSequence(sequence)) {
        if ([seen containsObject:caption]) continue;
        if (captionClass && ![caption isKindOfClass:captionClass]) continue;
        NSString *text = SpliceKit_structureCaptionText(caption);
        if (!SpliceKit_structureCaptionTextIsToolGenerated(text)) continue;
        [toRemove addObject:caption];
        [seen addObject:caption];
    }

    return toRemove;
}

static void SpliceKit_structureSeekTimelineToSeconds(id timeline, id sequence, double seconds) {
    if (!timeline || seconds < 0) seconds = 0;
    int fdN = 100, fdD = 2400;
    CMTime fd = SpliceKit_sequenceFrameDuration(sequence);
    if (fd.timescale > 0) { fdN = (int)fd.value; fdD = fd.timescale; }
    double fps = (double)fdD / (double)fdN;
    long long frames = (long long)llround(seconds * fps);
    if (frames < 0) frames = 0;
    CMTime t = {frames * fdN, fdD, 1, 0};
    SEL setSel = @selector(setPlayheadTime:);
    if ([timeline respondsToSelector:setSel]) {
        ((void (*)(id, SEL, CMTime))objc_msgSend)(timeline, setSel, t);
    }
}

static double SpliceKit_structureSequenceDurationSeconds(id sequence) {
    if (!sequence) return 0;

    SEL durSel = NSSelectorFromString(@"duration");
    if ([sequence respondsToSelector:durSel]) {
        CMTime d = ((CMTime (*)(id, SEL))STRET_MSG)(sequence, durSel);
        double secs = SpliceKit_secondsFromTime(d);
        if (secs > 0) return secs;
    }

    // FFAnchoredSequence on FCP 12.3 does not answer -duration (checked against the
    // live runtime: 67 selectors match "duration" and none of them is the bare one).
    // Asking for it and giving up left this reading 0, which made the caller think the
    // sequence had no duration and skip recording it — so the gap song_structure_blocks
    // appends was never registered and never removed. Sum the primary storyline the way
    // timeline.getDetailedState does.
    id primary = [sequence respondsToSelector:@selector(primaryObject)]
        ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
    if (!primary || ![primary respondsToSelector:@selector(containedItems)]) return 0;

    id items = ((id (*)(id, SEL))objc_msgSend)(primary, @selector(containedItems));
    if (![items isKindOfClass:[NSArray class]]) return 0;

    double total = 0;
    for (id item in (NSArray *)items) {
        if (![item respondsToSelector:@selector(duration)]) continue;
        CMTime d = ((CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
        double secs = SpliceKit_secondsFromTime(d);
        if (secs > 0) total += secs;
    }
    return total;
}

NSDictionary *SpliceKit_serverStructureGenerateCaptions(NSDictionary *params) {
    NSArray *sections = params[@"sections"];
    if (!sections || ![sections isKindOfClass:[NSArray class]] || sections.count == 0) {
        return @{@"error": @"sections array required (each: {label, start, end})"};
    }

    double atSeconds = params[@"atSeconds"] != nil ? [params[@"atSeconds"] doubleValue] : 0.0;
    if (atSeconds < 0) atSeconds = 0;

    double maxSectionEnd = 0;
    for (id obj in sections) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        double end = [obj[@"end"] doubleValue];
        if (end > maxSectionEnd) maxSectionEnd = end;
    }
    double labelsEnd = atSeconds + maxSectionEnd;

    __block double sequenceDuration = 0;
    __block double savedPlayheadSeconds = 0;
    __block NSArray<NSString *> *sequenceKeys = nil;
    __block NSString *sequenceName = nil;
    __block BOOL spineCountKnown = NO;
    __block NSUInteger spineCount = 0;

    @try {
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            id seq = tm ? ((id (*)(id, SEL))objc_msgSend)(tm, @selector(sequence)) : nil;
            sequenceDuration = SpliceKit_structureSequenceDurationSeconds(seq);
            sequenceKeys = [SpliceKit_structureSequenceLookupKeys(seq) copy];
            sequenceName = SpliceKit_structureObjectIdentifier(seq, @[@"displayName"]);
            id primary = SpliceKit_structurePrimaryObject(seq);
            SEL itemsSel = NSSelectorFromString(@"containedItems");
            if (primary && [primary respondsToSelector:itemsSel]) {
                @try {
                    NSArray *items = SpliceKit_mixerArrayFromContainer(
                        ((id (*)(id, SEL))objc_msgSend)(primary, itemsSel));
                    if (items) {
                        spineCountKnown = YES;
                        spineCount = items.count;
                    }
                } @catch (NSException *e) {}
            }
            if (tm && [tm respondsToSelector:@selector(playheadTime)]) {
                CMTime saved = ((CMTime (*)(id, SEL))STRET_MSG)(tm, @selector(playheadTime));
                savedPlayheadSeconds = SpliceKit_secondsFromTime(saved);
            }
            if (tm) {
                SpliceKit_structureSeekTimelineToSeconds(tm, seq, atSeconds);
            }
        });

        NSMutableDictionary *mutableParams = [params mutableCopy];
        mutableParams[@"atSeconds"] = @(atSeconds);
        __block id userSequence = nil;
        __block NSArray *captionsBefore = nil;
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            userSequence = tm ? ((id (*)(id, SEL))objc_msgSend)(tm, @selector(sequence)) : nil;
            if (userSequence) {
                captionsBefore = SpliceKit_allCaptionsOnSequence(userSequence);
            }
        });

        // Written before the paste so a crash after Final Cut Pro appends the gap
        // still leaves a duration remove_structure_blocks can find after relaunch.
        // Rolled back when the paste itself returns an error.
        BOOL durationKnown = sequenceDuration > 0.0 || (spineCountKnown && spineCount == 0);
        BOOL recordGap = durationKnown && sequenceKeys.count > 0 && labelsEnd > sequenceDuration + 0.05;
        NSMutableDictionary<NSString *, NSDictionary *> *previousGapEntries = [NSMutableDictionary dictionary];
        if (recordGap) {
            for (NSString *key in sequenceKeys) {
                NSDictionary *previous = SpliceKit_structureCopyGapEntry(key);
                if (previous) previousGapEntries[key] = previous;
                SpliceKit_structureRememberGapDuration(key, sequenceDuration);
            }
        }

        NSMutableDictionary *result = [SpliceKit_handleStructureGenerateCaptions(mutableParams) mutableCopy];
        if (result[@"error"]) {
            if (recordGap) {
                for (NSString *key in sequenceKeys) {
                    SpliceKit_structureSetGapEntry(key, previousGapEntries[key]);
                }
            }
            return result;
        }

        if (recordGap) {
            __block NSArray<NSString *> *keysAfter = nil;
            SpliceKit_executeOnMainThread(^{
                id tm = SpliceKit_getActiveTimelineModule();
                id seq = tm ? ((id (*)(id, SEL))objc_msgSend)(tm, @selector(sequence)) : nil;
                NSString *activeName = SpliceKit_structureObjectIdentifier(seq, @[@"displayName"]);
                if (sequenceName.length == 0 || activeName.length == 0 ||
                    [activeName isEqualToString:sequenceName]) {
                    keysAfter = [SpliceKit_structureSequenceLookupKeys(seq) copy];
                }
            });
            for (NSString *key in keysAfter) {
                SpliceKit_structureRememberGapDuration(key, sequenceDuration);
            }
            NSArray *lookup = keysAfter.count ? keysAfter : sequenceKeys;
            BOOL foundRecord = NO;
            double stored = SpliceKit_structureRecordedGapDuration(lookup, &foundRecord);
            result[@"appendedSpineGapRecorded"] = @(foundRecord);
            if (foundRecord) result[@"prePasteDurationSeconds"] = @(stored);
        }

        if (userSequence) {
            NSHashTable *beforeSet = SpliceKit_structureCaptionPointerSet(captionsBefore ?: @[]);
            __block NSMutableArray *newCaptions = [NSMutableArray array];
            SpliceKit_executeOnMainThread(^{
                for (id caption in SpliceKit_allCaptionsOnSequence(userSequence)) {
                    if (![beforeSet containsObject:caption]) {
                        [newCaptions addObject:caption];
                    }
                }
            });
            if (newCaptions.count > 0) {
                SpliceKit_structureRegisterCaptions(userSequence, newCaptions);
                result[@"registeredCaptions"] = @(newCaptions.count);
            }
        }

        __block double playheadAfterPaste = 0;
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            if (tm && [tm respondsToSelector:@selector(playheadTime)]) {
                CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(tm, @selector(playheadTime));
                playheadAfterPaste = SpliceKit_secondsFromTime(t);
            }
        });

        result[@"atSeconds"] = @(atSeconds);
        if (fabs(playheadAfterPaste - atSeconds) > 0.05) {
            result[@"placedAtSeconds"] = @(playheadAfterPaste);
        }

        if (sequenceDuration > 0 && labelsEnd > sequenceDuration + 0.05) {
            result[@"extendsPastSequenceEnd"] = @YES;
            result[@"sequenceDurationSeconds"] = @(sequenceDuration);
            result[@"labelsEndSeconds"] = @(labelsEnd);
        } else {
            result[@"extendsPastSequenceEnd"] = @NO;
        }
        return result;
    } @finally {
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            id seq = tm ? ((id (*)(id, SEL))objc_msgSend)(tm, @selector(sequence)) : nil;
            if (tm) {
                SpliceKit_structureSeekTimelineToSeconds(tm, seq, savedPlayheadSeconds);
            }
        });
    }
}

NSDictionary *SpliceKit_serverStructureRemove(NSDictionary *params) {
    BOOL dryRun = [params[@"dryRun"] boolValue];
    __block NSUInteger removedStorylines = 0;
    __block NSUInteger removedCaptions = 0;
    __block NSMutableArray *removedCaptionDetails = [NSMutableArray array];
    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module"};
                return;
            }
            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) {
                result = @{@"error": @"No sequence in timeline"};
                return;
            }

            BOOL usedRegistry = NO;
            NSArray *captions = SpliceKit_structureCaptionsToRemove(sequence, &usedRegistry);
            NSMutableArray *captionSummaries = [NSMutableArray arrayWithCapacity:captions.count];
            for (id caption in captions) {
                [captionSummaries addObject:SpliceKit_structureCaptionSummary(sequence, caption)];
            }

            NSUInteger storylinesToRemove =
                SpliceKit_structureCountStorylinesNamed(sequence, kSpliceKitStructureStorylineName);

            // Gaps are resolved even when no captions remain. The previous removal
            // returned as soon as the caption list was empty and never looked at the spine.
            NSArray<NSString *> *sequenceKeys = SpliceKit_structureSequenceLookupKeys(sequence);
            BOOL gapRecordFound = NO;
            double recordedDuration = SpliceKit_structureRecordedGapDuration(sequenceKeys, &gapRecordFound);
            NSArray *gaps = gapRecordFound
                ? SpliceKit_structureTrailingSpineGaps(sequence, recordedDuration) : @[];
            NSMutableArray *gapSummaries = [NSMutableArray arrayWithCapacity:gaps.count];
            for (id gap in gaps) {
                [gapSummaries addObject:SpliceKit_structureGapSummary(sequence, gap)];
            }

            BOOL hadGapRecord = gapRecordFound;
            double durationForPayload = recordedDuration;
            NSMutableDictionary * (^removalPayload)(BOOL, NSUInteger, NSUInteger, NSUInteger, NSArray *, NSArray *) =
            ^NSMutableDictionary *(BOOL isDryRun, NSUInteger storylines, NSUInteger captionCount,
                                   NSUInteger gapCount, NSArray *captionRows, NSArray *gapRows) {
                NSMutableDictionary *payload = [@{
                    @"status": @"ok",
                    @"dryRun": @(isDryRun),
                    @"removedStorylines": @(storylines),
                    @"removedCaptions": @(captionCount),
                    @"removedSpineGaps": @(gapCount),
                    @"removed": @(storylines + captionCount + gapCount),
                    @"captions": captionRows ?: @[],
                    @"spineGaps": gapRows ?: @[],
                    @"matchedViaRegistry": @(usedRegistry && captionCount > 0),
                } mutableCopy];
                if (hadGapRecord) payload[@"prePasteDurationSeconds"] = @(durationForPayload);
                return payload;
            };

            if (dryRun) {
                result = removalPayload(YES, storylinesToRemove, captions.count, gaps.count,
                                        captionSummaries, gapSummaries);
                return;
            }

            if (storylinesToRemove == 0 && captions.count == 0 && gaps.count == 0) {
                if (gapRecordFound) {
                    double now = SpliceKit_structureSequenceDurationSeconds(sequence);
                    if (now <= recordedDuration + 0.05) {
                        SpliceKit_structureClearGapRecords(sequenceKeys);
                        gapRecordFound = NO;
                    }
                }
                result = removalPayload(NO, 0, 0, 0, @[], @[]);
                return;
            }

            NSString *undoName = @"Remove Structure Blocks";
            BOOL openedUndoGroup = SpliceKit_internalBeginEditGroupIfNeeded(sequence, undoName);
            NSUInteger removedSpineGaps = 0;
            @try {
                removedStorylines = SpliceKit_structureRemoveStorylineNamed(sequence, kSpliceKitStructureStorylineName);

                if (captions.count > 0) {
                    SEL deleteSel = NSSelectorFromString(
                        @"_deleteAnchoredObjects:rootItem:preserveTime:preserveAnchors:playhead:error:");
                    NSDictionary *missingDelete = SpliceKit_directActionMissingSelectorError(
                        sequence, deleteSel, @"structure caption removal");
                    if (missingDelete) {
                        result = missingDelete;
                        return;
                    }

                    id rootItem = SpliceKit_structurePrimaryObject(sequence);
                    if (!rootItem) {
                        result = @{@"error": @"No primary storyline object on sequence"};
                        return;
                    }

                    CMTime playhead = {0, 1, 0, 0};
                    if ([timeline respondsToSelector:@selector(playheadTime)]) {
                        playhead = ((CMTime (*)(id, SEL))STRET_MSG)(timeline, @selector(playheadTime));
                    }

                    NSError *deleteError = nil;
                    BOOL deleted = ((BOOL (*)(id, SEL, id, id, BOOL, BOOL, CMTime *, NSError **))objc_msgSend)(
                        sequence, deleteSel, captions, rootItem, NO, NO, &playhead, &deleteError);
                    if (deleteError) {
                        result = @{@"error": deleteError.localizedDescription ?: @"Failed to delete structure captions"};
                        return;
                    }
                    if (!deleted) {
                        result = @{@"error": @"Failed to delete structure captions"};
                        return;
                    }
                    removedCaptions = captions.count;
                    [removedCaptionDetails addObjectsFromArray:captionSummaries];
                    SpliceKit_structureUnregisterCaptions(sequence, captions);
                }

                if (gaps.count > 0) {
                    NSDictionary *gapError = SpliceKit_structureDeleteSpineGaps(sequence, timeline, gaps);
                    if (gapError) {
                        result = gapError;
                        return;
                    }
                    removedSpineGaps = gaps.count;
                    SpliceKit_structureClearGapRecords(sequenceKeys);
                    gapRecordFound = NO;
                } else if (gapRecordFound) {
                    double now = SpliceKit_structureSequenceDurationSeconds(sequence);
                    if (now <= recordedDuration + 0.05) {
                        SpliceKit_structureClearGapRecords(sequenceKeys);
                        gapRecordFound = NO;
                    }
                }
            } @finally {
                SpliceKit_internalEndEditGroupIfOpened(sequence, timeline, undoName, openedUndoGroup);
            }

            if (result[@"error"]) return;

            result = removalPayload(NO, removedStorylines, removedCaptions, removedSpineGaps,
                                    removedCaptionDetails, gapSummaries);
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result ?: @{@"error": @"Failed to remove structure blocks"};
}

static NSDictionary *SpliceKit_captionRemovalItemLabel(id item, BOOL native) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    NSString *displayName = SpliceKit_displayNameForItem(item);
    if (displayName.length) info[@"displayName"] = displayName;
    info[@"class"] = NSStringFromClass([item class]);
    if (native) {
        SEL textSel = NSSelectorFromString(@"text");
        if ([item respondsToSelector:textSel]) {
            id text = ((id (*)(id, SEL))objc_msgSend)(item, textSel);
            if ([text isKindOfClass:[NSString class]] && [(NSString *)text length]) {
                info[@"text"] = text;
            }
        }
    } else {
        NSDictionary *entry = SpliceKit_buildVerifiedMotionTitleEntry(item);
        if (entry[@"text"]) info[@"text"] = entry[@"text"];
        if (entry[@"name"]) info[@"displayName"] = entry[@"name"];
    }
    return info;
}

static NSArray *SpliceKit_captionsToRemoveOnSequence(id sequence, BOOL native) {
    NSMutableArray *found = [NSMutableArray array];
    if (native) {
        Class captionClass = NSClassFromString(@"FFAnchoredCaption");
        for (id item in SpliceKit_allCaptionsOnSequence(sequence)) {
            if (captionClass && ![item isKindOfClass:captionClass]) continue;
            [found addObject:item];
        }
        return found;
    }
    for (id item in SpliceKit_allMotionTitleCandidatesOnSequence(sequence)) {
        if (!SpliceKit_itemIsMotionTitleVerifyCandidate(item)) continue;
        [found addObject:item];
    }
    return found;
}

NSDictionary *SpliceKit_handleNativeCaptionsRemove(NSDictionary *params) {
    BOOL native = params[@"native"] == nil ? YES : [params[@"native"] boolValue];
    BOOL dryRun = [params[@"dryRun"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module"};
                return;
            }
            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, NSSelectorFromString(@"sequence"));
            if (!sequence) {
                result = @{@"error": @"No sequence in timeline"};
                return;
            }

            NSArray *toRemove = SpliceKit_captionsToRemoveOnSequence(sequence, native);
            NSMutableArray *summaries = [NSMutableArray arrayWithCapacity:toRemove.count];
            for (id item in toRemove) {
                [summaries addObject:SpliceKit_captionRemovalItemLabel(item, native)];
            }

            NSString *pipeline = native ? @"native_FFAnchoredCaption" : @"motion_title_captions";
            if (dryRun) {
                result = @{
                    @"status": @"ok",
                    @"dryRun": @YES,
                    @"native": @(native),
                    @"pipeline": pipeline,
                    @"foundCount": @(toRemove.count),
                    @"removedCount": @0,
                    @"notRemoved": @[],
                    @"items": summaries,
                };
                return;
            }

            if (toRemove.count == 0) {
                result = @{
                    @"status": @"ok",
                    @"dryRun": @NO,
                    @"native": @(native),
                    @"pipeline": pipeline,
                    @"foundCount": @0,
                    @"removedCount": @0,
                    @"notRemoved": @[],
                    @"items": @[],
                };
                return;
            }

            NSString *undoName = @"Remove Captions";
            BOOL openedUndo = SpliceKit_internalBeginEditGroupIfNeeded(sequence, undoName);
            NSUInteger removedCount = 0;
            NSMutableArray *notRemoved = [NSMutableArray array];
            @try {
                SEL deleteSel = NSSelectorFromString(
                    @"_deleteAnchoredObjects:rootItem:preserveTime:preserveAnchors:playhead:error:");
                NSDictionary *missingDelete = SpliceKit_directActionMissingSelectorError(
                    sequence, deleteSel, @"caption removal");
                if (missingDelete) {
                    result = missingDelete;
                    return;
                }

                id rootItem = SpliceKit_structurePrimaryObject(sequence);
                if (!rootItem) {
                    result = @{@"error": @"No primary storyline object on sequence"};
                    return;
                }

                CMTime playhead = {0, 1, 0, 0};
                if ([timeline respondsToSelector:@selector(playheadTime)]) {
                    playhead = ((CMTime (*)(id, SEL))STRET_MSG)(timeline, @selector(playheadTime));
                }

                NSError *deleteError = nil;
                BOOL deleted = ((BOOL (*)(id, SEL, id, id, BOOL, BOOL, CMTime *, NSError **))objc_msgSend)(
                    sequence, deleteSel, toRemove, rootItem, NO, NO, &playhead, &deleteError);
                if (deleteError || !deleted) {
                    NSString *reason = deleteError.localizedDescription ?: @"Failed to delete caption items";
                    for (id item in toRemove) {
                        NSMutableDictionary *fail = [SpliceKit_captionRemovalItemLabel(item, native) mutableCopy];
                        fail[@"reason"] = reason;
                        [notRemoved addObject:fail];
                    }
                } else {
                    removedCount = toRemove.count;
                }
            } @finally {
                SpliceKit_internalEndEditGroupIfOpened(sequence, timeline, undoName, openedUndo);
            }

            result = @{
                @"status": @"ok",
                @"dryRun": @NO,
                @"native": @(native),
                @"pipeline": pipeline,
                @"foundCount": @(toRemove.count),
                @"removedCount": @(removedCount),
                @"notRemoved": notRemoved,
                @"items": summaries,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result ?: @{@"error": @"Failed to remove captions"};
}
