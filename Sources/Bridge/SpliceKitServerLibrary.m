//
//  SpliceKitServerLibrary.m
//  SpliceKit - Share destinations, creating projects / events / libraries, opening a
//  project by name, and selecting the clip at the playhead in a given lane.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Share/Export Handler

// The title of the item Final Cut Pro marks as the default share destination, e.g.
// "Export File (default)…". Main thread only.
static NSString *SpliceKit_defaultShareDestinationTitle(void) {
    @try {
        id app = ((id (*)(id, SEL))objc_msgSend)(
            objc_getClass("NSApplication"), @selector(sharedApplication));
        NSMenu *mainMenu = ((id (*)(id, SEL))objc_msgSend)(app, @selector(mainMenu));
        for (NSMenuItem *fileItem in mainMenu.itemArray) {
            if (![fileItem.title isEqualToString:@"File"] || !fileItem.hasSubmenu) continue;
            for (NSMenuItem *shareItem in fileItem.submenu.itemArray) {
                if (![shareItem.title isEqualToString:@"Share"] || !shareItem.hasSubmenu) continue;
                NSString *firstEnabled = nil;
                for (NSMenuItem *dest in shareItem.submenu.itemArray) {
                    if (dest.isSeparatorItem || dest.title.length == 0) continue;
                    if ([dest.title containsString:@"(default)"]) return dest.title;
                    if (!firstEnabled && dest.isEnabled &&
                        ![dest.title hasPrefix:@"Add Destination"]) {
                        firstEnabled = dest.title;
                    }
                }
                return firstEnabled;
            }
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Share] could not read the Share menu: %@", e.reason);
    }
    return nil;
}

// Fire a File > Share destination without waiting for it.
//
// Every share destination opens the Export sheet and sits there until a person answers
// it. Going through SpliceKit_handleMenuExecute means that sheet opens inside the
// bridge's own main-thread dispatch, so the 20-second watchdog gives up and reports
// "main thread stayed busy" with the sheet still on screen — which is exactly what
// share_project did. The item is located on the main thread (cheap, no modal) and its
// action is fired on a later turn of the run loop, so the bridge answers immediately and
// says the sheet is open, the way create_project does.
static NSDictionary *SpliceKit_shareDestinationAsyncNoWait(NSString *destination) {
    __block NSMenuItem *target = nil;
    __block NSMutableArray *available = [NSMutableArray array];
    SpliceKit_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            NSMenu *mainMenu = ((id (*)(id, SEL))objc_msgSend)(app, @selector(mainMenu));
            for (NSMenuItem *fileItem in mainMenu.itemArray) {
                if (![fileItem.title isEqualToString:@"File"] || !fileItem.hasSubmenu) continue;
                for (NSMenuItem *shareItem in fileItem.submenu.itemArray) {
                    if (![shareItem.title isEqualToString:@"Share"] || !shareItem.hasSubmenu) continue;
                    for (NSMenuItem *dest in shareItem.submenu.itemArray) {
                        if (dest.isSeparatorItem || dest.title.length == 0) continue;
                        [available addObject:dest.title];
                        NSString *bare = [dest.title stringByReplacingOccurrencesOfString:@"…"
                                                                               withString:@""];
                        if ([dest.title caseInsensitiveCompare:destination] == NSOrderedSame ||
                            [bare caseInsensitiveCompare:destination] == NSOrderedSame) {
                            target = dest;
                        }
                    }
                }
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[Share] could not read the Share menu: %@", e.reason);
        }
    });

    if (!target) {
        return @{@"error": [NSString stringWithFormat:
            @"No share destination called '%@' in File > Share. Available: %@",
            destination, [available componentsJoinedByString:@", "]]};
    }
    if (!target.isEnabled) {
        return @{@"error": [NSString stringWithFormat:
            @"The share destination '%@' is disabled right now. A project has to be open "
            @"and, for Share Selection, a range selected.", target.title]};
    }

    NSString *title = target.title;
    SEL action = target.action;
    id actionTarget = target.target;
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                app, @selector(sendAction:to:from:), action, actionTarget, target);
        } @catch (NSException *e) {
            SpliceKit_log(@"[Share] async %@ exception: %@", title, e.reason);
        }
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());

    return @{
        @"status": @"ok",
        @"destination": title,
        @"dialogPending": @YES,
        @"message": [NSString stringWithFormat:
            @"Final Cut Pro is opening the Export sheet for '%@'. It has to be answered at "
            @"the machine — the bridge can read it with detect_dialog and cancel it with "
            @"dismiss_dialog(action=\"cancel\"), but it cannot confirm a save panel.", title]
    };
}

NSDictionary *SpliceKit_handleShareExport(NSDictionary *params) {
    NSString *destination = params[@"destination"]; // optional: specific share destination

    if (destination) {
        return SpliceKit_shareDestinationAsyncNoWait(destination);
    }

    // No destination: use whichever one Final Cut Pro marks as the default.
    //
    // This used to send -shareDefaultDestination: down the responder chain. Nothing on
    // FCP 12.3 answers it, so share_project() with no argument always failed with "No
    // responder handled shareDefaultDestination:". The default destination is an ordinary
    // item in File > Share, titled "… (default)", so it is read from the menu and invoked
    // the same way a named destination is.
    __block NSString *title = nil;
    SpliceKit_executeOnMainThread(^{ title = SpliceKit_defaultShareDestinationTitle(); });
    if (title.length == 0) {
        return @{@"error": @"No share destination found in File > Share. Add one in Final "
                           @"Cut Pro's Settings > Destinations, or pass `destination` with "
                           @"the exact menu title."};
    }
    NSDictionary *r = SpliceKit_shareDestinationAsyncNoWait(title);
    if (![r isKindOfClass:[NSDictionary class]] || r[@"error"]) return r;
    NSMutableDictionary *out = [r mutableCopy];
    out[@"usedDefault"] = @YES;
    return out;
}

#pragma mark - Library/Project Management

NSDictionary *SpliceKit_handleProjectCreate(NSDictionary *params) {
    return SpliceKit_sendAppActionAsyncNoWait(@"newProject:");
}

NSDictionary *SpliceKit_handleEventCreate(NSDictionary *params) {
    return SpliceKit_sendAppActionAsyncNoWait(@"newEvent:");
}

NSDictionary *SpliceKit_handleLibraryCreate(NSDictionary *params) {
    return SpliceKit_sendAppActionAsyncNoWait(@"newLibrary:");
}

#pragma mark - Open Project by Name

NSDictionary *SpliceKit_handleProjectOpen(NSDictionary *params) {
    NSString *nameFilter = params[@"name"];
    NSString *eventFilter = params[@"event"];
    if (!nameFilter) return @{@"error": @"name parameter required"};

    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            // Step 1: Get active libraries
            Class libDocClass = objc_getClass("FFLibraryDocument");
            if (!libDocClass) {
                result = @{@"error": @"FFLibraryDocument class not found"};
                return;
            }

            SEL copyLibsSel = NSSelectorFromString(@"copyActiveLibraries");
            if (![libDocClass respondsToSelector:copyLibsSel]) {
                result = @{@"error": @"copyActiveLibraries not available"};
                return;
            }

            id libs = ((id (*)(id, SEL))objc_msgSend)((id)libDocClass, copyLibsSel);
            if (!libs || ![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active libraries found"};
                return;
            }

            // Step 2: Search across all libraries for matching sequence
            id foundSequence = nil;
            BOOL foundExact = NO;
            NSString *foundName = nil;
            NSString *foundEvent = nil;
            NSString *foundLibrary = nil;
            NSMutableArray *allSequences = [NSMutableArray array];

            // Walk each library's events, not -_deepLoadedSequences.
            //
            // Two things were wrong with the old walk. _deepLoadedSequences only answers
            // sequences Final Cut Pro has already loaded, so a project that has not been
            // opened yet in this session could not be opened by name at all. And the
            // event name came from -[FFAnchoredSequence event], which FCP 12.3 does not
            // answer: every entry reported event="" and so `event=` never matched
            // anything, including the name it was looking at. The event is the object
            // holding the sequence, which this walk has in hand.
            SEL dnSel = @selector(displayName);
            for (id lib in (NSArray *)libs) {
                NSString *libName = @"";
                if ([lib respondsToSelector:dnSel]) {
                    libName = ((id (*)(id, SEL))objc_msgSend)(lib, dnSel) ?: @"";
                }

                SEL eventsSel = NSSelectorFromString(@"events");
                if (![lib respondsToSelector:eventsSel]) continue;
                id events = ((id (*)(id, SEL))objc_msgSend)(lib, eventsSel);
                if (![events isKindOfClass:[NSArray class]]) continue;

                for (id event in (NSArray *)events) {
                    NSString *seqEvent = @"";
                    if ([event respondsToSelector:dnSel]) {
                        seqEvent = ((id (*)(id, SEL))objc_msgSend)(event, dnSel) ?: @"";
                    }

                    for (id seq in SpliceKit_browserClipsOfEvent(event)) {
                        if (!SpliceKit_browserItemIsProject(seq)) continue;

                        NSString *seqName = @"";
                        if ([seq respondsToSelector:dnSel]) {
                            seqName = ((id (*)(id, SEL))objc_msgSend)(seq, dnSel) ?: @"";
                        }

                        BOOL hasContent = NO;
                        SEL hasItemsSel = NSSelectorFromString(@"hasContainedItems");
                        if ([seq respondsToSelector:hasItemsSel]) {
                            hasContent = ((BOOL (*)(id, SEL))objc_msgSend)(seq, hasItemsSel);
                        }

                        [allSequences addObject:@{
                            @"name": seqName,
                            @"event": seqEvent,
                            @"library": libName,
                            @"hasContent": @(hasContent),
                        }];

                        // Match by name (case-insensitive contains), but an exact name
                        // wins over a longer one that merely contains it. Final Cut Pro
                        // hands out "QA Timeline 1" when "QA Timeline" is taken, and
                        // asking for "QA Timeline" used to open whichever of the two the
                        // walk reached first.
                        BOOL nameMatch = [seqName localizedCaseInsensitiveContainsString:nameFilter];
                        BOOL eventMatch = !eventFilter || eventFilter.length == 0 ||
                            [seqEvent localizedCaseInsensitiveContainsString:eventFilter];
                        BOOL exact = [seqName caseInsensitiveCompare:nameFilter] == NSOrderedSame;

                        if (nameMatch && eventMatch && (!foundSequence || (exact && !foundExact))) {
                            foundSequence = seq;
                            foundName = seqName;
                            foundEvent = seqEvent;
                            foundLibrary = libName;
                            foundExact = exact;
                        }
                    }
                }
            }

            if (!foundSequence) {
                result = @{@"error": [NSString stringWithFormat:
                    @"No project matching name='%@'%@ found. Available: %@",
                    nameFilter,
                    eventFilter ? [NSString stringWithFormat:@" event='%@'", eventFilter] : @"",
                    allSequences]};
                return;
            }

            // Step 3: Load the sequence into the editor
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
            if (!delegate) {
                result = @{@"error": @"No app delegate"};
                return;
            }

            SEL aecSel = @selector(activeEditorContainer);
            if (![delegate respondsToSelector:aecSel]) {
                result = @{@"error": @"No activeEditorContainer"};
                return;
            }
            id editorContainer = ((id (*)(id, SEL))objc_msgSend)(delegate, aecSel);
            if (!editorContainer) {
                result = @{@"error": @"Editor container is nil"};
                return;
            }

            SEL loadSel = NSSelectorFromString(@"loadEditorForSequence:");
            if (![editorContainer respondsToSelector:loadSel]) {
                result = @{@"error": @"loadEditorForSequence: not available on editor container"};
                return;
            }

            ((void (*)(id, SEL, id))objc_msgSend)(editorContainer, loadSel, foundSequence);

            result = @{
                @"status": @"ok",
                @"project": foundName ?: @"",
                @"event": foundEvent ?: @"",
                @"library": foundLibrary ?: @"",
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}

#pragma mark - Select Clip at Playhead with Lane

// The timeline item whose pointer key (object identity, as getDetailedState reports
// it with include_pointer_keys) is `key`: the spine's containedItems, every item's
// anchoredItems and every container's containedItems, to a bounded depth. Independent
// of the handle table, which a long walk can clear (SPLICEKIT_MAX_HANDLES).
static id SpliceKit_findTimelineItemByPointerKey(id container, NSString *key, NSInteger depth) {
    if (!container || key.length == 0 || depth > 8) return nil;
    for (NSString *selName in @[@"containedItems", @"anchoredItems"]) {
        SEL sel = NSSelectorFromString(selName);
        if (![container respondsToSelector:sel]) continue;
        NSArray *children = nil;
        @try {
            children = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(container, sel));
        } @catch (NSException *e) { children = nil; }
        for (id child in children) {
            if ([SpliceKit_handlePointerKey(child) isEqualToString:key]) return child;
        }
        for (id child in children) {
            id found = SpliceKit_findTimelineItemByPointerKey(child, key, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

NSDictionary *SpliceKit_handleSelectClipAtPlayheadLane(NSDictionary *params) {
    NSNumber *laneParam = params[@"lane"];
    if (!laneParam) return @{@"error": @"lane parameter required"};
    long long targetLane = [laneParam longLongValue];

    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module"};
                return;
            }

            id sequence = nil;
            if ([timeline respondsToSelector:@selector(sequence)]) {
                sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            }
            if (!sequence) {
                result = @{@"error": @"No sequence in timeline"};
                return;
            }

            // Get playhead time
            SpliceKit_CMTime playhead = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(
                timeline, @selector(playheadTime));

            // Get all items including connected clips (anchoredItems)
            id primaryObj = nil;
            if ([sequence respondsToSelector:@selector(primaryObject)]) {
                primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
            }
            if (!primaryObj) {
                result = @{@"error": @"No primary object on sequence"};
                return;
            }

            // Candidates come from the same walk get_timeline_clips reports (spine items on
            // lane 0; connected clips, nested ones included, with their lane relative to the
            // primary storyline and their absolute range), so this tool and that one agree
            // about the same timeline. The earlier direct scan read anchoredItems as an
            // NSArray, which FCP does not hand back for every clip, and found nothing.
            double playheadSec = playhead.timescale > 0 ? (double)playhead.value / (double)playhead.timescale : 0.0;
            NSDictionary *state = SpliceKit_handleTimelineGetDetailedState(@{@"limit": @100000,
                                                                             @"connected_limit": @100000,
                                                                             @"include_markers": @NO,
                                                                             @"include_nested": @NO,
                                                                             @"include_connected": @(targetLane != 0),
                                                                             @"include_pointer_keys": @YES});
            if (![state isKindOfClass:[NSDictionary class]] || state[@"error"]) {
                result = @{@"error": [NSString stringWithFormat:@"could not read the timeline: %@",
                                      state[@"error"] ?: @"no state"]};
                return;
            }
            id listAny = targetLane == 0 ? state[@"items"] : state[@"connectedItems"];
            NSArray *list = [listAny isKindOfClass:[NSArray class]] ? listAny : @[];
            NSUInteger candidateCount = 0;
            NSDictionary *bestEntry = nil;          // first clip under the playhead in that lane
            NSDictionary *containerEntry = nil;     // a connected storyline container there
            for (id entryAny in list) {
                if (![entryAny isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *entry = entryAny;
                if (targetLane != 0) {
                    id laneNum = entry[@"effectiveLane"] ?: entry[@"lane"];
                    if (![laneNum respondsToSelector:@selector(longLongValue)] ||
                        [laneNum longLongValue] != targetLane) continue;
                }
                candidateCount++;          // every clip in the lane, matched or not
                if (bestEntry) continue;
                double startSec = SpliceKit_browserEntrySeconds(entry, @"startTime");
                double endSec = SpliceKit_browserEntrySeconds(entry, @"endTime");
                if (isnan(startSec) || isnan(endSec)) continue;
                if (playheadSec < startSec - 0.001 || playheadSec > endSec + 0.001) continue;
                // A connected storyline is a container; the clip inside it (listed with the
                // same lane) is what a click there selects, so prefer that.
                if ([entry[@"isConnectedStoryline"] boolValue]) {
                    if (!containerEntry) containerEntry = entry;
                    continue;
                }
                bestEntry = entry;
            }
            if (!bestEntry) bestEntry = containerEntry;
            id bestMatch = nil;
            if (bestEntry) {
                // The walk stores a handle per item, and on a very long timeline the handle
                // table can be cleared before the walk ends; the object identity the walk
                // also reports (pointerKey) is what the match is checked and, if need be,
                // found by.
                NSString *wantKey = [bestEntry[@"pointerKey"] isKindOfClass:[NSString class]] ? bestEntry[@"pointerKey"] : nil;
                NSString *bestHandle = [bestEntry[@"handle"] isKindOfClass:[NSString class]] ? bestEntry[@"handle"] : nil;
                bestMatch = bestHandle.length > 0 ? SpliceKit_resolveHandle(bestHandle) : nil;
                if (bestMatch && wantKey.length > 0 && ![SpliceKit_handlePointerKey(bestMatch) isEqualToString:wantKey]) {
                    bestMatch = nil;
                }
                if (!bestMatch && wantKey.length > 0) {
                    bestMatch = SpliceKit_findTimelineItemByPointerKey(primaryObj, wantKey, 0);
                }
            }

            if (!bestMatch) {
                if (bestEntry) {
                    result = @{@"error": [NSString stringWithFormat:
                        @"The clip at the playhead (%.3fs) in lane %lld, \"%@\", could not be resolved to its object (its handle expired and it was not found by identity); call get_timeline_clips and try again.",
                        playheadSec, targetLane,
                        [bestEntry[@"name"] isKindOfClass:[NSString class]] ? bestEntry[@"name"] : @""]};
                    return;
                }
                result = @{@"error": [NSString stringWithFormat:
                    @"No clip found at playhead (%.3fs) in lane %lld. %lu clip%@ in that lane (get_timeline_clips lists them with their times).",
                    playheadSec, targetLane, (unsigned long)candidateCount, candidateCount == 1 ? @"" : @"s"]};
                return;
            }

            // Select through the same path select_clips uses (setSelectedItems: and its
            // fallbacks), and read the selection back.
            NSString *usedSelector = nil;
            if (!SpliceKit_handleSelectionApply(timeline, @[bestMatch], &usedSelector)) {
                result = @{@"error": @"Timeline module responds to none of setSelectedItems:, _setSelectedItems:, selectItems:"};
                return;
            }
            NSArray *readback = SpliceKit_handleSelectionCurrentItems(timeline);
            BOOL selectedNow = NO;
            for (id sel in readback) { if (sel == bestMatch) { selectedNow = YES; break; } }

            NSString *clipName = SpliceKit_displayNameForItem(bestMatch) ?: @"";
            NSString *handle = SpliceKit_storeHandle(bestMatch);

            NSMutableDictionary *out = [NSMutableDictionary dictionaryWithDictionary:@{
                @"status": @"ok",
                @"lane": @(targetLane),
                @"clip": clipName,
                @"class": NSStringFromClass([bestMatch class]),
                @"handle": handle,
                @"playheadSeconds": @(playheadSec),
                @"selected": @(selectedNow),
                @"selector": usedSelector ?: @"",
                @"candidatesInLane": @(candidateCount),
            }];
            double bs = SpliceKit_browserEntrySeconds(bestEntry, @"startTime");
            double be = SpliceKit_browserEntrySeconds(bestEntry, @"endTime");
            if (!isnan(bs)) out[@"startSeconds"] = @(bs);
            if (!isnan(be)) out[@"endSeconds"] = @(be);
            if ([bestEntry[@"isConnectedStoryline"] boolValue]) out[@"isConnectedStoryline"] = @YES;
            result = out;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}
