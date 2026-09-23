//
//  SpliceKitLiveCam+UI.m
//  The LiveCam panel window: building the cards and controls, refreshing them from
//  state, and the control actions.
//

#import "SpliceKitLiveCam+Private.h"

@implementation SpliceKitLiveCamPanel (UI)

- (NSView *)labeledRowWithLabel:(NSString *)label control:(NSView *)control {
    NSTextField *title = [NSTextField labelWithString:label ?: @""];
    title.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    title.textColor = [NSColor colorWithWhite:0.88 alpha:0.95];
    title.alignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    control.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *row = [NSStackView stackViewWithViews:@[title, control]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.orientation = NSUserInterfaceLayoutOrientationVertical;
    row.spacing = 4.0;
    row.alignment = NSLayoutAttributeCenterX;
    row.distribution = NSStackViewDistributionGravityAreas;
    row.detachesHiddenViews = YES;
    return row;
}

- (NSView *)sliderRowWithLabel:(NSString *)label slider:(NSSlider *)slider {
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider.heightAnchor constraintEqualToConstant:20.0].active = YES;
    return [self labeledRowWithLabel:label control:slider];
}

- (NSView *)centeredViewRow:(NSView *)view {
    NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.centerXAnchor constraintEqualToAnchor:row.centerXAnchor],
        [view.topAnchor constraintEqualToAnchor:row.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [view.leadingAnchor constraintGreaterThanOrEqualToAnchor:row.leadingAnchor],
        [view.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor],
    ]];
    return row;
}

- (NSSlider *)configuredSliderWithValue:(double)value
                               minValue:(double)minValue
                               maxValue:(double)maxValue {
    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    slider.minValue = minValue;
    slider.maxValue = maxValue;
    slider.doubleValue = value;
    slider.target = self;
    slider.action = @selector(adjustmentSliderChanged:);
    return slider;
}

- (NSView *)sectionCardWithTitle:(NSString *)title
                            rows:(NSArray<NSView *> *)rows
                       titleColor:(NSColor *)titleColor {
    NSView *card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 10.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.08] CGColor];
    card.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:0.15 alpha:0.97] CGColor];

    // Uppercase small-caps title, kerned, muted color. Matches the FCP
    // Inspector / modern Apple pro-app style and drops the colored tints
    // the old design used for each section.
    NSTextField *titleLabel = [NSTextField labelWithString:@""];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.alignment = NSTextAlignmentCenter;
    NSString *upper = [(title ?: @"") uppercaseString];
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:upper];
    [attr addAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
        NSKernAttributeName: @(1.2),
        NSParagraphStyleAttributeName: paragraph,
    } range:NSMakeRange(0, attr.length)];
    titleLabel.attributedStringValue = attr;
    (void)titleColor; // intentionally ignored — consistent uppercase label color

    NSStackView *stack = [NSStackView stackViewWithViews:rows ?: @[]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 5.0;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.detachesHiddenViews = YES;

    [card addSubview:titleLabel];
    [card addSubview:stack];

    // Stack's bottom uses `lessThanOrEqual` so when the card is forced to a
    // height larger than its natural content (e.g. the parent NSStackView
    // equalizes all 4 cards to the tallest one), the inner content stays
    // packed at the top and the extra space sits at the bottom of the card.
    // Without this, NSStackView's default gravity distribution spreads the
    // rows apart to fill the card, which is what made Camera sit at the
    // top and Resolution/Frame Rate/Quality drift to the bottom.
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8.0],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:8.0],

        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8.0],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8.0],
        [stack.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8.0],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-8.0],
    ]];

    return card;
}

- (NSTextField *)wrappingInfoLabelWithText:(NSString *)text {
    NSTextField *label = [NSTextField wrappingLabelWithString:text ?: @""];
    label.font = [NSFont systemFontOfSize:12];
    label.textColor = [NSColor colorWithWhite:0.77 alpha:0.95];
    label.maximumNumberOfLines = 3;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (void)setupPanelIfNeeded {
    if (self.panel) return;

    NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
    NSRect frame = NSMakeRect(NSMidX(screenFrame) - 390.0,
                              NSMidY(screenFrame) - 410.0,
                              780.0,
                              820.0);
    self.panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:(NSWindowStyleMaskTitled |
                                                       NSWindowStyleMaskClosable |
                                                       NSWindowStyleMaskUtilityWindow)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"LiveCam";
    self.panel.floatingPanel = YES;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.hidesOnDeactivate = NO;
    self.panel.releasedWhenClosed = NO;
    self.panel.minSize = NSMakeSize(760.0, 560.0);
    self.panel.contentMinSize = NSMakeSize(760.0, 560.0);
    // Cap the max height at what fits on this display rather than a fixed
    // 940pt — on a MacBook's visible area the old cap would run the panel
    // off-screen the moment Advanced Controls were opened.
    CGFloat maxPanelHeight = MAX(640.0, screenFrame.size.height - 40.0);
    self.panel.maxSize = NSMakeSize(920.0, maxPanelHeight);
    self.panel.contentMaxSize = NSMakeSize(920.0, maxPanelHeight);
    self.panel.styleMask |= NSWindowStyleMaskResizable;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorCanJoinAllSpaces;
    self.panel.delegate = self;

    NSView *background = [[NSView alloc] initWithFrame:self.panel.contentView.bounds];
    background.translatesAutoresizingMaskIntoConstraints = NO;
    background.wantsLayer = YES;
    background.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:0.11 alpha:0.985] CGColor];
    [self.panel.contentView addSubview:background];

    NSImageView *titleIconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    titleIconView.translatesAutoresizingMaskIntoConstraints = NO;
    titleIconView.imageScaling = NSImageScaleProportionallyDown;
    titleIconView.image = [NSImage imageWithSystemSymbolName:@"camera.fill"
                                    accessibilityDescription:@"LiveCam"];
    if (titleIconView.image) {
        titleIconView.contentTintColor = [NSColor colorWithWhite:0.92 alpha:0.96];
    }

    NSTextField *titleLabel = [NSTextField labelWithString:@"LiveCam"];
    titleLabel.font = [NSFont systemFontOfSize:24 weight:NSFontWeightBold];
    titleLabel.textColor = [NSColor labelColor];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.presetLabel = [NSTextField labelWithString:@""];
    self.presetLabel.hidden = YES;

    self.sessionLabel = [NSTextField labelWithString:@"Ready"];
    self.sessionLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    self.sessionLabel.textColor = [NSColor colorWithWhite:0.84 alpha:0.88];
    self.sessionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.sessionLabel.alignment = NSTextAlignmentRight;
    self.sessionLabel.maximumNumberOfLines = 1;

    self.permissionButton = [NSButton buttonWithTitle:@"Allow Camera…"
                                               target:self
                                               action:@selector(permissionButtonClicked:)];
    self.permissionButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.permissionButton.bezelStyle = NSBezelStyleRounded;
    self.permissionButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.permissionButton.hidden = YES;

    NSStackView *titleCluster = [NSStackView stackViewWithViews:@[titleIconView, titleLabel]];
    titleCluster.translatesAutoresizingMaskIntoConstraints = NO;
    titleCluster.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    titleCluster.spacing = 8.0;
    titleCluster.alignment = NSLayoutAttributeCenterY;
    titleCluster.detachesHiddenViews = YES;

    NSView *header = [[NSView alloc] initWithFrame:NSZeroRect];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:titleCluster];
    [header addSubview:self.permissionButton];
    [header addSubview:self.sessionLabel];

    NSView *previewContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    previewContainer.translatesAutoresizingMaskIntoConstraints = NO;
    previewContainer.wantsLayer = YES;
    previewContainer.layer.backgroundColor = [[NSColor blackColor] CGColor];
    previewContainer.layer.cornerRadius = 16.0;
    previewContainer.layer.borderWidth = 1.0;
    previewContainer.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.08] CGColor];
    previewContainer.layer.masksToBounds = YES;

    self.previewView = [[MTKView alloc] initWithFrame:NSZeroRect device:self.renderer.metalDevice];
    self.previewView.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewView.enableSetNeedsDisplay = YES;
    self.previewView.paused = YES;
    self.previewView.delegate = self;
    self.previewView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    self.previewView.framebufferOnly = NO;
    self.previewView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    [previewContainer addSubview:self.previewView];

    self.statusLabel = [self wrappingInfoLabelWithText:@"Preview will start after camera permission is granted."];
    self.statusLabel.font = [NSFont systemFontOfSize:12];
    self.statusLabel.textColor = [NSColor colorWithWhite:0.76 alpha:0.96];
    self.statusLabel.maximumNumberOfLines = 1;
    self.statusLabel.alignment = NSTextAlignmentCenter;

    // contentHost was the old wrapper view; the scroll view now owns layout.
    // Declaration kept out of the tree below.

    self.lookCategoryPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.lookCategoryPopup.target = self;
    self.lookCategoryPopup.action = @selector(lookCategoryChanged:);

    self.lookPresetPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.lookPresetPopup.target = self;
    self.lookPresetPopup.action = @selector(lookPresetChanged:);

    self.lookDescriptionLabel = [self wrappingInfoLabelWithText:@"Natural camera image with no stylized treatment."];
    self.lookDescriptionLabel.textColor = [NSColor secondaryLabelColor];
    self.lookDescriptionLabel.alignment = NSTextAlignmentCenter;

    self.timestampOverlayCheckbox = [NSButton checkboxWithTitle:@"Date/Time Stamp"
                                                           target:self
                                                           action:@selector(timestampOverlayChanged:)];
    self.timestampOverlayCheckbox.controlSize = NSControlSizeSmall;

    self.backgroundModePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.backgroundModePopup addItemWithTitle:@"None"];
    self.backgroundModePopup.lastItem.representedObject = @"none";
    [self.backgroundModePopup addItemWithTitle:@"Blur"];
    self.backgroundModePopup.lastItem.representedObject = @"blur";
    [self.backgroundModePopup addItemWithTitle:@"Green Screen"];
    self.backgroundModePopup.lastItem.representedObject = @"greenScreen";
    self.backgroundModePopup.target = self;
    self.backgroundModePopup.action = @selector(backgroundModeChanged:);

    self.backgroundColorPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.backgroundColorPopup addItemWithTitle:@"Green"];
    self.backgroundColorPopup.lastItem.representedObject = @"green";
    [self.backgroundColorPopup addItemWithTitle:@"Blue"];
    self.backgroundColorPopup.lastItem.representedObject = @"blue";
    [self.backgroundColorPopup addItemWithTitle:@"Transparent"];
    self.backgroundColorPopup.lastItem.representedObject = @"transparent";
    self.backgroundColorPopup.target = self;
    self.backgroundColorPopup.action = @selector(configurationChanged:);

    self.backgroundEdgeSlider = [self configuredSliderWithValue:0.25 minValue:0.0 maxValue:1.0];
    // Defaults are tuned to clean up the typical Vision overcut without manual tweaking.
    self.backgroundRefinementSlider = [self configuredSliderWithValue:0.0 minValue:-1.0 maxValue:1.0];
    self.backgroundChokeSlider = [self configuredSliderWithValue:0.20 minValue:-1.0 maxValue:1.0];
    self.backgroundSpillSlider = [self configuredSliderWithValue:0.55 minValue:0.0 maxValue:1.0];
    self.backgroundWrapSlider = [self configuredSliderWithValue:0.0 minValue:0.0 maxValue:1.0];

    self.backgroundQualityPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.backgroundQualityPopup addItemWithTitle:@"Fast"];
    self.backgroundQualityPopup.lastItem.representedObject = @"fast";
    [self.backgroundQualityPopup addItemWithTitle:@"Balanced"];
    self.backgroundQualityPopup.lastItem.representedObject = @"balanced";
    [self.backgroundQualityPopup addItemWithTitle:@"Accurate"];
    self.backgroundQualityPopup.lastItem.representedObject = @"accurate";
    self.backgroundQualityPopup.target = self;
    self.backgroundQualityPopup.action = @selector(backgroundQualityChanged:);
    self.backgroundInfoLabel = [self wrappingInfoLabelWithText:@"Choose a background treatment for the live camera feed."];
    self.backgroundStatusLabel = [self wrappingInfoLabelWithText:@""];
    self.backgroundStatusLabel.textColor = [NSColor tertiaryLabelColor];
    self.backgroundStatusLabel.maximumNumberOfLines = 2;
    self.backgroundStatusLabel.alignment = NSTextAlignmentCenter;
    self.openVideoEffectsButton = [NSButton buttonWithTitle:@"Open Video Effects"
                                                     target:self
                                                     action:@selector(openVideoEffects:)];
    self.openVideoEffectsButton.bezelStyle = NSBezelStyleRounded;
    self.openVideoEffectsButton.toolTip = @"Opens the macOS Video Effects menu for Portrait blur, Center Stage, and Studio Light.";

    self.cameraPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.cameraPopup.target = self;
    self.cameraPopup.action = @selector(deviceSelectionChanged:);

    self.microphonePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.microphonePopup.target = self;
    self.microphonePopup.action = @selector(deviceSelectionChanged:);

    self.resolutionPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.resolutionPopup addItemWithTitle:@"1280x720"];
    self.resolutionPopup.lastItem.representedObject = @"1280x720";
    [self.resolutionPopup addItemWithTitle:@"1920x1080"];
    self.resolutionPopup.lastItem.representedObject = @"1920x1080";
    [self.resolutionPopup addItemWithTitle:@"640x480"];
    self.resolutionPopup.lastItem.representedObject = @"640x480";
    self.resolutionPopup.target = self;
    self.resolutionPopup.action = @selector(configurationChanged:);

    self.frameRatePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSNumber *fps in @[@24, @30, @60]) {
        [self.frameRatePopup addItemWithTitle:[NSString stringWithFormat:@"%@ fps", fps]];
        self.frameRatePopup.lastItem.representedObject = fps;
    }
    self.frameRatePopup.target = self;
    self.frameRatePopup.action = @selector(configurationChanged:);

    self.qualityPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.qualityPopup addItemWithTitle:@"Fast H.264"];
    self.qualityPopup.lastItem.representedObject = @"fast";
    [self.qualityPopup addItemWithTitle:@"Balanced H.264"];
    self.qualityPopup.lastItem.representedObject = @"balanced";
    [self.qualityPopup addItemWithTitle:@"High H.264"];
    self.qualityPopup.lastItem.representedObject = @"high";
    self.qualityPopup.target = self;
    self.qualityPopup.action = @selector(configurationChanged:);

    self.mirrorCheckbox = [NSButton checkboxWithTitle:@"Mirror preview"
                                               target:self
                                               action:@selector(configurationChanged:)];
    self.muteCheckbox = [NSButton checkboxWithTitle:@"Mute audio"
                                             target:self
                                             action:@selector(configurationChanged:)];

    self.audioMeter = [[SpliceKitLiveCamAudioMeterView alloc] initWithFrame:NSZeroRect];
    [self.audioMeter.heightAnchor constraintEqualToConstant:46.0].active = YES;

    self.destinationControl = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    self.destinationControl.segmentCount = 2;
    [self.destinationControl setLabel:@"Library" forSegment:0];
    [self.destinationControl setLabel:@"Timeline" forSegment:1];
    self.destinationControl.trackingMode = NSSegmentSwitchTrackingSelectOne;
    self.destinationControl.target = self;
    self.destinationControl.action = @selector(destinationChanged:);
    self.destinationControl.selectedSegment = 0;

    self.timelinePlacementPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.timelinePlacementPopup addItemWithTitle:@"Append"];
    [self.timelinePlacementPopup addItemWithTitle:@"At Playhead"];
    [self.timelinePlacementPopup addItemWithTitle:@"Connected Above"];
    self.timelinePlacementPopup.target = self;
    self.timelinePlacementPopup.action = @selector(configurationChanged:);
    self.destinationHintLabel = [self wrappingInfoLabelWithText:@"Fallback: Library if placement fails."];
    self.destinationHintLabel.textColor = [NSColor tertiaryLabelColor];
    self.destinationHintLabel.alignment = NSTextAlignmentCenter;

    self.clipNameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.clipNameField.placeholderString = @"Optional clip name";
    self.clipNameField.delegate = self;

    self.eventNameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.eventNameField.placeholderString = @"Current Event";
    self.eventNameField.delegate = self;
    self.nameHintLabel = [self wrappingInfoLabelWithText:@"Auto name: LiveCam_YYYYMMDD_HHMMSS"];
    self.nameHintLabel.textColor = [NSColor tertiaryLabelColor];

    self.intensitySlider = [self configuredSliderWithValue:self.adjustments.intensity minValue:0.0 maxValue:1.5];
    self.exposureSlider = [self configuredSliderWithValue:self.adjustments.exposure minValue:-1.0 maxValue:1.0];
    self.contrastSlider = [self configuredSliderWithValue:self.adjustments.contrast minValue:0.5 maxValue:1.8];
    self.saturationSlider = [self configuredSliderWithValue:self.adjustments.saturation minValue:0.0 maxValue:2.0];
    self.temperatureSlider = [self configuredSliderWithValue:self.adjustments.temperature minValue:-1.0 maxValue:1.0];
    self.sharpnessSlider = [self configuredSliderWithValue:self.adjustments.sharpness minValue:0.0 maxValue:1.5];
    self.glowSlider = [self configuredSliderWithValue:self.adjustments.glow minValue:0.0 maxValue:1.5];

    self.recordButton = [NSButton buttonWithTitle:@"Record"
                                           target:self
                                           action:@selector(recordClicked:)];
    self.recordButton.bezelStyle = NSBezelStyleRounded;
    self.recordButton.bezelColor = [NSColor systemRedColor];
    self.recordButton.contentTintColor = [NSColor whiteColor];
    self.recordButton.font = [NSFont systemFontOfSize:13 weight:NSFontWeightBold];

    self.stopButton = [NSButton buttonWithTitle:@"Stop"
                                         target:self
                                         action:@selector(stopClicked:)];
    self.stopButton.bezelStyle = NSBezelStyleRounded;
    self.stopButton.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.stopButton.enabled = NO;

    self.elapsedLabel = [NSTextField labelWithString:@"00:00:00"];
    self.elapsedLabel.font = [NSFont monospacedDigitSystemFontOfSize:16 weight:NSFontWeightSemibold];
    self.elapsedLabel.textColor = [NSColor labelColor];

    NSStackView *recordButtons = [NSStackView stackViewWithViews:@[self.recordButton, self.stopButton]];
    recordButtons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    recordButtons.spacing = 10.0;
    recordButtons.alignment = NSLayoutAttributeCenterY;

    NSStackView *transportCluster = [NSStackView stackViewWithViews:@[
        self.elapsedLabel,
        recordButtons,
    ]];
    transportCluster.translatesAutoresizingMaskIntoConstraints = NO;
    transportCluster.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    transportCluster.alignment = NSLayoutAttributeCenterY;
    transportCluster.spacing = 14.0;
    transportCluster.detachesHiddenViews = YES;

    NSView *transportRow = [[NSView alloc] initWithFrame:NSZeroRect];
    transportRow.translatesAutoresizingMaskIntoConstraints = NO;
    [transportRow addSubview:transportCluster];

    // Four-card layout matching the reference design:
    //   Video | Audio | Look | Extras
    // Each card sizes to its own content height (no more equal-height
    // constraint), so sparse cards don't inherit the Extras card's green-
    // screen slider stack.

    NSArray<NSView *> *videoRows = @[
        [self labeledRowWithLabel:@"Camera" control:self.cameraPopup],
        [self labeledRowWithLabel:@"Resolution" control:self.resolutionPopup],
        [self labeledRowWithLabel:@"Frame Rate" control:self.frameRatePopup],
        [self labeledRowWithLabel:@"Quality" control:self.qualityPopup],
    ];

    NSArray<NSView *> *audioRows = @[
        [self labeledRowWithLabel:@"Microphone" control:self.microphonePopup],
        [self centeredViewRow:self.audioMeter],
    ];

    NSArray<NSView *> *lookRows = @[
        [self labeledRowWithLabel:@"Category" control:self.lookCategoryPopup],
        [self labeledRowWithLabel:@"Preset" control:self.lookPresetPopup],
        [self centeredViewRow:self.lookDescriptionLabel],
        [self centeredViewRow:self.timestampOverlayCheckbox],
    ];

    // Green-screen-specific keying rows. These used to live inside the Extras
    // card, but that made Extras balloon to ~15 rows in green-screen mode
    // while Video/Audio/Look had 2–4 rows each, breaking the 4-card row's
    // uniform-grid look. Now they live at the bottom of the Advanced section
    // and their visibility is toggled by refreshBackgroundUI.
    self.backgroundColorRow = [self labeledRowWithLabel:@"Color" control:self.backgroundColorPopup];
    self.backgroundEdgeRow = [self sliderRowWithLabel:@"Edge Softness" slider:self.backgroundEdgeSlider];
    NSView *backgroundRefinementRow = [self sliderRowWithLabel:@"Refinement" slider:self.backgroundRefinementSlider];
    NSView *backgroundChokeRow = [self sliderRowWithLabel:@"Choke" slider:self.backgroundChokeSlider];
    NSView *backgroundSpillRow = [self sliderRowWithLabel:@"Spill" slider:self.backgroundSpillSlider];
    NSView *backgroundWrapRow = [self sliderRowWithLabel:@"Light Wrap" slider:self.backgroundWrapSlider];
    NSView *backgroundQualityRow = [self labeledRowWithLabel:@"Quality" control:self.backgroundQualityPopup];

    self.timelinePlacementRow = [self labeledRowWithLabel:@"Placement" control:self.timelinePlacementPopup];

    // Thin divider separating Background-group controls from Destination-
    // group controls inside the Extras card.
    NSBox *extrasDivider = [[NSBox alloc] initWithFrame:NSZeroRect];
    extrasDivider.boxType = NSBoxCustom;
    extrasDivider.borderWidth = 0;
    extrasDivider.fillColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.08];
    extrasDivider.translatesAutoresizingMaskIntoConstraints = NO;
    [extrasDivider.heightAnchor constraintEqualToConstant:1.0].active = YES;

    NSArray<NSView *> *extrasRows = @[
        [self labeledRowWithLabel:@"Background" control:self.backgroundModePopup],
        [self centeredViewRow:self.backgroundStatusLabel],
        [self centeredViewRow:self.openVideoEffectsButton],
        extrasDivider,
        [self labeledRowWithLabel:@"Record To" control:self.destinationControl],
        self.timelinePlacementRow,
        [self centeredViewRow:self.destinationHintLabel],
    ];

    // --- Advanced section: sub-sections with uniform-width horizontal grids
    //
    // Instead of one tall vertical stack, Advanced is broken into logical
    // sub-sections (Metadata, Options, Image Adjustments, Keying), and the
    // sliders inside each sub-section are laid out in a 3-column horizontal
    // row where every column gets the same width via distribution=FillEqually.
    // That gives every slider the same on-screen width regardless of which
    // row it lives in.

    NSView *(^blankCell)(void) = ^NSView * {
        NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
        v.translatesAutoresizingMaskIntoConstraints = NO;
        return v;
    };

    NSStackView *(^rowOf)(NSArray<NSView *> *) = ^NSStackView *(NSArray<NSView *> *views) {
        NSStackView *row = [NSStackView stackViewWithViews:views];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.alignment = NSLayoutAttributeTop;
        row.spacing = 14.0;
        row.distribution = NSStackViewDistributionFillEqually;
        row.detachesHiddenViews = YES;
        return row;
    };

    NSTextField *(^subsectionHeader)(NSString *) = ^NSTextField *(NSString *text) {
        NSTextField *label = [NSTextField labelWithString:@""];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        NSString *upper = [(text ?: @"") uppercaseString];
        NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:upper];
        [attr addAttributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
            NSKernAttributeName: @(1.2),
        } range:NSMakeRange(0, attr.length)];
        label.attributedStringValue = attr;
        return label;
    };

    // Metadata: Clip Name | Event
    NSStackView *metadataRow = rowOf(@[
        [self labeledRowWithLabel:@"Clip Name" control:self.clipNameField],
        [self labeledRowWithLabel:@"Event" control:self.eventNameField],
    ]);

    // Options: Mirror preview | Mute audio
    NSStackView *optionsRow = rowOf(@[self.mirrorCheckbox, self.muteCheckbox]);

    // Image Adjustments — 3 columns × 3 rows (7 sliders + 2 blank cells).
    NSStackView *adjustRow1 = rowOf(@[
        [self sliderRowWithLabel:@"Intensity" slider:self.intensitySlider],
        [self sliderRowWithLabel:@"Exposure" slider:self.exposureSlider],
        [self sliderRowWithLabel:@"Contrast" slider:self.contrastSlider],
    ]);
    NSStackView *adjustRow2 = rowOf(@[
        [self sliderRowWithLabel:@"Saturation" slider:self.saturationSlider],
        [self sliderRowWithLabel:@"Warmth" slider:self.temperatureSlider],
        [self sliderRowWithLabel:@"Sharpness" slider:self.sharpnessSlider],
    ]);
    NSStackView *adjustRow3 = rowOf(@[
        [self sliderRowWithLabel:@"Glow" slider:self.glowSlider],
        blankCell(),
        blankCell(),
    ]);

    // Green Screen Keying sub-section. Whole group toggled by refreshBackgroundUI
    // via the enclosing NSStackView's hidden state.
    NSStackView *keyingRow1 = rowOf(@[
        self.backgroundColorRow,
        backgroundQualityRow,
        blankCell(),
    ]);
    NSStackView *keyingRow2 = rowOf(@[
        self.backgroundEdgeRow,
        backgroundRefinementRow,
        backgroundChokeRow,
    ]);
    NSStackView *keyingRow3 = rowOf(@[
        backgroundSpillRow,
        backgroundWrapRow,
        blankCell(),
    ]);

    NSStackView *keyingGroup = [NSStackView stackViewWithViews:@[
        subsectionHeader(@"Green Screen Keying"),
        keyingRow1, keyingRow2, keyingRow3,
    ]];
    keyingGroup.translatesAutoresizingMaskIntoConstraints = NO;
    keyingGroup.orientation = NSUserInterfaceLayoutOrientationVertical;
    keyingGroup.alignment = NSLayoutAttributeLeading;
    keyingGroup.spacing = 8.0;
    keyingGroup.detachesHiddenViews = YES;
    self.advancedKeyingGroup = keyingGroup;

    NSStackView *advancedLeftColumn = [NSStackView stackViewWithViews:@[
        subsectionHeader(@"Clip"),
        metadataRow,
        optionsRow,
        subsectionHeader(@"Image Adjustments"),
        adjustRow1,
        adjustRow2,
        adjustRow3,
    ]];
    advancedLeftColumn.translatesAutoresizingMaskIntoConstraints = NO;
    advancedLeftColumn.orientation = NSUserInterfaceLayoutOrientationVertical;
    advancedLeftColumn.spacing = 8.0;
    advancedLeftColumn.alignment = NSLayoutAttributeLeading;
    advancedLeftColumn.detachesHiddenViews = YES;

    NSStackView *advancedColumns = [NSStackView stackViewWithViews:@[
        advancedLeftColumn,
        keyingGroup,
    ]];
    advancedColumns.translatesAutoresizingMaskIntoConstraints = NO;
    advancedColumns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    advancedColumns.spacing = 20.0;
    advancedColumns.alignment = NSLayoutAttributeTop;
    advancedColumns.distribution = NSStackViewDistributionFillEqually;
    advancedColumns.detachesHiddenViews = YES;
    self.advancedContainer = advancedColumns;

    self.advancedToggleButton = [NSButton buttonWithTitle:@"Show Advanced Controls"
                                                   target:self
                                                   action:@selector(toggleAdvancedControls:)];
    self.advancedToggleButton.bezelStyle = NSBezelStyleRounded;
    self.advancedToggleButton.controlSize = NSControlSizeSmall;

    NSView *videoSection = [self sectionCardWithTitle:@"Video"
                                                 rows:videoRows
                                           titleColor:nil];
    NSView *audioSection = [self sectionCardWithTitle:@"Audio"
                                                 rows:audioRows
                                           titleColor:nil];
    NSView *lookSection = [self sectionCardWithTitle:@"Look"
                                                rows:lookRows
                                          titleColor:nil];
    NSView *extrasSection = [self sectionCardWithTitle:@"Extras"
                                                  rows:extrasRows
                                            titleColor:nil];
    self.advancedSectionCard = [self sectionCardWithTitle:@"Advanced"
                                                     rows:@[self.advancedContainer]
                                                titleColor:[NSColor secondaryLabelColor]];
    self.advancedSectionCard.hidden = !self.advancedVisible;
    [self.advancedContainer.widthAnchor constraintEqualToAnchor:self.advancedSectionCard.widthAnchor constant:-32.0].active = YES;

    NSView *advancedToggleRow = [[NSView alloc] initWithFrame:NSZeroRect];
    advancedToggleRow.translatesAutoresizingMaskIntoConstraints = NO;
    [advancedToggleRow addSubview:self.advancedToggleButton];

    // Drop the "Previewing with…" status line out of the layout — it reads
    // as noise. Keep the label alive (other code paths call updateStatus:
    // on it) but hide it and leave it out of the view hierarchy.
    self.statusLabel.hidden = YES;

    NSStackView *previewStack = [NSStackView stackViewWithViews:@[
        previewContainer,
        transportRow,
    ]];
    previewStack.translatesAutoresizingMaskIntoConstraints = NO;
    previewStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    previewStack.spacing = 10.0;
    previewStack.alignment = NSLayoutAttributeWidth;
    previewStack.detachesHiddenViews = YES;

    // Four settings cards in a single row, all equal width and equal height
    // (matching the tallest card). Inner content is packed at the top of
    // each card so shorter cards show a clean empty space at the bottom,
    // like the reference mock. This is what gives the grid its cohesive
    // "Apple pro-app" look.
    NSStackView *controlsGrid = [NSStackView stackViewWithViews:@[
        videoSection, audioSection, lookSection, extrasSection,
    ]];
    controlsGrid.translatesAutoresizingMaskIntoConstraints = NO;
    controlsGrid.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    controlsGrid.spacing = 12.0;
    controlsGrid.alignment = NSLayoutAttributeHeight;
    controlsGrid.distribution = NSStackViewDistributionFillEqually;
    controlsGrid.detachesHiddenViews = YES;

    // The whole content below the header lives inside an NSScrollView so
    // the preview + settings + Advanced controls scroll together when they
    // don't fit on-screen. User can open Advanced and just keep scrolling.
    NSStackView *contentStack = [NSStackView stackViewWithViews:@[
        previewStack,
        controlsGrid,
        self.advancedSectionCard,
        advancedToggleRow,
    ]];
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    contentStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    contentStack.spacing = 12.0;
    contentStack.alignment = NSLayoutAttributeWidth;
    contentStack.detachesHiddenViews = YES;
    contentStack.edgeInsets = NSEdgeInsetsMake(0, 18, 16, 18);

    // Flipped wrapper so scrolling starts from the top of the content.
    SpliceKitLiveCamFlippedView *scrollDocView = [[SpliceKitLiveCamFlippedView alloc] initWithFrame:NSZeroRect];
    scrollDocView.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollDocView addSubview:contentStack];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.drawsBackground = NO;
    scrollView.borderType = NSNoBorder;
    scrollView.documentView = scrollDocView;

    // Legacy ivar — some debug paths and refreshAdvancedUI still reference
    // it; point it at the doc view so the pointer stays valid.
    self.mainColumn = scrollDocView;

    [background addSubview:header];
    [background addSubview:scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [background.leadingAnchor constraintEqualToAnchor:self.panel.contentView.leadingAnchor],
        [background.trailingAnchor constraintEqualToAnchor:self.panel.contentView.trailingAnchor],
        [background.topAnchor constraintEqualToAnchor:self.panel.contentView.topAnchor],
        [background.bottomAnchor constraintEqualToAnchor:self.panel.contentView.bottomAnchor],

        [header.leadingAnchor constraintEqualToAnchor:background.leadingAnchor constant:18.0],
        [header.trailingAnchor constraintEqualToAnchor:background.trailingAnchor constant:-18.0],
        [header.topAnchor constraintEqualToAnchor:background.topAnchor constant:16.0],
        [header.heightAnchor constraintEqualToConstant:48.0],

        [titleCluster.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [titleCluster.topAnchor constraintEqualToAnchor:header.topAnchor],
        [titleIconView.widthAnchor constraintEqualToConstant:16.0],
        [titleIconView.heightAnchor constraintEqualToConstant:16.0],
        [self.sessionLabel.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [self.sessionLabel.centerYAnchor constraintEqualToAnchor:titleCluster.centerYAnchor],
        [self.sessionLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleCluster.trailingAnchor constant:24.0],

        [self.permissionButton.centerYAnchor constraintEqualToAnchor:self.sessionLabel.centerYAnchor],
        [self.permissionButton.trailingAnchor constraintEqualToAnchor:self.sessionLabel.leadingAnchor constant:-8.0],
        [self.permissionButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleCluster.trailingAnchor constant:16.0],

        // Scroll view fills the rest of the panel.
        [scrollView.leadingAnchor constraintEqualToAnchor:background.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:background.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:6.0],
        [scrollView.bottomAnchor constraintEqualToAnchor:background.bottomAnchor],

        // Document view matches the scroll view width so content never
        // scrolls horizontally — only vertically as needed.
        [scrollDocView.leadingAnchor constraintEqualToAnchor:scrollView.contentView.leadingAnchor],
        [scrollDocView.trailingAnchor constraintEqualToAnchor:scrollView.contentView.trailingAnchor],
        [scrollDocView.topAnchor constraintEqualToAnchor:scrollView.contentView.topAnchor],
        [scrollDocView.widthAnchor constraintEqualToAnchor:scrollView.contentView.widthAnchor],

        [contentStack.leadingAnchor constraintEqualToAnchor:scrollDocView.leadingAnchor],
        [contentStack.trailingAnchor constraintEqualToAnchor:scrollDocView.trailingAnchor],
        [contentStack.topAnchor constraintEqualToAnchor:scrollDocView.topAnchor],
        [contentStack.bottomAnchor constraintEqualToAnchor:scrollDocView.bottomAnchor],

        [previewContainer.heightAnchor constraintEqualToAnchor:previewContainer.widthAnchor multiplier:(9.0 / 16.0)],

        [self.previewView.leadingAnchor constraintEqualToAnchor:previewContainer.leadingAnchor],
        [self.previewView.trailingAnchor constraintEqualToAnchor:previewContainer.trailingAnchor],
        [self.previewView.topAnchor constraintEqualToAnchor:previewContainer.topAnchor],
        [self.previewView.bottomAnchor constraintEqualToAnchor:previewContainer.bottomAnchor],

        [transportCluster.centerXAnchor constraintEqualToAnchor:transportRow.centerXAnchor],
        [transportCluster.topAnchor constraintEqualToAnchor:transportRow.topAnchor],
        [transportCluster.bottomAnchor constraintEqualToAnchor:transportRow.bottomAnchor],

        [self.advancedToggleButton.trailingAnchor constraintEqualToAnchor:advancedToggleRow.trailingAnchor],
        [self.advancedToggleButton.topAnchor constraintEqualToAnchor:advancedToggleRow.topAnchor],
        [self.advancedToggleButton.bottomAnchor constraintEqualToAnchor:advancedToggleRow.bottomAnchor],

        // Preview, status line, and transport row each fill the content
        // width — without these they'd hug their intrinsic sizes and
        // collapse into a small cluster at the top-left of the scroll view.
        [previewContainer.widthAnchor constraintEqualToAnchor:self.mainColumn.widthAnchor constant:-36.0],
        [transportRow.widthAnchor constraintEqualToAnchor:self.mainColumn.widthAnchor constant:-36.0],

        // Four-card row and the Advanced section also fill the content width.
        [controlsGrid.widthAnchor constraintEqualToAnchor:self.mainColumn.widthAnchor constant:-36.0],
        [self.advancedSectionCard.widthAnchor constraintEqualToAnchor:self.mainColumn.widthAnchor constant:-36.0],

        // Each of the four settings cards has a small minimum so they
        // don't squash into unreadable slivers on narrow panels.
        [videoSection.widthAnchor constraintGreaterThanOrEqualToConstant:150.0],
        [audioSection.widthAnchor constraintGreaterThanOrEqualToConstant:150.0],
        [lookSection.widthAnchor constraintGreaterThanOrEqualToConstant:150.0],
        [extrasSection.widthAnchor constraintGreaterThanOrEqualToConstant:150.0],
    ]];

    [self buildPresetButtons];
    [self restoreSavedControlSelections];
    [self refreshDestinationUI];
    [self refreshBackgroundUI];
    [self refreshAdvancedUI];
    [self refreshNameHint];
    [self updateControlsForState];
}

- (void)buildPresetButtons {
    NSString *selectedCategory = self.lookCategoryPopup.selectedItem.representedObject ?: self.lookCategoryPopup.titleOfSelectedItem;
    if (selectedCategory.length == 0) {
        selectedCategory = [self selectedPreset].category ?: self.presetCategories.firstObject;
    }

    [self.lookCategoryPopup removeAllItems];
    for (NSString *category in self.presetCategories) {
        [self.lookCategoryPopup addItemWithTitle:category];
        self.lookCategoryPopup.lastItem.representedObject = category;
    }
    NSInteger categoryIndex = [self.lookCategoryPopup indexOfItemWithRepresentedObject:selectedCategory];
    [self.lookCategoryPopup selectItemAtIndex:(categoryIndex >= 0 ? categoryIndex : 0)];

    [self.lookPresetPopup removeAllItems];
    for (SpliceKitLiveCamPreset *preset in [self presetsForSelectedCategory]) {
        [self.lookPresetPopup addItemWithTitle:preset.name];
        self.lookPresetPopup.lastItem.representedObject = preset.identifier;
    }
    [self refreshPresetButtons];
}

- (void)restoreSavedControlSelections {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    NSString *savedResolution = [defaults stringForKey:kLiveCamResolutionKey] ?: @"1280x720";
    NSInteger resolutionIndex = [self.resolutionPopup indexOfItemWithRepresentedObject:savedResolution];
    [self.resolutionPopup selectItemAtIndex:(resolutionIndex >= 0 ? resolutionIndex : 0)];

    NSNumber *savedFPS = @([defaults integerForKey:kLiveCamFrameRateKey] ?: 30);
    NSInteger fpsIndex = [self.frameRatePopup indexOfItemWithRepresentedObject:savedFPS];
    [self.frameRatePopup selectItemAtIndex:(fpsIndex >= 0 ? fpsIndex : 1)];

    NSString *savedQuality = [defaults stringForKey:kLiveCamQualityKey] ?: @"balanced";
    NSInteger qualityIndex = [self.qualityPopup indexOfItemWithRepresentedObject:savedQuality];
    [self.qualityPopup selectItemAtIndex:(qualityIndex >= 0 ? qualityIndex : 1)];

    NSInteger savedDestination = [defaults integerForKey:kLiveCamDestinationKey];
    self.destinationControl.selectedSegment = (savedDestination == 1) ? 1 : 0;

    NSInteger savedPlacement = [defaults integerForKey:kLiveCamPlacementKey];
    if (savedPlacement < 0 || savedPlacement > 2) savedPlacement = 0;
    [self.timelinePlacementPopup selectItemAtIndex:savedPlacement];

    NSInteger savedBackgroundMode = [defaults integerForKey:kLiveCamBackgroundModeKey];
    if (savedBackgroundMode < 0 || savedBackgroundMode > 2) savedBackgroundMode = 0;
    [self.backgroundModePopup selectItemAtIndex:savedBackgroundMode];

    NSString *savedBackgroundColor = [defaults stringForKey:kLiveCamBackgroundColorKey] ?: @"green";
    NSInteger backgroundColorIndex = [self.backgroundColorPopup indexOfItemWithRepresentedObject:savedBackgroundColor];
    [self.backgroundColorPopup selectItemAtIndex:(backgroundColorIndex >= 0 ? backgroundColorIndex : 0)];
    self.backgroundEdgeSlider.doubleValue = [defaults objectForKey:kLiveCamBackgroundEdgeSoftnessKey]
        ? [defaults doubleForKey:kLiveCamBackgroundEdgeSoftnessKey]
        : 0.25;
    self.backgroundRefinementSlider.doubleValue = [defaults objectForKey:kLiveCamBackgroundRefinementKey]
        ? [defaults doubleForKey:kLiveCamBackgroundRefinementKey]
        : 0.55;
    self.backgroundChokeSlider.doubleValue = [defaults objectForKey:kLiveCamBackgroundChokeKey]
        ? [defaults doubleForKey:kLiveCamBackgroundChokeKey]
        : 0.20;
    self.backgroundSpillSlider.doubleValue = [defaults objectForKey:kLiveCamBackgroundSpillKey]
        ? [defaults doubleForKey:kLiveCamBackgroundSpillKey]
        : 0.55;
    self.backgroundWrapSlider.doubleValue = [defaults objectForKey:kLiveCamBackgroundWrapKey]
        ? [defaults doubleForKey:kLiveCamBackgroundWrapKey]
        : 0.0;
    NSString *savedBgQuality = [defaults stringForKey:kLiveCamBackgroundQualityKey] ?: @"balanced";
    NSInteger qIdx = [self.backgroundQualityPopup indexOfItemWithRepresentedObject:savedBgQuality];
    [self.backgroundQualityPopup selectItemAtIndex:(qIdx >= 0 ? qIdx : 1)];
    SpliceKitLiveCamSegmentationQuality q = SpliceKitLiveCamSegmentationQualityBalanced;
    if ([savedBgQuality isEqualToString:@"fast"]) q = SpliceKitLiveCamSegmentationQualityFast;
    else if ([savedBgQuality isEqualToString:@"accurate"]) q = SpliceKitLiveCamSegmentationQualityAccurate;
    self.segmentationEngine.quality = q;

    self.mirrorCheckbox.state = [defaults objectForKey:kLiveCamMirrorKey]
        ? ([defaults boolForKey:kLiveCamMirrorKey] ? NSControlStateValueOn : NSControlStateValueOff)
        : NSControlStateValueOn;
    self.muteCheckbox.state = [defaults boolForKey:kLiveCamMuteKey]
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.timestampOverlayCheckbox.state = [defaults objectForKey:kLiveCamTimestampOverlayKey]
        ? ([defaults boolForKey:kLiveCamTimestampOverlayKey] ? NSControlStateValueOn : NSControlStateValueOff)
        : NSControlStateValueOn;

    self.clipNameField.stringValue = @"";
    self.eventNameField.stringValue = [defaults stringForKey:kLiveCamEventNameKey] ?: @"";

    self.intensitySlider.doubleValue = self.adjustments.intensity;
    self.exposureSlider.doubleValue = self.adjustments.exposure;
    self.contrastSlider.doubleValue = self.adjustments.contrast;
    self.saturationSlider.doubleValue = self.adjustments.saturation;
    self.temperatureSlider.doubleValue = self.adjustments.temperature;
    self.sharpnessSlider.doubleValue = self.adjustments.sharpness;
    self.glowSlider.doubleValue = self.adjustments.glow;
    if ([self.clipNameField.stringValue hasPrefix:@"CrashRecovery"]) {
        self.clipNameField.stringValue = @"";
    }
    [self buildPresetButtons];
}

- (void)refreshPresetButtons {
    NSString *selectedIdentifier = [self selectedPresetIdentifier];
    NSArray<SpliceKitLiveCamPreset *> *visiblePresets = [self presetsForSelectedCategory];
    NSInteger presetIndex = NSNotFound;
    for (NSUInteger idx = 0; idx < visiblePresets.count; idx++) {
        if ([visiblePresets[idx].identifier isEqualToString:selectedIdentifier]) {
            presetIndex = (NSInteger)idx;
            break;
        }
    }
    if (presetIndex == NSNotFound) {
        SpliceKitLiveCamPreset *selectedPreset = [self selectedPreset];
        NSInteger categoryIndex = [self.lookCategoryPopup indexOfItemWithRepresentedObject:selectedPreset.category];
        if (categoryIndex >= 0) {
            [self.lookCategoryPopup selectItemAtIndex:categoryIndex];
            visiblePresets = [self presetsForSelectedCategory];
        }
        [self.lookPresetPopup removeAllItems];
        for (SpliceKitLiveCamPreset *preset in visiblePresets) {
            [self.lookPresetPopup addItemWithTitle:preset.name];
            self.lookPresetPopup.lastItem.representedObject = preset.identifier;
        }
        for (NSUInteger idx = 0; idx < visiblePresets.count; idx++) {
            if ([visiblePresets[idx].identifier isEqualToString:selectedIdentifier]) {
                presetIndex = (NSInteger)idx;
                break;
            }
        }
    }
    [self.lookPresetPopup selectItemAtIndex:(presetIndex != NSNotFound ? presetIndex : 0)];

    SpliceKitLiveCamPreset *selectedPreset = [self selectedPreset];
    self.presetLabel.stringValue = selectedPreset.name ?: @"Clean";
    self.lookDescriptionLabel.stringValue = selectedPreset.summary.length > 0
        ? selectedPreset.summary
        : @"";
    BOOL timestampSupported = SpliceKitLiveCamPresetSupportsTimestampOverlay(selectedIdentifier);
    self.timestampOverlayCheckbox.hidden = !timestampSupported;
    self.timestampOverlayCheckbox.enabled = timestampSupported;
    self.timestampOverlayCheckbox.state = [self selectedTimestampOverlayEnabled]
        ? NSControlStateValueOn
        : NSControlStateValueOff;
}

- (void)refreshDestinationUI {
    BOOL timeline = (self.destinationControl.selectedSegment == 1);
    self.timelinePlacementRow.hidden = !timeline;
    self.destinationHintLabel.hidden = !timeline;
    self.destinationHintLabel.stringValue = timeline
        ? @"Fallback: Library if placement fails."
        : @"";
}

- (NSArray<SpliceKitLiveCamPreset *> *)presetsForSelectedCategory {
    NSString *category = self.lookCategoryPopup.selectedItem.representedObject ?: self.lookCategoryPopup.titleOfSelectedItem;
    if (category.length == 0) return self.presets;
    NSMutableArray<SpliceKitLiveCamPreset *> *matches = [NSMutableArray array];
    for (SpliceKitLiveCamPreset *preset in self.presets) {
        if ([preset.category isEqualToString:category]) {
            [matches addObject:preset];
        }
    }
    return matches.count > 0 ? matches : self.presets;
}

- (NSString *)selectedBackgroundColorKey {
    NSString *key = SpliceKitLiveCamString(self.backgroundColorPopup.selectedItem.representedObject);
    return key.length > 0 ? key : @"green";
}

- (void)refreshBackgroundEffectState {
    AVCaptureDevice *device = [self selectedVideoDevice];
    self.systemBlurSupported = NO;
    self.systemBlurActive = NO;
    self.centerStageSupported = NO;
    self.centerStageActive = NO;
    self.studioLightActive = NO;

    if (!device) return;

    if (@available(macOS 12.0, *)) {
        AVCaptureDeviceFormat *format = device.activeFormat;
        if ([format respondsToSelector:@selector(isPortraitEffectSupported)]) {
            self.systemBlurSupported = format.isPortraitEffectSupported;
        }
        self.systemBlurActive = device.isPortraitEffectActive;
    }
    if (@available(macOS 12.3, *)) {
        AVCaptureDeviceFormat *format = device.activeFormat;
        if ([format respondsToSelector:@selector(isCenterStageSupported)]) {
            self.centerStageSupported = format.isCenterStageSupported;
        }
        self.centerStageActive = device.isCenterStageActive;
    }
    if (@available(macOS 13.0, *)) {
        self.studioLightActive = device.isStudioLightActive;
    }
}

- (void)refreshBackgroundUI {
    if (!self.backgroundModePopup) return;

    [self refreshBackgroundEffectState];

    SpliceKitLiveCamBackgroundMode mode = [self selectedBackgroundMode];
    BOOL blurAvailable = self.systemBlurSupported || self.systemBlurActive;
    BOOL greenScreenAvailable = self.segmentationEngine.supported;
    [[self.backgroundModePopup itemAtIndex:1] setEnabled:blurAvailable];
    [[self.backgroundModePopup itemAtIndex:2] setEnabled:greenScreenAvailable];

    if (mode == SpliceKitLiveCamBackgroundModeSystemBlur && !blurAvailable) {
        [self.backgroundModePopup selectItemAtIndex:0];
        mode = SpliceKitLiveCamBackgroundModeNone;
    } else if (mode == SpliceKitLiveCamBackgroundModeGreenScreen && !greenScreenAvailable) {
        [self.backgroundModePopup selectItemAtIndex:0];
        mode = SpliceKitLiveCamBackgroundModeNone;
    }

    BOOL blur = (mode == SpliceKitLiveCamBackgroundModeSystemBlur);
    BOOL greenScreen = (mode == SpliceKitLiveCamBackgroundModeGreenScreen);
    BOOL showVideoEffectsButton = blur || (greenScreen && (self.systemBlurActive || self.centerStageActive || self.studioLightActive));

    self.backgroundStatusLabel.hidden = (mode == SpliceKitLiveCamBackgroundModeNone);
    self.openVideoEffectsButton.hidden = !showVideoEffectsButton;
    self.openVideoEffectsButton.enabled = blurAvailable;
    // Toggle the whole Keying sub-section inside Advanced — it lives as
    // its own NSStackView group now, so one hidden toggle collapses all
    // 7 rows rather than leaving the "empty" keying container visible.
    self.advancedKeyingGroup.hidden = !greenScreen;
    self.backgroundColorRow.hidden = !greenScreen;
    self.backgroundEdgeRow.hidden = !greenScreen;
    self.backgroundColorPopup.enabled = greenScreen;
    self.backgroundEdgeSlider.enabled = greenScreen;
    self.backgroundRefinementSlider.enabled = greenScreen;
    self.backgroundChokeSlider.enabled = greenScreen;
    self.backgroundSpillSlider.enabled = greenScreen;
    // Light wrap is a no-op in transparent mode (no background color to bleed).
    BOOL transparentKey = [[self selectedBackgroundColorKey] isEqualToString:@"transparent"];
    self.backgroundWrapSlider.enabled = greenScreen && !transparentKey;
    self.backgroundQualityPopup.enabled = greenScreen;

    if (blur) {
        self.backgroundStatusLabel.stringValue = self.systemBlurSupported
            ? @"System Portrait Effect available."
            : @"Background blur unavailable on this camera.";
    } else if (greenScreen) {
        if (self.segmentationEngine.supported) {
            NSString *colorName = [[self selectedBackgroundColorKey] isEqualToString:@"blue"] ? @"blue" : @"green";
            self.backgroundStatusLabel.stringValue = [NSString stringWithFormat:@"LiveCam subject isolation. %@ field.", colorName];
        } else {
            self.backgroundStatusLabel.stringValue = self.segmentationEngine.lastError.length > 0
                ? self.segmentationEngine.lastError
                : @"Green Screen is unavailable on this system.";
        }
    } else {
        self.backgroundStatusLabel.stringValue = @"";
    }
}

- (void)refreshAdvancedUI {
    self.advancedContainer.hidden = !self.advancedVisible;
    self.advancedSectionCard.hidden = !self.advancedVisible;
    [self.advancedToggleButton setTitle:(self.advancedVisible ? @"Hide Advanced Controls" : @"Show Advanced Controls")];
}

- (void)refreshNameHint {
    NSString *baseName = SpliceKitLiveCamTrimmedString(self.clipNameField.stringValue);
    if ([baseName hasPrefix:@"CrashRecovery"]) {
        baseName = @"";
    }
    NSString *previewBase = baseName.length > 0 ? SpliceKitLiveCamSanitizeFilename(baseName) : @"LiveCam";
    self.nameHintLabel.stringValue = [NSString stringWithFormat:@"Auto name: %@_%@", previewBase, @"YYYYMMDD_HHMMSS"];
}

- (void)postVisibilityChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:SpliceKitLiveCamVisibilityDidChangeNotification
                                                        object:self
                                                      userInfo:@{@"visible": @(self.isVisible)}];
}

- (void)updateStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.stringValue = status ?: @"";
    });
}

- (void)updateSessionLabel:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.sessionLabel.stringValue = text ?: @"";
    });
}

- (void)updateControlsForState {
    BOOL locked = self.recordingActive || self.finalizingRecording;
    self.lookCategoryPopup.enabled = !locked;
    self.lookPresetPopup.enabled = !locked;
    self.backgroundModePopup.enabled = !locked;
    self.backgroundColorPopup.enabled = !locked && self.backgroundColorRow.hidden == NO;
    self.backgroundEdgeSlider.enabled = !locked && self.backgroundEdgeRow.hidden == NO;
    BOOL bgEnabled = !locked && self.backgroundEdgeRow.hidden == NO;
    self.backgroundRefinementSlider.enabled = bgEnabled;
    self.backgroundChokeSlider.enabled = bgEnabled;
    self.backgroundSpillSlider.enabled = bgEnabled;
    self.backgroundWrapSlider.enabled = bgEnabled;
    self.backgroundQualityPopup.enabled = bgEnabled;
    self.openVideoEffectsButton.enabled = !locked && !self.openVideoEffectsButton.isHidden;
    self.advancedToggleButton.enabled = !locked;
    self.cameraPopup.enabled = !locked;
    self.microphonePopup.enabled = !locked;
    self.resolutionPopup.enabled = !locked;
    self.frameRatePopup.enabled = !locked;
    self.qualityPopup.enabled = !locked;
    self.timelinePlacementPopup.enabled = !locked;
    self.destinationControl.enabled = !locked;
    self.clipNameField.enabled = !locked;
    self.eventNameField.enabled = !locked;
    self.mirrorCheckbox.enabled = !locked;
    self.muteCheckbox.enabled = !locked;
    self.timestampOverlayCheckbox.enabled = !locked && !self.timestampOverlayCheckbox.hidden;
    self.intensitySlider.enabled = !locked;
    self.exposureSlider.enabled = !locked;
    self.contrastSlider.enabled = !locked;
    self.saturationSlider.enabled = !locked;
    self.temperatureSlider.enabled = !locked;
    self.sharpnessSlider.enabled = !locked;
    self.glowSlider.enabled = !locked;
    self.recordButton.enabled = !locked && self.cameraAuthorized && self.session.isRunning;
    self.stopButton.enabled = self.recordingActive || self.finalizingRecording;
}

- (void)deviceSelectionChanged:(id)sender {
    if (sender == self.cameraPopup) {
        [self refreshResolutionOptionsPreservingSelection:nil frameRate:nil];
    }
    [self persistDefaults];
    [self refreshBackgroundUI];
    if (self.isVisible && !self.recordingActive && !self.finalizingRecording) {
        [self reconfigurePreviewSession];
    }
}

- (void)configurationChanged:(id)sender {
    if (sender == self.resolutionPopup) {
        [self refreshFrameRateOptionsPreservingSelection:nil];
    }
    [self refreshDestinationUI];
    [self refreshPresetButtons];
    [self refreshBackgroundUI];
    [self refreshNameHint];
    [self persistDefaults];
    if (sender == self.resolutionPopup || sender == self.frameRatePopup) {
        if (self.isVisible && !self.recordingActive && !self.finalizingRecording) {
            [self reconfigurePreviewSession];
        }
    }
}

- (void)adjustmentSliderChanged:(id)sender {
    self.adjustments.intensity = self.intensitySlider.doubleValue;
    self.adjustments.exposure = self.exposureSlider.doubleValue;
    self.adjustments.contrast = self.contrastSlider.doubleValue;
    self.adjustments.saturation = self.saturationSlider.doubleValue;
    self.adjustments.temperature = self.temperatureSlider.doubleValue;
    self.adjustments.sharpness = self.sharpnessSlider.doubleValue;
    self.adjustments.glow = self.glowSlider.doubleValue;
    [self persistDefaults];
}

- (void)destinationChanged:(id)sender {
    [self refreshDestinationUI];
    [self persistDefaults];
}

- (void)lookCategoryChanged:(id)sender {
    NSString *category = self.lookCategoryPopup.selectedItem.representedObject ?: self.lookCategoryPopup.titleOfSelectedItem;
    SpliceKitLiveCamPreset *currentPreset = [self selectedPreset];
    NSArray<SpliceKitLiveCamPreset *> *visiblePresets = [self presetsForSelectedCategory];
    NSString *identifier = ([currentPreset.category isEqualToString:category] && currentPreset.identifier.length > 0)
        ? currentPreset.identifier
        : visiblePresets.firstObject.identifier;
    [self storeSelectedPresetIdentifier:identifier];
    [self buildPresetButtons];
    [self refreshPresetButtons];
    [self updateStatus:[NSString stringWithFormat:@"Previewing %@.", [self selectedPreset].name ?: @"Clean"]];
    [self persistDefaults];
}

- (void)lookPresetChanged:(id)sender {
    NSString *identifier = SpliceKitLiveCamString(self.lookPresetPopup.selectedItem.representedObject);
    [self storeSelectedPresetIdentifier:identifier];
    [self refreshPresetButtons];
    [self updateStatus:[NSString stringWithFormat:@"Previewing %@.", [self selectedPreset].name ?: @"Clean"]];
    [self persistDefaults];
}

- (void)backgroundQualityChanged:(id)sender {
    NSString *key = SpliceKitLiveCamString(self.backgroundQualityPopup.selectedItem.representedObject);
    SpliceKitLiveCamSegmentationQuality q = SpliceKitLiveCamSegmentationQualityBalanced;
    if ([key isEqualToString:@"fast"]) q = SpliceKitLiveCamSegmentationQualityFast;
    else if ([key isEqualToString:@"accurate"]) q = SpliceKitLiveCamSegmentationQualityAccurate;
    self.segmentationEngine.quality = q;
    [self.segmentationEngine reset];
    [self.renderer resetMaskHistory];
    [self persistDefaults];
}

- (void)backgroundModeChanged:(id)sender {
    if ([self selectedBackgroundMode] != SpliceKitLiveCamBackgroundModeGreenScreen) {
        [self.segmentationEngine reset];
        [self.renderer resetMaskHistory];
    }
    [self refreshBackgroundUI];

    switch ([self selectedBackgroundMode]) {
        case SpliceKitLiveCamBackgroundModeSystemBlur:
            [self updateStatus:@"Blur is controlled by macOS Video Effects. Open Video Effects to turn Portrait blur on or off."];
            break;
        case SpliceKitLiveCamBackgroundModeGreenScreen:
            [self updateStatus:@"Previewing with LiveCam Green Screen. Best results come from clear separation and stable lighting."];
            break;
        default:
            [self updateStatus:@"Previewing the natural camera feed. System Video Effects still pass through when enabled."];
            break;
    }

    [self persistDefaults];
}

- (void)openVideoEffects:(id)sender {
    if (!@available(macOS 12.0, *)) {
        [self updateStatus:@"System Video Effects are not available on this macOS version."];
        return;
    }

    [AVCaptureDevice showSystemUserInterface:AVCaptureSystemUserInterfaceVideoEffects];
    [self updateStatus:@"Open Video Effects to manage Portrait blur, Center Stage, and Studio Light for the current camera."];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshBackgroundUI];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshBackgroundUI];
    });
}

- (void)timestampOverlayChanged:(id)sender {
    [self persistDefaults];
}

- (void)toggleAdvancedControls:(id)sender {
    self.advancedVisible = !self.advancedVisible;
    [self refreshAdvancedUI];
    [self persistDefaults];
}

- (void)controlTextDidChange:(NSNotification *)obj {
    [self refreshNameHint];
    [self persistDefaults];
}

@end
