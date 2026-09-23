//
//  SpliceKitCaptionPanel+UI.m
//  The caption panel window: building the controls, the live preview and the
//  control actions.
//

#import "SpliceKitCaptionPanel+Private.h"

// Flipped document view so NSScrollView shows content top-down. Without this, an
// unflipped doc view's origin is at the bottom-left and the scroll view can show
// dead space above anchored-to-top content.
@interface SpliceKitCaptionPanelDocView : NSView
@end
@implementation SpliceKitCaptionPanelDocView
- (BOOL)isFlipped { return YES; }
@end

@implementation SpliceKitCaptionPanel (UI)

#pragma mark - Panel Lifecycle

- (void)setupPanelIfNeeded {
    if (self.panel) return;

    NSRect frame = NSMakeRect(100, 150, 480, 680);
    NSUInteger mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                      NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow;

    self.panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:mask
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"Social Captions";
    self.panel.floatingPanel = YES;
    self.panel.becomesKeyOnlyIfNeeded = NO;
    self.panel.hidesOnDeactivate = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.minSize = NSMakeSize(400, 500);
    self.panel.delegate = self;
    self.panel.releasedWhenClosed = NO;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSView *content = self.panel.contentView;
    content.wantsLayer = YES;

    [self buildUI:content];
}

- (void)buildUI:(NSView *)content {
    // Main stack view for vertical layout
    NSScrollView *scrollView = [[NSScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    scrollView.automaticallyAdjustsContentInsets = NO;
    scrollView.contentInsets = NSEdgeInsetsZero;
    [content addSubview:scrollView];

    NSView *docView = [[SpliceKitCaptionPanelDocView alloc] initWithFrame:NSMakeRect(0, 0, 460, 0)];
    docView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.documentView = docView;

    // Status bar at bottom (fixed, not scrollable)
    NSView *statusBar = [[NSView alloc] init];
    statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:statusBar];

    self.statusLabel = [NSTextField labelWithString:@"Ready — choose a style and transcribe"];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [statusBar addSubview:self.statusLabel];

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.hidden = YES;
    [statusBar addSubview:self.spinner];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:content.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:statusBar.topAnchor],

        [statusBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [statusBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [statusBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [statusBar.heightAnchor constraintEqualToConstant:28],

        [self.spinner.leadingAnchor constraintEqualToAnchor:statusBar.leadingAnchor constant:8],
        [self.spinner.centerYAnchor constraintEqualToAnchor:statusBar.centerYAnchor],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.spinner.trailingAnchor constant:6],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:statusBar.trailingAnchor constant:-8],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:statusBar.centerYAnchor],

        [docView.leadingAnchor constraintEqualToAnchor:scrollView.contentView.leadingAnchor],
        [docView.trailingAnchor constraintEqualToAnchor:scrollView.contentView.trailingAnchor],
        [docView.topAnchor constraintEqualToAnchor:scrollView.contentView.topAnchor],
        [docView.widthAnchor constraintEqualToAnchor:scrollView.contentView.widthAnchor],
    ]];

    CGFloat pad = 14;
    CGFloat rowH = 26;
    NSView *prev = nil; // track the last added view for vertical chaining

    // === STYLE PRESET ===
    NSTextField *presetLabel = [self makeLabel:@"Style"];
    [docView addSubview:presetLabel];

    self.presetPopup = [[NSPopUpButton alloc] init];
    self.presetPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.presetPopup.controlSize = NSControlSizeRegular;
    for (SpliceKitCaptionStyle *s in [SpliceKitCaptionStyle builtInPresets]) {
        [self.presetPopup addItemWithTitle:s.name];
    }
    self.presetPopup.target = self;
    self.presetPopup.action = @selector(presetChanged:);
    [docView addSubview:self.presetPopup];

    [NSLayoutConstraint activateConstraints:@[
        [presetLabel.topAnchor constraintEqualToAnchor:docView.topAnchor constant:pad],
        [presetLabel.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [presetLabel.widthAnchor constraintEqualToConstant:80],
        [self.presetPopup.centerYAnchor constraintEqualToAnchor:presetLabel.centerYAnchor],
        [self.presetPopup.leadingAnchor constraintEqualToAnchor:presetLabel.trailingAnchor constant:4],
        [self.presetPopup.trailingAnchor constraintEqualToAnchor:docView.trailingAnchor constant:-pad],
    ]];
    prev = presetLabel;

    // === TRANSCRIPTION ENGINE ===
    NSTextField *engineLabel = [self makeLabel:@"Engine"];
    [docView addSubview:engineLabel];

    self.enginePopup = [[NSPopUpButton alloc] init];
    self.enginePopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.enginePopup.controlSize = NSControlSizeRegular;
    [self.enginePopup addItemWithTitle:@"Parakeet v3 (Fast, ~475 MB)"];
    self.enginePopup.lastItem.representedObject = @"parakeetV3";
    [self.enginePopup addItemWithTitle:@"Whisper large-v3-turbo (~800 MB)"];
    self.enginePopup.lastItem.representedObject = @"whisperLargeV3Turbo";
    [self.enginePopup addItemWithTitle:@"Whisper large-v3 (Highest quality, ~1.5 GB)"];
    self.enginePopup.lastItem.representedObject = @"whisperLargeV3";
    NSString *savedEngine = [[NSUserDefaults standardUserDefaults] stringForKey:@"SpliceKitCaptionEngine"] ?: @"whisperLargeV3";
    for (NSMenuItem *item in self.enginePopup.itemArray) {
        if ([item.representedObject isEqual:savedEngine]) { [self.enginePopup selectItem:item]; break; }
    }
    self.enginePopup.target = self;
    self.enginePopup.action = @selector(engineChanged:);
    [docView addSubview:self.enginePopup];

    [NSLayoutConstraint activateConstraints:@[
        [engineLabel.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:8],
        [engineLabel.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [engineLabel.widthAnchor constraintEqualToConstant:80],
        [self.enginePopup.centerYAnchor constraintEqualToAnchor:engineLabel.centerYAnchor],
        [self.enginePopup.leadingAnchor constraintEqualToAnchor:engineLabel.trailingAnchor constant:4],
        [self.enginePopup.trailingAnchor constraintEqualToAnchor:docView.trailingAnchor constant:-pad],
    ]];
    prev = engineLabel;

    // === PREVIEW ===
    self.previewView = [[NSView alloc] init];
    self.previewView.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewView.wantsLayer = YES;
    self.previewView.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:0.1 alpha:1] CGColor];
    self.previewView.layer.cornerRadius = 8;
    [docView addSubview:self.previewView];

    self.previewLabel = [[NSTextField alloc] init];
    self.previewLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewLabel.editable = NO;
    self.previewLabel.selectable = NO;
    self.previewLabel.bordered = NO;
    self.previewLabel.drawsBackground = NO;
    self.previewLabel.alignment = NSTextAlignmentCenter;
    self.previewLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.previewLabel.maximumNumberOfLines = 3;
    [self.previewView addSubview:self.previewLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.previewView.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:10],
        [self.previewView.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [self.previewView.trailingAnchor constraintEqualToAnchor:docView.trailingAnchor constant:-pad],
        [self.previewView.heightAnchor constraintEqualToConstant:140],

        [self.previewLabel.leadingAnchor constraintEqualToAnchor:self.previewView.leadingAnchor constant:12],
        [self.previewLabel.trailingAnchor constraintEqualToAnchor:self.previewView.trailingAnchor constant:-12],
        [self.previewLabel.centerYAnchor constraintEqualToAnchor:self.previewView.centerYAnchor],
    ]];
    prev = self.previewView;

    // === FONT ===
    NSTextField *fontLabel = [self makeLabel:@"Font"];
    [docView addSubview:fontLabel];

    self.fontPopup = [[NSPopUpButton alloc] init];
    self.fontPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.fontPopup.controlSize = NSControlSizeSmall;
    NSArray *families = [[[NSFontManager sharedFontManager] availableFontFamilies]
                         sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *fam in families) { [self.fontPopup addItemWithTitle:fam]; }
    self.fontPopup.target = self; self.fontPopup.action = @selector(fontChanged:);
    [docView addSubview:self.fontPopup];

    [self layoutRow:fontLabel control:self.fontPopup in:docView below:prev pad:pad rowH:rowH];
    prev = fontLabel;

    // === FONT SIZE ===
    NSTextField *sizeLabel = [self makeLabel:@"Size"];
    [docView addSubview:sizeLabel];

    self.fontSizeSlider = [[NSSlider alloc] init];
    self.fontSizeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.fontSizeSlider.minValue = 20; self.fontSizeSlider.maxValue = 120;
    self.fontSizeSlider.target = self; self.fontSizeSlider.action = @selector(fontSizeChanged:);
    self.fontSizeSlider.controlSize = NSControlSizeSmall;
    [docView addSubview:self.fontSizeSlider];

    self.fontSizeField = [[NSTextField alloc] init];
    self.fontSizeField.translatesAutoresizingMaskIntoConstraints = NO;
    self.fontSizeField.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.fontSizeField.alignment = NSTextAlignmentCenter;
    self.fontSizeField.editable = NO; self.fontSizeField.bordered = YES;
    self.fontSizeField.controlSize = NSControlSizeSmall;
    [docView addSubview:self.fontSizeField];

    [NSLayoutConstraint activateConstraints:@[
        [sizeLabel.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:8],
        [sizeLabel.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [sizeLabel.widthAnchor constraintEqualToConstant:80],
        [self.fontSizeSlider.centerYAnchor constraintEqualToAnchor:sizeLabel.centerYAnchor],
        [self.fontSizeSlider.leadingAnchor constraintEqualToAnchor:sizeLabel.trailingAnchor constant:4],
        [self.fontSizeSlider.trailingAnchor constraintEqualToAnchor:self.fontSizeField.leadingAnchor constant:-6],
        [self.fontSizeField.centerYAnchor constraintEqualToAnchor:sizeLabel.centerYAnchor],
        [self.fontSizeField.trailingAnchor constraintEqualToAnchor:docView.trailingAnchor constant:-pad],
        [self.fontSizeField.widthAnchor constraintEqualToConstant:44],
    ]];
    prev = sizeLabel;

    // === COLORS (text, highlight, outline, shadow) ===
    NSTextField *colorsLabel = [self makeLabel:@"Colors"];
    [docView addSubview:colorsLabel];

    self.textColorWell = [self makeColorWell]; [docView addSubview:self.textColorWell];
    NSTextField *tcLabel = [self makeTinyLabel:@"Text"]; [docView addSubview:tcLabel];

    self.highlightColorWell = [self makeColorWell]; [docView addSubview:self.highlightColorWell];
    NSTextField *hcLabel = [self makeTinyLabel:@"Highlight"]; [docView addSubview:hcLabel];

    self.outlineColorWell = [self makeColorWell]; [docView addSubview:self.outlineColorWell];
    NSTextField *ocLabel = [self makeTinyLabel:@"Outline"]; [docView addSubview:ocLabel];

    self.shadowColorWell = [self makeColorWell]; [docView addSubview:self.shadowColorWell];
    NSTextField *scLabel = [self makeTinyLabel:@"Shadow"]; [docView addSubview:scLabel];

    self.textColorWell.target = self; self.textColorWell.action = @selector(colorChanged:);
    self.highlightColorWell.target = self; self.highlightColorWell.action = @selector(colorChanged:);
    self.outlineColorWell.target = self; self.outlineColorWell.action = @selector(colorChanged:);
    self.shadowColorWell.target = self; self.shadowColorWell.action = @selector(colorChanged:);

    [NSLayoutConstraint activateConstraints:@[
        [colorsLabel.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:10],
        [colorsLabel.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [colorsLabel.widthAnchor constraintEqualToConstant:80],

        [self.textColorWell.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [self.textColorWell.leadingAnchor constraintEqualToAnchor:colorsLabel.trailingAnchor constant:4],
        [tcLabel.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [tcLabel.leadingAnchor constraintEqualToAnchor:self.textColorWell.trailingAnchor constant:2],

        [self.highlightColorWell.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [self.highlightColorWell.leadingAnchor constraintEqualToAnchor:tcLabel.trailingAnchor constant:8],
        [hcLabel.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [hcLabel.leadingAnchor constraintEqualToAnchor:self.highlightColorWell.trailingAnchor constant:2],

        [self.outlineColorWell.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [self.outlineColorWell.leadingAnchor constraintEqualToAnchor:hcLabel.trailingAnchor constant:8],
        [ocLabel.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [ocLabel.leadingAnchor constraintEqualToAnchor:self.outlineColorWell.trailingAnchor constant:2],

        [self.shadowColorWell.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [self.shadowColorWell.leadingAnchor constraintEqualToAnchor:ocLabel.trailingAnchor constant:8],
        [scLabel.centerYAnchor constraintEqualToAnchor:colorsLabel.centerYAnchor],
        [scLabel.leadingAnchor constraintEqualToAnchor:self.shadowColorWell.trailingAnchor constant:2],
    ]];
    prev = colorsLabel;

    // === OUTLINE WIDTH ===
    NSTextField *owLabel = [self makeLabel:@"Outline W."];
    [docView addSubview:owLabel];
    self.outlineWidthSlider = [[NSSlider alloc] init];
    self.outlineWidthSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.outlineWidthSlider.minValue = 0; self.outlineWidthSlider.maxValue = 6;
    self.outlineWidthSlider.controlSize = NSControlSizeSmall;
    self.outlineWidthSlider.target = self; self.outlineWidthSlider.action = @selector(outlineWidthChanged:);
    [docView addSubview:self.outlineWidthSlider];
    [self layoutRow:owLabel control:self.outlineWidthSlider in:docView below:prev pad:pad rowH:rowH];
    prev = owLabel;

    // === SHADOW BLUR ===
    NSTextField *sbLabel = [self makeLabel:@"Shadow Blur"];
    [docView addSubview:sbLabel];
    self.shadowBlurSlider = [[NSSlider alloc] init];
    self.shadowBlurSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.shadowBlurSlider.minValue = 0; self.shadowBlurSlider.maxValue = 20;
    self.shadowBlurSlider.controlSize = NSControlSizeSmall;
    self.shadowBlurSlider.target = self; self.shadowBlurSlider.action = @selector(shadowBlurChanged:);
    [docView addSubview:self.shadowBlurSlider];
    [self layoutRow:sbLabel control:self.shadowBlurSlider in:docView below:prev pad:pad rowH:rowH];
    prev = sbLabel;

    // === POSITION ===
    NSTextField *posLabel = [self makeLabel:@"Position"];
    [docView addSubview:posLabel];
    self.positionPopup = [[NSPopUpButton alloc] init];
    self.positionPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.positionPopup.controlSize = NSControlSizeSmall;
    [self.positionPopup addItemsWithTitles:@[@"Bottom", @"Center", @"Top"]];
    self.positionPopup.target = self; self.positionPopup.action = @selector(positionChanged:);
    [docView addSubview:self.positionPopup];
    [self layoutRow:posLabel control:self.positionPopup in:docView below:prev pad:pad rowH:rowH];
    prev = posLabel;

    // === ANIMATION ===
    NSTextField *animLabel = [self makeLabel:@"Animation"];
    [docView addSubview:animLabel];
    self.animationPopup = [[NSPopUpButton alloc] init];
    self.animationPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.animationPopup.controlSize = NSControlSizeSmall;
    [self.animationPopup addItemsWithTitles:@[@"None", @"Fade", @"Pop", @"Slide Up", @"Typewriter", @"Bounce"]];
    self.animationPopup.target = self; self.animationPopup.action = @selector(animationChanged:);
    [docView addSubview:self.animationPopup];
    [self layoutRow:animLabel control:self.animationPopup in:docView below:prev pad:pad rowH:rowH];
    prev = animLabel;

    // === CHECKBOXES ===
    self.allCapsCheckbox = [NSButton checkboxWithTitle:@"ALL CAPS" target:self action:@selector(capsToggled:)];
    self.allCapsCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    self.allCapsCheckbox.font = [NSFont systemFontOfSize:11];
    [docView addSubview:self.allCapsCheckbox];

    self.wordHighlightCheckbox = [NSButton checkboxWithTitle:@"Word-by-word highlight" target:self action:@selector(highlightToggled:)];
    self.wordHighlightCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    self.wordHighlightCheckbox.font = [NSFont systemFontOfSize:11];
    [docView addSubview:self.wordHighlightCheckbox];

    [NSLayoutConstraint activateConstraints:@[
        [self.allCapsCheckbox.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:10],
        [self.allCapsCheckbox.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad + 84],
        [self.wordHighlightCheckbox.centerYAnchor constraintEqualToAnchor:self.allCapsCheckbox.centerYAnchor],
        [self.wordHighlightCheckbox.leadingAnchor constraintEqualToAnchor:self.allCapsCheckbox.trailingAnchor constant:16],
    ]];
    prev = self.allCapsCheckbox;

    // === SEPARATOR ===
    NSBox *sep1 = [[NSBox alloc] init]; sep1.boxType = NSBoxSeparator;
    sep1.translatesAutoresizingMaskIntoConstraints = NO;
    [docView addSubview:sep1];
    [NSLayoutConstraint activateConstraints:@[
        [sep1.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:10],
        [sep1.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [sep1.trailingAnchor constraintEqualToAnchor:docView.trailingAnchor constant:-pad],
    ]];
    prev = sep1;

    // === GROUPING ===
    NSTextField *groupLabel = [self makeLabel:@"Grouping"];
    [docView addSubview:groupLabel];
    self.groupingPopup = [[NSPopUpButton alloc] init];
    self.groupingPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.groupingPopup.controlSize = NSControlSizeSmall;
    [self.groupingPopup addItemsWithTitles:@[@"By Words", @"By Sentence", @"By Time", @"By Characters"]];
    self.groupingPopup.target = self; self.groupingPopup.action = @selector(groupingChanged:);
    [docView addSubview:self.groupingPopup];

    self.groupingValueField = [[NSTextField alloc] init];
    self.groupingValueField.translatesAutoresizingMaskIntoConstraints = NO;
    self.groupingValueField.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.groupingValueField.alignment = NSTextAlignmentCenter;
    self.groupingValueField.stringValue = @"5";
    self.groupingValueField.controlSize = NSControlSizeSmall;
    [docView addSubview:self.groupingValueField];

    NSTextField *gpSuffix = [self makeTinyLabel:@"max per group"];
    [docView addSubview:gpSuffix];

    [NSLayoutConstraint activateConstraints:@[
        [groupLabel.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:10],
        [groupLabel.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [groupLabel.widthAnchor constraintEqualToConstant:80],
        [self.groupingPopup.centerYAnchor constraintEqualToAnchor:groupLabel.centerYAnchor],
        [self.groupingPopup.leadingAnchor constraintEqualToAnchor:groupLabel.trailingAnchor constant:4],
        [self.groupingValueField.centerYAnchor constraintEqualToAnchor:groupLabel.centerYAnchor],
        [self.groupingValueField.leadingAnchor constraintEqualToAnchor:self.groupingPopup.trailingAnchor constant:6],
        [self.groupingValueField.widthAnchor constraintEqualToConstant:40],
        [gpSuffix.centerYAnchor constraintEqualToAnchor:groupLabel.centerYAnchor],
        [gpSuffix.leadingAnchor constraintEqualToAnchor:self.groupingValueField.trailingAnchor constant:4],
    ]];
    prev = groupLabel;

    // === SEPARATOR ===
    NSBox *sep2 = [[NSBox alloc] init]; sep2.boxType = NSBoxSeparator;
    sep2.translatesAutoresizingMaskIntoConstraints = NO;
    [docView addSubview:sep2];
    [NSLayoutConstraint activateConstraints:@[
        [sep2.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:10],
        [sep2.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [sep2.trailingAnchor constraintEqualToAnchor:docView.trailingAnchor constant:-pad],
    ]];
    prev = sep2;

    // === ACTION BUTTONS ===
    self.transcribeButton = [NSButton buttonWithTitle:@"Transcribe" target:self action:@selector(transcribeClicked:)];
    self.transcribeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.transcribeButton.bezelStyle = NSBezelStyleRounded;
    [docView addSubview:self.transcribeButton];

    self.generateButton = [NSButton buttonWithTitle:@"Generate Captions" target:self action:@selector(generateClicked:)];
    self.generateButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.generateButton.bezelStyle = NSBezelStyleRounded;
    self.generateButton.keyEquivalent = @"\r";
    [docView addSubview:self.generateButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.transcribeButton.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:12],
        [self.transcribeButton.leadingAnchor constraintEqualToAnchor:docView.leadingAnchor constant:pad],
        [self.generateButton.centerYAnchor constraintEqualToAnchor:self.transcribeButton.centerYAnchor],
        [self.generateButton.leadingAnchor constraintEqualToAnchor:self.transcribeButton.trailingAnchor constant:8],
    ]];

    self.exportSRTButton = [NSButton buttonWithTitle:@"SRT" target:self action:@selector(exportSRTClicked:)];
    self.exportSRTButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.exportSRTButton.bezelStyle = NSBezelStyleRounded;
    self.exportSRTButton.font = [NSFont systemFontOfSize:11];
    [docView addSubview:self.exportSRTButton];

    self.exportTXTButton = [NSButton buttonWithTitle:@"TXT" target:self action:@selector(exportTXTClicked:)];
    self.exportTXTButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.exportTXTButton.bezelStyle = NSBezelStyleRounded;
    self.exportTXTButton.font = [NSFont systemFontOfSize:11];
    [docView addSubview:self.exportTXTButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.exportTXTButton.centerYAnchor constraintEqualToAnchor:self.transcribeButton.centerYAnchor],
        [self.exportTXTButton.trailingAnchor constraintEqualToAnchor:docView.trailingAnchor constant:-pad],
        [self.exportSRTButton.centerYAnchor constraintEqualToAnchor:self.transcribeButton.centerYAnchor],
        [self.exportSRTButton.trailingAnchor constraintEqualToAnchor:self.exportTXTButton.leadingAnchor constant:-4],
    ]];

    // Bottom constraint for scrollable doc view — Equal (not LessThanOrEqual) so docView's
    // height collapses to fit content. Without this, docView keeps its initial 900pt frame
    // and the scroll view ends up with dead space above the Style row.
    [self.transcribeButton.bottomAnchor constraintEqualToAnchor:docView.bottomAnchor constant:-pad].active = YES;

    [self syncUIFromStyle];

    // Size the panel to the natural content height. Without this the initial
    // 680pt frame leaves ~120pt of dead space below the action buttons, and
    // nothing caps how much larger the user can grow it.
    [content layoutSubtreeIfNeeded];
    CGFloat docHeight = docView.fittingSize.height;
    if (docHeight > 0) {
        CGFloat totalContentHeight = docHeight + 28.0; // status bar is 28pt
        NSSize minSize = NSMakeSize(400, totalContentHeight);
        self.panel.contentMinSize = minSize;
        self.panel.contentMaxSize = NSMakeSize(CGFLOAT_MAX, totalContentHeight);
        [self.panel setContentSize:NSMakeSize(self.panel.contentView.frame.size.width, totalContentHeight)];
    }
}

#pragma mark - UI Helpers

- (NSTextField *)makeLabel:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    label.textColor = [NSColor secondaryLabelColor];
    return label;
}

- (NSTextField *)makeTinyLabel:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont systemFontOfSize:9];
    label.textColor = [NSColor tertiaryLabelColor];
    return label;
}

- (NSColorWell *)makeColorWell {
    NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 24, 24)];
    well.translatesAutoresizingMaskIntoConstraints = NO;
    well.bordered = YES;
    [NSLayoutConstraint activateConstraints:@[
        [well.widthAnchor constraintEqualToConstant:24],
        [well.heightAnchor constraintEqualToConstant:24],
    ]];
    return well;
}

- (void)layoutRow:(NSView *)label control:(NSView *)ctrl in:(NSView *)parent below:(NSView *)prev
              pad:(CGFloat)pad rowH:(CGFloat)rowH {
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:8],
        [label.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:pad],
        [label.widthAnchor constraintEqualToConstant:80],
        [ctrl.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
        [ctrl.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:4],
        [ctrl.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-pad],
    ]];
}

- (void)syncUIFromStyle {
    if (!self.panel) return;
    SpliceKitCaptionStyle *s = self.style;

    // Preset popup
    NSArray *presets = [SpliceKitCaptionStyle builtInPresets];
    NSInteger idx = -1;
    for (NSInteger i = 0; i < (NSInteger)presets.count; i++) {
        if ([((SpliceKitCaptionStyle *)presets[i]).presetID isEqualToString:s.presetID]) { idx = i; break; }
    }
    if (idx >= 0) [self.presetPopup selectItemAtIndex:idx];

    // Font
    [self.fontPopup selectItemWithTitle:s.font ?: @"Helvetica Neue"];

    // Font size
    self.fontSizeSlider.doubleValue = s.fontSize;
    self.fontSizeField.stringValue = [NSString stringWithFormat:@"%.0f", s.fontSize];

    // Colors
    self.textColorWell.color = s.textColor ?: [NSColor whiteColor];
    self.highlightColorWell.color = s.highlightColor ?: [NSColor yellowColor];
    self.outlineColorWell.color = s.outlineColor ?: [NSColor blackColor];
    self.shadowColorWell.color = s.shadowColor ?: [NSColor blackColor];

    // Sliders
    self.outlineWidthSlider.doubleValue = s.outlineWidth;
    self.shadowBlurSlider.doubleValue = s.shadowBlurRadius;

    // Popups
    [self.positionPopup selectItemAtIndex:(NSInteger)s.position];
    [self.animationPopup selectItemAtIndex:(NSInteger)s.animation];

    // Checkboxes
    self.allCapsCheckbox.state = s.allCaps ? NSControlStateValueOn : NSControlStateValueOff;
    self.wordHighlightCheckbox.state = s.wordByWordHighlight ? NSControlStateValueOn : NSControlStateValueOff;

    // Grouping
    [self.groupingPopup selectItemAtIndex:(NSInteger)self.groupingMode];
    NSUInteger val = self.maxWordsPerSegment;
    if (self.groupingMode == SpliceKitCaptionGroupingByCharCount) val = self.maxCharsPerSegment;
    self.groupingValueField.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)val];

    [self updatePreview];
}

- (void)updatePreview {
    if (!self.previewLabel) return;
    SpliceKitCaptionStyle *s = self.style;

    NSString *word1 = s.allCaps ? @"THE " : @"The ";
    NSString *word2 = s.allCaps ? @"QUICK " : @"quick ";
    NSString *word3 = s.allCaps ? @"BROWN FOX" : @"brown fox";

    CGFloat previewFontSize = MIN(s.fontSize * 0.4, 36);
    NSFont *font = [NSFont fontWithName:s.font size:previewFontSize] ?:
                   [NSFont boldSystemFontOfSize:previewFontSize];

    NSMutableDictionary *normalAttrs = [@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: s.textColor ?: [NSColor whiteColor],
    } mutableCopy];

    NSMutableDictionary *highlightAttrs = [@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: (s.highlightColor && s.wordByWordHighlight)
            ? s.highlightColor : (s.textColor ?: [NSColor whiteColor]),
    } mutableCopy];

    if (SpliceKitCaption_usesWordHighlightRuntimeStyle(s)) {
        normalAttrs[NSKernAttributeName] = @(-1.28);
        highlightAttrs[NSKernAttributeName] = @(-1.28);
    }

    // Outline via stroke
    if (s.outlineColor && s.outlineWidth > 0) {
        normalAttrs[NSStrokeColorAttributeName] = s.outlineColor;
        normalAttrs[NSStrokeWidthAttributeName] = @(-s.outlineWidth); // negative = fill + stroke
        highlightAttrs[NSStrokeColorAttributeName] = s.outlineColor;
        highlightAttrs[NSStrokeWidthAttributeName] = @(-s.outlineWidth);
    }

    // Shadow
    if (s.shadowColor && s.shadowBlurRadius > 0) {
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = s.shadowColor;
        if (SpliceKitCaption_usesWordHighlightRuntimeStyle(s)) {
            shadow.shadowBlurRadius = 0.97;
            shadow.shadowOffset = NSMakeSize(1.42, -1.42);
        } else {
            shadow.shadowBlurRadius = s.shadowBlurRadius * 0.4;
            shadow.shadowOffset = NSMakeSize(s.shadowOffsetX * 0.4, -s.shadowOffsetY * 0.4);
        }
        normalAttrs[NSShadowAttributeName] = shadow;
        highlightAttrs[NSShadowAttributeName] = shadow;
    }

    NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] init];
    [attrStr appendAttributedString:[[NSAttributedString alloc] initWithString:word1 attributes:normalAttrs]];
    [attrStr appendAttributedString:[[NSAttributedString alloc] initWithString:word2 attributes:highlightAttrs]];
    [attrStr appendAttributedString:[[NSAttributedString alloc] initWithString:word3 attributes:normalAttrs]];

    self.previewLabel.attributedStringValue = attrStr;
}

#pragma mark - UI Actions

- (void)presetChanged:(id)sender {
    NSArray *presets = [SpliceKitCaptionStyle builtInPresets];
    NSInteger idx = self.presetPopup.indexOfSelectedItem;
    if (idx >= 0 && idx < (NSInteger)presets.count) {
        self.style = [presets[idx] copy];
        [self syncUIFromStyle];
    }
}

- (void)engineChanged:(id)sender {
    NSString *engineID = [self currentEngineID];
    [[NSUserDefaults standardUserDefaults] setObject:engineID forKey:@"SpliceKitCaptionEngine"];
    SpliceKit_log(@"[Captions] Transcription engine switched to: %@", engineID);
}

- (NSString *)currentEngineID {
    id obj = self.enginePopup.selectedItem.representedObject;
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"SpliceKitCaptionEngine"] ?: @"whisperLargeV3";
}

- (void)fontChanged:(id)sender { self.style.font = self.fontPopup.titleOfSelectedItem; [self updatePreview]; [self persistCaptionDraftStateForCurrentSequence]; }
- (void)fontSizeChanged:(id)sender {
    self.style.fontSize = self.fontSizeSlider.doubleValue;
    self.fontSizeField.stringValue = [NSString stringWithFormat:@"%.0f", self.style.fontSize];
    [self updatePreview];
    [self persistCaptionDraftStateForCurrentSequence];
}
- (void)colorChanged:(id)sender {
    self.style.textColor = self.textColorWell.color;
    self.style.highlightColor = self.highlightColorWell.color;
    self.style.outlineColor = self.outlineColorWell.color;
    self.style.shadowColor = self.shadowColorWell.color;
    [self updatePreview];
    [self persistCaptionDraftStateForCurrentSequence];
}
- (void)outlineWidthChanged:(id)sender { self.style.outlineWidth = self.outlineWidthSlider.doubleValue; [self updatePreview]; [self persistCaptionDraftStateForCurrentSequence]; }
- (void)shadowBlurChanged:(id)sender { self.style.shadowBlurRadius = self.shadowBlurSlider.doubleValue; [self updatePreview]; [self persistCaptionDraftStateForCurrentSequence]; }
- (void)positionChanged:(id)sender { self.style.position = (SpliceKitCaptionPosition)self.positionPopup.indexOfSelectedItem; [self persistCaptionDraftStateForCurrentSequence]; }
- (void)animationChanged:(id)sender { self.style.animation = (SpliceKitCaptionAnimation)self.animationPopup.indexOfSelectedItem; [self persistCaptionDraftStateForCurrentSequence]; }
- (void)capsToggled:(id)sender { self.style.allCaps = (self.allCapsCheckbox.state == NSControlStateValueOn); [self updatePreview]; [self persistCaptionDraftStateForCurrentSequence]; }
- (void)highlightToggled:(id)sender { self.style.wordByWordHighlight = (self.wordHighlightCheckbox.state == NSControlStateValueOn); [self updatePreview]; [self persistCaptionDraftStateForCurrentSequence]; }

- (void)groupingChanged:(id)sender {
    self.groupingMode = (SpliceKitCaptionGrouping)self.groupingPopup.indexOfSelectedItem;
    if (self.mutableWords.count > 0) [self regroupSegments];
    [self persistCaptionDraftStateForCurrentSequence];
}

- (void)transcribeClicked:(id)sender { [self transcribeTimeline]; }
- (void)generateClicked:(id)sender {
    self.generateButton.enabled = NO;
    self.statusLabel.stringValue = @"Generating captions...";
    // Must run on background thread — generateCaptions does dispatch_sync to main
    // for the import step, which would deadlock if called from main thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = [self generateCaptions];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.generateButton.enabled = YES;
            if (result[@"error"]) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Error: %@", result[@"error"]];
            }
        });
    });
}

- (void)exportSRTClicked:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"srt"]];
    panel.nameFieldStringValue = @"captions.srt";
    [panel beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            [self exportSRT:panel.URL.path];
        }
    }];
}

- (void)exportTXTClicked:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"txt"]];
    panel.nameFieldStringValue = @"captions.txt";
    [panel beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            [self exportTXT:panel.URL.path];
        }
    }];
}

- (void)windowWillClose:(NSNotification *)notification {
    // Panel closed by user — just let it hide
}

@end
