//
//  SpliceKitCaptionPanel.m
//  Social media-style captions — word-by-word highlighted, animated titles
//  inserted directly into FCP's timeline via the Objective-C runtime.
//
//  FCPXML is still generated for export/debug/fallback. For each caption
//  segment we can build a <title> element with styled text, positioning,
//  and optional keyframe animations. For word-by-word highlight mode, each
//  word in a segment gets its own sequential title where that word is
//  highlighted and the rest are dimmed.
//
//  Transcription is handled directly via the Parakeet engine (no dependency
//  on the Transcript Editor panel).
//

#import "SpliceKitCaptionPanel.h"
#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitTranscriptDiagnostics.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <float.h>
#import <math.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>
#import "SpliceKitCaptionPanel+Private.h"

// ARM64 returns all structs via objc_msgSend; x86_64 needs _stret for structs >16 bytes.

NSNotificationName const SpliceKitCaptionDidGenerateNotification = @"SpliceKitCaptionDidGenerate";

// Forward declare properties for panel UI

id SpliceKitCaption_currentSequence(void);

double SpliceKitCaption_CMTimeToSeconds(SpliceKitCaption_CMTime t) {
    return (t.timescale > 0) ? (double)t.value / t.timescale : 0;
}

#pragma mark - Word-Progress Template Config (SpliceKit Caption)
//
// The legacy word-progress title export emits only 3 params per title:
// Content Position, Content Opacity (fade-out), and Custom Speed
// (word-progress keyframes). All other params (Animate=Word, Speed=Custom,
// highlight colors, glow, etc.) are baked into the Motion template defaults.
//
// Content Position and Content Opacity key paths are universal (on the Widget's
// Content layer 10003). Custom Speed path depends on the template hierarchy:
//   Content (10003) → Text (10061) → behaviors (4) → SeqText (500001) → Controls (201) → CustomSpeed (209)
//
NSString * const kWP_ContentPositionKey = @"9999/10003/1/100/101";
NSString * const kWP_ContentOpacityKey  = @"9999/10003/1/200/202";
// Sequence Text behavior key path captured from the legacy template hierarchy.
// Content(10003) → TextGroup01-03 → Text(10061) → SeqText(3291121706)
NSString * const kWP_CustomSpeedKey     = @"9999/10003/3336225139/3336225138/3336087544/10061/4/3291121706/201/209";
NSString * const kSpliceKitRuntimeCaptionTemplateMatch =
    @"Bumper:Opener.localized/Basic Title.localized/Basic Title.moti";
NSString * const kSpliceKitCaptionStorylineName = @"SpliceKit Storyline";

// The runtime/native insertion path uses FCP's built-in Basic Title template so
// connected titles render on any installation without any external template.

NSString *SpliceKitLegacyCaptionStorylineName(void) {
    static NSString *name = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        name = [@[ @"m", @"Captions Storyline" ] componentsJoinedByString:@""];
    });
    return name;
}

// Content opacity fade-out: 5 frames before clip end
const double kWP_FadeOutDuration = 5.0 / 30.0;

#pragma mark - SpliceKitCaptionPanel

@implementation SpliceKitCaptionPanel

+ (instancetype)sharedPanel {
    static SpliceKitCaptionPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SpliceKitCaptionPanel alloc] init];
        // Arm headless persistence restore so caption positions snap back to
        // their saved offset (e.g. lower-third) on FCP relaunch without
        // requiring the user to open the captions panel.
        [instance enableAutomaticRestore];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _style = [[SpliceKitCaptionStyle builtInPresets] firstObject];
        _mutableWords = [NSMutableArray array];
        _mutableSegments = [NSMutableArray array];
        _status = SpliceKitCaptionStatusIdle;
        _groupingMode = SpliceKitCaptionGroupingByWordCount;
        _maxWordsPerSegment = 3;
        _maxCharsPerSegment = 20;
        _maxSecondsPerSegment = 3.0;
        _fdNum = 100; _fdDen = 2400; // default 24fps
        _frameRate = 24.0;
        _videoWidth = 1920; _videoHeight = 1080;
    }
    return self;
}

#pragma mark - Panel Visibility

- (void)showPanel {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{
            [self showPanel];
        });
        return;
    }

    [self setupPanelIfNeeded];
    [self restorePersistedStateForCurrentSequenceIfNeeded];
    [self.panel makeKeyAndOrderFront:nil];

    // Motion title channels are not always ready at the first open tick after
    // relaunch, so repair after the panel is visible and the project is active.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.panel.isVisible) {
            [self repairPersistedCaptionsOnCurrentSequenceIfNeeded];
        }
    });
}

- (void)hidePanel {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{
            [self hidePanel];
        });
        return;
    }

    [self.panel orderOut:nil];
}

- (BOOL)isVisible {
    return self.panel && self.panel.isVisible;
}

#pragma mark - Style Management

- (void)setStyle:(SpliceKitCaptionStyle *)style {
    _style = [style copy];
    if (self.panel) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self syncUIFromStyle];
        });
    }
    if (!self.suppressPersistenceWrites) {
        [self persistCaptionDraftStateForCurrentSequence];
    }
}

- (SpliceKitCaptionStyle *)currentStyle {
    return [self.style copy];
}

#pragma mark - Transcription (Built-in Parakeet)

- (void)transcribeTimeline {
    self.status = SpliceKitCaptionStatusTranscribing;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.spinner.hidden = NO;
        [self.spinner startAnimation:nil];
        self.transcribeButton.enabled = NO;
        self.statusLabel.stringValue = @"Transcribing timeline...";
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self performCaptionTranscription];
    });
}

- (double)captionFrameDurationSeconds {
    double frameDuration = 0;
    if (self.fdNum > 0 && self.fdDen > 0) {
        frameDuration = (double)self.fdNum / (double)self.fdDen;
    }
    if ((!isfinite(frameDuration) || frameDuration <= 0) &&
        self.frameRate > 0 && isfinite(self.frameRate)) {
        frameDuration = 1.0 / self.frameRate;
    }
    if (!isfinite(frameDuration) || frameDuration <= 0) {
        frameDuration = 1.0 / 30.0;
    }
    return frameDuration;
}

- (NSArray<SpliceKitTranscriptWord *> *)normalizedCaptionWordsFromWords:(NSArray<SpliceKitTranscriptWord *> *)words
                                                                 context:(NSString *)context {
    if (words.count == 0) return @[];

    double minDuration = MAX([self captionFrameDurationSeconds], 0.001);
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSMutableArray<SpliceKitTranscriptWord *> *validWords = [NSMutableArray arrayWithCapacity:words.count];

    NSUInteger droppedWords = 0;
    NSUInteger clampedStarts = 0;
    NSUInteger repairedDurations = 0;
    NSUInteger trimmedOverlaps = 0;
    NSUInteger cappedToNextStart = 0;

    for (SpliceKitTranscriptWord *word in words) {
        if (![word isKindOfClass:[SpliceKitTranscriptWord class]]) {
            droppedWords++;
            continue;
        }

        NSString *trimmedText = [word.text ?: @"" stringByTrimmingCharactersInSet:trimSet];
        if (trimmedText.length == 0) {
            droppedWords++;
            continue;
        }

        double start = word.startTime;
        double end = word.endTime;
        double duration = word.duration;
        if (!isfinite(start)) {
            droppedWords++;
            continue;
        }

        if (start < 0) {
            double usableDuration = (isfinite(end) && end > start) ? (end - start)
                : ((isfinite(duration) && duration > 0) ? duration : minDuration);
            start = 0;
            end = start + usableDuration;
            clampedStarts++;
        }

        if (!isfinite(end) || end <= start) {
            if (isfinite(duration) && duration > 0) {
                end = start + duration;
            } else {
                end = start + minDuration;
            }
            repairedDurations++;
        }

        if (!isfinite(end) || end <= start) {
            droppedWords++;
            continue;
        }

        word.text = trimmedText;
        word.startTime = start;
        word.endTime = end;
        word.duration = end - start;
        [validWords addObject:word];
    }

    [validWords sortUsingComparator:^NSComparisonResult(SpliceKitTranscriptWord *a, SpliceKitTranscriptWord *b) {
        if (a.startTime < b.startTime) return NSOrderedAscending;
        if (a.startTime > b.startTime) return NSOrderedDescending;
        if (a.endTime < b.endTime) return NSOrderedAscending;
        if (a.endTime > b.endTime) return NSOrderedDescending;
        return [(a.text ?: @"") compare:(b.text ?: @"") options:NSCaseInsensitiveSearch];
    }];

    for (NSUInteger i = 0; i < validWords.count; i++) {
        SpliceKitTranscriptWord *word = validWords[i];
        double start = word.startTime;
        double end = word.endTime;

        if (i + 1 < validWords.count) {
            SpliceKitTranscriptWord *next = validWords[i + 1];
            if (isfinite(next.startTime) && next.startTime > start && end > next.startTime) {
                end = next.startTime;
                cappedToNextStart++;
            }
        }

        if (i > 0) {
            SpliceKitTranscriptWord *previous = validWords[i - 1];
            if (start < previous.endTime) {
                double boundary = start + ((previous.endTime - start) * 0.5);
                double minPreviousEnd = previous.startTime + minDuration;
                double maxPreviousEnd = end - minDuration;
                if (maxPreviousEnd >= minPreviousEnd) {
                    boundary = MIN(MAX(boundary, minPreviousEnd), maxPreviousEnd);
                    previous.endTime = boundary;
                    previous.duration = previous.endTime - previous.startTime;
                    start = boundary;
                } else {
                    start = previous.endTime;
                }
                trimmedOverlaps++;
            }
        }

        if (end <= start) {
            end = start + minDuration;
            repairedDurations++;
        }

        word.startTime = start;
        word.endTime = end;
        word.duration = end - start;
    }

    for (NSUInteger i = 1; i < validWords.count; i++) {
        SpliceKitTranscriptWord *previous = validWords[i - 1];
        SpliceKitTranscriptWord *word = validWords[i];
        if (word.startTime < previous.endTime) {
            word.startTime = previous.endTime;
            if (word.endTime <= word.startTime) {
                word.endTime = word.startTime + minDuration;
                repairedDurations++;
            }
            word.duration = word.endTime - word.startTime;
            trimmedOverlaps++;
        }
    }

    for (NSUInteger i = 0; i < validWords.count; i++) {
        validWords[i].wordIndex = i;
    }

    if (droppedWords > 0 || clampedStarts > 0 || repairedDurations > 0 ||
        trimmedOverlaps > 0 || cappedToNextStart > 0) {
        SpliceKit_log(@"[Captions][Timing] %@ normalized %lu words: dropped=%lu clampedStarts=%lu repairedDurations=%lu overlapRepairs=%lu cappedToNext=%lu",
                      context ?: @"caption words",
                      (unsigned long)validWords.count,
                      (unsigned long)droppedWords,
                      (unsigned long)clampedStarts,
                      (unsigned long)repairedDurations,
                      (unsigned long)trimmedOverlaps,
                      (unsigned long)cappedToNextStart);
    } else {
        SpliceKit_log(@"[Captions][Timing] %@ normalized %lu words with no repairs",
                      context ?: @"caption words",
                      (unsigned long)validWords.count);
    }

    return [validWords copy];
}

- (void)setWordsManually:(NSArray<NSDictionary *> *)wordDicts {
    NSMutableArray<SpliceKitTranscriptWord *> *words = [NSMutableArray arrayWithCapacity:wordDicts.count];
    for (NSUInteger i = 0; i < wordDicts.count; i++) {
        NSDictionary *d = wordDicts[i];
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        SpliceKitTranscriptWord *w = [[SpliceKitTranscriptWord alloc] init];
        w.text = d[@"text"] ?: d[@"word"] ?: @"";
        w.startTime = [d[@"startTime"] doubleValue];
        double explicitEnd = d[@"endTime"] ? [d[@"endTime"] doubleValue] : NAN;
        double duration = [d[@"duration"] doubleValue];
        if ((!isfinite(duration) || duration <= 0) && isfinite(explicitEnd) && explicitEnd > w.startTime) {
            duration = explicitEnd - w.startTime;
        }
        w.duration = duration;
        w.endTime = isfinite(explicitEnd) && explicitEnd > w.startTime ? explicitEnd : (w.startTime + duration);
        w.confidence = d[@"confidence"] ? [d[@"confidence"] doubleValue] : 1.0;
        w.wordIndex = i;
        w.speaker = d[@"speaker"] ?: @"Unknown";
        w.clipHandle = d[@"clipHandle"];
        w.clipTimelineStart = [d[@"clipTimelineStart"] doubleValue];
        w.sourceMediaOffset = [d[@"sourceMediaOffset"] doubleValue];
        w.sourceMediaTime = [d[@"sourceMediaTime"] doubleValue];
        w.sourceMediaPath = d[@"sourceMediaPath"];
        [words addObject:w];
    }

    NSArray<SpliceKitTranscriptWord *> *normalizedWords =
        [self normalizedCaptionWordsFromWords:words context:@"Manual caption words"];
    @synchronized (self.mutableWords) {
        [self.mutableWords removeAllObjects];
        [self.mutableWords addObjectsFromArray:normalizedWords];
    }
    self.status = SpliceKitCaptionStatusReady;
    [self regroupSegments];
}

#pragma mark - Word Grouping

- (void)regroupSegments {
    NSMutableArray<SpliceKitCaptionSegment *> *segments = [NSMutableArray array];
    NSArray *words = nil;
    @synchronized (self.mutableWords) {
        words = [self.mutableWords copy];
    }
    if (words.count == 0) {
        self.mutableSegments = segments;
        return;
    }

    NSMutableArray<SpliceKitTranscriptWord *> *group = [NSMutableArray array];
    NSUInteger segIdx = 0;

    for (NSUInteger i = 0; i < words.count; i++) {
        SpliceKitTranscriptWord *word = words[i];
        BOOL shouldBreak = NO;

        // Force break on silence gaps (0.5s for social, 1.0s for others)
        if (group.count > 0) {
            double gap = word.startTime - ((SpliceKitTranscriptWord *)group.lastObject).endTime;
            double silenceThreshold = (self.groupingMode == SpliceKitCaptionGroupingSocial) ? 0.5 : 1.0;
            if (gap > silenceThreshold) shouldBreak = YES;
        }

        if (!shouldBreak && group.count > 0) {
            switch (self.groupingMode) {
                case SpliceKitCaptionGroupingByWordCount:
                    shouldBreak = (group.count >= self.maxWordsPerSegment);
                    break;
                case SpliceKitCaptionGroupingBySentence: {
                    NSString *prevText = ((SpliceKitTranscriptWord *)group.lastObject).text;
                    shouldBreak = [prevText hasSuffix:@"."] || [prevText hasSuffix:@"!"] ||
                                  [prevText hasSuffix:@"?"] || [prevText hasSuffix:@";"];
                    if (!shouldBreak) shouldBreak = (group.count >= 8);
                    break;
                }
                case SpliceKitCaptionGroupingByTime: {
                    double groupStart = ((SpliceKitTranscriptWord *)group.firstObject).startTime;
                    shouldBreak = (word.endTime - groupStart) > self.maxSecondsPerSegment;
                    break;
                }
                case SpliceKitCaptionGroupingByCharCount: {
                    NSUInteger totalChars = 0;
                    for (SpliceKitTranscriptWord *w in group) totalChars += w.text.length + 1;
                    shouldBreak = (totalChars + word.text.length > self.maxCharsPerSegment);
                    break;
                }
                case SpliceKitCaptionGroupingSocial: {
                    // Optimized for social media: 2-3 words, break on short pauses & punctuation
                    NSString *prevText = ((SpliceKitTranscriptWord *)group.lastObject).text;
                    BOOL sentenceEnd = [prevText hasSuffix:@"."] || [prevText hasSuffix:@"!"]
                                    || [prevText hasSuffix:@"?"];
                    BOOL hitMax = (group.count >= 3);
                    shouldBreak = sentenceEnd || hitMax;
                    break;
                }
            }
        }

        if (shouldBreak && group.count > 0) {
            SpliceKitCaptionSegment *seg = [self segmentFromWords:group index:segIdx++];
            [segments addObject:seg];
            [group removeAllObjects];
        }
        [group addObject:word];
    }

    // Flush remaining
    if (group.count > 0) {
        [segments addObject:[self segmentFromWords:group index:segIdx]];
    }

    self.mutableSegments = segments;
    SpliceKit_log(@"[Captions] Grouped %lu words into %lu segments",
                  (unsigned long)words.count, (unsigned long)segments.count);
    if (!self.suppressPersistenceWrites) {
        [self persistCaptionDraftStateForCurrentSequence];
    }
}

- (SpliceKitCaptionSegment *)segmentFromWords:(NSArray *)words index:(NSUInteger)idx {
    SpliceKitCaptionSegment *seg = [[SpliceKitCaptionSegment alloc] init];
    seg.words = [words copy];
    seg.startTime = ((SpliceKitTranscriptWord *)words.firstObject).startTime;
    seg.endTime = ((SpliceKitTranscriptWord *)words.lastObject).endTime;
    seg.duration = seg.endTime - seg.startTime;
    NSMutableArray *texts = [NSMutableArray array];
    for (SpliceKitTranscriptWord *w in words) { [texts addObject:w.text ?: @""]; }
    seg.text = [texts componentsJoinedByString:@" "];
    seg.segmentIndex = idx;
    return seg;
}

#pragma mark - Accessors

- (NSArray<SpliceKitCaptionSegment *> *)segments { return [self.mutableSegments copy]; }
- (NSArray<SpliceKitTranscriptWord *> *)words { return [self.mutableWords copy]; }

#pragma mark - Import Pipeline (polling-based)

// Poll a condition on the main thread. Blocks the calling (background) thread.
// Returns YES if condition became true before timeout, NO on timeout.
- (NSDictionary *)generateCaptions {
    [self ensurePersistedStateLoaded];

    SpliceKit_log(@"[Captions] generateCaptions called. Words: %lu, Segments: %lu",
                  (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSegments.count);

    // Auto-transcribe if no words yet
    if (self.mutableWords.count == 0) {
        SpliceKit_log(@"[Captions] Auto-transcribing timeline...");
        if (self.panel) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.stringValue = @"Transcribing timeline...";
            });
        }

        // Run Parakeet transcription synchronously (we're already off main thread)
        [self performCaptionTranscription];

        // Check if transcription produced results
        if (self.status == SpliceKitCaptionStatusError) {
            return @{@"error": self.errorMessage ?: @"Transcription failed"};
        }
    }

    if (self.mutableWords.count == 0) {
        self.status = SpliceKitCaptionStatusError;
        self.errorMessage = @"No words — transcription produced no results";
        self.lastGenerateResult = @{@"status": @"error", @"error": self.errorMessage};
        return @{@"error": @"No words — transcription produced no results"};
    }

    self.status = SpliceKitCaptionStatusGenerating;
    self.errorMessage = nil;
    self.lastGenerateResult = nil;
    if (self.panel) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.stringValue = @"Generating captions...";
            self.generateButton.enabled = NO;
        });
    }

    [self regroupSegments];
    if (self.mutableSegments.count == 0) {
        self.status = SpliceKitCaptionStatusError;
        self.errorMessage = @"No segments after grouping — check word timings";
        self.lastGenerateResult = @{@"status": @"error", @"error": self.errorMessage};
        return @{@"error": @"No segments after grouping — check word timings"};
    }
    [self detectTimelineProperties];

    SpliceKitCaptionStyle *s = self.style;
    double totalDuration = 0;
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        if (seg.endTime > totalDuration) totalDuration = seg.endTime;
    }
    totalDuration += 1.0;

    // ---------------------------------------------------------------
    // Generate SEGMENT-LEVEL FCPXML for export/debug (one title per segment).
    // Timeline insertion uses anchorWithPasteboard, not FCPXML import.
    // ---------------------------------------------------------------
    int titleCount = 0, tsCounter = 1;
    NSMutableString *xml = [self buildFCPXMLHeader:@"SpliceKit Captions"
                                     totalDuration:totalDuration
                                        titleCount:&titleCount
                                         tsCounter:&tsCounter];

    // Flat spine with absolute title offsets.
    // No gap containers, no spacer clips, no lanes — just titles directly in the spine.
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        [xml appendString:[self segmentTitleXMLForSegment:seg
                                                tsCounter:&tsCounter
                                                   indent:@"        "
                                                     lane:nil]];
        titleCount++;
    }

    [self appendFCPXMLFooter:xml];

    // Save segment-level FCPXML
    NSString *xmlPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_captions.fcpxml"];
    [xml writeToFile:xmlPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    SpliceKit_log(@"[Captions] Generated segment-level FCPXML: %d titles → %@", titleCount, xmlPath);

    // Also save word-level FCPXML to disk if highlight mode is on (for future use / manual import)
    NSString *wordLevelPath = nil;
    if (s.wordByWordHighlight && s.highlightColor) {
        wordLevelPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_captions_wordlevel.fcpxml"];
        NSString *wordXml = [self buildWordLevelFCPXML];
        if (wordXml) {
            [wordXml writeToFile:wordLevelPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            SpliceKit_log(@"[Captions] Word-level FCPXML saved to %@", wordLevelPath);
        }
    }

    // Store segment-level FCPXML for export/debug
    self.generatedFCPXML = xml;

    NSDictionary *directResult = [self addCaptionTitlesDirectlyToTimeline];
    BOOL directOK = (directResult[@"error"] == nil);
    NSUInteger insertedCount = directResult[@"insertedCount"]
        ? [directResult[@"insertedCount"] unsignedIntegerValue]
        : 0;
    NSUInteger removedExistingCaptionCollections = directResult[@"removedExistingCaptionCollections"]
        ? [directResult[@"removedExistingCaptionCollections"] unsignedIntegerValue]
        : 0;
    BOOL generatedWordLevelTitles = (insertedCount > (NSUInteger)titleCount &&
                                     insertedCount == self.mutableWords.count &&
                                     self.mutableWords.count > self.mutableSegments.count);
    NSString *successMsg = nil;
    if (generatedWordLevelTitles) {
        successMsg = [NSString stringWithFormat:@"Added %lu word-level captions from %d grouped segments",
                      (unsigned long)insertedCount, titleCount];
    } else {
        successMsg = insertedCount == (NSUInteger)titleCount
            ? [NSString stringWithFormat:@"Added %lu captions to timeline", (unsigned long)insertedCount]
            : [NSString stringWithFormat:@"Added %lu of %d captions to timeline",
                (unsigned long)insertedCount, titleCount];
    }
    if (removedExistingCaptionCollections > 0) {
        if (generatedWordLevelTitles) {
            successMsg = [NSString stringWithFormat:
                @"Replaced previous captions and added %lu word-level captions from %d grouped segments",
                (unsigned long)insertedCount, titleCount];
        } else {
            successMsg = insertedCount == (NSUInteger)titleCount
                ? [NSString stringWithFormat:@"Replaced previous captions and added %lu captions to timeline",
                    (unsigned long)insertedCount]
                : [NSString stringWithFormat:@"Replaced previous captions and added %lu of %d captions to timeline",
                    (unsigned long)insertedCount, titleCount];
        }
    }
    NSString *statusMsg = directOK
        ? successMsg
        : [NSString stringWithFormat:@"Caption insert failed — %@",
            directResult[@"error"] ?: [NSString stringWithFormat:@"FCPXML exported to %@", xmlPath]];
    self.status = directOK ? SpliceKitCaptionStatusReady : SpliceKitCaptionStatusError;
    self.errorMessage = directOK ? nil : (directResult[@"error"] ?: @"Caption insert failed");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateUIAfterGenerate:directOK message:statusMsg];
    });

    SpliceKit_log(@"[Captions] Direct insert result: %@", directResult);

    [[NSNotificationCenter defaultCenter] postNotificationName:SpliceKitCaptionDidGenerateNotification object:self];

    NSMutableDictionary *result = [@{
        @"status": directOK ? @"ok" : @"error",
        @"titleCount": @(titleCount),
        @"segmentCount": @(self.mutableSegments.count),
        @"wordCount": @(self.mutableWords.count),
        @"fcpxmlPath": xmlPath,
        @"message": statusMsg,
        @"importMethod": directOK ? @"directRuntime" : @"fcpxmlFallback",
    } mutableCopy];
    if (wordLevelPath) result[@"wordLevelFcpxmlPath"] = wordLevelPath;
    if (directResult[@"insertedCount"]) result[@"insertedCount"] = directResult[@"insertedCount"];
    if (directResult[@"warnings"]) result[@"warnings"] = directResult[@"warnings"];
    if (directResult[@"warning"]) result[@"warning"] = directResult[@"warning"];
    if (directResult[@"verification"]) result[@"verification"] = directResult[@"verification"];
    if (directResult[@"verificationWarning"]) result[@"verificationWarning"] = directResult[@"verificationWarning"];
    if (directResult[@"pasteHandled"]) result[@"pasteHandled"] = directResult[@"pasteHandled"];
    if (directResult[@"removedExistingCaptionCollections"]) {
        result[@"removedExistingCaptionCollections"] = directResult[@"removedExistingCaptionCollections"];
    }
    if (directResult[@"textAppliedCount"]) result[@"textAppliedCount"] = directResult[@"textAppliedCount"];
    if (directResult[@"positionApplied"]) result[@"positionApplied"] = directResult[@"positionApplied"];
    if (directResult[@"positionY"]) result[@"positionY"] = directResult[@"positionY"];
    if (directResult[@"debugPath"]) result[@"debugPath"] = directResult[@"debugPath"];
    if (!directOK && directResult[@"error"]) result[@"error"] = directResult[@"error"];
    self.lastGenerateResult = [result copy];
    if (directOK && insertedCount > 0) {
        [self persistGeneratedCaptionStateWithRuntimeEntries:[self runtimeEntriesForStyle:s] style:s];
    }
    return result;
}

- (void)updateUIAfterGenerate:(BOOL)success message:(NSString *)message {
    if (!self.panel) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.generateButton.enabled = YES;
        self.statusLabel.stringValue = message ?: @"Done";
    });
}

#pragma mark - Native Caption Generation (FFAnchoredCaption)

// Generates FCPXML with <caption> elements (FCP's native subtitle objects)
// and imports it via FFXMLTranslationTask. The importer's addCaption:toObject:
// creates FFAnchoredCaption objects, anchors them, and resolves lanes.
// This matches the path FCP uses for File > Import > Captions (SRT/ITT).

- (NSDictionary *)generateNativeCaptions:(NSString *)language format:(NSString *)format {
    SpliceKit_log(@"[NativeCaptions] generateNativeCaptions called. Words: %lu, Segments: %lu, lang=%@, fmt=%@",
                  (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSegments.count,
                  language, format);

    if (self.mutableWords.count == 0) {
        return @{@"error": @"No words — transcribe the timeline first"};
    }

    [self regroupSegments];
    if (self.mutableSegments.count == 0) {
        return @{@"error": @"No segments after grouping — check word timings"};
    }
    [self detectTimelineProperties];

    NSString *lang = language ?: @"en";
    NSString *fmt = format ?: @"ITT";
    int fdN = self.fdNum, fdD = self.fdDen;

    // Build FCPXML with <caption> elements — FCP's native subtitle format.
    // The FFXMLImporter.addCaption:toObject: handler creates FFAnchoredCaption
    // objects, sets up roles, anchors to the timeline, and resolves lanes.
    // We import via FFXMLTranslationTask (same as the existing title caption path).

    double totalDuration = 0;
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        if (seg.endTime > totalDuration) totalDuration = seg.endTime;
    }
    totalDuration += 1.0;

    NSString *totalDurStr = SpliceKitCaption_durRational(totalDuration, fdN, fdD);
    NSString *tempName = [NSString stringWithFormat:@"%@ %u",
        kCaptionImportProjectPrefix, (unsigned)(arc4random() % 10000)];

    // Caption role string: "ITT.en" format
    NSString *captionRole = [NSString stringWithFormat:@"ITT.%@", lang];

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n\n"];
    [xml appendString:@"<fcpxml version=\"1.11\">\n"];
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"r1\" name=\"FFVideoFormat%dx%dp%d\" "
        @"frameDuration=\"%d/%ds\" width=\"%d\" height=\"%d\"/>\n",
        self.videoWidth, self.videoHeight, (int)round(self.frameRate),
        fdN, fdD, self.videoWidth, self.videoHeight];
    [xml appendString:@"    </resources>\n"];
    [xml appendString:@"    <library>\n"];
    [xml appendFormat:@"        <event name=\"SpliceKit Captions\">\n"];
    [xml appendFormat:@"            <project name=\"%@\">\n", tempName];
    [xml appendFormat:@"                <sequence format=\"r1\" duration=\"%@\" "
        @"tcStart=\"0s\" tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\">\n", totalDurStr];
    [xml appendString:@"                    <spine>\n"];
    [xml appendFormat:@"                        <gap name=\"placeholder\" duration=\"%@\" start=\"0s\">\n",
        totalDurStr];

    NSUInteger captionCount = 0;
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        NSString *text = self.style.allCaps ? [seg.text uppercaseString] : seg.text;
        if (text.length == 0) continue;

        NSString *offsetStr = SpliceKitCaption_durRational(seg.startTime, fdN, fdD);
        NSString *durStr = SpliceKitCaption_durRational(MAX(seg.duration, 0.04), fdN, fdD);

        // <caption> uses offset (position in parent), duration, and lane.
        // The role uses "ITT.lang" format. No start= needed (defaults to 0s).
        // Text is plain (no text-style ref needed for simple captions).
        [xml appendFormat:@"                            <caption lane=\"1\" offset=\"%@\" "
            @"name=\"%@\" duration=\"%@\" role=\"%@\">\n",
            offsetStr,
            SpliceKitCaption_escapeXML(text),
            durStr, captionRole];
        [xml appendFormat:@"                                <text>%@</text>\n",
            SpliceKitCaption_escapeXML(text)];
        [xml appendString:@"                            </caption>\n"];
        captionCount++;
    }

    [xml appendString:@"                        </gap>\n"];
    [xml appendString:@"                    </spine>\n"];
    [xml appendString:@"                </sequence>\n"];
    [xml appendString:@"            </project>\n"];
    [xml appendString:@"        </event>\n"];
    [xml appendString:@"    </library>\n"];
    [xml appendString:@"</fcpxml>\n"];

    SpliceKit_log(@"[NativeCaptions] Built FCPXML with %lu <caption> elements, %lu bytes",
                  (unsigned long)captionCount, (unsigned long)xml.length);

    NSString *xmlPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_native_captions.fcpxml"];
    [xml writeToFile:xmlPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Import via FFXMLTranslationTask (same path as title captions)
    NSDictionary *importResult = SpliceKit_handlePasteboardImportXML(@{@"xml": xml});
    if (importResult[@"error"]) {
        return @{@"error": [NSString stringWithFormat:@"FCPXML import failed: %@", importResult[@"error"]],
                 @"fcpxmlPath": xmlPath};
    }

    SpliceKit_log(@"[NativeCaptions] Import OK — waiting for temp project");

    // Wait for temp project
    BOOL foundTemp = SpliceKitCaption_pollMainThread(^{
        return (BOOL)(SpliceKitCaption_findSequenceByPrefix(tempName) != nil);
    }, 5.0, 0.3);

    if (!foundTemp) {
        return @{@"error": @"Temp caption project not found after import",
                 @"fcpxmlPath": xmlPath,
                 @"captionCount": @(captionCount)};
    }

    // ---------------------------------------------------------------
    // Load temp project → select all → copy → switch back → paste
    // Same copy/paste approach as the title caption system.
    // ---------------------------------------------------------------
    __block id userSequence = nil;
    __block NSString *userSequenceName = nil;
    SpliceKit_executeOnMainThread(^{
        userSequence = SpliceKitCaption_currentSequence();
        if (userSequence) {
            userSequenceName = ((id (*)(id, SEL))objc_msgSend)(userSequence,
                NSSelectorFromString(@"displayName"));
        }
    });

    __block id tempSeq = nil;
    SpliceKit_executeOnMainThread(^{
        tempSeq = SpliceKitCaption_findSequenceByPrefix(tempName);
        if (!tempSeq) return;

        id appDelegate = [NSApp delegate];
        id editorContainer = ((id (*)(id, SEL))objc_msgSend)(appDelegate,
            NSSelectorFromString(@"activeEditorContainer"));
        if (!editorContainer) return;

        SEL loadSel = NSSelectorFromString(@"loadEditorForSequence:");
        if ([editorContainer respondsToSelector:loadSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(editorContainer, loadSel, tempSeq);
        }
    });

    // Wait for temp timeline to load
    BOOL tempReady = SpliceKitCaption_pollMainThread(^{
        id seq = SpliceKitCaption_currentSequence();
        if (!seq) return NO;
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq, NSSelectorFromString(@"displayName"));
        return [name hasPrefix:tempName];
    }, 5.0, 0.3);

    if (!tempReady) {
        SpliceKitCaption_deleteSequence(tempSeq);
        return @{@"error": @"Failed to load temp caption project",
                 @"fcpxmlPath": xmlPath};
    }

    [NSThread sleepForTimeInterval:0.5];

    // Select all + copy
    SpliceKit_executeOnMainThread(^{
        [NSApp sendAction:NSSelectorFromString(@"selectAll:") to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.3];
    SpliceKit_executeOnMainThread(^{
        [NSApp sendAction:NSSelectorFromString(@"copy:") to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.3];

    // Switch back to user's project
    SpliceKit_executeOnMainThread(^{
        // Re-verify userSequence is still valid
        if (userSequenceName) {
            for (id seq in SpliceKitCaption_allSequences()) {
                NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq,
                    NSSelectorFromString(@"displayName"));
                if ([name isEqualToString:userSequenceName]) {
                    userSequence = seq;
                    break;
                }
            }
        }

        id appDelegate = [NSApp delegate];
        id editorContainer = ((id (*)(id, SEL))objc_msgSend)(appDelegate,
            NSSelectorFromString(@"activeEditorContainer"));
        if (editorContainer && userSequence) {
            SEL loadSel = NSSelectorFromString(@"loadEditorForSequence:");
            if ([editorContainer respondsToSelector:loadSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(editorContainer, loadSel, userSequence);
            }
        }
    });

    // Wait for user's project to be active
    SpliceKitCaption_pollMainThread(^{
        id seq = SpliceKitCaption_currentSequence();
        if (!seq) return NO;
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq, NSSelectorFromString(@"displayName"));
        return (BOOL)(userSequenceName && [name isEqualToString:userSequenceName]);
    }, 5.0, 0.3);

    [NSThread sleepForTimeInterval:0.5];

    // Paste captions onto user's timeline
    SpliceKit_executeOnMainThread(^{
        [NSApp sendAction:NSSelectorFromString(@"deselectAll:") to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.2];
    SpliceKit_executeOnMainThread(^{
        [NSApp sendAction:NSSelectorFromString(@"paste:") to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.5];

    // Clean up temp project
    SpliceKit_executeOnMainThread(^{
        id tempToDelete = SpliceKitCaption_findSequenceByPrefix(tempName);
        if (tempToDelete && !SpliceKitCaption_deleteSequence(tempToDelete)) {
            SpliceKit_log(@"[NativeCaptions] Warning: temp project '%@' was not removed from the library",
                          tempName);
        }
    });

    SpliceKit_log(@"[NativeCaptions] Done: %lu captions via FCPXML import+paste", (unsigned long)captionCount);

    return @{
        @"status": @"ok",
        @"captionCount": @(captionCount),
        @"segmentCount": @(self.mutableSegments.count),
        @"wordCount": @(self.mutableWords.count),
        @"language": lang,
        @"format": fmt,
        @"grouping": @[@"words", @"sentence", @"time", @"chars", @"social"][(NSUInteger)MIN(self.groupingMode, 4)],
        @"fcpxmlPath": xmlPath,
        @"method": @"fcpxml_import_paste",
    };
}

#pragma mark - SRT / TXT Export

- (NSDictionary *)exportSRT:(NSString *)outputPath {
    [self ensurePersistedStateLoaded];

    if (self.mutableSegments.count == 0) {
        return @{@"error": @"No segments to export — transcribe first"};
    }

    NSMutableString *srt = [NSMutableString string];
    NSUInteger srtIndex = 1;
    for (NSUInteger i = 0; i < self.mutableSegments.count; i++) {
        SpliceKitCaptionSegment *seg = self.mutableSegments[i];
        NSString *text = self.style.allCaps ? [seg.text uppercaseString] : seg.text;
        // Skip empty segments
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) continue;
        [srt appendFormat:@"%lu\n", (unsigned long)srtIndex++];
        [srt appendFormat:@"%@ --> %@\n", [self srtTimestamp:seg.startTime], [self srtTimestamp:seg.endTime]];
        [srt appendFormat:@"%@\n\n", trimmed];
    }

    NSError *err = nil;
    [srt writeToFile:outputPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) {
        return @{@"error": [NSString stringWithFormat:@"Write failed: %@", err.localizedDescription]};
    }

    return @{@"status": @"ok", @"path": outputPath, @"segmentCount": @(self.mutableSegments.count)};
}

- (NSDictionary *)exportTXT:(NSString *)outputPath {
    [self ensurePersistedStateLoaded];

    if (self.mutableSegments.count == 0) {
        return @{@"error": @"No segments to export — transcribe first"};
    }

    NSMutableString *txt = [NSMutableString string];
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        NSString *text = self.style.allCaps ? [seg.text uppercaseString] : seg.text;
        [txt appendFormat:@"%@\n", text];
    }

    NSError *err = nil;
    [txt writeToFile:outputPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) {
        return @{@"error": [NSString stringWithFormat:@"Write failed: %@", err.localizedDescription]};
    }

    return @{@"status": @"ok", @"path": outputPath, @"segmentCount": @(self.mutableSegments.count)};
}

- (NSString *)srtTimestamp:(double)seconds {
    int h = (int)(seconds / 3600);
    int m = (int)(fmod(seconds, 3600) / 60);
    int s = (int)fmod(seconds, 60);
    int ms = (int)((seconds - floor(seconds)) * 1000);
    return [NSString stringWithFormat:@"%02d:%02d:%02d,%03d", h, m, s, ms];
}

#pragma mark - Persistence Restore

- (void)restorePersistedStateForCurrentSequenceIfNeeded {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{
            [self restorePersistedStateForCurrentSequenceIfNeeded];
        });
        return;
    }

    id sequence = SpliceKitCaption_currentSequence();
    if (!sequence) return;

    NSDictionary *state = SpliceKit_loadSequenceState(sequence);
    NSDictionary *captions = [state[@"captions"] isKindOfClass:[NSDictionary class]] ? state[@"captions"] : nil;
    NSDictionary *transcript = [state[@"transcript"] isKindOfClass:[NSDictionary class]] ? state[@"transcript"] : nil;
    NSString *sequenceKey = [state[@"sequenceIdentity"] isKindOfClass:[NSDictionary class]]
        ? state[@"sequenceIdentity"][@"cacheKey"] : nil;
    if (!captions && !transcript) return;
    if (sequenceKey.length > 0 &&
        [self.lastRestoredSequenceKey isEqualToString:sequenceKey] &&
        self.mutableWords.count > 0) {
        return;
    }

    self.suppressPersistenceWrites = YES;

    NSDictionary *draftStyle = [captions[@"draftStyle"] isKindOfClass:[NSDictionary class]] ? captions[@"draftStyle"] : nil;
    if (draftStyle) {
        _style = [SpliceKitCaptionStyle fromDictionary:draftStyle];
    }

    NSDictionary *draftGrouping = [captions[@"draftGrouping"] isKindOfClass:[NSDictionary class]] ? captions[@"draftGrouping"] : nil;
    if (draftGrouping) {
        NSString *mode = draftGrouping[@"mode"];
        if ([mode isEqualToString:@"sentence"]) self.groupingMode = SpliceKitCaptionGroupingBySentence;
        else if ([mode isEqualToString:@"time"]) self.groupingMode = SpliceKitCaptionGroupingByTime;
        else if ([mode isEqualToString:@"chars"]) self.groupingMode = SpliceKitCaptionGroupingByCharCount;
        else if ([mode isEqualToString:@"social"]) self.groupingMode = SpliceKitCaptionGroupingSocial;
        else self.groupingMode = SpliceKitCaptionGroupingByWordCount;

        if (draftGrouping[@"maxWords"]) self.maxWordsPerSegment = [draftGrouping[@"maxWords"] unsignedIntegerValue];
        if (draftGrouping[@"maxChars"]) self.maxCharsPerSegment = [draftGrouping[@"maxChars"] unsignedIntegerValue];
        if (draftGrouping[@"maxSeconds"]) self.maxSecondsPerSegment = [draftGrouping[@"maxSeconds"] doubleValue];
    }

    NSArray *wordDicts = [transcript[@"words"] isKindOfClass:[NSArray class]] ? transcript[@"words"] : nil;
    if (wordDicts.count > 0) {
        NSMutableArray<SpliceKitTranscriptWord *> *restoredWords = [NSMutableArray arrayWithCapacity:wordDicts.count];
        for (NSDictionary *wordDict in wordDicts) {
            SpliceKitTranscriptWord *word = SpliceKitCaption_transcriptWordFromDictionary(wordDict);
            if (word) [restoredWords addObject:word];
        }
        NSArray<SpliceKitTranscriptWord *> *normalizedWords =
            [self normalizedCaptionWordsFromWords:restoredWords context:@"Restored caption words"];
        @synchronized (self.mutableWords) {
            [self.mutableWords removeAllObjects];
            [self.mutableWords addObjectsFromArray:normalizedWords];
        }
        self.status = SpliceKitCaptionStatusReady;
        self.errorMessage = nil;
        if (transcript[@"frameRate"]) self.frameRate = [transcript[@"frameRate"] doubleValue];
        [self regroupSegments];
    }

    self.lastRestoredSequenceKey = sequenceKey;
    if (self.panel) {
        [self syncUIFromStyle];
        if (self.mutableWords.count > 0) {
            self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu words, %lu segments (restored)",
                (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSegments.count];
        }
    }

    self.suppressPersistenceWrites = NO;
}

- (void)repairPersistedCaptionsOnCurrentSequenceIfNeeded {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{
            [self repairPersistedCaptionsOnCurrentSequenceIfNeeded];
        });
        return;
    }

    id sequence = SpliceKitCaption_currentSequence();
    if (!sequence) {
        SpliceKit_log(@"[Captions] Persisted caption repair skipped: no active sequence");
        return;
    }

    NSDictionary *state = SpliceKit_loadSequenceState(sequence);
    NSDictionary *captions = [state[@"captions"] isKindOfClass:[NSDictionary class]] ? state[@"captions"] : nil;
    NSArray *runtimeEntries = [captions[@"generatedRuntimeEntries"] isKindOfClass:[NSArray class]]
        ? captions[@"generatedRuntimeEntries"] : nil;
    NSDictionary *styleDict = [captions[@"generatedStyle"] isKindOfClass:[NSDictionary class]]
        ? captions[@"generatedStyle"] : nil;
    NSString *sequenceKey = [state[@"sequenceIdentity"] isKindOfClass:[NSDictionary class]]
        ? state[@"sequenceIdentity"][@"cacheKey"] : nil;
    BOOL panelVisible = (self.panel && self.panel.isVisible);
    SpliceKit_log(@"[Captions] Persisted caption repair begin: sequenceKey=%@ panelVisible=%@ runtimeEntries=%lu",
                  sequenceKey ?: @"<nil>",
                  panelVisible ? @"YES" : @"NO",
                  (unsigned long)runtimeEntries.count);
    // Do NOT gate on panel visibility here: the Motion generator's position/scale
    // channel values don't persist into the FCP project XML, so on cold relaunch
    // titles render at the template's default (center) until something re-applies
    // them. We run the repair headlessly so captions snap back to their correct
    // lower-third position without requiring the user to open the panel.
    if (runtimeEntries.count == 0 || !styleDict) {
        SpliceKit_log(@"[Captions] Persisted caption repair skipped: runtime entries or style missing");
        return;
    }
    if (panelVisible) {
        if (sequenceKey.length > 0 && [self.lastHealedSequenceKey isEqualToString:sequenceKey]) {
            SpliceKit_log(@"[Captions] Persisted caption repair skipped: panel-visible restore already completed for %@", sequenceKey);
            return;
        }
    } else {
        if (sequenceKey.length > 0 && [self.lastHeadlessRestoredSequenceKey isEqualToString:sequenceKey]) {
            SpliceKit_log(@"[Captions] Persisted caption repair skipped: headless restore already completed for %@", sequenceKey);
            return;
        }
    }

    SpliceKitCaptionStyle *generatedStyle = [SpliceKitCaptionStyle fromDictionary:styleDict];
    CGFloat yOffset = [self yOffsetForStyle:generatedStyle];
    BOOL needsPosition = (generatedStyle.position != SpliceKitCaptionPositionCenter || generatedStyle.customYOffset != 0);

    __block NSUInteger textRestoredCount = 0;
    __block NSUInteger plainFallbackCount = 0;
    __block NSUInteger styledAppliedCount = 0;
    __block NSUInteger styledExpectedCount = 0;
    __block NSUInteger titleCount = 0;
    __block NSUInteger positionAppliedCount = 0;
    SpliceKit_executeOnMainThread(^{
        NSArray *titles = SpliceKitCaption_collectTitlesForPersistedStorylines(sequence);
        titleCount = titles.count;
        NSUInteger count = MIN(titles.count, runtimeEntries.count);

        for (NSUInteger i = 0; i < count; i++) {
            id title = titles[i];
            NSDictionary *entry = runtimeEntries[i];
            NSString *text = [entry[@"text"] isKindOfClass:[NSString class]] ? entry[@"text"] : @"";
            NSArray *displayWords = [entry[@"words"] isKindOfClass:[NSArray class]] ? entry[@"words"] : nil;
            NSNumber *activeWordIndex = entry[@"activeWordIndex"];
            BOOL didRestoreTextForTitle = NO;

            @try {
                BOOL isHighlightEntry = ([activeWordIndex isKindOfClass:[NSNumber class]] &&
                                         displayWords.count > 0);
                if (isHighlightEntry) {
                    styledExpectedCount++;
                    NSAttributedString *highlighted =
                        SpliceKitCaption_makeHighlightedGeneratorAttributedStringFromWords(
                            displayWords, [activeWordIndex unsignedIntegerValue], generatedStyle);
                    if (SpliceKitCaption_setGeneratorAttributedTextForPersistedRepair(title, highlighted)) {
                        styledAppliedCount++;
                        textRestoredCount++;
                        didRestoreTextForTitle = YES;
                    }
                }

                if (!didRestoreTextForTitle && text.length > 0) {
                    if (SpliceKitCaption_setGeneratorTextFields(title, @[text], NO)) {
                        textRestoredCount++;
                        plainFallbackCount++;
                        didRestoreTextForTitle = YES;
                    }
                }
            } @catch (NSException *e) {
                SpliceKit_log(@"[Captions] Failed to repair persisted title text: %@", e.reason);
            }

            if (needsPosition) {
                if (SpliceKitCaption_applyGeneratorPositionYOffset(title, yOffset)) {
                    positionAppliedCount++;
                }
            }
        }
    });

    if (textRestoredCount > 0) {
        SpliceKit_log(@"[Captions] Restored text for %lu/%lu persisted caption titles (styled=%lu/%lu plainFallback=%lu)%@",
                      (unsigned long)textRestoredCount,
                      (unsigned long)titleCount,
                      (unsigned long)styledAppliedCount,
                      (unsigned long)styledExpectedCount,
                      (unsigned long)plainFallbackCount,
                      panelVisible ? @" while panel was visible" : @" during relaunch");
    }

    NSUInteger expectedCount = MIN(titleCount, runtimeEntries.count);
    BOOL fullyRestoredText = (expectedCount > 0 &&
                              expectedCount == runtimeEntries.count &&
                              textRestoredCount == expectedCount);
    BOOL fullyRestoredStyled = (styledExpectedCount == 0 ||
                                styledAppliedCount == styledExpectedCount);
    BOOL fullyRestoredPosition = (!needsPosition ||
                                  (expectedCount > 0 && positionAppliedCount == expectedCount));

    if (!fullyRestoredText && expectedCount > 0) {
        SpliceKit_log(@"[Captions] Persisted caption restore incomplete (text=%lu expected=%lu panelVisible=%@); keeping automatic retries active",
                      (unsigned long)textRestoredCount,
                      (unsigned long)expectedCount,
                      panelVisible ? @"YES" : @"NO");
    }
    if (!fullyRestoredStyled && styledExpectedCount > 0) {
        SpliceKit_log(@"[Captions] Persisted caption styled restore incomplete (styled=%lu expected=%lu); keeping automatic retries active",
                      (unsigned long)styledAppliedCount,
                      (unsigned long)styledExpectedCount);
    }
    if (!fullyRestoredPosition && needsPosition && expectedCount > 0) {
        SpliceKit_log(@"[Captions] Persisted caption position restore incomplete (position=%lu expected=%lu panelVisible=%@); keeping automatic retries active",
                      (unsigned long)positionAppliedCount,
                      (unsigned long)expectedCount,
                      panelVisible ? @"YES" : @"NO");
    }

    if (panelVisible) {
        if (fullyRestoredText && fullyRestoredStyled && fullyRestoredPosition) {
            self.lastHealedSequenceKey = sequenceKey;
        }
    } else if (fullyRestoredText && fullyRestoredStyled && fullyRestoredPosition) {
        self.lastHeadlessRestoredSequenceKey = sequenceKey;
    }
}

#pragma mark - State

- (NSDictionary *)getState {
    [self ensurePersistedStateLoaded];

    NSMutableDictionary *state = [NSMutableDictionary dictionary];

    switch (self.status) {
        case SpliceKitCaptionStatusIdle: state[@"status"] = @"idle"; break;
        case SpliceKitCaptionStatusTranscribing: state[@"status"] = @"transcribing"; break;
        case SpliceKitCaptionStatusReady: state[@"status"] = @"ready"; break;
        case SpliceKitCaptionStatusGenerating: state[@"status"] = @"generating"; break;
        case SpliceKitCaptionStatusError: state[@"status"] = @"error"; break;
    }

    state[@"wordCount"] = @(self.mutableWords.count);
    state[@"segmentCount"] = @(self.mutableSegments.count);
    state[@"style"] = [self.style toDictionary];

    // `lastError`, not `error`: this is a state reading, and SpliceKit_handleRequest
    // turns a top-level `error` key into a JSON-RPC failure. Reporting the panel's
    // last error under that name made get_caption_state — a read-only tool — look
    // like the read itself had failed, with the text of an unrelated earlier paste.
    if (self.errorMessage) state[@"lastError"] = self.errorMessage;
    if (self.lastGenerateResult) state[@"lastGenerateResult"] = self.lastGenerateResult;

    // Segments
    NSMutableArray *segDicts = [NSMutableArray array];
    for (SpliceKitCaptionSegment *seg in self.mutableSegments) {
        [segDicts addObject:[seg toDictionary]];
    }
    state[@"segments"] = segDicts;

    // Grouping
    state[@"grouping"] = @{
        @"mode": @[@"words", @"sentence", @"time", @"chars", @"social"][(NSUInteger)MIN(self.groupingMode, 4)],
        @"maxWords": @(self.maxWordsPerSegment),
        @"maxChars": @(self.maxCharsPerSegment),
        @"maxSeconds": @(self.maxSecondsPerSegment),
    };

    return state;
}

@end
