//
//  SpliceKitTranscriptPanel.m
//  Text-based video editing — think Premiere Pro's text panel but inside FCP.
//
//  This creates a floating panel that transcribes all clips on the timeline,
//  then lets you edit the video by editing the text. Delete a word and the
//  corresponding video segment gets blade'd and removed. Drag words to reorder
//  clips. Click a word to jump the playhead there.
//
//  Supports multiple transcription engines:
//  - Parakeet v3: NVIDIA's TDT 0.6B model via FluidAudio, 25 languages, runs on-device
//  - Parakeet v2: English-optimized variant
//  - Apple Speech: SFSpeechRecognizer, slower but handles some edge cases better
//  - FCP Native: FCP's built-in AASpeechAnalyzer
//
//  The panel also detects silences between words and shows them as [...] markers.
//  You can batch-delete all silences to tighten up the edit.
//

#import "SpliceKitTranscriptPanel.h"
#import "SpliceKitTranscriptDiagnostics.h"
#import "SpliceKit.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "SpliceKitTranscriptPanel+Private.h"

// x86_64 ABI requires objc_msgSend_stret for struct returns > 16 bytes.
// ARM64 returns all structs through objc_msgSend (no _stret variant exists).

// FCP doesn't link against Speech.framework, so we load it at runtime.
// This avoids a hard dependency — if the framework isn't available (unlikely
// on macOS, but still), we just fall back to other engines.
Class SFSpeechRecognizerClass = nil;
Class SFSpeechURLRecognitionRequestClass = nil;

void SpliceKitTranscript_loadSpeechFramework(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *speechBundle = [NSBundle bundleWithPath:
            @"/System/Library/Frameworks/Speech.framework"];
        if ([speechBundle load]) {
            SFSpeechRecognizerClass = objc_getClass("SFSpeechRecognizer");
            SFSpeechURLRecognitionRequestClass = objc_getClass("SFSpeechURLRecognitionRequest");
            SpliceKit_log(@"[Transcript] Speech.framework loaded: recognizer=%@, request=%@",
                          SFSpeechRecognizerClass, SFSpeechURLRecognitionRequestClass);
        } else {
            SpliceKit_log(@"[Transcript] ERROR: Failed to load Speech.framework");
        }
    });
}

// macOS 26+ check for speaker diarization support
BOOL SpliceKitTranscript_isSpeakerDiarizationAvailable(void) {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    // macOS 26 (Darwin 25.x) added SFSpeechRecognitionRequest.addsSpeakerAttribution
    return v.majorVersion >= 26;
}

#pragma mark - Timecode Formatting

NSString *SpliceKitTranscript_timecodeFromSeconds(double seconds, double fps) {
    if (fps <= 0) fps = 24;
    if (seconds < 0) seconds = 0;
    int totalFrames = (int)(seconds * fps + 0.5);
    int fpsInt = (int)(fps + 0.5);
    if (fpsInt <= 0) fpsInt = 24;
    int frames = totalFrames % fpsInt;
    int totalSecs = totalFrames / fpsInt;
    int secs = totalSecs % 60;
    int mins = (totalSecs / 60) % 60;
    int hours = totalSecs / 3600;
    return [NSString stringWithFormat:@"%02d:%02d:%02d:%02d", hours, mins, secs, frames];
}

#pragma mark - SpliceKitTranscriptWord

@implementation SpliceKitTranscriptWord

- (instancetype)init {
    self = [super init];
    if (self) {
        _speaker = @"Unknown";
    }
    return self;
}

- (double)endTime {
    return _startTime + _duration;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"Word[%lu]: \"%@\" %.2f-%.2f (conf:%.0f%% speaker:%@)",
            (unsigned long)_wordIndex, _text, _startTime, self.endTime, _confidence * 100, _speaker];
}

@end

#pragma mark - SpliceKitTranscriptSilence

@implementation SpliceKitTranscriptSilence

- (NSString *)description {
    return [NSString stringWithFormat:@"Silence: %.2f-%.2f (%.2fs) after word %lu",
            _startTime, _endTime, _duration, (unsigned long)_afterWordIndex];
}

@end

static NSDictionary *SpliceKitTranscript_wordToDictionary(SpliceKitTranscriptWord *word) {
    if (!word) return @{};
    return @{
        @"index": @(word.wordIndex),
        @"text": word.text ?: @"",
        @"startTime": @(word.startTime),
        @"duration": @(word.duration),
        @"endTime": @(word.endTime),
        @"confidence": @(word.confidence),
        @"speaker": word.speaker ?: @"Unknown",
        @"clipHandle": word.clipHandle ?: @"",
        @"clipTimelineStart": @(word.clipTimelineStart),
        @"sourceMediaOffset": @(word.sourceMediaOffset),
        @"sourceMediaTime": @(word.sourceMediaTime),
        @"sourceMediaPath": word.sourceMediaPath ?: @"",
    };
}

static SpliceKitTranscriptWord *SpliceKitTranscript_wordFromDictionary(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    SpliceKitTranscriptWord *word = [[SpliceKitTranscriptWord alloc] init];
    word.text = dict[@"text"] ?: @"";
    word.startTime = [dict[@"startTime"] doubleValue];
    word.duration = [dict[@"duration"] doubleValue];
    word.endTime = [dict[@"endTime"] doubleValue];
    if (word.endTime <= word.startTime) word.endTime = word.startTime + word.duration;
    word.confidence = [dict[@"confidence"] doubleValue];
    word.wordIndex = [dict[@"index"] unsignedIntegerValue];
    NSString *spk = dict[@"speaker"] ?: @"Unknown";
    if (spk.length <= 3 && [spk hasPrefix:@"S"]) {
        spk = [NSString stringWithFormat:@"Speaker %@", [spk substringFromIndex:1]];
    }
    word.speaker = spk;
    word.clipHandle = dict[@"clipHandle"];
    word.clipTimelineStart = [dict[@"clipTimelineStart"] doubleValue];
    word.sourceMediaOffset = [dict[@"sourceMediaOffset"] doubleValue];
    word.sourceMediaTime = [dict[@"sourceMediaTime"] doubleValue];
    word.sourceMediaPath = dict[@"sourceMediaPath"];
    return word;
}

static NSDictionary *SpliceKitTranscript_silenceToDictionary(SpliceKitTranscriptSilence *silence) {
    if (!silence) return @{};
    return @{
        @"startTime": @(silence.startTime),
        @"endTime": @(silence.endTime),
        @"duration": @(silence.duration),
        @"afterWordIndex": @(silence.afterWordIndex),
    };
}

static SpliceKitTranscriptSilence *SpliceKitTranscript_silenceFromDictionary(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    SpliceKitTranscriptSilence *silence = [[SpliceKitTranscriptSilence alloc] init];
    silence.startTime = [dict[@"startTime"] doubleValue];
    silence.endTime = [dict[@"endTime"] doubleValue];
    silence.duration = [dict[@"duration"] doubleValue];
    silence.afterWordIndex = [dict[@"afterWordIndex"] unsignedIntegerValue];
    return silence;
}

#pragma mark - Forward Declarations

NSPasteboardType const SpliceKitTranscriptWordDragType = @"com.splicekit.transcript.words";

// We attach custom attributes to spans of text in the NSTextView so we can
// figure out what the user clicked on or selected. Each word, silence marker,
// and speaker label gets tagged with its index into our data model.
NSString *const FCPAttrItemType = @"FCPItemType";
NSString *const FCPAttrWordIndex = @"FCPWordIndex";
NSString *const FCPAttrSilenceIndex = @"FCPSilenceIndex";
NSString *const FCPAttrSpeakerName = @"FCPSpeakerName";
NSString *const FCPAttrSegmentStartIndex = @"FCPSegmentStartIndex";
NSString *const FCPAttrSegmentEndIndex = @"FCPSegmentEndIndex";

#pragma mark - SpliceKitTranscriptPanel Private
//
// Same CMTime struct trick as in SpliceKitServerInternal.h — we define our own copy
// so we can read struct return values from objc_msgSend without linking CoreMedia.
//

double CMTimeToSeconds(SpliceKitTranscript_CMTime t) {
    return (t.timescale > 0) ? (double)t.value / t.timescale : 0;
}

@implementation SpliceKitTranscriptPanel

#pragma mark - Singleton

+ (instancetype)sharedPanel {
    static SpliceKitTranscriptPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SpliceKitTranscriptPanel alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _status = SpliceKitTranscriptStatusIdle;
        _mutableWords = [NSMutableArray array];
        _mutableSilences = [NSMutableArray array];
        _pendingTranscriptions = [NSMutableArray array];
        _searchResultRanges = [NSMutableArray array];
        _currentSearchIndex = -1;
        _currentFilter = @"all";
        _silenceThreshold = 0.3; // 300ms default
        _frameRate = 24.0;
        _engine = SpliceKitTranscriptEngineParakeet; // Default to Parakeet (fastest, most accurate)
        _parakeetModelVersion = @"v3"; // v3 = multilingual, v2 = English-optimized
        _lastPlayheadHighlightRange = NSMakeRange(NSNotFound, 0);

        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSApplicationWillTerminateNotification
            object:nil queue:nil usingBlock:^(NSNotification *note) {
                [self stopPlayheadTimer];
                [self.panel orderOut:nil];
            }];
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
    if (self.status == SpliceKitTranscriptStatusReady && self.mutableWords.count > 0) {
        [self startPlayheadTimer];
    }
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
    return self.panel.isVisible;
}

- (void)windowWillClose:(NSNotification *)notification {
    // Don't stop timer — user may reopen and expect sync
}

- (void)focusSearchField {
    [self.panel makeKeyAndOrderFront:nil];
    [self.searchField becomeFirstResponder];
}

- (id)currentSequence {
    __block id sequence = nil;
    SpliceKit_executeOnMainThread(^{
        id timeline = [self getActiveTimelineModule];
        if ([timeline respondsToSelector:@selector(sequence)]) {
            sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
        }
    });
    return sequence;
}

- (void)ensurePersistedStateLoaded {
    if (self.status == SpliceKitTranscriptStatusTranscribing) return;
    // A file transcript (transcript.open with fileURL) belongs to no sequence.
    // Checking it against the open timeline treated it as stale and wiped it:
    // with no project open every getState emptied the words the run had just
    // produced, so file mode reported idle with 0 words and no error.
    if (self.sourceFilePath.length > 0) return;

    // Check if the current sequence matches what we have in memory.
    // If the sequence changed (project switch), we need to restore/clear even if words exist.
    id sequence = [self currentSequence];

    // No sequence (empty timeline or no project) — clear stale data
    if (!sequence && self.mutableWords.count > 0) {
        @synchronized (self.mutableWords) {
            [self.mutableWords removeAllObjects];
        }
        [self.mutableSilences removeAllObjects];
        self.fullText = nil;
        self.status = SpliceKitTranscriptStatusIdle;
        self.lastRestoredSequenceKey = nil;
        if (self.panel) {
            [self rebuildTextView];
            self.deleteSilencesButton.enabled = NO;
            [self updateStatusUI:@"No project open. Open a project and tap Transcribe."];
        }
        return;
    }

    if (sequence) {
        NSDictionary *state = SpliceKit_loadSequenceState(sequence);
        NSString *currentKey = [state[@"sequenceIdentity"] isKindOfClass:[NSDictionary class]]
            ? state[@"sequenceIdentity"][@"cacheKey"] : nil;

        // If we have words in memory, check they belong to the current sequence.
        // After restart lastRestoredSequenceKey is nil — always validate in that case.
        if (self.mutableWords.count > 0) {
            BOOL keyMismatch = NO;
            if (self.lastRestoredSequenceKey.length == 0) {
                // After restart: we have words but don't know which sequence they're from.
                // Trigger a restore which will load the correct data for this sequence.
                keyMismatch = YES;
            } else if (currentKey.length > 0 && ![self.lastRestoredSequenceKey isEqualToString:currentKey]) {
                keyMismatch = YES;
            }
            if (keyMismatch) {
                [self restorePersistedStateForCurrentSequenceIfNeeded];
                return;
            }
            return; // Words are loaded and match current sequence
        }
    }

    // No words in memory — try to restore from persistence
    [self restorePersistedStateForCurrentSequenceIfNeeded];
}

- (void)leaveFileMode {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{ [self leaveFileMode]; });
        return;
    }
    if (self.sourceFilePath.length == 0) return;
    self.sourceFilePath = nil;
    @synchronized (self.mutableWords) {
        [self.mutableWords removeAllObjects];
    }
    [self.mutableSilences removeAllObjects];
    self.fullText = nil;
    self.lastRestoredSequenceKey = nil;
    if (self.status != SpliceKitTranscriptStatusTranscribing) {
        self.status = SpliceKitTranscriptStatusIdle;
        self.errorMessage = nil;
    }
    if (self.panel) [self rebuildTextView];
}

- (NSDictionary *)transcriptPersistenceSection {
    NSMutableArray *wordDicts = [NSMutableArray array];
    @synchronized (self.mutableWords) {
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            [wordDicts addObject:SpliceKitTranscript_wordToDictionary(word)];
        }
    }

    NSMutableArray *silenceDicts = [NSMutableArray array];
    for (SpliceKitTranscriptSilence *silence in self.mutableSilences) {
        [silenceDicts addObject:SpliceKitTranscript_silenceToDictionary(silence)];
    }

    NSMutableDictionary *section = [@{
        @"status": @"ready",
        @"formatVersion": @2,
        @"frameRate": @(self.frameRate),
        @"silenceThreshold": @(self.silenceThreshold),
        @"speakerDetectionEnabled": @(self.speakerDetectionEnabled),
        @"words": wordDicts,
        @"silences": silenceDicts,
    } mutableCopy];

    NSString *engineName = (self.engine == SpliceKitTranscriptEngineFCPNative) ? @"fcpNative" :
                           (self.engine == SpliceKitTranscriptEngineParakeet) ? @"parakeet" : @"appleSpeech";
    section[@"engine"] = engineName;
    if (self.engine == SpliceKitTranscriptEngineParakeet) {
        section[@"parakeetModel"] = self.parakeetModelVersion ?: @"v3";
    }
    if (self.fullText.length > 0) {
        section[@"text"] = self.fullText;
    }
    return section;
}

- (void)persistTranscriptStateForCurrentSequence {
    if (self.suppressPersistenceWrites || self.mutableWords.count == 0) return;
    // A file transcript is not this sequence's; saving it there would restore it
    // as the timeline's transcript the next time the project is opened.
    if (self.sourceFilePath.length > 0) return;

    id sequence = [self currentSequence];
    if (!sequence) return;

    NSMutableDictionary *state = [[SpliceKit_loadSequenceState(sequence) mutableCopy] ?: [NSMutableDictionary dictionary] mutableCopy];
    state[@"transcript"] = [self transcriptPersistenceSection];

    NSError *error = nil;
    if (!SpliceKit_saveSequenceState(sequence, state, &error) && error) {
        SpliceKit_log(@"[Transcript] Failed to persist transcript state: %@", error.localizedDescription);
    }
}

- (void)restorePersistedStateForCurrentSequenceIfNeeded {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{
            [self restorePersistedStateForCurrentSequenceIfNeeded];
        });
        return;
    }

    if (self.sourceFilePath.length > 0) return;  // file mode: see ensurePersistedStateLoaded

    id sequence = [self currentSequence];
    if (!sequence) return;

    NSDictionary *state = SpliceKit_loadSequenceState(sequence);
    NSDictionary *transcript = [state[@"transcript"] isKindOfClass:[NSDictionary class]] ? state[@"transcript"] : nil;
    NSArray *wordDicts = [transcript[@"words"] isKindOfClass:[NSArray class]] ? transcript[@"words"] : nil;
    NSString *engineName = [transcript[@"engine"] isKindOfClass:[NSString class]] ? transcript[@"engine"] : nil;
    NSInteger formatVersion = [transcript[@"formatVersion"] respondsToSelector:@selector(integerValue)]
        ? [transcript[@"formatVersion"] integerValue] : 0;

    // Check if the sequence changed — if so, clear stale transcript from previous project
    NSString *sequenceKey = [state[@"sequenceIdentity"] isKindOfClass:[NSDictionary class]]
        ? state[@"sequenceIdentity"][@"cacheKey"] : nil;
    if (sequenceKey.length > 0 &&
        self.lastRestoredSequenceKey.length > 0 &&
        ![self.lastRestoredSequenceKey isEqualToString:sequenceKey]) {
        // Sequence changed — clear old transcript data
        @synchronized (self.mutableWords) {
            [self.mutableWords removeAllObjects];
        }
        [self.mutableSilences removeAllObjects];
        self.fullText = nil;
        self.status = SpliceKitTranscriptStatusIdle;
        self.lastRestoredSequenceKey = sequenceKey;
        if (self.panel) {
            [self rebuildTextView];
            self.deleteSilencesButton.enabled = NO;
            [self updateStatusUI:@"Project changed. Tap Refresh to transcribe."];
        }
    }

    if (!transcript || wordDicts.count == 0) return;

    // Older FCP Native transcripts stored source-relative word times, which causes
    // playback highlighting to jump between clips after restoring cached state.
    if ([engineName isEqualToString:@"fcpNative"] && formatVersion < 2) {
        NSMutableDictionary *mutableState = [state mutableCopy] ?: [NSMutableDictionary dictionary];
        [mutableState removeObjectForKey:@"transcript"];
        SpliceKit_saveSequenceState(sequence, mutableState, nil);

        @synchronized (self.mutableWords) {
            [self.mutableWords removeAllObjects];
        }
        [self.mutableSilences removeAllObjects];
        self.fullText = nil;
        self.status = SpliceKitTranscriptStatusIdle;
        self.errorMessage = nil;
        self.lastRestoredSequenceKey = sequenceKey;

        if (self.panel) {
            [self rebuildTextView];
            self.deleteSilencesButton.enabled = NO;
            [self updateStatusUI:@"Transcript needs refresh after update. Tap Refresh to rebuild."];
        }
        return;
    }

    if (sequenceKey.length > 0 &&
        [self.lastRestoredSequenceKey isEqualToString:sequenceKey] &&
        self.mutableWords.count > 0) {
        return;
    }

    self.suppressPersistenceWrites = YES;
    @synchronized (self.mutableWords) {
        [self.mutableWords removeAllObjects];
        for (NSDictionary *wordDict in wordDicts) {
            SpliceKitTranscriptWord *word = SpliceKitTranscript_wordFromDictionary(wordDict);
            if (word) [self.mutableWords addObject:word];
        }
        [self.mutableWords sortUsingComparator:^NSComparisonResult(SpliceKitTranscriptWord *a, SpliceKitTranscriptWord *b) {
            if (a.startTime < b.startTime) return NSOrderedAscending;
            if (a.startTime > b.startTime) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
            self.mutableWords[i].wordIndex = i;
        }
    }

    [self.mutableSilences removeAllObjects];
    NSArray *silenceDicts = [transcript[@"silences"] isKindOfClass:[NSArray class]] ? transcript[@"silences"] : nil;
    for (NSDictionary *silenceDict in silenceDicts) {
        SpliceKitTranscriptSilence *silence = SpliceKitTranscript_silenceFromDictionary(silenceDict);
        if (silence) [self.mutableSilences addObject:silence];
    }
    if (self.mutableSilences.count == 0) {
        [self detectSilences];
    }

    if ([engineName isEqualToString:@"fcpNative"]) {
        self.engine = SpliceKitTranscriptEngineFCPNative;
    } else if ([engineName isEqualToString:@"appleSpeech"]) {
        self.engine = SpliceKitTranscriptEngineAppleSpeech;
    } else {
        self.engine = SpliceKitTranscriptEngineParakeet;
    }
    if ([transcript[@"parakeetModel"] isKindOfClass:[NSString class]]) {
        self.parakeetModelVersion = transcript[@"parakeetModel"];
    }
    if (transcript[@"frameRate"]) {
        self.frameRate = [transcript[@"frameRate"] doubleValue];
        self.frameRateKnown = YES;
    }
    if (transcript[@"silenceThreshold"]) self.silenceThreshold = [transcript[@"silenceThreshold"] doubleValue];
    self.speakerDetectionEnabled = [transcript[@"speakerDetectionEnabled"] boolValue];
    self.fullText = [transcript[@"text"] isKindOfClass:[NSString class]] ? transcript[@"text"] : nil;
    self.status = SpliceKitTranscriptStatusReady;
    self.errorMessage = nil;
    self.lastRestoredSequenceKey = sequenceKey;

    if (self.panel) {
        [self updateSpeakerCheckboxState];
        if (self.engine == SpliceKitTranscriptEngineAppleSpeech) {
            [self.enginePopup selectItemWithTitle:@"Apple Speech"];
        } else if (self.engine == SpliceKitTranscriptEngineParakeet) {
            NSString *title = [self.parakeetModelVersion isEqualToString:@"v2"] ? @"Parakeet v2" : @"Parakeet v3";
            [self.enginePopup selectItemWithTitle:title];
        } else {
            [self.enginePopup selectItemWithTitle:@"FCP Native"];
        }
        self.speakerDetectionCheckbox.state = self.speakerDetectionEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        [self rebuildTextView];
        self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);
        [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses (restored)",
            (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSilences.count]];
    }

    self.suppressPersistenceWrites = NO;
}

- (void)clearTranscript {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{ [self clearTranscript]; });
        return;
    }

    @synchronized (self.mutableWords) {
        [self.mutableWords removeAllObjects];
    }
    [self.mutableSilences removeAllObjects];
    self.fullText = nil;
    self.status = SpliceKitTranscriptStatusIdle;
    self.errorMessage = nil;
    self.lastRestoredSequenceKey = nil;

    // Remove persisted transcript for current sequence
    id sequence = [self currentSequence];
    if (sequence) {
        NSMutableDictionary *state = [[SpliceKit_loadSequenceState(sequence) mutableCopy] ?: [NSMutableDictionary dictionary] mutableCopy];
        [state removeObjectForKey:@"transcript"];
        NSError *error = nil;
        SpliceKit_saveSequenceState(sequence, state, &error);
    }

    if (self.panel) {
        [self rebuildTextView];
        self.deleteSilencesButton.enabled = NO;
        [self updateStatusUI:@"Transcript cleared."];
    }

    SpliceKit_log(@"[Transcript] Transcript cleared");
}

#pragma mark - Search

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == self.searchField) {
        self.currentSearchQuery = self.searchField.stringValue;
        // Reset filter to All when typing in search
        if (self.currentSearchQuery.length > 0 && ![self.currentFilter isEqualToString:@"all"]) {
            self.currentFilter = @"all";
            [self.filterPopup selectItemWithTitle:@"All"];
        }
        [self performSearchHighlighting];
    }
}

- (void)performSearchHighlighting {
    [self.searchResultRanges removeAllObjects];
    self.currentSearchIndex = -1;

    NSTextStorage *storage = self.textView.textStorage;
    NSRange fullRange = NSMakeRange(0, storage.length);
    if (fullRange.length == 0) {
        [self updateSearchResultsUI];
        return;
    }

    // Clear previous search highlighting
    self.suppressTextViewCallbacks = YES;
    [storage removeAttribute:NSBackgroundColorAttributeName range:fullRange];

    NSString *query = self.currentSearchQuery;
    BOOL filterPauses = [self.currentFilter isEqualToString:@"pauses"];
    BOOL filterLowConf = [self.currentFilter isEqualToString:@"lowConfidence"];

    if (filterPauses) {
        // Highlight all silence markers
        for (SpliceKitTranscriptSilence *silence in self.mutableSilences) {
            if (silence.textRange.location + silence.textRange.length <= storage.length) {
                [self.searchResultRanges addObject:[NSValue valueWithRange:silence.textRange]];
                [storage addAttribute:NSBackgroundColorAttributeName
                                value:[NSColor colorWithCalibratedRed:0.9 green:0.7 blue:0.2 alpha:0.5]
                                range:silence.textRange];
            }
        }
    } else if (filterLowConf) {
        // Highlight low confidence words
        @synchronized (self.mutableWords) {
            for (SpliceKitTranscriptWord *word in self.mutableWords) {
                if (word.confidence < 0.5 && word.textRange.location + word.textRange.length <= storage.length) {
                    [self.searchResultRanges addObject:[NSValue valueWithRange:word.textRange]];
                    [storage addAttribute:NSBackgroundColorAttributeName
                                    value:[NSColor colorWithCalibratedRed:0.9 green:0.5 blue:0.2 alpha:0.4]
                                    range:word.textRange];
                }
            }
        }
    } else if (query.length > 0) {
        // Text search
        NSString *text = [storage string];
        NSRange searchRange = NSMakeRange(0, text.length);
        NSStringCompareOptions options = NSCaseInsensitiveSearch;

        while (searchRange.location < text.length) {
            NSRange foundRange = [text rangeOfString:query options:options range:searchRange];
            if (foundRange.location == NSNotFound) break;

            [self.searchResultRanges addObject:[NSValue valueWithRange:foundRange]];
            [storage addAttribute:NSBackgroundColorAttributeName
                            value:[NSColor colorWithCalibratedRed:0.9 green:0.7 blue:0.2 alpha:0.4]
                            range:foundRange];

            searchRange.location = NSMaxRange(foundRange);
            searchRange.length = text.length - searchRange.location;
        }
    }

    self.suppressTextViewCallbacks = NO;

    if (self.searchResultRanges.count > 0) {
        self.currentSearchIndex = 0;
        [self scrollToCurrentSearchResult];
    }

    [self updateSearchResultsUI];
}

- (void)scrollToCurrentSearchResult {
    if (self.currentSearchIndex < 0 || self.currentSearchIndex >= (NSInteger)self.searchResultRanges.count) return;

    NSRange range = self.searchResultRanges[self.currentSearchIndex].rangeValue;

    // Highlight current result more prominently
    NSTextStorage *storage = self.textView.textStorage;
    self.suppressTextViewCallbacks = YES;

    // Reset all to standard highlight color
    for (NSValue *rv in self.searchResultRanges) {
        NSRange r = rv.rangeValue;
        if (r.location + r.length <= storage.length) {
            [storage addAttribute:NSBackgroundColorAttributeName
                            value:[NSColor colorWithCalibratedRed:0.9 green:0.7 blue:0.2 alpha:0.4]
                            range:r];
        }
    }

    // Highlight current with brighter color
    if (range.location + range.length <= storage.length) {
        [storage addAttribute:NSBackgroundColorAttributeName
                        value:[NSColor colorWithCalibratedRed:1.0 green:0.8 blue:0.2 alpha:0.7]
                        range:range];
    }

    self.suppressTextViewCallbacks = NO;

    // Scroll to visible
    [self.textView scrollRangeToVisible:range];

    [self updateSearchResultsUI];
}

- (void)updateSearchResultsUI {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger total = self.searchResultRanges.count;
        if (total > 0) {
            self.resultCountLabel.stringValue = [NSString stringWithFormat:@"%ld/%lu",
                (long)(self.currentSearchIndex + 1), (unsigned long)total];
            self.prevResultButton.enabled = YES;
            self.nextResultButton.enabled = YES;
            self.deleteResultsButton.enabled = YES;
        } else {
            self.resultCountLabel.stringValue = @"";
            self.prevResultButton.enabled = NO;
            self.nextResultButton.enabled = NO;
            self.deleteResultsButton.enabled = (self.currentSearchQuery.length > 0 ||
                                                ![self.currentFilter isEqualToString:@"all"]);
        }
    });
}

- (NSDictionary *)searchTranscript:(NSString *)query {
    [self ensurePersistedStateLoaded];

    if (!query || query.length == 0) {
        return @{@"error": @"Query cannot be empty"};
    }

    NSMutableArray *results = [NSMutableArray array];

    // Check for special keywords
    if ([[query lowercaseString] isEqualToString:@"pauses"] ||
        [[query lowercaseString] isEqualToString:@"silences"]) {
        for (SpliceKitTranscriptSilence *silence in self.mutableSilences) {
            [results addObject:@{
                @"type": @"silence",
                @"startTime": @(silence.startTime),
                @"endTime": @(silence.endTime),
                @"duration": @(silence.duration),
                @"afterWordIndex": @(silence.afterWordIndex)
            }];
        }
        return @{@"query": query, @"resultCount": @(results.count), @"results": results};
    }

    // Text search through words
    @synchronized (self.mutableWords) {
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            if ([word.text rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [results addObject:@{
                    @"type": @"word",
                    @"index": @(word.wordIndex),
                    @"text": word.text,
                    @"startTime": @(word.startTime),
                    @"endTime": @(word.endTime),
                    @"confidence": @(word.confidence),
                    @"speaker": word.speaker ?: @"Unknown"
                }];
            }
        }
    }

    // Also update the UI search
    dispatch_async(dispatch_get_main_queue(), ^{
        self.searchField.stringValue = query;
        self.currentSearchQuery = query;
        [self performSearchHighlighting];
    });

    return @{@"query": query, @"resultCount": @(results.count), @"results": results};
}

#pragma mark - Transcribe Timeline
//
// Main entry point for transcription. Walks the primary storyline plus any
// anchored (connected) clips, extracts the source media URL, and feeds it to
// the selected engine. All clips are processed in a single batch so the model
// only loads once.
//

- (void)transcribeTimeline {
    SpliceKit_log(@"[Transcript] Starting timeline transcription%@",
        self.primaryStorylineOnly ? @" (primary storyline only)" : @"");

    // Back to timeline mode: this run's words belong to the open sequence.
    [self beginRun];
    self.sourceFilePath = nil;
    self.skippedSources = nil;
    self.completedTranscriptions = 0;
    self.totalTranscriptions = 0;
    self.progressFraction = 0;
    self.progressMessage = @"Analyzing timeline";
    self.transcriptionStartDate = [NSDate date];
    self.status = SpliceKitTranscriptStatusTranscribing;
    self.errorMessage = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        self.status = SpliceKitTranscriptStatusTranscribing;
        self.errorMessage = nil;
        [self updateStatusUI:@"Analyzing timeline..."];
        self.spinner.hidden = NO;
        [self.spinner startAnimation:nil];
        self.progressBar.hidden = NO;
        self.progressBar.indeterminate = YES;
        [self.progressBar startAnimation:nil];
        self.refreshButton.enabled = NO;
        self.deleteSilencesButton.enabled = NO;
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (self.engine == SpliceKitTranscriptEngineFCPNative || self.engine == SpliceKitTranscriptEngineParakeet) {
            // FCP Native and Parakeet don't need Apple speech authorization
            [self performTimelineTranscription];
        } else {
            [self requestSpeechAuthorizationWithCompletion:^(BOOL authorized) {
                if (!authorized) {
                    // The authorization helper already set a specific error for a
                    // denial or restriction. Only the "framework never loaded" case
                    // reaches here without one, so don't overwrite the better message.
                    if (!objc_getClass("SFSpeechRecognizer")) {
                        [self setErrorState:@"Apple Speech framework not available. "
                                            "Use Parakeet or FCP Native engine instead."];
                    }
                    return;
                }
                [self performTimelineTranscription];
            }];
        }
    });
}

#pragma mark - Silence Detection

- (void)detectSilences {
    [self.mutableSilences removeAllObjects];

    @synchronized (self.mutableWords) {
        if (self.mutableWords.count < 2) return;

        // Compute median word duration to detect silence absorption.
        // Some engines (especially Parakeet) extend a word's endTime through trailing
        // silence instead of leaving a gap, making pauses invisible to gap-only detection.
        NSMutableArray<NSNumber *> *durations = [NSMutableArray arrayWithCapacity:self.mutableWords.count];
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            [durations addObject:@(word.duration)];
        }
        [durations sortUsingSelector:@selector(compare:)];
        double medianDuration = [durations[durations.count / 2] doubleValue];
        // Use 75th percentile as a more robust estimate of "normal" word length
        double p75Duration = [durations[(NSUInteger)(durations.count * 0.75)] doubleValue];

        // Words longer than 2x the 75th percentile are suspicious — likely contain
        // absorbed silence. Previous threshold of MAX(3x median, 1.0) was too aggressive
        // and missed pauses absorbed into 0.5-0.9s words.
        double suspectThreshold = MAX(p75Duration * 2.0, self.silenceThreshold * 2.0);

        // Phase 1: Also compute start-to-start intervals to detect silence in engines
        // that produce contiguous timestamps (endTime[i] == startTime[i+1]) with no gaps.
        // A large start-to-start interval relative to typical speech rate implies a pause.
        NSMutableArray<NSNumber *> *intervals = [NSMutableArray arrayWithCapacity:self.mutableWords.count - 1];
        for (NSUInteger i = 0; i < self.mutableWords.count - 1; i++) {
            double interval = self.mutableWords[i + 1].startTime - self.mutableWords[i].startTime;
            if (interval > 0) [intervals addObject:@(interval)];
        }
        [intervals sortUsingSelector:@selector(compare:)];
        double medianInterval = intervals.count > 0 ? [intervals[intervals.count / 2] doubleValue] : 0;

        for (NSUInteger i = 0; i < self.mutableWords.count - 1; i++) {
            SpliceKitTranscriptWord *current = self.mutableWords[i];
            SpliceKitTranscriptWord *next = self.mutableWords[i + 1];
            BOOL silenceAdded = NO;

            // Standard inter-word gap detection
            double gap = next.startTime - current.endTime;
            if (gap >= self.silenceThreshold) {
                SpliceKitTranscriptSilence *silence = [[SpliceKitTranscriptSilence alloc] init];
                silence.startTime = current.endTime;
                silence.endTime = next.startTime;
                silence.duration = gap;
                silence.afterWordIndex = i;
                [self.mutableSilences addObject:silence];
                silenceAdded = YES;
            }

            // Intra-word silence detection: if a word is suspiciously long, the tail
            // portion beyond a typical word duration is likely absorbed silence.
            if (!silenceAdded && current.duration >= suspectThreshold) {
                double estimatedSpeechEnd = current.startTime + medianDuration;
                double intraGap = current.endTime - estimatedSpeechEnd;
                if (intraGap >= self.silenceThreshold) {
                    SpliceKitTranscriptSilence *silence = [[SpliceKitTranscriptSilence alloc] init];
                    silence.startTime = estimatedSpeechEnd;
                    silence.endTime = current.endTime;
                    silence.duration = intraGap;
                    silence.afterWordIndex = i;
                    [self.mutableSilences addObject:silence];
                    silenceAdded = YES;
                }
            }

            // Phase 2: Start-to-start interval detection for contiguous-timestamp engines.
            // If gap was 0 (no inter-word gap) and no intra-word silence was found,
            // check if the interval between word starts is abnormally long.
            if (!silenceAdded && medianInterval > 0) {
                double interval = next.startTime - current.startTime;
                // An interval > 2.5x median with duration >= threshold indicates a pause
                // absorbed into contiguous timing
                if (interval > medianInterval * 2.5 && interval - medianDuration >= self.silenceThreshold) {
                    double silenceStart = current.startTime + medianDuration;
                    double silenceDuration = next.startTime - silenceStart;
                    if (silenceDuration >= self.silenceThreshold) {
                        SpliceKitTranscriptSilence *silence = [[SpliceKitTranscriptSilence alloc] init];
                        silence.startTime = silenceStart;
                        silence.endTime = next.startTime;
                        silence.duration = silenceDuration;
                        silence.afterWordIndex = i;
                        [self.mutableSilences addObject:silence];
                    }
                }
            }
        }

        // Check last word too
        SpliceKitTranscriptWord *lastWord = self.mutableWords.lastObject;
        if (lastWord.duration >= suspectThreshold) {
            double estimatedSpeechEnd = lastWord.startTime + medianDuration;
            double intraGap = lastWord.endTime - estimatedSpeechEnd;
            if (intraGap >= self.silenceThreshold) {
                SpliceKitTranscriptSilence *silence = [[SpliceKitTranscriptSilence alloc] init];
                silence.startTime = estimatedSpeechEnd;
                silence.endTime = lastWord.endTime;
                silence.duration = intraGap;
                silence.afterWordIndex = self.mutableWords.count - 1;
                [self.mutableSilences addObject:silence];
            }
        }

        // Sort by start time since intra-word silences may interleave with gap silences
        [self.mutableSilences sortUsingComparator:^NSComparisonResult(SpliceKitTranscriptSilence *a, SpliceKitTranscriptSilence *b) {
            return [@(a.startTime) compare:@(b.startTime)];
        }];
    }

    SpliceKit_log(@"[Transcript] Detected %lu silences (threshold: %.2fs, suspectThreshold: %.2fs)",
                  (unsigned long)self.mutableSilences.count, self.silenceThreshold,
                  self.silenceThreshold * 2.0);
}

- (void)redetectSilencesAndRefreshUI {
    [self detectSilences];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self rebuildTextView];
        self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);
        [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses",
            (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSilences.count]];
    });
}

#pragma mark - Speaker Assignment

- (void)assignSpeakers {
    // If speaker diarization provided real labels, keep them.
    // Fill gaps: short runs of "Unknown" between the same speaker inherit that speaker.
    // This is standard diarization cleanup — the diarizer often drops confidence on
    // 1-2 word fragments at sentence boundaries, creating noise in the display.
    // Users can always manually override via setSpeaker:forWordsFrom:count:.
    @synchronized (self.mutableWords) {
        NSUInteger count = self.mutableWords.count;
        if (count == 0) return;

        // Pass 1: fill empty/nil speakers with "Unknown"
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            if (!word.speaker || word.speaker.length == 0) {
                word.speaker = @"Unknown";
            }
        }

        // Pass 2: propagate known speakers to neighboring "Unknown" runs.
        // For each run of Unknown words, if the speakers before and after the run
        // are the same, assign that speaker to the entire run. If only one side
        // has a known speaker, use that. This merges fragments like:
        //   Speaker 1 | Unknown | Speaker 1  →  Speaker 1 | Speaker 1 | Speaker 1
        NSUInteger i = 0;
        while (i < count) {
            if ([self.mutableWords[i].speaker isEqualToString:@"Unknown"]) {
                // Find the end of this Unknown run
                NSUInteger runStart = i;
                while (i < count && [self.mutableWords[i].speaker isEqualToString:@"Unknown"]) {
                    i++;
                }
                NSUInteger runEnd = i; // exclusive
                NSUInteger runLen = runEnd - runStart;

                // Get speakers before and after the run
                NSString *before = (runStart > 0) ? self.mutableWords[runStart - 1].speaker : nil;
                NSString *after = (runEnd < count) ? self.mutableWords[runEnd].speaker : nil;
                BOOL beforeKnown = before && ![before isEqualToString:@"Unknown"];
                BOOL afterKnown = after && ![after isEqualToString:@"Unknown"];

                NSString *assign = nil;
                if (beforeKnown && afterKnown && [before isEqualToString:after]) {
                    // Same speaker on both sides — merge
                    assign = before;
                } else if (runLen <= 3) {
                    // Short run (1-3 words) — assign from whichever side is known
                    if (beforeKnown) assign = before;
                    else if (afterKnown) assign = after;
                }

                if (assign) {
                    for (NSUInteger j = runStart; j < runEnd; j++) {
                        self.mutableWords[j].speaker = assign;
                    }
                }
            } else {
                i++;
            }
        }
    }
}

- (void)setSpeaker:(NSString *)speaker forWordsFrom:(NSUInteger)startIndex count:(NSUInteger)count {
    [self ensurePersistedStateLoaded];

    @synchronized (self.mutableWords) {
        NSUInteger end = MIN(startIndex + count, self.mutableWords.count);
        for (NSUInteger i = startIndex; i < end; i++) {
            self.mutableWords[i].speaker = speaker;
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self rebuildTextView];
    });
}

// Start a new run: stop a helper still working on the previous one (it may be
// stuck, e.g. waiting on a privacy prompt) and return this run's number.
- (NSUInteger)beginRun {
    NSUInteger generation = self.runGeneration + 1;
    self.runGeneration = generation;
    NSTask *previous = self.activeHelperTask;
    self.activeHelperTask = nil;
    @try {
        if (previous.isRunning) {
            SpliceKit_log(@"[Transcript] Stopping the previous transcriber (pid %d): a new run started",
                previous.processIdentifier);
            [previous terminate];
        }
    } @catch (__unused NSException *e) {
    }
    return generation;
}

// Why a media file cannot be transcribed, or nil when it can: missing, a folder,
// unreadable, or without an audio track (a screen recording). Both file mode and
// the timeline batch ask this first, so the reason reaches the caller instead of
// the helper failing on it.
+ (NSString *)audioProblemForFileAtPath:(NSString *)path {
    if (path.length == 0) return @"no file path";
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        // A dangling symlink (media on an unmounted volume) also lands here.
        NSString *dest = [fm destinationOfSymbolicLinkAtPath:path error:nil];
        if (dest.length) return [NSString stringWithFormat:@"file not found (link to %@, which is not reachable)", dest];
        return @"file not found";
    }
    if (isDir) return @"is a folder, not a media file";
    if (![fm isReadableFileAtPath:path]) return @"file is not readable (permissions)";
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        NSArray *allTracks = asset.tracks;
#pragma clang diagnostic pop
        // No tracks at all means AVFoundation could not parse it; let the helper
        // try (it has its own decoder) rather than refusing a file it may read.
        if (allTracks.count > 0 && audioTracks.count == 0) return @"no audio track";
    } @catch (__unused NSException *e) {
    }
    return nil;
}

- (void)transcribeFromURL:(NSURL *)audioURL
       timelineStart:(double)timelineStart
       trimStart:(double)trimStart
       trimDuration:(double)trimDuration {

    SpliceKit_log(@"[Transcript] Transcribing file: %@", audioURL.path);

    // File mode from here on: the persistence checks must not replace these words
    // with (or wipe them for) whatever timeline is open. Set synchronously so a
    // getState racing the main-queue block below already sees it.
    NSUInteger generation = [self beginRun];
    self.sourceFilePath = audioURL.path;
    self.skippedSources = nil;
    self.completedTranscriptions = 0;
    self.totalTranscriptions = 1;
    self.progressFraction = 0;
    self.progressMessage = @"Starting";
    self.transcriptionStartDate = [NSDate date];
    self.status = SpliceKitTranscriptStatusTranscribing;
    self.errorMessage = nil;
    @synchronized (self.mutableWords) {
        [self.mutableWords removeAllObjects];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.mutableSilences removeAllObjects];
        self.fullText = nil;
        [self rebuildTextView];
        self.status = SpliceKitTranscriptStatusTranscribing;
        self.errorMessage = nil;
        [self updateStatusUI:@"Transcribing audio file..."];
        self.spinner.hidden = NO;
        [self.spinner startAnimation:nil];
        self.progressBar.hidden = NO;
        self.progressBar.indeterminate = YES;
        [self.progressBar startAnimation:nil];
        self.refreshButton.enabled = NO;
        self.deleteSilencesButton.enabled = NO;
    });

    // Honour the selected engine. This path used to go straight to Apple Speech
    // whatever the dropdown said, so transcribing a file with Parakeet selected
    // silently ran a different engine — and failed outright on a Mac where
    // speech recognition was never authorised, which is every freshly installed
    // one. Parakeet needs no permission, so route it there when it is selected.
    if (self.engine == SpliceKitTranscriptEngineParakeet) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *problem = [SpliceKitTranscriptPanel audioProblemForFileAtPath:audioURL.path];
            if (problem) {
                [self setErrorState:[NSString stringWithFormat:@"Cannot transcribe %@: %@",
                    audioURL.path, problem]];
                return;
            }
            [self transcribeFileWithParakeet:audioURL timelineStart:timelineStart generation:generation];
        });
        return;
    }

    [self requestSpeechAuthorizationWithCompletion:^(BOOL authorized) {
        if (!authorized) {
            // Keep the specific reason the helper recorded; opening System Settings
            // is still the right next step, but it must not replace the message.
            [self openSpeechRecognitionSettings];
            if (!self.errorMessage) {
                [self setErrorState:@"Speech recognition not authorized. Opening System Settings..."];
            }
            return;
        }

        [self.mutableWords removeAllObjects];
        [self.mutableSilences removeAllObjects];

        [self transcribeAudioFile:audioURL
                    timelineStart:timelineStart
                        trimStart:trimStart
                     trimDuration:(trimDuration == HUGE_VAL ? 7200.0 : trimDuration)
                       clipHandle:nil
                       completion:^(NSArray<SpliceKitTranscriptWord *> *words, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    [self setErrorState:[NSString stringWithFormat:@"Transcription error: %@",
                        error.localizedDescription]];
                } else {
                    @synchronized (self.mutableWords) {
                        [self.mutableWords addObjectsFromArray:words];
                        for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
                            self.mutableWords[i].wordIndex = i;
                        }
                    }

                    [self detectSilences];
                    [self assignSpeakers];

                    self.status = SpliceKitTranscriptStatusReady;
                    [self rebuildTextView];
                    [self startPlayheadTimer];
                    self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);

                    NSUInteger silenceCount = self.mutableSilences.count;
                    [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses",
                        (unsigned long)self.mutableWords.count, (unsigned long)silenceCount]];
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"SpliceKitTranscriptDidComplete" object:self];
                }

                self.spinner.hidden = YES;
                [self.spinner stopAnimation:nil];
                self.progressBar.hidden = YES;
                self.refreshButton.enabled = YES;
            });
        }];
    }];
}

#pragma mark - Timeline Editing Operations
//
// Low-level timeline manipulation. These methods blade, select, and delete segments
// by driving FCP's own editing commands through the responder chain. The sleeps
// between operations give FCP's undo system and layout engine time to catch up —
// without them, rapid-fire edits can desync the timeline state.
//

/// Blade at start, blade at end, select the segment in between, ripple delete it.
- (NSDictionary *)deleteTimelineRange:(double)deleteStart end:(double)deleteEnd {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) {
                result = @{@"error": @"No active timeline"};
                return;
            }

            // Blade at start
            [self setPlayheadToTime:deleteStart];
            [NSThread sleepForTimeInterval:0.02];

            SEL bladeSel = NSSelectorFromString(@"blade:");
            if ([timeline respondsToSelector:bladeSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, bladeSel, nil);
            }
            [NSThread sleepForTimeInterval:0.02];

            // Blade at end
            [self setPlayheadToTime:deleteEnd];
            [NSThread sleepForTimeInterval:0.02];

            if ([timeline respondsToSelector:bladeSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, bladeSel, nil);
            }
            [NSThread sleepForTimeInterval:0.02];

            // Select clip at midpoint
            double midPoint = (deleteStart + deleteEnd) / 2.0;
            [self setPlayheadToTime:midPoint];
            [NSThread sleepForTimeInterval:0.02];

            SEL selectSel = NSSelectorFromString(@"selectClipAtPlayhead:");
            if ([timeline respondsToSelector:selectSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, selectSel, nil);
            }
            [NSThread sleepForTimeInterval:0.02];

            // Delete (ripple delete)
            SEL deleteSel = NSSelectorFromString(@"delete:");
            if ([timeline respondsToSelector:deleteSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, deleteSel, nil);
            }

            result = @{@"status": @"ok",
                       @"timeRange": @{@"start": @(deleteStart), @"end": @(deleteEnd)},
                       @"duration": @(deleteEnd - deleteStart)};

        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

/// Deletes a contiguous range of words from both the timeline and our data model.
/// After the timeline edit, we remove the words from the array, re-index, and
/// resync timestamps from FCP's actual clip positions (since blade changes durations).
- (NSDictionary *)deleteWordsFromIndex:(NSUInteger)startIndex count:(NSUInteger)count {
    [self ensurePersistedStateLoaded];

    @synchronized (self.mutableWords) {
        if (startIndex >= self.mutableWords.count) {
            return @{@"error": @"startIndex out of range"};
        }
        if (startIndex + count > self.mutableWords.count) {
            count = self.mutableWords.count - startIndex;
        }
    }

    SpliceKitTranscriptWord *firstWord = self.mutableWords[startIndex];
    SpliceKitTranscriptWord *lastWord = self.mutableWords[startIndex + count - 1];
    double deleteStart = firstWord.startTime;
    double deleteEnd = lastWord.endTime;
    double deletedDuration = deleteEnd - deleteStart;

    SpliceKit_log(@"[Transcript] Deleting words %lu-%lu: %.2fs - %.2fs (%.2fs)",
                  (unsigned long)startIndex, (unsigned long)(startIndex + count - 1),
                  deleteStart, deleteEnd, deletedDuration);

    NSDictionary *result = [self deleteTimelineRange:deleteStart end:deleteEnd];

    if (result[@"error"]) return result;

    // Remove deleted words from the data model
    @synchronized (self.mutableWords) {
        [self.mutableWords removeObjectsInRange:NSMakeRange(startIndex, count)];
        for (NSUInteger i = startIndex; i < self.mutableWords.count; i++) {
            self.mutableWords[i].wordIndex = i;
        }
    }

    // Resync timestamps from the actual FCP timeline state
    [self resyncTimestampsFromTimeline];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self rebuildTextView];
        self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);
        [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses",
            (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSilences.count]];
    });

    NSMutableDictionary *fullResult = [result mutableCopy];
    fullResult[@"deletedWords"] = @(count);
    return fullResult;
}

#pragma mark - Delete Silences (Batch)
// Removes silence gaps from the timeline. Works from end to start so each
// removal's time shift doesn't affect the positions of not-yet-deleted silences.
// After all timeline edits, we walk forward through the word array and shift
// timestamps by the cumulative duration of removed silences before each word.

- (NSDictionary *)deleteAllSilences {
    return [self deleteSilencesLongerThan:0];
}

- (NSDictionary *)deleteSilencesLongerThan:(double)minDuration {
    [self ensurePersistedStateLoaded];

    // Collect silences to delete (filter by minimum duration)
    NSMutableArray<SpliceKitTranscriptSilence *> *toDelete = [NSMutableArray array];
    for (SpliceKitTranscriptSilence *silence in self.mutableSilences) {
        if (silence.duration >= minDuration) {
            [toDelete addObject:silence];
        }
    }

    if (toDelete.count == 0) {
        return @{@"status": @"ok", @"deletedCount": @0, @"message": @"No silences to delete"};
    }

    SpliceKit_log(@"[Transcript] Batch deleting %lu silences (min duration: %.2fs)",
                  (unsigned long)toDelete.count, minDuration);

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatusUI:[NSString stringWithFormat:@"Deleting %lu pauses...", (unsigned long)toDelete.count]];
        self.spinner.hidden = NO;
        [self.spinner startAnimation:nil];
        self.deleteSilencesButton.enabled = NO;
    });

    // Sort by startTime descending (delete from end first to avoid position shifts)
    [toDelete sortUsingComparator:^NSComparisonResult(SpliceKitTranscriptSilence *a, SpliceKitTranscriptSilence *b) {
        return (a.startTime > b.startTime) ? NSOrderedAscending : NSOrderedDescending;
    }];

    __block NSUInteger deletedCount = 0;
    __block NSString *lastError = nil;
    __block double totalTimeRemoved = 0;

    // Use the safe blade+select+delete approach via the responder chain.
    // Sleeps are reduced from 50ms to 20ms since these are direct ObjC calls
    // that execute synchronously — the sleep is just for FCP's internal state to settle.
    for (SpliceKitTranscriptSilence *silence in toDelete) {
        // Adjust times for already-removed content
        double adjStart = silence.startTime - totalTimeRemoved;
        double adjEnd = silence.endTime - totalTimeRemoved;

        NSDictionary *result = [self deleteTimelineRange:adjStart end:adjEnd];
        if (result[@"error"]) {
            lastError = result[@"error"];
            SpliceKit_log(@"[Transcript] Error deleting silence at %.2fs: %@", adjStart, lastError);
        } else {
            deletedCount++;
            totalTimeRemoved += silence.duration;
        }

        if (deletedCount % 5 == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateStatusUI:[NSString stringWithFormat:@"Deleting pauses... %lu/%lu",
                    (unsigned long)deletedCount, (unsigned long)toDelete.count]];
            });
        }
    }

    // Re-read the actual clip layout after the ripple deletes instead of trying
    // to infer every timestamp shift locally. This keeps clipTimelineStart and
    // sourceMediaOffset consistent with the real timeline state.
    [self resyncTimestampsFromTimeline];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self rebuildTextView];
        self.spinner.hidden = YES;
        [self.spinner stopAnimation:nil];
        self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);
        [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses — removed %lu silences",
            (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSilences.count,
            (unsigned long)deletedCount]];
    });

    NSMutableDictionary *response = [NSMutableDictionary dictionary];
    response[@"status"] = lastError ? @"partial" : @"ok";
    response[@"deletedCount"] = @(deletedCount);
    response[@"totalSilences"] = @(toDelete.count);
    response[@"timeRemoved"] = @(totalTimeRemoved);
    if (lastError) response[@"lastError"] = lastError;

    return response;
}

#pragma mark - Move Words (Drag to Reorder)

/// Moves a range of words to a new position in the timeline. The operation is:
/// blade at source boundaries, cut the segment, seek to destination, paste.
/// The destination time is adjusted if it's after the source (since cutting
/// the source shifts everything after it earlier by the source duration).
- (NSDictionary *)moveWordsFromIndex:(NSUInteger)startIndex count:(NSUInteger)count toIndex:(NSUInteger)destIndex {
    [self ensurePersistedStateLoaded];

    @synchronized (self.mutableWords) {
        if (startIndex >= self.mutableWords.count || destIndex > self.mutableWords.count) {
            return @{@"error": @"Index out of range"};
        }
        if (startIndex + count > self.mutableWords.count) {
            count = self.mutableWords.count - startIndex;
        }
        if (destIndex > startIndex && destIndex < startIndex + count) {
            return @{@"error": @"Cannot move to within source range"};
        }
    }

    SpliceKitTranscriptWord *firstWord = self.mutableWords[startIndex];
    SpliceKitTranscriptWord *lastWord = self.mutableWords[startIndex + count - 1];
    double sourceStart = firstWord.startTime;
    double sourceEnd = lastWord.endTime;
    double sourceDuration = sourceEnd - sourceStart;

    double destTime;
    if (destIndex == 0) {
        destTime = 0;
    } else if (destIndex >= self.mutableWords.count) {
        SpliceKitTranscriptWord *lastW = self.mutableWords.lastObject;
        destTime = lastW.endTime;
    } else {
        destTime = self.mutableWords[destIndex].startTime;
    }

    SpliceKit_log(@"[Transcript] Moving words %lu-%lu (%.2fs-%.2fs) to index %lu (time %.2fs)",
                  (unsigned long)startIndex, (unsigned long)(startIndex + count - 1),
                  sourceStart, sourceEnd, (unsigned long)destIndex, destTime);

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) {
                result = @{@"error": @"No active timeline"};
                return;
            }

            // Step 1: Blade at source start
            [self setPlayheadToTime:sourceStart];
            [NSThread sleepForTimeInterval:0.05];
            SEL bladeSel = NSSelectorFromString(@"blade:");
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, bladeSel, nil);
            [NSThread sleepForTimeInterval:0.05];

            // Step 2: Blade at source end
            [self setPlayheadToTime:sourceEnd];
            [NSThread sleepForTimeInterval:0.05];
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, bladeSel, nil);
            [NSThread sleepForTimeInterval:0.05];

            // Step 3: Select the source segment
            double midPoint = (sourceStart + sourceEnd) / 2.0;
            [self setPlayheadToTime:midPoint];
            [NSThread sleepForTimeInterval:0.05];

            SEL selectSel = NSSelectorFromString(@"selectClipAtPlayhead:");
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, selectSel, nil);
            [NSThread sleepForTimeInterval:0.05];

            // Step 4: Cut
            SEL cutSel = NSSelectorFromString(@"cut:");
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, cutSel, nil);
            [NSThread sleepForTimeInterval:0.1];

            // Step 5: Move playhead to destination (adjust for position shift)
            double adjustedDestTime = destTime;
            if (destTime > sourceStart) {
                adjustedDestTime -= sourceDuration;
            }
            [self setPlayheadToTime:adjustedDestTime];
            [NSThread sleepForTimeInterval:0.05];

            // Step 6: Paste
            SEL pasteSel = NSSelectorFromString(@"paste:");
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, pasteSel, nil);

            result = @{@"status": @"ok",
                       @"movedWords": @(count),
                       @"from": @{@"start": @(sourceStart), @"end": @(sourceEnd)},
                       @"to": @(destTime)};

        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    if (result[@"error"]) return result;

    // Update data model locally: reorder words in the array
    @synchronized (self.mutableWords) {
        NSArray *movedWords = [self.mutableWords subarrayWithRange:NSMakeRange(startIndex, count)];
        [self.mutableWords removeObjectsInRange:NSMakeRange(startIndex, count)];

        NSUInteger adjustedDest = destIndex;
        if (destIndex > startIndex) {
            adjustedDest -= count;
        }
        adjustedDest = MIN(adjustedDest, self.mutableWords.count);

        NSIndexSet *insertIndices = [NSIndexSet indexSetWithIndexesInRange:
            NSMakeRange(adjustedDest, count)];
        [self.mutableWords insertObjects:movedWords atIndexes:insertIndices];

        // Re-index
        for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
            self.mutableWords[i].wordIndex = i;
        }
    }

    // Resync timestamps from the actual FCP timeline state
    [self resyncTimestampsFromTimeline];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self rebuildTextView];
        self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);
        [self updateStatusUI:[NSString stringWithFormat:@"Moved %lu words — %lu words, %lu pauses",
            (unsigned long)count, (unsigned long)self.mutableWords.count,
            (unsigned long)self.mutableSilences.count]];
    });

    return result;
}

#pragma mark - Resync Timestamps from Timeline
//
// After any edit (move, delete), the word timestamps in our data model may not
// match FCP's actual timeline anymore. This method re-reads the real clip positions
// from FCP and re-maps each word using its immutable sourceMediaTime (position in
// the original source file). This is the most reliable way to stay in sync —
// trying to track cumulative shifts manually is fragile with compound edits.
//

- (void)resyncTimestampsFromTimeline {
    // Each word has an immutable sourceMediaTime (its position in the source file).
    // We match each word to the clip that contains its source time, then compute:
    //   word.startTime = clip.timelineStart + (word.sourceMediaTime - clip.trimStart)
    SpliceKit_log(@"[Transcript] Resyncing timestamps from timeline...");

    // Give FCP a moment to settle after the edit
    [NSThread sleepForTimeInterval:0.3];

    __block NSArray *clipInfos = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) return;

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) return;

            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject))
                : nil;
            clipInfos = [self collectClipInfosForSequence:sequence primaryObject:primaryObj errorMessage:nil];
        } @catch (NSException *e) {
            SpliceKit_log(@"[Transcript] Resync error: %@", e.reason);
        }
    });

    if (!clipInfos || clipInfos.count == 0) {
        SpliceKit_log(@"[Transcript] Resync: no clips found");
        return;
    }

    // Build actual clip segments with media paths for matching
    NSMutableArray *actualClips = [NSMutableArray array];
    for (NSDictionary *info in clipInfos) {
        NSURL *mediaURL = info[@"mediaURL"];
        if (mediaURL) {
            [actualClips addObject:@{
                @"timelineStart": info[@"timelineStart"] ?: @0,
                @"trimStart": info[@"trimStart"] ?: @0,
                @"duration": info[@"duration"] ?: @0,
                @"path": mediaURL.path ?: @"",
            }];
        }
    }

    SpliceKit_log(@"[Transcript] Resync: found %lu clips on timeline", (unsigned long)actualClips.count);

    @synchronized (self.mutableWords) {
        if (self.mutableWords.count == 0) return;

        NSUInteger matched = 0, unmatched = 0;

        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            double smt = word.sourceMediaTime;
            NSString *path = word.sourceMediaPath;
            BOOL found = NO;

            // Find the clip on the timeline that contains this word's source media time.
            // After blade operations, the original clip may be split into multiple
            // clips with different trimStart/duration ranges.
            for (NSDictionary *clip in actualClips) {
                double clipTrimStart = [clip[@"trimStart"] doubleValue];
                double clipDuration = [clip[@"duration"] doubleValue];
                double clipTimelineStart = [clip[@"timelineStart"] doubleValue];
                NSString *clipPath = clip[@"path"];

                // Match by source media path and source time within clip's trim range
                BOOL pathMatch = (!path || !clipPath || path.length == 0 ||
                                  [path isEqualToString:clipPath]);
                BOOL timeMatch = (smt >= clipTrimStart - 0.01 &&
                                  smt < clipTrimStart + clipDuration + 0.01);

                if (pathMatch && timeMatch) {
                    double newStartTime = clipTimelineStart + (smt - clipTrimStart);
                    word.startTime = newStartTime;
                    word.clipTimelineStart = clipTimelineStart;
                    word.sourceMediaOffset = clipTrimStart;
                    found = YES;
                    matched++;
                    break;
                }
            }

            if (!found) {
                unmatched++;
            }
        }

        SpliceKit_log(@"[Transcript] Resync: matched %lu words, %lu unmatched",
                      (unsigned long)matched, (unsigned long)unmatched);
    }

    [self detectSilences];
    SpliceKit_log(@"[Transcript] Resync complete");
}

- (void)updatePlayheadHighlight:(double)timeInSeconds {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.suppressTextViewCallbacks) return;
        if (self.searchResultRanges.count > 0) return;

        NSTextStorage *storage = self.textView.textStorage;
        NSUInteger storageLen = storage.length;
        if (storageLen == 0) return;

        // Find which word the playhead is on
        NSRange newRange = NSMakeRange(NSNotFound, 0);
        @synchronized (self.mutableWords) {
            for (SpliceKitTranscriptWord *word in self.mutableWords) {
                if (timeInSeconds >= word.startTime && timeInSeconds < word.endTime) {
                    if (word.textRange.location + word.textRange.length <= storageLen) {
                        newRange = word.textRange;
                    }
                    break;
                }
            }
        }

        // Skip update if same word is already highlighted
        if (NSEqualRanges(newRange, self.lastPlayheadHighlightRange)) return;

        self.suppressTextViewCallbacks = YES;

        // Clear only the previous highlight (not the whole document)
        if (self.lastPlayheadHighlightRange.location != NSNotFound &&
            self.lastPlayheadHighlightRange.location + self.lastPlayheadHighlightRange.length <= storageLen) {
            [storage removeAttribute:NSBackgroundColorAttributeName
                               range:self.lastPlayheadHighlightRange];
        }

        // Apply new highlight
        if (newRange.location != NSNotFound) {
            [storage addAttribute:NSBackgroundColorAttributeName
                            value:[NSColor colorWithCalibratedRed:0.2 green:0.5 blue:1.0 alpha:0.3]
                            range:newRange];
        }

        self.lastPlayheadHighlightRange = newRange;
        self.suppressTextViewCallbacks = NO;
    });
}

#pragma mark - FCP Integration Helpers
// These reach into FCP's runtime to get the active timeline module and move the
// playhead. The chain is: NSApp -> delegate -> activeEditorContainer -> timelineModule.

- (id)getEditorContainer {
    id app = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("NSApplication"), @selector(sharedApplication));
    id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
    if (!delegate) return nil;

    SEL aecSel = @selector(activeEditorContainer);
    if (![delegate respondsToSelector:aecSel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(delegate, aecSel);
}

- (id)getActiveTimelineModule {
    id container = [self getEditorContainer];
    if (!container) return nil;

    SEL tmSel = NSSelectorFromString(@"timelineModule");
    if ([container respondsToSelector:tmSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(container, tmSel);
    }
    return nil;
}

/// Moves the playhead to an exact time (in seconds) by constructing a CMTime and
/// calling setPlayheadTime: on the timeline module. The timescale is read from
/// the sequence's frame duration so we snap to exact frame boundaries.
- (void)setPlayheadToTime:(double)seconds {
    id timeline = [self getActiveTimelineModule];
    if (!timeline) return;

    int32_t timescale = 600;
    if ([timeline respondsToSelector:@selector(sequenceFrameDuration)]) {
        SpliceKitTranscript_CMTime fd = ((SpliceKitTranscript_CMTime (*)(id, SEL))STRET_MSG)(
            timeline, @selector(sequenceFrameDuration));
        if (fd.timescale > 0) timescale = fd.timescale;
    }

    SpliceKitTranscript_CMTime cmTime = {
        .value = (int64_t)(seconds * timescale),
        .timescale = timescale,
        .flags = 1,
        .epoch = 0
    };

    SEL setPlayheadSel = NSSelectorFromString(@"setPlayheadTime:");
    if ([timeline respondsToSelector:setPlayheadSel]) {
        ((void (*)(id, SEL, SpliceKitTranscript_CMTime))objc_msgSend)(timeline, setPlayheadSel, cmTime);
    }
}

#pragma mark - State
// Thread-safe accessors and the getState method used by the MCP API to
// return the full transcript state (words, silences, timecodes, progress).

- (NSArray<SpliceKitTranscriptWord *> *)words {
    @synchronized (self.mutableWords) {
        return [self.mutableWords copy];
    }
}

- (NSArray<SpliceKitTranscriptSilence *> *)silences {
    return [self.mutableSilences copy];
}

- (NSDictionary *)getState {
    return [self getStateWithOptions:nil];
}

static BOOL SpliceKitTranscript_optBool(NSDictionary *opts, NSString *key, BOOL fallback) {
    id v = opts[key];
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return fallback;
}

static double SpliceKitTranscript_optDouble(NSDictionary *opts, NSString *key, double fallback) {
    id v = opts[key];
    if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]]) {
        NSString *str = [v description];
        if (str.length) return [v doubleValue];
    }
    return fallback;
}

// Options (all optional; with none the answer is the full state, as before):
//   includeWords / includeSilences / includeText / includeGapBuckets / includeSkipped (bool, default YES)
//   wordsOnly     — words and the counts only: no text, silences or gap histogram
//   fields        — word keys to return, e.g. ["text","startTime","endTime"]
//   startSeconds / endSeconds — only words (and silences) overlapping this timeline window
//   offset / limit — page through the (windowed) word list; nextOffset says where to go on
// A 40-minute transcript is ~1.8 M characters in full; a page of words with three
// fields is a few KB, which is what an MCP client can take in one answer.
- (NSDictionary *)getStateWithOptions:(NSDictionary *)opts {
    [self ensurePersistedStateLoaded];
    if (![opts isKindOfClass:[NSDictionary class]]) opts = @{};

    BOOL wordsOnly = SpliceKitTranscript_optBool(opts, @"wordsOnly", NO);
    BOOL includeWords = SpliceKitTranscript_optBool(opts, @"includeWords", YES);
    BOOL includeSilences = SpliceKitTranscript_optBool(opts, @"includeSilences", !wordsOnly);
    BOOL includeText = SpliceKitTranscript_optBool(opts, @"includeText", !wordsOnly);
    BOOL includeGapBuckets = SpliceKitTranscript_optBool(opts, @"includeGapBuckets", !wordsOnly);
    BOOL includeSkipped = SpliceKitTranscript_optBool(opts, @"includeSkipped", YES);
    double windowStart = SpliceKitTranscript_optDouble(opts, @"startSeconds", -INFINITY);
    double windowEnd = SpliceKitTranscript_optDouble(opts, @"endSeconds", INFINITY);
    BOOL windowed = isfinite(windowStart) || isfinite(windowEnd);
    NSInteger offset = MAX(0, (NSInteger)SpliceKitTranscript_optDouble(opts, @"offset", 0));
    double limitValue = SpliceKitTranscript_optDouble(opts, @"limit", -1);
    NSInteger limit = limitValue > 0 ? (NSInteger)limitValue : -1;
    NSSet *fields = nil;
    if ([opts[@"fields"] isKindOfClass:[NSArray class]] && [opts[@"fields"] count] > 0) {
        fields = [NSSet setWithArray:opts[@"fields"]];
    } else if ([opts[@"fields"] isKindOfClass:[NSString class]] && [opts[@"fields"] length] > 0) {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *part in [opts[@"fields"] componentsSeparatedByString:@","]) {
            NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length) [parts addObject:trimmed];
        }
        if (parts.count) fields = [NSSet setWithArray:parts];
    }

    NSMutableDictionary *state = [NSMutableDictionary dictionary];

    switch (self.status) {
        case SpliceKitTranscriptStatusIdle:        state[@"status"] = @"idle"; break;
        case SpliceKitTranscriptStatusTranscribing: state[@"status"] = @"transcribing"; break;
        case SpliceKitTranscriptStatusReady:       state[@"status"] = @"ready"; break;
        case SpliceKitTranscriptStatusError:       state[@"status"] = @"error"; break;
    }

    state[@"visible"] = @(self.isVisible);
    state[@"wordCount"] = @(self.mutableWords.count);
    state[@"silenceCount"] = @(self.mutableSilences.count);
    state[@"silenceThreshold"] = @(self.silenceThreshold);
    // The 24 fps default is not a reading: say so until a timeline run (or a
    // restored transcript) has told us the sequence's rate.
    if (self.frameRateKnown) {
        state[@"frameRate"] = @(self.frameRate);
    } else {
        state[@"frameRate"] = [NSNull null];
        state[@"frameRateNote"] = [NSString stringWithFormat:
            @"unknown (no timeline transcribed yet); timecodes use %.0f fps", self.frameRate];
    }
    if (self.sourceFilePath.length > 0) {
        state[@"source"] = @{@"mode": @"file", @"path": self.sourceFilePath};
    } else {
        NSMutableDictionary *source = [@{@"mode": @"timeline"} mutableCopy];
        if (self.primaryStorylineOnly) source[@"primaryStorylineOnly"] = @YES;
        state[@"source"] = source;
    }
    state[@"engine"] = (self.engine == SpliceKitTranscriptEngineFCPNative) ? @"fcpNative" :
                       (self.engine == SpliceKitTranscriptEngineParakeet) ? @"parakeet" : @"appleSpeech";
    if (self.engine == SpliceKitTranscriptEngineParakeet) {
        state[@"parakeetModel"] = self.parakeetModelVersion ?: @"v3";
    }
    state[@"speakerDetectionAvailable"] = @(SpliceKitTranscript_isSpeakerDiarizationAvailable());
    state[@"speakerDetectionEnabled"] = @(self.speakerDetectionEnabled);

    if (self.errorMessage) {
        state[@"errorMessage"] = self.errorMessage;
    }

    if (includeText && self.fullText) {
        state[@"text"] = self.fullText;
    }

    if (self.status == SpliceKitTranscriptStatusTranscribing) {
        NSMutableDictionary *progress = [@{
            @"completed": @(self.completedTranscriptions),
            @"total": @(self.totalTranscriptions),
            @"fraction": @(self.progressFraction),
        } mutableCopy];
        if (self.progressMessage.length) progress[@"message"] = self.progressMessage;
        if (self.transcriptionStartDate) {
            progress[@"elapsedSeconds"] = @(round(-[self.transcriptionStartDate timeIntervalSinceNow] * 10) / 10);
        }
        state[@"progress"] = progress;
    }

    NSArray *skipped = self.skippedSources;
    if (includeSkipped && skipped.count > 0) {
        state[@"skippedClips"] = skipped;
    }

    if (includeWords && self.mutableWords.count > 0) {
        NSMutableArray *wordList = [NSMutableArray array];
        NSInteger matched = 0;
        @synchronized (self.mutableWords) {
            for (SpliceKitTranscriptWord *word in self.mutableWords) {
                if (windowed && (word.endTime <= windowStart || word.startTime >= windowEnd)) continue;
                NSInteger position = matched++;
                if (position < offset) continue;
                if (limit >= 0 && (NSInteger)wordList.count >= limit) continue;
                // Times to the millisecond (a frame is 17-42 ms): the helper's float32
                // times printed as 5.199999809265137 made up much of the payload.
                NSDictionary *full = @{
                    @"index": @(word.wordIndex),
                    @"text": word.text ?: @"",
                    @"startTime": @(round(word.startTime * 1000.0) / 1000.0),
                    @"endTime": @(round(word.endTime * 1000.0) / 1000.0),
                    @"duration": @(round(word.duration * 1000.0) / 1000.0),
                    @"confidence": @(round(word.confidence * 1000.0) / 1000.0),
                    @"speaker": word.speaker ?: @"Unknown"
                };
                if (fields) {
                    NSMutableDictionary *picked = [NSMutableDictionary dictionary];
                    for (NSString *key in full) {
                        if ([fields containsObject:key]) picked[key] = full[key];
                    }
                    [wordList addObject:picked];
                } else {
                    [wordList addObject:full];
                }
            }
        }
        state[@"words"] = wordList;
        if (windowed || offset > 0 || limit >= 0) {
            state[@"wordsMatched"] = @(matched);
            state[@"wordsOffset"] = @(offset);
            state[@"wordsReturned"] = @(wordList.count);
            NSInteger next = offset + (NSInteger)wordList.count;
            state[@"nextOffset"] = next < matched ? @(next) : [NSNull null];
        }
    }

    if (includeSilences && self.mutableSilences.count > 0) {
        NSMutableArray *silenceList = [NSMutableArray array];
        for (SpliceKitTranscriptSilence *silence in self.mutableSilences) {
            if (windowed && (silence.endTime <= windowStart || silence.startTime >= windowEnd)) continue;
            [silenceList addObject:@{
                @"startTime": @(round(silence.startTime * 1000.0) / 1000.0),
                @"endTime": @(round(silence.endTime * 1000.0) / 1000.0),
                @"duration": @(round(silence.duration * 1000.0) / 1000.0),
                @"afterWordIndex": @(silence.afterWordIndex),
                @"startTimecode": SpliceKitTranscript_timecodeFromSeconds(silence.startTime, self.frameRate),
                @"endTimecode": SpliceKitTranscript_timecodeFromSeconds(silence.endTime, self.frameRate),
            }];
        }
        state[@"silences"] = silenceList;
    }

    // Gap histogram — helps users pick a useful silence threshold
    if (includeGapBuckets && self.mutableWords.count >= 2) {
        NSUInteger gaps01 = 0, gaps03 = 0, gaps05 = 0, gaps10 = 0, gaps20 = 0, gaps50 = 0;
        @synchronized (self.mutableWords) {
            for (NSUInteger i = 0; i < self.mutableWords.count - 1; i++) {
                SpliceKitTranscriptWord *current = self.mutableWords[i];
                SpliceKitTranscriptWord *next = self.mutableWords[i + 1];
                double gap = next.startTime - current.endTime;
                // Also count intra-word gaps from suspiciously long words
                double wordExcess = current.duration - 1.0;
                double effectiveGap = MAX(gap, wordExcess);
                if (effectiveGap >= 0.1) gaps01++;
                if (effectiveGap >= 0.3) gaps03++;
                if (effectiveGap >= 0.5) gaps05++;
                if (effectiveGap >= 1.0) gaps10++;
                if (effectiveGap >= 2.0) gaps20++;
                if (effectiveGap >= 5.0) gaps50++;
            }
        }
        state[@"gapBuckets"] = @{
            @"0.1+": @(gaps01),
            @"0.3+": @(gaps03),
            @"0.5+": @(gaps05),
            @"1.0+": @(gaps10),
            @"2.0+": @(gaps20),
            @"5.0+": @(gaps50),
        };
    }

    return state;
}

@end
