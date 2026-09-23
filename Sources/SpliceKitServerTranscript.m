//
//  SpliceKitServerTranscript.m
//  SpliceKit - transcript.* handlers for the transcript panel.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Transcript Handlers
//
// These proxy calls to SpliceKitTranscriptPanel for text-based editing.
// The transcript panel does the heavy lifting — transcribing audio, managing
// word/silence data, and performing timeline edits when words are deleted/moved.
// Most handlers just forward parameters and return the panel's result.
//

// A file argument as a plain path, "~/..." or a file:// URL, as a filesystem path.
// [NSURL fileURLWithPath:] on "file:///Users/a%20b/x.wav" made it relative to
// FCP's working directory ("/file:/Users/a%20b/x.wav") with the %20s intact.
NSString *SpliceKit_filesystemPathFromParam(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *raw = [(NSString *)value stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 0) return nil;
    if ([raw.lowercaseString hasPrefix:@"file:"]) {
        NSURL *url = [NSURL URLWithString:raw];
        if (url.isFileURL && url.path.length > 0) return url.path;  // .path percent-decodes
        NSString *rest = [raw substringFromIndex:5];
        while ([rest hasPrefix:@"//"]) rest = [rest substringFromIndex:1];
        return [rest stringByRemovingPercentEncoding] ?: rest;
    }
    return [raw stringByExpandingTildeInPath];
}

NSDictionary *SpliceKit_handleTranscriptOpen(NSDictionary *params) {
    NSString *fileURL = nil;
    if (params[@"fileURL"] && ![params[@"fileURL"] isKindOfClass:[NSNull class]] &&
        [[params[@"fileURL"] description] length] > 0) {
        fileURL = SpliceKit_filesystemPathFromParam(params[@"fileURL"]);
        BOOL isDir = NO;
        if (!fileURL || ![[NSFileManager defaultManager] fileExistsAtPath:fileURL isDirectory:&isDir]) {
            return @{@"error": [NSString stringWithFormat:
                @"File not found: %@ (from fileURL %@). Pass a plain path or a file:// URL.",
                fileURL ?: @"(unparseable)", params[@"fileURL"]]};
        }
        if (isDir) {
            return @{@"error": [NSString stringWithFormat:@"%@ is a folder, not a media file.", fileURL]};
        }
    }
    __block BOOL forceRetranscribe = [params[@"forceRetranscribe"] boolValue];
    id primaryOnlyParam = params[@"primaryStorylineOnly"];
    __block BOOL startedTranscription = NO;
    __block BOOL restoredTranscript = NO;
    __block BOOL alreadyTranscribing = NO;

    SpliceKit_executeOnMainThread(^{
        SpliceKitTranscriptPanel *panel = [SpliceKitTranscriptPanel sharedPanel];
        if ([primaryOnlyParam respondsToSelector:@selector(boolValue)]) {
            BOOL primaryOnly = [primaryOnlyParam boolValue];
            // A different clip set is a different transcript: do not hand back
            // the one made with the other setting.
            if (primaryOnly != panel.primaryStorylineOnly) forceRetranscribe = YES;
            panel.primaryStorylineOnly = primaryOnly;
        }
        // Coming back from a file transcript to the timeline: forget the file's
        // words so the timeline's own transcript is restored (or made).
        if (!fileURL && panel.sourceFilePath.length > 0 &&
            panel.status != SpliceKitTranscriptStatusTranscribing) {
            [panel leaveFileMode];
        }
        [panel showPanel];

        if (fileURL) {
            NSURL *url = [NSURL fileURLWithPath:fileURL];
            double timelineStart = [params[@"timelineStart"] doubleValue];
            double trimStart = [params[@"trimStart"] doubleValue];
            double trimDuration = [params[@"trimDuration"] doubleValue] ?: HUGE_VAL;
            [panel transcribeFromURL:url timelineStart:timelineStart trimStart:trimStart trimDuration:trimDuration];
            startedTranscription = YES;
        } else if (!forceRetranscribe && panel.status == SpliceKitTranscriptStatusReady && panel.words.count > 0) {
            restoredTranscript = YES;
        } else if (!forceRetranscribe && panel.status == SpliceKitTranscriptStatusTranscribing) {
            alreadyTranscribing = YES;
        } else {
            [panel transcribeTimeline];
            startedTranscription = YES;
        }
    });

    if (startedTranscription) {
        return @{
            @"status": @"ok",
            @"message": @"Transcript panel opened. Transcription started. Use transcript.getState to check progress.",
            @"transcriptionStarted": @YES,
        };
    }
    if (alreadyTranscribing) {
        return @{
            @"status": @"ok",
            @"message": @"Transcript panel opened. Transcription already in progress. Use transcript.getState to check progress.",
            @"transcriptionStarted": @NO,
        };
    }
    return @{
        @"status": @"ok",
        @"message": restoredTranscript ? @"Transcript panel opened. Restored persisted transcript." : @"Transcript panel opened.",
        @"transcriptionStarted": @NO,
    };
}

NSDictionary *SpliceKit_handleTranscriptClose(NSDictionary *params) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[SpliceKitTranscriptPanel sharedPanel] hidePanel];
    });
    return @{@"status": @"ok"};
}

NSDictionary *SpliceKit_handleTranscriptGetState(NSDictionary *params) {
    // Check for project switch before returning state — ensures stale transcript
    // from a previous project is cleared/replaced with the current project's data.
    SpliceKitTranscriptPanel *panel = [SpliceKitTranscriptPanel sharedPanel];
    if (panel.status != SpliceKitTranscriptStatusTranscribing) {
        SpliceKit_executeOnMainThread(^{
            [panel ensurePersistedStateLoaded];
        });
    }
    return [panel getStateWithOptions:params] ?: @{@"status": @"idle"};
}

NSDictionary *SpliceKit_handleTranscriptDeleteWords(NSDictionary *params) {
    NSUInteger startIndex = [params[@"startIndex"] unsignedIntegerValue];
    NSUInteger count = [params[@"count"] unsignedIntegerValue];
    if (count == 0) return @{@"error": @"count must be > 0"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        id timeline = nil;
        id sequence = nil;
        NSString *undoGroupName = @"Delete Words";
        BOOL openedUndoGroup = NO;
        @try {
            timeline = SpliceKit_getActiveTimelineModule();
            if (timeline) {
                sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
                openedUndoGroup = SpliceKit_internalBeginEditGroupIfNeeded(sequence, undoGroupName);
            }
            @try {
                result = [[SpliceKitTranscriptPanel sharedPanel] deleteWordsFromIndex:startIndex count:count];
            } @finally {
                if (openedUndoGroup) {
                    SpliceKit_internalEndEditGroupIfOpened(sequence, timeline, undoGroupName, YES);
                }
            }
            if (result && !result[@"error"] && openedUndoGroup) {
                NSMutableDictionary *out = [result mutableCopy];
                out[@"undoStep"] = undoGroupName;
                result = out;
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Operation failed"};
}

NSDictionary *SpliceKit_handleTranscriptMoveWords(NSDictionary *params) {
    NSUInteger startIndex = [params[@"startIndex"] unsignedIntegerValue];
    NSUInteger count = [params[@"count"] unsignedIntegerValue];
    NSUInteger destIndex = [params[@"destIndex"] unsignedIntegerValue];
    if (count == 0) return @{@"error": @"count must be > 0"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        id timeline = nil;
        id sequence = nil;
        NSString *undoGroupName = @"Move Words";
        BOOL openedUndoGroup = NO;
        @try {
            timeline = SpliceKit_getActiveTimelineModule();
            if (timeline) {
                sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
                openedUndoGroup = SpliceKit_internalBeginEditGroupIfNeeded(sequence, undoGroupName);
            }
            @try {
                result = [[SpliceKitTranscriptPanel sharedPanel] moveWordsFromIndex:startIndex count:count toIndex:destIndex];
            } @finally {
                if (openedUndoGroup) {
                    SpliceKit_internalEndEditGroupIfOpened(sequence, timeline, undoGroupName, YES);
                }
            }
            if (result && !result[@"error"] && openedUndoGroup) {
                NSMutableDictionary *out = [result mutableCopy];
                out[@"undoStep"] = undoGroupName;
                result = out;
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Operation failed"};
}

NSDictionary *SpliceKit_handleTranscriptSearch(NSDictionary *params) {
    NSString *query = params[@"query"];
    if (!query || query.length == 0) return @{@"error": @"query is required"};

    return [[SpliceKitTranscriptPanel sharedPanel] searchTranscript:query] ?: @{@"error": @"Search failed"};
}

NSDictionary *SpliceKit_handleTranscriptDeleteSilences(NSDictionary *params) {
    double minDuration = [params[@"minDuration"] doubleValue]; // 0 = delete all

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        id timeline = nil;
        id sequence = nil;
        NSString *undoGroupName = @"Delete Silences";
        BOOL openedUndoGroup = NO;
        @try {
            timeline = SpliceKit_getActiveTimelineModule();
            if (timeline) {
                sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
                openedUndoGroup = SpliceKit_internalBeginEditGroupIfNeeded(sequence, undoGroupName);
            }
            @try {
                result = [[SpliceKitTranscriptPanel sharedPanel] deleteSilencesLongerThan:minDuration];
            } @finally {
                if (openedUndoGroup) {
                    SpliceKit_internalEndEditGroupIfOpened(sequence, timeline, undoGroupName, YES);
                }
            }
            if (result && openedUndoGroup) {
                NSMutableDictionary *out = [result mutableCopy];
                out[@"undoStep"] = undoGroupName;
                result = out;
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Operation failed"};
}

NSDictionary *SpliceKit_handleTranscriptSetSilenceThreshold(NSDictionary *params) {
    double threshold = [params[@"threshold"] doubleValue];
    if (threshold <= 0) return @{@"error": @"threshold must be > 0"};

    SpliceKitTranscriptPanel *panel = [SpliceKitTranscriptPanel sharedPanel];
    panel.silenceThreshold = threshold;
    [panel redetectSilencesAndRefreshUI];

    return @{@"status": @"ok", @"silenceThreshold": @(threshold), @"silenceCount": @(panel.silences.count)};
}

NSDictionary *SpliceKit_handleTranscriptSetEngine(NSDictionary *params) {
    NSString *engineName = params[@"engine"];
    // The Whisper engines belong to the caption panel (captions.*), not this one; the
    // old messages offered them here and then rejected them.
    if (!engineName) return @{@"error": @"engine is required ('parakeet' = 'parakeetV3', 'parakeetV2', 'fcpNative', 'appleSpeech')"};

    SpliceKitTranscriptPanel *panel = [SpliceKitTranscriptPanel sharedPanel];
    if ([engineName isEqualToString:@"fcpNative"]) {
        panel.engine = SpliceKitTranscriptEngineFCPNative;
    } else if ([engineName isEqualToString:@"appleSpeech"]) {
        panel.engine = SpliceKitTranscriptEngineAppleSpeech;
    } else if ([engineName isEqualToString:@"parakeetV3"] || [engineName isEqualToString:@"parakeet"]) {
        panel.engine = SpliceKitTranscriptEngineParakeet;
        panel.parakeetModelVersion = @"v3";
    } else if ([engineName isEqualToString:@"parakeetV2"]) {
        panel.engine = SpliceKitTranscriptEngineParakeet;
        panel.parakeetModelVersion = @"v2";
    } else {
        return @{@"error": @"Unknown engine. Use 'parakeet' (= 'parakeetV3'), 'parakeetV2', 'fcpNative' or 'appleSpeech'"};
    }
    NSMutableDictionary *answer = [@{@"status": @"ok", @"engine": engineName} mutableCopy];
    if (panel.engine == SpliceKitTranscriptEngineParakeet) answer[@"parakeetModel"] = panel.parakeetModelVersion ?: @"v3";
    return answer;
}

NSDictionary *SpliceKit_handleTranscriptSetSpeaker(NSDictionary *params) {
    NSString *speaker = params[@"speaker"];
    NSUInteger startIndex = [params[@"startIndex"] unsignedIntegerValue];
    NSUInteger count = [params[@"count"] unsignedIntegerValue];
    if (!speaker || speaker.length == 0) return @{@"error": @"speaker name is required"};
    if (count == 0) return @{@"error": @"count must be > 0"};

    [[SpliceKitTranscriptPanel sharedPanel] setSpeaker:speaker forWordsFrom:startIndex count:count];
    return @{@"status": @"ok", @"speaker": speaker, @"startIndex": @(startIndex), @"count": @(count)};
}
