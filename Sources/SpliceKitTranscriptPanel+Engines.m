//
//  SpliceKitTranscriptPanel+Engines.m
//  The FCP Native (AASpeechAnalyzer) and Apple Speech (SFSpeechRecognizer) engines,
//  including speech-recognition authorization.
//

#import "SpliceKitTranscriptPanel+Private.h"

@implementation SpliceKitTranscriptPanel (Engines)

#pragma mark - Speech Recognition Authorization

// SFSpeechRecognizerAuthorizationStatus
typedef NS_ENUM(NSInteger, SpliceKitSpeechAuthStatus) {
    SpliceKitSpeechAuthNotDetermined = 0,
    SpliceKitSpeechAuthDenied        = 1,
    SpliceKitSpeechAuthRestricted    = 2,
    SpliceKitSpeechAuthAuthorized    = 3,
};

static NSString *SpliceKitSpeechAuthStatusName(NSInteger status) {
    switch (status) {
        case SpliceKitSpeechAuthNotDetermined: return @"notDetermined";
        case SpliceKitSpeechAuthDenied:        return @"denied";
        case SpliceKitSpeechAuthRestricted:    return @"restricted";
        case SpliceKitSpeechAuthAuthorized:    return @"authorized";
        default: return [NSString stringWithFormat:@"unknown(%ld)", (long)status];
    }
}

/// Human-readable reason the Apple Speech engine cannot run, or nil when it can.
/// Kept separate from the request flow so both the pre-flight check and the
/// failure path describe the same state in the same words.
- (NSString *)speechAuthorizationBlockedReasonForStatus:(NSInteger)status {
    switch (status) {
        case SpliceKitSpeechAuthAuthorized:
            return nil;
        case SpliceKitSpeechAuthRestricted:
            return @"Speech recognition is restricted on this Mac (Screen Time or an MDM "
                   @"profile blocks it). Use the Parakeet or FCP Native engine instead.";
        case SpliceKitSpeechAuthDenied:
        default:
            return [NSString stringWithFormat:
                @"Speech recognition permission was denied (status: %@).\n\n"
                @"Grant it in System Settings > Privacy & Security > Speech Recognition, "
                @"enable \"%@\", then quit and reopen the app.\n\n"
                @"If it is not listed there, the app has never been able to ask — use the "
                @"Parakeet engine instead, which needs no permission.",
                SpliceKitSpeechAuthStatusName(status),
                [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"]
                    ?: [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"]
                    ?: @"Final Cut Pro"];
    }
}

- (void)requestSpeechAuthorizationWithCompletion:(void(^)(BOOL authorized))completion {
    if (!SFSpeechRecognizerClass) {
        SpliceKit_log(@"[Transcript] Speech framework not loaded");
        completion(NO);
        return;
    }

    SEL statusSel = NSSelectorFromString(@"authorizationStatus");
    NSInteger status = ((NSInteger (*)(Class, SEL))objc_msgSend)(SFSpeechRecognizerClass, statusSel);
    SpliceKit_log(@"[Transcript] Speech authorization status: %@", SpliceKitSpeechAuthStatusName(status));

    if (status == SpliceKitSpeechAuthAuthorized) {
        completion(YES);
        return;
    }

    if (status == SpliceKitSpeechAuthNotDetermined) {
        // The patched bundle carries NSSpeechRecognitionUsageDescription (added by
        // patcher/patch_fcp.sh Step 4b), so this genuinely can present the system
        // dialog and register the app in the Speech Recognition privacy pane.
        // Ask on the main queue: the prompt is UI, and this is reached from a
        // background transcription queue.
        SpliceKit_log(@"[Transcript] Requesting speech recognition authorization...");
        dispatch_async(dispatch_get_main_queue(), ^{
            SEL reqSel = NSSelectorFromString(@"requestAuthorization:");
            ((void (*)(Class, SEL, id))objc_msgSend)(SFSpeechRecognizerClass, reqSel,
                ^(NSInteger newStatus) {
                    SpliceKit_log(@"[Transcript] Authorization callback: %@",
                                  SpliceKitSpeechAuthStatusName(newStatus));
                    // Honour the answer. This used to proceed unconditionally on the
                    // assumption that the dialog could never appear, which turned a
                    // denial into a transcription that failed later with no reason
                    // attached — indistinguishable from the feature being broken.
                    if (newStatus != SpliceKitSpeechAuthAuthorized) {
                        [self setErrorState:[self speechAuthorizationBlockedReasonForStatus:newStatus]];
                        completion(NO);
                        return;
                    }
                    completion(YES);
                });
        });
        return;
    }

    [self setErrorState:[self speechAuthorizationBlockedReasonForStatus:status]];
    completion(NO);
}

#pragma mark - FCP Native Transcription (AASpeechAnalyzer via FFTranscriptionCoordinator)

- (void)performFCPNativeTranscription {
    SpliceKit_log(@"[Transcript] Using FCP Native engine (FFTranscriptionCoordinator)");
    NSDate *diagStartTime = [NSDate date];

    // Gather assets from timeline clips on the main thread.
    // FCP's own startBackgroundTranscriptionForClips: iterates clips and calls
    // [clip assets] (an NSSet of FFAsset) then unions them all together.
    // We replicate that exact pattern here.
    __block NSArray *assetArray = nil;
    __block NSMapTable *clipInfosByAsset = nil;
    __block NSDictionary<NSString *, NSArray<NSDictionary *> *> *clipInfosByPath = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) {
                [self setErrorState:@"No active timeline. Open a project first."];
                return;
            }

            // Detect frame rate
            if ([timeline respondsToSelector:@selector(sequenceFrameDuration)]) {
                SpliceKitTranscript_CMTime fd = ((SpliceKitTranscript_CMTime (*)(id, SEL))STRET_MSG)(
                    timeline, @selector(sequenceFrameDuration));
                if (fd.timescale > 0 && fd.value > 0) {
                    self.frameRate = (double)fd.timescale / fd.value;
                    self.frameRateKnown = YES;
                }
            }

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject))
                : nil;

            NSString *collectError = nil;
            NSArray *clipInfos = [self collectClipInfosForSequence:sequence
                                                      primaryObject:primaryObj
                                                       errorMessage:&collectError];
            if (!clipInfos) {
                [self setErrorState:collectError ?: @"No items on timeline."];
                return;
            }
            SpliceKitTranscriptDiag_logClipInfos(clipInfos, @"FCP Native");
            SpliceKitTranscriptDiag_logFCPNativeState(clipInfos);

            // modalTranscriptsForClips expects objects that respond to `assets`
            // (like FFAnchoredObject subclasses). It internally calls [clip assets]
            // to get FFAsset objects. We pass the containedItems directly.
            // Also include the sequence itself as a fallback.
            NSMutableOrderedSet *clipObjects = [NSMutableOrderedSet orderedSet];
            SEL assetsSel = NSSelectorFromString(@"assets");
            clipInfosByAsset = [NSMapTable strongToStrongObjectsMapTable];
            NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *mutableClipInfosByPath = [NSMutableDictionary dictionary];

            // Track which FFAsset objects we've already seen so we don't send
            // the same source file to modalTranscriptsForClips twice (v1 + a1
            // components share the same FFAsset but are different objects).
            NSMutableSet *seenAssets = [NSMutableSet set];

            for (NSDictionary *clipInfo in clipInfos) {
                NSURL *mediaURL = clipInfo[@"mediaURL"];
                if (mediaURL.path.length > 0) {
                    NSMutableArray *clipsForPath = mutableClipInfosByPath[mediaURL.path];
                    if (!clipsForPath) {
                        clipsForPath = [NSMutableArray array];
                        mutableClipInfosByPath[mediaURL.path] = clipsForPath;
                    }
                    [clipsForPath addObject:clipInfo];
                }

                id candidate = [self transcriptAssetCandidateForClipInfo:clipInfo assetsSelector:assetsSel];
                if (candidate) {
                    id itemAssets = ((id (*)(id, SEL))objc_msgSend)(candidate, assetsSel);
                    if ([itemAssets isKindOfClass:[NSSet class]] && [(NSSet *)itemAssets count] > 0) {
                        // Check if we've already seen these assets (v1/a1 dedup)
                        BOOL allSeen = YES;
                        for (id asset in (NSSet *)itemAssets) {
                            if (![seenAssets containsObject:asset]) {
                                allSeen = NO;
                                break;
                            }
                        }
                        if (allSeen) {
                            SpliceKit_log(@"[Transcript] Dedup: skipping %@ (assets already covered)",
                                NSStringFromClass([candidate class]));
                            // Still add to path mapping for word lookup
                            continue;
                        }

                        [clipObjects addObject:candidate];
                        SpliceKit_log(@"[Transcript] Item %@ has %lu assets",
                            NSStringFromClass([candidate class]), (unsigned long)[(NSSet *)itemAssets count]);

                        // Map by FFAsset objects (what we expect as result keys)
                        for (id asset in (NSSet *)itemAssets) {
                            [seenAssets addObject:asset];
                            NSMutableArray *clipsForAsset = [clipInfosByAsset objectForKey:asset];
                            if (!clipsForAsset) {
                                clipsForAsset = [NSMutableArray array];
                                [clipInfosByAsset setObject:clipsForAsset forKey:asset];
                            }
                            [clipsForAsset addObject:clipInfo];
                        }

                        // Also map by candidate object itself — modalTranscriptsForClips
                        // may return the candidate (e.g. FFAnchoredCollection) as the key
                        // rather than the FFAsset, depending on FCP version.
                        NSMutableArray *clipsForCandidate = [clipInfosByAsset objectForKey:candidate];
                        if (!clipsForCandidate) {
                            clipsForCandidate = [NSMutableArray array];
                            [clipInfosByAsset setObject:clipsForCandidate forKey:candidate];
                        }
                        [clipsForCandidate addObject:clipInfo];
                    }
                }
            }

            // If no items had assets, try the sequence itself
            if (clipObjects.count == 0 && [sequence respondsToSelector:assetsSel]) {
                [clipObjects addObject:sequence];
                SpliceKit_log(@"[Transcript] Using sequence as clip source");
            }

            assetArray = [clipObjects array];
            clipInfosByPath = [mutableClipInfosByPath copy];
            SpliceKit_log(@"[Transcript] Collected %lu clip objects for transcription",
                          (unsigned long)assetArray.count);

        } @catch (NSException *e) {
            [self setErrorState:[NSString stringWithFormat:@"Error reading timeline: %@", e.reason]];
        }
    });

    if (!assetArray || assetArray.count == 0) {
        if (self.status != SpliceKitTranscriptStatusError) {
            [self setErrorState:@"No assets found on timeline. Try Apple Speech engine instead."];
        }
        return;
    }

    SpliceKit_log(@"[Transcript] Found %lu assets for FCP native transcription", (unsigned long)assetArray.count);

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatusUI:[NSString stringWithFormat:@"Transcribing %lu asset(s) via FCP engine...",
            (unsigned long)assetArray.count]];
        self.progressBar.hidden = NO;
        self.progressBar.indeterminate = YES;
        [self.progressBar startAnimation:nil];
    });

    [self.mutableWords removeAllObjects];
    [self.mutableSilences removeAllObjects];

    // Call FFTranscriptionCoordinator.modalTranscriptsForClips:locale:
    // This must run off the main thread (the decompiled code asserts this)
    @try {
        Class coordClass = objc_getClass("FFTranscriptionCoordinator");
        if (!coordClass) {
            [self setErrorState:@"FFTranscriptionCoordinator not found. FCP Native engine unavailable."];
            return;
        }

        // Check if platform supports transcription
        BOOL supported = ((BOOL (*)(id, SEL))objc_msgSend)(coordClass,
            NSSelectorFromString(@"platformSupportsTranscription"));
        if (!supported) {
            [self setErrorState:@"Transcription not supported on this platform. Try Apple Speech engine."];
            return;
        }

        id coordinator = ((id (*)(id, SEL))objc_msgSend)(coordClass,
            NSSelectorFromString(@"sharedCoordinator"));
        if (!coordinator) {
            [self setErrorState:@"Could not get FFTranscriptionCoordinator. Try Apple Speech engine."];
            return;
        }

        // Get the system language or default to en-US
        NSString *localeID = [[NSLocale currentLocale] localeIdentifier] ?: @"en-US";

        SpliceKit_log(@"[Transcript] Calling modalTranscriptsForClips with %lu assets, locale=%@",
                      (unsigned long)assetArray.count, localeID);

        // modalTranscriptsForClips:locale: — synchronous, must be called off main thread
        // It internally calls [clip assets] on each item, so we pass the assets array
        SEL modalSel = NSSelectorFromString(@"modalTranscriptsForClips:locale:");
        id resultMap = ((id (*)(id, SEL, id, id))objc_msgSend)(coordinator, modalSel, assetArray, localeID);

        if (!resultMap) {
            [self setErrorState:@"FCP transcription returned no results. Try Apple Speech engine."];
            return;
        }

        SpliceKit_log(@"[Transcript] FCP transcription complete, processing results...");

        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatusUI:@"Processing transcript..."];
            self.progressBar.indeterminate = NO;
            self.progressBar.doubleValue = 0.5;
        });

        // Extract words from the FFTranscript objects in the result map
        // resultMap is an NSMapTable: FFAsset -> FFTranscript
        NSUInteger totalWords = 0;

        @try {
            // NSMapTable enumeration
            id keyEnumerator = ((id (*)(id, SEL))objc_msgSend)(resultMap,
                NSSelectorFromString(@"keyEnumerator"));

            id asset;
            while ((asset = ((id (*)(id, SEL))objc_msgSend)(keyEnumerator, @selector(nextObject)))) {
                id transcript = ((id (*)(id, SEL, id))objc_msgSend)(resultMap,
                    NSSelectorFromString(@"objectForKey:"), asset);
                if (!transcript) continue;

                NSArray<NSDictionary *> *matchingClipInfos = [clipInfosByAsset objectForKey:asset];

                // FCP may return clip objects (FFAnchoredCollection) as keys, not FFAsset.
                // Try resolving the clip's .assets and matching each one.
                if (matchingClipInfos.count == 0 && [asset respondsToSelector:NSSelectorFromString(@"assets")]) {
                    id innerAssets = ((id (*)(id, SEL))objc_msgSend)(asset, NSSelectorFromString(@"assets"));
                    if ([innerAssets isKindOfClass:[NSSet class]]) {
                        for (id innerAsset in (NSSet *)innerAssets) {
                            matchingClipInfos = [clipInfosByAsset objectForKey:innerAsset];
                            if (matchingClipInfos.count > 0) break;
                        }
                    }
                }

                // Fallback: match by media file path
                if (matchingClipInfos.count == 0) {
                    NSString *assetPath = [self mediaPathForTranscriptAsset:asset];
                    if (assetPath.length > 0) {
                        matchingClipInfos = clipInfosByPath[assetPath];
                    }
                }
                if (matchingClipInfos.count == 0) {
                    SpliceKit_log(@"[Transcript] No clip mapping found for FCP transcript asset %@ — "
                                  "tried direct lookup, .assets lookup, and media path fallback",
                                  NSStringFromClass([asset class]));
                    continue;
                }

                // Get phrases from transcript
                id phrases = ((id (*)(id, SEL))objc_msgSend)(transcript,
                    NSSelectorFromString(@"phrases"));
                if (!phrases || ![phrases isKindOfClass:[NSArray class]]) continue;

                NSMutableArray<NSDictionary *> *assetWords = [NSMutableArray array];

                for (id phrase in (NSArray *)phrases) {
                    // Get words from phrase
                    id phraseWords = ((id (*)(id, SEL))objc_msgSend)(phrase,
                        NSSelectorFromString(@"words"));
                    if (!phraseWords || ![phraseWords isKindOfClass:[NSArray class]]) continue;

                    for (id fcpWord in (NSArray *)phraseWords) {
                        NSString *text = ((id (*)(id, SEL))objc_msgSend)(fcpWord,
                            NSSelectorFromString(@"text"));
                        if (!text || text.length == 0) continue;

                        // Get timeRange (CMTimeRange struct)
                        SEL trSel = NSSelectorFromString(@"timeRange");
                        NSMethodSignature *sig = [fcpWord methodSignatureForSelector:trSel];
                        if (!sig || [sig methodReturnLength] != sizeof(SpliceKitTranscript_CMTimeRange)) continue;

                        SpliceKitTranscript_CMTimeRange timeRange;
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setTarget:fcpWord];
                        [inv setSelector:trSel];
                        [inv invoke];
                        [inv getReturnValue:&timeRange];

                        double startTime = CMTimeToSeconds(timeRange.start);
                        double duration = CMTimeToSeconds(timeRange.duration);

                        if (duration <= 0) continue;
                        [assetWords addObject:@{
                            @"text": text,
                            @"startTime": @(startTime),
                            @"duration": @(duration),
                        }];
                    }
                }

                for (NSDictionary *clipInfo in matchingClipInfos) {
                    double timelineStart = [clipInfo[@"timelineStart"] doubleValue];
                    double trimStart = [clipInfo[@"trimStart"] doubleValue];
                    double clipDuration = [clipInfo[@"duration"] doubleValue];
                    NSString *clipHandle = clipInfo[@"handle"];
                    NSURL *mediaURL = clipInfo[@"mediaURL"];
                    NSString *sourcePath = mediaURL.path ?: [self mediaPathForTranscriptAsset:asset];

                    for (NSDictionary *assetWord in assetWords) {
                        double startTime = [assetWord[@"startTime"] doubleValue];
                        double duration = [assetWord[@"duration"] doubleValue];
                        if (startTime < trimStart || startTime >= trimStart + clipDuration) {
                            continue;
                        }

                        double timelineDuration = MIN(duration, (trimStart + clipDuration) - startTime);
                        if (timelineDuration <= 0) continue;

                        SpliceKitTranscriptWord *word = [[SpliceKitTranscriptWord alloc] init];
                        word.text = assetWord[@"text"] ?: @"";
                        word.startTime = timelineStart + (startTime - trimStart);
                        word.duration = timelineDuration;
                        word.confidence = 1.0; // FCP native doesn't provide per-word confidence
                        word.clipHandle = clipHandle;
                        word.clipTimelineStart = timelineStart;
                        word.sourceMediaOffset = trimStart;
                        word.sourceMediaTime = startTime; // FCP native times are source-relative
                        word.sourceMediaPath = sourcePath;
                        word.speaker = @"Unknown";

                        @synchronized (self.mutableWords) {
                            [self.mutableWords addObject:word];
                        }
                        totalWords++;
                    }
                }
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[Transcript] Exception extracting results: %@", e.reason);
        }

        SpliceKit_log(@"[Transcript] Extracted %lu words from FCP native transcription", (unsigned long)totalWords);

        // Finalize on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (self.mutableWords) {
                [self.mutableWords sortUsingComparator:^NSComparisonResult(SpliceKitTranscriptWord *a, SpliceKitTranscriptWord *b) {
                    if (a.startTime < b.startTime) return NSOrderedAscending;
                    if (a.startTime > b.startTime) return NSOrderedDescending;
                    return NSOrderedSame;
                }];

                for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
                    self.mutableWords[i].wordIndex = i;
                }
            }

            [self detectSilences];
            [self assignSpeakers];

            self.status = SpliceKitTranscriptStatusReady;
            [self rebuildTextView];
            [self startPlayheadTimer];

            self.spinner.hidden = YES;
            [self.spinner stopAnimation:nil];
            self.progressBar.hidden = YES;
            self.refreshButton.enabled = YES;
            self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);

            NSUInteger silenceCount = self.mutableSilences.count;
            [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses (FCP Native)",
                (unsigned long)self.mutableWords.count, (unsigned long)silenceCount]];

            SpliceKit_log(@"[Transcript] FCP Native complete: %lu words, %lu silences",
                          (unsigned long)self.mutableWords.count, (unsigned long)silenceCount);
            SpliceKitTranscriptDiag_logSummary(@"FCP Native",
                -[diagStartTime timeIntervalSinceNow],
                self.mutableWords.count, silenceCount, 0,
                self.errorMessage);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SpliceKitTranscriptDidComplete" object:self];
        });

    } @catch (NSException *e) {
        [self setErrorState:[NSString stringWithFormat:@"FCP Native error: %@. Try Apple Speech engine.", e.reason]];
    }
}

#pragma mark - Apple Speech Transcription (SFSpeechRecognizer fallback)

- (void)performAppleSpeechTranscription {
    SpliceKit_log(@"[Transcript] Using Apple Speech engine (SFSpeechRecognizer)");
    SpliceKitTranscript_loadSpeechFramework();
    NSDate *diagStartTime = [NSDate date];
    SpliceKitTranscriptDiag_logAppleSpeechState();

    __block NSArray *clips = nil;
    __block double totalDuration = 0;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) {
                [self setErrorState:@"No active timeline. Open a project first."];
                return;
            }

            // Detect frame rate
            if ([timeline respondsToSelector:@selector(sequenceFrameDuration)]) {
                SpliceKitTranscript_CMTime fd = ((SpliceKitTranscript_CMTime (*)(id, SEL))STRET_MSG)(
                    timeline, @selector(sequenceFrameDuration));
                if (fd.timescale > 0 && fd.value > 0) {
                    self.frameRate = (double)fd.timescale / fd.value;
                    self.frameRateKnown = YES;
                }
            }

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject))
                : nil;

            NSString *collectError = nil;
            clips = [self collectClipInfosForSequence:sequence
                                         primaryObject:primaryObj
                                          errorMessage:&collectError];
            if (!clips) {
                [self setErrorState:collectError ?: @"No items on timeline."];
                return;
            }

            for (NSDictionary *clipInfo in clips) {
                double clipEnd = [clipInfo[@"timelineStart"] doubleValue] + [clipInfo[@"duration"] doubleValue];
                if (clipEnd > totalDuration) totalDuration = clipEnd;
            }

        } @catch (NSException *e) {
            [self setErrorState:[NSString stringWithFormat:@"Error reading timeline: %@", e.reason]];
        }
    });

    if (!clips || clips.count == 0) {
        if (self.status != SpliceKitTranscriptStatusError) {
            [self setErrorState:@"No media clips found on timeline."];
        }
        return;
    }

    SpliceKit_log(@"[Transcript] Found %lu clips, total duration: %.2fs", (unsigned long)clips.count, totalDuration);
    SpliceKitTranscriptDiag_logClipInfos(clips, @"Apple Speech");

    [self.mutableWords removeAllObjects];
    [self.mutableSilences removeAllObjects];
    self.completedTranscriptions = 0;
    self.totalTranscriptions = 0;

    NSMutableArray *transcribableClips = [NSMutableArray array];
    for (NSDictionary *clipInfo in clips) {
        if (clipInfo[@"mediaURL"]) {
            [transcribableClips addObject:clipInfo];
        }
    }

    if (transcribableClips.count == 0) {
        [self setErrorState:@"Could not find source media files for any clips. Try providing a file path directly."];
        return;
    }

    self.totalTranscriptions = transcribableClips.count;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatusUI:[NSString stringWithFormat:@"Transcribing clip 1/%lu...",
            (unsigned long)self.totalTranscriptions]];
        self.progressBar.hidden = NO;
        self.progressBar.indeterminate = NO;
        self.progressBar.doubleValue = 0;
    });

    [self transcribeClipsSequentially:transcribableClips index:0 completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (self.mutableWords) {
                [self.mutableWords sortUsingComparator:^NSComparisonResult(SpliceKitTranscriptWord *a, SpliceKitTranscriptWord *b) {
                    if (a.startTime < b.startTime) return NSOrderedAscending;
                    if (a.startTime > b.startTime) return NSOrderedDescending;
                    return NSOrderedSame;
                }];

                for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
                    self.mutableWords[i].wordIndex = i;
                }
            }

            // Detect silences and assign speakers
            [self detectSilences];
            [self assignSpeakers];

            self.status = SpliceKitTranscriptStatusReady;
            [self rebuildTextView];
            [self startPlayheadTimer];

            self.spinner.hidden = YES;
            [self.spinner stopAnimation:nil];
            self.progressBar.hidden = YES;
            self.refreshButton.enabled = YES;
            self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);

            NSUInteger silenceCount = self.mutableSilences.count;
            [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses",
                (unsigned long)self.mutableWords.count, (unsigned long)silenceCount]];

            SpliceKit_log(@"[Transcript] Complete: %lu words, %lu silences",
                          (unsigned long)self.mutableWords.count, (unsigned long)silenceCount);
            SpliceKitTranscriptDiag_logSummary(@"Apple Speech",
                -[diagStartTime timeIntervalSinceNow],
                self.mutableWords.count, silenceCount, transcribableClips.count,
                self.errorMessage);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SpliceKitTranscriptDidComplete" object:self];
        });
    }];
}

- (void)transcribeClipsSequentially:(NSArray *)clips index:(NSUInteger)idx completion:(void(^)(void))completion {
    if (idx >= clips.count) {
        completion();
        return;
    }

    NSDictionary *clipInfo = clips[idx];
    NSURL *mediaURL = clipInfo[@"mediaURL"];
    double timelineStart = [clipInfo[@"timelineStart"] doubleValue];
    double trimStart = [clipInfo[@"trimStart"] doubleValue];
    double mediaOrigin = [clipInfo[@"mediaOrigin"] doubleValue];
    double clipDuration = [clipInfo[@"duration"] doubleValue];
    NSString *clipHandle = clipInfo[@"handle"];

    // Convert trimStart from FCP timecode space to file-relative for Apple Speech
    double fileRelativeTrimStart = trimStart - mediaOrigin;

    [self transcribeAudioFile:mediaURL
                timelineStart:timelineStart
                    trimStart:fileRelativeTrimStart
                 trimDuration:clipDuration
                   clipHandle:clipHandle
                   completion:^(NSArray<SpliceKitTranscriptWord *> *words, NSError *error) {
        if (error) {
            SpliceKit_log(@"[Transcript] Transcription error for %@: %@", mediaURL.lastPathComponent, error);
            // Surface permission errors — FCP's process can't get speech authorization
            // since it has no NSSpeechRecognitionUsageDescription in its Info.plist
            NSString *errDesc = error.localizedDescription ?: @"";
            if ([errDesc containsString:@"permission"] || [errDesc containsString:@"denied"] ||
                [errDesc containsString:@"not authorized"] || error.code == 4 /* kAFAssistantErrorDomain denied */) {
                [self setErrorState:@"Apple Speech denied — FCP can't request speech permission. "
                                    "Use Parakeet or FCP Native engine instead."];
                return;
            }
        } else {
            // Apple Speech returns file-relative timestamps, but sourceMediaTime and
            // sourceMediaOffset must be in FCP's timecode coordinate space for
            // resyncTimestampsFromTimeline to match words back to clips after edits.
            if (mediaOrigin != 0) {
                for (SpliceKitTranscriptWord *word in words) {
                    word.sourceMediaTime += mediaOrigin;
                    word.sourceMediaOffset = trimStart; // original FCP trimStart
                }
            }
            @synchronized (self.mutableWords) {
                [self.mutableWords addObjectsFromArray:words];
            }
            SpliceKit_log(@"[Transcript] Transcribed %lu words from %@",
                          (unsigned long)words.count, mediaURL.lastPathComponent);
        }
        self.completedTranscriptions++;

        dispatch_async(dispatch_get_main_queue(), ^{
            double progress = (double)self.completedTranscriptions / MAX(self.totalTranscriptions, 1);
            self.progressBar.doubleValue = progress;

            if (self.completedTranscriptions < self.totalTranscriptions) {
                [self updateStatusUI:[NSString stringWithFormat:@"Transcribing clip %lu/%lu (%lu words so far)...",
                    (unsigned long)(self.completedTranscriptions + 1),
                    (unsigned long)self.totalTranscriptions,
                    (unsigned long)self.mutableWords.count]];
            } else {
                [self updateStatusUI:[NSString stringWithFormat:@"Processing %lu words...",
                    (unsigned long)self.mutableWords.count]];
            }
        });

        [self transcribeClipsSequentially:clips index:idx + 1 completion:completion];
    }];
}

#pragma mark - Speech Transcription

- (void)transcribeAudioFile:(NSURL *)audioURL
              timelineStart:(double)timelineStart
                  trimStart:(double)trimStart
               trimDuration:(double)trimDuration
                 clipHandle:(NSString *)clipHandle
                 completion:(void(^)(NSArray<SpliceKitTranscriptWord *> *, NSError *))completion {

    if (!SFSpeechRecognizerClass || !SFSpeechURLRecognitionRequestClass) {
        completion(nil, [NSError errorWithDomain:@"SpliceKitTranscript" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Speech framework not available"}]);
        return;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:audioURL.path]) {
        SpliceKit_log(@"[Transcript] File not found: %@", audioURL.path);
        completion(nil, [NSError errorWithDomain:@"SpliceKitTranscript" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Media file not found"}]);
        return;
    }

    SpliceKit_log(@"[Transcript] Transcribing: %@ (timeline:%.2f, trim:%.2f, dur:%.2f)",
                  audioURL.lastPathComponent, timelineStart, trimStart, trimDuration);

    id recognizer = ((id (*)(id, SEL, id))objc_msgSend)(
        [SFSpeechRecognizerClass alloc],
        NSSelectorFromString(@"initWithLocale:"),
        [NSLocale localeWithLocaleIdentifier:@"en-US"]);

    if (!recognizer) {
        completion(nil, [NSError errorWithDomain:@"SpliceKitTranscript" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"Could not create speech recognizer"}]);
        return;
    }

    BOOL isAvailable = ((BOOL (*)(id, SEL))objc_msgSend)(recognizer, NSSelectorFromString(@"isAvailable"));
    if (!isAvailable) {
        completion(nil, [NSError errorWithDomain:@"SpliceKitTranscript" code:4
            userInfo:@{NSLocalizedDescriptionKey: @"Speech recognizer not available"}]);
        return;
    }

    id request = ((id (*)(id, SEL, id))objc_msgSend)(
        [SFSpeechURLRecognitionRequestClass alloc],
        NSSelectorFromString(@"initWithURL:"),
        audioURL);

    if (!request) {
        completion(nil, [NSError errorWithDomain:@"SpliceKitTranscript" code:5
            userInfo:@{NSLocalizedDescriptionKey: @"Could not create recognition request"}]);
        return;
    }

    // Enable partial results so we get streaming progress for long clips
    ((void (*)(id, SEL, BOOL))objc_msgSend)(request,
        NSSelectorFromString(@"setShouldReportPartialResults:"), YES);

    // Use on-device recognition — faster, no network needed, and avoids stricter
    // authorization requirements that can prevent the app from appearing in Settings
    SEL onDeviceSel = NSSelectorFromString(@"setRequiresOnDeviceRecognition:");
    if ([request respondsToSelector:onDeviceSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(request, onDeviceSel, YES);
    }

    // macOS 26+: Enable speaker diarization if user opted in
    __block BOOL useSpeakerDiarization = NO;
    if (self.speakerDetectionEnabled && SpliceKitTranscript_isSpeakerDiarizationAvailable()) {
        SEL speakerSel = NSSelectorFromString(@"setAddsSpeakerAttribution:");
        if ([request respondsToSelector:speakerSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(request, speakerSel, YES);
            useSpeakerDiarization = YES;
            SpliceKit_log(@"[Transcript] Speaker diarization enabled (macOS 26+)");
        } else {
            SpliceKit_log(@"[Transcript] Speaker diarization selector not available on this request");
        }
    }

    // Track last partial word count for progress updates
    __block NSUInteger lastPartialCount = 0;

    SEL taskSel = NSSelectorFromString(@"recognitionTaskWithRequest:resultHandler:");
    ((id (*)(id, SEL, id, id))objc_msgSend)(recognizer, taskSel, request,
        ^(id result, NSError *error) {
            if (error && !result) {
                completion(nil, error);
                return;
            }

            BOOL isFinal = ((BOOL (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"isFinal"));

            id transcription = ((id (*)(id, SEL))objc_msgSend)(result,
                NSSelectorFromString(@"bestTranscription"));
            if (!transcription) {
                if (isFinal) completion(@[], nil);
                return;
            }

            id segments = ((id (*)(id, SEL))objc_msgSend)(transcription,
                NSSelectorFromString(@"segments"));
            if (!segments || ![segments isKindOfClass:[NSArray class]]) {
                if (isFinal) completion(@[], nil);
                return;
            }

            NSUInteger segCount = [(NSArray *)segments count];

            // Update progress on partial results (throttled to every 10 new words)
            if (!isFinal) {
                if (segCount > lastPartialCount + 10) {
                    lastPartialCount = segCount;
                    // Estimate progress based on latest word timestamp vs clip duration
                    double latestTime = 0;
                    if (segCount > 0) {
                        id lastSeg = [(NSArray *)segments lastObject];
                        latestTime = ((double (*)(id, SEL))objc_msgSend)(lastSeg,
                            NSSelectorFromString(@"timestamp"));
                    }
                    double progressFraction = (trimDuration > 0) ? (latestTime - trimStart) / trimDuration : 0;
                    progressFraction = MIN(MAX(progressFraction, 0), 0.99);

                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.progressBar.indeterminate = NO;
                        self.progressBar.doubleValue = progressFraction;
                        [self updateStatusUI:[NSString stringWithFormat:@"Transcribing... %lu words (%.0f%%)",
                            (unsigned long)segCount, progressFraction * 100]];
                    });
                }
                return; // Wait for final result
            }

            // Final result — extract all words
            NSMutableArray<SpliceKitTranscriptWord *> *words = [NSMutableArray array];
            NSMutableSet *speakerNames = [NSMutableSet set];

            for (id segment in (NSArray *)segments) {
                NSString *text = ((id (*)(id, SEL))objc_msgSend)(segment,
                    NSSelectorFromString(@"substring"));
                double timestamp = ((double (*)(id, SEL))objc_msgSend)(segment,
                    NSSelectorFromString(@"timestamp"));
                double duration = ((double (*)(id, SEL))objc_msgSend)(segment,
                    NSSelectorFromString(@"duration"));
                float confidence = ((float (*)(id, SEL))objc_msgSend)(segment,
                    NSSelectorFromString(@"confidence"));

                // macOS 26+: Extract speaker label from segment
                NSString *speakerLabel = @"Unknown";
                if (useSpeakerDiarization) {
                    // Try speakerAttribution property (SFSpeakerAttribution object)
                    SEL attrSel = NSSelectorFromString(@"speakerAttribution");
                    if ([segment respondsToSelector:attrSel]) {
                        id attribution = ((id (*)(id, SEL))objc_msgSend)(segment, attrSel);
                        if (attribution) {
                            // SFSpeakerAttribution has a 'speaker' property (SFSpeaker)
                            SEL speakerSel = NSSelectorFromString(@"speaker");
                            if ([attribution respondsToSelector:speakerSel]) {
                                id speaker = ((id (*)(id, SEL))objc_msgSend)(attribution, speakerSel);
                                if (speaker) {
                                    // SFSpeaker has identifier/name
                                    SEL nameSel = NSSelectorFromString(@"identifier");
                                    if ([speaker respondsToSelector:nameSel]) {
                                        NSString *name = ((id (*)(id, SEL))objc_msgSend)(speaker, nameSel);
                                        if (name.length > 0) {
                                            speakerLabel = [NSString stringWithFormat:@"Speaker %@", name];
                                        }
                                    }
                                    if ([speakerLabel isEqualToString:@"Unknown"]) {
                                        // Fallback: try description or displayName
                                        SEL dispSel = NSSelectorFromString(@"displayName");
                                        if ([speaker respondsToSelector:dispSel]) {
                                            NSString *dn = ((id (*)(id, SEL))objc_msgSend)(speaker, dispSel);
                                            if (dn.length > 0) speakerLabel = dn;
                                        }
                                    }
                                }
                            }
                            // Fallback: attribution might directly have speakerIdentifier
                            if ([speakerLabel isEqualToString:@"Unknown"]) {
                                SEL idSel = NSSelectorFromString(@"speakerIdentifier");
                                if ([attribution respondsToSelector:idSel]) {
                                    NSString *sid = ((id (*)(id, SEL))objc_msgSend)(attribution, idSel);
                                    if (sid.length > 0) {
                                        speakerLabel = [NSString stringWithFormat:@"Speaker %@", sid];
                                    }
                                }
                            }
                        }
                    }
                    [speakerNames addObject:speakerLabel];
                }

                if (timestamp >= trimStart && timestamp < trimStart + trimDuration) {
                    SpliceKitTranscriptWord *word = [[SpliceKitTranscriptWord alloc] init];
                    word.text = text;
                    word.startTime = timelineStart + (timestamp - trimStart);
                    word.duration = MIN(duration, (trimStart + trimDuration) - timestamp);
                    word.confidence = confidence;
                    word.clipHandle = clipHandle;
                    word.clipTimelineStart = timelineStart;
                    word.sourceMediaOffset = trimStart;
                    word.sourceMediaTime = timestamp; // raw time in source file (immutable)
                    word.sourceMediaPath = audioURL.path;
                    word.speaker = speakerLabel;
                    [words addObject:word];
                }
            }

            if (useSpeakerDiarization) {
                SpliceKit_log(@"[Transcript] Got %lu words with %lu unique speakers from segments",
                    (unsigned long)words.count, (unsigned long)speakerNames.count);
            } else {
                SpliceKit_log(@"[Transcript] Got %lu words from segments", (unsigned long)words.count);
            }
            completion(words, nil);
        });
}

@end
