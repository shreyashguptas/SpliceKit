//
//  SpliceKitServerSpine.m
//  SpliceKit - Spine manipulation (spine.*) and the edit-group begin/end helpers.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Spine Manipulation (spine.*)
//
// Direct manipulation of the timeline spine's containedItems array.
// This allows Lua scripts to reorder, insert, and remove clips at
// the data model level — no cut/paste, no FCPXML roundtrip.
//
// The spine is: sequence -> primaryObject (FFAnchoredCollection) -> containedItems.
// containedItems is an NSMutableArray of clips, transitions, and gaps.
//
// All mutations wrap in FCP's editing transaction system:
//   sequence.actionBeginEditing -> mutate -> sequence.actionEndEditing
// This ensures undo support and proper notification propagation.
//

// Helper: get the sequence and spine (primaryObject) for the active timeline.
// Returns NO and sets *outError if not available.
static BOOL SpliceKit_getSequenceAndSpine(id *outSequence, id *outSpine, NSDictionary **outError) {
    id timeline = SpliceKit_getActiveTimelineModule();
    if (!timeline) {
        *outError = @{@"error": @"No active timeline module. Is a project open?"};
        return NO;
    }
    id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
    if (!sequence) {
        *outError = @{@"error": @"No sequence in timeline. Open a project first."};
        return NO;
    }
    id spine = nil;
    if ([sequence respondsToSelector:@selector(primaryObject)]) {
        spine = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
    }
    if (!spine || ![spine respondsToSelector:@selector(containedItems)]) {
        *outError = @{@"error": @"No primaryObject (spine) found on sequence."};
        return NO;
    }
    *outSequence = sequence;
    *outSpine = spine;
    return YES;
}

// spine.getItems — returns all items in the spine with handles, classes, durations.
// This is similar to timeline.getDetailedState but focused on the spine items
// and always returns handles suitable for reordering operations.
NSDictionary *SpliceKit_handleSpineGetItems(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id sequence = nil, spine = nil;
            NSDictionary *err = nil;
            if (!SpliceKit_getSequenceAndSpine(&sequence, &spine, &err)) {
                result = err;
                return;
            }
            id items = ((id (*)(id, SEL))objc_msgSend)(spine, @selector(containedItems));
            if (![items isKindOfClass:[NSArray class]]) {
                result = @{@"error": @"containedItems is not an array"};
                return;
            }
            NSArray *arr = (NSArray *)items;
            NSMutableArray *itemList = [NSMutableArray array];
            SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
            BOOL canGetRange = [spine respondsToSelector:erSel];
            for (NSInteger i = 0; i < (NSInteger)arr.count; i++) {
                id item = arr[i];
                NSMutableDictionary *info = [NSMutableDictionary dictionary];
                info[@"index"] = @(i);
                info[@"class"] = NSStringFromClass([item class]);
                NSString *h = SpliceKit_storeHandle(item);
                info[@"handle"] = h;
                if ([item respondsToSelector:@selector(displayName)]) {
                    id name = ((id (*)(id, SEL))objc_msgSend)(item, @selector(displayName));
                    info[@"name"] = name ?: @"";
                }
                if ([item respondsToSelector:@selector(duration)]) {
                    CMTime d = ((CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
                    info[@"duration"] = SpliceKit_serializeCMTime(d);
                }
                if (canGetRange) {
                    @try {
                        CMTimeRange range = ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(
                            spine, erSel, item);
                        info[@"startTime"] = SpliceKit_serializeCMTime(range.start);
                    } @catch (NSException *e) {}
                }
                [itemList addObject:info];
            }
            NSString *spineHandle = SpliceKit_storeHandle(spine);
            NSString *seqHandle = SpliceKit_storeHandle(sequence);
            result = @{
                @"items": itemList,
                @"count": @(arr.count),
                @"spineHandle": spineHandle,
                @"sequenceHandle": seqHandle
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

// spine.reorder — reorder spine items by providing an array of indices.
// The indices refer to positions in the CURRENT containedItems array.
// Items are rearranged to match the given order. Transitions are removed
// (they don't make sense after reorder). Timing is recalculated.
//
// Example: [3, 1, 0, 2] means:
//   new position 0 = old item 3
//   new position 1 = old item 1
//   new position 2 = old item 0
//   new position 3 = old item 2
//
// If skip_transitions is true (default), transition items are excluded
// from both the input indices and the output. Only clips are reordered.
// Helper: get the library document's NSUndoManager.
// Path: PEAppController -> _targetLibrary -> libraryDocument -> undoManager

id SpliceKit_getUndoManager(void) {
    id app = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("NSApplication"), @selector(sharedApplication));
    id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));

    SEL libSel = NSSelectorFromString(@"_targetLibrary");
    id library = nil;
    if ([delegate respondsToSelector:libSel]) {
        library = ((id (*)(id, SEL))objc_msgSend)(delegate, libSel);
    }
    if (!library) {
        id libs = ((id (*)(id, SEL))objc_msgSend)(
            objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
        if ([libs respondsToSelector:@selector(firstObject)]) {
            library = ((id (*)(id, SEL))objc_msgSend)(libs, @selector(firstObject));
        }
    }
    if (!library) return nil;
    id doc = ((id (*)(id, SEL))objc_msgSend)(library, @selector(libraryDocument));
    if (!doc) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(doc, @selector(undoManager));
}

// Helper: apply a specific item order to the spine. Used by both reorder and undo.
static void SpliceKit_applySpineOrder(id spine, NSArray *newItems) {
    SEL removeSel = NSSelectorFromString(@"removeObjectFromContainedItemsAtIndex:");
    SEL addSel = NSSelectorFromString(@"addObjectToContainedItems:");
    SEL deferSel = NSSelectorFromString(@"_setDeferUpdates:");

    // Defer updates during bulk mutation
    if ([spine respondsToSelector:deferSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(spine, deferSel, YES);
    }

    // Remove all items (reverse order)
    id currentItems = ((id (*)(id, SEL))objc_msgSend)(spine, @selector(containedItems));
    NSInteger count = [(NSArray *)currentItems count];
    for (NSInteger i = count - 1; i >= 0; i--) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(spine, removeSel, (NSUInteger)i);
    }

    // Re-add in the target order
    for (id item in newItems) {
        ((void (*)(id, SEL, id))objc_msgSend)(spine, addSel, item);
    }

    // Un-defer and process
    if ([spine respondsToSelector:deferSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(spine, deferSel, NO);
    }
    SEL processSel = NSSelectorFromString(@"_processDeferredUpdates");
    if ([spine respondsToSelector:processSel]) {
        ((void (*)(id, SEL))objc_msgSend)(spine, processSel);
    }

    // Clear cached values on every item (invalidates sibling offset cache)
    SEL clearSel = NSSelectorFromString(@"clearCachedValues");
    id newContained = ((id (*)(id, SEL))objc_msgSend)(spine, @selector(containedItems));
    if ([newContained isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)newContained) {
            if ([item respondsToSelector:clearSel]) {
                ((void (*)(id, SEL))objc_msgSend)(item, clearSel);
            }
        }
    }
    // Clear spine's own caches
    if ([spine respondsToSelector:clearSel]) {
        ((void (*)(id, SEL))objc_msgSend)(spine, clearSel);
    }
    // Invalidate lane sorting
    SEL updateLanesSel = NSSelectorFromString(@"_updateCollectionLanes");
    if ([spine respondsToSelector:updateLanesSel]) {
        ((void (*)(id, SEL))objc_msgSend)(spine, updateLanesSel);
    }
    // Notify that contained items changed
    SEL informSel = NSSelectorFromString(@"informContainedItemsAddedRemovedOrPlayEnableChanged:");
    if ([spine respondsToSelector:informSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(spine, informSel, YES);
    }
}

// Helper: refresh timeline after spine mutation.
static void SpliceKit_refreshTimeline(id sequence) {
    SEL forceUpdateSel = NSSelectorFromString(@"forceUpdate");
    if ([sequence respondsToSelector:forceUpdateSel]) {
        ((void (*)(id, SEL))objc_msgSend)(sequence, forceUpdateSel);
    }
    id timeline = SpliceKit_getActiveTimelineModule();
    if (timeline) {
        SEL reloadSel = NSSelectorFromString(@"reloadTimelineView:");
        if ([timeline respondsToSelector:reloadSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, reloadSel, nil);
        }
    }
}

NSDictionary *SpliceKit_handleSpineReorder(NSDictionary *params) {
    NSArray *order = params[@"order"];  // array of integers (0-based indices into clip list)
    if (!order || ![order isKindOfClass:[NSArray class]] || order.count < 2) {
        return @{@"error": @"'order' must be an array of at least 2 indices"};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id sequence = nil, spine = nil;
            NSDictionary *err = nil;
            if (!SpliceKit_getSequenceAndSpine(&sequence, &spine, &err)) {
                result = err;
                return;
            }

            id containedItems = ((id (*)(id, SEL))objc_msgSend)(spine, @selector(containedItems));
            if (![containedItems isKindOfClass:[NSArray class]]) {
                result = @{@"error": @"containedItems is not an array"};
                return;
            }

            // Snapshot the original order for undo
            NSArray *originalItems = [(NSArray *)containedItems copy];

            // Separate clips from transitions
            NSMutableArray *clips = [NSMutableArray array];
            NSMutableArray *transitions = [NSMutableArray array];
            for (id item in originalItems) {
                NSString *cls = NSStringFromClass([item class]);
                if ([cls containsString:@"Transition"]) {
                    [transitions addObject:item];
                } else {
                    [clips addObject:item];
                }
            }

            // Validate order indices
            if ((NSInteger)order.count != (NSInteger)clips.count) {
                result = @{@"error": [NSString stringWithFormat:
                    @"order has %lu elements but there are %lu clips",
                    (unsigned long)order.count, (unsigned long)clips.count]};
                return;
            }

            // Build the new clip order
            NSMutableArray *newClips = [NSMutableArray arrayWithCapacity:clips.count];
            NSMutableSet *usedIndices = [NSMutableSet set];
            for (NSNumber *idx in order) {
                NSInteger i = [idx integerValue];
                if (i < 0 || i >= (NSInteger)clips.count) {
                    result = @{@"error": [NSString stringWithFormat:
                        @"Index %ld out of range (0-%ld)", (long)i, (long)clips.count - 1]};
                    return;
                }
                if ([usedIndices containsObject:@(i)]) {
                    result = @{@"error": [NSString stringWithFormat:
                        @"Duplicate index %ld in order array", (long)i]};
                    return;
                }
                [usedIndices addObject:@(i)];
                [newClips addObject:clips[i]];
            }

            // Register undo with the library document's undo manager
            NSUndoManager *um = (NSUndoManager *)SpliceKit_getUndoManager();
            if (um) {
                [um beginUndoGrouping];
                [um setActionName:@"Shuffle Clips"];

                // Capture spine, sequence, and both orders for undo/redo
                id capturedSpine = spine;
                id capturedSequence = sequence;
                NSArray *capturedOriginal = originalItems;
                NSArray *capturedNew = [newClips copy];
                [um registerUndoWithTarget:(id)spine handler:^(id target) {
                    // UNDO: restore original order
                    SpliceKit_applySpineOrder(capturedSpine, capturedOriginal);
                    SpliceKit_refreshTimeline(capturedSequence);
                    // Register REDO: re-apply shuffled order
                    [um registerUndoWithTarget:(id)capturedSpine handler:^(id target2) {
                        SpliceKit_applySpineOrder(capturedSpine, capturedNew);
                        SpliceKit_refreshTimeline(capturedSequence);
                    }];
                }];
            }

            // Apply the new order
            SpliceKit_applySpineOrder(spine, newClips);
            SpliceKit_refreshTimeline(sequence);

            // Close the undo group
            if (um) {
                [um endUndoGrouping];
            }

            result = @{
                @"status": @"ok",
                @"clipsReordered": @(newClips.count),
                @"transitionsRemoved": @(transitions.count)
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

// timeline.beginEdit — open one undo step on the sequence.
// Everything between beginEdit and endEdit becomes a single Edit > Undo entry
// named after `name` (FCP's internal term is an undoable action). Opens with
// actionBegin: <name> when available -- the begin selector every shipped
// SpliceKit site pairs with actionEnd:save:error: -- and only falls back to
// the legacy actionBeginEditing / actionEndEditing:error: pair when it is not.
NSString *sOpenEditGroupName = nil;
// Which begin selector opened the current step, so endEdit closes with the
// matching end selector and never closes a transaction FCP itself opened.
static NSString *sOpenEditGroupBeginSelector = nil;

NSDictionary *SpliceKit_handleTimelineBeginEdit(NSDictionary *params) {
    NSString *name = ([params[@"name"] isKindOfClass:[NSString class]] && [params[@"name"] length] > 0)
        ? params[@"name"] : @"Edit";
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module."};
                return;
            }
            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) {
                result = @{@"error": @"No sequence in timeline."};
                return;
            }

            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            out[@"name"] = name;

            // Informational only: FCP's own view of whether a timeline transaction is open.
            BOOL hadOpen = NO;
            if (SpliceKit_tryReadBoolSelector(sequence, @"hasOpenTimelineTransaction", &hadOpen)) {
                out[@"hadOpenTransaction"] = @(hadOpen);
            }

            // SpliceKit's own state decides nesting: never open a second step on top of
            // one we already opened, and never let a probe make us skip a begin that we
            // would then fail to close.
            if (sOpenEditGroupName) {
                out[@"status"] = @"ok";
                out[@"note"] = @"an undo step opened by SpliceKit is already open; nested begin ignored";
                out[@"openName"] = sOpenEditGroupName;
                out[@"openedWith"] = sOpenEditGroupBeginSelector ?: @"";
                result = out;
                return;
            }

            SEL namedBeginSel = NSSelectorFromString(@"actionBegin:");
            SEL legacyBeginSel = NSSelectorFromString(@"actionBeginEditing");
            if ([sequence respondsToSelector:namedBeginSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(sequence, namedBeginSel, name);
                sOpenEditGroupBeginSelector = @"actionBegin:";
            } else if ([sequence respondsToSelector:legacyBeginSel]) {
                ((void (*)(id, SEL))objc_msgSend)(sequence, legacyBeginSel);
                sOpenEditGroupBeginSelector = @"actionBeginEditing";
            } else {
                result = @{@"error": @"Sequence responds to neither actionBegin: nor actionBeginEditing"};
                return;
            }
            sOpenEditGroupName = [name copy];
            out[@"openedWith"] = sOpenEditGroupBeginSelector;

            BOOL hasOpen = NO;
            if (SpliceKit_tryReadBoolSelector(sequence, @"hasOpenTimelineTransaction", &hasOpen)) {
                out[@"hasOpenTransaction"] = @(hasOpen);
            }
            out[@"status"] = @"ok";
            result = out;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

// timeline.endEdit — close the undo step opened by timeline.beginEdit with the
// end selector that matches the begin selector used (actionEnd:save:error: for
// actionBegin:, actionEndEditing:error: for actionBeginEditing), passing a real
// NSError pointer. Does nothing when SpliceKit has no step open, so it can never
// close a transaction FCP itself opened. Also forces a timing update and reloads
// the timeline view.
NSDictionary *SpliceKit_handleTimelineEndEdit(NSDictionary *params) {
    BOOL save = params[@"save"] ? [params[@"save"] boolValue] : YES;
    NSString *paramName = ([params[@"name"] isKindOfClass:[NSString class]] && [params[@"name"] length] > 0)
        ? params[@"name"] : nil;
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module."};
                return;
            }
            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) {
                result = @{@"error": @"No sequence in timeline."};
                return;
            }

            NSString *name = paramName ?: (sOpenEditGroupName ?: @"Edit");
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            out[@"name"] = name;
            out[@"saved"] = @(save);

            BOOL hadOpen = NO;
            if (SpliceKit_tryReadBoolSelector(sequence, @"hasOpenTimelineTransaction", &hadOpen)) {
                out[@"hadOpenTransaction"] = @(hadOpen);
            }

            if (!sOpenEditGroupName) {
                out[@"status"] = @"ok";
                out[@"note"] = @"no undo step opened by SpliceKit is open; nothing closed";
                result = out;
                return;
            }
            NSString *beginUsed = sOpenEditGroupBeginSelector ?: @"actionBegin:";

            // Force update to recalculate timing
            SEL forceUpdateSel = NSSelectorFromString(@"forceUpdate");
            if ([sequence respondsToSelector:forceUpdateSel]) {
                ((void (*)(id, SEL))objc_msgSend)(sequence, forceUpdateSel);
            }

            NSError *err = nil;
            BOOL endOK = YES;
            BOOL haveReturn = NO;
            if ([beginUsed isEqualToString:@"actionBeginEditing"]) {
                SEL endSel = NSSelectorFromString(@"actionEndEditing:error:");
                if (![sequence respondsToSelector:endSel]) {
                    sOpenEditGroupName = nil;
                    sOpenEditGroupBeginSelector = nil;
                    result = @{@"error": @"Sequence does not respond to actionEndEditing:error:", @"name": name};
                    return;
                }
                if (SpliceKit_selectorReturnsBOOL(sequence, endSel)) {
                    endOK = ((BOOL (*)(id, SEL, BOOL, NSError **))objc_msgSend)(sequence, endSel, save, &err);
                    haveReturn = YES;
                } else {
                    ((void (*)(id, SEL, BOOL, NSError **))objc_msgSend)(sequence, endSel, save, &err);
                }
                out[@"closedWith"] = @"actionEndEditing:error:";
            } else {
                SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
                if (![sequence respondsToSelector:endSel]) {
                    sOpenEditGroupName = nil;
                    sOpenEditGroupBeginSelector = nil;
                    result = @{@"error": @"Sequence does not respond to actionEnd:save:error:", @"name": name};
                    return;
                }
                if (SpliceKit_selectorReturnsBOOL(sequence, endSel)) {
                    endOK = ((BOOL (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(sequence, endSel, name, save, &err);
                    haveReturn = YES;
                } else {
                    ((void (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(sequence, endSel, name, save, &err);
                }
                out[@"closedWith"] = @"actionEnd:save:error:";
            }
            out[@"openedWith"] = beginUsed;
            sOpenEditGroupName = nil;
            sOpenEditGroupBeginSelector = nil;

            // Reload the timeline view
            SEL reloadSel = NSSelectorFromString(@"reloadTimelineView:");
            if ([timeline respondsToSelector:reloadSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, reloadSel, nil);
            }

            if (haveReturn) out[@"returnedOK"] = @(endOK);
            if (err) out[@"error"] = err.localizedDescription ?: [err description];

            BOOL hasOpen = NO;
            if (SpliceKit_tryReadBoolSelector(sequence, @"hasOpenTimelineTransaction", &hasOpen)) {
                out[@"hasOpenTransaction"] = @(hasOpen);
            }
            out[@"status"] = (err || (haveReturn && !endOK)) ? @"failed" : @"ok";
            result = out;
        } @catch (NSException *e) {
            sOpenEditGroupName = nil;
            sOpenEditGroupBeginSelector = nil;
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

// Main-thread-only helpers for grouping multi-step edits into one undo step.
// Skips begin when SpliceKit (or begin_edit) already has a group open.
BOOL SpliceKit_internalBeginEditGroupIfNeeded(id sequence, NSString *name) {
    if (!sequence || name.length == 0 || sOpenEditGroupName) {
        return NO;
    }
    SEL namedBeginSel = NSSelectorFromString(@"actionBegin:");
    SEL legacyBeginSel = NSSelectorFromString(@"actionBeginEditing");
    if ([sequence respondsToSelector:namedBeginSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(sequence, namedBeginSel, name);
        sOpenEditGroupBeginSelector = @"actionBegin:";
    } else if ([sequence respondsToSelector:legacyBeginSel]) {
        ((void (*)(id, SEL))objc_msgSend)(sequence, legacyBeginSel);
        sOpenEditGroupBeginSelector = @"actionBeginEditing";
    } else {
        return NO;
    }
    sOpenEditGroupName = [name copy];
    return YES;
}

void SpliceKit_internalEndEditGroupIfOpened(id sequence, id timeline, NSString *name, BOOL openedByUs) {
    if (!openedByUs || !sOpenEditGroupName) {
        return;
    }
    NSString *closeName = name.length > 0 ? name : (sOpenEditGroupName ?: @"Edit");
    NSString *beginUsed = sOpenEditGroupBeginSelector ?: @"actionBegin:";

    SEL forceUpdateSel = NSSelectorFromString(@"forceUpdate");
    if (sequence && [sequence respondsToSelector:forceUpdateSel]) {
        ((void (*)(id, SEL))objc_msgSend)(sequence, forceUpdateSel);
    }

    NSError *err = nil;
    if ([beginUsed isEqualToString:@"actionBeginEditing"]) {
        SEL endSel = NSSelectorFromString(@"actionEndEditing:error:");
        if (sequence && [sequence respondsToSelector:endSel]) {
            if (SpliceKit_selectorReturnsBOOL(sequence, endSel)) {
                ((BOOL (*)(id, SEL, BOOL, NSError **))objc_msgSend)(sequence, endSel, YES, &err);
            } else {
                ((void (*)(id, SEL, BOOL, NSError **))objc_msgSend)(sequence, endSel, YES, &err);
            }
        }
    } else {
        SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
        if (sequence && [sequence respondsToSelector:endSel]) {
            if (SpliceKit_selectorReturnsBOOL(sequence, endSel)) {
                ((BOOL (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(sequence, endSel, closeName, YES, &err);
            } else {
                ((void (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(sequence, endSel, closeName, YES, &err);
            }
        }
    }
    if (err) {
        SpliceKit_log(@"internalEndEditGroup \"%@\" error: %@", closeName, err.localizedDescription);
    }

    sOpenEditGroupName = nil;
    sOpenEditGroupBeginSelector = nil;

    SEL reloadSel = NSSelectorFromString(@"reloadTimelineView:");
    if (timeline && [timeline respondsToSelector:reloadSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(timeline, reloadSel, nil);
    }
}
