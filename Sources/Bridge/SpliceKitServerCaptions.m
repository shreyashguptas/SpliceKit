//
//  SpliceKitServerCaptions.m
//  SpliceKit - captions.* handlers (styled social-media caption titles), the cleanup of
//  SpliceKit's scratch import projects, and native FCP captions (FFAnchoredCaption).
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Social Media Captions
//
// Handlers for the social captions panel — word-by-word highlighted titles
// generated as FCPXML and imported into the timeline. The caption panel does
// the heavy lifting; these handlers just proxy parameters through.
//

NSDictionary *SpliceKit_handleCaptionsOpen(NSDictionary *params) {
    // The caption panel transcribes the timeline only: its words carry timeline times and
    // the clips they came from, which is what generate places the titles by. A bare file has
    // neither, so fileURL is refused instead of being ignored (it used to start a timeline
    // transcription). A file's words: transcript.open with fileURL.
    id fileURL = params[@"fileURL"];
    if (fileURL && fileURL != [NSNull null]
        && !([fileURL isKindOfClass:[NSString class]] && [(NSString *)fileURL length] == 0)) {
        return @{@"error": @"captions.open does not transcribe a file: the caption panel only "
                            @"transcribes the clips on the open timeline. Leave fileURL out, or "
                            @"transcribe the file with transcript.open (fileURL) instead."};
    }
    NSString *presetID = params[@"style"];
    // Discard the persisted captions and transcribe the timeline again (the timeline may
    // have changed since they were made); the counterpart of transcript.open's flag.
    BOOL forceRetranscribe = [params[@"forceRetranscribe"] respondsToSelector:@selector(boolValue)]
        && [params[@"forceRetranscribe"] boolValue];
    __block BOOL startedTranscription = NO;
    __block BOOL restoredCaptions = NO;
    __block BOOL alreadyTranscribing = NO;

    SpliceKit_executeOnMainThread(^{
        SpliceKitCaptionPanel *panel = [SpliceKitCaptionPanel sharedPanel];
        if (presetID) {
            SpliceKitCaptionStyle *style = [SpliceKitCaptionStyle presetWithID:presetID];
            if (style) [panel setStyle:style];
        }
        [panel showPanel];
        if (panel.status == SpliceKitCaptionStatusTranscribing) {
            alreadyTranscribing = YES;
        } else if (forceRetranscribe) {
            [panel transcribeTimeline];
            startedTranscription = YES;
        } else if (panel.status == SpliceKitCaptionStatusReady && panel.words.count > 0) {
            restoredCaptions = YES;
        } else if (panel.status == SpliceKitCaptionStatusTranscribing) {
            alreadyTranscribing = YES;
        } else if (panel.words.count == 0) {
            [panel transcribeTimeline];
            startedTranscription = YES;
        }
    });

    if (startedTranscription) {
        return @{
            @"status": @"ok",
            @"message": @"Caption panel opened. Transcription started. Use captions.getState to check progress.",
            @"transcriptionStarted": @YES,
        };
    }
    if (alreadyTranscribing) {
        return @{
            @"status": @"ok",
            @"message": @"Caption panel opened. Transcription already in progress. Use captions.getState to check progress.",
            @"transcriptionStarted": @NO,
        };
    }
    return @{
        @"status": @"ok",
        @"message": restoredCaptions ? @"Caption panel opened. Restored persisted captions." : @"Caption panel opened.",
        @"transcriptionStarted": @NO,
    };
}

NSDictionary *SpliceKit_handleCaptionsClose(NSDictionary *params) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SpliceKitCaptionPanel sharedPanel] hidePanel];
    });
    return @{@"status": @"ok"};
}

NSDictionary *SpliceKit_handleCaptionsGetState(NSDictionary *params) {
    return [[SpliceKitCaptionPanel sharedPanel] getState] ?: @{@"status": @"idle"};
}

NSDictionary *SpliceKit_handleCaptionsGetStyles(NSDictionary *params) {
    NSArray *presets = [SpliceKitCaptionStyle builtInPresets];
    NSMutableArray *list = [NSMutableArray array];
    for (SpliceKitCaptionStyle *s in presets) {
        [list addObject:[s toDictionary]];
    }
    return @{@"styles": list, @"count": @(list.count)};
}

NSDictionary *SpliceKit_handleCaptionsSetStyle(NSDictionary *params) {
    NSString *presetID = params[@"presetID"];
    SpliceKitCaptionStyle *style = nil;

    if (presetID) {
        style = [SpliceKitCaptionStyle presetWithID:presetID];
        if (!style) return @{@"error": [NSString stringWithFormat:@"Unknown preset: %@", presetID]};
        // Merge all params as overrides on top of the preset
        NSMutableDictionary *merged = [[style toDictionary] mutableCopy];
        for (NSString *key in params) {
            if (![key isEqualToString:@"presetID"]) merged[key] = params[key];
        }
        style = [SpliceKitCaptionStyle fromDictionary:merged];
    } else {
        style = [SpliceKitCaptionStyle fromDictionary:params];
    }

    [[SpliceKitCaptionPanel sharedPanel] setStyle:style];
    return @{@"status": @"ok", @"style": [style toDictionary]};
}

NSDictionary *SpliceKit_handleCaptionsSetGrouping(NSDictionary *params) {
    SpliceKitCaptionPanel *panel = [SpliceKitCaptionPanel sharedPanel];
    NSString *mode = params[@"mode"];
    if ([mode isEqualToString:@"words"]) panel.groupingMode = SpliceKitCaptionGroupingByWordCount;
    else if ([mode isEqualToString:@"sentence"]) panel.groupingMode = SpliceKitCaptionGroupingBySentence;
    else if ([mode isEqualToString:@"time"]) panel.groupingMode = SpliceKitCaptionGroupingByTime;
    else if ([mode isEqualToString:@"chars"]) panel.groupingMode = SpliceKitCaptionGroupingByCharCount;
    else if ([mode isEqualToString:@"social"]) panel.groupingMode = SpliceKitCaptionGroupingSocial;

    if (params[@"maxWords"]) panel.maxWordsPerSegment = [params[@"maxWords"] unsignedIntegerValue];
    if (params[@"maxChars"]) panel.maxCharsPerSegment = [params[@"maxChars"] unsignedIntegerValue];
    if (params[@"maxSeconds"]) panel.maxSecondsPerSegment = [params[@"maxSeconds"] doubleValue];

    [panel regroupSegments];
    return @{@"status": @"ok", @"segmentCount": @(panel.segments.count)};
}

NSDictionary *SpliceKit_handleCaptionsGenerate(NSDictionary *params) {
    SpliceKitCaptionPanel *panel = [SpliceKitCaptionPanel sharedPanel];

    // Support one-shot: set style + grouping + generate in one call
    if (params[@"style"] || params[@"presetID"]) {
        NSString *pid = params[@"style"] ?: params[@"presetID"];
        SpliceKitCaptionStyle *style = [SpliceKitCaptionStyle presetWithID:pid];
        if (style) {
            // Apply overrides via serialization round-trip.
            // Map MCP param names to style dict keys.
            NSDictionary *keyMap = @{
                @"word_highlight": @"wordByWordHighlight",
                @"all_caps": @"allCaps",
                @"font_size": @"fontSize",
                @"font_face": @"fontFace",
                @"outline_width": @"outlineWidth",
            };
            NSMutableDictionary *merged = [[style toDictionary] mutableCopy];
            for (NSString *key in params) {
                if ([key isEqualToString:@"style"] || [key isEqualToString:@"presetID"] ||
                    [key isEqualToString:@"maxWords"]) continue;
                NSString *mappedKey = keyMap[key] ?: key;
                merged[mappedKey] = params[key];
            }
            style = [SpliceKitCaptionStyle fromDictionary:merged];
            [panel setStyle:style];
        }
    }
    if (params[@"maxWords"]) {
        panel.maxWordsPerSegment = [params[@"maxWords"] unsignedIntegerValue];
        [panel regroupSegments];
    }

    // Run on background thread — generateCaptions touches FCP on the main thread
    // as needed, then stores the final result on the caption panel for getState.
    // The previous run's result goes first: getState shows lastGenerateResult again only
    // when this run has finished, which is what the MCP tool waits for.
    [panel clearLastGenerateResult];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *genResult = [panel generateCaptions];
        SpliceKit_log(@"[Captions] Generate result: %@", genResult);
    });
    return @{@"status": @"ok", @"async": @YES,
             @"message": @"Caption generation started. captions.getState reports lastGenerateResult when it has finished."};
}

NSDictionary *SpliceKit_handleCaptionsExportSRT(NSDictionary *params) {
    NSString *path = params[@"path"];
    if (!path) return @{@"error": @"path parameter required"};
    return [[SpliceKitCaptionPanel sharedPanel] exportSRT:path];
}

NSDictionary *SpliceKit_handleCaptionsExportTXT(NSDictionary *params) {
    NSString *path = params[@"path"];
    if (!path) return @{@"error": @"path parameter required"};
    return [[SpliceKitCaptionPanel sharedPanel] exportTXT:path];
}

NSDictionary *SpliceKit_handleCaptionsSetWords(NSDictionary *params) {
    NSArray *wordDicts = params[@"words"];
    if (!wordDicts || ![wordDicts isKindOfClass:[NSArray class]])
        return @{@"error": @"words array required"};
    [[SpliceKitCaptionPanel sharedPanel] setWordsManually:wordDicts];
    return @{@"status": @"ok", @"wordCount": @(wordDicts.count)};
}

// A gap is a generator (FFAnchoredGapGeneratorComponent, display name "Gap"), so the
// class-name check below would treat it as a caption title and verify_captions would
// report "No text found on 'Gap'". It is not a caption.
static BOOL SpliceKit_nameIsGap(id name) {
    return [name isKindOfClass:[NSString class]] && [(NSString *)name isEqualToString:@"Gap"];
}

BOOL SpliceKit_itemIsGapGenerator(id item) {
    if (!item) return NO;
    Class gapClass = objc_getClass("FFAnchoredGapGeneratorComponent");
    if (gapClass && [item isKindOfClass:gapClass]) return YES;
    NSString *className = NSStringFromClass([item class]) ?: @"";
    if ([className isEqualToString:@"FFAnchoredGapGeneratorComponent"] ||
        [className containsString:@"GapGenerator"]) return YES;
    if (SpliceKit_nameIsGap(SpliceKit_displayNameForItem(item))) return YES;
    @try {
        SEL effectSel = NSSelectorFromString(@"effect");
        if ([item respondsToSelector:effectSel]) {
            id effect = ((id (*)(id, SEL))objc_msgSend)(item, effectSel);
            if (effect && SpliceKit_nameIsGap(SpliceKit_displayNameForItem(effect))) return YES;
            SEL nameSel = NSSelectorFromString(@"name");
            if (effect && [effect respondsToSelector:nameSel]) {
                id effectName = ((id (*)(id, SEL))objc_msgSend)(effect, nameSel);
                if (SpliceKit_nameIsGap(effectName)) return YES;
            }
        }
    } @catch (NSException *e) {}
    return NO;
}

BOOL SpliceKit_itemIsMotionTitleVerifyCandidate(id item) {
    if (!item || SpliceKit_itemIsGapGenerator(item)) return NO;
    NSString *className = NSStringFromClass([item class]);
    BOOL isGenerator = [className containsString:@"Generator"] || [className containsString:@"Motion"];
    SEL esSel = NSSelectorFromString(@"effectStack");
    id effectStack = [item respondsToSelector:esSel]
        ? ((id (*)(id, SEL))objc_msgSend)(item, esSel) : nil;
    return effectStack || isGenerator;
}

// Build one verify_captions entry for a generator/Motion title (connected or nested in a storyline).
NSMutableDictionary *SpliceKit_buildVerifiedMotionTitleEntry(id connectedItem) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    NSString *className = NSStringFromClass([connectedItem class]);
    SEL esSel = NSSelectorFromString(@"effectStack");
    id effectStack = [connectedItem respondsToSelector:esSel]
        ? ((id (*)(id, SEL))objc_msgSend)(connectedItem, esSel) : nil;

    @try {
        if ([connectedItem respondsToSelector:@selector(displayName)]) {
            id n = ((id (*)(id, SEL))objc_msgSend)(connectedItem, @selector(displayName));
            if (n) entry[@"name"] = [n description];
        }
    } @catch (NSException *e) {}
    entry[@"class"] = className;

    NSMutableArray *textChannels = [NSMutableArray array];
    @try {
        SEL effectSel = NSSelectorFromString(@"effect");
        id genEffect = [connectedItem respondsToSelector:effectSel]
            ? ((id (*)(id, SEL))objc_msgSend)(connectedItem, effectSel) : nil;
        if (genEffect) {
            SEL cfSel = NSSelectorFromString(@"channelFolder");
            id cf = [genEffect respondsToSelector:cfSel]
                ? ((id (*)(id, SEL))objc_msgSend)(genEffect, cfSel) : nil;
            if (cf) SpliceKit_collectTitleText(cf, textChannels, 0);
        }
    } @catch (NSException *e) {}

    if (textChannels.count == 0 && effectStack) {
        @try {
            SEL efSel = NSSelectorFromString(@"visibleEffects");
            if ([effectStack respondsToSelector:efSel]) {
                NSArray *effects = ((id (*)(id, SEL))objc_msgSend)(effectStack, efSel);
                for (id effect in effects) {
                    SEL cfSel = NSSelectorFromString(@"channelFolder");
                    if ([effect respondsToSelector:cfSel]) {
                        id cf = ((id (*)(id, SEL))objc_msgSend)(effect, cfSel);
                        if (cf) SpliceKit_collectTitleText(cf, textChannels, 0);
                    }
                }
            }
        } @catch (NSException *e) {}
    }

    if (textChannels.count > 0) {
        NSDictionary *first = textChannels.firstObject;
        if (first[@"text"]) entry[@"text"] = first[@"text"];
        if (first[@"fontSize"]) entry[@"fontSize"] = first[@"fontSize"];
        if (first[@"fontFamily"]) entry[@"fontFamily"] = first[@"fontFamily"];
        if (first[@"fontName"]) entry[@"fontName"] = first[@"fontName"];
        entry[@"textChannelCount"] = @(textChannels.count);
    }

    return entry;
}

// Verify that generated captions rendered correctly by inspecting timeline items.
// Finds connected title clips and reads their text channels to confirm
// text content, font size, and font family match the expected style.
NSDictionary *SpliceKit_handleCaptionsVerify(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            SEL seqSel = NSSelectorFromString(@"sequence");
            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
            if (!sequence) { result = @{@"error": @"No sequence"}; return; }

            // Get the primary storyline's contained items
            SEL primarySel = NSSelectorFromString(@"primaryObject");
            id primary = [sequence respondsToSelector:primarySel]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, primarySel) : nil;
            if (!primary) { result = @{@"error": @"No primary object"}; return; }

            // Walk spine anchored items and descend into connected storylines (same as generate_captions paste).
            NSMutableArray *verified = [NSMutableArray array];
            int maxToCheck = 5; // Check first 5 titles for efficiency

            for (id connectedItem in SpliceKit_allMotionTitleCandidatesOnSequence(sequence)) {
                if ((int)verified.count >= maxToCheck) break;
                // Gap generators are not captions. Skip them before they become
                // a "No text found" issue; a real title with no text still counts.
                if (SpliceKit_itemIsGapGenerator(connectedItem)) continue;
                if (!SpliceKit_itemIsMotionTitleVerifyCandidate(connectedItem)) continue;
                [verified addObject:SpliceKit_buildVerifiedMotionTitleEntry(connectedItem)];
            }

            // Compare against expected style from the caption panel
            SpliceKitCaptionPanel *panel = [SpliceKitCaptionPanel sharedPanel];
            SpliceKitCaptionStyle *expectedStyle = panel.currentStyle;
            NSMutableArray *issues = [NSMutableArray array];

            for (NSDictionary *v in verified) {
                if (v[@"fontSize"] && expectedStyle) {
                    double actual = [v[@"fontSize"] doubleValue];
                    double expected = expectedStyle.fontSize;
                    if (fabs(actual - expected) > 1.0) {
                        [issues addObject:[NSString stringWithFormat:
                            @"Font size mismatch on '%@': expected %.0f, got %.0f",
                            v[@"name"] ?: @"?", expected, actual]];
                    }
                }
                if (!v[@"text"] || [v[@"text"] length] == 0) {
                    [issues addObject:[NSString stringWithFormat:
                        @"No text found on '%@'", v[@"name"] ?: @"?"]];
                }
            }

            NSMutableDictionary *res = [NSMutableDictionary dictionary];
            res[@"status"] = issues.count > 0 ? @"issues_found" : @"ok";
            res[@"titlesChecked"] = @(verified.count);
            res[@"verified"] = verified;
            if (issues.count > 0) res[@"issues"] = issues;
            if (expectedStyle) {
                res[@"expectedFontSize"] = @(expectedStyle.fontSize);
                res[@"expectedFont"] = expectedStyle.font ?: @"Helvetica";
            }
            result = res;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Verification failed"};
}

// Every scratch project SpliceKit creates for an import must be named here, or
// cleanup_temp_projects walks straight past it and it stays in the library for good.
// "_SKPaste_" was missing: the FCPXML pasteboard route (see the tempProjectName built
// further down this file) imports into a uniquely named project and switches back, and
// three of those were found sitting in the QA library reporting
// "No scratch import projects found".

// Does `name` match one of `patterns` from end to end?
//
// These were hasPrefix: tests, which is far too loose for something whose answer is
// "trash this". A user project called "SK Structure notes", or an event called
// "SpliceKit Captions Q3 review", matched — and the walk had just been widened from
// "sequences Final Cut Pro happens to have loaded" to every project in the library,
// so a colliding name anywhere, never opened, became reachable.
//
// The names SpliceKit generates are exact shapes: "SpliceKit Caption Import %u",
// "SK Structure %u" and "_SKPaste_%u", each with a random number. Final Cut Pro only
// ever appends " N" to de-duplicate. So the whole name is matched, and a name that
// merely starts the same way is left alone.
static BOOL SpliceKit_nameMatchesAnyPattern(NSString *name, NSArray<NSRegularExpression *> *patterns) {
    if (name.length == 0) return NO;
    for (NSRegularExpression *re in patterns) {
        if ([re numberOfMatchesInString:name options:0 range:NSMakeRange(0, name.length)] > 0) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSRegularExpression *> *SpliceKit_compilePatterns(NSArray<NSString *> *sources) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *src in sources) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:src
                                                                           options:0
                                                                             error:NULL];
        if (re) [out addObject:re];
    }
    return out;
}

static BOOL SpliceKit_isScratchImportProjectName(NSString *name) {
    static NSArray<NSRegularExpression *> *patterns = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        patterns = SpliceKit_compilePatterns(@[
            @"^SpliceKit Caption Import \\d+( \\d+)*$",
            @"^SK Structure \\d+( \\d+)*$",
            @"^_SKPaste_\\d+( \\d+)*$",
        ]);
    });
    return SpliceKit_nameMatchesAnyPattern(name, patterns);
}

// The library item to trash when we want a PROJECT gone.
//
// -[FFAnchoredSequence libraryItem] and -containerObject both answer the
// FFEventRecord the project lives IN, not the project's own record. Trashing that
// would take the whole event with it — for the QA timeline that is the event holding
// every source clip. -targetSequenceRecord is the project's own FFSequenceRecord and
// is the only one of the three that is safe to trash, so it is tried first and an
// event record is refused outright.
// The events SpliceKit's own FCPXML declares (<event name="SpliceKit Captions"> and
// <event name="SpliceKit Structure">). Final Cut Pro de-duplicates an imported event name
// by appending a number, so each import leaves behind "SpliceKit Captions 3", "… 4", "… 5".
// Only ours, and only ever removed once emptied — see the sweep in captions.cleanup.
static BOOL SpliceKit_isScratchImportEventName(NSString *name) {
    static NSArray<NSRegularExpression *> *patterns = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Declared without a number; Final Cut Pro appends " 3", " 4" to de-duplicate.
        patterns = SpliceKit_compilePatterns(@[
            @"^SpliceKit Captions( \\d+)*$",
            @"^SpliceKit Structure( \\d+)*$",
        ]);
    });
    return SpliceKit_nameMatchesAnyPattern(name, patterns);
}

static id SpliceKit_libraryItemForSequence(id sequence) {
    if (!sequence) return nil;
    SEL selectors[] = {
        NSSelectorFromString(@"targetSequenceRecord"),
        NSSelectorFromString(@"libraryItem"),
        NSSelectorFromString(@"containerObject"),
        NSSelectorFromString(@"targetLibraryItem"),
    };
    Class eventRecordClass = objc_getClass("FFEventRecord");
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL sel = selectors[i];
        if (![sequence respondsToSelector:sel]) continue;
        id item = nil;
        @try { item = ((id (*)(id, SEL))objc_msgSend)(sequence, sel); }
        @catch (NSException *e) { item = nil; }
        if (!item) continue;
        if (eventRecordClass && [item isKindOfClass:eventRecordClass]) {
            SpliceKit_log(@"[SpliceKit] Refusing to trash an event: -%@ on a sequence answers "
                          @"the enclosing event, not the project",
                          NSStringFromSelector(sel));
            continue;
        }
        return item;
    }

    // Nothing usable yet. -targetSequenceRecord is nil until Final Cut Pro has actually
    // loaded the sequence, which is the state every scratch project left over from an
    // earlier session is in. The enclosing event is an FFLibraryItem, so ask it for the
    // child record by name.
    SEL containerSel = NSSelectorFromString(@"containerObject");
    SEL namedSel = NSSelectorFromString(@"childItemNamed:");
    SEL displayNameSel = NSSelectorFromString(@"displayName");
    if ([sequence respondsToSelector:containerSel] && [sequence respondsToSelector:displayNameSel]) {
        id container = nil;
        NSString *name = nil;
        @try {
            container = ((id (*)(id, SEL))objc_msgSend)(sequence, containerSel);
            name = ((id (*)(id, SEL))objc_msgSend)(sequence, displayNameSel);
        } @catch (NSException *e) { container = nil; }
        if (container && name.length > 0 && [container respondsToSelector:namedSel]) {
            id child = nil;
            @try { child = ((id (*)(id, SEL, id))objc_msgSend)(container, namedSel, name); }
            @catch (NSException *e) { child = nil; }
            if (child && !(eventRecordClass && [child isKindOfClass:eventRecordClass])) return child;
        }

        // -childItemNamed: answers nil for a project with no content in it — an empty
        // scratch project left from an earlier session reports -sequenceType "clip",
        // -isProject NO and -targetSequenceRecord nil, so every route above comes up empty
        // and cleanup could find it by name but never remove it. The event's own child
        // records do contain it, so the last resort is to walk them and match the name.
        if (container && name.length > 0) {
            for (NSString *listSel in @[@"childItems", @"sequenceRecords"]) {
                SEL sel = NSSelectorFromString(listSel);
                if (![container respondsToSelector:sel]) continue;
                id kids = nil;
                @try { kids = ((id (*)(id, SEL))objc_msgSend)(container, sel); }
                @catch (NSException *e) { kids = nil; }
                if (!kids) continue;
                // -childItems answers an NSSet on this build and an NSArray on others.
                if ([kids respondsToSelector:@selector(allObjects)]) {
                    @try { kids = ((id (*)(id, SEL))objc_msgSend)(kids, @selector(allObjects)); }
                    @catch (NSException *e) { continue; }
                }
                if (![kids isKindOfClass:[NSArray class]]) continue;
                for (id kid in (NSArray *)kids) {
                    if (eventRecordClass && [kid isKindOfClass:eventRecordClass]) continue;
                    if (![kid respondsToSelector:displayNameSel]) continue;
                    NSString *kidName = nil;
                    @try { kidName = ((id (*)(id, SEL))objc_msgSend)(kid, displayNameSel); }
                    @catch (NSException *e) { kidName = nil; }
                    if ([kidName isKindOfClass:[NSString class]] && [kidName isEqualToString:name]) {
                        return kid;
                    }
                }
            }
        }
    }
    return nil;
}

static id SpliceKit_libraryForSequence(id sequence, id libraryItem) {
    SEL librarySel = NSSelectorFromString(@"library");
    if (sequence && [sequence respondsToSelector:librarySel]) {
        id library = ((id (*)(id, SEL))objc_msgSend)(sequence, librarySel);
        if (library) return library;
    }
    if (libraryItem && [libraryItem respondsToSelector:librarySel]) {
        id library = ((id (*)(id, SEL))objc_msgSend)(libraryItem, librarySel);
        if (library) return library;
    }
    return nil;
}

// Move one library item (a project record, or an event record we created ourselves) to
// the library trash. FCP 12.3's FFLibrary answers all three of these; they are tried in
// order because the action variant is the one that shows up in Edit > Undo.
// `undoable` NO tries the action variant last: a pipeline that removes its own scratch
// project straight after pasting from it (native captions, paste_fcpxml, structure
// blocks) must leave its paste as the top undo step. With the undoable trash on top,
// Edit > Undo first brought the scratch project back ("Undo SpliceKit Cleanup") and the
// pasted captions stayed on the timeline.
static BOOL SpliceKit_trashLibraryItemWithUndo(id library, id libraryItem, NSString *label, BOOL undoable);

static BOOL SpliceKit_trashLibraryItem(id library, id libraryItem, NSString *label) {
    return SpliceKit_trashLibraryItemWithUndo(library, libraryItem, label, YES);
}

static BOOL SpliceKit_trashLibraryItemQuietly(id library, id libraryItem, NSString *label) {
    if (!library || !libraryItem) return NO;
    SEL trashSel = NSSelectorFromString(@"trashLibraryItem:immediately:error:");
    if ([library respondsToSelector:trashSel]) {
        NSError *error = nil;
        BOOL ok = NO;
        @try {
            ok = ((BOOL (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(
                library, trashSel, libraryItem, NO, &error);
        } @catch (NSException *e) {
            SpliceKit_log(@"[SpliceKit] trashLibraryItem raised for '%@': %@", label ?: @"?", e.reason);
            ok = NO;
        }
        if (ok) return YES;
    }
    return SpliceKit_trashLibraryItemWithUndo(library, libraryItem, label, YES);
}

static BOOL SpliceKit_trashLibraryItemWithUndo(id library, id libraryItem, NSString *label, BOOL undoable) {
    if (!library || !libraryItem) return NO;
    if (!undoable) return SpliceKit_trashLibraryItemQuietly(library, libraryItem, label);

    // Each of the three is wrapped on its own. They are dynamic calls into Flexo, and a
    // raise from one used to unwind past the caller's loop over looseProjects/eventsToRemove,
    // so one awkward item silently stopped the rest of the sweep from being processed at all.
    // A throw here is now just "that API did not work", and the next one is tried.
    NSError *error = nil;
    SEL trashActionSel = NSSelectorFromString(@"actionMoveLibraryItemToTrash:actionName:error:");
    if ([library respondsToSelector:trashActionSel]) {
        BOOL ok = NO;
        @try {
            ok = ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                library, trashActionSel, libraryItem, @"SpliceKit Cleanup", &error);
        } @catch (NSException *e) {
            SpliceKit_log(@"[SpliceKit] actionMoveLibraryItemToTrash raised for '%@': %@",
                          label ?: @"?", e.reason);
            ok = NO;
        }
        if (ok) return YES;
        if (error) {
            SpliceKit_log(@"[SpliceKit] actionMoveLibraryItemToTrash failed for '%@': %@",
                          label ?: @"?", error.localizedDescription);
            error = nil;
        }
    }

    SEL trashSel = NSSelectorFromString(@"trashLibraryItem:immediately:error:");
    if ([library respondsToSelector:trashSel]) {
        BOOL ok = NO;
        @try {
            ok = ((BOOL (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(
                library, trashSel, libraryItem, NO, &error);
        } @catch (NSException *e) {
            SpliceKit_log(@"[SpliceKit] trashLibraryItem raised for '%@': %@",
                          label ?: @"?", e.reason);
            ok = NO;
        }
        if (ok) return YES;
        if (error) {
            SpliceKit_log(@"[SpliceKit] trashLibraryItem failed for '%@': %@",
                          label ?: @"?", error.localizedDescription);
            error = nil;
        }
    }

    SEL removeSel = NSSelectorFromString(@"removeLibraryItem:error:");
    if ([library respondsToSelector:removeSel]) {
        BOOL ok = NO;
        @try {
            ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(
                library, removeSel, libraryItem, &error);
        } @catch (NSException *e) {
            SpliceKit_log(@"[SpliceKit] removeLibraryItem raised for '%@': %@",
                          label ?: @"?", e.reason);
            ok = NO;
        }
        if (ok) return YES;
        if (error) {
            SpliceKit_log(@"[SpliceKit] removeLibraryItem failed for '%@': %@",
                          label ?: @"?", error.localizedDescription);
        }
    }

    SpliceKit_log(@"[SpliceKit] Warning: could not trash '%@': library trash APIs failed",
                  label ?: @"?");
    return NO;
}

// Trash a scratch project a pipeline has just pasted from, without an undo step of its
// own (see SpliceKit_trashLibraryItemWithUndo). cleanup_temp_projects, which is an edit a
// person asked for, uses the undoable path instead.
static BOOL SpliceKit_deleteSequenceLibraryItemWithUndo(id sequence, BOOL undoable);

BOOL SpliceKit_deleteSequenceLibraryItem(id sequence) {
    return SpliceKit_deleteSequenceLibraryItemWithUndo(sequence, NO);
}

static BOOL SpliceKit_deleteSequenceLibraryItemWithUndo(id sequence, BOOL undoable) {
    if (!sequence) return NO;

    NSString *projectName = nil;
    SEL displayNameSel = NSSelectorFromString(@"displayName");
    if ([sequence respondsToSelector:displayNameSel]) {
        projectName = ((id (*)(id, SEL))objc_msgSend)(sequence, displayNameSel);
    }

    id libraryItem = SpliceKit_libraryItemForSequence(sequence);
    if (!libraryItem) {
        SpliceKit_log(@"[SpliceKit] Warning: could not delete temp project '%@': sequence has no library item",
                      projectName ?: @"?");
        return NO;
    }

    id library = SpliceKit_libraryForSequence(sequence, libraryItem);
    if (!library) {
        SpliceKit_log(@"[SpliceKit] Warning: could not delete temp project '%@': no library",
                      projectName ?: @"?");
        return NO;
    }

    return SpliceKit_trashLibraryItemWithUndo(library, libraryItem, projectName, undoable);
}

// Clean up stale scratch import projects (caption + song-structure FCPXML temps) and the
// events SpliceKit's own FCPXML created to hold them.
NSDictionary *SpliceKit_handleCaptionsCleanup(NSDictionary *params) {
    BOOL dryRun = [params[@"dryRun"] boolValue];
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id activeLibs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
            if (!activeLibs || [(NSArray *)activeLibs count] == 0) {
                result = @{@"error": @"No active library"};
                return;
            }
            id library = [(NSArray *)activeLibs objectAtIndex:0];

            // Walk the library's events, not -_deepLoadedSequences.
            //
            // _deepLoadedSequences only answers the sequences Final Cut Pro currently has
            // loaded in memory. A scratch project that was imported, copied from and
            // switched away from is not loaded, so it was invisible here: three _SKPaste_*
            // projects sat in the QA library while this handler reported "No scratch import
            // projects found" and browser.listClips listed all three. This is the same walk
            // browser.listClips makes, so anything the browser shows, cleanup can see.
            SEL eventsSel = NSSelectorFromString(@"events");
            NSArray *events = nil;
            if ([library respondsToSelector:eventsSel]) {
                events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
            }
            if (![events isKindOfClass:[NSArray class]]) {
                result = @{
                    @"status": @"ok",
                    @"dryRun": @(dryRun),
                    @"found": @(0),
                    @"removed": @(0),
                    @"foundNames": @[],
                    @"removedNames": @[],
                    @"failedNames": @[],
                    @"foundEventNames": @[],
                    @"removedEventNames": @[],
                    @"message": @"No events found"
                };
                return;
            }

            SEL dnSel = NSSelectorFromString(@"displayName");
            NSMutableArray *foundNames = [NSMutableArray array];   // scratch projects
            NSMutableArray *looseProjects = [NSMutableArray array]; // ones not in a scratch event
            NSMutableArray *foundEvents = [NSMutableArray array];
            NSMutableArray *eventsToRemove = [NSMutableArray array];
            NSMutableArray *eventProjectNames = [NSMutableArray array]; // parallel to eventsToRemove

            for (id event in events) {
                NSString *eventName = nil;
                if ([event respondsToSelector:dnSel]) {
                    eventName = ((id (*)(id, SEL))objc_msgSend)(event, dnSel);
                }
                NSArray *items = SpliceKit_browserClipsOfEvent(event);

                NSMutableArray *scratchHere = [NSMutableArray array];
                BOOL everythingIsScratch = YES;
                for (id item in items) {
                    // Matched on name alone, deliberately. -isProject only answers YES once
                    // Final Cut Pro has actually loaded the sequence, so right after launch
                    // every project except the open one reads NO and gating on it made this
                    // handler report "No scratch import projects found" with three scratch
                    // projects sitting in the browser. The names below are ones SpliceKit
                    // itself generates, so the name is the reliable signal.
                    NSString *name = nil;
                    if ([item respondsToSelector:dnSel]) {
                        name = ((id (*)(id, SEL))objc_msgSend)(item, dnSel);
                    }
                    if (SpliceKit_isScratchImportProjectName(name)) {
                        [scratchHere addObject:@[name ?: @"?", item]];
                    } else {
                        everythingIsScratch = NO;
                    }
                }

                // An event SpliceKit's own FCPXML declared, holding nothing but SpliceKit
                // scratch, goes as a unit. That is both tidier and the only way to clear a
                // scratch project Final Cut Pro has not loaded: an unloaded sequence has no
                // reachable FFSequenceRecord to trash, but its event always does.
                // scratchHere.count > 0 matters: everythingIsScratch starts YES and is only
                // ever cleared inside the loop above, so an EMPTY event whose name happened to
                // match sailed through and was trashed without one byte of SpliceKit scratch
                // in it. An event only goes if it actually holds our scratch and nothing else.
                BOOL eventIsOurs = SpliceKit_isScratchImportEventName(eventName)
                    && everythingIsScratch
                    && scratchHere.count > 0;
                NSMutableArray *namesHere = [NSMutableArray array];
                for (NSArray *pair in scratchHere) {
                    [foundNames addObject:pair[0]];
                    [namesHere addObject:pair[0]];
                    if (!eventIsOurs) [looseProjects addObject:pair];
                }
                if (eventIsOurs) {
                    [foundEvents addObject:eventName ?: @"?"];
                    [eventsToRemove addObject:event];
                    [eventProjectNames addObject:namesHere];
                }
            }

            NSMutableArray *removedNames = [NSMutableArray array];
            NSMutableArray *removedEvents = [NSMutableArray array];
            NSMutableArray *failedNames = [NSMutableArray array];
            if (!dryRun) {
                for (NSArray *pair in looseProjects) {
                    if (SpliceKit_deleteSequenceLibraryItemWithUndo(pair[1], YES)) {
                        [removedNames addObject:pair[0]];
                    } else {
                        [failedNames addObject:pair[0]];
                    }
                }
                for (NSUInteger i = 0; i < eventsToRemove.count; i++) {
                    NSString *eventName = foundEvents[i];
                    if (SpliceKit_trashLibraryItem(library, eventsToRemove[i], eventName)) {
                        [removedEvents addObject:eventName];
                        // The projects inside went with it.
                        [removedNames addObjectsFromArray:eventProjectNames[i]];
                    } else {
                        [failedNames addObject:eventName];
                        [failedNames addObjectsFromArray:eventProjectNames[i]];
                    }
                }
            }

            NSString *message = nil;
            if (dryRun) {
                message = (foundNames.count + foundEvents.count) > 0
                    ? [NSString stringWithFormat:
                        @"Would remove %lu scratch import project(s) and %lu scratch event(s)",
                        (unsigned long)foundNames.count, (unsigned long)foundEvents.count]
                    : @"No scratch import projects found";
            } else if ((removedNames.count + removedEvents.count) > 0) {
                message = [NSString stringWithFormat:
                    @"Removed %lu scratch import project(s) and %lu scratch event(s). "
                    @"They are in the library trash until File > Delete Generated Library Files "
                    @"or emptying the trash clears them.",
                    (unsigned long)removedNames.count, (unsigned long)removedEvents.count];
            } else if (foundNames.count + foundEvents.count > 0) {
                message = @"Found scratch import projects but could not remove any (see failedNames)";
            } else {
                message = @"No scratch import projects found";
            }

            result = @{
                @"status": failedNames.count > 0 ? @"partial" : @"ok",
                @"dryRun": @(dryRun),
                @"found": @(foundNames.count),
                @"removed": @(removedNames.count),
                @"foundNames": foundNames,
                @"removedNames": removedNames,
                @"failedNames": failedNames,
                @"foundEventNames": foundEvents,
                @"removedEventNames": removedEvents,
                @"message": message
            };
        } @catch (NSException *e) {
            SpliceKit_log(@"[SpliceKit] captions.cleanup exception: %@", e.reason);
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Cleanup failed"};
}

#pragma mark - Native Captions (FFAnchoredCaption)

NSDictionary *SpliceKit_handleNativeCaptionsGenerate(NSDictionary *params) {
    SpliceKitCaptionPanel *panel = [SpliceKitCaptionPanel sharedPanel];

    // Apply grouping mode if specified
    NSString *grouping = params[@"grouping"] ?: @"word";
    if ([grouping isEqualToString:@"word"]) {
        panel.groupingMode = SpliceKitCaptionGroupingByWordCount;
        panel.maxWordsPerSegment = 1;
    } else if ([grouping isEqualToString:@"phrase"] || [grouping isEqualToString:@"sentence"]) {
        panel.groupingMode = SpliceKitCaptionGroupingBySentence;
    } else if ([grouping hasPrefix:@"group:"]) {
        NSInteger n = [[grouping substringFromIndex:6] integerValue];
        panel.groupingMode = SpliceKitCaptionGroupingByWordCount;
        panel.maxWordsPerSegment = MAX(n, 1);
    } else if ([grouping hasPrefix:@"time:"]) {
        double s = [[grouping substringFromIndex:5] doubleValue];
        panel.groupingMode = SpliceKitCaptionGroupingByTime;
        panel.maxSecondsPerSegment = MAX(s, 0.1);
    } else if ([grouping isEqualToString:@"social"]) {
        panel.groupingMode = SpliceKitCaptionGroupingSocial;
    } else {
        // Default: word-by-word
        panel.groupingMode = SpliceKitCaptionGroupingByWordCount;
        panel.maxWordsPerSegment = 1;
    }

    // Also accept explicit maxWords / maxSeconds overrides
    if (params[@"maxWords"]) {
        panel.maxWordsPerSegment = MAX([params[@"maxWords"] unsignedIntegerValue], 1);
    }
    if (params[@"maxSeconds"]) {
        panel.maxSecondsPerSegment = MAX([params[@"maxSeconds"] doubleValue], 0.1);
    }

    NSString *language = params[@"language"] ?: @"en";
    NSString *format = params[@"format"] ?: @"ITT";

    return [panel generateNativeCaptions:language format:format];
}

NSDictionary *SpliceKit_handleNativeCaptionsVerify(NSDictionary *params) {
    // Use FCP's allCaptions method on the sequence to find FFAnchoredCaption objects
    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timelineModule = SpliceKit_getActiveTimelineModule();
            if (!timelineModule) {
                result = @{@"error": @"No active timeline module"};
                return;
            }
            id sequence = ((id (*)(id, SEL))objc_msgSend)(timelineModule,
                NSSelectorFromString(@"sequence"));
            if (!sequence) {
                result = @{@"error": @"No sequence in timeline"};
                return;
            }

            NSMutableArray *captionInfos = [NSMutableArray array];
            Class captionClass = NSClassFromString(@"FFAnchoredCaption");

            SEL textSel = NSSelectorFromString(@"text");
            SEL displayNameSel = NSSelectorFromString(@"displayName");

            for (id item in SpliceKit_allCaptionsOnSequence(sequence)) {
                @try {
                    BOOL isCaption = captionClass && [item isKindOfClass:captionClass];
                    if (!isCaption) continue;

                    NSString *text = [item respondsToSelector:textSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(item, textSel) : nil;
                    NSString *name = [item respondsToSelector:displayNameSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(item, displayNameSel) : nil;

                    NSMutableDictionary *info = [NSMutableDictionary dictionary];
                    if (text) info[@"text"] = text;
                    if (name) info[@"displayName"] = name;
                    info[@"class"] = NSStringFromClass([item class]);
                    [captionInfos addObject:info];
                } @catch (NSException *e) {
                    // Skip problematic items
                }
            }

            result = @{
                @"status": @"ok",
                @"captionCount": @(captionInfos.count),
                @"captions": captionInfos,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result ?: @{@"error": @"Verification failed"};
}
