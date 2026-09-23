//
//  SpliceKitLiveCam+Ingest.m
//  Bringing a finished LiveCam recording into Final Cut: timeline identity checks,
//  the import FCPXML, finding / selecting the new clip, and timeline placement.
//

#import "SpliceKitLiveCam+Private.h"

static NSString *SpliceKitLiveCamCurrentTimelineEventName(void) {
    __block NSString *eventName = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) return;

            SEL seqSel = NSSelectorFromString(@"sequence");
            id sequence = [timeline respondsToSelector:seqSel]
                ? ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel)
                : nil;
            if (!sequence) return;

            SEL eventSel = NSSelectorFromString(@"event");
            SEL containerEventSel = NSSelectorFromString(@"containerEvent");
            id event = nil;
            if ([sequence respondsToSelector:eventSel]) {
                event = ((id (*)(id, SEL))objc_msgSend)(sequence, eventSel);
            } else if ([sequence respondsToSelector:containerEventSel]) {
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
        } @catch (NSException *e) {
            SpliceKit_log(@"[LiveCamImport] Failed to resolve current event: %@", e.reason);
        }
    });
    return eventName;
}

NSDictionary *SpliceKitLiveCamCurrentTimelineIdentity(void) {
    __block NSDictionary *identity = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) return;
            id sequence = [timeline respondsToSelector:@selector(sequence)]
                ? ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence))
                : nil;
            if (sequence) {
                identity = SpliceKit_sequenceIdentity(sequence);
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[LiveCamTimeline] Failed to resolve timeline identity: %@", e.reason);
        }
    });
    return identity;
}

static BOOL SpliceKitLiveCamHasActiveTimeline(void) {
    __block BOOL hasTimeline = NO;
    SpliceKit_executeOnMainThread(^{
        @try {
            hasTimeline = (SpliceKit_getActiveTimelineModule() != nil);
        } @catch (__unused NSException *e) {
            hasTimeline = NO;
        }
    });
    return hasTimeline;
}

static BOOL SpliceKitLiveCamTimelineIdentityMatches(NSDictionary *expected,
                                                    NSDictionary *current) {
    if (!expected || !current) return NO;
    NSString *expectedKey = SpliceKitLiveCamString(expected[@"cacheKey"]);
    NSString *currentKey = SpliceKitLiveCamString(current[@"cacheKey"]);
    if (expectedKey.length > 0 && currentKey.length > 0) {
        return [expectedKey isEqualToString:currentKey];
    }
    return [[expected description] isEqualToString:[current description]];
}

static NSDictionary *SpliceKitLiveCamInspectMediaAtURL(NSURL *url) {
    if (!url.isFileURL) return @{@"error": @"LiveCam media URL must be a file URL."};
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        return @{@"error": @"LiveCam recording file does not exist on disk."};
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    CMTime duration = asset.duration;
    if (!CMTIME_IS_VALID(duration) || CMTIME_IS_INDEFINITE(duration) ||
        duration.timescale <= 0 || duration.value <= 0) {
        return @{@"error": @"LiveCam recording has no readable duration."};
    }

    AVAssetTrack *videoTrack = videoTracks.firstObject;
    AVAssetTrack *audioTrack = audioTracks.firstObject;

    int width = 1280;
    int height = 720;
    NSString *frameDuration = @"100/2400s";
    if (videoTrack) {
        CGSize size = CGSizeApplyAffineTransform(videoTrack.naturalSize, videoTrack.preferredTransform);
        width = MAX(1, (int)fabs(size.width));
        height = MAX(1, (int)fabs(size.height));
        if (videoTrack.nominalFrameRate > 0.0f) {
            frameDuration = SpliceKitLiveCamFrameDurationString(videoTrack.nominalFrameRate);
        } else if (CMTIME_IS_VALID(videoTrack.minFrameDuration) &&
                   videoTrack.minFrameDuration.value > 0 &&
                   videoTrack.minFrameDuration.timescale > 0) {
            frameDuration = [NSString stringWithFormat:@"%lld/%ds",
                             videoTrack.minFrameDuration.value,
                             videoTrack.minFrameDuration.timescale];
        }
    }

    return @{
        @"duration": [NSString stringWithFormat:@"%lld/%ds", duration.value, duration.timescale],
        @"width": @(width),
        @"height": @(height),
        @"frameDuration": frameDuration,
        @"hasVideo": @(videoTrack != nil),
        @"hasAudio": @(audioTrack != nil),
        @"audioRate": @(audioTrack ? (int)round(audioTrack.naturalTimeScale > 0 ? audioTrack.naturalTimeScale : 48000) : 0),
    };
}

static NSString *SpliceKitLiveCamImportXML(NSURL *fileURL,
                                           NSString *clipName,
                                           NSString *eventName,
                                           NSDictionary *mediaInfo) {
    NSString *uid = [[NSUUID UUID] UUIDString];
    NSString *fmtID = [NSString stringWithFormat:@"fmt_%@", [uid substringToIndex:8]];
    NSString *assetID = [NSString stringWithFormat:@"asset_%@", [uid substringToIndex:8]];
    NSString *escapedClip = SpliceKitLiveCamEscapeXML(clipName ?: @"LiveCam");
    NSString *escapedEvent = SpliceKitLiveCamEscapeXML(eventName ?: @"LiveCam");
    NSString *duration = SpliceKitLiveCamString(mediaInfo[@"duration"]);
    NSString *frameDuration = SpliceKitLiveCamString(mediaInfo[@"frameDuration"]);
    int width = [mediaInfo[@"width"] intValue] ?: 1280;
    int height = [mediaInfo[@"height"] intValue] ?: 720;
    BOOL hasVideo = [mediaInfo[@"hasVideo"] boolValue];
    BOOL hasAudio = [mediaInfo[@"hasAudio"] boolValue];
    int audioRate = [mediaInfo[@"audioRate"] intValue] ?: 48000;

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n"];
    [xml appendString:@"<fcpxml version=\"1.14\">\n"];
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"%@\" frameDuration=\"%@\" width=\"%d\" height=\"%d\" name=\"FFVideoFormat%dx%dp\"/>\n",
        fmtID, frameDuration.length > 0 ? frameDuration : @"100/2400s", width, height, width, height];
    [xml appendFormat:@"        <asset id=\"%@\" name=\"%@\" uid=\"%@\" start=\"0s\" duration=\"%@\" hasVideo=\"%@\" hasAudio=\"%@\" format=\"%@\" audioSources=\"%@\" audioChannels=\"2\" audioRate=\"%d\">\n",
        assetID,
        escapedClip,
        uid,
        duration.length > 0 ? duration : @"2400/2400s",
        hasVideo ? @"1" : @"0",
        hasAudio ? @"1" : @"0",
        fmtID,
        hasAudio ? @"1" : @"0",
        audioRate];
    [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n",
        fileURL.absoluteURL.absoluteString ?: @""];
    [xml appendString:@"        </asset>\n"];
    [xml appendString:@"    </resources>\n"];
    [xml appendFormat:@"    <event name=\"%@\">\n", escapedEvent];
    [xml appendFormat:@"        <asset-clip ref=\"%@\" name=\"%@\" duration=\"%@\" start=\"0s\"/>\n",
        assetID, escapedClip, duration.length > 0 ? duration : @"2400/2400s"];
    [xml appendString:@"    </event>\n"];
    [xml appendString:@"</fcpxml>\n"];
    return xml;
}

static id SpliceKitLiveCamFindClipNamed(NSString *clipName, NSString *eventName) {
    __block id foundClip = nil;
    NSString *needle = [[SpliceKitLiveCamTrimmedString(clipName) lowercaseString] copy];
    NSString *eventNeedle = [[SpliceKitLiveCamTrimmedString(eventName) lowercaseString] copy];

    if (needle.length == 0) return nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) return;

            id library = [(NSArray *)libs firstObject];
            SEL eventsSel = NSSelectorFromString(@"events");
            id events = [library respondsToSelector:eventsSel]
                ? ((id (*)(id, SEL))objc_msgSend)(library, eventsSel)
                : nil;
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
            SpliceKit_log(@"[LiveCamImport] Clip lookup failed: %@", e.reason);
        }
    });
    return foundClip;
}

static BOOL SpliceKitLiveCamSelectClipInBrowser(id clip) {
    __block BOOL selected = NO;
    if (!clip) return NO;

    SpliceKit_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
            if (!delegate) return;

            id browserContainer = nil;
            SEL browserSel = NSSelectorFromString(@"mediaBrowserContainerModule");
            if ([delegate respondsToSelector:browserSel]) {
                browserContainer = ((id (*)(id, SEL))objc_msgSend)(delegate, browserSel);
            }

            Class rangeObjClass = objc_getClass("FigTimeRangeAndObject");
            if (!rangeObjClass) return;

            CMTimeRange clipRange = kCMTimeRangeZero;
            SEL clippedRangeSel = NSSelectorFromString(@"clippedRange");
            SEL durationSel = NSSelectorFromString(@"duration");
            if ([clip respondsToSelector:clippedRangeSel]) {
                clipRange = ((CMTimeRange (*)(id, SEL))SPLICEKIT_LIVECAM_STRET_MSG)(clip, clippedRangeSel);
            } else if ([clip respondsToSelector:durationSel]) {
                CMTime duration = ((CMTime (*)(id, SEL))SPLICEKIT_LIVECAM_STRET_MSG)(clip, durationSel);
                clipRange = CMTimeRangeMake(kCMTimeZero, duration);
            }

            SEL rangeAndObjSel = NSSelectorFromString(@"rangeAndObjectWithRange:andObject:");
            if (![(id)rangeObjClass respondsToSelector:rangeAndObjSel]) return;
            id mediaRange = ((id (*)(id, SEL, CMTimeRange, id))objc_msgSend)(
                (id)rangeObjClass, rangeAndObjSel, clipRange, clip);
            if (!mediaRange) return;

            id filmstrip = nil;
            SEL filmstripSel = NSSelectorFromString(@"filmstripModule");
            if (browserContainer && [browserContainer respondsToSelector:filmstripSel]) {
                filmstrip = ((id (*)(id, SEL))objc_msgSend)(browserContainer, filmstripSel);
            }

            SEL setSelectionSel = NSSelectorFromString(@"setSelection:");
            if (filmstrip && [filmstrip respondsToSelector:setSelectionSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(filmstrip, setSelectionSel, @[mediaRange]);
                selected = YES;
            }

            SEL setCurrentSel = NSSelectorFromString(@"setCurrentSelection:");
            if (!selected && browserContainer && [browserContainer respondsToSelector:setCurrentSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(browserContainer, setCurrentSel, @[mediaRange]);
                selected = YES;
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[LiveCamImport] Failed to select browser clip: %@", e.reason);
        }
    });
    return selected;
}

@implementation SpliceKitLiveCamPanel (Ingest)

- (NSDictionary *)verifyConnectedPlacementForClipName:(NSString *)clipName {
    for (NSInteger lane = 1; lane <= 4; lane++) {
        NSDictionary *response = SpliceKit_handleRequest(@{
            @"method": @"timeline.selectClipInLane",
            @"params": @{@"lane": @(lane)}
        });
        NSDictionary *result = response[@"result"] ?: response;
        if (result[@"error"]) continue;
        NSString *actual = SpliceKitLiveCamString(result[@"clip"]);
        if (actual.length > 0 &&
            ([[actual lowercaseString] isEqualToString:[clipName lowercaseString]] ||
             [[actual lowercaseString] containsString:[clipName lowercaseString]])) {
            return @{
                @"verified": @YES,
                @"lane": @(lane),
                @"clip": actual,
            };
        }
    }
    return @{@"verified": @NO,
             @"error": @"Connected placement could not be verified at the playhead."};
}

- (NSDictionary *)ingestFinalizedRecordingAtURL:(NSURL *)url {
    NSDictionary *mediaInfo = SpliceKitLiveCamInspectMediaAtURL(url);
    if (mediaInfo[@"error"]) {
        return @{@"message": [NSString stringWithFormat:@"LiveCam saved the file, but inspection failed: %@",
                              mediaInfo[@"error"]]};
    }

    NSString *eventName = self.recordingEventName.length > 0
        ? self.recordingEventName
        : SpliceKitLiveCamCurrentTimelineEventName();
    if (eventName.length == 0) eventName = @"LiveCam";

    NSString *xml = SpliceKitLiveCamImportXML(url, self.recordingClipName, eventName, mediaInfo);
    SpliceKit_log(@"[LiveCamImport] importing clip=%@ event=%@ path=%@",
                  self.recordingClipName, eventName, url.path);
    NSDictionary *importResponse = SpliceKit_handleRequest(@{
        @"method": @"fcpxml.import",
        @"params": @{@"xml": xml, @"internal": @YES}
    });
    NSDictionary *importResult = importResponse[@"result"] ?: importResponse;
    if (importResult[@"error"]) {
        return @{@"message": [NSString stringWithFormat:@"LiveCam saved the clip to %@, but Final Cut import failed: %@",
                              url.path,
                              importResult[@"error"]]};
    }

    id clip = nil;
    for (NSInteger attempt = 0; attempt < 15 && !clip; attempt++) {
        clip = SpliceKitLiveCamFindClipNamed(self.recordingClipName, eventName);
        if (!clip) [NSThread sleepForTimeInterval:0.2];
    }

    if (!clip) {
        return @{@"message": [NSString stringWithFormat:@"LiveCam imported the file into %@, but could not re-find the browser clip for reveal or timeline placement.",
                              eventName]};
    }

    NSString *handle = SpliceKit_storeHandle(clip);
    if (handle.length == 0) {
        return @{@"message": [NSString stringWithFormat:@"LiveCam imported %@ into %@, but could not prepare the clip for placement.",
                              self.recordingClipName,
                              eventName]};
    }

    SpliceKitLiveCamSelectClipInBrowser(clip);

    if (self.recordingDestination == SpliceKitLiveCamDestinationLibrary) {
        return @{@"message": [NSString stringWithFormat:@"LiveCam saved %@ and imported it into the %@ event.",
                              self.recordingClipName,
                              eventName]};
    }

    NSDictionary *currentIdentity = SpliceKitLiveCamCurrentTimelineIdentity();
    if (!SpliceKitLiveCamHasActiveTimeline() ||
        !SpliceKitLiveCamTimelineIdentityMatches(self.recordingSequenceIdentity, currentIdentity)) {
        SpliceKit_log(@"[LiveCamTimeline] Timeline changed during recording. expected=%@ current=%@",
                      self.recordingSequenceIdentity, currentIdentity);
        return @{@"message": [NSString stringWithFormat:@"LiveCam imported %@ into %@, but the active timeline changed during recording so it stayed in the Library instead.",
                              self.recordingClipName,
                              eventName]};
    }

    if (self.recordingPlacement == SpliceKitLiveCamTimelinePlacementConnectedAbove) {
        NSDictionary *placementResponse = SpliceKit_handleRequest(@{
            @"method": @"browser.connectClip",
            @"params": @{@"handle": handle}
        });
        NSDictionary *placementResult = placementResponse[@"result"] ?: placementResponse;
        if (placementResult[@"error"]) {
            SpliceKit_log(@"[LiveCamTimeline] explicit connect failed: %@", placementResult[@"error"]);
            return @{@"message": [NSString stringWithFormat:@"LiveCam imported %@ into %@, but connected timeline insertion failed: %@",
                                  self.recordingClipName,
                                  eventName,
                                  placementResult[@"error"]]};
        }

        NSDictionary *verify = [self verifyConnectedPlacementForClipName:self.recordingClipName];
        if ([verify[@"verified"] boolValue]) {
            NSInteger lane = [verify[@"lane"] integerValue];
            SpliceKit_log(@"[LiveCamVerify] connected placement verified clip=%@ lane=%ld",
                          self.recordingClipName,
                          (long)lane);
            return @{@"message": [NSString stringWithFormat:@"LiveCam imported %@ into %@ and connected it above the storyline at the playhead (lane %ld).",
                                  self.recordingClipName,
                                  eventName,
                                  (long)lane]};
        }

        SpliceKit_log(@"[LiveCamVerify] connect placement unverified: %@", verify[@"error"]);
        return @{@"message": [NSString stringWithFormat:@"LiveCam imported %@ into %@, but connected placement could not be verified so the clip was left in the Library.",
                              self.recordingClipName,
                              eventName]};
    }

    NSString *method = self.recordingPlacement == SpliceKitLiveCamTimelinePlacementInsertAtPlayhead
        ? @"browser.insertClip"
        : @"browser.appendClip";
    NSDictionary *placementResponse = SpliceKit_handleRequest(@{
        @"method": method,
        @"params": @{@"handle": handle}
    });
    NSDictionary *placementResult = placementResponse[@"result"] ?: placementResponse;
    if (placementResult[@"error"]) {
        SpliceKit_log(@"[LiveCamTimeline] placement failed method=%@ error=%@", method, placementResult[@"error"]);
        return @{@"message": [NSString stringWithFormat:@"LiveCam imported %@ into %@, but %@ failed so the clip stayed in the Library.",
                              self.recordingClipName,
                              eventName,
                              self.recordingPlacement == SpliceKitLiveCamTimelinePlacementInsertAtPlayhead ? @"playhead insertion" : @"append placement"]};
    }

    SpliceKit_log(@"[LiveCamTimeline] placement verified=%@ debug=%@",
                  placementResult[@"placementVerified"],
                  placementResult[@"placementDebug"]);

    NSString *placementText = self.recordingPlacement == SpliceKitLiveCamTimelinePlacementInsertAtPlayhead
        ? @"inserted it at the playhead"
        : @"appended it to the end of the active timeline";
    return @{@"message": [NSString stringWithFormat:@"LiveCam imported %@ into %@ and %@.",
                          self.recordingClipName,
                          eventName,
                          placementText]};
}

@end
