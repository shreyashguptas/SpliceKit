//
//  SpliceKitCaptionPanel+Private.h
//  Private declarations shared by SpliceKitCaptionPanel.m and the files split out of it
//  (listed in SOURCES.txt right after it).
//  The functions and variables below were file-static before SpliceKitCaptionPanel.m
//  was split. They are declared hidden so they stay out of the dylib's exported symbols.
//

#ifndef SpliceKitCaptionPanel_Private_h
#define SpliceKitCaptionPanel_Private_h

// The imports SpliceKitCaptionPanel.m has always been compiled with.
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
#import "SpliceKitTime.h"
#import "SpliceKitStrings.h"

@interface SpliceKitCaptionPanel ()
@property (nonatomic, strong) NSTextField *statusLabel;
@end

@interface SpliceKitCaptionPanel () <NSWindowDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) SpliceKitCaptionStyle *style;
@property (nonatomic, strong) NSMutableArray<SpliceKitTranscriptWord *> *mutableWords;
@property (nonatomic, strong) NSMutableArray<SpliceKitCaptionSegment *> *mutableSegments;
@property (nonatomic) SpliceKitCaptionStatus status;
@property (nonatomic, copy) NSString *errorMessage;
@property (nonatomic, strong) NSDictionary *lastGenerateResult;

// UI
@property (nonatomic, strong) NSPopUpButton *presetPopup;
@property (nonatomic, strong) NSPopUpButton *enginePopup;
@property (nonatomic, strong) NSPopUpButton *fontPopup;
@property (nonatomic, strong) NSTextField *fontSizeField;
@property (nonatomic, strong) NSSlider *fontSizeSlider;
@property (nonatomic, strong) NSColorWell *textColorWell;
@property (nonatomic, strong) NSColorWell *highlightColorWell;
@property (nonatomic, strong) NSColorWell *outlineColorWell;
@property (nonatomic, strong) NSSlider *outlineWidthSlider;
@property (nonatomic, strong) NSColorWell *shadowColorWell;
@property (nonatomic, strong) NSSlider *shadowBlurSlider;
@property (nonatomic, strong) NSPopUpButton *positionPopup;
@property (nonatomic, strong) NSPopUpButton *animationPopup;
@property (nonatomic, strong) NSButton *allCapsCheckbox;
@property (nonatomic, strong) NSButton *wordHighlightCheckbox;
@property (nonatomic, strong) NSPopUpButton *groupingPopup;
@property (nonatomic, strong) NSTextField *groupingValueField;
@property (nonatomic, strong) NSView *previewView;
@property (nonatomic, strong) NSTextField *previewLabel;
@property (nonatomic, strong) NSButton *transcribeButton;
@property (nonatomic, strong) NSButton *generateButton;
@property (nonatomic, strong) NSButton *exportSRTButton;
@property (nonatomic, strong) NSButton *exportTXTButton;
@property (nonatomic, strong) NSProgressIndicator *spinner;

// Frame rate info (detected from timeline)
@property (nonatomic) int fdNum;   // frame duration numerator
@property (nonatomic) int fdDen;   // frame duration denominator
@property (nonatomic) double frameRate;
@property (nonatomic) int videoWidth;
@property (nonatomic) int videoHeight;
@property (nonatomic) BOOL suppressPersistenceWrites;
@property (nonatomic, copy) NSString *lastRestoredSequenceKey;
@property (nonatomic, copy) NSString *lastHeadlessRestoredSequenceKey;
@property (nonatomic, copy) NSString *lastHealedSequenceKey;
@property (nonatomic, strong) id automaticRestoreObserver;
@property (nonatomic) NSUInteger automaticRestoreGeneration;
- (double)captionFrameDurationSeconds;
- (NSArray<SpliceKitTranscriptWord *> *)normalizedCaptionWordsFromWords:(NSArray<SpliceKitTranscriptWord *> *)words
                                                                 context:(NSString *)context;
@end

#pragma GCC visibility push(hidden)

#pragma mark - Defined in SpliceKitCaptionPanel.m

extern NSString * const kWP_ContentPositionKey;
extern NSString * const kWP_ContentOpacityKey;
extern NSString * const kWP_CustomSpeedKey;
extern NSString * const kSpliceKitRuntimeCaptionTemplateMatch;
extern NSString * const kSpliceKitCaptionStorylineName;
NSString *SpliceKitLegacyCaptionStorylineName(void);
extern const double kWP_FadeOutDuration;

#pragma mark - Defined in SpliceKitCaptionStyle.m

NSString *SpliceKitCaption_colorToFCPXML(NSColor *color);
NSDictionary *SpliceKitCaption_transcriptWordToDictionary(SpliceKitTranscriptWord *word);
SpliceKitTranscriptWord *SpliceKitCaption_transcriptWordFromDictionary(NSDictionary *dict);

#pragma mark - Defined in SpliceKitCaptionPanel+Timeline.m

NSString *SpliceKitCaption_durRational(double seconds, int fdNum, int fdDen);
BOOL SpliceKitCaption_usesWordHighlightRuntimeStyle(SpliceKitCaptionStyle *style);
NSAttributedString *SpliceKitCaption_makeHighlightedGeneratorAttributedStringFromWords(NSArray<NSString *> *displayWords,
                                                                                       NSUInteger activeWordIndex,
                                                                                       SpliceKitCaptionStyle *style);
BOOL SpliceKitCaption_setGeneratorAttributedTextForPersistedRepair(id generator,
                                                                   NSAttributedString *attr);
BOOL SpliceKitCaption_setGeneratorTextFields(id generator,
                                             NSArray<NSString *> *fields,
                                             BOOL notifyChange);
NSArray *SpliceKitCaption_collectTitlesForPersistedStorylines(id sequence);
BOOL SpliceKitCaption_applyGeneratorPositionYOffset(id titleObject, CGFloat yOffset);
extern NSString *const kCaptionImportProjectPrefix;
NSArray *SpliceKitCaption_allSequences(void);
id SpliceKitCaption_findSequenceByPrefix(NSString *prefix);
id SpliceKitCaption_currentSequence(void);
BOOL SpliceKitCaption_deleteSequence(id sequence);
BOOL SpliceKitCaption_pollMainThread(BOOL (^condition)(void), double timeoutSec, double intervalSec);

#pragma GCC visibility pop

// Implemented in SpliceKitCaptionPanel+UI.m, called from another file.
@interface SpliceKitCaptionPanel (UI)
- (void)setupPanelIfNeeded;
- (void)syncUIFromStyle;
- (NSString *)currentEngineID;
@end

// Implemented in SpliceKitCaptionPanel+Persistence.m, called from another file.
@interface SpliceKitCaptionPanel (Persistence)
- (void)enableAutomaticRestore;
- (NSArray<NSDictionary *> *)runtimeEntriesForStyle:(SpliceKitCaptionStyle *)style;
- (void)ensurePersistedStateLoaded;
- (void)persistCaptionDraftStateForCurrentSequence;
- (void)persistGeneratedCaptionStateWithRuntimeEntries:(NSArray<NSDictionary *> *)runtimeEntries
                                                 style:(SpliceKitCaptionStyle *)style;
- (CGFloat)yOffsetForStyle:(SpliceKitCaptionStyle *)style;
@end

// Implemented in SpliceKitCaptionPanel+Transcription.m, called from another file.
@interface SpliceKitCaptionPanel (Transcription)
- (void)performCaptionTranscription;
@end

// Implemented in SpliceKitCaptionPanel+Timeline.m, called from another file.
@interface SpliceKitCaptionPanel (Timeline)
- (NSDictionary *)addCaptionTitlesDirectlyToTimeline;
@end

// Implemented in SpliceKitCaptionPanel+FCPXML.m, called from another file.
@interface SpliceKitCaptionPanel (FCPXML)
- (void)detectTimelineProperties;
- (NSString *)segmentTitleXMLForSegment:(SpliceKitCaptionSegment *)seg
                              tsCounter:(int *)tsCounter
                                 indent:(NSString *)indent
                                   lane:(NSString *)lane;
- (NSMutableString *)buildFCPXMLHeader:(NSString *)projectName
                          totalDuration:(double)totalDuration
                              titleCount:(int *)outTitleCount
                              tsCounter:(int *)outTsCounter;
- (void)appendFCPXMLFooter:(NSMutableString *)xml;
- (NSString *)buildWordLevelFCPXML;
@end

#endif /* SpliceKitCaptionPanel_Private_h */
