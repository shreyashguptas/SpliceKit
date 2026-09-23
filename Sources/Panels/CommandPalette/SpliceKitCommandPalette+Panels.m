//
//  SpliceKitCommandPalette+Panels.m
//  Auxiliary windows the palette opens: the processing HUD and URL import prompt,
//  Remove Silences and Scene Detection options, and the SpliceKit options panel.
//

#import "SpliceKitCommandPalette+Private.h"

@implementation SpliceKitCommandPalette (Panels)

#pragma mark - Processing HUD

- (NSPanel *)showProcessingHUD:(NSString *)message {
    __block NSPanel *hud = nil;
    if ([NSThread isMainThread]) {
        hud = [self _createProcessingHUD:message];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            hud = [self _createProcessingHUD:message];
        });
    }
    return hud;
}

- (NSPanel *)_createProcessingHUD:(NSString *)message {
    NSPanel *hud = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 118)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView)
        backing:NSBackingStoreBuffered defer:NO];
    hud.title = @"";
    hud.titleVisibility = NSWindowTitleHidden;
    hud.titlebarAppearsTransparent = YES;
    hud.level = NSFloatingWindowLevel;
    hud.backgroundColor = [NSColor clearColor];
    hud.movableByWindowBackground = YES;
    hud.releasedWhenClosed = NO;
    [hud center];

    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:hud.contentView.bounds];
    bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    bg.material = NSVisualEffectMaterialHUDWindow;
    bg.state = NSVisualEffectStateActive;
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 12;
    bg.layer.masksToBounds = YES;
    [hud.contentView addSubview:bg];

    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 50, 24, 24)];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeRegular;
    [spinner startAnimation:nil];
    [bg addSubview:spinner];

    NSTextField *label = [NSTextField wrappingLabelWithString:message ?: @"Working..."];
    label.frame = NSMakeRect(52, 42, 446, 40);
    label.alignment = NSTextAlignmentLeft;
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.textColor = [NSColor labelColor];
    label.maximumNumberOfLines = 2;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    [bg addSubview:label];
    objc_setAssociatedObject(hud, "processingLabel", label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [hud makeKeyAndOrderFront:nil];
    return hud;
}

- (void)updateProcessingHUD:(NSPanel *)hud message:(NSString *)message {
    if (!hud) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTextField *label = objc_getAssociatedObject(hud, "processingLabel");
        if (label) {
            label.stringValue = message ?: @"Working...";
            [label sizeToFit];
            NSRect frame = label.frame;
            frame.origin.x = 52;
            frame.size.width = 446;
            frame.size.height = MIN(MAX(frame.size.height, 20), 40);
            frame.origin.y = 62 - frame.size.height / 2.0;
            label.frame = frame;
        }
    });
}

- (void)attachURLImportCancelButtonToHUD:(NSPanel *)hud jobID:(NSString *)jobID {
    if (!hud || jobID.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (objc_getAssociatedObject(hud, "urlImportCancelButton")) return;

        NSVisualEffectView *bg = hud.contentView.subviews.firstObject;
        if (![bg isKindOfClass:[NSVisualEffectView class]]) return;

        objc_setAssociatedObject(hud, "urlImportJobID", jobID, OBJC_ASSOCIATION_COPY_NONATOMIC);

        NSButton *cancelButton = [NSButton buttonWithTitle:@"Cancel Import"
                                                    target:self
                                                    action:@selector(handleURLImportCancelButton:)];
        cancelButton.frame = NSMakeRect(388, 14, 112, 30);
        cancelButton.bezelStyle = NSBezelStyleRounded;
        [bg addSubview:cancelButton];
        objc_setAssociatedObject(hud, "urlImportCancelButton", cancelButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

- (void)handleURLImportCancelButton:(NSButton *)sender {
    NSPanel *hud = (NSPanel *)sender.window;
    NSString *jobID = objc_getAssociatedObject(hud, "urlImportJobID");
    if (jobID.length == 0) return;

    NSDictionary *cancelResult = SpliceKitURLImport_cancel(@{@"job_id": jobID});
    sender.enabled = NO;
    NSString *message = [cancelResult[@"state"] isEqualToString:@"cancelled"]
        ? @"Cancelling URL import..."
        : @"Cancel request sent...";
    [self updateProcessingHUD:hud message:message];
}

- (void)dismissProcessingHUD:(NSPanel *)hud {
    if (!hud) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [hud close];
    });
}

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = title ?: @"SpliceKit";
        alert.informativeText = message ?: @"";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    });
}

- (NSString *)selectedURLImportModeForToggle:(NSButton *)timelineToggle
                                       popup:(NSPopUpButton *)popup {
    if (timelineToggle.state != NSControlStateValueOn) {
        return @"import_only";
    }
    switch (popup.indexOfSelectedItem) {
        case 1: return @"insert_at_timeline_start";
        case 2: return @"append_to_timeline";
        default: return @"insert_at_playhead";
    }
}

- (void)syncURLImportTimelineControls:(NSButton *)timelineToggle {
    NSTextField *label = objc_getAssociatedObject(timelineToggle, "urlImportTimelineLabel");
    NSPopUpButton *popup = objc_getAssociatedObject(timelineToggle, "urlImportTimelinePopup");
    BOOL enabled = (timelineToggle.state == NSControlStateValueOn);
    popup.enabled = enabled;
    label.enabled = enabled;
    label.textColor = enabled ? [NSColor labelColor] : [NSColor secondaryLabelColor];
}

- (void)handleURLImportTimelineToggle:(NSButton *)sender {
    [self syncURLImportTimelineControls:sender];
}

- (void)showURLImportPromptWithDefaultMode:(NSString *)defaultMode {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL defaultsToTimeline = ![defaultMode isEqualToString:@"import_only"];
        NSString *promptTitle = defaultsToTimeline
            ? @"Import URL to Timeline"
            : @"Import URL to Library";
        NSString *primaryButtonTitle = defaultsToTimeline
            ? @"Add to Timeline"
            : @"Import to Library";
        NSString *failureTitle = defaultsToTimeline
            ? @"Import URL to Timeline Failed"
            : @"Import URL to Library Failed";
        NSString *emptyMessage = defaultsToTimeline
            ? @"Paste a video URL to add to the timeline."
            : @"Paste a video URL to import into the library.";

        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = promptTitle;
        alert.informativeText = defaultsToTimeline
            ? @"Paste a YouTube, Vimeo, or direct media URL. SpliceKit will download it, import it into Final Cut Pro, then place it in the active timeline using the selected placement."
            : @"Paste a YouTube, Vimeo, or direct media URL. SpliceKit will download it, convert it if needed, and import it into Final Cut Pro.";
        [alert addButtonWithTitle:primaryButtonTitle];
        [alert addButtonWithTitle:@"Cancel"];

        NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 212)];

        NSButton *qualityToggle = [[NSButton alloc] initWithFrame:NSMakeRect(0, 188, 420, 20)];
        [qualityToggle setButtonType:NSButtonTypeSwitch];
        qualityToggle.title = @"Highest Quality (larger files, may require VP9/AV1 remux)";
        qualityToggle.state = NSControlStateValueOff;
        qualityToggle.toolTip = @"YouTube caps progressive mp4 at 720p. Enable this to fetch the highest available resolution (1080p, 1440p, or 4K) by downloading separate video + audio streams and merging.";
        [accessory addSubview:qualityToggle];

        NSTextField *urlLabel = [NSTextField labelWithString:@"URL"];
        urlLabel.frame = NSMakeRect(0, 160, 80, 20);
        [accessory addSubview:urlLabel];

        NSScrollView *urlScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 108, 420, 48)];
        urlScroll.hasVerticalScroller = YES;
        urlScroll.hasHorizontalScroller = NO;
        urlScroll.borderType = NSBezelBorder;
        urlScroll.autohidesScrollers = YES;

        NSTextView *urlField = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 48)];
        urlField.minSize = NSMakeSize(0, 48);
        urlField.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
        urlField.verticallyResizable = YES;
        urlField.horizontallyResizable = NO;
        urlField.automaticQuoteSubstitutionEnabled = NO;
        urlField.automaticDashSubstitutionEnabled = NO;
        urlField.automaticTextReplacementEnabled = NO;
        urlField.font = [NSFont systemFontOfSize:13];
        urlField.string = @"";
        urlScroll.documentView = urlField;
        [accessory addSubview:urlScroll];

        NSTextField *urlHint = [NSTextField labelWithString:@"Paste a full YouTube, Vimeo, or direct video URL"];
        urlHint.frame = NSMakeRect(2, 90, 320, 14);
        urlHint.font = [NSFont systemFontOfSize:11];
        urlHint.textColor = [NSColor secondaryLabelColor];
        [accessory addSubview:urlHint];

        NSButton *timelineToggle = [[NSButton alloc] initWithFrame:NSMakeRect(0, 62, 260, 20)];
        [timelineToggle setButtonType:NSButtonTypeSwitch];
        timelineToggle.title = defaultsToTimeline
            ? @"Place in active timeline"
            : @"Also place in active timeline";
        timelineToggle.target = self;
        timelineToggle.action = @selector(handleURLImportTimelineToggle:);
        timelineToggle.state = defaultsToTimeline
            ? NSControlStateValueOn
            : NSControlStateValueOff;
        [accessory addSubview:timelineToggle];

        NSTextField *placementLabel = [NSTextField labelWithString:@"Timeline Placement"];
        placementLabel.frame = NSMakeRect(0, 34, 140, 20);
        [accessory addSubview:placementLabel];

        NSPopUpButton *modePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 8, 188, 26) pullsDown:NO];
        [modePopup addItemsWithTitles:@[@"At Current Playhead", @"At Timeline Start", @"Append to Timeline End"]];
        if ([defaultMode isEqualToString:@"append_to_timeline"]) {
            [modePopup selectItemAtIndex:2];
        } else if ([defaultMode isEqualToString:@"insert_at_timeline_start"]) {
            [modePopup selectItemAtIndex:1];
        } else {
            [modePopup selectItemAtIndex:0];
        }
        [accessory addSubview:modePopup];
        objc_setAssociatedObject(timelineToggle, "urlImportTimelineLabel", placementLabel, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(timelineToggle, "urlImportTimelinePopup", modePopup, OBJC_ASSOCIATION_ASSIGN);
        [self syncURLImportTimelineControls:timelineToggle];

        NSTextField *titleLabel = [NSTextField labelWithString:@"Title Override"];
        titleLabel.frame = NSMakeRect(198, 34, 100, 20);
        [accessory addSubview:titleLabel];

        NSTextField *titleField = [[NSTextField alloc] initWithFrame:NSMakeRect(198, 8, 222, 24)];
        titleField.placeholderString = @"Optional clip name";
        [accessory addSubview:titleField];

        alert.accessoryView = accessory;

        NSInteger response = [alert runModal];
        if (response != NSAlertFirstButtonReturn) return;

        NSString *url = [urlField.string stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (url.length == 0) {
            [self showSimpleAlertWithTitle:promptTitle message:emptyMessage];
            return;
        }

        NSMutableDictionary *params = [NSMutableDictionary dictionary];
        params[@"url"] = url;
        params[@"mode"] = [self selectedURLImportModeForToggle:timelineToggle popup:modePopup];
        params[@"highest_quality"] = @(qualityToggle.state == NSControlStateValueOn);
        NSString *title = [titleField.stringValue stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (title.length > 0) params[@"title"] = title;

        NSPanel *hud = [self showProcessingHUD:(defaultsToTimeline
            ? @"Starting timeline URL import..."
            : @"Starting library URL import...")];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *start = SpliceKitURLImport_start(params);
            if (start[@"error"]) {
                [self dismissProcessingHUD:hud];
                [self showSimpleAlertWithTitle:failureTitle message:start[@"error"]];
                return;
            }

            NSString *jobID = start[@"job_id"];
            if (jobID.length == 0) {
                [self dismissProcessingHUD:hud];
                [self showSimpleAlertWithTitle:failureTitle
                                       message:@"The URL import job did not return a valid job ID."];
                return;
            }
            [self attachURLImportCancelButtonToHUD:hud jobID:jobID];

            dispatch_async(dispatch_get_main_queue(), ^{
                __block dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                    dispatch_get_main_queue());
                dispatch_source_set_timer(timer,
                    dispatch_time(DISPATCH_TIME_NOW, 0),
                    (uint64_t)(0.35 * NSEC_PER_SEC),
                    (uint64_t)(0.05 * NSEC_PER_SEC));

                dispatch_source_set_event_handler(timer, ^{
                    NSDictionary *status = SpliceKitURLImport_status(@{@"job_id": jobID});
                    NSString *state = status[@"state"] ?: @"";
                    NSString *message = status[@"message"] ?: @"Working...";
                    double progress = [status[@"progress"] doubleValue];
                    NSString *hudMessage = message;
                    if (progress > 0.0 && progress < 1.0 && ![message containsString:@"%"]) {
                        hudMessage = [NSString stringWithFormat:@"%@ %.0f%%", message, progress * 100.0];
                    }
                    [self updateProcessingHUD:hud message:hudMessage];

                    BOOL finished = [state isEqualToString:@"completed"] ||
                                    [state isEqualToString:@"failed"] ||
                                    [state isEqualToString:@"cancelled"];
                    if (!finished) return;

                    dispatch_source_cancel(timer);
                    timer = nil;
                    [self dismissProcessingHUD:hud];

                    BOOL completed = [state isEqualToString:@"completed"];
                    NSString *statusError = [status[@"error"] isKindOfClass:[NSString class]]
                        ? status[@"error"] : @"";
                    BOOL hasWarning = completed && statusError.length > 0;

                    if (completed && !hasWarning) {
                        SpliceKit_log(@"[URLImport] %@", status[@"message"] ?: @"URL import finished.");
                        return;
                    }

                    NSMutableString *summary = [NSMutableString stringWithString:
                        status[@"message"] ?: @"URL import finished."];
                    NSString *targetEvent = status[@"target_event"];
                    NSString *finalPath = [status[@"normalized_path"] length] > 0
                        ? status[@"normalized_path"] : status[@"download_path"];
                    if (targetEvent.length > 0) {
                        [summary appendFormat:@"\n\nEvent: %@", targetEvent];
                    }
                    if (finalPath.length > 0 && !completed) {
                        [summary appendFormat:@"\nPath: %@", finalPath];
                    }
                    if (statusError.length > 0) {
                        [summary appendFormat:@"\n\nDetail: %@", statusError];
                    }

                    NSString *titleText = completed ? @"URL Imported With Warning" : @"Import From URL Failed";
                    [self showSimpleAlertWithTitle:titleText message:summary];
                });

                dispatch_resume(timer);
            });
        });
    });
}

#pragma mark - Remove Silences

- (NSString *)findSilenceDetector {
    // The framework's Resources (deployed by make install), then the per-user tool locations.
    return SpliceKit_findHelperTool(@"silence-detector", nil);
}

- (void)showSilenceOptionsPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Build options panel
        NSPanel *opts = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 320)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
            backing:NSBackingStoreBuffered defer:NO];
        opts.title = @"Remove Silences";
        [opts center];

        NSView *v = opts.contentView;
        CGFloat y = 280;

        // --- Threshold ---
        NSTextField *threshLabel = [NSTextField labelWithString:@"Threshold (dB):"];
        threshLabel.frame = NSMakeRect(20, y, 140, 20);
        [v addSubview:threshLabel];

        NSPopUpButton *threshPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(165, y - 2, 190, 26) pullsDown:NO];
        [threshPop addItemsWithTitles:@[@"Auto (adaptive)", @"-35 dB (aggressive)", @"-40 dB", @"-44 dB", @"-48 dB (conservative)", @"-52 dB (very conservative)"]];
        [threshPop selectItemAtIndex:0];
        [v addSubview:threshPop];

        // --- Min silence duration ---
        y -= 40;
        NSTextField *durLabel = [NSTextField labelWithString:@"Min silence duration:"];
        durLabel.frame = NSMakeRect(20, y, 140, 20);
        [v addSubview:durLabel];

        NSPopUpButton *durPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(165, y - 2, 190, 26) pullsDown:NO];
        [durPop addItemsWithTitles:@[@"0.2s (catch short pauses)", @"0.3s", @"0.5s (default)", @"0.75s", @"1.0s (only long gaps)"]];
        [durPop selectItemAtIndex:1];
        [v addSubview:durPop];

        // --- Padding ---
        y -= 40;
        NSTextField *padLabel = [NSTextField labelWithString:@"Padding:"];
        padLabel.frame = NSMakeRect(20, y, 140, 20);
        [v addSubview:padLabel];

        NSPopUpButton *padPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(165, y - 2, 190, 26) pullsDown:NO];
        [padPop addItemsWithTitles:@[@"0.0s (tight cuts)", @"0.05s", @"0.08s (default)", @"0.1s", @"0.15s (safe)"]];
        [padPop selectItemAtIndex:2];
        [v addSubview:padPop];

        // --- Description ---
        y -= 50;
        NSTextField *desc = [NSTextField wrappingLabelWithString:
            @"Threshold: How quiet audio must be to count as silence. "
            @"Lower values = less aggressive. \"Auto\" analyzes the clip's audio profile.\n\n"
            @"Min duration: Silences shorter than this are ignored.\n\n"
            @"Padding: Audio kept before/after each cut to avoid clipping words."];
        desc.frame = NSMakeRect(20, 60, 340, 120);
        desc.font = [NSFont systemFontOfSize:11];
        desc.textColor = [NSColor secondaryLabelColor];
        [v addSubview:desc];

        // --- Buttons ---
        NSButton *cancelBtn = [NSButton buttonWithTitle:@"Cancel" target:nil action:nil];
        cancelBtn.frame = NSMakeRect(180, 15, 80, 32);
        cancelBtn.bezelStyle = NSBezelStyleRounded;
        [v addSubview:cancelBtn];

        NSButton *runBtn = [NSButton buttonWithTitle:@"Remove" target:nil action:nil];
        runBtn.frame = NSMakeRect(270, 15, 90, 32);
        runBtn.bezelStyle = NSBezelStyleRounded;
        runBtn.keyEquivalent = @"\r";
        [v addSubview:runBtn];

        // Run modal
        cancelBtn.target = opts;
        cancelBtn.action = @selector(close);

        runBtn.target = self;
        runBtn.action = @selector(_silenceOptionsRun:);
        objc_setAssociatedObject(runBtn, "panel", opts, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(runBtn, "threshPop", threshPop, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(runBtn, "durPop", durPop, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(runBtn, "padPop", padPop, OBJC_ASSOCIATION_RETAIN);

        [opts makeKeyAndOrderFront:nil];
    });
}

- (void)_silenceOptionsRun:(NSButton *)sender {
    NSPanel *panel = objc_getAssociatedObject(sender, "panel");
    NSPopUpButton *threshPop = objc_getAssociatedObject(sender, "threshPop");
    NSPopUpButton *durPop = objc_getAssociatedObject(sender, "durPop");
    NSPopUpButton *padPop = objc_getAssociatedObject(sender, "padPop");

    // Parse threshold
    NSString *threshold = @"auto";
    NSArray *threshVals = @[@"auto", @"-35", @"-40", @"-44", @"-48", @"-52"];
    threshold = threshVals[threshPop.indexOfSelectedItem];

    // Parse min duration
    NSArray *durVals = @[@0.2, @0.3, @0.5, @0.75, @1.0];
    double minDur = [durVals[durPop.indexOfSelectedItem] doubleValue];

    // Parse padding
    NSArray *padVals = @[@0.0, @0.05, @0.08, @0.1, @0.15];
    double pad = [padVals[padPop.indexOfSelectedItem] doubleValue];

    [panel close];
    [self performRemoveSilencesWithThreshold:threshold minDuration:minDur padding:pad];
}

- (void)performRemoveSilencesWithThreshold:(NSString *)threshold minDuration:(double)minDuration padding:(double)padding {
    NSPanel *hud = [self showProcessingHUD:@"Analyzing audio for silences..."];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *detector = [self findSilenceDetector];
            if (!detector) {
                [self dismissProcessingHUD:hud];
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *a = [[NSAlert alloc] init];
                    a.messageText = @"Silence Detector Not Found";
                    a.informativeText = @"Re-run the SpliceKit patcher to install tools, or build from source with 'make tools'.";
                    a.alertStyle = NSAlertStyleWarning;
                    [a runModal];
                });
                return;
            }

            __block NSArray *items = nil;
            __block double fps = 24.0;
            SpliceKit_executeOnMainThread(^{
                NSDictionary *s = SpliceKit_handleTimelineGetDetailedState(@{@"limit": @500});
                if (s[@"error"]) return;
                items = s[@"items"];
                if (s[@"frameRate"]) fps = [s[@"frameRate"] doubleValue];
            });

            if (!items.count) {
                [self dismissProcessingHUD:hud];
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *a = [[NSAlert alloc] init];
                    a.messageText = @"No Clips in Timeline";
                    [a runModal];
                });
                return;
            }

            NSString *minDurStr = [NSString stringWithFormat:@"%.2f", minDuration];
            NSString *padStr = [NSString stringWithFormat:@"%.2f", padding];

            NSMutableArray *silRanges = [NSMutableArray array];
            double tlOff = 0;
            NSInteger analyzed = 0;

            for (NSDictionary *item in items) {
                NSString *cls = item[@"class"] ?: @"";
                double dur = [item[@"duration"][@"seconds"] doubleValue];
                long long lane = [item[@"lane"] longLongValue];
                if (lane != 0 || [cls containsString:@"Transition"]) {
                    if (lane == 0) tlOff += dur;
                    continue;
                }
                NSString *mp = nil;
                NSString *handle = item[@"handle"];
                double trim = [item[@"trimmedOffset"][@"seconds"] doubleValue];
                if (handle) {
                    id obj = SpliceKit_resolveHandle(handle);
                    if (obj) {
                        @try {
                            id mediaObj = obj;
                            if ([cls containsString:@"Collection"]) {
                                id contained = [obj valueForKey:@"containedItems"];
                                if ([contained isKindOfClass:[NSArray class]] && [(NSArray *)contained count] > 0)
                                    mediaObj = [(NSArray *)contained objectAtIndex:0];
                            }
                            id media = [mediaObj valueForKey:@"media"];
                            if (media) {
                                id rep = [media valueForKey:@"originalMediaRep"];
                                if (rep) {
                                    id url = [rep valueForKey:@"fileURL"];
                                    if (url && [url respondsToSelector:@selector(path)])
                                        mp = ((id (*)(id, SEL))objc_msgSend)(url, @selector(path));
                                }
                            }
                        } @catch (NSException *e) {}
                    }
                }
                if (!mp || ![[NSFileManager defaultManager] fileExistsAtPath:mp]) {
                    tlOff += dur; continue;
                }

                NSArray *detectorArgs = @[mp, @"--threshold", threshold, @"--min-duration", minDurStr,
                                          @"--padding", padStr,
                                          @"--start", [NSString stringWithFormat:@"%.4f", trim],
                                          @"--end", [NSString stringWithFormat:@"%.4f", trim + dur]];
                int detectorStatus = -1;
                NSData *d = nil;
                if (SpliceKit_runProcess(detector, detectorArgs, nil, SpliceKitProcessOptionsNone, 0,
                                         &detectorStatus, &d, NULL, NULL) != SpliceKitProcessExited) {
                    tlOff += dur; continue;
                }

                if (detectorStatus == 0) {
                    NSDictionary *r = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                    for (NSDictionary *rng in r[@"silentRanges"]) {
                        double ss = [rng[@"start"] doubleValue], se = [rng[@"end"] doubleValue];
                        double ts = MAX(tlOff + (ss - trim), tlOff);
                        double te = MIN(tlOff + (se - trim), tlOff + dur);
                        if (te > ts) [silRanges addObject:@{@"start": @(ts), @"end": @(te)}];
                    }
                    analyzed++;
                }
                tlOff += dur;
            }

            if (!silRanges.count) {
                [self dismissProcessingHUD:hud];
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *a = [[NSAlert alloc] init];
                    a.messageText = @"No Silences Found";
                    a.informativeText = [NSString stringWithFormat:
                        @"Analyzed %ld clip%@. No silent segments detected.\nThreshold: %@, Min: %@s",
                        (long)analyzed, analyzed==1?@"":@"s", threshold, minDurStr];
                    [a runModal];
                });
                return;
            }

            [silRanges sortUsingComparator:^(NSDictionary *a, NSDictionary *b) {
                return [b[@"start"] compare:a[@"start"]];
            }];

            __block NSInteger done = 0;
            NSInteger total = silRanges.count;
            SpliceKit_executeOnMainThread(^{
                id app = [NSApplication sharedApplication];
                SEL gs = @selector(gotoStart:), s10 = @selector(stepForward10Frames:), s1 = @selector(stepForward:);
                for (NSDictionary *rng in silRanges) {
                    double silEnd = [rng[@"end"] doubleValue], silStart = [rng[@"start"] doubleValue];
                    [app sendAction:gs to:nil from:nil];
                    int f = (int)round(silEnd * fps);
                    for (int j=0;j<f/10;j++) [app sendAction:s10 to:nil from:nil];
                    for (int j=0;j<f%10;j++) [app sendAction:s1 to:nil from:nil];
                    SpliceKit_handleTimelineAction(@{@"action": @"blade"});
                    [app sendAction:gs to:nil from:nil];
                    f = (int)round(silStart * fps);
                    for (int j=0;j<f/10;j++) [app sendAction:s10 to:nil from:nil];
                    for (int j=0;j<f%10;j++) [app sendAction:s1 to:nil from:nil];
                    SpliceKit_handleTimelineAction(@{@"action": @"blade"});
                    [NSThread sleepForTimeInterval:0.03];
                    SpliceKit_handleTimelineAction(@{@"action": @"selectClipAtPlayhead"});
                    SpliceKit_handleTimelineAction(@{@"action": @"delete"});
                    done++;
                }
            });

            [self dismissProcessingHUD:hud];
            double totSil = 0;
            for (NSDictionary *r in silRanges) totSil += [r[@"end"] doubleValue] - [r[@"start"] doubleValue];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *a = [[NSAlert alloc] init];
                a.messageText = @"Silences Removed";
                a.informativeText = [NSString stringWithFormat:
                    @"Removed %ld of %ld silent segment%@ (%.1fs total).\nThreshold: %@, Min: %@s, Pad: %@s\n\nUse Cmd+Z to undo.",
                    (long)done, (long)total, total==1?@"":@"s", totSil, threshold, minDurStr, padStr];
                a.alertStyle = NSAlertStyleInformational;
                [a runModal];
            });
        }
    });
}

#pragma mark - Scene Detection Options

- (void)showSceneDetectionOptionsPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSPanel *opts = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 340)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
            backing:NSBackingStoreBuffered defer:NO];
        opts.title = @"Detect Scene Changes";
        [opts center];

        NSView *v = opts.contentView;
        CGFloat y = 300;

        // --- Action ---
        NSTextField *actLabel = [NSTextField labelWithString:@"Action:"];
        actLabel.frame = NSMakeRect(20, y, 140, 20);
        [v addSubview:actLabel];

        NSPopUpButton *actPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(165, y - 2, 190, 26) pullsDown:NO];
        [actPop addItemsWithTitles:@[@"Detect only (report count)", @"Add markers at changes", @"Blade at changes"]];
        [actPop selectItemAtIndex:1];
        [v addSubview:actPop];

        // --- Threshold ---
        y -= 40;
        NSTextField *threshLabel = [NSTextField labelWithString:@"Sensitivity:"];
        threshLabel.frame = NSMakeRect(20, y, 140, 20);
        [v addSubview:threshLabel];

        NSPopUpButton *threshPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(165, y - 2, 190, 26) pullsDown:NO];
        [threshPop addItemsWithTitles:@[@"0.10 (very sensitive)", @"0.15 (sensitive)", @"0.20 (moderate)", @"0.25", @"0.35 (default)", @"0.50 (only major changes)"]];
        [threshPop selectItemAtIndex:2];
        [v addSubview:threshPop];

        // --- Sample interval ---
        y -= 40;
        NSTextField *intLabel = [NSTextField labelWithString:@"Sample interval:"];
        intLabel.frame = NSMakeRect(20, y, 140, 20);
        [v addSubview:intLabel];

        NSPopUpButton *intPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(165, y - 2, 190, 26) pullsDown:NO];
        [intPop addItemsWithTitles:@[@"Every frame (precise)", @"0.05s", @"0.1s", @"0.2s (fast)", @"0.5s (very fast)"]];
        [intPop selectItemAtIndex:0];
        [v addSubview:intPop];

        // --- Description ---
        y -= 50;
        NSTextField *desc = [NSTextField wrappingLabelWithString:
            @"Sensitivity: How different adjacent frames must be to count as a scene change. "
            @"Lower values detect more subtle changes (camera moves, lighting shifts). "
            @"Higher values only detect hard cuts.\n\n"
            @"Sample interval: How often to compare frames. "
            @"\"Every frame\" is most accurate but slower on long clips."];
        desc.frame = NSMakeRect(20, 60, 340, 120);
        desc.font = [NSFont systemFontOfSize:11];
        desc.textColor = [NSColor secondaryLabelColor];
        [v addSubview:desc];

        // --- Buttons ---
        NSButton *cancelBtn = [NSButton buttonWithTitle:@"Cancel" target:opts action:@selector(close)];
        cancelBtn.frame = NSMakeRect(180, 15, 80, 32);
        cancelBtn.bezelStyle = NSBezelStyleRounded;
        [v addSubview:cancelBtn];

        NSButton *runBtn = [NSButton buttonWithTitle:@"Detect" target:self action:@selector(_sceneOptionsRun:)];
        runBtn.frame = NSMakeRect(270, 15, 90, 32);
        runBtn.bezelStyle = NSBezelStyleRounded;
        runBtn.keyEquivalent = @"\r";
        [v addSubview:runBtn];

        objc_setAssociatedObject(runBtn, "panel", opts, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(runBtn, "actPop", actPop, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(runBtn, "threshPop", threshPop, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(runBtn, "intPop", intPop, OBJC_ASSOCIATION_RETAIN);

        [opts makeKeyAndOrderFront:nil];
    });
}

- (void)_sceneOptionsRun:(NSButton *)sender {
    NSPanel *panel = objc_getAssociatedObject(sender, "panel");
    NSPopUpButton *actPop = objc_getAssociatedObject(sender, "actPop");
    NSPopUpButton *threshPop = objc_getAssociatedObject(sender, "threshPop");
    NSPopUpButton *intPop = objc_getAssociatedObject(sender, "intPop");

    NSArray *actVals = @[@"detect", @"markers", @"blade"];
    NSString *action = actVals[actPop.indexOfSelectedItem];

    NSArray *threshVals = @[@0.10, @0.15, @0.20, @0.25, @0.35, @0.50];
    double threshold = [threshVals[threshPop.indexOfSelectedItem] doubleValue];

    NSArray *intVals = @[@0.0, @0.05, @0.1, @0.2, @0.5];
    double interval = [intVals[intPop.indexOfSelectedItem] doubleValue];
    // 0.0 means every frame — pass a very small value
    if (interval < 0.001) interval = 0.001;

    [panel close];

    // Show processing HUD
    NSPanel *hud = [self showProcessingHUD:@"Detecting scene changes..."];

    // Run on background
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *r = SpliceKit_handleDetectSceneChanges(@{
            @"action": action,
            @"threshold": @(threshold),
            @"sampleInterval": @(interval),
        });
        [self dismissProcessingHUD:hud];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *a = [[NSAlert alloc] init];
            if (r[@"error"]) {
                a.messageText = @"Scene Detection Error";
                a.informativeText = r[@"error"];
                a.alertStyle = NSAlertStyleWarning;
            } else {
                NSUInteger count = [r[@"count"] unsignedIntegerValue];
                double dur = [r[@"duration"] doubleValue];
                NSString *actionDesc = @"detected";
                if ([action isEqualToString:@"markers"]) actionDesc = @"marked";
                else if ([action isEqualToString:@"blade"]) actionDesc = @"bladed";
                a.messageText = count > 0
                    ? [NSString stringWithFormat:@"Scene Changes %@", [actionDesc capitalizedString]]
                    : @"No Scene Changes Found";
                a.informativeText = [NSString stringWithFormat:
                    @"%lu scene change%@ %@ in %.1fs of media.\n\nSensitivity: %.2f, Interval: %.2fs",
                    (unsigned long)count, count == 1 ? @"" : @"s", actionDesc, dur, threshold, interval];
                if (count == 0) {
                    a.informativeText = [a.informativeText stringByAppendingString:
                        @"\n\nTry lowering the sensitivity value to detect more subtle changes."];
                }
            }
            [a runModal];
        });
    });
}

#pragma mark - SpliceKit Options Panel

- (void)showBridgeOptionsPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSPanel *opts = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 380)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
            backing:NSBackingStoreBuffered defer:NO];
        opts.title = @"SpliceKit Options";
        [opts center];

        NSView *v = opts.contentView;
        CGFloat y = 335;

        // --- Effect Drag as Adjustment Clip ---
        NSButton *effectDragCheck = [NSButton checkboxWithTitle:@"Effect Drag as Adjustment Clip"
                                                         target:self
                                                         action:@selector(_bridgeOptionEffectDragToggled:)];
        effectDragCheck.frame = NSMakeRect(20, y, 340, 20);
        effectDragCheck.state = SpliceKit_isEffectDragAsAdjustmentClipEnabled()
            ? NSControlStateValueOn : NSControlStateValueOff;
        objc_setAssociatedObject(effectDragCheck, "panel", opts, OBJC_ASSOCIATION_RETAIN);
        [v addSubview:effectDragCheck];

        y -= 22;
        NSTextField *effectDragDesc = [NSTextField wrappingLabelWithString:
            @"Allow dragging a video effect from the Effects Browser into empty space above a clip "
            @"to create an adjustment clip with that effect applied."];
        effectDragDesc.frame = NSMakeRect(38, y - 38, 320, 48);
        effectDragDesc.font = [NSFont systemFontOfSize:11];
        effectDragDesc.textColor = [NSColor secondaryLabelColor];
        [v addSubview:effectDragDesc];

        y -= 72;

        // --- Viewer Pinch-to-Zoom ---
        NSButton *pinchCheck = [NSButton checkboxWithTitle:@"Viewer Pinch-to-Zoom"
                                                    target:self
                                                    action:@selector(_bridgeOptionPinchZoomToggled:)];
        pinchCheck.frame = NSMakeRect(20, y, 340, 20);
        pinchCheck.state = SpliceKit_isViewerPinchZoomEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
        objc_setAssociatedObject(pinchCheck, "panel", opts, OBJC_ASSOCIATION_RETAIN);
        [v addSubview:pinchCheck];

        y -= 22;
        NSTextField *pinchDesc = [NSTextField wrappingLabelWithString:
            @"Use trackpad pinch gestures to zoom the viewer. "
            @"Supports any zoom level, not just the preset percentages."];
        pinchDesc.frame = NSMakeRect(38, y - 30, 320, 40);
        pinchDesc.font = [NSFont systemFontOfSize:11];
        pinchDesc.textColor = [NSColor secondaryLabelColor];
        [v addSubview:pinchDesc];

        y -= 62;

        // --- Default Spatial Conform ---
        NSTextField *conformLabel = [NSTextField labelWithString:@"Default Spatial Conform:"];
        conformLabel.frame = NSMakeRect(20, y, 180, 20);
        [v addSubview:conformLabel];

        NSPopUpButton *conformPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(200, y - 2, 150, 26) pullsDown:NO];
        [conformPopup addItemsWithTitles:@[@"Fit (Default)", @"Fill", @"None"]];
        conformPopup.target = self;
        conformPopup.action = @selector(_bridgeOptionConformChanged:);
        objc_setAssociatedObject(conformPopup, "panel", opts, OBJC_ASSOCIATION_RETAIN);

        NSString *currentConform = SpliceKit_getDefaultSpatialConformType();
        if ([currentConform isEqualToString:@"fill"]) [conformPopup selectItemAtIndex:1];
        else if ([currentConform isEqualToString:@"none"]) [conformPopup selectItemAtIndex:2];
        else [conformPopup selectItemAtIndex:0];
        [v addSubview:conformPopup];

        y -= 24;
        NSTextField *conformDesc = [NSTextField wrappingLabelWithString:
            @"Override the default spatial conform type for newly added clips. "
            @"Fit letterboxes, Fill crops to fill the frame, None uses native resolution."];
        conformDesc.frame = NSMakeRect(38, y - 38, 320, 48);
        conformDesc.font = [NSFont systemFontOfSize:11];
        conformDesc.textColor = [NSColor secondaryLabelColor];
        [v addSubview:conformDesc];

        // --- Close button ---
        NSButton *closeBtn = [NSButton buttonWithTitle:@"Done" target:opts action:@selector(close)];
        closeBtn.frame = NSMakeRect(280, 15, 80, 32);
        closeBtn.bezelStyle = NSBezelStyleRounded;
        closeBtn.keyEquivalent = @"\r";
        [v addSubview:closeBtn];

        [opts makeKeyAndOrderFront:nil];
    });
}

- (void)_bridgeOptionPinchZoomToggled:(NSButton *)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    SpliceKit_setViewerPinchZoomEnabled(enabled);
}

- (void)_bridgeOptionEffectDragToggled:(NSButton *)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    SpliceKit_setEffectDragAsAdjustmentClipEnabled(enabled);
}

- (void)_bridgeOptionConformChanged:(NSPopUpButton *)sender {
    NSInteger idx = [sender indexOfSelectedItem];
    NSString *value;
    if (idx == 1) value = @"fill";
    else if (idx == 2) value = @"none";
    else value = @"fit";
    SpliceKit_setDefaultSpatialConformType(value);
}

@end
