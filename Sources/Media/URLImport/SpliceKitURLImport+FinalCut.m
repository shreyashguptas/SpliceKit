//
//  SpliceKitURLImport+FinalCut.m
//  Bringing a downloaded file into Final Cut: the import FCPXML, finding the new
//  clip in its event, and inserting it into the open timeline.
//

#import "SpliceKitURLImport+Private.h"

@implementation SpliceKitURLImportService (FinalCut)

- (NSString *)currentTimelineEventName {
    __block NSString *eventName = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) return;
            SEL seqSel = NSSelectorFromString(@"sequence");
            id sequence = (timeline && [timeline respondsToSelector:seqSel])
                ? ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel) : nil;

            SEL eventSel = NSSelectorFromString(@"event");
            SEL containerEventSel = NSSelectorFromString(@"containerEvent");
            id event = nil;
            if (sequence && [sequence respondsToSelector:eventSel]) {
                event = ((id (*)(id, SEL))objc_msgSend)(sequence, eventSel);
            } else if (sequence && [sequence respondsToSelector:containerEventSel]) {
                event = ((id (*)(id, SEL))objc_msgSend)(sequence, containerEventSel);
            }
            if (!event) {
                @try { event = [sequence valueForKey:@"event"]; } @catch (__unused NSException *e) {}
            }
            if (!event) {
                @try { event = [sequence valueForKey:@"containerEvent"]; } @catch (__unused NSException *e) {}
            }
            if (event && [event respondsToSelector:@selector(displayName)]) {
                eventName = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName));
            }
            SpliceKit_log(@"[URLImport] currentTimelineEventName resolved to '%@'", eventName ?: @"");
        } @catch (NSException *e) {
            SpliceKit_log(@"[URLImport] Failed to read current event: %@", e.reason);
        }
    });
    return eventName;
}

- (BOOL)hasActiveTimeline {
    __block BOOL hasTimeline = NO;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            hasTimeline = (timeline != nil);
        } @catch (NSException *e) {
            SpliceKit_log(@"[URLImport] Failed to detect active timeline: %@", e.reason);
        }
    });
    return hasTimeline;
}

- (NSString *)importXMLForJob:(SpliceKitURLImportJob *)job
                     mediaInfo:(NSDictionary *)mediaInfo
                     eventName:(NSString *)eventName {
    NSString *uid = [[NSUUID UUID] UUIDString];
    NSString *fmtID = [NSString stringWithFormat:@"fmt_%@", [uid substringToIndex:8]];
    NSString *assetID = [NSString stringWithFormat:@"asset_%@", [uid substringToIndex:8]];
    NSString *clipName = SpliceKit_escapeXMLWithApostrophe(job.clipName ?: @"Imported Clip");
    NSString *escapedEvent = SpliceKit_escapeXMLWithApostrophe(eventName ?: @"URL Imports");
    NSString *mediaURL = SpliceKit_escapeXMLWithApostrophe(
        [[[NSURL fileURLWithPath:(job.normalizedPath ?: job.downloadPath)] absoluteURL] absoluteString]);
    NSString *duration = mediaInfo[@"duration"] ?: @"2400/2400s";
    NSString *frameDuration = mediaInfo[@"frameDuration"] ?: @"100/2400s";
    int width = [mediaInfo[@"width"] intValue] ?: 1920;
    int height = [mediaInfo[@"height"] intValue] ?: 1080;
    BOOL hasVideo = [mediaInfo[@"hasVideo"] boolValue];
    BOOL hasAudio = [mediaInfo[@"hasAudio"] boolValue];
    int audioRate = [mediaInfo[@"audioRate"] intValue] ?: 48000;

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n"];
    [xml appendString:@"<fcpxml version=\"1.14\">\n"];
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"%@\" frameDuration=\"%@\" width=\"%d\" height=\"%d\" name=\"FFVideoFormat%dx%dp\"/>\n",
        fmtID, frameDuration, width, height, width, height];
    [xml appendFormat:@"        <asset id=\"%@\" name=\"%@\" uid=\"%@\" start=\"0s\" duration=\"%@\" hasVideo=\"%@\" hasAudio=\"%@\" format=\"%@\" audioSources=\"%@\" audioChannels=\"2\" audioRate=\"%d\">\n",
        assetID, clipName, uid, duration, hasVideo ? @"1" : @"0", hasAudio ? @"1" : @"0",
        fmtID, hasAudio ? @"1" : @"0", audioRate];
    [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n", mediaURL];
    [xml appendString:@"        </asset>\n"];
    [xml appendString:@"    </resources>\n"];
    [xml appendFormat:@"    <event name=\"%@\">\n", escapedEvent];
    [xml appendFormat:@"        <asset-clip ref=\"%@\" name=\"%@\" duration=\"%@\" start=\"0s\"/>\n",
        assetID, clipName, duration];
    [xml appendString:@"    </event>\n"];
    [xml appendString:@"</fcpxml>\n"];
    return xml;
}

- (id)findClipNamed:(NSString *)clipName inEventNamed:(NSString *)eventName {
    __block id foundClip = nil;
    NSString *needle = [clipName lowercaseString];
    NSString *eventNeedle = [eventName lowercaseString];

    SpliceKit_executeOnMainThread(^{
        @try {
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                return;
            }

            id library = [(NSArray *)libs firstObject];
            SEL eventsSel = NSSelectorFromString(@"events");
            id events = [library respondsToSelector:eventsSel]
                ? ((id (*)(id, SEL))objc_msgSend)(library, eventsSel) : nil;
            if (![events isKindOfClass:[NSArray class]]) return;

            for (id event in (NSArray *)events) {
                NSString *candidateEvent = @"";
                if ([event respondsToSelector:@selector(displayName)]) {
                    candidateEvent = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName)) ?: @"";
                }
                if (eventNeedle.length > 0 &&
                    ![[candidateEvent lowercaseString] containsString:eventNeedle]) {
                    continue;
                }

                id clips = nil;
                SEL displayClipsSel = NSSelectorFromString(@"displayOwnedClips");
                SEL ownedClipsSel = NSSelectorFromString(@"ownedClips");
                SEL childItemsSel = NSSelectorFromString(@"childItems");
                if ([event respondsToSelector:displayClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, displayClipsSel);
                } else if ([event respondsToSelector:ownedClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, ownedClipsSel);
                } else if ([event respondsToSelector:childItemsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, childItemsSel);
                }
                if ([clips isKindOfClass:[NSSet class]]) clips = [(NSSet *)clips allObjects];
                if (![clips isKindOfClass:[NSArray class]]) continue;

                for (id clip in [(NSArray *)clips reverseObjectEnumerator]) {
                    if (![clip respondsToSelector:@selector(displayName)]) continue;
                    NSString *candidateName = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName)) ?: @"";
                    if ([[candidateName lowercaseString] isEqualToString:needle]) {
                        foundClip = clip;
                        return;
                    }
                }
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[URLImport] Clip lookup failed: %@", e.reason);
        }
    });
    return foundClip;
}

- (void)performTimelineInsertionForJob:(SpliceKitURLImportJob *)job {
    if (![self hasActiveTimeline]) {
        [self finishJob:job
                success:YES
                  state:SpliceKitURLImportStateCompleted
                message:@"Imported to event, but there is no active project to place it into."
                  error:nil];
        return;
    }

    [self updateJob:job state:SpliceKitURLImportStateInserting
            message:@"Placing imported clip into the active timeline..."
           progress:0.97];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id clip = nil;
        for (NSInteger attempt = 0; attempt < 12 && !clip; attempt++) {
            clip = [self findClipNamed:job.clipName inEventNamed:job.targetEvent];
            if (!clip) [NSThread sleepForTimeInterval:0.25];
        }

        if (!clip) {
            [self finishJob:job
                    success:YES
                      state:SpliceKitURLImportStateCompleted
                    message:@"Imported to the event, but could not find the new browser clip to place on the timeline."
                      error:nil];
            return;
        }

        NSString *clipHandle = SpliceKit_storeHandle(clip);
        if (clipHandle.length == 0) {
            [self finishJob:job
                    success:YES
                      state:SpliceKitURLImportStateCompleted
                    message:@"Imported to the event, but could not prepare the browser clip for timeline placement."
                      error:nil];
            return;
        }

        if ([job.mode isEqualToString:@"insert_at_timeline_start"]) {
            NSDictionary *seekResponse = SpliceKit_handleRequest(@{
                @"method": @"playback.seekToTime",
                @"params": @{@"seconds": @0}
            });
            NSDictionary *seekResult = seekResponse[@"result"] ?: seekResponse;
            if (seekResult[@"error"]) {
                [self finishJob:job
                        success:YES
                          state:SpliceKitURLImportStateCompleted
                        message:@"Imported to the event, but could not move the playhead to the timeline start."
                          error:seekResult[@"error"]];
                return;
            }
            [NSThread sleepForTimeInterval:0.1];
        }

        NSString *method = [job.mode isEqualToString:@"append_to_timeline"]
            ? @"browser.appendClip"
            : @"browser.insertClip";
        NSDictionary *insertResponse = SpliceKit_handleRequest(@{
            @"method": method,
            @"params": @{@"handle": clipHandle}
        });
        NSDictionary *insertResult = insertResponse[@"result"] ?: insertResponse;
        if (insertResult[@"error"]) {
            [self finishJob:job
                    success:YES
                      state:SpliceKitURLImportStateCompleted
                    message:@"Imported to the event, but timeline placement failed."
                      error:insertResult[@"error"]];
            return;
        }

        dispatch_async(self.stateQueue, ^{
            job.timelineInserted = YES;
        });
        NSString *message = nil;
        if ([job.mode isEqualToString:@"append_to_timeline"]) {
            message = @"Downloaded, imported, and appended to the active timeline.";
        } else if ([job.mode isEqualToString:@"insert_at_timeline_start"]) {
            message = @"Downloaded, imported, and inserted at the timeline start.";
        } else {
            message = @"Downloaded, imported, and inserted at the playhead.";
        }
        [self finishJob:job success:YES state:SpliceKitURLImportStateCompleted message:message error:nil];
    });
}

- (void)importJobIntoFinalCut:(SpliceKitURLImportJob *)job mediaInfo:(NSDictionary *)mediaInfo {
    [self updateJob:job state:SpliceKitURLImportStateImporting
            message:@"Importing media into Final Cut Pro..."
           progress:0.92];

    NSString *eventName = job.targetEvent.length > 0 ? job.targetEvent : [self currentTimelineEventName];
    if (eventName.length == 0) eventName = @"URL Imports";
    dispatch_async(self.stateQueue, ^{
        job.targetEvent = eventName;
    });

    NSString *xml = [self importXMLForJob:job mediaInfo:mediaInfo eventName:eventName];
    NSDictionary *response = SpliceKit_handleRequest(@{
        @"method": @"fcpxml.import",
        @"params": @{@"xml": xml, @"internal": @YES}
    });
    NSDictionary *result = response[@"result"] ?: response;
    if (result[@"error"]) {
        [self finishJob:job
                success:NO
                  state:SpliceKitURLImportStateFailed
                message:@"Final Cut import failed."
                  error:result[@"error"]];
        return;
    }

    dispatch_async(self.stateQueue, ^{
        job.imported = YES;
    });

    if ([job.mode isEqualToString:@"import_only"]) {
        [self finishJob:job
                success:YES
                  state:SpliceKitURLImportStateCompleted
                message:@"Downloaded and imported into the current event."
                  error:nil];
        return;
    }

    [self performTimelineInsertionForJob:job];
}

@end
