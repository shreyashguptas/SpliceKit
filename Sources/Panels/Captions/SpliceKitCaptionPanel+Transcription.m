//
//  SpliceKitCaptionPanel+Transcription.m
//  Transcribing the timeline for captions: the transcriber binaries, collecting
//  the timeline clips and running the transcription.
//

#import "SpliceKitCaptionPanel+Private.h"

@implementation SpliceKitCaptionPanel (Transcription)

- (void)transcriptionFinishedWithWords:(NSArray<SpliceKitTranscriptWord *> *)words {
    NSArray<SpliceKitTranscriptWord *> *normalizedWords =
        [self normalizedCaptionWordsFromWords:words context:@"Transcriber output"];
    @synchronized (self.mutableWords) {
        [self.mutableWords removeAllObjects];
        [self.mutableWords addObjectsFromArray:normalizedWords ?: @[]];
    }

    self.status = SpliceKitCaptionStatusReady;
    [self regroupSegments];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.spinner.hidden = YES;
        [self.spinner stopAnimation:nil];
        self.transcribeButton.enabled = YES;
        self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu words, %lu segments",
            (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSegments.count];
    });

    SpliceKit_log(@"[Captions] Transcription complete: %lu words",
                  (unsigned long)self.mutableWords.count);
}

- (void)transcriptionFailedWithError:(NSString *)error {
    self.status = SpliceKitCaptionStatusError;
    self.errorMessage = error;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.spinner.hidden = YES;
        [self.spinner stopAnimation:nil];
        self.transcribeButton.enabled = YES;
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Error: %@", error];
    });
    SpliceKit_log(@"[Captions] Transcription error: %@", error);
}

#pragma mark - Parakeet Transcription Engine

- (NSString *)parakeetTranscriberPath {
    return [self transcriberBinaryPathForName:@"parakeet-transcriber"];
}

- (NSString *)whisperTranscriberPath {
    return [self transcriberBinaryPathForName:@"whisper-transcriber"];
}

- (NSString *)transcriberBinaryPathForName:(NSString *)name {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. Inside the FCP framework bundle (deployed by patcher)
    NSString *buildDir = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Contents/Frameworks/SpliceKit.framework/Versions/A/Resources"];
    NSString *builtPath = [buildDir stringByAppendingPathComponent:name];
    if ([fm fileExistsAtPath:builtPath]) return builtPath;

    // 2. Standard tool locations
    NSString *home = NSHomeDirectory();
    NSArray *searchPaths = @[
        [home stringByAppendingPathComponent:[@"Applications/SpliceKit/tools/" stringByAppendingString:name]],
        [home stringByAppendingPathComponent:[@"Library/Application Support/SpliceKit/tools/" stringByAppendingString:name]],
        [home stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Library/Caches/SpliceKit/tools/%@/.build/release/%@", name, name]],
    ];
    for (NSString *path in searchPaths) {
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

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
    } @catch (NSException *e) {}

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
    } @catch (NSException *e) {}

    // Chain 3: KVC paths
    @try {
        id url = [clip valueForKeyPath:@"media.fileURL"];
        if ([url isKindOfClass:[NSURL class]]) return url;
    } @catch (NSException *e) {}
    @try {
        id url = [clip valueForKeyPath:@"clipInPlace.asset.originalMediaURL"];
        if ([url isKindOfClass:[NSURL class]]) return url;
    } @catch (NSException *e) {}

    return nil;
}

- (void)collectClipsFrom:(NSArray *)items
            primaryObject:(id)primaryObject
               atTimeline:(double *)timelinePos
                     into:(NSMutableArray *)clipInfos {
    for (id item in items) {
        NSString *className = NSStringFromClass([item class]);
        double itemTimelineStart = *timelinePos;

        double clipDuration = 0;
        if ([item respondsToSelector:@selector(duration)]) {
            SpliceKitCaption_CMTime d = ((SpliceKitCaption_CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
            clipDuration = SpliceKitCaption_CMTimeToSeconds(d);
        }

        BOOL isMedia = [className containsString:@"MediaComponent"];
        BOOL isCollection = [className containsString:@"Collection"] || [className containsString:@"AnchoredClip"];
        BOOL isTransition = [className containsString:@"Transition"];

        if (isMedia && clipDuration > 0) {
            [self addTimelineObject:item defaultTimeline:itemTimelineStart primaryObject:primaryObject into:clipInfos];

        } else if (isCollection && clipDuration > 0) {
            [self addTimelineObject:item defaultTimeline:itemTimelineStart primaryObject:primaryObject into:clipInfos];
        }

        for (id anchoredItem in [self anchoredItemsForTimelineItem:item]) {
            [self addTimelineObject:anchoredItem defaultTimeline:itemTimelineStart primaryObject:primaryObject into:clipInfos];
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

    SEL rangeSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (![primaryObject respondsToSelector:rangeSel]) return NO;

    @try {
        SpliceKitCaption_CMTimeRange range =
            ((SpliceKitCaption_CMTimeRange (*)(id, SEL, id))STRET_MSG)(primaryObject, rangeSel, item);
        double start = SpliceKitCaption_CMTimeToSeconds(range.start);
        double duration = SpliceKitCaption_CMTimeToSeconds(range.duration);
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
        SpliceKitCaption_CMTime offset =
            ((SpliceKitCaption_CMTime (*)(id, SEL))STRET_MSG)(item, offsetSel);
        return SpliceKitCaption_CMTimeToSeconds(offset);
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
    BOOL isCollection = [className containsString:@"Collection"] || [className containsString:@"AnchoredClip"];
    if (!isMedia && !isCollection) return;

    double clipDuration = 0;
    if ([item respondsToSelector:@selector(duration)]) {
        SpliceKitCaption_CMTime d = ((SpliceKitCaption_CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
        clipDuration = SpliceKitCaption_CMTimeToSeconds(d);
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

    if (isMedia) {
        [self addMediaClip:item timelineObject:item duration:effectiveDuration atTimeline:timelineStart into:clipInfos];
        return;
    }

    id innerMedia = [self findFirstMediaInContainer:item];
    if (!innerMedia) return;

    double collTrimStart = 0;
    SEL crSel = NSSelectorFromString(@"clippedRange");
    if ([item respondsToSelector:crSel]) {
        NSMethodSignature *sig = [item methodSignatureForSelector:crSel];
        if (sig && [sig methodReturnLength] == sizeof(SpliceKitCaption_CMTimeRange)) {
            SpliceKitCaption_CMTimeRange range;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:item];
            [inv setSelector:crSel];
            [inv invoke];
            [inv getReturnValue:&range];
            collTrimStart = SpliceKitCaption_CMTimeToSeconds(range.start);
        }
    }

    [self addMediaClip:innerMedia
          timelineObject:item
               duration:effectiveDuration
              trimStart:collTrimStart
             atTimeline:timelineStart
                   into:clipInfos];
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
    SEL unclippedSel = NSSelectorFromString(@"unclippedRange");
    if ([clip respondsToSelector:unclippedSel]) {
        NSMethodSignature *sig = [clip methodSignatureForSelector:unclippedSel];
        if (sig && [sig methodReturnLength] == sizeof(SpliceKitCaption_CMTimeRange)) {
            SpliceKitCaption_CMTimeRange range;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:clip];
            [inv setSelector:unclippedSel];
            [inv invoke];
            [inv getReturnValue:&range];
            trimStart = SpliceKitCaption_CMTimeToSeconds(range.start);
        }
    }
    [self addMediaClip:clip
          timelineObject:timelineObject
               duration:clipDuration
              trimStart:trimStart
             atTimeline:timelinePos
                   into:clipInfos];
}

- (void)addMediaClip:(id)clip timelineObject:(id)timelineObject duration:(double)clipDuration trimStart:(double)trimStart atTimeline:(double)timelinePos into:(NSMutableArray *)clipInfos {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"timelineStart"] = @(timelinePos);
    info[@"duration"] = @(clipDuration);
    info[@"trimStart"] = @(trimStart);
    info[@"handle"] = SpliceKit_storeHandle(clip);
    if (timelineObject) info[@"timelineObject"] = timelineObject;
    if (clip) info[@"mediaObject"] = clip;

    // Get the media's timecode origin (unclippedRange.start) for coordinate conversion.
    double mediaOrigin = 0;
    SEL ucSel = NSSelectorFromString(@"unclippedRange");
    if ([clip respondsToSelector:ucSel]) {
        NSMethodSignature *sig = [clip methodSignatureForSelector:ucSel];
        if (sig && [sig methodReturnLength] == sizeof(SpliceKitCaption_CMTimeRange)) {
            SpliceKitCaption_CMTimeRange range;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:clip];
            [inv setSelector:ucSel];
            [inv invoke];
            [inv getReturnValue:&range];
            mediaOrigin = SpliceKitCaption_CMTimeToSeconds(range.start);
        }
    }
    info[@"mediaOrigin"] = @(mediaOrigin);

    NSURL *mediaURL = [self getMediaURLForClip:clip];
    if (mediaURL) info[@"mediaURL"] = mediaURL;
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

- (void)performCaptionTranscription {
    NSString *engineID = [self currentEngineID];

    // Engine-specific resolution: binary path, model arg, user-facing label.
    NSString *binaryPath = nil;
    NSString *modelArg = nil;
    NSString *engineLabel = nil;
    NSString *binaryName = nil;
    if ([engineID isEqualToString:@"whisperLargeV3"]) {
        binaryPath = [self whisperTranscriberPath];
        modelArg = @"large-v3";
        engineLabel = @"Whisper large-v3";
        binaryName = @"whisper-transcriber";
    } else if ([engineID isEqualToString:@"whisperLargeV3Turbo"]) {
        binaryPath = [self whisperTranscriberPath];
        modelArg = @"large-v3-turbo";
        engineLabel = @"Whisper large-v3-turbo";
        binaryName = @"whisper-transcriber";
    } else {
        binaryPath = [self parakeetTranscriberPath];
        modelArg = @"v3";
        engineLabel = @"Parakeet v3";
        binaryName = @"parakeet-transcriber";
    }

    SpliceKit_log(@"[Captions] Starting transcription with engine: %@", engineLabel);

    if (!binaryPath) {
        [self transcriptionFailedWithError:
            [NSString stringWithFormat:@"%@ transcriber not found. Re-run the SpliceKit patcher, or pick a different engine.", engineLabel]];
        return;
    }
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:binaryPath]) {
        [self transcriptionFailedWithError:
            [NSString stringWithFormat:@"%@ binary is not executable. Try: chmod +x ~/Applications/SpliceKit/tools/%@", engineLabel, binaryName]];
        return;
    }

    SpliceKit_log(@"[Captions] Using %@ at: %@", binaryName, binaryPath);
    SpliceKitTranscriptDiag_logBinaryInfo(binaryPath);

    // Collect clips from the active timeline
    __block NSArray *clips = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                [self transcriptionFailedWithError:@"No active timeline. Open a project first."];
                return;
            }

            // Detect frame rate
            if ([timeline respondsToSelector:@selector(sequenceFrameDuration)]) {
                SpliceKitCaption_CMTime fd = ((SpliceKitCaption_CMTime (*)(id, SEL))STRET_MSG)(
                    timeline, @selector(sequenceFrameDuration));
                if (fd.timescale > 0 && fd.value > 0) {
                    self.frameRate = (double)fd.timescale / fd.value;
                    self.fdNum = (int)fd.value;
                    self.fdDen = (int)fd.timescale;
                }
            }

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) { [self transcriptionFailedWithError:@"No sequence in timeline."]; return; }

            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject))
                : nil;

            NSString *collectError = nil;
            clips = [self collectClipInfosForSequence:sequence
                                         primaryObject:primaryObj
                                          errorMessage:&collectError];
            if (!clips) {
                [self transcriptionFailedWithError:collectError ?: @"No items on timeline."];
                return;
            }
        } @catch (NSException *e) {
            [self transcriptionFailedWithError:[NSString stringWithFormat:@"Error reading timeline: %@", e.reason]];
        }
    });

    if (!clips || clips.count == 0) {
        if (self.status != SpliceKitCaptionStatusError) {
            [self transcriptionFailedWithError:@"No media clips found on timeline."];
        }
        return;
    }

    SpliceKit_log(@"[Captions] Found %lu items on timeline", (unsigned long)clips.count);
    SpliceKitTranscriptDiag_logClipInfos(clips, engineLabel);

    // Filter to clips with media URLs
    NSMutableArray *transcribableClips = [NSMutableArray array];
    for (NSDictionary *clipInfo in clips) {
        if (!clipInfo[@"mediaURL"]) continue;
        double dur = [clipInfo[@"duration"] doubleValue];
        if (dur < 0.5) continue;
        [transcribableClips addObject:clipInfo];
    }

    if (transcribableClips.count == 0) {
        [self transcriptionFailedWithError:@"No transcribable clips found on timeline."];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Transcribing %lu clips with %@...",
            (unsigned long)transcribableClips.count, engineLabel];
    });

    // Build batch manifest — deduplicate source files
    NSString *manifestPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_caption_batch.json"];
    NSMutableOrderedSet *uniqueFiles = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *clipInfo in transcribableClips) {
        NSURL *mediaURL = clipInfo[@"mediaURL"];
        [uniqueFiles addObject:mediaURL.path];
    }
    NSMutableArray *manifestEntries = [NSMutableArray array];
    for (NSString *file in uniqueFiles) {
        [manifestEntries addObject:@{@"file": file}];
    }
    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifestEntries options:0 error:nil];
    [manifestData writeToFile:manifestPath atomically:YES];
    SpliceKitTranscriptDiag_logBatchManifest(manifestEntries);

    SpliceKit_log(@"[Captions] %@ batch: %lu clips, %lu unique source files",
        engineLabel, (unsigned long)transcribableClips.count, (unsigned long)uniqueFiles.count);

    // Run transcriber binary
    NSMutableArray *taskArgs = [NSMutableArray arrayWithObjects:@"--batch", manifestPath, @"--progress", @"--model", modelArg, nil];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = binaryPath;
    task.arguments = taskArgs;

    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;

    __block NSMutableData *stdoutAccum = [NSMutableData data];
    __block NSMutableData *stderrAccum = [NSMutableData data];
    stdoutPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length > 0) {
            @synchronized (stdoutAccum) {
                [stdoutAccum appendData:data];
            }
        }
    };

    // Stream stderr for progress updates
    stderrPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) return;
        @synchronized (stderrAccum) {
            [stderrAccum appendData:data];
        }
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) return;
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"PROGRESS:"]) {
                NSArray *parts = [line componentsSeparatedByString:@":"];
                if (parts.count >= 3) {
                    NSString *msg = [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)]
                        componentsJoinedByString:@":"];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.statusLabel.stringValue = [NSString stringWithFormat:@"%@: %@", engineLabel, msg];
                    });
                }
            }
        }
    };

    NSTimeInterval taskStart = [NSDate timeIntervalSinceReferenceDate];
    SpliceKitTranscriptDiag_logProcessLaunch(binaryPath, taskArgs);
    @try {
        [task launch];
        SpliceKit_log(@"[Captions] %@ process started (PID %d)", engineLabel, task.processIdentifier);
        [task waitUntilExit];
    } @catch (NSException *e) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil;
        stderrPipe.fileHandleForReading.readabilityHandler = nil;
        [self transcriptionFailedWithError:[NSString stringWithFormat:@"Could not launch %@: %@", engineLabel, e.reason]];
        return;
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = nil;
    stderrPipe.fileHandleForReading.readabilityHandler = nil;

    NSData *remaining = [stdoutPipe.fileHandleForReading readDataToEndOfFile];
    if (remaining.length > 0) {
        @synchronized (stdoutAccum) {
            [stdoutAccum appendData:remaining];
        }
    }
    NSData *remainingStderr = [stderrPipe.fileHandleForReading readDataToEndOfFile];
    if (remainingStderr.length > 0) {
        @synchronized (stderrAccum) {
            [stderrAccum appendData:remainingStderr];
        }
    }
    NSTimeInterval taskElapsed = [NSDate timeIntervalSinceReferenceDate] - taskStart;

    [[NSFileManager defaultManager] removeItemAtPath:manifestPath error:nil];

    NSData *stdoutData;
    NSData *stderrData;
    @synchronized (stdoutAccum) {
        stdoutData = [stdoutAccum copy];
    }
    @synchronized (stderrAccum) {
        stderrData = [stderrAccum copy];
    }
    // -[NSTask terminationStatus] throws if task is still running. Defensively
    // ensure exit before reading. See APPLE-MACOS-1D / APPLE-MACOS-17.
    int exitCode = -1;
    @try {
        if (task.isRunning) {
            SpliceKit_log(@"[Captions] WARNING: task still running after waitUntilExit; terminating");
            [task terminate];
            [task waitUntilExit];
        }
        exitCode = task.terminationStatus;
    } @catch (NSException *e) {
        SpliceKit_log(@"[Captions] ERROR: failed to read terminationStatus: %@", e.reason);
        exitCode = -1;
    }
    SpliceKitTranscriptDiag_logProcessExit(exitCode, stdoutData, stderrData, taskElapsed);

    if (exitCode != 0) {
        SpliceKit_log(@"[Captions] %@ failed (exit code %d)", engineLabel, exitCode);
        [self transcriptionFailedWithError:[NSString stringWithFormat:@"%@ transcription failed (exit code %d). Check log for details.", engineLabel, exitCode]];
        return;
    }

    // Parse JSON output
    NSData *jsonData = stdoutData;

    if (jsonData.length == 0) {
        [self transcriptionFailedWithError:[NSString stringWithFormat:@"%@ produced no output. The audio may be silent or too short.", engineLabel]];
        return;
    }
    SpliceKitTranscriptDiag_inspectRawOutput(jsonData);

    // CoreML's E5RT runtime can print error messages to stdout before the JSON.
    // Detect and strip any non-JSON prefix so parsing succeeds.
    NSString *rawOutput = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    if (rawOutput && [rawOutput hasPrefix:@"E5RT "]) {
        NSRange bracketRange = [rawOutput rangeOfString:@"["];
        if (bracketRange.location != NSNotFound) {
            NSString *errPrefix = [rawOutput substringToIndex:bracketRange.location];
            SpliceKit_log(@"[Captions] CoreML warning on stdout (stripped): %@", [errPrefix stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
            rawOutput = [rawOutput substringFromIndex:bracketRange.location];
            jsonData = [rawOutput dataUsingEncoding:NSUTF8StringEncoding];
        }
    }

    NSError *jsonError = nil;
    NSArray *batchResults = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];
    if (![batchResults isKindOfClass:[NSArray class]]) {
        [self transcriptionFailedWithError:[NSString stringWithFormat:@"%@ returned unexpected output. Check the log for details.", engineLabel]];
        return;
    }

    // Map results back to clips
    SpliceKitTranscriptDiag_logParsedResults(batchResults);
    NSMutableDictionary *resultsByFile = [NSMutableDictionary dictionary];
    for (NSDictionary *result in batchResults) {
        NSString *file = result[@"file"];
        NSArray *words = result[@"words"];
        if (file && [words isKindOfClass:[NSArray class]]) {
            resultsByFile[file] = words;
        }
    }

    // Build words array
    NSMutableArray<SpliceKitTranscriptWord *> *allWords = [NSMutableArray array];
    for (NSDictionary *clipInfo in transcribableClips) {
        NSURL *mediaURL = clipInfo[@"mediaURL"];
        double timelineStart = [clipInfo[@"timelineStart"] doubleValue];
        double trimStart = [clipInfo[@"trimStart"] doubleValue];
        double clipDuration = [clipInfo[@"duration"] doubleValue];
        double mediaOrigin = [clipInfo[@"mediaOrigin"] doubleValue];
        NSString *clipHandle = clipInfo[@"handle"];

        NSArray *wordDicts = resultsByFile[mediaURL.path];
        if (!wordDicts) {
            SpliceKitTranscriptDiag_logWordFiltering(mediaURL.lastPathComponent,
                @[], trimStart, mediaOrigin, clipDuration, 0);
            continue;
        }

        // Convert trimStart from FCP's timecode coordinate space to file-relative
        double fileRelativeTrimStart = trimStart - mediaOrigin;
        NSUInteger wordsAddedForClip = 0;

        for (NSDictionary *wd in wordDicts) {
            NSString *text = wd[@"word"];
            double startTime = [wd[@"startTime"] doubleValue];
            double endTime = [wd[@"endTime"] doubleValue];
            double confidence = [wd[@"confidence"] doubleValue];

            if (startTime >= fileRelativeTrimStart && startTime < fileRelativeTrimStart + clipDuration) {
                SpliceKitTranscriptWord *word = [[SpliceKitTranscriptWord alloc] init];
                word.text = text;
                word.startTime = timelineStart + (startTime - fileRelativeTrimStart);
                word.duration = MIN(endTime - startTime, (fileRelativeTrimStart + clipDuration) - startTime);
                word.endTime = word.startTime + word.duration;
                word.confidence = confidence;
                word.clipHandle = clipHandle;
                word.clipTimelineStart = timelineStart;
                word.sourceMediaOffset = trimStart;
                word.sourceMediaTime = startTime + mediaOrigin;
                word.sourceMediaPath = mediaURL.path;
                [allWords addObject:word];
                wordsAddedForClip++;
            }
        }
        SpliceKitTranscriptDiag_logWordFiltering(mediaURL.lastPathComponent,
            wordDicts, trimStart, mediaOrigin, clipDuration, wordsAddedForClip);
    }

    SpliceKit_log(@"[Captions] %@ transcription complete: %lu words", engineLabel, (unsigned long)allWords.count);
    [self transcriptionFinishedWithWords:allWords];
}

@end
