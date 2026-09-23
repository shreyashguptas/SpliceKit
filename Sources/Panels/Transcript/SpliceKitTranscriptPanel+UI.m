//
//  SpliceKitTranscriptPanel+UI.m
//  The transcript panel window: building it, the toolbar buttons, rendering the
//  transcript text, click / delete / drag handling, speaker rename and playhead highlight.
//

#import "SpliceKitTranscriptPanel+Private.h"

@implementation SpliceKitTranscriptPanel (UI)

#pragma mark - Panel UI Setup

- (void)setupPanelIfNeeded {
    if (self.panel) return;

    SpliceKit_log(@"[Transcript] Setting up panel UI");

    // Create floating panel — wider for segment layout
    NSRect frame = NSMakeRect(100, 150, 620, 700);
    NSUInteger styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow;

    self.panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:styleMask
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"Transcript Editor";
    self.panel.floatingPanel = YES;
    self.panel.becomesKeyOnlyIfNeeded = NO;
    self.panel.hidesOnDeactivate = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.minSize = NSMakeSize(420, 350);
    self.panel.delegate = self;
    self.panel.releasedWhenClosed = NO;

    // Dark appearance to match FCP
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSView *content = self.panel.contentView;
    content.wantsLayer = YES;

    // ──── Row 1: Search + Filter + Transcribe ────
    NSView *row1 = [[NSView alloc] init];
    row1.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:row1];

    // Search field
    self.searchField = [[NSSearchField alloc] init];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.placeholderString = @"Search transcript...";
    self.searchField.delegate = self;
    self.searchField.sendsSearchStringImmediately = YES;
    self.searchField.sendsWholeSearchString = NO;
    [row1 addSubview:self.searchField];

    // Filter popup
    self.filterPopup = [[NSPopUpButton alloc] init];
    self.filterPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.filterPopup addItemsWithTitles:@[@"All", @"Pauses", @"Low Confidence"]];
    self.filterPopup.target = self;
    self.filterPopup.action = @selector(filterChanged:);
    [self.filterPopup setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row1 addSubview:self.filterPopup];

    // Engine selector
    self.enginePopup = [[NSPopUpButton alloc] init];
    self.enginePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.enginePopup addItemsWithTitles:@[@"FCP Native", @"Apple Speech", @"Parakeet v3", @"Parakeet v2"]];
    self.enginePopup.target = self;
    self.enginePopup.action = @selector(engineChanged:);
    self.enginePopup.font = [NSFont systemFontOfSize:11];
    self.enginePopup.controlSize = NSControlSizeSmall;
    [self.enginePopup setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.enginePopup selectItemAtIndex:2]; // Default to Parakeet v3
    [row1 addSubview:self.enginePopup];

    // Speaker detection checkbox
    self.speakerDetectionCheckbox = [NSButton checkboxWithTitle:@"Speakers"
                                                        target:self
                                                        action:@selector(speakerDetectionToggled:)];
    self.speakerDetectionCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    self.speakerDetectionCheckbox.font = [NSFont systemFontOfSize:11];
    self.speakerDetectionCheckbox.controlSize = NSControlSizeSmall;
    [self.speakerDetectionCheckbox setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row1 addSubview:self.speakerDetectionCheckbox];
    // Initial state: disabled when FCP Native is default engine
    [self updateSpeakerCheckboxState];

    // Transcribe button
    self.refreshButton = [NSButton buttonWithTitle:@"Transcribe"
                                            target:self
                                            action:@selector(refreshClicked:)];
    self.refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.refreshButton.bezelStyle = NSBezelStyleRounded;
    [self.refreshButton setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row1 addSubview:self.refreshButton];

    // ──── Row 2: Delete buttons + Status/Spinner + Result nav ────
    NSView *row2 = [[NSView alloc] init];
    row2.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:row2];

    // Delete results button
    self.deleteResultsButton = [NSButton buttonWithTitle:@"Delete"
                                                  target:self
                                                  action:@selector(deleteResultsClicked:)];
    self.deleteResultsButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.deleteResultsButton.bezelStyle = NSBezelStyleRounded;
    self.deleteResultsButton.image = [NSImage imageWithSystemSymbolName:@"trash" accessibilityDescription:@"Delete"];
    self.deleteResultsButton.imagePosition = NSImageLeading;
    self.deleteResultsButton.enabled = NO;
    [self.deleteResultsButton setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row2 addSubview:self.deleteResultsButton];

    // Delete silences button
    self.deleteSilencesButton = [NSButton buttonWithTitle:@"Delete Silences"
                                                   target:self
                                                   action:@selector(deleteSilencesClicked:)];
    self.deleteSilencesButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.deleteSilencesButton.bezelStyle = NSBezelStyleRounded;
    self.deleteSilencesButton.enabled = NO;
    [self.deleteSilencesButton setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row2 addSubview:self.deleteSilencesButton];

    // Status label + spinner
    self.statusLabel = [NSTextField labelWithString:@"Ready"];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row2 addSubview:self.statusLabel];

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.hidden = YES;
    [row2 addSubview:self.spinner];

    // Result count
    self.resultCountLabel = [NSTextField labelWithString:@""];
    self.resultCountLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.resultCountLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.resultCountLabel.textColor = [NSColor secondaryLabelColor];
    self.resultCountLabel.alignment = NSTextAlignmentRight;
    [self.resultCountLabel setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row2 addSubview:self.resultCountLabel];

    // Prev/Next buttons
    self.prevResultButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.up" accessibilityDescription:@"Previous"]
                                               target:self
                                               action:@selector(prevResultClicked:)];
    self.prevResultButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.prevResultButton.bezelStyle = NSBezelStyleRounded;
    self.prevResultButton.bordered = NO;
    self.prevResultButton.enabled = NO;
    [row2 addSubview:self.prevResultButton];

    self.nextResultButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:@"Next"]
                                               target:self
                                               action:@selector(nextResultClicked:)];
    self.nextResultButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.nextResultButton.bezelStyle = NSBezelStyleRounded;
    self.nextResultButton.bordered = NO;
    self.nextResultButton.enabled = NO;
    [row2 addSubview:self.nextResultButton];

    // ──── Progress bar (hidden by default, shown during transcription) ────
    self.progressBar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressBar.style = NSProgressIndicatorStyleBar;
    self.progressBar.controlSize = NSControlSizeSmall;
    self.progressBar.indeterminate = NO;
    self.progressBar.minValue = 0;
    self.progressBar.maxValue = 1.0;
    self.progressBar.doubleValue = 0;
    self.progressBar.hidden = YES;
    [content addSubview:self.progressBar];

    // ──── Scroll view with text view ────
    // Create scroll view with a real initial frame so NSTextView can read contentSize.
    // Auto Layout will override the frame later, but the initial size lets the text view
    // configure its autoresizing geometry correctly.
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 600, 500)];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.drawsBackground = YES;
    self.scrollView.backgroundColor = [NSColor colorWithCalibratedWhite:0.15 alpha:1.0];
    [content addSubview:self.scrollView];

    // Text view — created using scrollView.contentSize so the initial frame matches
    // the clip view. lineFragmentPadding provides left/right text padding within the
    // text container; textContainerInset provides top/bottom only.
    NSSize cs = self.scrollView.contentSize;
    self.textView = [[SpliceKitTranscriptTextView alloc] initWithFrame:
        NSMakeRect(0, 0, cs.width, cs.height)];
    self.textView.transcriptPanel = self;
    self.textView.minSize = NSMakeSize(0, cs.height);
    self.textView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.textView.verticallyResizable = YES;
    self.textView.horizontallyResizable = NO;
    self.textView.autoresizingMask = NSViewWidthSizable;
    self.textView.textContainer.containerSize = NSMakeSize(cs.width, FLT_MAX);
    self.textView.textContainer.widthTracksTextView = YES;
    self.textView.textContainer.lineFragmentPadding = 16;
    self.textView.font = [NSFont systemFontOfSize:15];
    self.textView.textColor = [NSColor labelColor];
    self.textView.backgroundColor = [NSColor colorWithCalibratedWhite:0.15 alpha:1.0];
    self.textView.insertionPointColor = [NSColor whiteColor];
    self.textView.editable = YES;
    self.textView.selectable = YES;
    self.textView.richText = YES;
    self.textView.allowsUndo = NO;
    self.textView.delegate = self;
    self.textView.textContainerInset = NSMakeSize(0, 12);
    self.scrollView.documentView = self.textView;

    [self.textView setupDragTypes];

    // Instructions text
    NSMutableAttributedString *instructions = [[NSMutableAttributedString alloc]
        initWithString:@"Transcript Editor\n\nClick \"Transcribe\" to transcribe audio from your timeline clips.\n\nOnce transcribed:\n  \u2022 Click a word to jump the playhead\n  \u2022 Select words and press Delete to remove those segments\n  \u2022 Drag words to reorder clips\n  \u2022 Use Search to find text or filter Pauses\n  \u2022 Click \"Delete Silences\" to batch-remove pauses\n\nSilences are shown as [\u22ef] markers between words."
        attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:14],
            NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
        }];
    [self.textView.textStorage setAttributedString:instructions];

    // ──── Auto Layout ────

    // Row 1
    [NSLayoutConstraint activateConstraints:@[
        [row1.topAnchor constraintEqualToAnchor:content.topAnchor constant:10],
        [row1.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [row1.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [row1.heightAnchor constraintEqualToConstant:28],

        [self.searchField.leadingAnchor constraintEqualToAnchor:row1.leadingAnchor],
        [self.searchField.centerYAnchor constraintEqualToAnchor:row1.centerYAnchor],

        [self.filterPopup.leadingAnchor constraintEqualToAnchor:self.searchField.trailingAnchor constant:8],
        [self.filterPopup.centerYAnchor constraintEqualToAnchor:row1.centerYAnchor],
        [self.filterPopup.widthAnchor constraintGreaterThanOrEqualToConstant:100],

        [self.enginePopup.leadingAnchor constraintEqualToAnchor:self.filterPopup.trailingAnchor constant:6],
        [self.enginePopup.centerYAnchor constraintEqualToAnchor:row1.centerYAnchor],

        [self.speakerDetectionCheckbox.leadingAnchor constraintEqualToAnchor:self.enginePopup.trailingAnchor constant:6],
        [self.speakerDetectionCheckbox.centerYAnchor constraintEqualToAnchor:row1.centerYAnchor],

        [self.refreshButton.leadingAnchor constraintEqualToAnchor:self.speakerDetectionCheckbox.trailingAnchor constant:6],
        [self.refreshButton.trailingAnchor constraintEqualToAnchor:row1.trailingAnchor],
        [self.refreshButton.centerYAnchor constraintEqualToAnchor:row1.centerYAnchor],

        [self.searchField.trailingAnchor constraintEqualToAnchor:self.filterPopup.leadingAnchor constant:-8],
    ]];

    // Row 2
    [NSLayoutConstraint activateConstraints:@[
        [row2.topAnchor constraintEqualToAnchor:row1.bottomAnchor constant:6],
        [row2.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [row2.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [row2.heightAnchor constraintEqualToConstant:24],

        [self.deleteResultsButton.leadingAnchor constraintEqualToAnchor:row2.leadingAnchor],
        [self.deleteResultsButton.centerYAnchor constraintEqualToAnchor:row2.centerYAnchor],

        [self.deleteSilencesButton.leadingAnchor constraintEqualToAnchor:self.deleteResultsButton.trailingAnchor constant:6],
        [self.deleteSilencesButton.centerYAnchor constraintEqualToAnchor:row2.centerYAnchor],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.deleteSilencesButton.trailingAnchor constant:8],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:row2.centerYAnchor],

        [self.spinner.leadingAnchor constraintEqualToAnchor:self.statusLabel.trailingAnchor constant:4],
        [self.spinner.centerYAnchor constraintEqualToAnchor:row2.centerYAnchor],

        [self.nextResultButton.trailingAnchor constraintEqualToAnchor:row2.trailingAnchor],
        [self.nextResultButton.centerYAnchor constraintEqualToAnchor:row2.centerYAnchor],
        [self.nextResultButton.widthAnchor constraintEqualToConstant:24],

        [self.prevResultButton.trailingAnchor constraintEqualToAnchor:self.nextResultButton.leadingAnchor constant:-2],
        [self.prevResultButton.centerYAnchor constraintEqualToAnchor:row2.centerYAnchor],
        [self.prevResultButton.widthAnchor constraintEqualToConstant:24],

        [self.resultCountLabel.trailingAnchor constraintEqualToAnchor:self.prevResultButton.leadingAnchor constant:-6],
        [self.resultCountLabel.centerYAnchor constraintEqualToAnchor:row2.centerYAnchor],

        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.resultCountLabel.leadingAnchor constant:-8],
    ]];

    // Progress bar (full width, thin, between toolbar and scroll view)
    [NSLayoutConstraint activateConstraints:@[
        [self.progressBar.topAnchor constraintEqualToAnchor:row2.bottomAnchor constant:6],
        [self.progressBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [self.progressBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [self.progressBar.heightAnchor constraintEqualToConstant:4],
    ]];

    // Scroll view
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.progressBar.bottomAnchor constant:4],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];
}

#pragma mark - Button Actions

- (void)refreshClicked:(id)sender {
    [self transcribeTimeline];
}

- (void)engineChanged:(id)sender {
    NSString *selected = self.enginePopup.titleOfSelectedItem;
    if ([selected isEqualToString:@"Apple Speech"]) {
        self.engine = SpliceKitTranscriptEngineAppleSpeech;
        SpliceKit_log(@"[Transcript] Engine switched to Apple Speech (SFSpeechRecognizer)");
    } else if ([selected hasPrefix:@"Parakeet"]) {
        self.engine = SpliceKitTranscriptEngineParakeet;
        if ([selected isEqualToString:@"Parakeet v2"]) {
            self.parakeetModelVersion = @"v2";
            SpliceKit_log(@"[Transcript] Engine switched to Parakeet v2 (English-optimized)");
        } else {
            self.parakeetModelVersion = @"v3";
            SpliceKit_log(@"[Transcript] Engine switched to Parakeet v3 (Multilingual)");
        }
    } else {
        self.engine = SpliceKitTranscriptEngineFCPNative;
        SpliceKit_log(@"[Transcript] Engine switched to FCP Native (AASpeechAnalyzer)");
    }
    [self updateSpeakerCheckboxState];
}

- (void)speakerDetectionToggled:(id)sender {
    self.speakerDetectionEnabled = (self.speakerDetectionCheckbox.state == NSControlStateValueOn);
    SpliceKit_log(@"[Transcript] Speaker detection %@", self.speakerDetectionEnabled ? @"enabled" : @"disabled");
}

- (void)updateSpeakerCheckboxState {
    BOOL macOS26 = SpliceKitTranscript_isSpeakerDiarizationAvailable();
    BOOL isAppleSpeech = (self.engine == SpliceKitTranscriptEngineAppleSpeech);
    BOOL isParakeet = (self.engine == SpliceKitTranscriptEngineParakeet);

    if (isParakeet) {
        // Parakeet has built-in diarization via FluidAudio — always available
        self.speakerDetectionCheckbox.enabled = YES;
        self.speakerDetectionCheckbox.state = NSControlStateValueOn;
        self.speakerDetectionEnabled = YES;
        self.speakerDetectionCheckbox.toolTip = @"Detect different speakers (FluidAudio diarization)";
    } else if (isAppleSpeech && macOS26) {
        self.speakerDetectionCheckbox.enabled = YES;
        self.speakerDetectionCheckbox.state = NSControlStateValueOn;
        self.speakerDetectionEnabled = YES;
        self.speakerDetectionCheckbox.toolTip = @"Detect different speakers (macOS 26+)";
    } else if (isAppleSpeech) {
        self.speakerDetectionCheckbox.enabled = NO;
        self.speakerDetectionCheckbox.state = NSControlStateValueOff;
        self.speakerDetectionEnabled = NO;
        self.speakerDetectionCheckbox.toolTip = @"Speaker detection requires macOS 26 or later";
    } else {
        // FCP Native: no diarization
        self.speakerDetectionCheckbox.enabled = NO;
        self.speakerDetectionCheckbox.state = NSControlStateValueOff;
        self.speakerDetectionEnabled = NO;
        self.speakerDetectionCheckbox.toolTip = @"Speaker detection not available with FCP Native engine";
    }
}

- (void)filterChanged:(id)sender {
    NSString *selected = self.filterPopup.titleOfSelectedItem;
    if ([selected isEqualToString:@"Pauses"]) {
        self.currentFilter = @"pauses";
        self.searchField.stringValue = @"";
        self.currentSearchQuery = @"";
    } else if ([selected isEqualToString:@"Low Confidence"]) {
        self.currentFilter = @"lowConfidence";
        self.searchField.stringValue = @"";
        self.currentSearchQuery = @"";
    } else {
        self.currentFilter = @"all";
    }
    [self rebuildTextView];
    [self performSearchHighlighting];
}

- (void)deleteResultsClicked:(id)sender {
    if (self.searchResultRanges.count == 0) return;

    // If filter is pauses, delete all silences
    if ([self.currentFilter isEqualToString:@"pauses"]) {
        [self deleteSilencesClicked:sender];
        return;
    }

    // Delete selected search result words
    // Collect word indices from search results (reverse order for safe deletion)
    NSMutableArray<NSNumber *> *wordIndicesToDelete = [NSMutableArray array];
    @synchronized (self.mutableWords) {
        for (NSValue *rangeVal in self.searchResultRanges) {
            NSRange range = rangeVal.rangeValue;
            for (SpliceKitTranscriptWord *word in self.mutableWords) {
                NSRange intersection = NSIntersectionRange(range, word.textRange);
                if (intersection.length > 0) {
                    [wordIndicesToDelete addObject:@(word.wordIndex)];
                }
            }
        }
    }

    if (wordIndicesToDelete.count == 0) return;

    // Sort descending so we delete from end first
    [wordIndicesToDelete sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [b compare:a];
    }];

    [self updateStatusUI:@"Deleting search results..."];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSNumber *idx in wordIndicesToDelete) {
            [self deleteWordsFromIndex:idx.unsignedIntegerValue count:1];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatusUI:@"Deleted search results"];
        });
    });
}

- (void)deleteSilencesClicked:(id)sender {
    [self deleteAllSilences];
}

- (void)prevResultClicked:(id)sender {
    if (self.searchResultRanges.count == 0) return;
    self.currentSearchIndex--;
    if (self.currentSearchIndex < 0) {
        self.currentSearchIndex = (NSInteger)self.searchResultRanges.count - 1;
    }
    [self scrollToCurrentSearchResult];
}

- (void)nextResultClicked:(id)sender {
    if (self.searchResultRanges.count == 0) return;
    self.currentSearchIndex++;
    if (self.currentSearchIndex >= (NSInteger)self.searchResultRanges.count) {
        self.currentSearchIndex = 0;
    }
    [self scrollToCurrentSearchResult];
}

#pragma mark - Text View Display

- (void)rebuildTextView {
    self.suppressTextViewCallbacks = YES;
    self.lastPlayheadHighlightRange = NSMakeRange(NSNotFound, 0);

    NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] init];
    NSUInteger textPos = 0;

    // Color definitions
    NSColor *normalColor = [NSColor colorWithCalibratedWhite:0.9 alpha:1.0];
    NSColor *lowConfColor = [NSColor systemOrangeColor];
    NSColor *headerSpeakerColor = [NSColor colorWithCalibratedRed:0.6 green:0.75 blue:1.0 alpha:1.0];
    NSColor *headerTimeColor = [NSColor colorWithCalibratedWhite:0.5 alpha:1.0];
    NSColor *silenceBgColor = [NSColor colorWithCalibratedWhite:0.3 alpha:1.0];
    NSColor *silenceFgColor = [NSColor colorWithCalibratedWhite:0.55 alpha:1.0];

    NSFont *normalFont = [NSFont systemFontOfSize:15];
    NSFont *headerSpeakerFont = [NSFont boldSystemFontOfSize:13];
    NSFont *headerTimeFont = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    NSFont *silenceFont = [NSFont boldSystemFontOfSize:13];

    NSDictionary *normalAttrs = @{
        NSFontAttributeName: normalFont,
        NSForegroundColorAttributeName: normalColor,
        NSCursorAttributeName: [NSCursor IBeamCursor],
        FCPAttrItemType: @"word",
    };

    NSDictionary *lowConfAttrs = @{
        NSFontAttributeName: normalFont,
        NSForegroundColorAttributeName: lowConfColor,
        NSCursorAttributeName: [NSCursor IBeamCursor],
        FCPAttrItemType: @"word",
    };

    // Build silence lookup: afterWordIndex -> silence
    NSMutableDictionary<NSNumber *, SpliceKitTranscriptSilence *> *silenceMap = [NSMutableDictionary dictionary];
    for (SpliceKitTranscriptSilence *s in self.mutableSilences) {
        silenceMap[@(s.afterWordIndex)] = s;
    }

    @synchronized (self.mutableWords) {
        if (self.mutableWords.count == 0) {
            self.suppressTextViewCallbacks = NO;
            return;
        }

        // Compute segments: group by speaker + large time gaps
        NSMutableArray *segments = [NSMutableArray array];
        NSMutableDictionary *currentSegment = nil;
        NSString *currentSpeaker = nil;

        for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
            SpliceKitTranscriptWord *word = self.mutableWords[i];
            BOOL newSegment = NO;

            if (i == 0) {
                newSegment = YES;
            } else if (![word.speaker isEqualToString:currentSpeaker]) {
                // Break on speaker change
                newSegment = YES;
            }

            if (newSegment) {
                currentSegment = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"speaker": word.speaker ?: @"Unknown",
                    @"startWordIndex": @(i),
                    @"startTime": @(word.startTime),
                }];
                [segments addObject:currentSegment];
                currentSpeaker = word.speaker;
            }

            currentSegment[@"endWordIndex"] = @(i);
            currentSegment[@"endTime"] = @(word.endTime);
        }

        // Build the attributed string segment by segment
        for (NSDictionary *segment in segments) {
            NSUInteger segStart = [segment[@"startWordIndex"] unsignedIntegerValue];
            NSUInteger segEnd = [segment[@"endWordIndex"] unsignedIntegerValue];
            NSString *speaker = segment[@"speaker"];
            double segStartTime = [segment[@"startTime"] doubleValue];
            double segEndTime = [segment[@"endTime"] doubleValue];

            // Add spacing before segment (except first)
            if (segStart > 0) {
                [attrStr appendAttributedString:[[NSAttributedString alloc]
                    initWithString:@"\n\n" attributes:@{
                        NSFontAttributeName: [NSFont systemFontOfSize:8],
                        FCPAttrItemType: @"spacer",
                    }]];
                textPos += 2;
            }

            // ── Segment Header: "Speaker 1        00:00:00:00 - 00:00:15:19" ──
            NSString *startTC = SpliceKitTranscript_timecodeFromSeconds(segStartTime, self.frameRate);
            NSString *endTC = SpliceKitTranscript_timecodeFromSeconds(segEndTime, self.frameRate);

            // Speaker name (clickable to rename)
            NSString *speakerStr = [NSString stringWithFormat:@"%@", speaker];
            [attrStr appendAttributedString:[[NSAttributedString alloc]
                initWithString:speakerStr attributes:@{
                    NSFontAttributeName: headerSpeakerFont,
                    NSForegroundColorAttributeName: headerSpeakerColor,
                    NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
                    NSCursorAttributeName: [NSCursor pointingHandCursor],
                    FCPAttrItemType: @"speakerLabel",
                    FCPAttrSpeakerName: speaker,
                    FCPAttrSegmentStartIndex: @(segStart),
                    FCPAttrSegmentEndIndex: @(segEnd),
                }]];
            textPos += speakerStr.length;

            // Spacer between speaker and timecode
            NSString *spacer = @"        ";
            [attrStr appendAttributedString:[[NSAttributedString alloc]
                initWithString:spacer attributes:@{
                    NSFontAttributeName: headerTimeFont,
                    FCPAttrItemType: @"header",
                }]];
            textPos += spacer.length;

            // Timecode range
            NSString *timeStr = [NSString stringWithFormat:@"%@ - %@", startTC, endTC];
            [attrStr appendAttributedString:[[NSAttributedString alloc]
                initWithString:timeStr attributes:@{
                    NSFontAttributeName: headerTimeFont,
                    NSForegroundColorAttributeName: headerTimeColor,
                    FCPAttrItemType: @"header",
                }]];
            textPos += timeStr.length;

            // Newline after header
            [attrStr appendAttributedString:[[NSAttributedString alloc]
                initWithString:@"\n" attributes:@{
                    NSFontAttributeName: normalFont,
                    FCPAttrItemType: @"header",
                }]];
            textPos += 1;

            // ── Words in this segment ──
            for (NSUInteger i = segStart; i <= segEnd; i++) {
                SpliceKitTranscriptWord *word = self.mutableWords[i];

                // Check for silence before this word
                if (i > 0) {
                    SpliceKitTranscriptSilence *silence = silenceMap[@(i - 1)];
                    if (silence) {
                        // Insert silence marker: " [···] "
                        NSString *silenceStr = @" [\u22EF] ";

                        NSMutableDictionary *silenceAttrs = [NSMutableDictionary dictionaryWithDictionary:@{
                            NSFontAttributeName: silenceFont,
                            NSForegroundColorAttributeName: silenceFgColor,
                            NSBackgroundColorAttributeName: silenceBgColor,
                            FCPAttrItemType: @"silence",
                            FCPAttrSilenceIndex: @([self.mutableSilences indexOfObject:silence]),
                            NSToolTipAttributeName: [NSString stringWithFormat:@"Pause: %.1fs (%@ - %@)",
                                silence.duration,
                                SpliceKitTranscript_timecodeFromSeconds(silence.startTime, self.frameRate),
                                SpliceKitTranscript_timecodeFromSeconds(silence.endTime, self.frameRate)],
                        }];

                        silence.textRange = NSMakeRange(textPos, silenceStr.length);

                        [attrStr appendAttributedString:[[NSAttributedString alloc]
                            initWithString:silenceStr attributes:silenceAttrs]];
                        textPos += silenceStr.length;
                    } else if (i > segStart) {
                        // Regular space between words within the same segment
                        [attrStr appendAttributedString:[[NSAttributedString alloc]
                            initWithString:@" " attributes:normalAttrs]];
                        textPos += 1;
                    }
                } else if (i > segStart) {
                    [attrStr appendAttributedString:[[NSAttributedString alloc]
                        initWithString:@" " attributes:normalAttrs]];
                    textPos += 1;
                }

                // Word
                NSDictionary *attrs = (word.confidence < 0.5) ? lowConfAttrs : normalAttrs;
                word.textRange = NSMakeRange(textPos, word.text.length);

                NSMutableDictionary *wordAttrs = [attrs mutableCopy];
                wordAttrs[NSToolTipAttributeName] = [NSString stringWithFormat:@"%@ - %@ (%.0f%%)",
                    SpliceKitTranscript_timecodeFromSeconds(word.startTime, self.frameRate),
                    SpliceKitTranscript_timecodeFromSeconds(word.endTime, self.frameRate),
                    word.confidence * 100];
                wordAttrs[FCPAttrWordIndex] = @(i);

                [attrStr appendAttributedString:[[NSAttributedString alloc]
                    initWithString:word.text attributes:wordAttrs]];
                textPos += word.text.length;
            }
        }
    }

    [self.textView.textStorage setAttributedString:attrStr];
    self.fullText = [attrStr string];

    if (!self.suppressPersistenceWrites && self.status == SpliceKitTranscriptStatusReady) {
        [self persistTranscriptStateForCurrentSequence];
    }

    self.suppressTextViewCallbacks = NO;

    // Re-apply search highlighting if active
    if (self.currentSearchQuery.length > 0 || ![self.currentFilter isEqualToString:@"all"]) {
        [self performSearchHighlighting];
    }
}

#pragma mark - Click Handling (Jump Playhead)

- (void)handleClickAtCharIndex:(NSUInteger)charIdx {
    if (charIdx >= self.textView.textStorage.length) return;

    // Check what type of item was clicked
    NSDictionary *attrs = [self.textView.textStorage attributesAtIndex:charIdx effectiveRange:nil];
    NSString *itemType = attrs[FCPAttrItemType];

    if ([itemType isEqualToString:@"word"]) {
        SpliceKitTranscriptWord *word = [self wordAtCharIndex:charIdx];
        if (!word) return;

        SpliceKit_log(@"[Transcript] Clicked word %lu: \"%@\" at %.2fs",
                      (unsigned long)word.wordIndex, word.text, word.startTime);

        [self setPlayheadToTime:word.startTime];
        [self highlightWordRange:NSMakeRange(word.wordIndex, 1)
                           color:[NSColor selectedTextBackgroundColor]];

    } else if ([itemType isEqualToString:@"speakerLabel"]) {
        NSString *currentName = attrs[FCPAttrSpeakerName];
        NSUInteger segStart = [attrs[FCPAttrSegmentStartIndex] unsignedIntegerValue];
        NSUInteger segEnd = [attrs[FCPAttrSegmentEndIndex] unsignedIntegerValue];
        if (currentName) {
            [self showSpeakerRenamePopoverForSpeaker:currentName
                                        segmentStart:segStart
                                          segmentEnd:segEnd
                                         atCharIndex:charIdx];
        }

    } else if ([itemType isEqualToString:@"silence"]) {
        NSNumber *silenceIdx = attrs[FCPAttrSilenceIndex];
        if (silenceIdx && silenceIdx.unsignedIntegerValue < self.mutableSilences.count) {
            SpliceKitTranscriptSilence *silence = self.mutableSilences[silenceIdx.unsignedIntegerValue];
            SpliceKit_log(@"[Transcript] Clicked silence at %.2fs (%.1fs duration)",
                          silence.startTime, silence.duration);
            [self setPlayheadToTime:silence.startTime];
        }
    }
}

- (SpliceKitTranscriptWord *)wordAtCharIndex:(NSUInteger)charIdx {
    @synchronized (self.mutableWords) {
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            if (charIdx >= word.textRange.location &&
                charIdx < NSMaxRange(word.textRange)) {
                return word;
            }
        }
    }
    return nil;
}

#pragma mark - Speaker Rename Popover

- (void)showSpeakerRenamePopoverForSpeaker:(NSString *)currentName
                              segmentStart:(NSUInteger)segStart
                                segmentEnd:(NSUInteger)segEnd
                               atCharIndex:(NSUInteger)charIdx {

    // Build the popover content view
    NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 80)];

    // Text field for new name
    NSTextField *nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 44, 256, 24)];
    nameField.stringValue = currentName;
    nameField.placeholderString = @"Enter speaker name...";
    nameField.font = [NSFont systemFontOfSize:13];
    nameField.bezelStyle = NSTextFieldRoundedBezel;
    [nameField selectText:nil];
    [contentView addSubview:nameField];

    // "Rename all" checkbox
    NSButton *renameAllCheckbox = [NSButton checkboxWithTitle:
        [NSString stringWithFormat:@"Rename all \"%@\" instances", currentName]
                                                      target:nil action:nil];
    renameAllCheckbox.frame = NSMakeRect(12, 12, 200, 20);
    renameAllCheckbox.font = [NSFont systemFontOfSize:11];
    renameAllCheckbox.state = NSControlStateValueOn;
    [contentView addSubview:renameAllCheckbox];

    // Apply button
    NSButton *applyButton = [NSButton buttonWithTitle:@"Rename" target:nil action:nil];
    applyButton.frame = NSMakeRect(214, 8, 56, 28);
    applyButton.bezelStyle = NSBezelStyleRounded;
    applyButton.keyEquivalent = @"\r"; // Enter key
    [contentView addSubview:applyButton];

    // Create popover
    NSPopover *popover = [[NSPopover alloc] init];
    popover.behavior = NSPopoverBehaviorTransient;
    popover.contentSize = NSMakeSize(280, 80);

    NSViewController *vc = [[NSViewController alloc] init];
    vc.view = contentView;
    popover.contentViewController = vc;

    // Wire up the apply action
    applyButton.target = self;
    applyButton.action = @selector(_speakerRenameApply:);

    // Store context for the action via objc_setAssociatedObject
    objc_setAssociatedObject(applyButton, "nameField", nameField, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(applyButton, "renameAll", renameAllCheckbox, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(applyButton, "oldName", currentName, OBJC_ASSOCIATION_COPY);
    objc_setAssociatedObject(applyButton, "segStart", @(segStart), OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(applyButton, "segEnd", @(segEnd), OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(applyButton, "popover", popover, OBJC_ASSOCIATION_RETAIN);

    // Show popover relative to the clicked text
    NSRange glyphRange = [self.textView.layoutManager glyphRangeForCharacterRange:NSMakeRange(charIdx, 1) actualCharacterRange:nil];
    NSRect rect = [self.textView.layoutManager boundingRectForGlyphRange:glyphRange inTextContainer:self.textView.textContainer];
    rect.origin.x += self.textView.textContainerOrigin.x;
    rect.origin.y += self.textView.textContainerOrigin.y;

    [popover showRelativeToRect:rect ofView:self.textView preferredEdge:NSMaxYEdge];

    // Focus the text field
    dispatch_async(dispatch_get_main_queue(), ^{
        [nameField selectText:nil];
        [nameField.window makeFirstResponder:nameField];
    });
}

- (void)_speakerRenameApply:(NSButton *)sender {
    NSTextField *nameField = objc_getAssociatedObject(sender, "nameField");
    NSButton *renameAllCheckbox = objc_getAssociatedObject(sender, "renameAll");
    NSString *oldName = objc_getAssociatedObject(sender, "oldName");
    NSNumber *segStartNum = objc_getAssociatedObject(sender, "segStart");
    NSNumber *segEndNum = objc_getAssociatedObject(sender, "segEnd");
    NSPopover *popover = objc_getAssociatedObject(sender, "popover");

    NSString *newName = nameField.stringValue;
    if (newName.length == 0 || [newName isEqualToString:oldName]) {
        [popover close];
        return;
    }

    BOOL renameAll = (renameAllCheckbox.state == NSControlStateValueOn);

    @synchronized (self.mutableWords) {
        if (renameAll) {
            // Rename all words with this speaker name
            for (SpliceKitTranscriptWord *word in self.mutableWords) {
                if ([word.speaker isEqualToString:oldName]) {
                    word.speaker = newName;
                }
            }
            SpliceKit_log(@"[Transcript] Renamed all \"%@\" -> \"%@\"", oldName, newName);
        } else {
            // Rename only this segment
            NSUInteger start = segStartNum.unsignedIntegerValue;
            NSUInteger end = segEndNum.unsignedIntegerValue;
            for (NSUInteger i = start; i <= end && i < self.mutableWords.count; i++) {
                self.mutableWords[i].speaker = newName;
            }
            SpliceKit_log(@"[Transcript] Renamed segment %lu-%lu \"%@\" -> \"%@\"",
                (unsigned long)start, (unsigned long)end, oldName, newName);
        }
    }

    [popover close];
    [self rebuildTextView];
}

#pragma mark - Delete Words (Text-Based Editing)

- (void)handleDeleteKeyInTextView {
    NSRange selectedRange = self.textView.selectedRange;
    if (selectedRange.length == 0) {
        NSBeep();
        return;
    }

    // Find all words that overlap with the selection
    NSMutableIndexSet *wordIndices = [NSMutableIndexSet indexSet];
    @synchronized (self.mutableWords) {
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            NSRange intersection = NSIntersectionRange(selectedRange, word.textRange);
            if (intersection.length > 0) {
                [wordIndices addIndex:word.wordIndex];
            }
        }
    }

    // Also check if any silences are fully selected (for deleting pauses)
    NSMutableArray<SpliceKitTranscriptSilence *> *selectedSilences = [NSMutableArray array];
    for (SpliceKitTranscriptSilence *silence in self.mutableSilences) {
        NSRange intersection = NSIntersectionRange(selectedRange, silence.textRange);
        if (intersection.length > 0) {
            [selectedSilences addObject:silence];
        }
    }

    if (wordIndices.count == 0 && selectedSilences.count == 0) {
        NSBeep();
        return;
    }

    // If only silences selected (no words), delete those silence segments
    if (wordIndices.count == 0 && selectedSilences.count > 0) {
        [self updateStatusUI:@"Deleting pauses..."];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            // Delete from end to start to avoid position shifts
            NSArray *sorted = [selectedSilences sortedArrayUsingComparator:^NSComparisonResult(SpliceKitTranscriptSilence *a, SpliceKitTranscriptSilence *b) {
                return (a.startTime > b.startTime) ? NSOrderedAscending : NSOrderedDescending;
            }];
            double totalRemoved = 0;
            for (SpliceKitTranscriptSilence *silence in sorted) {
                // Adjust for already-removed time
                double adjStart = silence.startTime - totalRemoved;
                double adjEnd = silence.endTime - totalRemoved;
                [self deleteTimelineRange:adjStart end:adjEnd];
                double removed = silence.duration;
                totalRemoved += removed;

                // Shift all words after this silence earlier
                @synchronized (self.mutableWords) {
                    for (SpliceKitTranscriptWord *word in self.mutableWords) {
                        if (word.startTime > silence.startTime - (totalRemoved - removed)) {
                            word.startTime -= removed;
                        }
                    }
                }
            }

            [self detectSilences];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self rebuildTextView];
                self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);
                [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses",
                    (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSilences.count]];
            });
        });
        return;
    }

    NSUInteger startIdx = wordIndices.firstIndex;
    NSUInteger count = wordIndices.lastIndex - wordIndices.firstIndex + 1;

    SpliceKit_log(@"[Transcript] Deleting %lu words starting at index %lu",
                  (unsigned long)count, (unsigned long)startIdx);

    NSDictionary *result = [self deleteWordsFromIndex:startIdx count:count];
    SpliceKit_log(@"[Transcript] Delete result: %@", result);
}

#pragma mark - Drag & Drop Word Reordering

- (NSRange)selectedWordRange {
    NSRange sel = self.textView.selectedRange;
    if (sel.length == 0) return NSMakeRange(0, 0);

    NSMutableIndexSet *wordIndices = [NSMutableIndexSet indexSet];
    @synchronized (self.mutableWords) {
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            NSRange intersection = NSIntersectionRange(sel, word.textRange);
            if (intersection.length > 0) {
                [wordIndices addIndex:word.wordIndex];
            }
        }
    }

    if (wordIndices.count == 0) return NSMakeRange(0, 0);

    NSUInteger first = wordIndices.firstIndex;
    NSUInteger last = wordIndices.lastIndex;
    return NSMakeRange(first, last - first + 1);
}

- (NSUInteger)wordIndexAtCharIndex:(NSUInteger)charIdx {
    @synchronized (self.mutableWords) {
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            if (charIdx <= word.textRange.location) {
                return word.wordIndex;
            }
            if (charIdx < NSMaxRange(word.textRange)) {
                NSUInteger midpoint = word.textRange.location + word.textRange.length / 2;
                if (charIdx <= midpoint) {
                    return word.wordIndex;
                } else {
                    return word.wordIndex + 1;
                }
            }
        }
    }
    return self.mutableWords.count;
}

- (void)handleDropOfWordStart:(NSUInteger)srcStart count:(NSUInteger)srcCount atCharIndex:(NSUInteger)charIdx {
    NSUInteger destWordIdx = [self wordIndexAtCharIndex:charIdx];

    if (destWordIdx >= srcStart && destWordIdx <= srcStart + srcCount) {
        SpliceKit_log(@"[Transcript] Drop at same position — no-op");
        return;
    }

    SpliceKit_log(@"[Transcript] Drag-drop: words %lu-%lu -> before word %lu",
                  (unsigned long)srcStart, (unsigned long)(srcStart + srcCount - 1),
                  (unsigned long)destWordIdx);

    [self updateStatusUI:@"Moving clips on timeline..."];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = [self moveWordsFromIndex:srcStart count:srcCount toIndex:destWordIdx];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result[@"error"]) {
                [self updateStatusUI:[NSString stringWithFormat:@"Move failed: %@", result[@"error"]]];
                SpliceKit_log(@"[Transcript] Move error: %@", result[@"error"]);
            } else {
                [self updateStatusUI:[NSString stringWithFormat:@"Moved %lu word(s)", (unsigned long)srcCount]];
                SpliceKit_log(@"[Transcript] Move succeeded: %@", result);
            }
        });
    });
}

#pragma mark - Playhead Sync
// A 100ms timer that reads FCP's current playhead position and highlights the
// corresponding word in the transcript. Uses three different selector fallbacks
// (currentSequenceTime, playheadTime, playheadSequenceTime) because different
// FCP versions expose the playhead through different methods.
// We only update the highlight when the word changes (not every tick) and
// only clear/set the single affected range to avoid flickering the whole document.

- (void)startPlayheadTimer {
    [self stopPlayheadTimer];
    self.playheadTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                         target:self
                                                       selector:@selector(playheadTimerFired:)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)stopPlayheadTimer {
    [self.playheadTimer invalidate];
    self.playheadTimer = nil;
}

- (void)playheadTimerFired:(NSTimer *)timer {
    if (self.status != SpliceKitTranscriptStatusReady) return;
    if (self.mutableWords.count == 0) return;
    if (!self.panel.isVisible) return;

    __block double playheadTime = -1;
    @try {
        id timeline = SpliceKit_getActiveTimelineModule();
        if (!timeline) return;

        SEL currentTimeSel = NSSelectorFromString(@"currentSequenceTime");
        if ([timeline respondsToSelector:currentTimeSel]) {
            CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(
                timeline, currentTimeSel);
            double secs = SpliceKit_secondsFromTime(t);
            if (secs >= 0) playheadTime = secs;
        }

        if (playheadTime < 0 && [timeline respondsToSelector:@selector(playheadTime)]) {
            CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(
                timeline, @selector(playheadTime));
            playheadTime = SpliceKit_secondsFromTime(t);
        }

        if (playheadTime < 0) {
            id container = SpliceKit_getEditorContainer();
            SEL pstSel = NSSelectorFromString(@"playheadSequenceTime");
            if (container && [container respondsToSelector:pstSel]) {
                CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(
                    container, pstSel);
                playheadTime = SpliceKit_secondsFromTime(t);
            }
        }
    } @catch (NSException *e) {}

    if (playheadTime >= 0) {
        [self updatePlayheadHighlight:playheadTime];
    }
}

- (void)highlightWordRange:(NSRange)wordRange color:(NSColor *)color {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.mutableWords.count == 0) return;
        self.suppressTextViewCallbacks = YES;

        NSTextStorage *storage = self.textView.textStorage;
        NSUInteger end = MIN(wordRange.location + wordRange.length, self.mutableWords.count);

        for (NSUInteger i = wordRange.location; i < end; i++) {
            SpliceKitTranscriptWord *word = self.mutableWords[i];
            if (word.textRange.location + word.textRange.length <= storage.length) {
                [storage addAttribute:NSBackgroundColorAttributeName
                                value:color
                                range:word.textRange];
            }
        }

        self.suppressTextViewCallbacks = NO;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            self.suppressTextViewCallbacks = YES;
            [storage removeAttribute:NSBackgroundColorAttributeName
                               range:NSMakeRange(0, storage.length)];
            self.suppressTextViewCallbacks = NO;
        });
    });
}

#pragma mark - UI Helpers

- (void)updateStatusUI:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.stringValue = message;
    });
}

- (void)openSpeechRecognitionSettings {
    dispatch_async(dispatch_get_main_queue(), ^{
        // macOS 13+ uses the new System Settings URL scheme
        NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"];
        [[NSWorkspace sharedWorkspace] openURL:url];
    });
}

- (void)setErrorState:(NSString *)error {
    SpliceKit_log(@"[Transcript] Error: %@", error);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.status = SpliceKitTranscriptStatusError;
        self.errorMessage = error;
        [self updateStatusUI:[NSString stringWithFormat:@"Error: %@", error]];
        self.spinner.hidden = YES;
        [self.spinner stopAnimation:nil];
        self.progressBar.hidden = YES;
        self.refreshButton.enabled = YES;
        self.deleteSilencesButton.enabled = NO;
    });
}

#pragma mark - NSTextView Delegate
// We block all direct text editing — the transcript is not a regular text document.
// Insertions are always rejected. Deletions are handled by keyDown: in the custom
// text view subclass, which calls handleDeleteKeyInTextView instead.

- (BOOL)textView:(NSTextView *)textView shouldChangeTextInRange:(NSRange)range
                                               replacementString:(NSString *)string {
    if (self.suppressTextViewCallbacks) return YES;
    if (string.length > 0) return NO;
    return NO; // Deletions handled by keyDown
}

@end
