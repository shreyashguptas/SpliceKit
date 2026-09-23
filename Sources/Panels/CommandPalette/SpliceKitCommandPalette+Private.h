//
//  SpliceKitCommandPalette+Private.h
//  Private declarations shared by SpliceKitCommandPalette.m, its category files
//  (SpliceKitCommandPalette+*.m) and SpliceKitCommandPaletteViews.m: the class extension,
//  the palette view classes, and the category methods called from another file.
//  The functions and variables below were file-static before SpliceKitCommandPalette.m
//  was split. They are declared hidden so they stay out of the dylib's exported symbols.
//

#ifndef SpliceKitCommandPalette_Private_h
#define SpliceKitCommandPalette_Private_h

// The imports SpliceKitCommandPalette.m has always been compiled with.
#import "SpliceKitCommandPalette.h"
#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitURLImport.h"
#import "SpliceKitProcess.h"
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <Speech/Speech.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface SpliceKitCenteredTextFieldCell : NSTextFieldCell
@end

@interface SpliceKitCommandSearchField : NSTextField
@property (nonatomic, weak) NSTableView *targetTableView;
@end

@interface SpliceKitCommandPalettePanel : NSPanel
@end

@interface SpliceKitSiriOrbView : NSView
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, strong) CAGradientLayer *fallbackLayer;
@end

@interface SpliceKitPaletteRowView : NSTableRowView
@property (nonatomic, assign) BOOL separatorRow;
@end

@interface SpliceKitCommandRowView : NSTableCellView
@property (nonatomic, strong) NSView *cardView;
@property (nonatomic, strong) NSView *iconPlate;
@property (nonatomic, strong) NSImageView *iconView;
@property (nonatomic, strong) NSTextField *starLabel;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *detailLabel;
@property (nonatomic, strong) NSTextField *categoryLabel;
@property (nonatomic, strong) NSTextField *shortcutLabel;
@end

@interface FCPSeparatorRowView : NSTableCellView
@end

@interface SpliceKitSuggestionBubbleView : NSVisualEffectView
@property (nonatomic, strong) NSView *iconPlate;
@property (nonatomic, strong) NSImageView *iconView;
@property (nonatomic, strong) NSTextField *titleLabel;
- (void)configureWithCommand:(SpliceKitCommand *)cmd emphasis:(BOOL)emphasis;
@end

@interface SpliceKitLatencyPillView : NSVisualEffectView
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) CAGradientLayer *shimmerLayer;
- (void)configureWithText:(NSString *)text;
@end

@interface SpliceKitResultPlatterView : NSVisualEffectView
@property (nonatomic, strong) NSView *iconPlate;
@property (nonatomic, strong) NSImageView *iconView;
@property (nonatomic, strong) NSTextField *badgeLabel;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *subtitleLabel;
@property (nonatomic, strong) NSTextField *footnoteLabel;
- (void)configureWithTitle:(NSString *)title
                  subtitle:(NSString *)subtitle
                     badge:(NSString *)badge
                  footnote:(NSString *)footnote
                symbolName:(NSString *)symbolName
                    accent:(NSColor *)accent;
@end

typedef NS_ENUM(NSInteger, SpliceKitPalettePresentationState) {
    SpliceKitPalettePresentationStateHidden = 0,
    SpliceKitPalettePresentationStateLatencyPill,
};

@interface SpliceKitCommandPalette () <NSTableViewDelegate, NSTableViewDataSource,
                                  NSTextFieldDelegate, NSWindowDelegate, NSMenuDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSTextField *searchField;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSView *backgroundView;
@property (nonatomic, strong) NSView *searchChromeView;
@property (nonatomic, strong) NSView *heroStageView;
@property (nonatomic, strong) NSStackView *heroSuggestionStackView;
@property (nonatomic, strong) NSStackView *heroContinuerStackView;
@property (nonatomic, strong) SpliceKitLatencyPillView *heroLatencyPillView;
@property (nonatomic, strong) SpliceKitResultPlatterView *heroResultPlatterView;
@property (nonatomic, strong) NSLayoutConstraint *heroStageHeightConstraint;
@property (nonatomic, strong) CAGradientLayer *shellTintLayer;
@property (nonatomic, strong) CAGradientLayer *searchBodyLayer;
@property (nonatomic, strong) CAGradientLayer *searchGlossLayer;
@property (nonatomic, strong) CAGradientLayer *searchEdgeLayer;
@property (nonatomic, strong) SpliceKitSiriOrbView *orbView;
@property (nonatomic, strong) NSButton *dictationButton;
@property (nonatomic, strong) NSTextField *statusLabel;

@property (nonatomic, strong) NSArray<SpliceKitCommand *> *allCommands;
@property (nonatomic, strong) NSArray<SpliceKitCommand *> *masterCommands; // original full list
@property (nonatomic, strong) NSArray<SpliceKitCommand *> *filteredCommands;
@property (nonatomic, strong) NSString *statusError; // shown in the status line (dictation errors)
@property (nonatomic, assign) BOOL inBrowseMode;

@property (nonatomic, strong) id localEventMonitor;

// Favorites
@property (nonatomic, strong) NSMutableSet<NSString *> *favoriteKeys; // "type::action" for O(1) lookup
@property (nonatomic, strong) NSArray<SpliceKitCommand *> *rawBrowseCommands; // pre-injection list

// Live voice dictation
@property (nonatomic, strong) SFSpeechRecognizer *dictationRecognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *dictationRequest;
@property (nonatomic, strong) SFSpeechRecognitionTask *dictationTask;
@property (nonatomic, strong) AVAudioEngine *dictationAudioEngine;
@property (nonatomic, assign) BOOL dictationActive;
@property (nonatomic, strong) NSString *dictationSeedQuery;
@property (nonatomic, assign) SpliceKitPalettePresentationState presentationState;
@property (nonatomic, assign) NSUInteger presentationGeneration;
@property (nonatomic, assign) BOOL commandCommitAnimating;
@property (nonatomic, copy) NSString *heroStageSignature;
@end

#pragma GCC visibility push(hidden)

#pragma mark - Defined in SpliceKitCommandPalette.m

CGFloat FCPFuzzyScore(NSString *query, NSString *target);
extern NSString * const kSpliceKitFavoritesKey;

#pragma mark - Defined in SpliceKitCommandPaletteViews.m

NSColor *FCPPaletteColor(CGFloat r, CGFloat g, CGFloat b, CGFloat a);
NSView *FCPCreateGlassContainerView(NSRect frame, NSVisualEffectMaterial fallbackMaterial, CGFloat cornerRadius);
NSString *FCPCommandSymbolName(SpliceKitCommand *cmd);
NSColor *FCPCommandAccentColor(SpliceKitCommand *cmd);
void FCPSelectSingleTableRow(NSTableView *tableView, NSInteger row);

#pragma mark - Defined in SpliceKitCommandPalette+Registry.m

NSString *FCPFavoriteKey(NSString *type, NSString *action);

#pragma GCC visibility pop

// Implemented in SpliceKitCommandPalette.m, called from another file.
@interface SpliceKitCommandPalette ()
- (void)updateStatusLabel;
- (void)updateHeroStageAnimated:(BOOL)animated;
- (void)refreshSearchResultsForCurrentQuery;
@end

// Implemented in SpliceKitCommandPalette+Registry.m, called from another file.
@interface SpliceKitCommandPalette (Registry)
- (void)registerCommands;
- (void)injectFavoritesIntoCurrentList;
- (NSArray<SpliceKitCommand *> *)searchCommandsInArray:(NSArray<SpliceKitCommand *> *)commands query:(NSString *)query;
- (void)exitBrowseMode;
- (void)enterTransitionBrowseMode;
- (void)enterEffectBrowseMode:(NSString *)effectType;
- (void)enterFavoritesBrowseMode;
@end

// Implemented in SpliceKitCommandPalette+Dictation.m, called from another file.
@interface SpliceKitCommandPalette (Dictation)
- (void)stopDictation;
@end

// Implemented in SpliceKitCommandPalette+Panels.m, called from another file.
@interface SpliceKitCommandPalette (Panels)
- (void)showURLImportPromptWithDefaultMode:(NSString *)defaultMode;
- (void)showSilenceOptionsPanel;
- (void)showSceneDetectionOptionsPanel;
- (void)showBridgeOptionsPanel;
@end

// Implemented in SpliceKitCommandPaletteViews.m, called from another file.
@interface SpliceKitCommandRowView ()
- (void)configureWithCommand:(SpliceKitCommand *)cmd isFavorited:(BOOL)favorited selected:(BOOL)selected;
@end

#endif /* SpliceKitCommandPalette_Private_h */
