//
//  SpliceKitCommandPalette.m
//  VS Code-style command palette for FCP — Cmd+Shift+P opens it.
//
//  Fuzzy-searches across 100+ registered commands (editing, playback, color,
//  speed, markers, effects, FlexMusic, montage, etc). Type a command name to
//  filter, then press Return to run the selected command.
//
//  The palette floats above FCP as a vibrancy-backed panel with a search field
//  and a table view. It supports favorites (right-click to star), keyboard
//  navigation, and a browse mode when the search field is empty.
//

#import "SpliceKitCommandPalette.h"
#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitURLImport.h"
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <Speech/Speech.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "SpliceKitCommandPalette+Private.h"

#pragma mark - SpliceKitCommand

@implementation SpliceKitCommand
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@/%@>", self.name, self.type, self.action];
}
@end

#pragma mark - Fuzzy Search
//
// Simple fuzzy matcher — walks through the query and target strings in lockstep,
// looking for a subsequence match (every character in the query appears in the
// target in order, but not necessarily adjacent). Scores higher for:
//   - Consecutive matching characters (the "bl" in "blade" beats "b...l...a")
//   - Matches at the start of a word (capital letters, after spaces)
//   - Shorter target strings (exact matches rank above partial ones)
//
// Returns 0 if not all query characters were found.
//

CGFloat FCPFuzzyScore(NSString *query, NSString *target) {
    if (query.length == 0) return 1.0;
    NSString *q = [query lowercaseString];
    NSString *t = [target lowercaseString];

    NSUInteger qi = 0, ti = 0;
    CGFloat score = 0;
    CGFloat consecutiveBonus = 0;
    BOOL lastMatched = NO;

    while (qi < q.length && ti < t.length) {
        unichar qc = [q characterAtIndex:qi];
        unichar tc = [t characterAtIndex:ti];
        if (qc == tc) {
            score += 1.0;
            if (lastMatched) {
                consecutiveBonus += 0.5;
            }
            // Word-boundary matches are worth more — "cb" matching "Color Board" should score high
            if (ti == 0 || [t characterAtIndex:ti - 1] == ' ' ||
                ([t characterAtIndex:ti - 1] >= 'a' && tc >= 'A' && tc <= 'Z')) {
                score += 0.3;
            }
            lastMatched = YES;
            qi++;
        } else {
            lastMatched = NO;
        }
        ti++;
    }

    if (qi < q.length) return 0;

    score += consecutiveBonus;
    CGFloat normalized = score / (CGFloat)q.length;
    CGFloat lengthPenalty = 1.0 - ((CGFloat)(t.length - q.length) / (CGFloat)(t.length + 10));
    return normalized * lengthPenalty;
}

#pragma mark - SpliceKitCommandPalette

static NSString * const kCommandRowID = @"SpliceKitCommandRow";

NSString * const kSpliceKitFavoritesKey = @"SpliceKitCommandPaletteFavorites";
static NSString * const kSeparatorRowID = @"FCPSeparatorRow";

@implementation SpliceKitCommandPalette

+ (instancetype)sharedPalette {
    static SpliceKitCommandPalette *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self registerCommands];
        _filteredCommands = _allCommands;
        [self loadFavorites];
    }
    return self;
}

#pragma mark - Panel UI
//
// Builds the floating panel lazily on first show. The panel uses a
// vibrancy background (NSVisualEffectMaterialMenu) to match macOS system
// panels, with a rounded-corner mask for that modern look.
//

- (void)buildPanelIfNeeded {
    if (self.panel) return;

    CGFloat width = 820;
    CGFloat height = 430;
    NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
    CGFloat x = NSMidX(screenFrame) - width / 2;
    CGFloat y = NSMidY(screenFrame) + 36;
    NSRect frame = NSMakeRect(x, y, width, height);

    SpliceKitCommandPalettePanel *panel = [[SpliceKitCommandPalettePanel alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskFullSizeContentView)
        backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"SpliceKit Command Palette";
    panel.opaque = NO;
    panel.movableByWindowBackground = YES;
    panel.level = NSFloatingWindowLevel;
    panel.floatingPanel = YES;
    panel.becomesKeyOnlyIfNeeded = NO;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;
    panel.hasShadow = YES;
    panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
                               NSWindowCollectionBehaviorTransient |
                               NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.delegate = self;
    panel.minSize = NSMakeSize(720, 360);
    panel.maxSize = NSMakeSize(920, 720);
    panel.backgroundColor = [NSColor clearColor];
    panel.animationBehavior = NSWindowAnimationBehaviorUtilityWindow;
    panel.contentView.wantsLayer = YES;
    panel.contentView.layer.backgroundColor = NSColor.clearColor.CGColor;

    NSView *bg = FCPCreateGlassContainerView(panel.contentView.bounds, NSVisualEffectMaterialHUDWindow, 30.0);
    bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    bg.layer.borderWidth = 1.0;
    bg.layer.borderColor = FCPPaletteColor(1.0, 1.0, 1.0, 0.10).CGColor;
    bg.layer.backgroundColor = FCPPaletteColor(0.02, 0.03, 0.06, 0.075).CGColor;
    bg.layer.shadowColor = NSColor.blackColor.CGColor;
    bg.layer.shadowOpacity = 0.14;
    bg.layer.shadowRadius = 24.0;
    bg.layer.shadowOffset = CGSizeMake(0.0, -6.0);
    [panel.contentView addSubview:bg];
    self.backgroundView = bg;

    CAGradientLayer *shellTint = [CAGradientLayer layer];
    shellTint.frame = bg.bounds;
    shellTint.colors = @[
        (__bridge id)FCPPaletteColor(0.20, 0.24, 0.40, 0.085).CGColor,
        (__bridge id)FCPPaletteColor(0.10, 0.12, 0.20, 0.048).CGColor,
        (__bridge id)FCPPaletteColor(0.05, 0.06, 0.10, 0.024).CGColor
    ];
    shellTint.startPoint = CGPointMake(0.0, 1.0);
    shellTint.endPoint = CGPointMake(1.0, 0.0);
    shellTint.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [bg.layer addSublayer:shellTint];
    self.shellTintLayer = shellTint;

    NSView *searchChrome = FCPCreateGlassContainerView(NSZeroRect, NSVisualEffectMaterialMenu, 24.0);
    searchChrome.layer.borderWidth = 1.0;
    searchChrome.layer.borderColor = FCPPaletteColor(1.0, 1.0, 1.0, 0.12).CGColor;
    searchChrome.layer.backgroundColor = FCPPaletteColor(0.10, 0.12, 0.22, 0.075).CGColor;
    searchChrome.layer.shadowColor = NSColor.blackColor.CGColor;
    searchChrome.layer.shadowOpacity = 0.08;
    searchChrome.layer.shadowRadius = 14.0;
    searchChrome.layer.shadowOffset = CGSizeMake(0.0, -8.0);
    searchChrome.translatesAutoresizingMaskIntoConstraints = NO;
    [bg addSubview:searchChrome];
    self.searchChromeView = searchChrome;

    CAGradientLayer *searchBody = [CAGradientLayer layer];
    searchBody.frame = CGRectMake(0.0, 0.0, width - 36.0, 58.0);
    searchBody.colors = @[
        (__bridge id)FCPPaletteColor(0.26, 0.31, 0.54, 0.10).CGColor,
        (__bridge id)FCPPaletteColor(0.15, 0.18, 0.31, 0.055).CGColor,
        (__bridge id)FCPPaletteColor(0.09, 0.11, 0.18, 0.028).CGColor
    ];
    searchBody.startPoint = CGPointMake(0.0, 1.0);
    searchBody.endPoint = CGPointMake(1.0, 0.0);
    searchBody.cornerRadius = 24.0;
    searchBody.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [searchChrome.layer insertSublayer:searchBody atIndex:0];
    self.searchBodyLayer = searchBody;

    CAGradientLayer *searchGloss = [CAGradientLayer layer];
    searchGloss.frame = CGRectMake(1.0, 1.0, width - 38.0, 24.0);
    searchGloss.colors = @[
        (__bridge id)FCPPaletteColor(1.0, 1.0, 1.0, 0.18).CGColor,
        (__bridge id)FCPPaletteColor(0.84, 0.90, 1.0, 0.06).CGColor,
        (__bridge id)FCPPaletteColor(1.0, 1.0, 1.0, 0.0).CGColor
    ];
    searchGloss.startPoint = CGPointMake(0.0, 1.0);
    searchGloss.endPoint = CGPointMake(1.0, 0.0);
    searchGloss.cornerRadius = 22.0;
    searchGloss.autoresizingMask = kCALayerWidthSizable;
    [searchChrome.layer addSublayer:searchGloss];
    self.searchGlossLayer = searchGloss;

    CABasicAnimation *glossDrift = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    glossDrift.fromValue = @(-18.0);
    glossDrift.toValue = @(28.0);
    glossDrift.duration = 5.8;
    glossDrift.autoreverses = YES;
    glossDrift.repeatCount = HUGE_VALF;
    glossDrift.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [searchGloss addAnimation:glossDrift forKey:@"glossDrift"];

    CAGradientLayer *searchEdge = [CAGradientLayer layer];
    searchEdge.frame = CGRectMake(0.0, 0.0, width - 36.0, 58.0);
    searchEdge.colors = @[
        (__bridge id)FCPPaletteColor(0.74, 0.82, 1.0, 0.12).CGColor,
        (__bridge id)FCPPaletteColor(1.0, 1.0, 1.0, 0.02).CGColor,
        (__bridge id)FCPPaletteColor(0.42, 0.52, 0.96, 0.06).CGColor
    ];
    searchEdge.startPoint = CGPointMake(0.0, 0.5);
    searchEdge.endPoint = CGPointMake(1.0, 0.5);
    searchEdge.cornerRadius = 24.0;
    searchEdge.borderWidth = 1.0;
    searchEdge.borderColor = FCPPaletteColor(1.0, 1.0, 1.0, 0.10).CGColor;
    searchEdge.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [searchChrome.layer addSublayer:searchEdge];
    self.searchEdgeLayer = searchEdge;

    SpliceKitSiriOrbView *orbView = [[SpliceKitSiriOrbView alloc] initWithFrame:NSZeroRect];
    orbView.translatesAutoresizingMaskIntoConstraints = NO;
    [searchChrome addSubview:orbView];
    self.orbView = orbView;

    SpliceKitCommandSearchField *searchField = [[SpliceKitCommandSearchField alloc] initWithFrame:NSZeroRect];
    searchField.placeholderAttributedString = [[NSAttributedString alloc] initWithString:@"Type a command"
                                                                              attributes:@{
        NSForegroundColorAttributeName: FCPPaletteColor(0.92, 0.95, 1.0, 0.42),
        NSFontAttributeName: [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold]
    }];
    searchField.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
    searchField.textColor = FCPPaletteColor(0.97, 0.98, 1.0, 0.95);
    searchField.bordered = NO;
    searchField.focusRingType = NSFocusRingTypeNone;
    searchField.drawsBackground = NO;
    searchField.translatesAutoresizingMaskIntoConstraints = NO;
    searchField.delegate = self;
    [searchChrome addSubview:searchField];
    self.searchField = searchField;

    NSButton *dictationButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"mic.fill"
                                                                          accessibilityDescription:@"Voice dictation"]
                                                   target:self
                                                   action:@selector(toggleDictation:)];
    dictationButton.bordered = NO;
    dictationButton.buttonType = NSButtonTypeMomentaryPushIn;
    dictationButton.translatesAutoresizingMaskIntoConstraints = NO;
    dictationButton.contentTintColor = FCPPaletteColor(0.96, 0.97, 1.0, 0.68);
    dictationButton.wantsLayer = YES;
    dictationButton.layer.cornerRadius = 18.0;
    dictationButton.layer.masksToBounds = YES;
    dictationButton.layer.backgroundColor = FCPPaletteColor(1.0, 1.0, 1.0, 0.03).CGColor;
    dictationButton.layer.borderWidth = 1.0;
    dictationButton.layer.borderColor = FCPPaletteColor(1.0, 1.0, 1.0, 0.12).CGColor;
    dictationButton.toolTip = @"Start Siri-style voice dictation";
    [searchChrome addSubview:dictationButton];
    self.dictationButton = dictationButton;

    NSView *heroStage = [[NSView alloc] initWithFrame:NSZeroRect];
    heroStage.translatesAutoresizingMaskIntoConstraints = NO;
    heroStage.wantsLayer = YES;
    heroStage.layer.backgroundColor = NSColor.clearColor.CGColor;
    [bg addSubview:heroStage];
    self.heroStageView = heroStage;
    NSLayoutConstraint *heroStageHeightConstraint = [heroStage.heightAnchor constraintEqualToConstant:60.0];
    self.heroStageHeightConstraint = heroStageHeightConstraint;

    NSStackView *suggestionStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    suggestionStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    suggestionStack.alignment = NSLayoutAttributeCenterY;
    suggestionStack.distribution = NSStackViewDistributionFillEqually;
    suggestionStack.spacing = 12.0;
    suggestionStack.translatesAutoresizingMaskIntoConstraints = NO;
    suggestionStack.hidden = YES;
    suggestionStack.alphaValue = 0.0;
    [heroStage addSubview:suggestionStack];
    self.heroSuggestionStackView = suggestionStack;

    SpliceKitLatencyPillView *latencyPill = [[SpliceKitLatencyPillView alloc] initWithFrame:NSZeroRect];
    latencyPill.hidden = YES;
    latencyPill.alphaValue = 0.0;
    [heroStage addSubview:latencyPill];
    self.heroLatencyPillView = latencyPill;

    SpliceKitResultPlatterView *resultPlatter = [[SpliceKitResultPlatterView alloc] initWithFrame:NSZeroRect];
    resultPlatter.hidden = YES;
    resultPlatter.alphaValue = 0.0;
    [heroStage addSubview:resultPlatter];
    self.heroResultPlatterView = resultPlatter;

    NSStackView *continuerStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    continuerStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    continuerStack.alignment = NSLayoutAttributeCenterY;
    continuerStack.distribution = NSStackViewDistributionFillEqually;
    continuerStack.spacing = 12.0;
    continuerStack.translatesAutoresizingMaskIntoConstraints = NO;
    continuerStack.hidden = YES;
    continuerStack.alphaValue = 0.0;
    [heroStage addSubview:continuerStack];
    self.heroContinuerStackView = continuerStack;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    column.resizingMask = NSTableColumnAutoresizingMask;

    NSTableView *tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    [tableView addTableColumn:column];
    tableView.headerView = nil;
    tableView.rowHeight = 62.0;
    tableView.intercellSpacing = NSMakeSize(0.0, 0.0);
    tableView.backgroundColor = [NSColor clearColor];
    tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    tableView.allowsMultipleSelection = NO;
    tableView.allowsEmptySelection = NO;
    tableView.usesAlternatingRowBackgroundColors = NO;
    tableView.delegate = self;
    tableView.dataSource = self;
    tableView.doubleAction = @selector(executeSelectedCommand:);
    tableView.target = self;

    // Context menu for right-click favorites
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@""];
    contextMenu.delegate = self;
    tableView.menu = contextMenu;

    self.tableView = tableView;
    searchField.targetTableView = tableView;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = tableView;
    scroll.hasVerticalScroller = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.drawsBackground = NO;
    scroll.wantsLayer = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [bg addSubview:scroll];
    self.scrollView = scroll;

    NSTextField *statusLabel = [NSTextField labelWithString:@""];
    statusLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    statusLabel.textColor = FCPPaletteColor(0.88, 0.92, 0.99, 0.56);
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    statusLabel.alignment = NSTextAlignmentLeft;
    [bg addSubview:statusLabel];
    self.statusLabel = statusLabel;

    [NSLayoutConstraint activateConstraints:@[
        [searchChrome.topAnchor constraintEqualToAnchor:bg.topAnchor constant:18.0],
        [searchChrome.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor constant:18.0],
        [searchChrome.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor constant:-18.0],
        [searchChrome.heightAnchor constraintEqualToConstant:58.0],

        [orbView.leadingAnchor constraintEqualToAnchor:searchChrome.leadingAnchor constant:14.0],
        [orbView.centerYAnchor constraintEqualToAnchor:searchChrome.centerYAnchor],
        [orbView.widthAnchor constraintEqualToConstant:28.0],
        [orbView.heightAnchor constraintEqualToConstant:28.0],

        [dictationButton.trailingAnchor constraintEqualToAnchor:searchChrome.trailingAnchor constant:-14.0],
        [dictationButton.centerYAnchor constraintEqualToAnchor:searchChrome.centerYAnchor],
        [dictationButton.widthAnchor constraintEqualToConstant:36.0],
        [dictationButton.heightAnchor constraintEqualToConstant:36.0],

        [searchField.leadingAnchor constraintEqualToAnchor:orbView.trailingAnchor constant:20.0],
        [searchField.trailingAnchor constraintEqualToAnchor:dictationButton.leadingAnchor constant:-12.0],
        [searchField.topAnchor constraintEqualToAnchor:searchChrome.topAnchor constant:12.0],
        [searchField.bottomAnchor constraintEqualToAnchor:searchChrome.bottomAnchor constant:-6.0],

        [heroStage.topAnchor constraintEqualToAnchor:searchChrome.bottomAnchor constant:8.0],
        [heroStage.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor constant:18.0],
        [heroStage.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor constant:-18.0],
        heroStageHeightConstraint,

        [suggestionStack.leadingAnchor constraintEqualToAnchor:heroStage.leadingAnchor],
        [suggestionStack.trailingAnchor constraintEqualToAnchor:heroStage.trailingAnchor],
        [suggestionStack.topAnchor constraintEqualToAnchor:heroStage.topAnchor constant:4.0],
        [suggestionStack.heightAnchor constraintEqualToConstant:52.0],

        [latencyPill.centerXAnchor constraintEqualToAnchor:heroStage.centerXAnchor],
        [latencyPill.centerYAnchor constraintEqualToAnchor:heroStage.centerYAnchor],
        [latencyPill.widthAnchor constraintLessThanOrEqualToConstant:360.0],
        [latencyPill.widthAnchor constraintGreaterThanOrEqualToConstant:180.0],
        [latencyPill.heightAnchor constraintEqualToConstant:44.0],

        [resultPlatter.leadingAnchor constraintEqualToAnchor:heroStage.leadingAnchor],
        [resultPlatter.trailingAnchor constraintEqualToAnchor:heroStage.trailingAnchor],
        [resultPlatter.topAnchor constraintEqualToAnchor:heroStage.topAnchor constant:2.0],
        [resultPlatter.heightAnchor constraintEqualToConstant:88.0],

        [continuerStack.leadingAnchor constraintEqualToAnchor:heroStage.leadingAnchor],
        [continuerStack.trailingAnchor constraintEqualToAnchor:heroStage.trailingAnchor],
        [continuerStack.topAnchor constraintEqualToAnchor:resultPlatter.bottomAnchor constant:10.0],
        [continuerStack.heightAnchor constraintEqualToConstant:44.0],

        [scroll.topAnchor constraintEqualToAnchor:heroStage.bottomAnchor constant:8.0],
        [scroll.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor constant:6.0],
        [scroll.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor constant:-6.0],
        [scroll.bottomAnchor constraintEqualToAnchor:statusLabel.topAnchor constant:-10.0],

        [statusLabel.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor constant:22.0],
        [statusLabel.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor constant:-18.0],
        [statusLabel.bottomAnchor constraintEqualToAnchor:bg.bottomAnchor constant:-14.0],
        [statusLabel.heightAnchor constraintEqualToConstant:18.0],
    ]];

    self.panel = panel;
    [self updateStatusLabel];
    [self updatePaletteChromeAnimated:NO];
}

- (void)updateStatusLabel {
    NSUInteger count = self.filteredCommands.count;
    NSString *text = [NSString stringWithFormat:@"%lu command%@ ready  |  Return executes",
                      (unsigned long)count, count == 1 ? @"" : @"s"];
    if (self.dictationActive) {
        text = @"Listening... Speak a command name to search.";
    } else if (self.statusError) {
        text = self.statusError;
    } else if (self.searchField.stringValue.length == 0 && !self.inBrowseMode) {
        text = @"Return executes  |  Mic starts dictation";
    }
    self.statusLabel.stringValue = text;
    [self updatePaletteChromeAnimated:YES];
}

- (void)updatePaletteChromeAnimated:(BOOL)animated {
    if (!self.searchChromeView || !self.dictationButton) return;

    NSColor *border = self.dictationActive
        ? FCPPaletteColor(0.58, 0.80, 1.0, 0.34)
        : FCPPaletteColor(1.0, 1.0, 1.0, 0.18);
    NSColor *background = self.dictationActive
        ? FCPPaletteColor(0.20, 0.25, 0.40, 0.12)
        : FCPPaletteColor(0.10, 0.12, 0.22, 0.065);

    self.searchChromeView.layer.borderColor = border.CGColor;
    self.searchChromeView.layer.backgroundColor = background.CGColor;
    self.searchChromeView.layer.shadowOpacity = self.dictationActive ? 0.20 : 0.12;

    NSArray *bodyColors = self.dictationActive
        ? @[
            (__bridge id)FCPPaletteColor(0.28, 0.37, 0.62, 0.14).CGColor,
            (__bridge id)FCPPaletteColor(0.16, 0.22, 0.40, 0.075).CGColor,
            (__bridge id)FCPPaletteColor(0.10, 0.13, 0.24, 0.04).CGColor
        ]
        : @[
            (__bridge id)FCPPaletteColor(0.26, 0.31, 0.54, 0.10).CGColor,
            (__bridge id)FCPPaletteColor(0.15, 0.18, 0.31, 0.055).CGColor,
            (__bridge id)FCPPaletteColor(0.09, 0.11, 0.18, 0.028).CGColor
        ];
    self.searchBodyLayer.colors = bodyColors;
    self.searchEdgeLayer.borderColor = border.CGColor;
    self.searchGlossLayer.opacity = self.dictationActive ? 0.78 : 0.56;
    self.shellTintLayer.opacity = self.dictationActive ? 0.45 : 0.28;

    NSString *symbolName = self.dictationActive ? @"stop.fill" : @"mic.fill";
    self.dictationButton.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:@"Voice dictation"];
    self.dictationButton.contentTintColor = self.dictationActive
        ? FCPPaletteColor(0.96, 0.98, 1.0, 0.96)
        : FCPPaletteColor(0.96, 0.97, 1.0, 0.68);
    self.dictationButton.layer.backgroundColor = self.dictationActive
        ? FCPPaletteColor(0.42, 0.61, 0.98, 0.20).CGColor
        : FCPPaletteColor(1.0, 1.0, 1.0, 0.03).CGColor;
    self.dictationButton.layer.borderColor = self.dictationActive
        ? FCPPaletteColor(0.70, 0.84, 1.0, 0.30).CGColor
        : FCPPaletteColor(1.0, 1.0, 1.0, 0.12).CGColor;

    if (self.dictationActive && ![self.dictationButton.layer animationForKey:@"pulse"]) {
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        pulse.fromValue = @1.0;
        pulse.toValue = @1.08;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VALF;
        pulse.duration = 0.85;
        pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [self.dictationButton.layer addAnimation:pulse forKey:@"pulse"];
    } else if (!self.dictationActive) {
        [self.dictationButton.layer removeAnimationForKey:@"pulse"];
    }
}

- (NSArray<SpliceKitCommand *> *)continuerCommandsForCommand:(SpliceKitCommand *)command limit:(NSUInteger)limit {
    NSMutableArray<SpliceKitCommand *> *results = [NSMutableArray array];
    if (!command) return results;
    for (SpliceKitCommand *candidate in self.masterCommands) {
        if (candidate == command || candidate.isSeparatorRow) continue;
        if (candidate.category == command.category) {
            [results addObject:candidate];
            if (results.count >= limit) break;
        }
    }
    return results;
}

- (void)clearBubbleStack:(NSStackView *)stack {
    NSArray<NSView *> *views = stack.arrangedSubviews.copy;
    for (NSView *view in views) {
        [stack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
}

- (void)populateBubbleStack:(NSStackView *)stack
               withCommands:(NSArray<SpliceKitCommand *> *)commands
                   animated:(BOOL)animated
                   emphasis:(BOOL)emphasis {
    [self clearBubbleStack:stack];
    for (NSUInteger idx = 0; idx < commands.count; idx++) {
        SpliceKitSuggestionBubbleView *bubble = [[SpliceKitSuggestionBubbleView alloc] initWithFrame:NSZeroRect];
        [bubble configureWithCommand:commands[idx] emphasis:(emphasis && idx == 0)];
        [stack addArrangedSubview:bubble];
        [bubble.heightAnchor constraintEqualToConstant:48.0].active = YES;
        if (animated) {
            bubble.alphaValue = 0.0;
            bubble.hidden = NO;
            bubble.wantsLayer = YES;
            bubble.layer.transform = CATransform3DMakeTranslation(0.0, 10.0, 0.0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * idx * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                    context.duration = 0.22;
                    context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
                    bubble.animator.alphaValue = 1.0;
                } completionHandler:nil];
                [CATransaction begin];
                [CATransaction setAnimationDuration:0.26];
                bubble.layer.transform = CATransform3DIdentity;
                [CATransaction commit];
            });
        }
    }
}

- (void)animatePresentationView:(NSView *)view
                        visible:(BOOL)visible
                       animated:(BOOL)animated
                          delay:(NSTimeInterval)delay
                        yOffset:(CGFloat)yOffset
                          scale:(CGFloat)scale {
    if (!view) return;
    view.wantsLayer = YES;
    if (!animated) {
        view.hidden = !visible;
        view.alphaValue = visible ? 1.0 : 0.0;
        view.layer.transform = CATransform3DIdentity;
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (visible) {
            view.hidden = NO;
            view.alphaValue = 0.0;
            view.layer.transform = CATransform3DConcat(CATransform3DMakeTranslation(0.0, yOffset, 0.0),
                                                       CATransform3DMakeScale(scale, scale, 1.0));
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.22;
                context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
                view.animator.alphaValue = 1.0;
            } completionHandler:nil];
            [CATransaction begin];
            [CATransaction setAnimationDuration:0.28];
            [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
            view.layer.transform = CATransform3DIdentity;
            [CATransaction commit];
        } else if (!view.hidden) {
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.14;
                context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
                view.animator.alphaValue = 0.0;
            } completionHandler:^{
                view.hidden = YES;
            }];
            [CATransaction begin];
            [CATransaction setAnimationDuration:0.16];
            [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn]];
            view.layer.transform = CATransform3DConcat(CATransform3DMakeTranslation(0.0, yOffset, 0.0),
                                                       CATransform3DMakeScale(scale, scale, 1.0));
            [CATransaction commit];
        }
    });
}

- (void)updateHeroStageAnimated:(BOOL)animated {
    if (!self.heroStageView || self.commandCommitAnimating) return;

    NSString *query = [self.searchField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // The latency pill shows what dictation hears; otherwise the hero stage is collapsed.
    SpliceKitPalettePresentationState targetState = self.dictationActive
        ? SpliceKitPalettePresentationStateLatencyPill
        : SpliceKitPalettePresentationStateHidden;
    NSString *latencyText = @"";

    self.presentationState = targetState;

    CGFloat scrollAlpha = 1.0;
    CGFloat heroStageHeight = 0.0;
    switch (targetState) {
        case SpliceKitPalettePresentationStateHidden: {
            [self animatePresentationView:self.heroSuggestionStackView visible:NO animated:animated delay:0.0 yOffset:-8.0 scale:0.97];
            [self animatePresentationView:self.heroLatencyPillView visible:NO animated:animated delay:0.0 yOffset:-8.0 scale:0.96];
            [self animatePresentationView:self.heroResultPlatterView visible:NO animated:animated delay:0.0 yOffset:-10.0 scale:0.96];
            [self animatePresentationView:self.heroContinuerStackView visible:NO animated:animated delay:0.0 yOffset:6.0 scale:0.98];
            scrollAlpha = 1.0;
            break;
        }
        case SpliceKitPalettePresentationStateLatencyPill: {
            heroStageHeight = 72.0;
            latencyText = query.length > 0 ? query : @"Listening...";
            [self animatePresentationView:self.heroSuggestionStackView visible:NO animated:animated delay:0.0 yOffset:-8.0 scale:0.97];
            [self animatePresentationView:self.heroResultPlatterView visible:NO animated:animated delay:0.0 yOffset:-8.0 scale:0.95];
            [self animatePresentationView:self.heroContinuerStackView visible:NO animated:animated delay:0.0 yOffset:8.0 scale:0.98];
            [self animatePresentationView:self.heroLatencyPillView visible:YES animated:animated delay:0.02 yOffset:12.0 scale:0.94];
            scrollAlpha = 0.74;
            break;
        }
        default:
            break;
    }

    NSString *signature = [NSString stringWithFormat:@"%ld|%@|%@|%.3f",
                           (long)targetState, query, latencyText, scrollAlpha];
    if ([self.heroStageSignature isEqualToString:signature]) {
        if (!animated) {
            self.scrollView.alphaValue = scrollAlpha;
        }
        return;
    }
    self.heroStageSignature = signature;

    [self clearBubbleStack:self.heroSuggestionStackView];
    [self clearBubbleStack:self.heroContinuerStackView];
    if (latencyText.length > 0) {
        [self.heroLatencyPillView configureWithText:latencyText];
    }

    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.20;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            self.heroStageHeightConstraint.animator.constant = heroStageHeight;
        } completionHandler:nil];
    } else {
        self.heroStageHeightConstraint.constant = heroStageHeight;
    }

    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.18;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            self.scrollView.animator.alphaValue = scrollAlpha;
        } completionHandler:nil];
    } else {
        self.scrollView.alphaValue = scrollAlpha;
    }
}

- (void)performAnimatedExecutionForCommand:(SpliceKitCommand *)cmd {
    if (!cmd || self.commandCommitAnimating) return;

    self.commandCommitAnimating = YES;
    self.presentationGeneration += 1;
    NSUInteger generation = self.presentationGeneration;
    self.searchField.stringValue = cmd.name ?: @"";
    [self.heroLatencyPillView configureWithText:cmd.name ?: @"Working..."];
    [self animatePresentationView:self.heroSuggestionStackView visible:NO animated:YES delay:0.0 yOffset:-8.0 scale:0.97];
    [self animatePresentationView:self.heroContinuerStackView visible:NO animated:YES delay:0.0 yOffset:8.0 scale:0.98];
    [self animatePresentationView:self.heroResultPlatterView visible:NO animated:YES delay:0.0 yOffset:-8.0 scale:0.95];
    [self animatePresentationView:self.heroLatencyPillView visible:YES animated:YES delay:0.0 yOffset:12.0 scale:0.94];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.16;
        self.scrollView.animator.alphaValue = 0.70;
    } completionHandler:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.presentationGeneration) return;
        NSArray<SpliceKitCommand *> *continuer = [self continuerCommandsForCommand:cmd limit:3];
        [self.heroResultPlatterView configureWithTitle:(cmd.name ?: @"Ready")
                                              subtitle:(cmd.detail ?: @"Command prepared.")
                                                 badge:(cmd.categoryName ?: @"Command")
                                              footnote:@"Executing now"
                                            symbolName:FCPCommandSymbolName(cmd)
                                                accent:FCPCommandAccentColor(cmd)];
        [self populateBubbleStack:self.heroContinuerStackView withCommands:continuer animated:YES emphasis:YES];
        [self animatePresentationView:self.heroLatencyPillView visible:NO animated:YES delay:0.0 yOffset:-10.0 scale:0.92];
        [self animatePresentationView:self.heroResultPlatterView visible:YES animated:YES delay:0.0 yOffset:10.0 scale:0.95];
        [self animatePresentationView:self.heroContinuerStackView visible:YES animated:YES delay:0.06 yOffset:8.0 scale:0.98];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.64 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.presentationGeneration) return;
        self.commandCommitAnimating = NO;
        [self hidePalette];
        [self executeCommand:cmd.action type:cmd.type];
    });
}

- (void)animateResultsRefresh {
    if (!self.scrollView) return;
    self.scrollView.alphaValue = 0.88;
    self.scrollView.layer.transform = CATransform3DMakeTranslation(0.0, -4.0, 0.0);
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.18;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        self.scrollView.animator.alphaValue = 1.0;
    } completionHandler:nil];
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.18];
    self.scrollView.layer.transform = CATransform3DIdentity;
    [CATransaction commit];
}

- (void)animatePaletteShow {
    self.panel.alphaValue = 0.0;
    self.backgroundView.layer.transform = CATransform3DMakeScale(0.985, 0.985, 1.0);
    [self.panel makeKeyAndOrderFront:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.16;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        self.panel.animator.alphaValue = 1.0;
    } completionHandler:nil];
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.20];
    self.backgroundView.layer.transform = CATransform3DIdentity;
    [CATransaction commit];
}

- (void)animatePaletteHideWithCompletion:(dispatch_block_t)completion {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.12;
        self.panel.animator.alphaValue = 0.0;
    } completionHandler:^{
        if (completion) completion();
    }];
}

#pragma mark - Show / Hide

- (void)showPalette {
    [self buildPanelIfNeeded];
    self.searchField.stringValue = @"";
    self.searchField.placeholderAttributedString = [[NSAttributedString alloc] initWithString:@"Type a command"
                                                                                  attributes:@{
        NSForegroundColorAttributeName: FCPPaletteColor(0.92, 0.95, 1.0, 0.42),
        NSFontAttributeName: [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold]
    }];
    self.inBrowseMode = NO;
    self.allCommands = self.masterCommands;
    self.filteredCommands = self.allCommands;
    self.statusError = nil;
    self.commandCommitAnimating = NO;
    self.heroStageSignature = nil;
    self.presentationGeneration += 1;
    [self.tableView reloadData];
    [self updateStatusLabel];

    // Restore saved position, or center on active screen
    NSString *savedFrame = [[NSUserDefaults standardUserDefaults] stringForKey:@"SpliceKitCommandPaletteFrame"];
    if (savedFrame) {
        [self.panel setFrameFromString:savedFrame];
    } else {
        NSScreen *screen = [NSScreen mainScreen];
        for (NSWindow *w in [NSApp windows]) {
            if (w.isMainWindow && w.screen) { screen = w.screen; break; }
        }
        CGFloat x = NSMidX(screen.visibleFrame) - self.panel.frame.size.width / 2;
        CGFloat y = NSMidY(screen.visibleFrame) + 60;
        [self.panel setFrameOrigin:NSMakePoint(x, y)];
    }

    [self updatePaletteChromeAnimated:NO];
    [self updateHeroStageAnimated:NO];
    [self animatePaletteShow];
    [self.panel makeFirstResponder:self.searchField];

    // Select first row
    if (self.filteredCommands.count > 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                    byExtendingSelection:NO];
    }

    if (!self.localEventMonitor) {
        __weak typeof(self) weakSelf = self;
        self.localEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
            handler:^NSEvent *(NSEvent *event) {
                if (!weakSelf.panel.isVisible) return event;

                // Escape -> stop dictation, go back to main if in browse mode, else close
                if (event.keyCode == 53) {
                    if (weakSelf.dictationActive) {
                        [weakSelf stopDictation];
                    } else if (weakSelf.inBrowseMode) {
                        [weakSelf exitBrowseMode];
                    } else {
                        [weakSelf hidePalette];
                    }
                    return nil;
                }
                // Return -> execute
                if (event.keyCode == 36) {
                    [weakSelf executeSelectedCommand:nil];
                    return nil;
                }
                // Up/Down arrow -> navigate table (skip separator rows)
                if (event.keyCode == 126) { // Up
                    NSInteger row = weakSelf.tableView.selectedRow;
                    if (row > 0) {
                        NSInteger newRow = row - 1;
                        SpliceKitCommand *cmd = [weakSelf commandForDisplayRow:newRow];
                        if (cmd && cmd.isSeparatorRow && newRow > 0) newRow--;
                        FCPSelectSingleTableRow(weakSelf.tableView, newRow);
                    }
                    return nil;
                }
                if (event.keyCode == 125) { // Down
                    NSInteger row = weakSelf.tableView.selectedRow;
                    NSInteger max = weakSelf.tableView.numberOfRows - 1;
                    if (row < max) {
                        NSInteger newRow = row + 1;
                        SpliceKitCommand *cmd = [weakSelf commandForDisplayRow:newRow];
                        if (cmd && cmd.isSeparatorRow && newRow < max) newRow++;
                        FCPSelectSingleTableRow(weakSelf.tableView, newRow);
                    }
                    return nil;
                }
                return event;
            }];
    }
}

- (void)hidePalette {
    [[NSUserDefaults standardUserDefaults] setObject:[self.panel stringWithSavedFrame]
                                              forKey:@"SpliceKitCommandPaletteFrame"];
    self.presentationGeneration += 1;
    self.commandCommitAnimating = NO;
    [self stopDictation];
    [self animatePaletteHideWithCompletion:^{
        [self.panel orderOut:nil];
        if (self.localEventMonitor) {
            [NSEvent removeMonitor:self.localEventMonitor];
            self.localEventMonitor = nil;
        }
    }];
}

- (void)togglePalette {
    if ([self isVisible]) {
        [self hidePalette];
    } else {
        [self showPalette];
    }
}

- (BOOL)isVisible {
    return self.panel.isVisible;
}

#pragma mark - NSWindowDelegate

- (void)windowWillClose:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] setObject:[self.panel stringWithSavedFrame]
                                              forKey:@"SpliceKitCommandPaletteFrame"];
    [self stopDictation];
    if (self.localEventMonitor) {
        [NSEvent removeMonitor:self.localEventMonitor];
        self.localEventMonitor = nil;
    }
}

- (void)windowDidMove:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] setObject:[self.panel stringWithSavedFrame]
                                              forKey:@"SpliceKitCommandPaletteFrame"];
}

- (void)windowDidResize:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] setObject:[self.panel stringWithSavedFrame]
                                              forKey:@"SpliceKitCommandPaletteFrame"];
}

#pragma mark - NSControl Text Editing Delegate (arrow keys)

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    if (commandSelector == @selector(moveUp:)) {
        NSInteger row = self.tableView.selectedRow;
        if (row > 0) {
            NSInteger newRow = row - 1;
            SpliceKitCommand *cmd = [self commandForDisplayRow:newRow];
            if (cmd && cmd.isSeparatorRow && newRow > 0) newRow--;
            FCPSelectSingleTableRow(self.tableView, newRow);
        }
        return YES;
    }
    if (commandSelector == @selector(moveDown:)) {
        NSInteger row = self.tableView.selectedRow;
        NSInteger maxRow = self.tableView.numberOfRows - 1;
        if (row < maxRow) {
            NSInteger newRow = row + 1;
            SpliceKitCommand *cmd = [self commandForDisplayRow:newRow];
            if (cmd && cmd.isSeparatorRow && newRow < maxRow) newRow++;
            FCPSelectSingleTableRow(self.tableView, newRow);
        }
        return YES;
    }
    if (commandSelector == @selector(insertNewline:)) {
        [self executeSelectedCommand:nil];
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        if (self.dictationActive) {
            [self stopDictation];
        } else if (self.inBrowseMode) {
            [self exitBrowseMode];
        } else {
            [self hidePalette];
        }
        return YES;
    }
    return NO;
}

#pragma mark - Search / Filter
//
// Fuzzy-scores every command against the query, scoring name, keywords, and
// detail text. Commands below a threshold (0.3) are dropped. Name matches are
// weighted 1.0, keyword matches 0.8, detail matches 0.5.
//

// Strip common stop words so wordy queries like "add the default
// transition to all clips" match "Add Default Transition to All Clips" even
// though 'h' (from "the") doesn't appear in the target.
static NSString *FCPStripStopWords(NSString *query) {
    static NSSet *stopWords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stopWords = [NSSet setWithObjects:
            @"the", @"a", @"an", @"my", @"this", @"that", @"please",
            @"can", @"you", @"i", @"me", @"it", @"its", @"with",
            @"for", @"on", @"of", @"is", @"and", @"or", nil];
    });
    NSMutableArray *words = [[query componentsSeparatedByString:@" "] mutableCopy];
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSString *word in words) {
        if (word.length > 0 && ![stopWords containsObject:[word lowercaseString]]) {
            [filtered addObject:word];
        }
    }
    return filtered.count > 0 ? [filtered componentsJoinedByString:@" "] : query;
}

- (NSArray<SpliceKitCommand *> *)searchCommands:(NSString *)query {
    if (query.length == 0) return self.allCommands;

    // Try both raw query and stop-word-stripped version
    NSString *cleaned = FCPStripStopWords(query);
    BOOL hasCleaned = ![cleaned isEqualToString:query];

    NSMutableArray<SpliceKitCommand *> *results = [NSMutableArray array];
    for (SpliceKitCommand *cmd in self.allCommands) {
        // Score against name
        CGFloat nameScore = FCPFuzzyScore(query, cmd.name);
        if (hasCleaned) nameScore = MAX(nameScore, FCPFuzzyScore(cleaned, cmd.name));
        // Score against keywords
        CGFloat keywordScore = 0;
        for (NSString *kw in cmd.keywords) {
            CGFloat s = FCPFuzzyScore(query, kw);
            if (hasCleaned) s = MAX(s, FCPFuzzyScore(cleaned, kw));
            if (s > keywordScore) keywordScore = s;
        }
        // Score against category
        CGFloat catScore = FCPFuzzyScore(query, cmd.categoryName) * 0.5;
        // Score against detail
        CGFloat detailScore = FCPFuzzyScore(query, cmd.detail) * 0.3;

        CGFloat best = MAX(MAX(nameScore, keywordScore), MAX(catScore, detailScore));
        if (best > 0.2) {
            cmd.score = best;
            [results addObject:cmd];
        }
    }

    [results sortUsingComparator:^NSComparisonResult(SpliceKitCommand *a, SpliceKitCommand *b) {
        if (a.score > b.score) return NSOrderedAscending;
        if (a.score < b.score) return NSOrderedDescending;
        return [a.name compare:b.name];
    }];

    return results;
}

- (void)refreshSearchResultsForCurrentQuery {
    NSString *query = self.searchField.stringValue;
    if (self.inBrowseMode && self.rawBrowseCommands) {
        if (query.length > 0) {
            // Search raw list (no favorites section) to avoid duplicates
            self.filteredCommands = [self searchCommandsInArray:self.rawBrowseCommands query:query];
        } else {
            // Restore favorites section when search is cleared
            [self injectFavoritesIntoCurrentList];
        }
    } else {
        self.filteredCommands = [self searchCommands:query];
    }
    [self.tableView reloadData];
    [self updateStatusLabel];
    [self updateHeroStageAnimated:YES];
    [self animateResultsRefresh];

    // Auto-select first row
    if (self.filteredCommands.count > 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                    byExtendingSelection:NO];
    }
}

- (void)controlTextDidChange:(NSNotification *)notification {
    [self refreshSearchResultsForCurrentQuery];
}

#pragma mark - NSTableView DataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.filteredCommands.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    SpliceKitCommand *cmd = [self commandForDisplayRow:row];
    if (!cmd) return nil;

    // Separator row
    if (cmd.isSeparatorRow) {
        FCPSeparatorRowView *cell = [tableView makeViewWithIdentifier:kSeparatorRowID owner:nil];
        if (!cell) {
            cell = [[FCPSeparatorRowView alloc] initWithFrame:NSMakeRect(0, 0, 500, 20)];
            cell.identifier = kSeparatorRowID;
        }
        return cell;
    }

    SpliceKitCommandRowView *cell = [tableView makeViewWithIdentifier:kCommandRowID owner:nil];
    if (!cell) {
        cell = [[SpliceKitCommandRowView alloc] initWithFrame:NSMakeRect(0, 0, 500, 40)];
        cell.identifier = kCommandRowID;
    }

    [cell configureWithCommand:cmd
                   isFavorited:cmd.isFavoritedItem
                      selected:(tableView.selectedRow == row)];
    return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    SpliceKitPaletteRowView *rowView = [[SpliceKitPaletteRowView alloc] initWithFrame:NSZeroRect];
    SpliceKitCommand *cmd = [self commandForDisplayRow:row];
    rowView.separatorRow = cmd.isSeparatorRow;
    return rowView;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    SpliceKitCommand *cmd = [self commandForDisplayRow:row];
    if (cmd && cmd.isSeparatorRow) return 20;

    return 62;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    SpliceKitCommand *cmd = [self commandForDisplayRow:row];
    if (cmd && cmd.isSeparatorRow) return NO;
    return YES;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    // The hero stage is derived from query/dictation state, not transient table selection.
    NSRange visibleRows = [self.tableView rowsInRect:self.tableView.visibleRect];
    if (visibleRows.length > 0 && self.tableView.numberOfColumns > 0) {
        NSIndexSet *rows = [NSIndexSet indexSetWithIndexesInRange:visibleRows];
        NSIndexSet *columns = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.tableView.numberOfColumns)];
        [self.tableView reloadDataForRowIndexes:rows columnIndexes:columns];
    }
}

#pragma mark - Execute

- (void)executeSelectedCommand:(id)sender {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0) return;

    SpliceKitCommand *cmd = [self commandForDisplayRow:row];
    if (!cmd || cmd.isSeparatorRow) return;

    // Don't hide palette for browse commands — they repopulate it
    if ([cmd.type isEqualToString:@"transition_browse"]) {
        [self enterTransitionBrowseMode];
        return;
    }
    if ([cmd.type isEqualToString:@"effect_browse"]) {
        [self enterEffectBrowseMode:@"filter"];
        return;
    }
    if ([cmd.type isEqualToString:@"generator_browse"]) {
        [self enterEffectBrowseMode:@"generator"];
        return;
    }
    if ([cmd.type isEqualToString:@"title_browse"]) {
        [self enterEffectBrowseMode:@"title"];
        return;
    }
    if ([cmd.type isEqualToString:@"favorites_browse"]) {
        [self enterFavoritesBrowseMode];
        return;
    }
    [self performAnimatedExecutionForCommand:cmd];
}

- (NSDictionary *)executeCommand:(NSString *)action type:(NSString *)type {
    __block NSDictionary *result = nil;

    if ([type isEqualToString:@"timeline"]) {
        result = SpliceKit_handleTimelineAction(@{@"action": action});
    } else if ([type isEqualToString:@"playback"]) {
        result = SpliceKit_handlePlayback(@{@"action": action});
    } else if ([type isEqualToString:@"transcript"]) {
        SpliceKit_executeOnMainThread(^{
            Class panelClass = objc_getClass("SpliceKitTranscriptPanel");
            if (!panelClass) return;
            id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
            if ([action isEqualToString:@"openTranscript"]) {
                ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
            } else if ([action isEqualToString:@"closeTranscript"]) {
                ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
            }
        });
        result = @{@"action": action, @"status": @"ok"};
    } else if ([type isEqualToString:@"captions"]) {
        SpliceKit_executeOnMainThread(^{
            Class panelClass = objc_getClass("SpliceKitCaptionPanel");
            if (!panelClass) return;
            id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
            if ([action isEqualToString:@"openCaptions"]) {
                ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
            } else if ([action isEqualToString:@"closeCaptions"]) {
                ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
            }
        });
        result = @{@"action": action, @"status": @"ok"};
    } else if ([type isEqualToString:@"mixer"]) {
        SpliceKit_executeOnMainThread(^{
            Class panelClass = objc_getClass("SpliceKitMixerPanel");
            if (!panelClass) return;
            id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
            if ([action isEqualToString:@"openMixer"]) {
                ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
            } else if ([action isEqualToString:@"closeMixer"]) {
                ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
            }
        });
        result = @{@"action": action, @"status": @"ok"};
    } else if ([type isEqualToString:@"livecam"]) {
        SpliceKit_executeOnMainThread(^{
            Class panelClass = objc_getClass("SpliceKitLiveCamPanel");
            if (!panelClass) return;
            id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
            if ([action isEqualToString:@"openLiveCam"]) {
                ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
            } else if ([action isEqualToString:@"closeLiveCam"]) {
                ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
            }
        });
        result = @{@"action": action, @"status": @"ok"};
    } else if ([type isEqualToString:@"transition_browse"]) {
        // Switch palette into transition browsing mode
        [self enterTransitionBrowseMode];
        result = @{@"action": action, @"status": @"ok"};
    } else if ([type isEqualToString:@"transition_apply"]) {
        result = SpliceKit_handleTransitionsApply(@{@"effectID": action});
    } else if ([type isEqualToString:@"title_apply"] || [type isEqualToString:@"generator_apply"]) {
        result = SpliceKit_handleTitleInsert(@{@"effectID": action});
    } else if ([type isEqualToString:@"effect_apply"]) {
        result = SpliceKit_handleEffectsApply(@{@"effectID": action});
    } else if ([type isEqualToString:@"effect_apply_by_name"]) {
        result = SpliceKit_handleEffectsApply(@{@"name": action});
    } else if ([type isEqualToString:@"subject_stabilize"]) {
        // Run on background thread — tracking takes time
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *r = SpliceKit_handleSubjectStabilize(@{});
            dispatch_async(dispatch_get_main_queue(), ^{
                if (r[@"error"]) {
                    SpliceKit_log(@"[Stabilize] Error: %@", r[@"error"]);
                } else {
                    SpliceKit_log(@"[Stabilize] Complete: %@ keyframes applied", r[@"keyframesApplied"]);
                }
            });
        });
        result = @{@"action": action, @"status": @"started"};
    } else if ([type isEqualToString:@"silence_options"]) {
        [self showSilenceOptionsPanel];
        result = @{@"action": action, @"status": @"started"};
    } else if ([type isEqualToString:@"scene_options"]) {
        [self showSceneDetectionOptionsPanel];
        result = @{@"action": action, @"status": @"started"};
    } else if ([type isEqualToString:@"spine_action"]) {
        // Spine manipulation actions (shuffle, reverse)
        if ([action isEqualToString:@"shuffle"]) {

            NSDictionary *state = SpliceKit_handleSpineGetItems(@{});
            NSArray *items = state[@"items"];
            if (!items || [items count] < 2) {
                result = @{@"error": @"Need at least 2 clips to shuffle"};
            } else {
                // Collect clip indices (skip transitions)
                NSMutableArray *clipIndices = [NSMutableArray array];
                for (NSDictionary *item in items) {
                    NSString *cls = item[@"class"] ?: @"";
                    if (![cls containsString:@"Transition"]) {
                        [clipIndices addObject:@(clipIndices.count)];
                    }
                }
                // Fisher-Yates shuffle
                for (NSInteger i = clipIndices.count - 1; i > 0; i--) {
                    NSInteger j = arc4random_uniform((uint32_t)(i + 1));
                    [clipIndices exchangeObjectAtIndex:i withObjectAtIndex:j];
                }
                result = SpliceKit_handleSpineReorder(@{@"order": clipIndices});
                if (result[@"status"]) {
                    SpliceKit_log(@"[Shuffle] Reordered %@ clips (%@ transitions removed)",
                        result[@"clipsReordered"], result[@"transitionsRemoved"]);
                }
            }
        } else if ([action isEqualToString:@"reverse"]) {

            NSDictionary *state = SpliceKit_handleSpineGetItems(@{});
            NSArray *items = state[@"items"];
            if (!items || [items count] < 2) {
                result = @{@"error": @"Need at least 2 clips to reverse"};
            } else {
                NSMutableArray *clipIndices = [NSMutableArray array];
                for (NSDictionary *item in items) {
                    NSString *cls = item[@"class"] ?: @"";
                    if (![cls containsString:@"Transition"]) {
                        [clipIndices addObject:@(clipIndices.count)];
                    }
                }
                // Reverse the array
                NSArray *reversed = [[clipIndices reverseObjectEnumerator] allObjects];
                result = SpliceKit_handleSpineReorder(@{@"order": reversed});
                if (result[@"status"]) {
                    SpliceKit_log(@"[Reverse] Reversed %@ clips", result[@"clipsReordered"]);
                }
            }
        } else {
            result = @{@"error": [NSString stringWithFormat:@"Unknown spine action: %@", action]};
        }
    } else if ([type isEqualToString:@"batch_export"]) {
        result = SpliceKit_handleBatchExport(@{@"scope": @"all"});
    } else if ([type isEqualToString:@"bridge_options"]) {
        [self showBridgeOptionsPanel];
        result = @{@"action": action, @"status": @"ok"};
    } else if ([type isEqualToString:@"beats"]) {
        SpliceKit_log(@"[Beats] detect requires filePath. Use via MCP: detect_beats(file_path)");
        result = @{@"status": @"info", @"message": @"Use via MCP: detect_beats(file_path). Provide path to any MP3/WAV/M4A file."};
    } else if ([type isEqualToString:@"flexmusic"]) {
        // FlexMusic commands — dispatch to JSON-RPC handlers
        if ([action isEqualToString:@"listSongs"]) {
            result = SpliceKit_handleFlexMusicListSongs(@{});
            // Log summary for palette feedback
            NSArray *songs = result[@"songs"];
            if (songs) {
                SpliceKit_log(@"[FlexMusic] Found %lu songs", (unsigned long)songs.count);
            }
        } else if ([action isEqualToString:@"addToTimeline"]) {
            // Needs a song UID — show a message that this should be used via MCP
            SpliceKit_log(@"[FlexMusic] addToTimeline requires songUID parameter. Use via MCP: flexmusic_add_to_timeline(song_uid)");
            result = @{@"status": @"info", @"message": @"Use via MCP: flexmusic_add_to_timeline(song_uid). Run 'Browse FlexMusic Songs' first to find song UIDs."};
        } else if ([action isEqualToString:@"getTiming"]) {
            SpliceKit_log(@"[FlexMusic] getTiming requires songUID and durationSeconds. Use via MCP: flexmusic_get_timing(song_uid, duration_seconds)");
            result = @{@"status": @"info", @"message": @"Use via MCP: flexmusic_get_timing(song_uid, duration_seconds)"};
        } else if ([action isEqualToString:@"renderToFile"]) {
            SpliceKit_log(@"[FlexMusic] renderToFile requires songUID, durationSeconds, outputPath. Use via MCP: flexmusic_render_to_file(...)");
            result = @{@"status": @"info", @"message": @"Use via MCP: flexmusic_render_to_file(song_uid, duration_seconds, output_path)"};
        } else {
            result = @{@"error": [NSString stringWithFormat:@"Unknown flexmusic action: %@", action]};
        }
    } else if ([type isEqualToString:@"montage"]) {
        // Montage commands — dispatch to JSON-RPC handlers
        if ([action isEqualToString:@"auto"]) {
            SpliceKit_log(@"[Montage] auto requires songUID. Use via MCP: montage_auto(song_uid, event_name, style)");
            result = @{@"status": @"info", @"message": @"Use via MCP: montage_auto(song_uid, event_name, style, project_name). Run 'Browse FlexMusic Songs' first."};
        } else if ([action isEqualToString:@"analyzeClips"]) {
            result = SpliceKit_handleMontageAnalyze(@{});
            NSArray *clips = result[@"clips"];
            if (clips) {
                SpliceKit_log(@"[Montage] Analyzed %lu clips", (unsigned long)clips.count);
            }
        } else if ([action isEqualToString:@"planEdit"]) {
            SpliceKit_log(@"[Montage] planEdit requires beats, clips, style. Use via MCP: montage_plan_edit(...)");
            result = @{@"status": @"info", @"message": @"Use via MCP: montage_plan_edit(beats, clips, style)"};
        } else if ([action isEqualToString:@"assemble"]) {
            SpliceKit_log(@"[Montage] assemble requires editPlan. Use via MCP: montage_assemble(edit_plan, project_name, song_file)");
            result = @{@"status": @"info", @"message": @"Use via MCP: montage_assemble(edit_plan, project_name, song_file)"};
        } else {
            result = @{@"error": [NSString stringWithFormat:@"Unknown montage action: %@", action]};
        }
    } else if ([type isEqualToString:@"bridge_toggle"]) {
        if ([action isEqualToString:@"toggleEffectDragAsAdjustmentClip"]) {
            BOOL newState = !SpliceKit_isEffectDragAsAdjustmentClipEnabled();
            SpliceKit_setEffectDragAsAdjustmentClipEnabled(newState);
            result = @{@"action": action, @"status": @"ok",
                       @"effectDragAsAdjustmentClip": @(newState)};
        } else if ([action isEqualToString:@"toggleViewerPinchZoom"]) {
            BOOL newState = !SpliceKit_isViewerPinchZoomEnabled();
            SpliceKit_setViewerPinchZoomEnabled(newState);
            result = @{@"action": action, @"status": @"ok",
                       @"viewerPinchZoom": @(newState)};
        } else {
            result = @{@"error": [NSString stringWithFormat:@"Unknown toggle: %@", action]};
        }
    } else if ([type isEqualToString:@"bridge_conform_cycle"]) {
        NSString *current = SpliceKit_getDefaultSpatialConformType();
        NSString *next;
        if ([current isEqualToString:@"fit"]) next = @"fill";
        else if ([current isEqualToString:@"fill"]) next = @"none";
        else next = @"fit";
        SpliceKit_setDefaultSpatialConformType(next);
        result = @{@"action": action, @"status": @"ok",
                   @"defaultSpatialConformType": next};
    } else if ([type isEqualToString:@"dual_timeline"]) {
        if ([action isEqualToString:@"open"]) {
            result = SpliceKit_dualTimelineOpen(@{});
        } else if ([action isEqualToString:@"syncRoot"]) {
            result = SpliceKit_dualTimelineSyncRoot(@{});
        } else if ([action isEqualToString:@"openSelectedInSecondary"]) {
            result = SpliceKit_dualTimelineOpenSelectedInSecondary(@{});
        } else if ([action isEqualToString:@"focusPrimary"]) {
            result = SpliceKit_dualTimelineFocus(@{@"pane": @"primary"});
        } else if ([action isEqualToString:@"focusSecondary"]) {
            result = SpliceKit_dualTimelineFocus(@{@"pane": @"secondary"});
        } else if ([action isEqualToString:@"close"]) {
            result = SpliceKit_dualTimelineClose(@{});
        } else if ([action isEqualToString:@"toggleSecondaryBrowser"]) {
            result = SpliceKit_dualTimelineTogglePanel(@{@"pane": @"secondary", @"panel": @"browser"});
        } else if ([action isEqualToString:@"toggleSecondaryTimelineIndex"]) {
            result = SpliceKit_dualTimelineTogglePanel(@{@"pane": @"secondary", @"panel": @"timelineIndex"});
        } else if ([action isEqualToString:@"toggleSecondaryAudioMeters"]) {
            result = SpliceKit_dualTimelineTogglePanel(@{@"pane": @"secondary", @"panel": @"audioMeters"});
        } else if ([action isEqualToString:@"toggleSecondaryEffectsBrowser"]) {
            result = SpliceKit_dualTimelineTogglePanel(@{@"pane": @"secondary", @"panel": @"effectsBrowser"});
        } else if ([action isEqualToString:@"toggleSecondaryTransitionsBrowser"]) {
            result = SpliceKit_dualTimelineTogglePanel(@{@"pane": @"secondary", @"panel": @"transitionsBrowser"});
        } else {
            result = @{@"error": [NSString stringWithFormat:@"Unknown dual timeline action: %@", action]};
        }
    } else if ([type isEqualToString:@"url_import_prompt"]) {
        [self showURLImportPromptWithDefaultMode:action];
        result = @{@"action": action, @"status": @"started"};
    }

    if (!result) {
        result = @{@"error": [NSString stringWithFormat:@"Unknown command type: %@", type]};
    }

    SpliceKit_log(@"Command palette executed: %@ (%@) -> %@", action, type,
                  result[@"error"] ?: @"ok");
    return result;
}

- (void)loadFavorites {
    NSArray *dicts = [[NSUserDefaults standardUserDefaults] arrayForKey:kSpliceKitFavoritesKey];
    _favoriteKeys = [NSMutableSet set];
    for (NSDictionary *d in dicts) {
        NSString *key = FCPFavoriteKey(d[@"type"], d[@"action"]);
        if (key) [_favoriteKeys addObject:key];
    }
}

- (SpliceKitCommand *)commandForDisplayRow:(NSInteger)row {
    NSInteger cmdIdx = row;
    if (cmdIdx < 0 || cmdIdx >= (NSInteger)self.filteredCommands.count) return nil;
    return self.filteredCommands[cmdIdx];
}

@end
