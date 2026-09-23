//
//  SpliceKitServerMusic.m
//  SpliceKit - Music-driven editing: the beats.detect passthrough, media URLs of clips,
//  random clip assembly to song beats (song cut), and the FlexMusic (flexmusic.*) and
//  Montage Maker (montage.*) handlers.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Beat Detection (Any Audio File)

// Beat detection using AVFoundation spectral analysis.
// Reads any audio file (MP3, WAV, M4A, etc.) and detects beats, bars, tempo.
// Beat detection cannot run inside FCP's process (AVFoundation/popen deadlock in hardened runtime).
// The MCP server runs the beat-detector tool directly as an external process.
// This RPC endpoint accepts pre-computed beat data for passthrough.

NSDictionary *SpliceKit_handleBeatsDetect(NSDictionary *params) {
    // If called with pre-computed data (from MCP), just pass it through
    if (params[@"beats"] && params[@"bars"] && params[@"bpm"]) {
        return params; // Already has beat data
    }

    return @{@"error": @"Beat detection must run via the MCP server (detect_beats tool). "
             @"FCP's hardened runtime prevents audio file access from in-process code. "
             @"Use the detect_beats() MCP tool which runs the beat-detector externally."};
}


// Helper: get the original media URL from a browser or timeline clip
// NOTE: Many FFAsset/FFMediaRep methods deadlock when called from main thread
// inside SpliceKit_executeOnMainThread. This helper runs on a background thread
// with a timeout to avoid hanging the RPC server.
static NSString *SpliceKit_getMediaURLForClip(id clip) {
    if (!clip) return nil;

    __block NSString *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            id clipForMedia = clip;
            SEL primarySel = NSSelectorFromString(@"primaryObject");
            if ([clipForMedia respondsToSelector:primarySel]) {
                id primary = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, primarySel);
                if (primary) clipForMedia = primary;
            }
            SEL containedSel = NSSelectorFromString(@"containedItems");
            if ([clip respondsToSelector:containedSel]) {
                id contained = ((id (*)(id, SEL))objc_msgSend)(clip, containedSel);
                NSArray *containedItems = SpliceKit_mixerArrayFromContainer(contained);
                for (id child in containedItems) {
                    NSString *className = NSStringFromClass([child class]);
                    if ([className containsString:@"MediaComponent"] ||
                        [className containsString:@"Asset"] ||
                        [className containsString:@"Clip"]) {
                        clipForMedia = child;
                        break;
                    }
                }
            }
            if ([clipForMedia respondsToSelector:containedSel]) {
                id contained = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, containedSel);
                NSArray *containedItems = SpliceKit_mixerArrayFromContainer(contained);
                for (id child in containedItems) {
                    NSString *className = NSStringFromClass([child class]);
                    if ([className containsString:@"MediaComponent"] ||
                        [className containsString:@"Asset"] ||
                        [className containsString:@"Clip"]) {
                        clipForMedia = child;
                        break;
                    }
                }
            }

            SEL origSel = NSSelectorFromString(@"originalMediaURL");
            if ([clipForMedia respondsToSelector:origSel]) {
                id url = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, origSel);
                if (url && [url isKindOfClass:[NSURL class]]) {
                    result = [url absoluteString];
                }
            }

            if (!result) {
                id media = nil;
                SEL mediaSel = NSSelectorFromString(@"media");
                if ([clipForMedia respondsToSelector:mediaSel]) {
                    media = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, mediaSel);
                }
                if (media && [media respondsToSelector:origSel]) {
                    id url = ((id (*)(id, SEL))objc_msgSend)(media, origSel);
                    if ([url isKindOfClass:[NSURL class]]) result = [url absoluteString];
                }
                if (!result && media) {
                    SEL repSel = NSSelectorFromString(@"originalMediaRep");
                    if ([media respondsToSelector:repSel]) {
                        id rep = ((id (*)(id, SEL))objc_msgSend)(media, repSel);
                        SEL fileURLsSel = NSSelectorFromString(@"fileURLs");
                        if (rep && [rep respondsToSelector:fileURLsSel]) {
                            NSArray *urls = ((id (*)(id, SEL))objc_msgSend)(rep, fileURLsSel);
                            if ([urls isKindOfClass:[NSArray class]] && urls.count > 0 &&
                                [urls.firstObject isKindOfClass:[NSURL class]]) {
                                result = [urls.firstObject absoluteString];
                            }
                        }
                    }
                }
                if (!result && media) {
                    SEL repSel = NSSelectorFromString(@"currentRep");
                    if ([media respondsToSelector:repSel]) {
                        id rep = ((id (*)(id, SEL))objc_msgSend)(media, repSel);
                        SEL fileURLsSel = NSSelectorFromString(@"fileURLs");
                        if (rep && [rep respondsToSelector:fileURLsSel]) {
                            NSArray *urls = ((id (*)(id, SEL))objc_msgSend)(rep, fileURLsSel);
                            if ([urls isKindOfClass:[NSArray class]] && urls.count > 0 &&
                                [urls.firstObject isKindOfClass:[NSURL class]]) {
                                result = [urls.firstObject absoluteString];
                            }
                        }
                    }
                }
            }

            if (!result) {
                SEL refSel = NSSelectorFromString(@"assetMediaReference");
                if ([clipForMedia respondsToSelector:refSel]) {
                    id ref = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, refSel);
                    SEL resolvedSel = NSSelectorFromString(@"resolvedURL");
                    if (ref && [ref respondsToSelector:resolvedSel]) {
                        id url = ((id (*)(id, SEL))objc_msgSend)(ref, resolvedSel);
                        if ([url isKindOfClass:[NSURL class]]) result = [url absoluteString];
                    }
                }
            }

            if (!result) {
                @try {
                    id url = [clipForMedia valueForKeyPath:@"media.fileURL"];
                    if ([url isKindOfClass:[NSURL class]]) result = [url absoluteString];
                } @catch (NSException *e) {}
            }
            if (!result) {
                @try {
                    id url = [clipForMedia valueForKeyPath:@"clipInPlace.asset.originalMediaURL"];
                    if ([url isKindOfClass:[NSURL class]]) result = [url absoluteString];
                } @catch (NSException *e) {}
            }
        } @catch (NSException *e) { /* ignore */ }
        dispatch_semaphore_signal(sem);
    });

    // Wait max 2 seconds — if it deadlocks, we just skip this clip's URL
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return result;
}

#pragma mark - FlexMusic & Montage Maker
//
// FlexMusic is FCP's dynamic soundtrack system — royalty-free songs that render
// to any duration with proper musical phrasing. Montage Maker uses FlexMusic
// timing data + clip analysis to auto-assemble highlight reels.
//

// ---------- FlexMusic static state ----------
static id sFMSongLibrary = nil; // FMSongLibrary singleton

static id SpliceKit_getFlexMusicLibrary(void) {
    if (sFMSongLibrary) return sFMSongLibrary;

    Class fmLib = objc_getClass("FMSongLibrary");
    if (!fmLib) return nil;

    // Use the shared singleton factory — sharedLibraryWithOptions:
    SEL sharedSel = NSSelectorFromString(@"sharedLibraryWithOptions:");
    if ([fmLib respondsToSelector:sharedSel]) {
        sFMSongLibrary = ((id (*)(id, SEL, id))objc_msgSend)((id)fmLib, sharedSel, @{});
    }

    // Fallback: alloc/initWithOptions:
    if (!sFMSongLibrary) {
        id instance = ((id (*)(id, SEL))objc_msgSend)((id)fmLib, @selector(alloc));
        if (instance) {
            SEL initSel = NSSelectorFromString(@"initWithOptions:");
            if ([instance respondsToSelector:initSel]) {
                sFMSongLibrary = ((id (*)(id, SEL, id))objc_msgSend)(instance, initSel, @{});
            } else {
                sFMSongLibrary = ((id (*)(id, SEL))objc_msgSend)(instance, @selector(init));
            }
        }
    }

    return sFMSongLibrary;
}

// Helper: look up an NSString* constant from FlexMusicKit by symbol name
static NSString *SpliceKit_flexMusicConstant(const char *symbolName) {
    void *ptr = dlsym(RTLD_DEFAULT, symbolName);
    if (!ptr) return nil;
    CFStringRef *cfPtr = (CFStringRef *)ptr;
    return (__bridge NSString *)(*cfPtr);
}

// Helper: build a CMTime from seconds at timescale 600
static SpliceKit_CMTime SpliceKit_cmtimeFromSeconds(double seconds) {
    SpliceKit_CMTime t;
    t.value = (int64_t)(seconds * 600.0);
    t.timescale = 600;
    t.flags = 1; // kCMTimeFlags_Valid
    t.epoch = 0;
    return t;
}

// Helper: convert CMTime to double seconds
double SpliceKit_cmtimeToSeconds(SpliceKit_CMTime t) {
    if (t.timescale <= 0) return 0.0;
    return (double)t.value / (double)t.timescale;
}

static NSString *SpliceKit_escapeXMLString(NSString *value) {
    NSString *escaped = value ?: @"";
    escaped = [escaped stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    return escaped;
}

static NSString *SpliceKit_fcpxmlTimeStringForFrameCount(long long frameCount,
                                                         SpliceKit_CMTime frameDuration) {
    if (frameCount <= 0) return @"0s";
    long long value = frameCount * frameDuration.value;
    return [NSString stringWithFormat:@"%lld/%ds", value, frameDuration.timescale];
}

static NSString *SpliceKit_buildRandomClipAssemblyFCPXML(NSArray<NSMutableDictionary *> *plan,
                                                         NSString *projectName,
                                                         NSString *eventName,
                                                         SpliceKit_CMTime frameDuration,
                                                         NSString *songMediaURL,
                                                         long long totalDurationFrames,
                                                         NSString **errorOut) {
    NSMutableDictionary<NSString *, NSDictionary *> *mediaResources = [NSMutableDictionary dictionary];
    NSInteger resourceIndex = 0;

    for (NSMutableDictionary *entry in plan) {
        if (![entry[@"status"] isEqualToString:@"planned"]) continue;

        NSString *mediaURL = [entry[@"mediaURL"] isKindOfClass:[NSString class]] ? entry[@"mediaURL"] : @"";
        if (mediaURL.length == 0) {
            NSString *clipHandle = [entry[@"clipHandle"] isKindOfClass:[NSString class]] ? entry[@"clipHandle"] : @"";
            id browserClip = clipHandle.length > 0 ? SpliceKit_resolveHandle(clipHandle) : nil;
            mediaURL = SpliceKit_getMediaURLForClip(browserClip) ?: @"";
            if (mediaURL.length > 0) entry[@"mediaURL"] = mediaURL;
        }
        if (mediaURL.length == 0) {
            if (errorOut) {
                *errorOut = [NSString stringWithFormat:@"Clip '%@' is missing a browser media URL, so it cannot be assembled via FCPXML",
                             entry[@"clipName"] ?: @"Clip"];
            }
            return nil;
        }
        if (!mediaResources[mediaURL]) {
            mediaResources[mediaURL] = @{
                @"id": [NSString stringWithFormat:@"r%ld", (long)++resourceIndex],
                @"url": mediaURL,
            };
        }
    }

    if (songMediaURL.length == 0 && totalDurationFrames > 0) {
        if (errorOut) *errorOut = @"The selected song does not expose a media URL, so it cannot be attached in the FCPXML build";
        return nil;
    }

    NSString *uid = [[[NSUUID UUID] UUIDString] substringToIndex:8];
    NSString *formatId = [NSString stringWithFormat:@"fmt_%@", uid];
    NSString *frameDurationString = SpliceKit_fcpxmlTimeStringForFrameCount(1, frameDuration);
    NSString *sequenceDurationString = SpliceKit_fcpxmlTimeStringForFrameCount(totalDurationFrames, frameDuration);
    NSString *escapedProject = SpliceKit_escapeXMLString(projectName ?: @"Beat Random Cut");
    NSString *escapedEvent = SpliceKit_escapeXMLString(eventName.length > 0 ? eventName : @"SpliceKit Tests");

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n\n"];
    [xml appendString:@"<fcpxml version=\"1.14\">\n"];
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"%@\" name=\"FFVideoFormatCustom\" frameDuration=\"%@\" width=\"1920\" height=\"1080\"/>\n",
                      formatId, frameDurationString];

    for (NSString *urlKey in mediaResources) {
        NSDictionary *res = mediaResources[urlKey];
        [xml appendFormat:@"        <asset id=\"%@\" name=\"%@\" hasVideo=\"1\" format=\"%@\" hasAudio=\"1\" videoSources=\"1\" audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\">\n",
                          res[@"id"], res[@"id"], formatId];
        [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n",
                          SpliceKit_escapeXMLString(res[@"url"])];
        [xml appendString:@"        </asset>\n"];
    }

    if (songMediaURL.length > 0) {
        [xml appendString:@"        <asset id=\"song_audio\" name=\"Music\" hasAudio=\"1\" audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\">\n"];
        [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n",
                          SpliceKit_escapeXMLString(songMediaURL)];
        [xml appendString:@"        </asset>\n"];
    }

    [xml appendString:@"    </resources>\n"];
    [xml appendString:@"    <library>\n"];
    [xml appendFormat:@"        <event name=\"%@\">\n", escapedEvent];
    [xml appendFormat:@"            <project name=\"%@\">\n", escapedProject];
    [xml appendFormat:@"                <sequence format=\"%@\" duration=\"%@\" tcStart=\"0s\" tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\">\n",
                      formatId, sequenceDurationString];
    [xml appendString:@"                    <spine>\n"];

    BOOL attachedSong = NO;
    for (NSMutableDictionary *entry in plan) {
        long long offsetFrames = [entry[@"timelineOffsetFrames"] longLongValue];
        long long durationFrames = [entry[@"durationFrames"] longLongValue];
        NSString *offsetString = SpliceKit_fcpxmlTimeStringForFrameCount(offsetFrames, frameDuration);
        NSString *durationString = SpliceKit_fcpxmlTimeStringForFrameCount(durationFrames, frameDuration);
        NSString *clipName = SpliceKit_escapeXMLString(entry[@"clipName"] ?: @"Clip");
        BOOL addSongChild = (!attachedSong && songMediaURL.length > 0);

        if ([entry[@"status"] isEqualToString:@"gap"]) {
            if (addSongChild) {
                [xml appendFormat:@"                        <gap name=\"%@\" offset=\"%@\" duration=\"%@\">\n",
                                  clipName, offsetString, durationString];
                [xml appendFormat:@"                            <asset-clip ref=\"song_audio\" lane=\"-1\" name=\"Music\" offset=\"0s\" duration=\"%@\" start=\"0s\"/>\n",
                                  sequenceDurationString];
                [xml appendString:@"                        </gap>\n"];
                attachedSong = YES;
            } else {
                [xml appendFormat:@"                        <gap name=\"%@\" offset=\"%@\" duration=\"%@\"/>\n",
                                  clipName, offsetString, durationString];
            }
            continue;
        }

        NSString *mediaURL = entry[@"mediaURL"];
        NSDictionary *resource = mediaResources[mediaURL];
        NSString *inString = SpliceKit_fcpxmlTimeStringForFrameCount([entry[@"inFrames"] longLongValue], frameDuration);

        if (addSongChild) {
            [xml appendFormat:@"                        <asset-clip ref=\"%@\" name=\"%@\" offset=\"%@\" duration=\"%@\" start=\"%@\">\n",
                              resource[@"id"], clipName, offsetString, durationString, inString];
            // Connected clip offset is in parent's local time coordinates.
            // Anchor the song at the parent clip's start (in-point) so it
            // lines up with the parent's first visible frame on the timeline.
            [xml appendFormat:@"                            <asset-clip ref=\"song_audio\" lane=\"-1\" name=\"Music\" offset=\"%@\" duration=\"%@\" start=\"0s\"/>\n",
                              inString, sequenceDurationString];
            [xml appendString:@"                        </asset-clip>\n"];
            attachedSong = YES;
        } else {
            [xml appendFormat:@"                        <asset-clip ref=\"%@\" name=\"%@\" offset=\"%@\" duration=\"%@\" start=\"%@\"/>\n",
                              resource[@"id"], clipName, offsetString, durationString, inString];
        }
    }

    [xml appendString:@"                    </spine>\n"];
    [xml appendString:@"                </sequence>\n"];
    [xml appendString:@"            </project>\n"];
    [xml appendString:@"        </event>\n"];
    [xml appendString:@"    </library>\n"];
    [xml appendString:@"</fcpxml>\n"];
    return xml;
}

double SpliceKit_quantizeSecondsToFrameGrid(double seconds, double frameSeconds) {
    if (!isfinite(seconds) || seconds <= 0.0) return 0.0;
    if (!isfinite(frameSeconds) || frameSeconds <= 0.000001) return seconds;
    long long frames = llround(seconds / frameSeconds);
    return (double)frames * frameSeconds;
}

static BOOL SpliceKit_mediaURLLooksAudioOnly(NSString *urlString) {
    if (urlString.length == 0) return NO;

    NSString *path = [[NSURL URLWithString:urlString] path] ?: urlString;
    NSString *ext = [[path pathExtension] lowercaseString];
    static NSSet<NSString *> *audioExts = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        audioExts = [NSSet setWithArray:@[@"mp3", @"m4a", @"aac", @"wav", @"aif", @"aiff", @"caf", @"flac"]];
    });
    return [audioExts containsObject:ext];
}

static NSArray *SpliceKit_copyBrowserClipsForEvent(id event) {
    // The same walk browser.listClips makes (SpliceKit_browserClipsOfEvent).
    return SpliceKit_browserClipsOfEvent(event);
}

static SpliceKit_CMTimeRange SpliceKit_clipRangeForItem(id item) {
    SpliceKit_CMTimeRange clipRange = {0};
    if (!item) return clipRange;

    if ([item respondsToSelector:@selector(clippedRange)]) {
        clipRange = ((SpliceKit_CMTimeRange (*)(id, SEL))STRET_MSG)(item, @selector(clippedRange));
    } else if ([item respondsToSelector:@selector(duration)]) {
        SpliceKit_CMTime dur = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
        clipRange.start = (SpliceKit_CMTime){0, dur.timescale > 0 ? dur.timescale : 6000, 1, 0};
        clipRange.duration = dur;
    }

    if (clipRange.start.timescale <= 0) {
        clipRange.start.timescale = clipRange.duration.timescale > 0 ? clipRange.duration.timescale : 6000;
        clipRange.start.flags = 1;
    }
    if (clipRange.duration.timescale <= 0 && clipRange.duration.value > 0) {
        clipRange.duration.timescale = clipRange.start.timescale > 0 ? clipRange.start.timescale : 6000;
        clipRange.duration.flags = 1;
    }
    return clipRange;
}

static id SpliceKit_findBrowserClipMatchingMediaURL(NSString *mediaURL, NSString *fallbackName) {
    id libs = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
    if (![libs isKindOfClass:[NSArray class]]) return nil;

    BOOL requireURLMatch = (mediaURL.length > 0);
    NSString *lowerFallback = requireURLMatch ? nil : [fallbackName lowercaseString];
    for (id library in (NSArray *)libs) {
        SEL eventsSel = NSSelectorFromString(@"events");
        if (![library respondsToSelector:eventsSel]) continue;
        id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
        if (![events isKindOfClass:[NSArray class]]) continue;

        for (id event in (NSArray *)events) {
            NSArray *clips = SpliceKit_copyBrowserClipsForEvent(event);
            for (id clip in clips) {
                NSString *clipURL = SpliceKit_getMediaURLForClip(clip);
                if (mediaURL.length > 0 && clipURL.length > 0 && [clipURL isEqualToString:mediaURL]) {
                    return clip;
                }

                if (lowerFallback.length > 0) {
                    NSString *clipName = SpliceKit_displayNameForItem(clip);
                    if (clipName.length > 0 &&
                        [[clipName lowercaseString] containsString:lowerFallback]) {
                        return clip;
                    }
                }
            }
        }
    }

    return nil;
}

static id SpliceKit_normalizeSourceObjectForInsertion(id sourceObject) {
    if (!sourceObject) return nil;

    SEL mediaRangeSel = NSSelectorFromString(@"mediaRange");
    SEL sequenceSel = NSSelectorFromString(@"sequence");
    SEL organizerItemSel = NSSelectorFromString(@"organizerDataItem");

    // Organizer/browser-backed items respond to sequenceRecord and are acceptable as-is.
    // Raw timeline items (FFAnchoredMediaComponent) also respond to mediaRange/sequence
    // but crash on sequenceRecord, so they must NOT be returned early.
    if ([sourceObject respondsToSelector:mediaRangeSel] &&
        [sourceObject respondsToSelector:sequenceSel] &&
        [sourceObject respondsToSelector:NSSelectorFromString(@"sequenceRecord")]) {
        return sourceObject;
    }

    SEL isMediaRefSel = NSSelectorFromString(@"isMediaRef");
    if ([sourceObject respondsToSelector:organizerItemSel]) {
        @try {
            id organizerItem = ((id (*)(id, SEL))objc_msgSend)(sourceObject, organizerItemSel);
            if (organizerItem && [organizerItem respondsToSelector:isMediaRefSel]) return organizerItem;
        } @catch (NSException *e) {}
    }

    // Timeline-backed items usually need to be promoted through their owning sequence.
    if ([sourceObject respondsToSelector:sequenceSel]) {
        @try {
            id sourceSequence = ((id (*)(id, SEL))objc_msgSend)(sourceObject, sequenceSel);
            if (sourceSequence && [sourceSequence respondsToSelector:organizerItemSel]) {
                id organizerItem = ((id (*)(id, SEL))objc_msgSend)(sourceSequence, organizerItemSel);
                if (organizerItem && [organizerItem respondsToSelector:isMediaRefSel]) return organizerItem;
            }
        } @catch (NSException *e) {}
    }

    // Last resort: find the matching browser clip by media URL or display name.
    NSString *normMediaURL = SpliceKit_getMediaURLForClip(sourceObject) ?: @"";
    NSString *normDisplayName = SpliceKit_displayNameForItem(sourceObject);
    if (normMediaURL.length > 0 || normDisplayName.length > 0) {
        id browserClip = SpliceKit_findBrowserClipMatchingMediaURL(normMediaURL, normDisplayName);
        if (!browserClip && normMediaURL.length > 0 && normDisplayName.length > 0) {
            // URL didn't match (media may be wrapped in a browser sequence). Try name only.
            browserClip = SpliceKit_findBrowserClipMatchingMediaURL(nil, normDisplayName);
        }
        if (browserClip) return browserClip;
    }

    return sourceObject;
}

static NSDictionary *SpliceKit_prepareBrowserClipSourceForInsertion(id sourceBrowserClip,
                                                                    SpliceKit_CMTimeRange clipRange,
                                                                    BOOL preferAudio) {
    NSMutableDictionary *diag = [NSMutableDictionary dictionary];
    diag[@"ok"] = @NO;

    if (!sourceBrowserClip) {
        diag[@"error"] = @"Missing source browser clip";
        return diag;
    }
    if (clipRange.duration.timescale <= 0 || clipRange.duration.value <= 0) {
        diag[@"error"] = @"Missing source media range";
        return diag;
    }
    diag[@"sourceClipClass"] = NSStringFromClass([sourceBrowserClip class]) ?: @"";

    id insertionSource = SpliceKit_normalizeSourceObjectForInsertion(sourceBrowserClip);
    if (!insertionSource) {
        diag[@"error"] = @"Unable to normalize source object for insertion";
        return diag;
    }
    if (insertionSource != sourceBrowserClip) {
        diag[@"normalizedSourceClass"] = NSStringFromClass([insertionSource class]) ?: @"";
    }

    id appController = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("PEAppController"), NSSelectorFromString(@"appController"));
    id organizerContainer = appController &&
        [appController respondsToSelector:NSSelectorFromString(@"mediaEventOrganizerContainer")]
            ? ((id (*)(id, SEL))objc_msgSend)(appController, NSSelectorFromString(@"mediaEventOrganizerContainer"))
            : nil;
    id organizer = organizerContainer &&
        [organizerContainer respondsToSelector:NSSelectorFromString(@"activeOrganizerModule")]
            ? ((id (*)(id, SEL))objc_msgSend)(organizerContainer, NSSelectorFromString(@"activeOrganizerModule"))
            : nil;

    if (!organizer) {
        diag[@"error"] = @"No active organizer module";
        return diag;
    }

    diag[@"activeOrganizerClass"] = NSStringFromClass([organizer class]) ?: @"";

    if ([organizer respondsToSelector:NSSelectorFromString(@"setSidebarHidden:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(organizer, NSSelectorFromString(@"setSidebarHidden:"), NO);
    }
    if ([organizer respondsToSelector:NSSelectorFromString(@"setLibrarySidebarActive:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(organizer, NSSelectorFromString(@"setLibrarySidebarActive:"), YES);
    }
    if ([organizer respondsToSelector:NSSelectorFromString(@"_showLibrarySidebar")]) {
        ((void (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"_showLibrarySidebar"));
    }
    if ([organizer respondsToSelector:NSSelectorFromString(@"_syncSidebarButtonsToVisibleState")]) {
        ((void (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"_syncSidebarButtonsToVisibleState"));
    }

    id mediaDetail = [organizer respondsToSelector:NSSelectorFromString(@"mediaDetailContainerModule")]
        ? ((id (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"mediaDetailContainerModule"))
        : nil;
    id mediaBrowser = mediaDetail &&
        [mediaDetail respondsToSelector:NSSelectorFromString(@"getActiveMediaBrowser")]
            ? ((id (*)(id, SEL))objc_msgSend)(mediaDetail, NSSelectorFromString(@"getActiveMediaBrowser"))
            : nil;
    if (!mediaBrowser && [organizer respondsToSelector:NSSelectorFromString(@"filmstripModule")]) {
        mediaBrowser = ((id (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"filmstripModule"));
    }
    if (!mediaBrowser && organizerContainer &&
        [organizerContainer respondsToSelector:NSSelectorFromString(@"getActiveMediaBrowser")]) {
        mediaBrowser = ((id (*)(id, SEL))objc_msgSend)(organizerContainer, NSSelectorFromString(@"getActiveMediaBrowser"));
    }
    if (!mediaBrowser) {
        diag[@"error"] = @"No active media browser";
        return diag;
    }
    diag[@"mediaBrowserClass"] = NSStringFromClass([mediaBrowser class]) ?: @"";

    if ([mediaBrowser respondsToSelector:NSSelectorFromString(@"_ensureModuleIsVisible")]) {
        ((void (*)(id, SEL))objc_msgSend)(mediaBrowser, NSSelectorFromString(@"_ensureModuleIsVisible"));
    }

    Class rangeObjClass = objc_getClass("FigTimeRangeAndObject");
    SEL rangeAndObjSel = NSSelectorFromString(@"rangeAndObjectWithRange:andObject:");
    if (!rangeObjClass || ![(id)rangeObjClass respondsToSelector:rangeAndObjSel]) {
        diag[@"error"] = @"FigTimeRangeAndObject unavailable";
        return diag;
    }

    id mediaRange = ((id (*)(id, SEL, SpliceKit_CMTimeRange, id))objc_msgSend)(
        (id)rangeObjClass, rangeAndObjSel, clipRange, insertionSource);
    if (!mediaRange) {
        diag[@"error"] = @"Failed to build source media range";
        return diag;
    }

    NSArray *ranges = @[mediaRange];
    SpliceKit_CMTime zero = {0, clipRange.duration.timescale > 0 ? clipRange.duration.timescale : 6000, 1, 0};
    SEL revealSel = NSSelectorFromString(@"revealObject:andRange:atPlayhead:");
    if ([organizer respondsToSelector:revealSel]) {
        ((BOOL (*)(id, SEL, id, SpliceKit_CMTimeRange, SpliceKit_CMTime))objc_msgSend)(
            organizer, revealSel, insertionSource, clipRange, zero);
    }
    SEL revealRangesSel = NSSelectorFromString(@"revealMediaRanges:");
    if ([organizer respondsToSelector:revealRangesSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(organizer, revealRangesSel, ranges);
    }

    SEL selectSel = NSSelectorFromString(@"_selectMediaRanges:");
    if (![mediaBrowser respondsToSelector:selectSel]) {
        diag[@"error"] = @"Media browser cannot select ranges";
        return diag;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(mediaBrowser, selectSel, ranges);

    id selectionManager = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("PESelectionManager"), NSSelectorFromString(@"defaultSelectionManager"));
    if (selectionManager) {
        id context = nil;
        Class contextClass = objc_getClass("FFContext");
        if (contextClass) {
            context = ((id (*)(id, SEL))objc_msgSend)((id)contextClass, @selector(alloc));
            context = ((id (*)(id, SEL))objc_msgSend)(context, @selector(init));
        }
        SEL displaySel = NSSelectorFromString(@"displayMedia:context:effectCount:loadingBlock:unloadingBlock:");
        id displayTarget = [mediaBrowser respondsToSelector:displaySel] ? mediaBrowser : organizer;
        if (displayTarget && [displayTarget respondsToSelector:displaySel]) {
            ((void (*)(id, SEL, id, id, NSInteger, id, id))objc_msgSend)(
                displayTarget,
                displaySel,
                insertionSource,
                context,
                0,
                nil,
                nil);
        } else {
            id viewed = nil;
            Class viewedClipSetClass = objc_getClass("PEViewedClipSet");
            if (viewedClipSetClass) {
                viewed = ((id (*)(id, SEL))objc_msgSend)((id)viewedClipSetClass, @selector(alloc));
                viewed = ((id (*)(id, SEL, id, id, id, int, id))objc_msgSend)(
                    viewed,
                    NSSelectorFromString(@"initWithClips:contexts:effectCounts:layoutStyle:owner:"),
                    @[insertionSource],
                    @[context ?: [NSNull null]],
                    @[@0],
                    0,
                    nil);
            }
            if (viewed) {
                if ([viewed respondsToSelector:NSSelectorFromString(@"setTargetPlayer:")]) {
                    ((void (*)(id, SEL, int))objc_msgSend)(viewed, NSSelectorFromString(@"setTargetPlayer:"), 1);
                }
                if ([selectionManager respondsToSelector:NSSelectorFromString(@"setViewedClips:")]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(selectionManager, NSSelectorFromString(@"setViewedClips:"), viewed);
                }
            }
        }
        if ([selectionManager respondsToSelector:NSSelectorFromString(@"viewedClips")]) {
            id viewed = ((id (*)(id, SEL))objc_msgSend)(selectionManager, NSSelectorFromString(@"viewedClips"));
            if ([viewed respondsToSelector:NSSelectorFromString(@"setPreferAudio:")]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(viewed, NSSelectorFromString(@"setPreferAudio:"), preferAudio);
            }
        }
    }

    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];

    NSUInteger selectedRangeCount = 0;
    if ([organizer respondsToSelector:NSSelectorFromString(@"selectedRangesOfMediaForTimelineEditing")]) {
        id selectedRanges = ((id (*)(id, SEL))objc_msgSend)(
            organizer, NSSelectorFromString(@"selectedRangesOfMediaForTimelineEditing"));
        if ([selectedRanges respondsToSelector:@selector(count)]) {
            selectedRangeCount = [selectedRanges count];
        }
    } else if ([organizer respondsToSelector:NSSelectorFromString(@"selectedRangesOfMedia")]) {
        id selectedRanges = ((id (*)(id, SEL))objc_msgSend)(
            organizer, NSSelectorFromString(@"selectedRangesOfMedia"));
        if ([selectedRanges respondsToSelector:@selector(count)]) {
            selectedRangeCount = [selectedRanges count];
        }
    }

    NSUInteger viewedClipCount = 0;
    if (selectionManager && [selectionManager respondsToSelector:NSSelectorFromString(@"viewedClips")]) {
        id viewedClips = ((id (*)(id, SEL))objc_msgSend)(selectionManager, NSSelectorFromString(@"viewedClips"));
        if (viewedClips && [viewedClips respondsToSelector:NSSelectorFromString(@"clips")]) {
            id clips = ((id (*)(id, SEL))objc_msgSend)(viewedClips, NSSelectorFromString(@"clips"));
            if ([clips respondsToSelector:@selector(count)]) {
                viewedClipCount = [clips count];
            }
        }
    }

    diag[@"selectedRangeCount"] = @(selectedRangeCount);
    diag[@"viewedClipCount"] = @(viewedClipCount);
    diag[@"ok"] = @((selectedRangeCount > 0) && (viewedClipCount > 0));
    if (selectedRangeCount == 0 || viewedClipCount == 0) {
        diag[@"error"] = [NSString stringWithFormat:
            @"Source prep incomplete (selectedRangeCount=%lu viewedClipCount=%lu)",
            (unsigned long)selectedRangeCount,
            (unsigned long)viewedClipCount];
    }
    return diag;
}

id SpliceKit_findSequenceNamedInActiveLibraries(NSString *projectName) {
    if (projectName.length == 0) return nil;

    id libs = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
    if (![libs isKindOfClass:[NSArray class]]) return nil;

    for (id library in (NSArray *)libs) {
        if (!library) continue;

        id seqSet = nil;
        SEL deepSel = NSSelectorFromString(@"_deepLoadedSequences");
        if ([library respondsToSelector:deepSel]) {
            seqSet = ((id (*)(id, SEL))objc_msgSend)(library, deepSel);
        }
        if (!seqSet) continue;

        id seqArray = nil;
        if ([seqSet respondsToSelector:@selector(allObjects)]) {
            seqArray = ((id (*)(id, SEL))objc_msgSend)(seqSet, @selector(allObjects));
        } else if ([seqSet isKindOfClass:[NSArray class]]) {
            seqArray = seqSet;
        }
        if (![seqArray isKindOfClass:[NSArray class]]) continue;

        // First pass: exact match
        for (id seq in (NSArray *)seqArray) {
            NSString *seqName = nil;
            if ([seq respondsToSelector:@selector(displayName)]) {
                seqName = ((id (*)(id, SEL))objc_msgSend)(seq, @selector(displayName));
            }
            if (seqName && [seqName isEqualToString:projectName]) {
                return seq;
            }
        }
        // Second pass: case-insensitive substring match
        NSString *lowerProjectName = [projectName lowercaseString];
        for (id seq in (NSArray *)seqArray) {
            NSString *seqName = nil;
            if ([seq respondsToSelector:@selector(displayName)]) {
                seqName = ((id (*)(id, SEL))objc_msgSend)(seq, @selector(displayName));
            }
            if (seqName && [[seqName lowercaseString] containsString:lowerProjectName]) {
                return seq;
            }
        }
    }

    return nil;
}

static BOOL SpliceKit_loadSequenceInActiveEditor(id sequence) {
    if (!sequence) return NO;

    id app = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("NSApplication"), @selector(sharedApplication));
    id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
    if (!delegate) return NO;

    SEL containerSel = @selector(activeEditorContainer);
    if (![delegate respondsToSelector:containerSel]) return NO;
    id editorContainer = ((id (*)(id, SEL))objc_msgSend)(delegate, containerSel);
    if (!editorContainer) return NO;

    SEL loadSel = NSSelectorFromString(@"loadEditorForSequence:");
    if (![editorContainer respondsToSelector:loadSel]) return NO;

    ((void (*)(id, SEL, id))objc_msgSend)(editorContainer, loadSel, sequence);
    return YES;
}

static SpliceKit_CMTime SpliceKit_makeCMTimeWithTimescale(double seconds, int32_t timescale) {
    if (!isfinite(seconds)) seconds = 0.0;
    if (timescale <= 0) timescale = 6000;
    return (SpliceKit_CMTime){
        .value = (int64_t)llround(seconds * (double)timescale),
        .timescale = timescale,
        .flags = 1,
        .epoch = 0,
    };
}

static SpliceKit_CMTime SpliceKit_addSecondsToCMTime(SpliceKit_CMTime base, double seconds) {
    double baseSeconds = (base.timescale > 0) ? ((double)base.value / (double)base.timescale) : 0.0;
    int32_t timescale = base.timescale > 0 ? base.timescale : 6000;
    return SpliceKit_makeCMTimeWithTimescale(baseSeconds + seconds, timescale);
}

static id SpliceKit_findAssemblyEvent(NSArray *events, NSString *eventName) {
    if (![events isKindOfClass:[NSArray class]] || events.count == 0) return nil;
    if (eventName.length == 0) return events.firstObject;

    NSString *needle = [eventName lowercaseString];
    for (id event in events) {
        NSString *name = SpliceKit_displayNameForItem(event);
        if (name.length > 0 && [[name lowercaseString] containsString:needle]) {
            return event;
        }
    }
    return nil;
}

static NSDictionary *SpliceKit_createNativeProjectSequence(NSString *projectName, id targetEvent) {
    NSMutableDictionary *diag = [NSMutableDictionary dictionary];
    diag[@"ok"] = @NO;

    if (projectName.length == 0) {
        diag[@"error"] = @"Missing project name";
        return diag;
    }
    if (!targetEvent) {
        diag[@"error"] = @"Missing target event for project creation";
        return diag;
    }

    SEL libraryItemSel = NSSelectorFromString(@"libraryItem");
    id eventLibraryItem = [targetEvent respondsToSelector:libraryItemSel]
        ? ((id (*)(id, SEL))objc_msgSend)(targetEvent, libraryItemSel)
        : targetEvent;
    if (!eventLibraryItem) {
        diag[@"error"] = @"Target event does not expose a library item";
        return diag;
    }

    Class projectDocClass = objc_getClass("FFProjectDocument");
    SEL createSel = NSSelectorFromString(@"actionNewProject:name:sequence:actionName:error:");
    if (!projectDocClass || ![(id)projectDocClass respondsToSelector:createSel]) {
        diag[@"error"] = @"FFProjectDocument actionNewProject:name:sequence:actionName:error: unavailable";
        return diag;
    }

    NSError *error = nil;
    id createdProjectClip = ((id (*)(id, SEL, id, id, id, id, NSError **))objc_msgSend)(
        (id)projectDocClass,
        createSel,
        eventLibraryItem,
        projectName,
        nil,
        @"SpliceKit Song Cut",
        &error);
    if (!createdProjectClip) {
        diag[@"error"] = error.localizedDescription ?: @"Native project creation returned nil";
        return diag;
    }

    id sequence = nil;
    for (int attempt = 0; attempt < 40 && !sequence; attempt++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        sequence = SpliceKit_findSequenceNamedInActiveLibraries(projectName);
    }
    if (!sequence) {
        diag[@"error"] = @"Created the native project clip, but could not resolve the backing sequence";
        diag[@"createdObjectClass"] = NSStringFromClass([createdProjectClip class]) ?: @"";
        return diag;
    }

    BOOL loaded = SpliceKit_loadSequenceInActiveEditor(sequence);
    diag[@"sequence"] = sequence;
    diag[@"sequenceHandle"] = SpliceKit_storeHandle(sequence) ?: @"";
    diag[@"createdObjectClass"] = NSStringFromClass([createdProjectClip class]) ?: @"";
    diag[@"eventName"] = SpliceKit_displayNameForItem(targetEvent) ?: @"";
    diag[@"loaded"] = @(loaded);
    diag[@"ok"] = @(loaded);
    if (!loaded) {
        diag[@"error"] = @"Created project but failed to load it into the active editor";
    }
    return diag;
}

static NSDictionary *SpliceKit_performPreparedMediaEdit(id timeline,
                                                        NSInteger editKind,
                                                        BOOL backTimed,
                                                        NSString *trackType,
                                                        BOOL useExplicitTime,
                                                        SpliceKit_CMTime explicitTime) {
    NSMutableDictionary *diag = [NSMutableDictionary dictionary];
    diag[@"ok"] = @NO;
    diag[@"editKind"] = @(editKind);
    diag[@"trackType"] = trackType ?: @"all";
    diag[@"useExplicitTime"] = @(useExplicitTime);

    if (!timeline) {
        diag[@"error"] = @"Missing active timeline";
        return diag;
    }

    Class editActionClass = objc_getClass("FFEditAction");
    SEL createEditSel = NSSelectorFromString(@"editActionOfKind:backTimed:trackType:");
    if (!editActionClass || ![(id)editActionClass respondsToSelector:createEditSel]) {
        diag[@"error"] = @"FFEditAction editActionOfKind:backTimed:trackType: unavailable";
        return diag;
    }

    id editAction = ((id (*)(id, SEL, NSInteger, BOOL, id))objc_msgSend)(
        (id)editActionClass,
        createEditSel,
        editKind,
        backTimed,
        trackType ?: @"all");
    if (!editAction) {
        diag[@"error"] = @"Failed to build edit action";
        return diag;
    }

    NSString *pasteboardName = [NSString stringWithFormat:@"com.apple.nle.splicekit.%@",
                                [[NSUUID UUID] UUIDString]];
    diag[@"pasteboardName"] = pasteboardName;

    id appController = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("PEAppController"), NSSelectorFromString(@"appController"));
    id source = appController &&
        [appController respondsToSelector:NSSelectorFromString(@"activeSourceForEditAction:")]
            ? ((id (*)(id, SEL, id))objc_msgSend)(appController, NSSelectorFromString(@"activeSourceForEditAction:"), editAction)
            : nil;

    if (!source && appController) {
        id organizerContainer = [appController respondsToSelector:NSSelectorFromString(@"mediaEventOrganizerContainer")]
            ? ((id (*)(id, SEL))objc_msgSend)(appController, NSSelectorFromString(@"mediaEventOrganizerContainer"))
            : nil;
        id organizer = organizerContainer &&
            [organizerContainer respondsToSelector:NSSelectorFromString(@"activeOrganizerModule")]
                ? ((id (*)(id, SEL))objc_msgSend)(organizerContainer, NSSelectorFromString(@"activeOrganizerModule"))
                : nil;
        id mediaDetail = organizer &&
            [organizer respondsToSelector:NSSelectorFromString(@"mediaDetailContainerModule")]
                ? ((id (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"mediaDetailContainerModule"))
                : nil;
        source = mediaDetail &&
            [mediaDetail respondsToSelector:NSSelectorFromString(@"getActiveMediaBrowser")]
                ? ((id (*)(id, SEL))objc_msgSend)(mediaDetail, NSSelectorFromString(@"getActiveMediaBrowser"))
                : nil;
        if (!source && organizer && [organizer respondsToSelector:NSSelectorFromString(@"filmstripModule")]) {
            source = ((id (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"filmstripModule"));
        }
    }

    if (!source) {
        diag[@"error"] = @"No active source for the prepared browser selection";
        return diag;
    }
    diag[@"sourceClass"] = NSStringFromClass([source class]) ?: @"";

    BOOL canSource = YES;
    SEL canSourceSel = NSSelectorFromString(@"canSourceDataForEditAction:");
    if ([source respondsToSelector:canSourceSel]) {
        canSource = ((BOOL (*)(id, SEL, id))objc_msgSend)(source, canSourceSel, editAction);
    }
    diag[@"canSource"] = @(canSource);
    if (!canSource) {
        diag[@"error"] = @"Prepared browser selection cannot source data for this edit action";
        return diag;
    }

    SEL writeSel = NSSelectorFromString(@"writeDataForEditAction:toPasteboardWithName:");
    if (![source respondsToSelector:writeSel]) {
        diag[@"error"] = @"Source module cannot write edit data to the pasteboard";
        return diag;
    }
    BOOL wrote = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(source, writeSel, editAction, pasteboardName);
    diag[@"writeOK"] = @(wrote);
    if (!wrote) {
        diag[@"error"] = @"Source module failed to write the prepared selection to the pasteboard";
        return diag;
    }

    if (useExplicitTime) {
        SEL containerSel = NSSelectorFromString(@"_containerForEditOperation");
        id container = [timeline respondsToSelector:containerSel]
            ? ((id (*)(id, SEL))objc_msgSend)(timeline, containerSel)
            : nil;
        if (!container && [timeline respondsToSelector:NSSelectorFromString(@"rootItem")]) {
            container = ((id (*)(id, SEL))objc_msgSend)(timeline, NSSelectorFromString(@"rootItem"));
        }
        if (!container) {
            diag[@"error"] = @"Timeline has no container for explicit-time insertion";
            return diag;
        }
        diag[@"containerClass"] = NSStringFromClass([container class]) ?: @"";

        SEL addSel = NSSelectorFromString(@"_addItemsWithPasteboard:atTime:pasteMode:backtimed:useSelectedRange:trackType:container:changesUnderActionHandler:");
        if (![timeline respondsToSelector:addSel]) {
            diag[@"error"] = @"Timeline does not support explicit-time pasteboard insertion";
            return diag;
        }
        ((void (*)(id, SEL, id, SpliceKit_CMTime, int, BOOL, BOOL, id, id, id))objc_msgSend)(
            timeline,
            addSel,
            pasteboardName,
            explicitTime,
            (int)editKind,
            backTimed,
            YES,
            trackType ?: @"all",
            container,
            nil);
    } else {
        SEL performSel = NSSelectorFromString(@"performEditAction:fromPasteboardWithName:fromAnimation:");
        if (![timeline respondsToSelector:performSel]) {
            diag[@"error"] = @"Timeline cannot consume pasteboard edits";
            return diag;
        }
        ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
            timeline,
            performSel,
            editAction,
            pasteboardName,
            NO);
    }

    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
    diag[@"ok"] = @YES;
    return diag;
}

NSDictionary *SpliceKit_handleAssembleRandomClipsToBeats(NSDictionary *params) {
    NSString *sourceHandle = [params[@"sourceHandle"] isKindOfClass:[NSString class]] ? params[@"sourceHandle"] : nil;
    NSString *sourceProjectName = [params[@"sourceProjectName"] isKindOfClass:[NSString class]] ? params[@"sourceProjectName"] : nil;
    NSString *clipSourceProjectName = [params[@"clipSourceProjectName"] isKindOfClass:[NSString class]] ? params[@"clipSourceProjectName"] : nil;
    NSArray *clipHandles = [params[@"clipHandles"] isKindOfClass:[NSArray class]] ? params[@"clipHandles"] : nil;
    NSString *eventName = [params[@"eventName"] isKindOfClass:[NSString class]] ? params[@"eventName"] : nil;
    NSString *grid = [params[@"grid"] isKindOfClass:[NSString class]] ? [params[@"grid"] lowercaseString] : @"bar";
    NSString *buildMode = [params[@"buildMode"] isKindOfClass:[NSString class]]
        ? [params[@"buildMode"] lowercaseString] : @"native";
    NSString *projectName = [params[@"projectName"] isKindOfClass:[NSString class]]
        ? params[@"projectName"] : @"Beat Random Cut";
    NSInteger segmentMinStep = params[@"segmentMinStep"] ? [params[@"segmentMinStep"] integerValue] : 1;
    NSInteger segmentMaxStep = params[@"segmentMaxStep"] ? [params[@"segmentMaxStep"] integerValue] : segmentMinStep;
    NSInteger maxSegments = params[@"maxSegments"] ? [params[@"maxSegments"] integerValue] : 0;
    long long randomSeed = params[@"randomSeed"] ? [params[@"randomSeed"] longLongValue] : 1337;
    BOOL allowClipReuse = params[@"allowClipReuse"] ? [params[@"allowClipReuse"] boolValue] : YES;
    BOOL includeAudio = params[@"includeAudio"] ? [params[@"includeAudio"] boolValue] : YES;
    BOOL targetCurrentTimeline = params[@"targetCurrentTimeline"] ? [params[@"targetCurrentTimeline"] boolValue] : NO;
    BOOL dryRun = [params[@"dryRun"] boolValue];
    NSDictionary *rawStepWeights = [params[@"stepWeights"] isKindOfClass:[NSDictionary class]]
        ? params[@"stepWeights"] : nil;

    if ([grid isEqualToString:@"random"]) {
        grid = @"beat";
    } else if ([grid isEqualToString:@"random_half"] || [grid isEqualToString:@"random_half_beat"]) {
        grid = @"half_beat";
    } else if ([grid isEqualToString:@"random_quarter"] || [grid isEqualToString:@"random_quarter_beat"]) {
        grid = @"quarter_beat";
    }

    if (![@[@"beat", @"half", @"half_beat", @"quarter", @"quarter_beat", @"bar", @"section"] containsObject:grid]) {
        return @{@"error": @"grid must be one of: beat, half_beat, quarter_beat, bar, section"};
    }
    if ([buildMode isEqualToString:@"xml"]) buildMode = @"fcpxml";
    if (![@[@"native", @"fcpxml"] containsObject:buildMode]) {
        return @{@"error": @"buildMode must be one of: native, fcpxml"};
    }
    if (targetCurrentTimeline && ![buildMode isEqualToString:@"native"]) {
        return @{@"error": @"targetCurrentTimeline is only supported for native builds"};
    }
    if (segmentMinStep < 1) segmentMinStep = 1;
    if (segmentMaxStep < segmentMinStep) segmentMaxStep = segmentMinStep;

    NSMutableDictionary<NSNumber *, NSNumber *> *stepWeights = [NSMutableDictionary dictionary];
    for (id rawKey in rawStepWeights) {
        NSInteger step = [rawKey integerValue];
        NSInteger weight = [rawStepWeights[rawKey] integerValue];
        if (step < segmentMinStep || step > segmentMaxStep || weight <= 0) continue;
        stepWeights[@(step)] = @(weight);
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id sequence = [timeline respondsToSelector:@selector(sequence)]
                ? ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence)) : nil;
            if (!sequence) { result = @{@"error": @"No sequence in timeline"}; return; }

            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
            if (!primaryObj) { result = @{@"error": @"Cannot access primary storyline"}; return; }

            SpliceKit_CMTime frameDuration = {100, 2400, 1, 0};
            SEL frameDurationSel = NSSelectorFromString(@"frameDuration");
            if ([sequence respondsToSelector:frameDurationSel]) {
                SpliceKit_CMTime fd = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(sequence, frameDurationSel);
                if (fd.value > 0 && fd.timescale > 0) frameDuration = fd;
            }

            NSArray *rootItems = SpliceKit_mixerArrayFromContainer(
                ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems))) ?: @[];

            NSMutableArray<NSDictionary *> *activeVisibleEntries = [NSMutableArray array];
            NSMutableSet<NSString *> *visited = [NSMutableSet set];
            for (id item in rootItems) {
                SpliceKit_collectVisibleTimelineEntries(item, primaryObj, activeVisibleEntries, visited);
            }

            NSArray *selectedItems = nil;
            NSMutableSet<NSString *> *selectedKeys = [NSMutableSet set];
            SEL selectedSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
            if ([timeline respondsToSelector:selectedSel]) {
                id selItems = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, selectedSel, NO, NO);
                selectedItems = SpliceKit_mixerArrayFromContainer(selItems);
            } else if ([timeline respondsToSelector:@selector(selectedItems)]) {
                selectedItems = SpliceKit_mixerArrayFromContainer(
                    ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(selectedItems)));
            }
            for (id selectedItem in selectedItems) {
                NSString *pointerKey = SpliceKit_handlePointerKey(selectedItem);
                if (pointerKey.length > 0) [selectedKeys addObject:pointerKey];
            }

            NSDictionary *sourceContext = nil;
            NSArray<NSDictionary *> *sourceVisibleEntries = nil;
            id sourcePrimaryObj = nil;
            if (sourceProjectName.length > 0) {
                sourceContext = SpliceKit_findVisibleEntryContextNamed(sourceProjectName);
                if ([sourceContext[@"error"] isKindOfClass:[NSString class]]) {
                    result = @{@"error": sourceContext[@"error"]};
                    return;
                }
                sourceVisibleEntries = sourceContext[@"visibleEntries"];
                sourcePrimaryObj = sourceContext[@"primaryObject"];
                if (sourceVisibleEntries.count == 0) {
                    result = @{@"error": [NSString stringWithFormat:@"No visible clips found in sourceProjectName \"%@\"", sourceProjectName]};
                    return;
                }
            } else {
                sourceVisibleEntries = activeVisibleEntries;
                sourcePrimaryObj = primaryObj;
            }

            NSDictionary *sourceEntry = nil;
            NSString *sourceKey = nil;
            if (sourceHandle.length > 0) {
                id sourceObj = SpliceKit_resolveHandle(sourceHandle);
                if (!sourceObj) {
                    result = @{@"error": [NSString stringWithFormat:@"Source handle not found: %@", sourceHandle]};
                    return;
                }
                sourceKey = SpliceKit_handlePointerKey(sourceObj);
                for (NSDictionary *entry in sourceVisibleEntries) {
                    if ([entry[@"pointerKey"] isEqualToString:sourceKey]) {
                        sourceEntry = entry;
                        break;
                    }
                }
                if (!sourceEntry) {
                    result = @{@"error": sourceProjectName.length > 0
                        ? @"Source clip handle is not visible in the requested source project"
                        : @"Source clip is not visible in the active timeline"};
                    return;
                }
            } else {
                NSArray *orderedEntries = [sourceVisibleEntries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
                    return [lhs[@"start"] compare:rhs[@"start"]];
                }];
                if (sourceProjectName.length == 0) {
                    for (NSDictionary *entry in orderedEntries) {
                        if (![selectedKeys containsObject:entry[@"pointerKey"]]) continue;
                        if (![entry[@"hasTimingMetadata"] boolValue] || ![entry[@"hasAudio"] boolValue]) continue;
                        sourceEntry = entry;
                        break;
                    }
                }
                if (!sourceEntry) {
                    for (NSDictionary *entry in orderedEntries) {
                        if (![entry[@"hasTimingMetadata"] boolValue] || ![entry[@"hasAudio"] boolValue]) continue;
                        if (![entry[@"beatGridEnabled"] boolValue]) continue;
                        sourceEntry = entry;
                        break;
                    }
                }
                if (!sourceEntry) {
                    for (NSDictionary *entry in orderedEntries) {
                        if ([entry[@"hasTimingMetadata"] boolValue] && [entry[@"hasAudio"] boolValue]) {
                            sourceEntry = entry;
                            break;
                        }
                    }
                }
                if (!sourceEntry) {
                    result = @{@"error": sourceProjectName.length > 0
                        ? [NSString stringWithFormat:
                             @"No audio clip in project \"%@\" carries a Final Cut Pro beat map. "
                             @"These tools read Final Cut Pro's own timing metadata, which comes "
                             @"with songs from its music library; detect_beats cannot add it.",
                             sourceProjectName]
                        : @"No audio clip on this timeline carries a Final Cut Pro beat map. Pass "
                          @"sourceHandle to name a clip, or use detect_beats with beat_sync_blade "
                          @"to cut to beats on ordinary audio."};
                    return;
                }
                sourceKey = sourceEntry[@"pointerKey"];
            }

            id sourceItem = sourceEntry[@"item"];
            if (!SpliceKit_boolForSelector(sourceItem, @"hasTimingMetadata")) {
                // -hasTimingMetadata is Final Cut Pro's own flag for audio it holds a
                // beat map for, which in practice means a song from its built-in music
                // library. SpliceKit only ever reads it; detect_beats analyses a file
                // with an external binary and cannot set it. The old wording here said
                // "Run beat detection on it first", which sends the caller down a path
                // that can never make this check pass.
                result = @{@"error": @"This clip has no Final Cut Pro beat map. Only audio "
                                     @"from Final Cut Pro's own music library carries one, "
                                     @"and nothing in SpliceKit can add it — detect_beats "
                                     @"analyses the file separately and does not set it. "
                                     @"To cut to beats on ordinary audio, use detect_beats "
                                     @"with beat_sync_blade or blade_at_times instead."};
                return;
            }
            SpliceKit_CMTimeRange sourceClipRange = SpliceKit_clipRangeForItem(sourceItem);

            double sourceStartSec = 0.0;
            double sourceEndSec = 0.0;
            double tempo = 0.0;
            NSArray<NSNumber *> *timelineGrid = SpliceKit_translateTimingMetadataToTimeline(
                sourceItem, sourcePrimaryObj, grid, &sourceStartSec, &sourceEndSec, &tempo);
            double sourceDuration = sourceEndSec - sourceStartSec;
            if (timelineGrid.count == 0 || sourceDuration <= 0.0001) {
                result = @{@"error": @"Source clip has no usable timing metadata for the requested grid"};
                return;
            }
            NSString *sourceMediaURL = SpliceKit_getMediaURLForClip(sourceItem) ?: @"";
            if (sourceMediaURL.length == 0 && [sourceItem respondsToSelector:NSSelectorFromString(@"media")]) {
                id sourceMedia = ((id (*)(id, SEL))objc_msgSend)(sourceItem, NSSelectorFromString(@"media"));
                SEL originalMediaURLSel = NSSelectorFromString(@"originalMediaURL");
                if (sourceMedia && [sourceMedia respondsToSelector:originalMediaURLSel]) {
                    id originalMediaURL = ((id (*)(id, SEL))objc_msgSend)(sourceMedia, originalMediaURLSel);
                    if ([originalMediaURL respondsToSelector:@selector(absoluteString)]) {
                        sourceMediaURL = ((id (*)(id, SEL))objc_msgSend)(originalMediaURL, @selector(absoluteString)) ?: @"";
                    }
                }
            }
            NSString *sourceFallbackName = [sourceEntry[@"name"] isKindOfClass:[NSString class]]
                ? sourceEntry[@"name"] : SpliceKit_displayNameForItem(sourceItem);
            id sourceBrowserClip = SpliceKit_findBrowserClipMatchingMediaURL(sourceMediaURL, sourceFallbackName);
            id sourceInsertObject = sourceBrowserClip ?: sourceItem;

            NSMutableArray<NSNumber *> *boundaries = [NSMutableArray arrayWithObject:@0.0];
            for (NSNumber *markerNum in timelineGrid) {
                double relative = [markerNum doubleValue] - sourceStartSec;
                if (relative > 0.0001 && relative < sourceDuration - 0.0001) {
                    [boundaries addObject:@(relative)];
                }
            }
            [boundaries addObject:@(sourceDuration)];
            NSArray<NSNumber *> *sortedBoundaries = SpliceKit_sortedUniqueSeconds(boundaries, 0.0001);
            if (sortedBoundaries.count < 2) {
                result = @{@"error": @"Not enough beat boundaries found inside the source clip"};
                return;
            }

            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active library"};
                return;
            }
            id library = [(NSArray *)libs firstObject];
            SEL eventsSel = NSSelectorFromString(@"events");
            if (![library respondsToSelector:eventsSel]) {
                result = @{@"error": @"Library does not respond to events"};
                return;
            }
            id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
            if (![events isKindOfClass:[NSArray class]] || [(NSArray *)events count] == 0) {
                result = @{@"error": @"No events in library"};
                return;
            }

            NSMutableSet<NSString *> *requestedClipKeys = [NSMutableSet set];
            for (id handleValue in clipHandles) {
                if (![handleValue isKindOfClass:[NSString class]]) continue;
                id clipObj = SpliceKit_resolveHandle(handleValue);
                NSString *pointerKey = SpliceKit_handlePointerKey(clipObj);
                if (pointerKey.length > 0) [requestedClipKeys addObject:pointerKey];
            }

            NSMutableArray<NSMutableDictionary *> *clipPool = [NSMutableArray array];
            if (clipSourceProjectName.length > 0) {
                NSDictionary *clipSourceContext = SpliceKit_findVisibleEntryContextNamed(clipSourceProjectName);
                if ([clipSourceContext[@"error"] isKindOfClass:[NSString class]]) {
                    result = @{@"error": clipSourceContext[@"error"]};
                    return;
                }

                NSArray<NSDictionary *> *clipEntries = clipSourceContext[@"visibleEntries"];
                if (clipEntries.count == 0) {
                    result = @{@"error": [NSString stringWithFormat:@"No visible clips found in clipSourceProjectName \"%@\"", clipSourceProjectName]};
                    return;
                }

                for (NSDictionary *entry in clipEntries) {
                    id clip = entry[@"item"];
                    NSString *pointerKey = entry[@"pointerKey"];
                    if (pointerKey.length == 0) continue;
                    if (requestedClipKeys.count > 0 && ![requestedClipKeys containsObject:pointerKey]) continue;
                    if (![entry[@"hasVideo"] boolValue] || [entry[@"isAudioOnly"] boolValue]) continue;

                    double durationSec = [entry[@"end"] doubleValue] - [entry[@"start"] doubleValue];
                    if (durationSec <= 0.050) continue;

                    NSString *mediaURL = SpliceKit_getMediaURLForClip(clip) ?: @"";
                    if (mediaURL.length > 0) {
                        if (sourceMediaURL.length > 0 && [mediaURL isEqualToString:sourceMediaURL]) continue;
                        if (SpliceKit_mediaURLLooksAudioOnly(mediaURL)) continue;
                    }

                    // Resolve the timeline clip to its browser equivalent for native insertion.
                    // The native edit path requires organizer-backed items, not raw
                    // FFAnchoredMediaComponent objects from another sequence's timeline.
                    NSString *clipDisplayName = [entry[@"name"] isKindOfClass:[NSString class]]
                        ? entry[@"name"] : SpliceKit_displayNameForItem(clip);
                    id browserClip = SpliceKit_findBrowserClipMatchingMediaURL(mediaURL, clipDisplayName);
                    if (!browserClip) {
                        // URL didn't match — media is likely inside a browser sequence.
                        // Fall back to name-based matching against browser clips.
                        browserClip = SpliceKit_findBrowserClipMatchingMediaURL(nil, clipDisplayName);
                    }
                    id poolClip = browserClip ?: clip;
                    double poolDurationSec = durationSec;
                    if (browserClip && [browserClip respondsToSelector:@selector(duration)]) {
                        SpliceKit_CMTime bDur = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(browserClip, @selector(duration));
                        double bDurSec = SpliceKit_cmtimeToSeconds(bDur);
                        if (bDurSec > poolDurationSec) poolDurationSec = bDurSec;
                    }

                    NSString *handle = SpliceKit_storeHandle(poolClip);
                    [clipPool addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                        @"clip": poolClip,
                        @"pointerKey": pointerKey,
                        @"handle": handle ?: @"",
                        @"name": clipDisplayName,
                        @"event": clipSourceProjectName ?: @"",
                        @"durationSeconds": @(poolDurationSec),
                        @"mediaURL": mediaURL ?: @"",
                    }]];
                }
            } else {
                for (id event in (NSArray *)events) {
                    NSString *browserEventName = SpliceKit_displayNameForItem(event);
                    if (eventName.length > 0 &&
                        ![[browserEventName lowercaseString] containsString:[eventName lowercaseString]]) {
                        continue;
                    }

                    NSArray *clips = SpliceKit_copyBrowserClipsForEvent(event);
                    for (id clip in clips) {
                        NSString *pointerKey = SpliceKit_handlePointerKey(clip);
                        if (pointerKey.length == 0) continue;
                        if (requestedClipKeys.count > 0 && ![requestedClipKeys containsObject:pointerKey]) continue;

                        BOOL hasVideo = SpliceKit_boolForSelector(clip, @"hasVideo");
                        BOOL hasContainedItems = SpliceKit_boolForSelector(clip, @"hasContainedItems");
                        if (!hasVideo) {
                            NSString *className = NSStringFromClass([clip class]);
                            hasVideo = [className containsString:@"Video"] ||
                                       [className containsString:@"Media"] ||
                                       [className containsString:@"Asset"] ||
                                       [className containsString:@"Clip"] ||
                                       [className containsString:@"Sequence"] ||
                                       hasContainedItems;
                        }
                        if (!hasVideo) continue;

                        double durationSec = 0.0;
                        if ([clip respondsToSelector:@selector(duration)]) {
                            SpliceKit_CMTime duration = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(clip, @selector(duration));
                            durationSec = SpliceKit_cmtimeToSeconds(duration);
                        } else if ([clip respondsToSelector:NSSelectorFromString(@"clippedRange")]) {
                            SpliceKit_CMTimeRange range = ((SpliceKit_CMTimeRange (*)(id, SEL))STRET_MSG)(
                                clip, NSSelectorFromString(@"clippedRange"));
                            durationSec = SpliceKit_cmtimeToSeconds(range.duration);
                        } else if ([clip respondsToSelector:NSSelectorFromString(@"unclippedRange")]) {
                            SpliceKit_CMTimeRange range = ((SpliceKit_CMTimeRange (*)(id, SEL))STRET_MSG)(
                                clip, NSSelectorFromString(@"unclippedRange"));
                            durationSec = SpliceKit_cmtimeToSeconds(range.duration);
                        } else if ([clip respondsToSelector:NSSelectorFromString(@"mediaRange")]) {
                            SpliceKit_CMTimeRange range = ((SpliceKit_CMTimeRange (*)(id, SEL))STRET_MSG)(
                                clip, NSSelectorFromString(@"mediaRange"));
                            durationSec = SpliceKit_cmtimeToSeconds(range.duration);
                        }
                        if (durationSec <= 0.050) continue;

                        NSString *mediaURL = SpliceKit_getMediaURLForClip(clip) ?: @"";
                        NSString *clipClassName = NSStringFromClass([clip class]) ?: @"";
                        if (mediaURL.length > 0) {
                            if (sourceMediaURL.length > 0 && [mediaURL isEqualToString:sourceMediaURL]) continue;
                            if (SpliceKit_mediaURLLooksAudioOnly(mediaURL)) continue;
                        } else if (hasContainedItems ||
                                   [clipClassName containsString:@"Sequence"] ||
                                   [clipClassName containsString:@"Project"]) {
                            // Keep the song-cut pool on media-backed clips instead of previously generated projects.
                            continue;
                        }

                        NSString *handle = SpliceKit_storeHandle(clip);
                        [clipPool addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                            @"clip": clip,
                            @"pointerKey": pointerKey,
                            @"handle": handle ?: @"",
                            @"name": SpliceKit_displayNameForItem(clip),
                            @"event": browserEventName ?: @"",
                            @"durationSeconds": @(durationSec),
                            @"mediaURL": mediaURL ?: @"",
                        }]];
                    }
                }
            }
            if (clipPool.count == 0) {
                result = @{@"error": clipSourceProjectName.length > 0
                    ? @"No eligible source clips found in the requested clipSourceProjectName"
                    : @"No browser clips found for random beat assembly"};
                return;
            }
            if (includeAudio && !sourceInsertObject && !dryRun) {
                result = @{@"error": @"Couldn't resolve the selected beat source song for native insertion"};
                return;
            }

            NSMutableArray<NSMutableDictionary *> *plan = [NSMutableArray array];
            NSMutableSet<NSString *> *usedClipKeys = [NSMutableSet set];
            NSUInteger assignedClipCount = 0;
            NSUInteger gapCount = 0;
            uint64_t rngState = (uint64_t)randomSeed;
            BOOL isHalfBeatGrid = [grid isEqualToString:@"half_beat"] || [grid isEqualToString:@"half"];
            BOOL forceNextHalfBeat = NO;
            for (NSUInteger boundaryIndex = 0; boundaryIndex + 1 < sortedBoundaries.count;) {
                NSInteger requestedStep;
                if (forceNextHalfBeat) {
                    // Second half of a half-beat pair — force step=1 so the pair
                    // resolves on a whole-beat boundary.
                    requestedStep = 1;
                    forceNextHalfBeat = NO;
                } else {
                    requestedStep = SpliceKit_chooseRandomAssemblyStep(segmentMinStep, segmentMaxStep, stepWeights, &rngState);
                    if (requestedStep == 1 && isHalfBeatGrid && segmentMaxStep > 1) {
                        // Half-beats always come in pairs.
                        forceNextHalfBeat = YES;
                    }
                }
                NSUInteger maxRemaining = sortedBoundaries.count - 1 - boundaryIndex;
                if ((NSUInteger)requestedStep > maxRemaining) requestedStep = (NSInteger)maxRemaining;

                double startSec = [sortedBoundaries[boundaryIndex] doubleValue];
                NSMutableArray<NSMutableDictionary *> *eligible = nil;
                double segmentDuration = 0.0;
                NSUInteger nextBoundaryIndex = NSNotFound;

                for (NSInteger step = requestedStep; step >= 1; step--) {
                    NSUInteger candidateNextIndex = MIN(sortedBoundaries.count - 1, boundaryIndex + (NSUInteger)step);
                    if (candidateNextIndex <= boundaryIndex) continue;

                    double candidateEndSec = [sortedBoundaries[candidateNextIndex] doubleValue];
                    double candidateDuration = candidateEndSec - startSec;
                    if (candidateDuration <= 0.0001) continue;

                    NSMutableArray<NSMutableDictionary *> *candidates = [NSMutableArray array];
                    for (NSMutableDictionary *candidate in clipPool) {
                        if (!allowClipReuse && [usedClipKeys containsObject:candidate[@"pointerKey"]]) continue;
                        if ([candidate[@"durationSeconds"] doubleValue] + 0.0001 < candidateDuration) continue;
                        [candidates addObject:candidate];
                    }
                    if (candidates.count > 0) {
                        eligible = candidates;
                        segmentDuration = candidateDuration;
                        nextBoundaryIndex = candidateNextIndex;
                        requestedStep = step;
                        break;
                    }
                }

                if (!eligible || nextBoundaryIndex == NSNotFound) {
                    NSUInteger fallbackNextIndex = MIN(sortedBoundaries.count - 1, boundaryIndex + 1);
                    if (fallbackNextIndex <= boundaryIndex) break;

                    gapCount++;
                    [plan addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                        @"segmentIndex": @(plan.count),
                        @"timelineStartSeconds": @(startSec),
                        @"durationSeconds": @([sortedBoundaries[fallbackNextIndex] doubleValue] - startSec),
                        @"clipName": [NSString stringWithFormat:@"Gap %lu", (unsigned long)(plan.count + 1)],
                        @"status": @"gap",
                    }]];
                    boundaryIndex = fallbackNextIndex;
                    if (maxSegments > 0 && (NSInteger)plan.count >= maxSegments) break;
                    continue;
                }

                NSMutableDictionary *chosen = nil;
                while (eligible.count > 0) {
                    NSUInteger choiceIndex = (NSUInteger)(SpliceKit_nextRandom(&rngState) % (uint64_t)eligible.count);
                    NSMutableDictionary *candidate = eligible[choiceIndex];
                    NSString *mediaURL = candidate[@"mediaURL"];
                    if (![mediaURL isKindOfClass:[NSString class]] || mediaURL.length == 0) {
                        NSString *resolved = SpliceKit_getMediaURLForClip(candidate[@"clip"]);
                        if (resolved.length > 0) {
                            if (sourceMediaURL.length > 0 && [resolved isEqualToString:sourceMediaURL]) {
                                [eligible removeObjectAtIndex:choiceIndex];
                                continue;
                            }
                            if (SpliceKit_mediaURLLooksAudioOnly(resolved)) {
                                [eligible removeObjectAtIndex:choiceIndex];
                                continue;
                            }
                            candidate[@"mediaURL"] = resolved;
                            mediaURL = resolved;
                        }
                    }

                    if ([buildMode isEqualToString:@"fcpxml"] && mediaURL.length == 0) {
                        [eligible removeObjectAtIndex:choiceIndex];
                        continue;
                    }

                    chosen = candidate;
                    break;
                }

                if (!chosen) {
                    gapCount++;
                    [plan addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                        @"segmentIndex": @(plan.count),
                        @"timelineStartSeconds": @(startSec),
                        @"durationSeconds": @(segmentDuration),
                        @"clipName": [NSString stringWithFormat:@"Gap %lu", (unsigned long)(plan.count + 1)],
                        @"status": @"gap",
                    }]];
                    boundaryIndex = nextBoundaryIndex;
                    if (maxSegments > 0 && (NSInteger)plan.count >= maxSegments) break;
                    continue;
                }

                if (!allowClipReuse) {
                    [usedClipKeys addObject:chosen[@"pointerKey"]];
                }

                double clipDuration = [chosen[@"durationSeconds"] doubleValue];
                double maxIn = MAX(0.0, clipDuration - segmentDuration);
                double inPoint = 0.0;
                if (maxIn > 0.0001) {
                    double unit = (double)(SpliceKit_nextRandom(&rngState) % 1000000ULL) / 1000000.0;
                    inPoint = unit * maxIn;
                }

                assignedClipCount++;
                [plan addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                    @"segmentIndex": @(plan.count),
                    @"timelineStartSeconds": @(startSec),
                    @"durationSeconds": @(segmentDuration),
                    @"clipHandle": chosen[@"handle"] ?: @"",
                    @"clipName": chosen[@"name"] ?: @"Clip",
                    @"clipEvent": chosen[@"event"] ?: @"",
                    @"inSeconds": @(inPoint),
                    @"outSeconds": @(inPoint + segmentDuration),
                    @"mediaURL": chosen[@"mediaURL"] ?: @"",
                    @"step": @(requestedStep),
                    @"status": @"planned",
                }]];
                boundaryIndex = nextBoundaryIndex;
                if (maxSegments > 0 && (NSInteger)plan.count >= maxSegments) break;
            }

            if (plan.count == 0) {
                result = @{@"error": @"Unable to derive any assembly segments from the beat map"};
                return;
            }
            if (gapCount > 0) {
                result = @{@"error": @"Could not cover the full song length with the current clip pool at the requested pacing. Use shorter spans or provide longer video clips."};
                return;
            }

            NSString *destinationProjectName = targetCurrentTimeline
                ? (SpliceKit_displayNameForItem(sequence).length > 0 ? SpliceKit_displayNameForItem(sequence) : projectName)
                : projectName;

            if (dryRun) {
                result = @{
                    @"status": @"ok",
                    @"dryRun": @YES,
                    @"buildMethod": buildMode,
                    @"grid": grid,
                    @"projectName": destinationProjectName,
                    @"randomSeed": @(randomSeed),
                    @"segmentMinStep": @(segmentMinStep),
                    @"segmentMaxStep": @(segmentMaxStep),
                    @"allowClipReuse": @(allowClipReuse),
                    @"targetCurrentTimeline": @(targetCurrentTimeline),
                    @"source": @{
                        @"handle": SpliceKit_storeHandle(sourceItem),
                        @"name": sourceEntry[@"name"] ?: @"",
                        @"tempo": @(tempo),
                        @"duration": @(sourceDuration),
                    },
                    @"segmentCount": @(plan.count),
                    @"assignedClipCount": @(assignedClipCount),
                    @"gapCount": @(gapCount),
                    @"clipPoolCount": @(clipPool.count),
                    @"plan": plan,
                };
                return;
            }

            double frameSeconds = SpliceKit_secondsFromTime(frameDuration);
            if (!isfinite(frameSeconds) || frameSeconds <= 0.000001) {
                frameSeconds = 1.0 / 24.0;
            }

            // Quantize each segment's offset from its ORIGINAL beat boundary time
            // to prevent cumulative rounding drift across hundreds of segments.
            long long totalDurationFrames = 0;
            for (NSMutableDictionary *entry in plan) {
                double startSeconds = [entry[@"timelineStartSeconds"] doubleValue];
                double endSeconds = startSeconds + [entry[@"durationSeconds"] doubleValue];
                long long startFrames = MAX(0LL, llround(startSeconds / frameSeconds));
                long long endFrames = MAX(startFrames + 1, llround(endSeconds / frameSeconds));
                long long durationFrames = endFrames - startFrames;

                entry[@"timelineOffsetFrames"] = @(startFrames);
                entry[@"durationFrames"] = @(durationFrames);
                totalDurationFrames = endFrames;

                NSNumber *inSecondsValue = entry[@"inSeconds"];
                if (inSecondsValue) {
                    long long inFrames = MAX(0LL, llround([inSecondsValue doubleValue] / frameSeconds));
                    entry[@"inFrames"] = @(inFrames);
                }
            }

            id targetEvent = nil;
            NSString *targetEventName = @"";
            if (!targetCurrentTimeline) {
                targetEvent = SpliceKit_findAssemblyEvent((NSArray *)events, eventName);
                if (!targetEvent) {
                    result = @{@"error": @"Couldn't find a target event for project creation"};
                    return;
                }
                targetEventName = SpliceKit_displayNameForItem(targetEvent) ?: @"SpliceKit Tests";
            }
            NSString *songMediaURLForBuild = sourceMediaURL.length > 0
                ? sourceMediaURL
                : (sourceInsertObject ? (SpliceKit_getMediaURLForClip(sourceInsertObject) ?: @"") : @"");

            if ([buildMode isEqualToString:@"fcpxml"]) {
                NSString *fcpxmlError = nil;
                NSString *xml = SpliceKit_buildRandomClipAssemblyFCPXML(
                    plan,
                    destinationProjectName,
                    targetEventName,
                    frameDuration,
                    includeAudio ? songMediaURLForBuild : @"",
                    totalDurationFrames,
                    &fcpxmlError);
                if (xml.length == 0) {
                    result = @{@"error": fcpxmlError ?: @"Failed to build the song-cut FCPXML document"};
                    return;
                }

                NSDictionary *importResult = SpliceKit_handleFCPXMLImport(@{
                    @"xml": xml,
                    @"internal": @YES,
                }) ?: @{};
                if ([importResult[@"error"] isKindOfClass:[NSString class]]) {
                    result = @{@"error": importResult[@"error"]};
                    return;
                }

                result = @{
                    @"status": @"ok",
                    @"dryRun": @NO,
                    @"grid": grid,
                    @"projectName": destinationProjectName,
                    @"randomSeed": @(randomSeed),
                    @"segmentMinStep": @(segmentMinStep),
                    @"segmentMaxStep": @(segmentMaxStep),
                    @"allowClipReuse": @(allowClipReuse),
                    @"targetCurrentTimeline": @NO,
                    @"source": @{
                        @"handle": SpliceKit_storeHandle(sourceItem),
                        @"name": sourceEntry[@"name"] ?: @"",
                        @"tempo": @(tempo),
                        @"duration": @(sourceDuration),
                    },
                    @"segmentCount": @(plan.count),
                    @"assignedClipCount": @(assignedClipCount),
                    @"appliedClipCount": @(assignedClipCount),
                    @"failedSegmentCount": @0,
                    @"omittedSegmentCount": @0,
                    @"gapCount": @0,
                    @"clipPoolCount": @(clipPool.count),
                    @"buildMethod": @"fcpxml",
                    @"projectFound": @YES,
                    @"projectLoaded": @NO,
                    @"fcpxmlImport": importResult,
                    @"songAudioInserted": @(includeAudio && songMediaURLForBuild.length > 0),
                    @"songAudioError": (includeAudio && songMediaURLForBuild.length == 0)
                        ? @"The selected song could not be resolved to a media URL for the FCPXML build"
                        : @"",
                    @"projectHandle": @"",
                    @"plan": plan,
                };
                return;
            }

            NSDictionary *nativeProject = targetCurrentTimeline
                ? @{
                    @"ok": @YES,
                    @"loaded": @YES,
                    @"sequence": sequence,
                    @"sequenceHandle": SpliceKit_storeHandle(sequence) ?: @"",
                    @"createdObjectClass": @"",
                    @"eventName": @"",
                    @"reusedCurrentTimeline": @YES,
                }
                : (SpliceKit_createNativeProjectSequence(destinationProjectName, targetEvent) ?: @{});
            NSMutableDictionary *nativeProjectResult = [nativeProject mutableCopy];
            [nativeProjectResult removeObjectForKey:@"sequence"];
            id importedSequence = nativeProject[@"sequence"];
            BOOL loadedSequence = [nativeProject[@"loaded"] boolValue];
            id buildTimeline = targetCurrentTimeline ? timeline : nil;

            if (targetCurrentTimeline) {
                if (activeVisibleEntries.count > 0) {
                    result = @{@"error": @"targetCurrentTimeline requires the active timeline to be empty before assembly"};
                    return;
                }
            } else if (loadedSequence) {
                for (int attempt = 0; attempt < 40; attempt++) {
                    [[NSRunLoop currentRunLoop] runUntilDate:
                        [NSDate dateWithTimeIntervalSinceNow:0.1]];
                    buildTimeline = SpliceKit_getActiveTimelineModule();
                    if (!buildTimeline) continue;
                    id activeSequence = [buildTimeline respondsToSelector:@selector(sequence)]
                        ? ((id (*)(id, SEL))objc_msgSend)(buildTimeline, @selector(sequence))
                        : nil;
                    NSString *activeName = [activeSequence respondsToSelector:@selector(displayName)]
                        ? ((id (*)(id, SEL))objc_msgSend)(activeSequence, @selector(displayName))
                        : nil;
                    if (activeName.length > 0 && [activeName isEqualToString:destinationProjectName]) {
                        break;
                    }
                    buildTimeline = nil;
                }
            }

            NSUInteger omittedSegments = 0;
            NSUInteger appliedSegments = 0;
            NSUInteger failedSegments = 0;
            long long builtDurationFrames = 0;
            NSMutableDictionary *nativeErrors = [NSMutableDictionary dictionary];

            id buildSequence = (buildTimeline && [buildTimeline respondsToSelector:@selector(sequence)])
                ? ((id (*)(id, SEL))objc_msgSend)(buildTimeline, @selector(sequence))
                : nil;
            NSString *assembleUndoName = @"Assemble to Beats";
            BOOL openedAssembleUndo = NO;
            if (loadedSequence && buildTimeline && buildSequence) {
                openedAssembleUndo = SpliceKit_internalBeginEditGroupIfNeeded(buildSequence, assembleUndoName);
            }

            BOOL songAudioInserted = NO;
            NSString *songAudioError = @"";
            NSDictionary *songAudioPrep = @{};
            NSDictionary *songAudioEdit = @{};

            @try {
            if (loadedSequence && buildTimeline) {
                for (NSMutableDictionary *entry in plan) {
                    if ([entry[@"status"] isEqualToString:@"gap"]) {
                        entry[@"status"] = @"omitted";
                        entry[@"reason"] = entry[@"reason"] ?: @"No eligible browser clip was available for this beat span";
                        omittedSegments++;
                        continue;
                    }

                    NSString *clipHandle = [entry[@"clipHandle"] isKindOfClass:[NSString class]] ? entry[@"clipHandle"] : @"";
                    id sourceClip = clipHandle.length > 0 ? SpliceKit_resolveHandle(clipHandle) : nil;
                    if (!sourceClip) {
                        entry[@"status"] = @"failed";
                        entry[@"reason"] = @"Source clip handle could not be resolved";
                        failedSegments++;
                        continue;
                    }

                    SpliceKit_CMTimeRange sourceClipRange = SpliceKit_clipRangeForItem(sourceClip);
                    int32_t segmentTimescale = sourceClipRange.start.timescale > 0
                        ? sourceClipRange.start.timescale
                        : (sourceClipRange.duration.timescale > 0
                            ? sourceClipRange.duration.timescale
                            : (frameDuration.timescale > 0 ? frameDuration.timescale : 6000));
                    double inSeconds = [entry[@"inFrames"] longLongValue] * frameSeconds;
                    double durationSeconds = [entry[@"durationFrames"] longLongValue] * frameSeconds;
                    SpliceKit_CMTimeRange segmentRange = sourceClipRange;
                    segmentRange.start = SpliceKit_addSecondsToCMTime(sourceClipRange.start, inSeconds);
                    segmentRange.duration = SpliceKit_makeCMTimeWithTimescale(durationSeconds, segmentTimescale);

                    NSDictionary *sourcePrep = SpliceKit_prepareBrowserClipSourceForInsertion(sourceClip, segmentRange, NO) ?: @{};
                    if (![sourcePrep[@"ok"] boolValue]) {
                        entry[@"status"] = @"failed";
                        entry[@"reason"] = [sourcePrep[@"error"] isKindOfClass:[NSString class]]
                            ? sourcePrep[@"error"] : @"Failed to prepare the browser clip segment";
                        failedSegments++;
                        continue;
                    }

                    NSDictionary *editDiag = SpliceKit_performPreparedMediaEdit(
                        buildTimeline,
                        2,
                        NO,
                        @"all",
                        NO,
                        SpliceKit_makeCMTimeWithTimescale(0.0, frameDuration.timescale));
                    if (![editDiag[@"ok"] boolValue]) {
                        entry[@"status"] = @"failed";
                        entry[@"reason"] = [editDiag[@"error"] isKindOfClass:[NSString class]]
                            ? editDiag[@"error"] : @"Native append edit failed";
                        failedSegments++;
                        continue;
                    }

                    entry[@"status"] = @"applied";
                    entry[@"nativeAction"] = @"appendWithSelectedMedia:";
                    builtDurationFrames += [entry[@"durationFrames"] longLongValue];
                    appliedSegments++;
                }
            } else {
                nativeErrors[@"project"] = [nativeProject[@"error"] isKindOfClass:[NSString class]]
                    ? nativeProject[@"error"] : @"Failed to create or load the native target project";
            }

            if (loadedSequence && buildTimeline && includeAudio && sourceInsertObject && builtDurationFrames > 0) {
                double targetSongSeconds = MIN(sourceDuration, builtDurationFrames * frameSeconds);
                int32_t songTimescale = sourceClipRange.duration.timescale > 0
                    ? sourceClipRange.duration.timescale
                    : (frameDuration.timescale > 0 ? frameDuration.timescale : 6000);
                SpliceKit_CMTimeRange songInsertRange = sourceClipRange;
                songInsertRange.duration = SpliceKit_makeCMTimeWithTimescale(targetSongSeconds, songTimescale);

                songAudioPrep = SpliceKit_prepareBrowserClipSourceForInsertion(sourceInsertObject, songInsertRange, YES) ?: @{};
                if (![songAudioPrep[@"ok"] boolValue]) {
                    songAudioError = [songAudioPrep[@"error"] isKindOfClass:[NSString class]]
                        ? songAudioPrep[@"error"] : @"Could not prepare the source song for insertion";
                } else {
                    SpliceKit_CMTime zero = SpliceKit_makeCMTimeWithTimescale(0.0, frameDuration.timescale);
                    songAudioEdit = SpliceKit_performPreparedMediaEdit(
                        buildTimeline,
                        3,
                        NO,
                        @"audio",
                        YES,
                        zero) ?: @{};
                    songAudioInserted = [songAudioEdit[@"ok"] boolValue];
                    if (!songAudioInserted) {
                        songAudioError = [songAudioEdit[@"error"] isKindOfClass:[NSString class]]
                            ? songAudioEdit[@"error"] : @"Native song connect edit failed";
                    } else {
                        SEL setPlayheadSel = NSSelectorFromString(@"setPlayheadTime:");
                        if ([buildTimeline respondsToSelector:setPlayheadSel]) {
                            ((void (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(buildTimeline, setPlayheadSel, zero);
                        }
                        SEL commitSel = NSSelectorFromString(@"setCommittedPlayheadTime:");
                        if ([buildTimeline respondsToSelector:commitSel]) {
                            ((void (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(buildTimeline, commitSel, zero);
                        }
                    }
                }
            } else if (includeAudio && !sourceInsertObject) {
                songAudioError = @"Couldn't resolve the selected beat source song for native insertion";
            } else if (includeAudio && builtDurationFrames <= 0) {
                songAudioError = @"No video segments were appended, so the song was not connected";
            }
            } @finally {
                if (openedAssembleUndo) {
                    SpliceKit_internalEndEditGroupIfOpened(buildSequence, buildTimeline, assembleUndoName, YES);
                }
            }

            result = @{
                @"status": @"ok",
                @"dryRun": @NO,
                @"grid": grid,
                @"projectName": destinationProjectName,
                @"randomSeed": @(randomSeed),
                @"segmentMinStep": @(segmentMinStep),
                @"segmentMaxStep": @(segmentMaxStep),
                @"allowClipReuse": @(allowClipReuse),
                @"targetCurrentTimeline": @(targetCurrentTimeline),
                @"source": @{
                    @"handle": SpliceKit_storeHandle(sourceItem),
                    @"name": sourceEntry[@"name"] ?: @"",
                    @"tempo": @(tempo),
                    @"duration": @(sourceDuration),
                },
                @"segmentCount": @(plan.count),
                @"assignedClipCount": @(assignedClipCount),
                @"appliedClipCount": @(appliedSegments),
                @"failedSegmentCount": @(failedSegments),
                @"omittedSegmentCount": @(omittedSegments),
                @"gapCount": @0,
                @"clipPoolCount": @(clipPool.count),
                @"buildMethod": buildMode,
                @"projectFound": @(importedSequence != nil),
                @"projectLoaded": @(loadedSequence && buildTimeline != nil),
                @"nativeProject": nativeProjectResult ?: @{},
                @"nativeErrors": nativeErrors,
                @"songAudioInserted": @(songAudioInserted),
                @"songAudioError": songAudioError ?: @"",
                @"songAudioPrep": songAudioPrep ?: @{},
                @"songAudioEdit": songAudioEdit ?: @{},
                @"projectHandle": importedSequence ? SpliceKit_storeHandle(importedSequence) : @"",
                @"plan": plan,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result ?: @{@"error": @"Failed to assemble random clips to song beats"};
}

// ---------- 1. flexmusic.listSongs ----------

static BOOL SpliceKit_flexMusicCollectionIsEmpty(id collection) {
    if (!collection) return YES;
    if ([collection isKindOfClass:[NSArray class]]) return [(NSArray *)collection count] == 0;
    if ([collection isKindOfClass:[NSSet class]]) return [(NSSet *)collection count] == 0;
    if ([collection isKindOfClass:[NSDictionary class]]) return [(NSDictionary *)collection count] == 0;
    return YES;
}

static NSArray *SpliceKit_flexMusicNormalizeSongCollection(id collection) {
    if (!collection) return nil;
    if ([collection isKindOfClass:[NSArray class]]) return (NSArray *)collection;
    if ([collection isKindOfClass:[NSSet class]]) return [(NSSet *)collection allObjects];
    if ([collection isKindOfClass:[NSDictionary class]]) return [(NSDictionary *)collection allValues];
    return nil;
}

NSDictionary *SpliceKit_handleFlexMusicListSongs(NSDictionary *params) {
    NSString *filter = params[@"filter"];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id library = SpliceKit_getFlexMusicLibrary();
            if (!library) {
                result = @{@"error": @"FMSongLibrary not available (FlexMusicKit framework not loaded)"};
                return;
            }

            // Try multiple selectors to get songs
            id songs = nil;

            // 1. bundledSongs — locally available songs
            SEL bundledSel = NSSelectorFromString(@"bundledSongs");
            if ([library respondsToSelector:bundledSel]) {
                songs = ((id (*)(id, SEL))objc_msgSend)(library, bundledSel);
            }

            // 2. fetchSongsWithOptions: — returns array directly (synchronous)
            if (SpliceKit_flexMusicCollectionIsEmpty(songs)) {
                SEL fetchSel = NSSelectorFromString(@"fetchSongsWithOptions:");
                if ([library respondsToSelector:fetchSel]) {
                    Class fetchOptClass = objc_getClass("FMFetchOptions");
                    id fetchOpts = nil;
                    if (fetchOptClass) {
                        fetchOpts = ((id (*)(id, SEL))objc_msgSend)(
                            ((id (*)(id, SEL))objc_msgSend)((id)fetchOptClass, @selector(alloc)),
                            @selector(init));
                    }
                    id fetched = ((id (*)(id, SEL, id))objc_msgSend)(library, fetchSel, fetchOpts);
                    if (fetched && [fetched isKindOfClass:[NSArray class]]) {
                        songs = fetched;
                    }
                }
            }

            // 3. Try generic accessors
            if (SpliceKit_flexMusicCollectionIsEmpty(songs)) {
                for (NSString *selName in @[@"songs", @"availableSongs", @"allSongs"]) {
                    SEL sel = NSSelectorFromString(selName);
                    if ([library respondsToSelector:sel]) {
                        id result2 = ((id (*)(id, SEL))objc_msgSend)(library, sel);
                        if (result2 && [result2 isKindOfClass:[NSArray class]] && [(NSArray *)result2 count] > 0) {
                            songs = result2;
                            break;
                        }
                    }
                }
            }

            // Also try FFFlexMusicLibrary from Flexo as fallback
            if (SpliceKit_flexMusicCollectionIsEmpty(songs)) {
                Class ffFlexLib = objc_getClass("FFFlexMusicLibrary");
                if (ffFlexLib) {
                    SEL sharedSel = NSSelectorFromString(@"sharedLibrary");
                    if ([ffFlexLib respondsToSelector:sharedSel]) {
                        id ffLib = ((id (*)(id, SEL))objc_msgSend)((id)ffFlexLib, sharedSel);
                        if (ffLib) {
                            SEL fSongsSel = NSSelectorFromString(@"songs");
                            if ([ffLib respondsToSelector:fSongsSel]) {
                                songs = ((id (*)(id, SEL))objc_msgSend)(ffLib, fSongsSel);
                            }
                        }
                    }
                }
            }

            NSArray *songArray = SpliceKit_flexMusicNormalizeSongCollection(songs);
            if (!songArray) {
                result = @{@"error": @"Could not retrieve songs from FMSongLibrary",
                           @"libraryClass": NSStringFromClass([library class])};
                return;
            }

            NSMutableArray *songList = [NSMutableArray array];
            for (id song in songArray) {
                @autoreleasepool {
                    NSMutableDictionary *info = [NSMutableDictionary dictionary];

                    // UID / identifier
                    SEL uidSel = NSSelectorFromString(@"songUID");
                    SEL idSel = NSSelectorFromString(@"identifier");
                    NSString *uid = nil;
                    if ([song respondsToSelector:uidSel]) {
                        uid = ((id (*)(id, SEL))objc_msgSend)(song, uidSel);
                    } else if ([song respondsToSelector:idSel]) {
                        uid = ((id (*)(id, SEL))objc_msgSend)(song, idSel);
                    }
                    if (uid) info[@"uid"] = uid;

                    // Name
                    SEL nameSel = NSSelectorFromString(@"name");
                    SEL dispSel = @selector(displayName);
                    NSString *name = nil;
                    if ([song respondsToSelector:nameSel]) {
                        name = ((id (*)(id, SEL))objc_msgSend)(song, nameSel);
                    } else if ([song respondsToSelector:dispSel]) {
                        name = ((id (*)(id, SEL))objc_msgSend)(song, dispSel);
                    }
                    if (name) info[@"name"] = name;

                    // Metadata
                    SEL metaSel = NSSelectorFromString(@"metadata");
                    if ([song respondsToSelector:metaSel]) {
                        id metadata = ((id (*)(id, SEL))objc_msgSend)(song, metaSel);
                        if (metadata) {
                            SEL artistSel = NSSelectorFromString(@"artistName");
                            if ([metadata respondsToSelector:artistSel]) {
                                id artist = ((id (*)(id, SEL))objc_msgSend)(metadata, artistSel);
                                if (artist) info[@"artist"] = artist;
                            }
                            SEL genreSel = NSSelectorFromString(@"genres");
                            if ([metadata respondsToSelector:genreSel]) {
                                id genres = ((id (*)(id, SEL))objc_msgSend)(metadata, genreSel);
                                if (genres) info[@"genres"] = genres;
                            }
                        }
                    }

                    // Duration
                    SEL durSel = NSSelectorFromString(@"naturalDuration");
                    if ([song respondsToSelector:durSel]) {
                        SpliceKit_CMTime dur = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(song, durSel);
                        info[@"durationSeconds"] = @(SpliceKit_cmtimeToSeconds(dur));
                    }

                    // Filter
                    if (filter.length > 0) {
                        NSString *lowerFilter = [filter lowercaseString];
                        NSString *nameStr = info[@"name"] ?: @"";
                        NSString *artistStr = info[@"artist"] ?: @"";
                        BOOL matches = [[nameStr lowercaseString] containsString:lowerFilter] ||
                                       [[artistStr lowercaseString] containsString:lowerFilter];
                        if (!matches) continue;
                    }

                    // Store handle
                    NSString *handle = SpliceKit_storeHandle(song);
                    info[@"handle"] = handle;

                    [songList addObject:info];
                }
            }

            result = @{@"songs": songList, @"count": @(songList.count)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to list songs"};
}

// ---------- 2. flexmusic.getSong ----------

NSDictionary *SpliceKit_handleFlexMusicGetSong(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *handle = params[@"handle"];
    if (!songUID && !handle) return @{@"error": @"songUID or handle parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id song = nil;

            // Resolve by handle first
            if (handle) {
                song = SpliceKit_resolveHandle(handle);
            }

            // Resolve by UID via library
            if (!song && songUID) {
                id library = SpliceKit_getFlexMusicLibrary();
                if (library) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([library respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(library, forUIDSel, songUID);
                    }
                }
                // Try FFFlexMusicLibrary fallback
                if (!song) {
                    Class ffFlexLib = objc_getClass("FFFlexMusicLibrary");
                    if (ffFlexLib) {
                        SEL sharedSel = NSSelectorFromString(@"sharedLibrary");
                        if ([ffFlexLib respondsToSelector:sharedSel]) {
                            id ffLib = ((id (*)(id, SEL))objc_msgSend)((id)ffFlexLib, sharedSel);
                            if (ffLib) {
                                SEL fForUIDSel = NSSelectorFromString(@"songForUID:");
                                if ([ffLib respondsToSelector:fForUIDSel]) {
                                    song = ((id (*)(id, SEL, id))objc_msgSend)(ffLib, fForUIDSel, songUID);
                                }
                            }
                        }
                    }
                }
            }

            if (!song) {
                result = @{@"error": @"Song not found"};
                return;
            }

            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"class"] = NSStringFromClass([song class]);

            // UID
            SEL uidSel = NSSelectorFromString(@"songUID");
            SEL idSel = NSSelectorFromString(@"identifier");
            if ([song respondsToSelector:uidSel]) {
                id uid = ((id (*)(id, SEL))objc_msgSend)(song, uidSel);
                if (uid) info[@"uid"] = uid;
            } else if ([song respondsToSelector:idSel]) {
                id uid = ((id (*)(id, SEL))objc_msgSend)(song, idSel);
                if (uid) info[@"uid"] = uid;
            }

            // Name
            SEL nameSel = NSSelectorFromString(@"name");
            if ([song respondsToSelector:nameSel]) {
                id name = ((id (*)(id, SEL))objc_msgSend)(song, nameSel);
                if (name) info[@"name"] = name;
            }

            // Metadata
            SEL metaSel = NSSelectorFromString(@"metadata");
            if ([song respondsToSelector:metaSel]) {
                id metadata = ((id (*)(id, SEL))objc_msgSend)(song, metaSel);
                if (metadata) {
                    NSMutableDictionary *meta = [NSMutableDictionary dictionary];

                    SEL artistSel = NSSelectorFromString(@"artistName");
                    if ([metadata respondsToSelector:artistSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, artistSel);
                        if (v) meta[@"artist"] = v;
                    }
                    SEL moodSel = NSSelectorFromString(@"mood");
                    if ([metadata respondsToSelector:moodSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, moodSel);
                        if (v) meta[@"mood"] = v;
                    }
                    SEL paceSel = NSSelectorFromString(@"pace");
                    if ([metadata respondsToSelector:paceSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, paceSel);
                        if (v) meta[@"pace"] = v;
                    }
                    SEL genreSel = NSSelectorFromString(@"genres");
                    if ([metadata respondsToSelector:genreSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, genreSel);
                        if (v) meta[@"genres"] = v;
                    }
                    SEL arousalSel = NSSelectorFromString(@"arousal");
                    if ([metadata respondsToSelector:arousalSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, arousalSel);
                        if (v) meta[@"arousal"] = v;
                    }
                    SEL valenceSel = NSSelectorFromString(@"valence");
                    if ([metadata respondsToSelector:valenceSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, valenceSel);
                        if (v) meta[@"valence"] = v;
                    }

                    info[@"metadata"] = meta;
                }
            }

            // Durations
            SEL natDurSel = NSSelectorFromString(@"naturalDuration");
            if ([song respondsToSelector:natDurSel]) {
                SpliceKit_CMTime dur = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(song, natDurSel);
                info[@"naturalDurationSeconds"] = @(SpliceKit_cmtimeToSeconds(dur));
            }
            SEL minDurSel = NSSelectorFromString(@"minimumDuration");
            if ([song respondsToSelector:minDurSel]) {
                SpliceKit_CMTime dur = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(song, minDurSel);
                info[@"minimumDurationSeconds"] = @(SpliceKit_cmtimeToSeconds(dur));
            }
            SEL idealSel = NSSelectorFromString(@"idealDurations");
            if ([song respondsToSelector:idealSel]) {
                id ideals = ((id (*)(id, SEL))objc_msgSend)(song, idealSel);
                if ([ideals isKindOfClass:[NSArray class]]) {
                    info[@"idealDurations"] = ideals;
                }
            }

            // Song format
            SEL fmtSel = NSSelectorFromString(@"songFormat");
            if ([song respondsToSelector:fmtSel]) {
                id fmt = ((id (*)(id, SEL))objc_msgSend)(song, fmtSel);
                if (fmt) info[@"songFormat"] = fmt;
            }

            // Store handle
            NSString *h = SpliceKit_storeHandle(song);
            info[@"handle"] = h;

            result = info;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to get song"};
}

// ---------- 3. flexmusic.getTiming ----------

NSDictionary *SpliceKit_handleFlexMusicGetTiming(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *handle = params[@"handle"];
    NSNumber *durationSecondsNum = params[@"durationSeconds"];
    if (!songUID && !handle) return @{@"error": @"songUID or handle parameter required"};
    if (!durationSecondsNum) return @{@"error": @"durationSeconds parameter required"};

    double durationSeconds = [durationSecondsNum doubleValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // Resolve song
            id song = nil;
            if (handle) {
                song = SpliceKit_resolveHandle(handle);
            }
            if (!song && songUID) {
                id library = SpliceKit_getFlexMusicLibrary();
                if (library) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([library respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(library, forUIDSel, songUID);
                    }
                }
            }
            if (!song) {
                result = @{@"error": @"Song not found"};
                return;
            }

            SpliceKit_CMTime durTime = SpliceKit_cmtimeFromSeconds(durationSeconds);

            // Get options for duration - try FFAnchoredFlexMusicObject first
            id options = nil;
            Class ffFlexObj = objc_getClass("FFAnchoredFlexMusicObject");
            if (ffFlexObj) {
                SEL optSel = NSSelectorFromString(@"optionsForDuration:");
                if ([ffFlexObj respondsToSelector:optSel]) {
                    options = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        (id)ffFlexObj, optSel, durTime);
                }
            }
            if (!options) {
                // Build options manually
                NSMutableDictionary *opts = [NSMutableDictionary dictionary];
                // Look up option constants via dlsym
                NSString *loopOpt = SpliceKit_flexMusicConstant("FMSong_Option_LoopSongForLongDurations");
                NSString *outroOpt = SpliceKit_flexMusicConstant("FMSong_Option_OutroCanBeShortened");
                if (loopOpt) opts[loopOpt] = @YES;
                if (outroOpt) opts[outroOpt] = @YES;
                options = opts;
            }

            // Get rendition
            id rendition = nil;
            SEL rendSel = NSSelectorFromString(@"renditionForDuration:withOptions:");
            if ([song respondsToSelector:rendSel]) {
                rendition = ((id (*)(id, SEL, SpliceKit_CMTime, id))objc_msgSend)(
                    song, rendSel, durTime, options);
            }
            if (!rendition) {
                // Try simpler renditionForDuration:
                SEL rendSel2 = NSSelectorFromString(@"renditionForDuration:");
                if ([song respondsToSelector:rendSel2]) {
                    rendition = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        song, rendSel2, durTime);
                }
            }
            if (!rendition) {
                result = @{@"error": @"Could not get rendition for specified duration"};
                return;
            }

            NSString *rendHandle = SpliceKit_storeHandle(rendition);
            NSMutableDictionary *timing = [NSMutableDictionary dictionary];
            timing[@"renditionHandle"] = rendHandle;
            timing[@"renditionClass"] = NSStringFromClass([rendition class]);

            // Get fitted duration from rendition
            SEL rendDurSel = NSSelectorFromString(@"duration");
            if ([rendition respondsToSelector:rendDurSel]) {
                SpliceKit_CMTime rd = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(rendition, rendDurSel);
                timing[@"fittedDurationSeconds"] = @(SpliceKit_cmtimeToSeconds(rd));
            }

            // Extract timed metadata using identifier constants
            NSString *beatId = SpliceKit_flexMusicConstant("FMTimedMetadataIdentifierBeat");
            NSString *barId = SpliceKit_flexMusicConstant("FMTimedMetadataIdentifierBar");
            NSString *sectionId = SpliceKit_flexMusicConstant("FMTimedMetadataIdentifierSection");
            NSString *segmentId = SpliceKit_flexMusicConstant("FMTimedMetadataIdentifierSegment");
            NSString *onsetId = SpliceKit_flexMusicConstant("FMTimedMetadataIdentifierOnset");

            SEL timedMetaSel = NSSelectorFromString(@"timedMetadataItemsWithIdentifier:");
            BOOL hasTimedMeta = [rendition respondsToSelector:timedMetaSel];

            // Helper block to extract time arrays from timed metadata
            NSArray *(^extractTimes)(NSString *) = ^NSArray *(NSString *identifier) {
                if (!identifier || !hasTimedMeta) return @[];
                id items = ((id (*)(id, SEL, id))objc_msgSend)(rendition, timedMetaSel, identifier);
                if (![items isKindOfClass:[NSArray class]]) return @[];
                NSMutableArray *times = [NSMutableArray array];
                for (id item in (NSArray *)items) {
                    SEL timeSel = NSSelectorFromString(@"time");
                    if ([item respondsToSelector:timeSel]) {
                        SpliceKit_CMTime t = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(item, timeSel);
                        [times addObject:@(SpliceKit_cmtimeToSeconds(t))];
                    }
                }
                return times;
            };

            timing[@"beats"] = extractTimes(beatId);
            timing[@"bars"] = extractTimes(barId);
            timing[@"sections"] = extractTimes(sectionId);
            timing[@"segments"] = extractTimes(segmentId);
            timing[@"onsets"] = extractTimes(onsetId);

            // Also try FFFlexMusicTimingMetadata if direct timed metadata is empty
            if ([timing[@"beats"] count] == 0) {
                Class ffTimingClass = objc_getClass("FFFlexMusicTimingMetadata");
                if (ffTimingClass) {
                    SEL initRendSel = NSSelectorFromString(@"initWithSongRendition:clippedRange:");
                    if ([ffTimingClass instancesRespondToSelector:initRendSel]) {
                        // Full range
                        SpliceKit_CMTime start = {0, 600, 1, 0};
                        SpliceKit_CMTimeRange fullRange = {start, durTime};

                        id tmObj = ((id (*)(id, SEL))objc_msgSend)((id)ffTimingClass, @selector(alloc));
                        tmObj = ((id (*)(id, SEL, id, SpliceKit_CMTimeRange))objc_msgSend)(
                            tmObj, initRendSel, rendition, fullRange);

                        if (tmObj) {
                            SEL newMetaSel = NSSelectorFromString(@"newTimingMetadataForType:");
                            if ([tmObj respondsToSelector:newMetaSel]) {
                                // Type 1 = beats, 2 = bars, 4 = sections
                                int types[] = {1, 2, 4};
                                NSString *keys[] = {@"beats", @"bars", @"sections"};
                                for (int i = 0; i < 3; i++) {
                                    id metaItems = ((id (*)(id, SEL, int))objc_msgSend)(
                                        tmObj, newMetaSel, types[i]);
                                    if ([metaItems isKindOfClass:[NSArray class]]) {
                                        NSMutableArray *times = [NSMutableArray array];
                                        for (id item in (NSArray *)metaItems) {
                                            SEL timeSel2 = NSSelectorFromString(@"time");
                                            if ([item respondsToSelector:timeSel2]) {
                                                SpliceKit_CMTime t = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(item, timeSel2);
                                                [times addObject:@(SpliceKit_cmtimeToSeconds(t))];
                                            }
                                        }
                                        if (times.count > 0) timing[keys[i]] = times;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Report available identifiers
            NSMutableArray *availableIds = [NSMutableArray array];
            if (beatId) [availableIds addObject:@"beat"];
            if (barId) [availableIds addObject:@"bar"];
            if (sectionId) [availableIds addObject:@"section"];
            if (segmentId) [availableIds addObject:@"segment"];
            if (onsetId) [availableIds addObject:@"onset"];
            timing[@"availableIdentifiers"] = availableIds;

            result = timing;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to get timing"};
}

// ---------- 4. flexmusic.renderToFile ----------

NSDictionary *SpliceKit_handleFlexMusicRender(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *handle = params[@"handle"];
    NSNumber *durationSecondsNum = params[@"durationSeconds"];
    NSString *outputPath = params[@"outputPath"];
    NSString *format = params[@"format"] ?: @"m4a";

    if (!songUID && !handle) return @{@"error": @"songUID or handle parameter required"};
    if (!durationSecondsNum) return @{@"error": @"durationSeconds parameter required"};

    double durationSeconds = [durationSecondsNum doubleValue];

    // Generate output path if not provided
    if (!outputPath) {
        NSString *ext = [format isEqualToString:@"wav"] ? @"wav" : @"m4a";
        outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"splicekit_flexmusic_%@.%@",
             [[NSUUID UUID] UUIDString], ext]];
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // Resolve song
            id song = nil;
            if (handle) {
                song = SpliceKit_resolveHandle(handle);
            }
            if (!song && songUID) {
                id library = SpliceKit_getFlexMusicLibrary();
                if (library) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([library respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(library, forUIDSel, songUID);
                    }
                }
            }
            if (!song) {
                result = @{@"error": @"Song not found"};
                return;
            }

            SpliceKit_CMTime durTime = SpliceKit_cmtimeFromSeconds(durationSeconds);

            // Get rendition
            id rendition = nil;
            SEL rendSel = NSSelectorFromString(@"renditionForDuration:withOptions:");
            id options = nil;
            Class ffFlexObj = objc_getClass("FFAnchoredFlexMusicObject");
            if (ffFlexObj) {
                SEL optSel = NSSelectorFromString(@"optionsForDuration:");
                if ([ffFlexObj respondsToSelector:optSel]) {
                    options = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        (id)ffFlexObj, optSel, durTime);
                }
            }
            if (!options) options = @{};

            if ([song respondsToSelector:rendSel]) {
                rendition = ((id (*)(id, SEL, SpliceKit_CMTime, id))objc_msgSend)(
                    song, rendSel, durTime, options);
            }
            if (!rendition) {
                SEL rendSel2 = NSSelectorFromString(@"renditionForDuration:");
                if ([song respondsToSelector:rendSel2]) {
                    rendition = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        song, rendSel2, durTime);
                }
            }
            if (!rendition) {
                result = @{@"error": @"Could not get rendition for export"};
                return;
            }

            // Get AVComposition and AVAudioMix from rendition
            SEL compSel = NSSelectorFromString(@"avCompositionWithAudioMix:includeShortenedOutroFadeOut:");
            id composition = nil;
            id audioMix = nil;

            if ([rendition respondsToSelector:compSel]) {
                // audioMix is passed by reference (AVAudioMix **)
                __unsafe_unretained id mixRef = nil;
                composition = ((id (*)(id, SEL, __unsafe_unretained id *, BOOL))objc_msgSend)(
                    rendition, compSel, &mixRef, YES);
                audioMix = mixRef;
            }

            // Fallback: try avComposition directly
            if (!composition) {
                SEL simpleCompSel = NSSelectorFromString(@"avComposition");
                if ([rendition respondsToSelector:simpleCompSel]) {
                    composition = ((id (*)(id, SEL))objc_msgSend)(rendition, simpleCompSel);
                }
            }

            if (!composition) {
                result = @{@"error": @"Could not get AVComposition from rendition"};
                return;
            }

            // Remove existing file if any
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

            // Create AVAssetExportSession
            Class exportClass = objc_getClass("AVAssetExportSession");
            SEL exportInitSel = NSSelectorFromString(@"exportSessionWithAsset:presetName:");
            NSString *preset = @"AVAssetExportPresetAppleM4A";
            if ([format isEqualToString:@"wav"]) {
                preset = @"AVAssetExportPresetPassthrough";
            }

            id exportSession = ((id (*)(id, SEL, id, id))objc_msgSend)(
                (id)exportClass, exportInitSel, composition, preset);
            if (!exportSession) {
                result = @{@"error": @"Could not create AVAssetExportSession"};
                return;
            }

            // Configure export session
            NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
            ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                @selector(setOutputURL:), outputURL);

            NSString *fileType = [format isEqualToString:@"wav"]
                ? @"com.microsoft.waveform-audio"
                : @"com.apple.m4a-audio";
            ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                NSSelectorFromString(@"setOutputFileType:"), fileType);

            if (audioMix) {
                ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                    NSSelectorFromString(@"setAudioMix:"), audioMix);
            }

            // Export synchronously
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block BOOL exportOK = NO;
            __block NSString *exportError = nil;

            ((void (*)(id, SEL, void(^)(void)))objc_msgSend)(exportSession,
                NSSelectorFromString(@"exportAsynchronouslyWithCompletionHandler:"),
                ^{
                    NSInteger status = ((NSInteger (*)(id, SEL))objc_msgSend)(
                        exportSession, NSSelectorFromString(@"status"));
                    // AVAssetExportSessionStatusCompleted = 3
                    exportOK = (status == 3);
                    if (!exportOK) {
                        id err = ((id (*)(id, SEL))objc_msgSend)(
                            exportSession, @selector(error));
                        exportError = err ? [err description] : @"Export failed with unknown error";
                    }
                    dispatch_semaphore_signal(sem);
                });

            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

            if (exportOK) {
                // Get actual file size
                NSDictionary *attrs = [[NSFileManager defaultManager]
                    attributesOfItemAtPath:outputPath error:nil];
                NSNumber *fileSize = attrs[NSFileSize] ?: @0;

                result = @{
                    @"status": @"ok",
                    @"path": outputPath,
                    @"format": format,
                    @"durationSeconds": durationSecondsNum,
                    @"fileSizeBytes": fileSize
                };
            } else {
                result = @{@"error": exportError ?: @"Export timed out"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to render song"};
}

// ---------- 5. flexmusic.addToTimeline ----------

NSDictionary *SpliceKit_handleFlexMusicAddToTimeline(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *handle = params[@"handle"];
    NSNumber *durationSecondsNum = params[@"durationSeconds"];
    if (!songUID && !handle) return @{@"error": @"songUID or handle parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // If no explicit duration, try to get timeline duration
            double durationSeconds = durationSecondsNum ? [durationSecondsNum doubleValue] : 0;

            if (durationSeconds <= 0) {
                id timeline = SpliceKit_getActiveTimelineModule();
                if (timeline) {
                    SEL seqSel = @selector(sequence);
                    if ([timeline respondsToSelector:seqSel]) {
                        id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
                        if (sequence) {
                            SEL durSel = NSSelectorFromString(@"duration");
                            if ([sequence respondsToSelector:durSel]) {
                                SpliceKit_CMTime d = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(
                                    sequence, durSel);
                                durationSeconds = SpliceKit_cmtimeToSeconds(d);
                            }
                        }
                    }
                }
            }

            if (durationSeconds <= 0) {
                durationSeconds = 30.0; // fallback default
            }

            // Resolve song
            id song = nil;
            if (handle) {
                song = SpliceKit_resolveHandle(handle);
            }
            if (!song && songUID) {
                id library = SpliceKit_getFlexMusicLibrary();
                if (library) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([library respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(library, forUIDSel, songUID);
                    }
                }
            }
            if (!song) {
                result = @{@"error": @"Song not found"};
                return;
            }

            SpliceKit_CMTime durTime = SpliceKit_cmtimeFromSeconds(durationSeconds);

            // Get song name for FCPXML
            NSString *songName = @"FlexMusic";
            SEL nameSel = NSSelectorFromString(@"name");
            if ([song respondsToSelector:nameSel]) {
                id n = ((id (*)(id, SEL))objc_msgSend)(song, nameSel);
                if (n) songName = n;
            }

            // Get rendition and export to temp file
            id rendition = nil;
            id options = @{};
            Class ffFlexObj = objc_getClass("FFAnchoredFlexMusicObject");
            if (ffFlexObj) {
                SEL optSel = NSSelectorFromString(@"optionsForDuration:");
                if ([ffFlexObj respondsToSelector:optSel]) {
                    options = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        (id)ffFlexObj, optSel, durTime) ?: @{};
                }
            }
            SEL rendSel = NSSelectorFromString(@"renditionForDuration:withOptions:");
            if ([song respondsToSelector:rendSel]) {
                rendition = ((id (*)(id, SEL, SpliceKit_CMTime, id))objc_msgSend)(
                    song, rendSel, durTime, options);
            }
            if (!rendition) {
                SEL rendSel2 = NSSelectorFromString(@"renditionForDuration:");
                if ([song respondsToSelector:rendSel2]) {
                    rendition = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        song, rendSel2, durTime);
                }
            }
            if (!rendition) {
                result = @{@"error": @"Could not get rendition for timeline insertion"};
                return;
            }

            // Export to temp file
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"splicekit_flexmusic_%@.m4a",
                 [[NSUUID UUID] UUIDString]]];

            SEL compSel = NSSelectorFromString(@"avCompositionWithAudioMix:includeShortenedOutroFadeOut:");
            id composition = nil;
            id audioMix = nil;
            if ([rendition respondsToSelector:compSel]) {
                __unsafe_unretained id mixRef = nil;
                composition = ((id (*)(id, SEL, __unsafe_unretained id *, BOOL))objc_msgSend)(
                    rendition, compSel, &mixRef, YES);
                audioMix = mixRef;
            }
            if (!composition) {
                SEL simpleCompSel = NSSelectorFromString(@"avComposition");
                if ([rendition respondsToSelector:simpleCompSel]) {
                    composition = ((id (*)(id, SEL))objc_msgSend)(rendition, simpleCompSel);
                }
            }
            if (!composition) {
                result = @{@"error": @"Could not get AVComposition for export"};
                return;
            }

            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

            Class exportClass = objc_getClass("AVAssetExportSession");
            SEL exportInitSel = NSSelectorFromString(@"exportSessionWithAsset:presetName:");
            id exportSession = ((id (*)(id, SEL, id, id))objc_msgSend)(
                (id)exportClass, exportInitSel, composition, @"AVAssetExportPresetAppleM4A");
            if (!exportSession) {
                result = @{@"error": @"Could not create export session"};
                return;
            }

            NSURL *outputURL = [NSURL fileURLWithPath:tempPath];
            ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                @selector(setOutputURL:), outputURL);
            ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                NSSelectorFromString(@"setOutputFileType:"), @"com.apple.m4a-audio");
            if (audioMix) {
                ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                    NSSelectorFromString(@"setAudioMix:"), audioMix);
            }

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block BOOL exportOK = NO;
            ((void (*)(id, SEL, void(^)(void)))objc_msgSend)(exportSession,
                NSSelectorFromString(@"exportAsynchronouslyWithCompletionHandler:"),
                ^{
                    NSInteger status = ((NSInteger (*)(id, SEL))objc_msgSend)(
                        exportSession, NSSelectorFromString(@"status"));
                    exportOK = (status == 3);
                    dispatch_semaphore_signal(sem);
                });
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

            if (!exportOK) {
                result = @{@"error": @"Failed to render song audio for timeline import"};
                return;
            }

            // Import via FCPXML with the rendered audio file
            int durationFrames = (int)(durationSeconds * 24);
            NSString *escapedName = [[songName stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
            escapedName = [escapedName stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];

            NSURL *tempURL = [NSURL fileURLWithPath:tempPath];
            NSString *fmUID = [[[NSUUID UUID] UUIDString] substringToIndex:8];
            NSString *xml = [NSString stringWithFormat:
                @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                @"<!DOCTYPE fcpxml>\n\n"
                @"<fcpxml version=\"1.14\">\n"
                @"    <resources>\n"
                @"        <format id=\"fmt_%@\" frameDuration=\"100/2400s\" width=\"1920\" "
                @"height=\"1080\" name=\"FFVideoFormat1080p24\"/>\n"
                @"        <asset id=\"fm_%@\" hasAudio=\"1\" hasVideo=\"0\" "
                @"audioSources=\"1\" audioChannels=\"2\" audioRate=\"44100\" name=\"%@\">\n"
                @"            <media-rep kind=\"original-media\" src=\"%@\"/>\n"
                @"        </asset>\n"
                @"    </resources>\n"
                @"    <library>\n"
                @"        <event name=\"FlexMusic Import\">\n"
                @"            <project name=\"%@ Audio\">\n"
                @"                <sequence format=\"fmt_%@\" tcStart=\"0s\" tcFormat=\"NDF\" "
                @"audioLayout=\"stereo\" audioRate=\"48k\">\n"
                @"                    <spine>\n"
                @"                        <asset-clip ref=\"fm_%@\" name=\"%@\" "
                @"duration=\"%d00/2400s\" start=\"0s\"/>\n"
                @"                    </spine>\n"
                @"                </sequence>\n"
                @"            </project>\n"
                @"        </event>\n"
                @"    </library>\n"
                @"</fcpxml>\n",
                fmUID, fmUID, escapedName, [tempURL absoluteString],
                escapedName, fmUID, fmUID, escapedName, durationFrames];

            // Import the FCPXML
            NSString *xmlPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"splicekit_flexmusic_import.fcpxml"];
            NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
            [data writeToFile:xmlPath atomically:YES];
            NSURL *xmlURL = [NSURL fileURLWithPath:xmlPath];

            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));

            SEL openSel = NSSelectorFromString(@"openXMLDocumentWithURL:bundleURL:display:sender:");
            if ([delegate respondsToSelector:openSel]) {
                ((void (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(
                    delegate, openSel, xmlURL, nil, YES, nil);
                result = @{
                    @"status": @"ok",
                    @"songName": songName,
                    @"durationSeconds": @(durationSeconds),
                    @"audioFile": tempPath,
                    @"message": @"FlexMusic song added to timeline via FCPXML import"
                };
            } else {
                result = @{@"error": @"PEAppController does not respond to openXMLDocumentWithURL:"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to add song to timeline"};
}

// ---------- 6. montage.analyzeClips ----------

NSDictionary *SpliceKit_handleMontageAnalyze(NSDictionary *params) {
    NSString *eventFilter = params[@"eventName"];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // Get clips from library events
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active library"};
                return;
            }

            id library = [(NSArray *)libs firstObject];
            SEL eventsSel = NSSelectorFromString(@"events");
            if (![library respondsToSelector:eventsSel]) {
                result = @{@"error": @"Library does not respond to events"};
                return;
            }
            id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
            if (![events isKindOfClass:[NSArray class]] || [(NSArray *)events count] == 0) {
                result = @{@"error": @"No events in library"};
                return;
            }

            NSMutableArray *analyzedClips = [NSMutableArray array];
            NSInteger clipIndex = 0;

            for (id event in (NSArray *)events) {
                NSString *eventName = @"";
                if ([event respondsToSelector:@selector(displayName)])
                    eventName = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName)) ?: @"";

                // Filter by event name if specified
                if (eventFilter.length > 0 &&
                    ![[eventName lowercaseString] containsString:[eventFilter lowercaseString]]) {
                    continue;
                }

                // Get clips from event (the same walk as browser.listClips)
                NSArray *clips = SpliceKit_browserClipsOfEvent(event);
                if (clips.count == 0) continue;

                for (id clip in (NSArray *)clips) {
                    @autoreleasepool {
                        NSMutableDictionary *info = [NSMutableDictionary dictionary];
                        info[@"index"] = @(clipIndex++);
                        info[@"event"] = eventName;

                        NSString *className = NSStringFromClass([clip class]);
                        info[@"class"] = className;

                        // Name
                        NSString *clipName = @"";
                        if ([clip respondsToSelector:@selector(displayName)]) {
                            clipName = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName)) ?: @"";
                        }
                        info[@"name"] = clipName;

                        // Duration
                        double durationSec = 0;
                        if ([clip respondsToSelector:@selector(duration)]) {
                            SpliceKit_CMTime d = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(
                                clip, @selector(duration));
                            durationSec = SpliceKit_cmtimeToSeconds(d);
                            info[@"duration"] = SpliceKit_serializeCMTime(d);
                            info[@"durationSeconds"] = @(durationSec);
                        }

                        // Determine media type from class name
                        NSString *mediaType = @"unknown";
                        if ([className containsString:@"Photo"] || [className containsString:@"Image"] ||
                            [className containsString:@"Still"]) {
                            mediaType = @"photo";
                        } else if ([className containsString:@"Audio"] || [className containsString:@"Sound"]) {
                            mediaType = @"audio";
                        } else if ([className containsString:@"Video"] || [className containsString:@"Media"] ||
                                   [className containsString:@"Asset"] || [className containsString:@"Clip"]) {
                            mediaType = @"video";
                        }
                        // Check for hasVideo / hasAudio properties
                        SEL hasVideoSel = NSSelectorFromString(@"hasVideo");
                        SEL hasAudioSel = NSSelectorFromString(@"hasAudio");
                        BOOL hasVideo = NO, hasAudio = NO;
                        if ([clip respondsToSelector:hasVideoSel]) {
                            hasVideo = ((BOOL (*)(id, SEL))objc_msgSend)(clip, hasVideoSel);
                        }
                        if ([clip respondsToSelector:hasAudioSel]) {
                            hasAudio = ((BOOL (*)(id, SEL))objc_msgSend)(clip, hasAudioSel);
                        }
                        if (hasVideo) mediaType = @"video";
                        else if (hasAudio && !hasVideo) mediaType = @"audio";
                        info[@"mediaType"] = mediaType;
                        info[@"hasVideo"] = @(hasVideo);
                        info[@"hasAudio"] = @(hasAudio);

                        // Score: videos > photos > audio; longer clips score higher
                        double score = 0;
                        if ([mediaType isEqualToString:@"video"]) {
                            score = 10.0 + MIN(durationSec, 30.0);
                        } else if ([mediaType isEqualToString:@"photo"]) {
                            score = 5.0;
                        } else if ([mediaType isEqualToString:@"audio"]) {
                            score = 1.0;
                        } else {
                            score = 3.0 + MIN(durationSec, 10.0);
                        }
                        // Bonus for clips with audio (likely have dialogue)
                        if (hasAudio && hasVideo) score += 2.0;
                        info[@"score"] = @(score);

                        // NOTE: Media URL resolution via originalMediaURL deadlocks inside
                        // FCP's hardened runtime. Skip it — clips will use gaps in FCPXML.
                        // The user can provide file paths manually for proper media references.

                        // Store handle
                        NSString *h = SpliceKit_storeHandle(clip);
                        info[@"handle"] = h;

                        [analyzedClips addObject:info];
                    }
                }
            }

            // Sort by score descending
            [analyzedClips sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [b[@"score"] compare:a[@"score"]];
            }];

            result = @{@"clips": analyzedClips, @"count": @(analyzedClips.count)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to analyze clips"};
}

// ---------- 7. montage.planEdit ----------

NSDictionary *SpliceKit_handleMontagePlan(NSDictionary *params) {
    NSArray *beats = params[@"beats"];
    NSArray *bars = params[@"bars"];
    NSArray *clips = params[@"clips"];
    NSString *style = params[@"style"] ?: @"bar";
    NSNumber *totalDurationNum = params[@"totalDuration"];

    if (!clips || ![clips isKindOfClass:[NSArray class]] || clips.count == 0) {
        return @{@"error": @"clips array parameter required (with handle, duration, score)"};
    }

    // Determine cut points based on style
    NSArray *cutPoints = nil;
    if ([style isEqualToString:@"beat"]) {
        cutPoints = beats;
    } else if ([style isEqualToString:@"section"]) {
        NSArray *sections = params[@"sections"];
        cutPoints = (sections && [sections isKindOfClass:[NSArray class]] && sections.count > 0)
            ? sections : bars;
    } else {
        cutPoints = bars;
    }

    if (!cutPoints || ![cutPoints isKindOfClass:[NSArray class]] || cutPoints.count < 2) {
        return @{@"error": @"Not enough timing data (beats/bars) to plan edit. Need at least 2 cut points."};
    }

    double totalDuration = totalDurationNum ? [totalDurationNum doubleValue] :
        [[cutPoints lastObject] doubleValue];

    // Sort cut points
    NSArray *sortedCuts = [cutPoints sortedArrayUsingSelector:@selector(compare:)];

    // Sort clips by score descending for assignment
    NSArray *sortedClips = [clips sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"score"] compare:a[@"score"]];
        }];

    NSMutableArray *editPlan = [NSMutableArray array];
    NSMutableSet *usedHandles = [NSMutableSet set];
    NSInteger clipPoolIndex = 0;

    for (NSUInteger i = 0; i < sortedCuts.count - 1; i++) {
        double segStart = [sortedCuts[i] doubleValue];
        double segEnd = [sortedCuts[i + 1] doubleValue];
        double segDuration = segEnd - segStart;

        if (segDuration <= 0.01) continue; // skip degenerate segments

        // Pick the highest-scoring unused clip
        NSDictionary *chosenClip = nil;
        for (NSUInteger j = 0; j < sortedClips.count; j++) {
            NSString *h = sortedClips[j][@"handle"];
            if (h && ![usedHandles containsObject:h]) {
                chosenClip = sortedClips[j];
                [usedHandles addObject:h];
                break;
            }
        }

        // If all clips used, start reusing from the top
        if (!chosenClip) {
            [usedHandles removeAllObjects];
            chosenClip = sortedClips[clipPoolIndex % sortedClips.count];
            NSString *h = chosenClip[@"handle"];
            if (h) [usedHandles addObject:h];
            clipPoolIndex++;
        }

        double clipDuration = [chosenClip[@"durationSeconds"] doubleValue];
        if (clipDuration <= 0) clipDuration = [chosenClip[@"duration"] doubleValue];

        // Calculate in/out points (center the best part)
        double inPoint = 0;
        double outPoint = segDuration;
        if (clipDuration > segDuration) {
            inPoint = (clipDuration - segDuration) / 2.0;
            outPoint = inPoint + segDuration;
        } else {
            outPoint = MIN(clipDuration, segDuration);
        }

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"clipHandle"] = chosenClip[@"handle"] ?: @"";
        entry[@"clipName"] = chosenClip[@"name"] ?: @"";
        entry[@"mediaURL"] = chosenClip[@"mediaURL"] ?: @"";
        entry[@"inSeconds"] = @(inPoint);
        entry[@"outSeconds"] = @(outPoint);
        entry[@"timelineStartSeconds"] = @(segStart);
        entry[@"durationSeconds"] = @(segDuration);
        entry[@"segmentIndex"] = @(i);

        [editPlan addObject:entry];
    }

    return @{
        @"editPlan": editPlan,
        @"segmentCount": @(editPlan.count),
        @"totalDurationSeconds": @(totalDuration),
        @"style": style,
        @"cutPointCount": @(sortedCuts.count)
    };
}

// ---------- 8. montage.assemble ----------

NSDictionary *SpliceKit_handleMontageAssemble(NSDictionary *params) {
    NSArray *editPlan = params[@"editPlan"];
    NSString *projectName = params[@"projectName"] ?: @"SpliceKit Montage";
    NSString *songFile = params[@"songFile"];

    if (!editPlan || ![editPlan isKindOfClass:[NSArray class]] || editPlan.count == 0) {
        return @{@"error": @"editPlan array parameter required"};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // Collect unique media files from clip handles
            NSMutableDictionary *mediaResources = [NSMutableDictionary dictionary];
            NSMutableArray *spineClips = [NSMutableArray array];

            int resourceIndex = 100; // Start at 100 to avoid ID collision with format
            for (NSDictionary *entry in editPlan) {
                NSString *resourceId = nil;
                NSString *mediaURL = entry[@"mediaURL"] ?: @"";
                NSString *clipName = entry[@"clipName"] ?: @"Clip";

                // Deduplicate resources by media URL
                if (mediaURL.length > 0 && mediaResources[mediaURL]) {
                    resourceId = mediaResources[mediaURL][@"id"];
                } else {
                    resourceId = [NSString stringWithFormat:@"r%d", ++resourceIndex];
                    if (mediaURL.length > 0) {
                        mediaResources[mediaURL] = @{@"id": resourceId, @"url": mediaURL};
                    }
                }

                double inSec = [entry[@"inSeconds"] doubleValue];
                double durSec = [entry[@"durationSeconds"] doubleValue];
                double tlStart = [entry[@"timelineStartSeconds"] doubleValue];

                [spineClips addObject:@{
                    @"resourceId": resourceId ?: @"r0",
                    @"name": clipName,
                    @"inSeconds": @(inSec),
                    @"durationSeconds": @(durSec),
                    @"timelineStartSeconds": @(tlStart),
                    @"mediaURL": mediaURL
                }];
            }

            // Build FCPXML 1.14 document (DTD-compliant, modeled after FCP's own export)
            NSString *uid = [[[NSUUID UUID] UUIDString] substringToIndex:8];
            NSString *fmtId = [NSString stringWithFormat:@"fmt_%@", uid];

            NSMutableString *xml = [NSMutableString string];
            [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
            [xml appendString:@"<!DOCTYPE fcpxml>\n\n"];
            [xml appendString:@"<fcpxml version=\"1.14\">\n"];
            [xml appendString:@"    <resources>\n"];
            [xml appendFormat:@"        <format id=\"%@\" name=\"FFVideoFormat1080p24\" "
                                @"frameDuration=\"100/2400s\" width=\"1920\" height=\"1080\"/>\n", fmtId];

            // Assets with media-rep children (required by DTD)
            for (NSString *urlKey in mediaResources) {
                NSDictionary *res = mediaResources[urlKey];
                [xml appendFormat:@"        <asset id=\"%@\" name=\"%@\" hasVideo=\"1\" "
                    @"format=\"%@\" hasAudio=\"1\" videoSources=\"1\" "
                    @"audioSources=\"1\" audioChannels=\"2\" audioRate=\"44100\">\n",
                    res[@"id"], res[@"id"], fmtId];
                [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n",
                    res[@"url"]];
                [xml appendString:@"        </asset>\n"];
            }

            if (songFile.length > 0) {
                NSURL *songURL = [NSURL fileURLWithPath:songFile];
                [xml appendString:@"        <asset id=\"song_audio\" name=\"Music\" "
                    @"hasAudio=\"1\" audioSources=\"1\" audioChannels=\"2\" "
                    @"audioRate=\"44100\">\n"];
                [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n",
                    [songURL absoluteString]];
                [xml appendString:@"        </asset>\n"];
            }

            [xml appendString:@"    </resources>\n"];
            [xml appendString:@"    <library>\n"];
            [xml appendFormat:@"        <event name=\"Montage\">\n"];

            NSString *escapedProject = [[projectName
                stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
            [xml appendFormat:@"            <project name=\"%@\">\n", escapedProject];

            // Calculate total duration
            double totalDuration = 0;
            for (NSDictionary *clip in spineClips) {
                double end = [clip[@"timelineStartSeconds"] doubleValue] +
                             [clip[@"durationSeconds"] doubleValue];
                if (end > totalDuration) totalDuration = end;
            }
            int totalFrames = (int)(totalDuration * 2400 / 100); // 24fps = 100/2400s per frame

            [xml appendFormat:@"                <sequence format=\"%@\" "
                @"duration=\"%d00/2400s\" tcStart=\"0s\" tcFormat=\"NDF\" "
                @"audioLayout=\"stereo\" audioRate=\"48k\">\n", fmtId, totalFrames];
            [xml appendString:@"                    <spine>\n"];

            // Add clips to spine — first clip gets the connected song audio
            int offsetFrames = 0;
            for (NSUInteger i = 0; i < spineClips.count; i++) {
                NSDictionary *clip = spineClips[i];
                double durSec = [clip[@"durationSeconds"] doubleValue];
                double inSec = [clip[@"inSeconds"] doubleValue];

                int durFrames = MAX(1, (int)(durSec * 2400 / 100));
                int inFrames = (int)(inSec * 2400 / 100);

                NSString *name = clip[@"name"];
                NSString *escapedName = [[name stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                    stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
                escapedName = [escapedName stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];

                BOOL hasMedia = [clip[@"mediaURL"] length] > 0;
                BOOL isFirst = (i == 0);
                BOOL needsSongChild = isFirst && songFile.length > 0;

                if (hasMedia) {
                    if (needsSongChild) {
                        // First clip — open tag, add connected song, close tag
                        [xml appendFormat:@"                        <asset-clip ref=\"%@\" "
                            @"name=\"%@\" offset=\"%d00/2400s\" "
                            @"duration=\"%d00/2400s\" start=\"%d00/2400s\">\n",
                            clip[@"resourceId"], escapedName, offsetFrames,
                            durFrames, inFrames];
                        // Connected song audio on lane -1
                        [xml appendFormat:@"                            <asset-clip ref=\"song_audio\" "
                            @"lane=\"-1\" name=\"Music\" offset=\"0s\" "
                            @"duration=\"%d00/2400s\" start=\"0s\"/>\n", totalFrames];
                        [xml appendString:@"                        </asset-clip>\n"];
                    } else {
                        [xml appendFormat:@"                        <asset-clip ref=\"%@\" "
                            @"name=\"%@\" offset=\"%d00/2400s\" "
                            @"duration=\"%d00/2400s\" start=\"%d00/2400s\"/>\n",
                            clip[@"resourceId"], escapedName, offsetFrames,
                            durFrames, inFrames];
                    }
                } else {
                    if (needsSongChild) {
                        [xml appendFormat:@"                        <gap name=\"%@\" "
                            @"offset=\"%d00/2400s\" duration=\"%d00/2400s\">\n",
                            escapedName, offsetFrames, durFrames];
                        [xml appendFormat:@"                            <asset-clip ref=\"song_audio\" "
                            @"lane=\"-1\" name=\"Music\" offset=\"0s\" "
                            @"duration=\"%d00/2400s\" start=\"0s\"/>\n", totalFrames];
                        [xml appendString:@"                        </gap>\n"];
                    } else {
                        [xml appendFormat:@"                        <gap name=\"%@\" "
                            @"offset=\"%d00/2400s\" duration=\"%d00/2400s\"/>\n",
                            escapedName, offsetFrames, durFrames];
                    }
                }

                offsetFrames += durFrames;
            }

            [xml appendString:@"                    </spine>\n"];
            [xml appendString:@"                </sequence>\n"];
            [xml appendString:@"            </project>\n"];
            [xml appendString:@"        </event>\n"];
            [xml appendString:@"    </library>\n"];
            [xml appendString:@"</fcpxml>\n"];

            // Write and import FCPXML
            NSString *xmlPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"splicekit_montage.fcpxml"];
            NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
            [data writeToFile:xmlPath atomically:YES];
            NSURL *xmlURL = [NSURL fileURLWithPath:xmlPath];

            // Set result immediately, then dispatch import async (it can show modal progress)
            result = @{
                @"status": @"ok",
                @"projectName": projectName,
                @"clipCount": @(spineClips.count),
                @"totalDurationSeconds": @(totalDuration),
                @"hasSongAudio": @(songFile.length > 0),
                @"fcpxmlPath": xmlPath,
                @"message": @"Montage FCPXML written. Importing..."
            };

            // Import asynchronously on the next run loop iteration
            NSURL *importURL = [xmlURL copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                id app = ((id (*)(id, SEL))objc_msgSend)(
                    objc_getClass("NSApplication"), @selector(sharedApplication));
                id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
                SEL openSel = NSSelectorFromString(@"openXMLDocumentWithURL:bundleURL:display:sender:");
                if ([delegate respondsToSelector:openSel]) {
                    ((void (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(
                        delegate, openSel, importURL, nil, YES, nil);
                }
            });
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to assemble montage"};
}

// ---------- 9. montage.auto ----------

NSDictionary *SpliceKit_handleMontageAuto(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *songHandle = params[@"songHandle"];
    NSString *eventName = params[@"eventName"];
    NSString *style = params[@"style"] ?: @"bar";
    NSString *projectName = params[@"projectName"] ?: @"Auto Montage";

    if (!songUID && !songHandle) return @{@"error": @"songUID or songHandle parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // Step 1: Analyze clips from library
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active library"};
                return;
            }

            id library = [(NSArray *)libs firstObject];
            SEL eventsSel = NSSelectorFromString(@"events");
            if (![library respondsToSelector:eventsSel]) {
                result = @{@"error": @"Library does not respond to events"};
                return;
            }
            id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
            if (![events isKindOfClass:[NSArray class]] || [(NSArray *)events count] == 0) {
                result = @{@"error": @"No events in library"};
                return;
            }

            NSMutableArray *analyzedClips = [NSMutableArray array];
            for (id event in (NSArray *)events) {
                NSString *evName = @"";
                if ([event respondsToSelector:@selector(displayName)])
                    evName = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName)) ?: @"";

                if (eventName.length > 0 &&
                    ![[evName lowercaseString] containsString:[eventName lowercaseString]]) {
                    continue;
                }

                id clips = nil;
                SEL displayClipsSel = NSSelectorFromString(@"displayOwnedClips");
                SEL ownedClipsSel = NSSelectorFromString(@"ownedClips");
                if ([event respondsToSelector:displayClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, displayClipsSel);
                } else if ([event respondsToSelector:ownedClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, ownedClipsSel);
                }
                if (clips && [clips isKindOfClass:[NSSet class]])
                    clips = [(NSSet *)clips allObjects];
                if (![clips isKindOfClass:[NSArray class]]) continue;

                for (id clip in (NSArray *)clips) {
                    @autoreleasepool {
                        NSMutableDictionary *info = [NSMutableDictionary dictionary];

                        NSString *clipName = @"";
                        if ([clip respondsToSelector:@selector(displayName)])
                            clipName = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName)) ?: @"";
                        info[@"name"] = clipName;

                        double durationSec = 0;
                        if ([clip respondsToSelector:@selector(duration)]) {
                            SpliceKit_CMTime d = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(
                                clip, @selector(duration));
                            durationSec = SpliceKit_cmtimeToSeconds(d);
                        }
                        info[@"durationSeconds"] = @(durationSec);

                        BOOL hasVideo = NO;
                        SEL hasVideoSel = NSSelectorFromString(@"hasVideo");
                        if ([clip respondsToSelector:hasVideoSel])
                            hasVideo = ((BOOL (*)(id, SEL))objc_msgSend)(clip, hasVideoSel);

                        double score = hasVideo ? (10.0 + MIN(durationSec, 30.0)) : 3.0;
                        info[@"score"] = @(score);

                        NSString *h = SpliceKit_storeHandle(clip);
                        info[@"handle"] = h;

                        [analyzedClips addObject:info];
                    }
                }
            }

            if (analyzedClips.count == 0) {
                result = @{@"error": @"No clips found in library/event for montage"};
                return;
            }

            [analyzedClips sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [b[@"score"] compare:a[@"score"]];
            }];

            // Calculate total clip duration for song fitting
            double totalClipDuration = 0;
            for (NSDictionary *c in analyzedClips) {
                totalClipDuration += [c[@"durationSeconds"] doubleValue];
            }
            double montageDuration = MIN(totalClipDuration, 120.0);
            if (montageDuration < 5.0) montageDuration = 30.0;

            // Step 2: Get timing from song
            id song = nil;
            if (songHandle) {
                song = SpliceKit_resolveHandle(songHandle);
            }
            if (!song && songUID) {
                id fmLibrary = SpliceKit_getFlexMusicLibrary();
                if (fmLibrary) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([fmLibrary respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(fmLibrary, forUIDSel, songUID);
                    }
                }
            }
            if (!song) {
                result = @{@"error": @"Song not found for montage"};
                return;
            }

            SpliceKit_CMTime durTime = SpliceKit_cmtimeFromSeconds(montageDuration);

            id rendition = nil;
            id options = @{};
            Class ffFlexObj = objc_getClass("FFAnchoredFlexMusicObject");
            if (ffFlexObj) {
                SEL optSel = NSSelectorFromString(@"optionsForDuration:");
                if ([ffFlexObj respondsToSelector:optSel]) {
                    options = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        (id)ffFlexObj, optSel, durTime) ?: @{};
                }
            }
            SEL rendSel = NSSelectorFromString(@"renditionForDuration:withOptions:");
            if ([song respondsToSelector:rendSel]) {
                rendition = ((id (*)(id, SEL, SpliceKit_CMTime, id))objc_msgSend)(
                    song, rendSel, durTime, options);
            }
            if (!rendition) {
                SEL rendSel2 = NSSelectorFromString(@"renditionForDuration:");
                if ([song respondsToSelector:rendSel2]) {
                    rendition = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        song, rendSel2, durTime);
                }
            }
            if (!rendition) {
                result = @{@"error": @"Could not get song rendition for montage"};
                return;
            }

            // Get actual fitted duration
            double fittedDuration = montageDuration;
            SEL rendDurSel = NSSelectorFromString(@"duration");
            if ([rendition respondsToSelector:rendDurSel]) {
                SpliceKit_CMTime rd = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(rendition, rendDurSel);
                fittedDuration = SpliceKit_cmtimeToSeconds(rd);
                if (fittedDuration > 0) montageDuration = fittedDuration;
            }

            // Extract timing
            NSString *barId = SpliceKit_flexMusicConstant("FMTimedMetadataIdentifierBar");
            NSString *beatId = SpliceKit_flexMusicConstant("FMTimedMetadataIdentifierBeat");
            SEL timedMetaSel = NSSelectorFromString(@"timedMetadataItemsWithIdentifier:");
            BOOL hasTimedMeta = [rendition respondsToSelector:timedMetaSel];

            NSArray *(^extractTimesAuto)(NSString *) = ^NSArray *(NSString *identifier) {
                if (!identifier || !hasTimedMeta) return @[];
                id items = ((id (*)(id, SEL, id))objc_msgSend)(rendition, timedMetaSel, identifier);
                if (![items isKindOfClass:[NSArray class]]) return @[];
                NSMutableArray *times = [NSMutableArray array];
                [times addObject:@(0.0)];
                for (id item in (NSArray *)items) {
                    SEL timeSel = NSSelectorFromString(@"time");
                    if ([item respondsToSelector:timeSel]) {
                        SpliceKit_CMTime t = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(item, timeSel);
                        double sec = SpliceKit_cmtimeToSeconds(t);
                        if (sec > 0 && sec < montageDuration) [times addObject:@(sec)];
                    }
                }
                [times addObject:@(montageDuration)];
                return times;
            };

            NSArray *barTimes = extractTimesAuto(barId);
            NSArray *beatTimes = extractTimesAuto(beatId);
            NSArray *cutPoints = [style isEqualToString:@"beat"] ? beatTimes : barTimes;

            // If we got no timing data, create evenly spaced cuts
            if (cutPoints.count < 2) {
                NSMutableArray *evenCuts = [NSMutableArray array];
                double interval = montageDuration / MAX(analyzedClips.count, 4);
                for (double t = 0; t <= montageDuration; t += interval) {
                    [evenCuts addObject:@(t)];
                }
                if ([[evenCuts lastObject] doubleValue] < montageDuration - 0.5) {
                    [evenCuts addObject:@(montageDuration)];
                }
                cutPoints = evenCuts;
            }

            // Step 3: Plan the edit
            NSArray *sortedCuts = [cutPoints sortedArrayUsingSelector:@selector(compare:)];
            NSMutableArray *editPlan = [NSMutableArray array];
            NSMutableSet *usedHandles = [NSMutableSet set];

            NSArray *sortedClips = [analyzedClips sortedArrayUsingComparator:
                ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    return [b[@"score"] compare:a[@"score"]];
                }];

            NSInteger poolIdx = 0;
            for (NSUInteger i = 0; i < sortedCuts.count - 1; i++) {
                double segStart = [sortedCuts[i] doubleValue];
                double segEnd = [sortedCuts[i + 1] doubleValue];
                double segDuration = segEnd - segStart;
                if (segDuration <= 0.01) continue;

                NSDictionary *chosenClip = nil;
                for (NSUInteger j = 0; j < sortedClips.count; j++) {
                    NSString *ch = sortedClips[j][@"handle"];
                    if (ch && ![usedHandles containsObject:ch]) {
                        chosenClip = sortedClips[j];
                        [usedHandles addObject:ch];
                        break;
                    }
                }
                if (!chosenClip) {
                    [usedHandles removeAllObjects];
                    chosenClip = sortedClips[poolIdx % sortedClips.count];
                    NSString *ch = chosenClip[@"handle"];
                    if (ch) [usedHandles addObject:ch];
                    poolIdx++;
                }

                double clipDur = [chosenClip[@"durationSeconds"] doubleValue];
                double inPt = 0;
                if (clipDur > segDuration) {
                    inPt = (clipDur - segDuration) / 2.0;
                }

                [editPlan addObject:@{
                    @"clipHandle": chosenClip[@"handle"] ?: @"",
                    @"clipName": chosenClip[@"name"] ?: @"",
                    @"inSeconds": @(inPt),
                    @"outSeconds": @(inPt + MIN(clipDur, segDuration)),
                    @"timelineStartSeconds": @(segStart),
                    @"durationSeconds": @(segDuration)
                }];
            }

            if (editPlan.count == 0) {
                result = @{@"error": @"Edit plan is empty - not enough cut points or clips"};
                return;
            }

            // Step 4: Render song to temp file
            NSString *tempSongPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"splicekit_montage_song_%@.m4a",
                 [[NSUUID UUID] UUIDString]]];

            SEL compSel = NSSelectorFromString(@"avCompositionWithAudioMix:includeShortenedOutroFadeOut:");
            id composition = nil;
            id audioMix = nil;
            if ([rendition respondsToSelector:compSel]) {
                __unsafe_unretained id mixRef = nil;
                composition = ((id (*)(id, SEL, __unsafe_unretained id *, BOOL))objc_msgSend)(
                    rendition, compSel, &mixRef, YES);
                audioMix = mixRef;
            }
            if (!composition) {
                SEL simpleCompSel = NSSelectorFromString(@"avComposition");
                if ([rendition respondsToSelector:simpleCompSel])
                    composition = ((id (*)(id, SEL))objc_msgSend)(rendition, simpleCompSel);
            }

            BOOL songRendered = NO;
            if (composition) {
                [[NSFileManager defaultManager] removeItemAtPath:tempSongPath error:nil];
                Class exportClass = objc_getClass("AVAssetExportSession");
                SEL exportInitSel = NSSelectorFromString(@"exportSessionWithAsset:presetName:");
                id exportSession = ((id (*)(id, SEL, id, id))objc_msgSend)(
                    (id)exportClass, exportInitSel, composition, @"AVAssetExportPresetAppleM4A");
                if (exportSession) {
                    NSURL *outURL = [NSURL fileURLWithPath:tempSongPath];
                    ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                        @selector(setOutputURL:), outURL);
                    ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                        NSSelectorFromString(@"setOutputFileType:"), @"com.apple.m4a-audio");
                    if (audioMix) {
                        ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                            NSSelectorFromString(@"setAudioMix:"), audioMix);
                    }
                    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                    __block BOOL expOK = NO;
                    ((void (*)(id, SEL, void(^)(void)))objc_msgSend)(exportSession,
                        NSSelectorFromString(@"exportAsynchronouslyWithCompletionHandler:"),
                        ^{
                            NSInteger status = ((NSInteger (*)(id, SEL))objc_msgSend)(
                                exportSession, NSSelectorFromString(@"status"));
                            expOK = (status == 3);
                            dispatch_semaphore_signal(sem);
                        });
                    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
                    songRendered = expOK;
                }
            }

            // Step 5: Assemble montage via FCPXML
            NSMutableDictionary *mediaResources = [NSMutableDictionary dictionary];
            NSMutableArray *spineClips = [NSMutableArray array];
            int resIdx = 100;

            for (NSDictionary *entry in editPlan) {
                NSString *clipHandle = entry[@"clipHandle"];
                id clip = clipHandle ? SpliceKit_resolveHandle(clipHandle) : nil;
                NSString *mediaURL = @"";

                if (clip) {
                    NSString *resolved = SpliceKit_getMediaURLForClip(clip);
                    if (resolved) mediaURL = resolved;
                }

                NSString *resId = nil;
                if (mediaURL.length > 0 && mediaResources[mediaURL]) {
                    resId = mediaResources[mediaURL][@"id"];
                } else if (mediaURL.length > 0) {
                    resId = [NSString stringWithFormat:@"r%d", ++resIdx];
                    mediaResources[mediaURL] = @{@"id": resId, @"url": mediaURL};
                }

                [spineClips addObject:@{
                    @"resourceId": resId ?: @"r0",
                    @"name": entry[@"clipName"] ?: @"Clip",
                    @"inSeconds": entry[@"inSeconds"] ?: @0,
                    @"durationSeconds": entry[@"durationSeconds"] ?: @0,
                    @"timelineStartSeconds": entry[@"timelineStartSeconds"] ?: @0,
                    @"mediaURL": mediaURL
                }];
            }

            // Build DTD-compliant FCPXML 1.14
            NSString *uid = [[[NSUUID UUID] UUIDString] substringToIndex:8];
            NSString *fmtId = [NSString stringWithFormat:@"fmt_%@", uid];

            NSMutableString *xml = [NSMutableString string];
            [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
            [xml appendString:@"<!DOCTYPE fcpxml>\n\n"];
            [xml appendString:@"<fcpxml version=\"1.14\">\n"];
            [xml appendString:@"    <resources>\n"];
            [xml appendFormat:@"        <format id=\"%@\" name=\"FFVideoFormat1080p24\" "
                                @"frameDuration=\"100/2400s\" width=\"1920\" height=\"1080\"/>\n", fmtId];
            for (NSString *urlKey in mediaResources) {
                NSDictionary *res = mediaResources[urlKey];
                [xml appendFormat:@"        <asset id=\"%@\" name=\"%@\" hasVideo=\"1\" "
                    @"format=\"%@\" hasAudio=\"1\" videoSources=\"1\" "
                    @"audioSources=\"1\" audioChannels=\"2\" audioRate=\"44100\">\n",
                    res[@"id"], res[@"id"], fmtId];
                [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n",
                    res[@"url"]];
                [xml appendString:@"        </asset>\n"];
            }
            if (songRendered) {
                NSURL *songURL = [NSURL fileURLWithPath:tempSongPath];
                [xml appendString:@"        <asset id=\"song_audio\" name=\"Music\" "
                    @"hasAudio=\"1\" audioSources=\"1\" audioChannels=\"2\" "
                    @"audioRate=\"44100\">\n"];
                [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n",
                    [songURL absoluteString]];
                [xml appendString:@"        </asset>\n"];
            }
            [xml appendString:@"    </resources>\n"];

            int totalFrames = (int)(montageDuration * 2400 / 100);
            NSString *escapedProject = [[projectName
                stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];

            [xml appendString:@"    <library>\n"];
            [xml appendFormat:@"        <event name=\"Montage\">\n"];
            [xml appendFormat:@"            <project name=\"%@\">\n", escapedProject];
            [xml appendFormat:@"                <sequence format=\"%@\" "
                @"duration=\"%d00/2400s\" tcStart=\"0s\" tcFormat=\"NDF\" "
                @"audioLayout=\"stereo\" audioRate=\"48k\">\n", fmtId, totalFrames];
            [xml appendString:@"                    <spine>\n"];

            int offsetFrames = 0;
            for (NSUInteger i = 0; i < spineClips.count; i++) {
                NSDictionary *sc = spineClips[i];
                double dur = [sc[@"durationSeconds"] doubleValue];
                double inSec = [sc[@"inSeconds"] doubleValue];

                int durFrames = MAX(1, (int)(dur * 2400 / 100));
                int inFrames = (int)(inSec * 2400 / 100);
                NSString *name = sc[@"name"];
                NSString *escaped = [[name stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                    stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
                escaped = [escaped stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];

                BOOL hasMedia = [sc[@"mediaURL"] length] > 0;
                BOOL needsSong = (i == 0) && songRendered;

                if (hasMedia) {
                    if (needsSong) {
                        [xml appendFormat:@"                        <asset-clip ref=\"%@\" "
                            @"name=\"%@\" offset=\"%d00/2400s\" "
                            @"duration=\"%d00/2400s\" start=\"%d00/2400s\">\n",
                            sc[@"resourceId"], escaped, offsetFrames, durFrames, inFrames];
                        [xml appendFormat:@"                            <asset-clip ref=\"song_audio\" "
                            @"lane=\"-1\" name=\"Music\" offset=\"0s\" "
                            @"duration=\"%d00/2400s\" start=\"0s\"/>\n", totalFrames];
                        [xml appendString:@"                        </asset-clip>\n"];
                    } else {
                        [xml appendFormat:@"                        <asset-clip ref=\"%@\" "
                            @"name=\"%@\" offset=\"%d00/2400s\" "
                            @"duration=\"%d00/2400s\" start=\"%d00/2400s\"/>\n",
                            sc[@"resourceId"], escaped, offsetFrames, durFrames, inFrames];
                    }
                } else {
                    if (needsSong) {
                        [xml appendFormat:@"                        <gap name=\"%@\" "
                            @"offset=\"%d00/2400s\" duration=\"%d00/2400s\">\n",
                            escaped, offsetFrames, durFrames];
                        [xml appendFormat:@"                            <asset-clip ref=\"song_audio\" "
                            @"lane=\"-1\" name=\"Music\" offset=\"0s\" "
                            @"duration=\"%d00/2400s\" start=\"0s\"/>\n", totalFrames];
                        [xml appendString:@"                        </gap>\n"];
                    } else {
                        [xml appendFormat:@"                        <gap name=\"%@\" "
                            @"offset=\"%d00/2400s\" duration=\"%d00/2400s\"/>\n",
                            escaped, offsetFrames, durFrames];
                    }
                }
                offsetFrames += durFrames;
            }

            [xml appendString:@"                    </spine>\n"];
            [xml appendString:@"                </sequence>\n"];
            [xml appendString:@"            </project>\n"];
            [xml appendString:@"        </event>\n"];
            [xml appendString:@"    </library>\n"];
            [xml appendString:@"</fcpxml>\n"];

            NSString *xmlPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"splicekit_montage_auto.fcpxml"];
            NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
            [data writeToFile:xmlPath atomically:YES];
            NSURL *xmlURL = [NSURL fileURLWithPath:xmlPath];

            result = @{
                @"status": @"ok",
                @"projectName": projectName,
                @"clipCount": @(spineClips.count),
                @"totalDurationSeconds": @(montageDuration),
                @"songRendered": @(songRendered),
                @"style": style,
                @"cutPoints": @(sortedCuts.count),
                @"fcpxmlPath": xmlPath,
                @"message": @"Auto montage FCPXML written. Importing..."
            };

            NSURL *importURL = [xmlURL copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                id app = ((id (*)(id, SEL))objc_msgSend)(
                    objc_getClass("NSApplication"), @selector(sharedApplication));
                id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
                SEL openSel = NSSelectorFromString(@"openXMLDocumentWithURL:bundleURL:display:sender:");
                if ([delegate respondsToSelector:openSel]) {
                    ((void (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(
                        delegate, openSel, importURL, nil, YES, nil);
                }
            });
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to create auto montage"};
}
