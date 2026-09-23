//
//  SpliceKitCaptionPanel+Persistence.m
//  Saving the caption draft and generated-caption state with the project, and the
//  automatic restore when a project opens.
//

#import "SpliceKitCaptionPanel+Private.h"

@implementation SpliceKitCaptionPanel (Persistence)

- (void)enableAutomaticRestore {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{
            [self enableAutomaticRestore];
        });
        return;
    }

    if (!self.automaticRestoreObserver) {
        __weak typeof(self) weakSelf = self;
        // We fire restore whenever an FCP window becomes main — including on
        // launch-time timeline restoration — because caption positions don't
        // survive in the project XML and must be reapplied via ObjC.
        self.automaticRestoreObserver =
            [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeMainNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(__unused NSNotification *note) {
            [weakSelf scheduleAutomaticRestoreAttemptsWithInitialDelay:0.15];
        }];
    }

    // Always kick off a restore attempt on enable so captions repair even if
    // the current window became main before the observer was attached.
    [self scheduleAutomaticRestoreAttemptsWithInitialDelay:0.6];
}

- (void)scheduleAutomaticRestoreAttemptsWithInitialDelay:(NSTimeInterval)initialDelay {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{
            [self scheduleAutomaticRestoreAttemptsWithInitialDelay:initialDelay];
        });
        return;
    }

    self.automaticRestoreGeneration += 1;
    NSUInteger generation = self.automaticRestoreGeneration;
    NSArray<NSNumber *> *offsets = @[ @0.0, @0.35, @0.9, @1.8, @3.5, @6.0, @10.0 ];
    __weak typeof(self) weakSelf = self;

    for (NSNumber *offset in offsets) {
        NSTimeInterval delay = initialDelay + offset.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!weakSelf) return;
            if (weakSelf.automaticRestoreGeneration != generation) return;
            [weakSelf repairPersistedCaptionsOnCurrentSequenceIfNeeded];
        });
    }
}

- (NSDictionary *)captionDraftGroupingDictionary {
    return @{
        @"mode": @[@"words", @"sentence", @"time", @"chars", @"social"][(NSUInteger)MIN(self.groupingMode, 4)],
        @"maxWords": @(self.maxWordsPerSegment),
        @"maxChars": @(self.maxCharsPerSegment),
        @"maxSeconds": @(self.maxSecondsPerSegment),
    };
}

- (NSArray<NSDictionary *> *)runtimeEntriesForStyle:(SpliceKitCaptionStyle *)style {
    SpliceKitCaptionStyle *s = style ?: self.style;
    BOOL useWordHighlightRuntime = (s.wordByWordHighlight && s.highlightColor != nil);
    NSMutableArray<NSDictionary *> *runtimeEntries = [NSMutableArray array];

    for (NSUInteger segIndex = 0; segIndex < self.mutableSegments.count; segIndex++) {
        SpliceKitCaptionSegment *seg = self.mutableSegments[segIndex];
        NSString *segmentText = s.allCaps ? [seg.text uppercaseString] : seg.text;
        NSString *trimmed = [segmentText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) continue;

        if (useWordHighlightRuntime && seg.words.count > 0) {
            NSMutableArray<NSString *> *displayWords = [NSMutableArray arrayWithCapacity:seg.words.count];
            for (SpliceKitTranscriptWord *sourceWord in seg.words) {
                NSString *wordText = sourceWord.text ?: @"";
                if (s.allCaps) wordText = [wordText uppercaseString];
                [displayWords addObject:wordText];
            }

            for (NSUInteger wordIndex = 0; wordIndex < seg.words.count; wordIndex++) {
                SpliceKitTranscriptWord *word = seg.words[wordIndex];
                double titleStart = word.startTime;
                double titleEnd = (wordIndex + 1 < seg.words.count) ? seg.words[wordIndex + 1].startTime : seg.endTime;
                double frameDuration = [self captionFrameDurationSeconds];
                if (!isfinite(titleEnd) || titleEnd <= titleStart) {
                    titleEnd = titleStart + frameDuration;
                }
                double titleDuration = MAX(titleEnd - titleStart, frameDuration);
                [runtimeEntries addObject:@{
                    @"segmentIndex": @(segIndex),
                    @"activeWordIndex": @(wordIndex),
                    @"words": displayWords,
                    @"text": trimmed,
                    @"startTime": @(titleStart),
                    @"endTime": @(titleEnd),
                    @"duration": @(titleDuration),
                    @"mode": @"wordHighlight",
                }];
            }
        } else {
            [runtimeEntries addObject:@{
                @"segmentIndex": @(segIndex),
                @"text": trimmed,
                @"startTime": @(seg.startTime),
                @"endTime": @(seg.endTime),
                @"duration": @(MAX(seg.endTime - seg.startTime, seg.duration)),
                @"mode": @"segment",
            }];
        }
    }

    return runtimeEntries;
}

- (NSDictionary *)captionTranscriptPersistenceSection {
    NSMutableArray *wordDicts = [NSMutableArray array];
    @synchronized (self.mutableWords) {
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            [wordDicts addObject:SpliceKitCaption_transcriptWordToDictionary(word)];
        }
    }
    return @{
        @"status": @"ready",
        @"frameRate": @(self.frameRate),
        @"words": wordDicts,
    };
}

- (void)ensurePersistedStateLoaded {
    if (self.status == SpliceKitCaptionStatusTranscribing ||
        self.status == SpliceKitCaptionStatusGenerating) {
        return;
    }
    if (self.mutableWords.count > 0) return;
    [self restorePersistedStateForCurrentSequenceIfNeeded];
}

- (void)persistCaptionDraftStateForCurrentSequence {
    if (self.suppressPersistenceWrites) return;

    id sequence = SpliceKitCaption_currentSequence();
    if (!sequence) return;

    NSMutableDictionary *state = [[SpliceKit_loadSequenceState(sequence) mutableCopy] ?: [NSMutableDictionary dictionary] mutableCopy];
    NSMutableDictionary *captions = [[state[@"captions"] isKindOfClass:[NSDictionary class]]
        ? [state[@"captions"] mutableCopy]
        : [NSMutableDictionary dictionary] mutableCopy];
    captions[@"draftStyle"] = [self.style toDictionary];
    captions[@"draftGrouping"] = [self captionDraftGroupingDictionary];
    state[@"captions"] = captions;
    if (self.mutableWords.count > 0) {
        state[@"transcript"] = [self captionTranscriptPersistenceSection];
    }

    NSError *error = nil;
    if (!SpliceKit_saveSequenceState(sequence, state, &error) && error) {
        SpliceKit_log(@"[Captions] Failed to persist draft state: %@", error.localizedDescription);
    }
}

- (void)persistGeneratedCaptionStateWithRuntimeEntries:(NSArray<NSDictionary *> *)runtimeEntries
                                                 style:(SpliceKitCaptionStyle *)style {
    if (self.suppressPersistenceWrites || runtimeEntries.count == 0) return;

    id sequence = SpliceKitCaption_currentSequence();
    if (!sequence) return;

    NSMutableDictionary *state = [[SpliceKit_loadSequenceState(sequence) mutableCopy] ?: [NSMutableDictionary dictionary] mutableCopy];
    NSMutableDictionary *captions = [[state[@"captions"] isKindOfClass:[NSDictionary class]]
        ? [state[@"captions"] mutableCopy]
        : [NSMutableDictionary dictionary] mutableCopy];
    captions[@"draftStyle"] = [self.style toDictionary];
    captions[@"draftGrouping"] = [self captionDraftGroupingDictionary];
    captions[@"generatedStyle"] = [(style ?: self.style) toDictionary];
    captions[@"generatedRuntimeEntries"] = runtimeEntries;
    captions[@"generatedStorylineName"] = kSpliceKitCaptionStorylineName;
    captions[@"generatedAt"] = @([[NSDate date] timeIntervalSince1970]);
    state[@"captions"] = captions;
    if (self.mutableWords.count > 0) {
        state[@"transcript"] = [self captionTranscriptPersistenceSection];
    }

    NSError *error = nil;
    if (!SpliceKit_saveSequenceState(sequence, state, &error) && error) {
        SpliceKit_log(@"[Captions] Failed to persist generated caption state: %@", error.localizedDescription);
    }
    self.lastHeadlessRestoredSequenceKey = nil;
    self.lastHealedSequenceKey = nil;
}

- (CGFloat)yOffsetForStyle:(SpliceKitCaptionStyle *)style {
    SpliceKitCaptionStyle *resolvedStyle = style ?: self.style;
    switch (resolvedStyle.position) {
        case SpliceKitCaptionPositionBottom: return -(self.videoHeight * 0.32);
        case SpliceKitCaptionPositionCenter: return 0;
        case SpliceKitCaptionPositionTop: return (self.videoHeight * 0.32);
        case SpliceKitCaptionPositionCustom: return resolvedStyle.customYOffset;
    }
    return 0;
}

@end
