//
//  SpliceKitTranscriptPanel+Private.h
//  Private declarations shared by SpliceKitTranscriptPanel.m and the files split out of it
//  (listed in SOURCES.txt right after it).
//  The functions and variables below were file-static before SpliceKitTranscriptPanel.m
//  was split. They are declared hidden so they stay out of the dylib's exported symbols.
//

#ifndef SpliceKitTranscriptPanel_Private_h
#define SpliceKitTranscriptPanel_Private_h

// The imports SpliceKitTranscriptPanel.m has always been compiled with.
#import "SpliceKitTranscriptPanel.h"
#import "SpliceKitTranscriptDiagnostics.h"
#import "SpliceKit.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "SpliceKitTime.h"
#import "SpliceKitProcess.h"

@interface SpliceKitTranscriptPanel (TextViewCallbacks)
- (void)handleClickAtCharIndex:(NSUInteger)charIdx;
- (void)handleDeleteKeyInTextView;
- (void)handleDropOfWordStart:(NSUInteger)srcStart count:(NSUInteger)srcCount atCharIndex:(NSUInteger)charIdx;
- (NSUInteger)wordIndexAtCharIndex:(NSUInteger)charIdx;
- (NSRange)selectedWordRange;
- (void)focusSearchField;
@end

@interface SpliceKitTranscriptTextView : NSTextView <NSDraggingSource>
@property (nonatomic, weak) SpliceKitTranscriptPanel *transcriptPanel;
@property (nonatomic) BOOL isDragging;
@property (nonatomic) NSPoint dragOrigin;
@end

@interface SpliceKitTranscriptPanel () <NSTextViewDelegate, NSWindowDelegate, NSSearchFieldDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) SpliceKitTranscriptTextView *textView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSButton *refreshButton;
@property (nonatomic, strong) NSTimer *playheadTimer;

// Search & Filter UI
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSPopUpButton *filterPopup;
@property (nonatomic, strong) NSButton *deleteResultsButton;
@property (nonatomic, strong) NSButton *deleteSilencesButton;
@property (nonatomic, strong) NSTextField *resultCountLabel;
@property (nonatomic, strong) NSButton *prevResultButton;
@property (nonatomic, strong) NSButton *nextResultButton;

// Data
@property (nonatomic, readwrite) SpliceKitTranscriptStatus status;
@property (nonatomic, readwrite, strong) NSMutableArray<SpliceKitTranscriptWord *> *mutableWords;
@property (nonatomic, readwrite, strong) NSMutableArray<SpliceKitTranscriptSilence *> *mutableSilences;
@property (nonatomic, readwrite, copy) NSString *fullText;
@property (nonatomic, readwrite, copy) NSString *errorMessage;

// Transcription tracking
@property (nonatomic, strong) NSMutableArray *pendingTranscriptions;
@property (nonatomic) NSUInteger completedTranscriptions;
@property (nonatomic) NSUInteger totalTranscriptions;
@property (nonatomic) BOOL suppressTextViewCallbacks;

// Search state
@property (nonatomic, strong) NSMutableArray<NSValue *> *searchResultRanges; // NSRange values
@property (nonatomic) NSInteger currentSearchIndex;
@property (nonatomic, copy) NSString *currentSearchQuery;
@property (nonatomic, copy) NSString *currentFilter; // "all", "pauses", "lowConfidence"

// Progress bar
@property (nonatomic, strong) NSProgressIndicator *progressBar;

// Playhead tracking — stores the last highlighted word range to avoid clearing the whole document
@property (nonatomic) NSRange lastPlayheadHighlightRange;

// Options menu
@property (nonatomic, strong) NSPopUpButton *enginePopup;
// parakeetModelVersion is declared in the public header so the transcript.setEngine RPC can set it.

// Speaker diarization (macOS 26+)
@property (nonatomic, strong) NSButton *speakerDetectionCheckbox;
@property (nonatomic) BOOL speakerDetectionEnabled;

// Frame rate for timecodes
@property (nonatomic) double frameRate;
@property (nonatomic) BOOL suppressPersistenceWrites;
@property (nonatomic, copy) NSString *lastRestoredSequenceKey;
// NO until a timeline run read the sequence's frame duration; getState then
// reports the rate as unknown instead of the 24 fps default.
@property (nonatomic) BOOL frameRateKnown;
@property (nonatomic, readwrite, copy) NSString *sourceFilePath;
// Live progress for getState: the helper's last PROGRESS line and when the run began.
@property (atomic, copy) NSString *progressMessage;
@property (atomic) double progressFraction;
@property (atomic, strong) NSDate *transcriptionStartDate;
// Clips/files a timeline run left out, with the reason (no audio track, missing,
// the helper could not read it). Reported by getState so a partial transcript says so.
@property (atomic, copy) NSArray<NSDictionary *> *skippedSources;
// Each run takes a number; a helper that finishes after a newer run started (a
// forced re-run over a stuck one) drops its result instead of overwriting.
@property (atomic) NSUInteger runGeneration;
@property (atomic, strong) NSTask *activeHelperTask;
@end

#pragma GCC visibility push(hidden)

#pragma mark - Defined in SpliceKitTranscriptPanel.m

extern Class SFSpeechRecognizerClass;
extern Class SFSpeechURLRecognitionRequestClass;
void SpliceKitTranscript_loadSpeechFramework(void);
BOOL SpliceKitTranscript_isSpeakerDiarizationAvailable(void);
NSString *SpliceKitTranscript_timecodeFromSeconds(double seconds, double fps);
extern NSPasteboardType const SpliceKitTranscriptWordDragType;
extern NSString *const FCPAttrItemType;
extern NSString *const FCPAttrWordIndex;
extern NSString *const FCPAttrSilenceIndex;
extern NSString *const FCPAttrSpeakerName;
extern NSString *const FCPAttrSegmentStartIndex;
extern NSString *const FCPAttrSegmentEndIndex;

#pragma GCC visibility pop

// Implemented in SpliceKitTranscriptPanel.m, called from another file.
@interface SpliceKitTranscriptPanel ()
- (void)persistTranscriptStateForCurrentSequence;
- (void)performSearchHighlighting;
- (void)scrollToCurrentSearchResult;
- (void)assignSpeakers;
+ (NSString *)audioProblemForFileAtPath:(NSString *)path;
- (NSDictionary *)deleteTimelineRange:(double)deleteStart end:(double)deleteEnd;
- (void)setPlayheadToTime:(double)seconds;
@end

// Implemented in SpliceKitTranscriptPanel+UI.m, called from another file.
@interface SpliceKitTranscriptPanel (UI)
- (void)setupPanelIfNeeded;
- (void)updateSpeakerCheckboxState;
- (void)rebuildTextView;
- (void)startPlayheadTimer;
- (void)stopPlayheadTimer;
- (void)updateStatusUI:(NSString *)message;
- (void)openSpeechRecognitionSettings;
- (void)setErrorState:(NSString *)error;
@end

// Implemented in SpliceKitTranscriptPanel+Clips.m, called from another file.
@interface SpliceKitTranscriptPanel (Clips)
- (NSArray *)collectClipInfosForSequence:(id)sequence primaryObject:(id)primaryObject errorMessage:(NSString **)errorMessageOut;
- (void)performTimelineTranscription;
- (id)transcriptAssetCandidateForClipInfo:(NSDictionary *)clipInfo assetsSelector:(SEL)assetsSel;
- (NSString *)mediaPathForTranscriptAsset:(id)asset;
@end

// Implemented in SpliceKitTranscriptPanel+Engines.m, called from another file.
@interface SpliceKitTranscriptPanel (Engines)
- (void)requestSpeechAuthorizationWithCompletion:(void(^)(BOOL authorized))completion;
- (void)performFCPNativeTranscription;
- (void)performAppleSpeechTranscription;
- (void)transcribeAudioFile:(NSURL *)audioURL
              timelineStart:(double)timelineStart
                  trimStart:(double)trimStart
               trimDuration:(double)trimDuration
                 clipHandle:(NSString *)clipHandle
                 completion:(void(^)(NSArray<SpliceKitTranscriptWord *> *, NSError *))completion;
@end

// Implemented in SpliceKitTranscriptPanel+Parakeet.m, called from another file.
@interface SpliceKitTranscriptPanel (Parakeet)
- (void)performParakeetTranscription;
- (void)transcribeFileWithParakeet:(NSURL *)audioURL timelineStart:(double)timelineStart generation:(NSUInteger)generation;
@end

// Implemented in SpliceKitTranscriptTextView.m, called from another file.
@interface SpliceKitTranscriptTextView ()
- (void)setupDragTypes;
@end

#endif /* SpliceKitTranscriptPanel_Private_h */
