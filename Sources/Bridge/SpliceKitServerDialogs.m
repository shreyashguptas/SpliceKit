//
//  SpliceKitServerDialogs.m
//  SpliceKit - Dialogs: auto-dismissing known blocking alerts, and detecting, clicking,
//  filling and dismissing dialogs, sheets and file panels (dialog.*).
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Auto-Dismiss Known Dialogs

// Check for and auto-dismiss known blocking dialogs (e.g. "video properties not recognized").
// Called at the start of every request to clear stale dialogs that block interaction.
void SpliceKit_autoDismissBlockingDialogs(void) {
    // Runs before every request. It is opportunistic, so it waits at most 2 s for the
    // main thread and is not counted as a timeout: with the full 20 s here, a main
    // thread stuck in a progress sheet made every request (detect_dialog included)
    // spend 20 s on this before its own work, and the MCP client gave up at 30 s.
    SpliceKit_executeOnMainThreadWithTimeout(^{
        @try {
            // Check for sheets on all windows
            for (NSWindow *window in [NSApp windows]) {
                NSWindow *sheet = [window attachedSheet];
                if (!sheet) continue;

                // Scan text labels in the sheet for known blocking messages
                NSMutableArray *labels = [NSMutableArray array];
                NSMutableArray *buttons = [NSMutableArray array];

                // Recursive BFS to find text fields and buttons
                NSMutableArray *queue = [NSMutableArray arrayWithObject:[sheet contentView]];
                while (queue.count > 0) {
                    NSView *view = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    if (!view) continue;

                    if ([view isKindOfClass:[NSTextField class]] && ![(NSTextField *)view isEditable]) {
                        NSString *val = [(NSTextField *)view stringValue];
                        if (val.length > 0) [labels addObject:val];
                    }
                    if ([view isKindOfClass:[NSButton class]]) {
                        [buttons addObject:(NSButton *)view];
                    }
                    NSArray *subs = [view subviews];
                    if (subs) [queue addObjectsFromArray:subs];
                }

                // Check for "video properties" dialog
                BOOL isVideoPropsDialog = NO;
                for (NSString *label in labels) {
                    if ([label localizedCaseInsensitiveContainsString:@"video properties"] &&
                        [label localizedCaseInsensitiveContainsString:@"not recognized"]) {
                        isVideoPropsDialog = YES;
                        break;
                    }
                }

                if (isVideoPropsDialog) {
                    // Click "Continue" or "OK" or the default button
                    for (NSButton *btn in buttons) {
                        NSString *title = [btn title] ?: @"";
                        if ([title localizedCaseInsensitiveContainsString:@"continue"] ||
                            [title localizedCaseInsensitiveContainsString:@"ok"] ||
                            [[btn keyEquivalent] isEqualToString:@"\r"]) {
                            [btn performClick:nil];
                            SpliceKit_log(@"Auto-dismissed 'video properties not recognized' dialog");
                            break;
                        }
                    }
                }
            }

            // Also check modal windows
            NSWindow *modalWindow = [NSApp modalWindow];
            if (modalWindow) {
                NSMutableArray *labels = [NSMutableArray array];
                NSMutableArray *queue = [NSMutableArray arrayWithObject:[modalWindow contentView]];
                while (queue.count > 0) {
                    NSView *view = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    if (!view) continue;
                    if ([view isKindOfClass:[NSTextField class]] && ![(NSTextField *)view isEditable]) {
                        NSString *val = [(NSTextField *)view stringValue];
                        if (val.length > 0) [labels addObject:val];
                    }
                    NSArray *subs = [view subviews];
                    if (subs) [queue addObjectsFromArray:subs];
                }

                for (NSString *label in labels) {
                    if ([label localizedCaseInsensitiveContainsString:@"video properties"] &&
                        [label localizedCaseInsensitiveContainsString:@"not recognized"]) {
                        // Try to end the modal session
                        [NSApp stopModal];
                        [modalWindow close];
                        SpliceKit_log(@"Auto-dismissed modal 'video properties' dialog");
                        break;
                    }
                }
            }
        } @catch (NSException *e) {
            // Silently ignore - auto-dismiss is best-effort
        }
    }, 2.0, NO);
}

#pragma mark - Dialog Detection & Interaction
//
// FCP shows modal dialogs (sheets) for various operations. These handlers detect
// open dialogs, read their buttons/fields/checkboxes, and interact with them
// programmatically — so MCP clients can handle dialogs without user intervention.
//

// Recursively collect UI elements from a view hierarchy
// Forward declarations for dialog helpers
static NSArray<NSButton *> *SpliceKit_findButtonsInView(NSView *root);
static NSWindow *SpliceKit_findDialogWindow(void);
static NSDictionary *SpliceKit_dialogUndoSettleSnapshot(void);
static BOOL SpliceKit_dialogUndoSettleChanged(NSDictionary *before, NSDictionary *after);
static void SpliceKit_dialogApplySettle(NSMutableDictionary *result, NSDictionary *undoBefore, BOOL waitForUndo);
static BOOL SpliceKit_dialogButtonIsCancelLike(NSButton *btn);
static NSButton *SpliceKit_findCancelDialogButton(NSArray<NSButton *> *allButtons);
static NSButton *SpliceKit_findDefaultDialogButton(NSArray<NSButton *> *allButtons);

// Safe subview accessor - returns a COPY of the subviews array to avoid mutation crashes
static NSArray *SpliceKit_safeSubviews(NSView *view) {
    if (!view) return nil;
    @try {
        NSArray *subs = [view subviews];
        return subs ? [subs copy] : nil; // copy to avoid mutation during iteration
    } @catch (NSException *e) {
        return nil;
    }
}

static BOOL SpliceKit_windowIsSaveOrOpenPanel(NSWindow *window) {
    if (!window) return NO;
    Class savePanelClass = [NSSavePanel class];
    return savePanelClass && [window isKindOfClass:savePanelClass];
}

static void SpliceKit_enrichFilePanelDescription(NSWindow *window, NSMutableDictionary *info) {
    if (!SpliceKit_windowIsSaveOrOpenPanel(window)) return;

    BOOL isOpenPanel = [window isKindOfClass:[NSOpenPanel class]];
    info[@"isFilePanel"] = @YES;
    info[@"panelKind"] = isOpenPanel ? @"open" : @"save";
    info[@"panelDismiss"] = @"cancel: on the panel only (confirm/Save/Open not supported from bridge)";

    NSSavePanel *panel = (NSSavePanel *)window;
    NSString *nameField = @"";
    if ([panel respondsToSelector:@selector(nameFieldStringValue)]) {
        NSString *n = panel.nameFieldStringValue;
        if ([n isKindOfClass:[NSString class]]) nameField = n;
    }
    info[@"nameField"] = nameField;

    NSString *directoryURL = @"";
    NSString *directoryPath = @"";
    if ([panel respondsToSelector:@selector(directoryURL)]) {
        NSURL *dir = panel.directoryURL;
        if ([dir isKindOfClass:[NSURL class]]) {
            directoryURL = dir.absoluteString ?: @"";
            directoryPath = dir.path ?: @"";
        }
    }
    info[@"directoryURL"] = directoryURL;
    info[@"directoryPath"] = directoryPath;
}

static NSDictionary *SpliceKit_filePanelConfirmUnsupportedError(NSWindow *window) {
    NSMutableDictionary *panelInfo = [NSMutableDictionary dictionary];
    SpliceKit_enrichFilePanelDescription(window, panelInfo);
    NSString *nameField = [panelInfo[@"nameField"] isKindOfClass:[NSString class]]
        ? panelInfo[@"nameField"] : @"";
    NSString *directory = [panelInfo[@"directoryPath"] isKindOfClass:[NSString class]]
        ? panelInfo[@"directoryPath"] : @"";
    if (directory.length == 0 &&
        [panelInfo[@"directoryURL"] isKindOfClass:[NSString class]]) {
        directory = panelInfo[@"directoryURL"];
    }
    if (directory.length == 0) directory = @"(unknown)";
    return @{@"error": [NSString stringWithFormat:
        @"A save/open panel cannot be confirmed programmatically from the bridge on this Final Cut Pro build; "
        @"only cancelling is supported (dismiss_dialog with action cancel, or click_dialog_button Cancel). "
        @"A human must complete the panel, or cancel it and use a tool that takes an explicit path instead. "
        @"Panel name field: \"%@\"; directory: %@.",
        nameField, directory]};
}

static BOOL SpliceKit_dispatchFilePanelCancel(NSWindow *window) {
    if (!SpliceKit_windowIsSaveOrOpenPanel(window)) return NO;
    SEL sel = @selector(cancel:);
    if (![window respondsToSelector:sel]) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(window, sel, nil);
    return YES;
}

static BOOL SpliceKit_filePanelButtonTitleIsConfirm(NSString *title) {
    NSString *t = [[title lowercaseString] stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [t isEqualToString:@"ok"] || [t isEqualToString:@"save"] || [t isEqualToString:@"open"];
}

static BOOL SpliceKit_filePanelButtonTitleIsCancel(NSString *title) {
    NSString *t = [[title lowercaseString] stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [t isEqualToString:@"cancel"];
}

// AppKit builds a checkbox as a plain NSButton whose cell both shows and highlights
// its state by its contents; a radio button has the same cell shape and is told apart
// by the image the cell draws. FCP additionally ships button subclasses with
// "Checkbox" in the class name.
//
// The previous test was `className contains "Checkbox" || allowsMixedState`, which
// matched neither: -allowsMixedState is NO on an ordinary two-state checkbox, and
// FCP's Remove Attributes sheet is built from stock NSButtons. That sheet therefore
// reported zero checkboxes and could not be driven.
static BOOL SpliceKit_buttonIsCheckboxLike(NSButton *btn, BOOL *outIsRadio) {
    if (outIsRadio) *outIsRadio = NO;
    if (!btn) return NO;
    @try {
        NSString *cls = [btn className] ?: @"";
        if ([cls rangeOfString:@"heckbox" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [cls rangeOfString:@"heckBox" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }

        id cell = [btn cell];
        if (![cell isKindOfClass:[NSButtonCell class]]) return NO;
        NSButtonCell *bc = (NSButtonCell *)cell;

        // Push, toggle and momentary buttons all differ here: only switch and radio
        // cells use NSContentsCellMask for both.
        if ([bc showsStateBy] != NSContentsCellMask) return NO;
        if ([bc highlightsBy] != NSContentsCellMask) return NO;

        NSString *imageName = [[bc image] name] ?: @"";
        if ([imageName isEqualToString:@"NSRadioButton"]) {
            if (outIsRadio) *outIsRadio = YES;
        }
        return YES;
    } @catch (NSException *e) {}
    return NO;
}

// Flat dump of a dialog's view hierarchy: class, title, frame and depth per node.
// detect_dialog(view_tree=True) returns this so an unfamiliar sheet can be read
// without guessing which AppKit class FCP used to build it. Iterative on purpose —
// a recursive walker over a deep view tree is what crashed toggle_dialog_checkbox.
static NSArray *SpliceKit_describeViewTree(NSView *root, NSUInteger maxNodes) {
    NSMutableArray *nodes = [NSMutableArray array];
    if (!root) return nodes;
    if (maxNodes == 0) maxNodes = 2048;

    NSMutableArray *stack = [NSMutableArray arrayWithObject:@[root, @0]];
    while (stack.count > 0 && nodes.count < maxNodes) {
        NSArray *entry = [stack lastObject];
        [stack removeLastObject];
        NSView *view = entry[0];
        NSInteger depth = [entry[1] integerValue];
        if (!view) continue;

        NSMutableDictionary *node = [NSMutableDictionary dictionary];
        node[@"depth"] = @(depth);
        node[@"class"] = NSStringFromClass([view class]);
        @try {
            node[@"frame"] = NSStringFromRect([view frame]);
            node[@"hidden"] = @([view isHidden]);
            if ([view respondsToSelector:@selector(identifier)]) {
                NSString *ident = [view identifier];
                if (ident.length > 0) node[@"identifier"] = ident;
            }
            if ([view isKindOfClass:[NSControl class]]) {
                NSControl *ctl = (NSControl *)view;
                node[@"enabled"] = @([ctl isEnabled]);
                NSString *sv = [ctl stringValue];
                if (sv.length > 0) node[@"stringValue"] = sv;
            }
            if ([view isKindOfClass:[NSButton class]]) {
                NSButton *btn = (NSButton *)view;
                node[@"title"] = [btn title] ?: @"";
                node[@"state"] = @([btn state]);
                id cell = [btn cell];
                if ([cell isKindOfClass:[NSButtonCell class]]) {
                    NSButtonCell *bc = (NSButtonCell *)cell;
                    node[@"cellClass"] = NSStringFromClass([bc class]);
                    node[@"showsStateBy"] = @([bc showsStateBy]);
                    node[@"highlightsBy"] = @([bc highlightsBy]);
                    NSString *imageName = [[bc image] name];
                    if (imageName.length > 0) node[@"cellImage"] = imageName;
                }
            }
        } @catch (NSException *e) {
            node[@"error"] = e.reason ?: @"threw while being read";
        }
        [nodes addObject:node];

        NSArray *subviews = SpliceKit_safeSubviews(view);
        for (NSView *sub in [subviews reverseObjectEnumerator]) {
            if (sub) [stack addObject:@[sub, @(depth + 1)]];
        }
    }
    if (nodes.count >= maxNodes) {
        [nodes addObject:@{@"note": [NSString stringWithFormat:
            @"stopped at the %lu-node cap", (unsigned long)maxNodes]}];
    }
    return nodes;
}

static void SpliceKit_collectUIElements(NSView *view, NSMutableArray *buttons,
                                         NSMutableArray *textFields, NSMutableArray *labels,
                                         NSMutableArray *checkboxes, NSMutableArray *popups,
                                         int depth) {
    if (!view || depth > 15) return;

    NSArray *subviews = SpliceKit_safeSubviews(view);
    if (!subviews) return;

    for (NSView *subview in subviews) {
        if (!subview) continue;
        @try {
        if ([subview isKindOfClass:[NSButton class]]) {
            NSButton *btn = (NSButton *)subview;
            NSString *title = [btn title] ?: @"";
            NSInteger bezelStyle = [btn bezelStyle];
            BOOL isRadio = NO;
            BOOL isCheckbox = SpliceKit_buttonIsCheckboxLike(btn, &isRadio);
            if (isCheckbox) {
                NSInteger state = [btn state];
                [checkboxes addObject:@{
                    @"index": @(checkboxes.count),
                    @"title": title,
                    @"checked": @(state == NSControlStateValueOn),
                    @"state": state == NSControlStateValueMixed ? @"mixed"
                             : (state == NSControlStateValueOn ? @"on" : @"off"),
                    @"kind": isRadio ? @"radio" : @"checkbox",
                    @"enabled": @([btn isEnabled]),
                    @"tag": @([btn tag])
                }];
            } else if (title.length > 0) {
                [buttons addObject:@{
                    @"title": title,
                    @"enabled": @([btn isEnabled]),
                    @"tag": @([btn tag]),
                    @"keyEquivalent": [btn keyEquivalent] ?: @"",
                    @"bezelStyle": @(bezelStyle)
                }];
            }
        } else if ([subview isKindOfClass:[NSTextField class]]) {
            NSTextField *tf = (NSTextField *)subview;
            if ([tf isEditable]) {
                [textFields addObject:@{
                    @"value": [tf stringValue] ?: @"",
                    @"placeholder": [tf placeholderString] ?: @"",
                    @"editable": @YES,
                    @"tag": @([tf tag])
                }];
            } else {
                NSString *text = [tf stringValue] ?: @"";
                if (text.length > 0) {
                    [labels addObject:@{
                        @"text": text,
                        @"tag": @([tf tag])
                    }];
                }
            }
        } else if ([subview isKindOfClass:[NSPopUpButton class]]) {
            NSPopUpButton *popup = (NSPopUpButton *)subview;
            NSMutableArray *items = [NSMutableArray array];
            for (NSMenuItem *item in [popup itemArray]) {
                if (![item isSeparatorItem]) {
                    [items addObject:@{
                        @"title": [item title] ?: @"",
                        @"selected": @([popup selectedItem] == item)
                    }];
                }
            }
            [popups addObject:@{
                @"selectedTitle": [[popup titleOfSelectedItem] ?: @"" copy],
                @"items": items,
                @"tag": @([popup tag])
            }];
        } else if ([subview isKindOfClass:[NSSegmentedControl class]]) {
            NSSegmentedControl *seg = (NSSegmentedControl *)subview;
            NSMutableArray *segments = [NSMutableArray array];
            for (NSInteger i = 0; i < seg.segmentCount; i++) {
                [segments addObject:@{
                    @"label": [seg labelForSegment:i] ?: @"",
                    @"selected": @(seg.selectedSegment == i),
                    @"index": @(i)
                }];
            }
            [labels addObject:@{@"text": @"[segmented control]", @"segments": segments}];
        } else if ([subview isKindOfClass:[NSSlider class]]) {
            NSSlider *slider = (NSSlider *)subview;
            [labels addObject:@{
                @"text": @"[slider]",
                @"value": @([slider doubleValue]),
                @"min": @([slider minValue]),
                @"max": @([slider maxValue])
            }];
        }

        } @catch (NSException *e) {
            // Skip any view that throws when accessed
        }

        // Recurse into subviews
        SpliceKit_collectUIElements(subview, buttons, textFields, labels,
                                    checkboxes, popups, depth + 1);
    }
}

static NSDictionary *SpliceKit_describeWindowWithViewTree(NSWindow *window, BOOL includeViewTree) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"title"] = [window title] ?: @"";
    info[@"class"] = NSStringFromClass([window class]);
    info[@"visible"] = @([window isVisible]);
    info[@"isSheet"] = @([window isSheet]);
    info[@"isModal"] = @(window == [NSApp modalWindow]);
    info[@"frame"] = NSStringFromRect([window frame]);

    NSMutableArray *buttons = [NSMutableArray array];
    NSMutableArray *textFields = [NSMutableArray array];
    NSMutableArray *labels = [NSMutableArray array];
    NSMutableArray *checkboxes = [NSMutableArray array];
    NSMutableArray *popups = [NSMutableArray array];

    SpliceKit_collectUIElements([window contentView], buttons, textFields,
                                labels, checkboxes, popups, 0);

    info[@"buttons"] = buttons;
    info[@"textFields"] = textFields;
    info[@"labels"] = labels;
    info[@"checkboxes"] = checkboxes;
    info[@"popups"] = popups;

    // A name for the dialog when its title is a placeholder (QA run 3: the Compound Clip
    // Name sheet is titled "Window"): the labels of its fields, else its buttons, else
    // its class. The pseudo-labels collectUIElements adds ("[slider]", "[segmented
    // control]") are not labels.
    NSString *title = info[@"title"];
    NSString *summary = title;
    if (title.length == 0 || [title isEqualToString:@"Window"] || [title isEqualToString:@"Untitled"]
        || [title isEqualToString:@"Panel"]) {
        NSMutableArray *texts = [NSMutableArray array];
        for (NSDictionary *label in labels) {              // field labels first ("Compound Clip Name:")
            NSString *t = label[@"text"];
            if ([t isKindOfClass:[NSString class]] && t.length > 0 && ![t hasPrefix:@"["] && [t hasSuffix:@":"]) {
                [texts addObject:t];
            }
            if (texts.count >= 3) break;
        }
        for (NSDictionary *label in labels) {              // other text only when fewer than two of those
            if (texts.count >= 2) break;
            NSString *t = label[@"text"];
            if ([t isKindOfClass:[NSString class]] && t.length > 0 && ![t hasPrefix:@"["] && ![t hasSuffix:@":"]) {
                [texts addObject:t];
            }
        }
        if (texts.count > 0) {
            summary = [NSString stringWithFormat:@"fields %@", [texts componentsJoinedByString:@" / "]];
        } else {
            for (NSDictionary *button in buttons) {
                NSString *t = button[@"title"];
                if ([t isKindOfClass:[NSString class]] && t.length > 0) [texts addObject:t];
                if (texts.count >= 3) break;
            }
            summary = texts.count > 0
                ? [NSString stringWithFormat:@"buttons %@", [texts componentsJoinedByString:@" / "]]
                : NSStringFromClass([window class]);
        }
    }
    info[@"summary"] = summary ?: @"";

    if (includeViewTree) {
        info[@"viewTree"] = SpliceKit_describeViewTree([window contentView], 2048);
    }

    SpliceKit_enrichFilePanelDescription(window, info);

    return info;
}

NSDictionary *SpliceKit_describeWindow(NSWindow *window) {
    return SpliceKit_describeWindowWithViewTree(window, NO);
}

NSDictionary *SpliceKit_handleDialogDetect(NSDictionary *params) {
    // view_tree dumps each dialog's raw view hierarchy. Without it an unfamiliar
    // sheet can only be described through the element classes this file already
    // knows about, so anything FCP builds from something else reads as empty.
    BOOL includeViewTree = [params[@"viewTree"] boolValue] || [params[@"view_tree"] boolValue];
    __block NSDictionary *result = nil;
    BOOL answered = SpliceKit_executeOnMainThreadWithTimeout(^{
        @try {
            NSMutableArray *dialogs = [NSMutableArray array];
            NSMutableArray *overlays = [NSMutableArray array];

            // Check for modal window
            NSWindow *modalWindow = [NSApp modalWindow];
            if (modalWindow) {
                NSMutableDictionary *d = [SpliceKit_describeWindowWithViewTree(modalWindow, includeViewTree) mutableCopy];
                d[@"type"] = @"modal";
                [dialogs addObject:d];
            }

            // Check for sheets on all windows
            for (NSWindow *window in [NSApp windows]) {
                NSWindow *sheet = [window attachedSheet];
                if (sheet) {
                    NSMutableDictionary *d = [SpliceKit_describeWindowWithViewTree(sheet, includeViewTree) mutableCopy];
                    d[@"type"] = @"sheet";
                    d[@"parentWindow"] = [window title] ?: @"";
                    [dialogs addObject:d];
                }
            }

            // Check for any visible panels (alerts, floating windows, etc.)
            for (NSWindow *window in [NSApp windows]) {
                if (![window isVisible]) continue;
                if (modalWindow && window == modalWindow) continue;

                // Check if this is a panel/alert type window
                BOOL isPanel = [window isKindOfClass:[NSPanel class]];
                BOOL isAlert = [window isKindOfClass:NSClassFromString(@"NSAlertPanel") ?: [NSNull class]];
                BOOL isSheet = [window isSheet];
                BOOL isProgressPanel = [[window className] containsString:@"Progress"];
                BOOL isSharePanel = [[window className] containsString:@"Share"];

                // Check FCP-specific dialog classes
                NSString *className = NSStringFromClass([window class]);
                BOOL isFCPDialog = [className hasPrefix:@"FF"] && (
                    [className containsString:@"Panel"] ||
                    [className containsString:@"Sheet"] ||
                    [className containsString:@"Alert"] ||
                    [className containsString:@"Dialog"] ||
                    [className containsString:@"Progress"] ||
                    [className containsString:@"Window"] // Custom windows
                );

                if (isAlert || isProgressPanel || isSharePanel || isFCPDialog) {
                    NSMutableDictionary *d = [SpliceKit_describeWindowWithViewTree(window, includeViewTree) mutableCopy];
                    d[@"type"] = isAlert ? @"alert" : (isProgressPanel ? @"progress" :
                                  (isSharePanel ? @"share" : @"panel"));
                    // FCP's own chrome windows (FFOSCOverlayWindow: the Viewer's on-screen
                    // controls, up after every import) matched the "FF…Window" rule and made
                    // hasDialog true with nothing to answer. A non-modal window that is an
                    // overlay, or offers no control at all, is reported apart.
                    // Matched by what the window is, not by what collectUIElements found in
                    // it: a panel whose buttons are custom views reads as control-less and
                    // must still count as a dialog (flagged noControls instead).
                    BOOL noControls = [d[@"buttons"] count] == 0 && [d[@"textFields"] count] == 0 &&
                                      [d[@"checkboxes"] count] == 0 && [d[@"popups"] count] == 0;
                    BOOL isOverlay = window != [NSApp modalWindow] &&
                                     ([className containsString:@"Overlay"] || [window ignoresMouseEvents]);
                    if (noControls) d[@"noControls"] = @YES;
                    if (isOverlay) {
                        [overlays addObject:@{@"title": d[@"title"] ?: @"", @"class": className,
                                              @"frame": d[@"frame"] ?: @""}];
                        continue;
                    }
                    // Avoid duplicates
                    BOOL isDupe = NO;
                    for (NSDictionary *existing in dialogs) {
                        if ([existing[@"title"] isEqualToString:d[@"title"]] &&
                            [existing[@"class"] isEqualToString:d[@"class"]]) {
                            isDupe = YES; break;
                        }
                    }
                    if (!isDupe) [dialogs addObject:d];
                }

                // Also check for NSAlert-style windows (they have specific structure)
                if (isPanel && !isSheet) {
                    NSArray *buttons = [window contentView].subviews;
                    BOOL hasAlertButton = NO;
                    for (NSView *v in buttons) {
                        if ([v isKindOfClass:[NSButton class]] &&
                            [[(NSButton *)v keyEquivalent] isEqualToString:@"\r"]) {
                            hasAlertButton = YES;
                            break;
                        }
                    }
                    if (hasAlertButton) {
                        NSMutableDictionary *d = [SpliceKit_describeWindowWithViewTree(window, includeViewTree) mutableCopy];
                        d[@"type"] = @"alert";
                        BOOL isDupe = NO;
                        for (NSDictionary *existing in dialogs) {
                            if ([existing[@"title"] isEqualToString:d[@"title"]]) {
                                isDupe = YES; break;
                            }
                        }
                        if (!isDupe) [dialogs addObject:d];
                    }
                }
            }

            NSMutableDictionary *r = [@{
                @"hasDialog": @(dialogs.count > 0),
                @"dialogCount": @(dialogs.count),
                @"dialogs": dialogs
            } mutableCopy];
            if (overlays.count > 0) r[@"overlays"] = overlays;
            result = r;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    }, 3.0, NO);
    if (!answered) {
        // The main thread is inside something long (an import's progress sheet, a
        // modal the bridge cannot see from here). Answer from the window server
        // instead of timing out: titles and sizes of FCP's on-screen windows.
        NSArray *windows = SpliceKit_windowSnapshotOffMain();
        NSMutableArray *likelyDialogs = [NSMutableArray array];
        for (NSDictionary *w in windows) {
            NSString *title = w[@"title"];
            NSRect frame = NSRectFromString(w[@"bounds"]);
            int layer = [w[@"layer"] intValue];
            // By window level: a modal panel or alert sits at the modal-panel level (8);
            // a sheet at the document level (0) and much smaller than the document
            // window. Utility panels (SpliceKit's Transcript Editor, Lua REPL, Log,
            // Mixer; FCP's HUDs) float at level 3 and are not dialogs, nor are menus,
            // popups and overlays at higher levels.
            BOOL modalLevel = (layer == kCGModalPanelWindowLevel);
            BOOL sheetLike = (layer == kCGNormalWindowLevel && frame.size.width < 900 && frame.size.height < 700);
            if ((modalLevel || sheetLike) && ![title containsString:@"Overlay"]) {
                [likelyDialogs addObject:w];
            }
        }
        return @{
            @"mainThreadBusy": @YES,
            @"hasDialog": @(likelyDialogs.count > 0),
            @"dialogCount": @(likelyDialogs.count),
            @"dialogs": likelyDialogs,
            @"windows": windows,
            @"note": @"Final Cut Pro's main thread did not answer within 3 s, so this is read from the "
                     @"window server: window titles, sizes and levels only, no buttons or fields; dialogs are "
                     @"guessed from the window level (modal panels) and size (sheets). A window named like "
                     @"\"Import XML\" is a progress sheet; wait for it rather than retrying the operation.",
        };
    }
    return result ?: @{@"error": @"Dialog detect failed"};
}

NSDictionary *SpliceKit_handleDialogClick(NSDictionary *params) {
    NSString *buttonTitle = params[@"button"]; // button title to click
    NSNumber *buttonIndex = params[@"index"];   // or button index (0-based)
    if (!buttonTitle && !buttonIndex) {
        return @{@"error": @"button (title) or index parameter required"};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // Find the dialog window (modal > sheet > panel)
            NSWindow *dialogWindow = [NSApp modalWindow];

            if (!dialogWindow) {
                // Check for sheets
                for (NSWindow *window in [NSApp windows]) {
                    NSWindow *sheet = [window attachedSheet];
                    if (sheet) { dialogWindow = sheet; break; }
                }
            }

            if (!dialogWindow) {
                // Check for visible panels
                for (NSWindow *window in [NSApp windows]) {
                    if (![window isVisible]) continue;
                    if ([window isKindOfClass:[NSPanel class]] && ![window isSheet]) {
                        NSString *className = NSStringFromClass([window class]);
                        if ([className hasPrefix:@"FF"] || [className containsString:@"Alert"]) {
                            dialogWindow = window;
                            break;
                        }
                    }
                }
            }

            if (!dialogWindow) {
                result = @{@"error": @"No dialog found to interact with"};
                return;
            }

            // Use BFS to safely find all buttons
            NSArray<NSButton *> *buttonObjects = SpliceKit_findButtonsInView([dialogWindow contentView]);

            NSButton *targetButton = nil;

            if (buttonTitle) {
                // Find button by title (case-insensitive)
                for (NSButton *btn in buttonObjects) {
                    if ([[btn title] caseInsensitiveCompare:buttonTitle] == NSOrderedSame) {
                        targetButton = btn;
                        break;
                    }
                }
                if (!targetButton) {
                    // Try partial match
                    for (NSButton *btn in buttonObjects) {
                        if ([[btn title] localizedCaseInsensitiveContainsString:buttonTitle]) {
                            targetButton = btn;
                            break;
                        }
                    }
                }
            } else if (buttonIndex) {
                NSInteger idx = [buttonIndex integerValue];
                if (idx >= 0 && idx < (NSInteger)buttonObjects.count) {
                    targetButton = buttonObjects[idx];
                }
            }

            if (!targetButton && buttonTitle && SpliceKit_windowIsSaveOrOpenPanel(dialogWindow)) {
                if (SpliceKit_filePanelButtonTitleIsConfirm(buttonTitle)) {
                    result = SpliceKit_filePanelConfirmUnsupportedError(dialogWindow);
                    return;
                }
                if (SpliceKit_filePanelButtonTitleIsCancel(buttonTitle) &&
                    SpliceKit_dispatchFilePanelCancel(dialogWindow)) {
                    NSMutableDictionary *answer = [@{
                        @"status": @"ok",
                        @"clicked": buttonTitle,
                        @"dispatch": @"panelAction",
                        @"panelAction": @"cancel:",
                        @"dialog": [dialogWindow title] ?: @""
                    } mutableCopy];
                    SpliceKit_dialogApplySettle(answer, nil, NO);
                    result = answer;
                    return;
                }
            }

            if (!targetButton) {
                NSMutableArray *available = [NSMutableArray array];
                for (NSButton *btn in buttonObjects) {
                    [available addObject:[btn title]];
                }
                if (SpliceKit_windowIsSaveOrOpenPanel(dialogWindow)) {
                    result = SpliceKit_filePanelConfirmUnsupportedError(dialogWindow);
                } else {
                    result = @{@"error": [NSString stringWithFormat:@"Button '%@' not found. Available: %@",
                                buttonTitle ?: [buttonIndex stringValue],
                                [available componentsJoinedByString:@", "]]};
                }
                return;
            }

            if (![targetButton isEnabled]) {
                result = @{@"error": [NSString stringWithFormat:@"Button '%@' is disabled", [targetButton title]]};
                return;
            }

            if (SpliceKit_windowIsSaveOrOpenPanel(dialogWindow) &&
                SpliceKit_filePanelButtonTitleIsConfirm([targetButton title])) {
                result = SpliceKit_filePanelConfirmUnsupportedError(dialogWindow);
                return;
            }

            BOOL waitForUndo = !SpliceKit_dialogButtonIsCancelLike(targetButton);
            NSDictionary *undoBefore = waitForUndo ? SpliceKit_dialogUndoSettleSnapshot() : nil;
            [targetButton performClick:nil];

            NSMutableDictionary *answer = [@{@"status": @"ok", @"clicked": [targetButton title],
                                              @"dialog": [dialogWindow title] ?: @""} mutableCopy];
            SpliceKit_dialogApplySettle(answer, undoBefore, waitForUndo);
            result = answer;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Dialog click failed"};
}

NSDictionary *SpliceKit_handleDialogFill(NSDictionary *params) {
    NSString *value = params[@"value"];
    NSNumber *fieldIndex = params[@"index"] ?: @(0);
    if (!value) return @{@"error": @"value parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // Find dialog window
            NSWindow *dialogWindow = [NSApp modalWindow];
            if (!dialogWindow) {
                for (NSWindow *window in [NSApp windows]) {
                    @try {
                        NSWindow *sheet = [window attachedSheet];
                        if (sheet) { dialogWindow = sheet; break; }
                    } @catch (NSException *e) {}
                }
            }
            if (!dialogWindow) {
                result = @{@"error": @"No dialog found"};
                return;
            }

            // Use the collectUIElements function which has full safety
            NSMutableArray *buttons = [NSMutableArray array];
            NSMutableArray *textFields = [NSMutableArray array];
            NSMutableArray *labels = [NSMutableArray array];
            NSMutableArray *checkboxes = [NSMutableArray array];
            NSMutableArray *popups = [NSMutableArray array];

            SpliceKit_collectUIElements([dialogWindow contentView], buttons, textFields,
                                        labels, checkboxes, popups, 0);

            // textFields array already contains only editable fields (from collectUIElements)
            // But we need the actual NSTextField objects, not dicts.
            // So let's find them differently - use the first responder chain.

            // Simple approach: find editable text fields using a breadth-first search
            // with maximum safety
            NSMutableArray *editableFields = [NSMutableArray array];
            NSMutableArray *queue = [NSMutableArray arrayWithObject:[dialogWindow contentView]];

            while (queue.count > 0 && editableFields.count < 20) {
                NSView *current = queue[0];
                [queue removeObjectAtIndex:0];
                if (!current) continue;

                @try {
                    if ([current isKindOfClass:[NSTextField class]]) {
                        NSTextField *tf = (NSTextField *)current;
                        // Use respondsToSelector as extra safety
                        if ([tf respondsToSelector:@selector(isEditable)] &&
                            [tf respondsToSelector:@selector(setStringValue:)]) {
                            BOOL editable = NO;
                            @try { editable = [tf isEditable]; } @catch (NSException *e) {}
                            if (editable) {
                                [editableFields addObject:tf];
                            }
                        }
                    }

                    // Add child views to queue (BFS)
                    NSArray *subs = SpliceKit_safeSubviews(current);
                    if (subs) {
                        [queue addObjectsFromArray:subs];
                    }
                } @catch (NSException *e) {
                    // Skip this view entirely
                }
            }

            NSInteger idx = [fieldIndex integerValue];
            if (idx >= 0 && idx < (NSInteger)editableFields.count) {
                NSTextField *field = editableFields[idx];
                @try {
                    [field setStringValue:value];
                    result = @{@"status": @"ok", @"field": @(idx), @"value": value};
                } @catch (NSException *e) {
                    result = @{@"error": [NSString stringWithFormat:@"Cannot set field: %@", e.reason]};
                }
            } else {
                result = @{@"error": [NSString stringWithFormat:@"Field index %ld not found (have %lu fields)",
                            (long)idx, (unsigned long)editableFields.count]};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Dialog fill failed"};
}

NSDictionary *SpliceKit_handleDialogCheckbox(NSDictionary *params) {
    NSString *checkboxTitle = params[@"checkbox"];
    NSNumber *indexParam = params[@"index"];
    NSNumber *checked = params[@"checked"]; // YES/NO
    if (!checkboxTitle && !indexParam) {
        return @{@"error": @"checkbox (title) or index parameter required"};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSWindow *dialogWindow = [NSApp modalWindow];
            if (!dialogWindow) {
                for (NSWindow *window in [NSApp windows]) {
                    NSWindow *sheet = [window attachedSheet];
                    if (sheet) { dialogWindow = sheet; break; }
                }
            }
            if (!dialogWindow) { result = @{@"error": @"No dialog found"}; return; }

            // Collect every checkbox first, in the same order detect_dialog reports
            // them, so an index from that listing selects the same control and a miss
            // can say what was actually there. Iterative walk: a recursive one over a
            // deep view tree is what used to segfault this handler.
            NSMutableArray<NSButton *> *found = [NSMutableArray array];
            const NSUInteger kMaxDialogViewNodes = 8192;
            NSMutableArray *stack = [NSMutableArray array];
            NSView *rootView = [dialogWindow contentView];
            NSArray *rootSubs = rootView ? SpliceKit_safeSubviews(rootView) : nil;
            if (rootSubs) {
                for (NSInteger i = (NSInteger)rootSubs.count - 1; i >= 0; i--) {
                    NSView *v = rootSubs[i];
                    if (v) [stack addObject:v];
                }
            }
            NSUInteger visited = 0;
            while (stack.count > 0 && visited < kMaxDialogViewNodes) {
                NSView *subview = stack.lastObject;
                [stack removeLastObject];
                visited++;
                @try {
                    if ([subview isKindOfClass:[NSButton class]]) {
                        NSButton *btn = (NSButton *)subview;
                        BOOL isRadio = NO;
                        if (SpliceKit_buttonIsCheckboxLike(btn, &isRadio)) {
                            [found addObject:btn];
                        }
                    }
                    NSArray *subs = SpliceKit_safeSubviews(subview);
                    if (subs) {
                        for (NSInteger i = (NSInteger)subs.count - 1; i >= 0; i--) {
                            NSView *child = subs[i];
                            if (child) [stack addObject:child];
                        }
                    }
                } @catch (NSException *e) {
                    // Skip this view
                }
            }

            NSButton *targetCB = nil;
            if (checkboxTitle.length > 0) {
                for (NSButton *btn in found) {
                    if ([[btn title] localizedCaseInsensitiveContainsString:checkboxTitle]) {
                        targetCB = btn;
                        break;
                    }
                }
            } else {
                NSInteger idx = [indexParam integerValue];
                if (idx >= 0 && idx < (NSInteger)found.count) targetCB = found[(NSUInteger)idx];
            }

            if (!targetCB) {
                NSMutableArray *available = [NSMutableArray array];
                for (NSButton *btn in found) {
                    [available addObject:[btn title] ?: @""];
                }
                result = @{
                    @"error": checkboxTitle.length > 0
                        ? [NSString stringWithFormat:@"Checkbox '%@' not found", checkboxTitle]
                        : [NSString stringWithFormat:@"No checkbox at index %@", indexParam],
                    @"available": available,
                    @"dialog": [dialogWindow title] ?: NSStringFromClass([dialogWindow class]),
                };
                return;
            }

            if (checked) {
                [targetCB setState:[checked boolValue] ? NSControlStateValueOn : NSControlStateValueOff];
                // setState: alone updates the control but does not run its action, so
                // a sheet that enables its OK button from the action never sees it.
                @try {
                    SEL action = [targetCB action];
                    id target = [targetCB target];
                    if (action && target) {
                        ((void (*)(id, SEL, id))objc_msgSend)(target, action, targetCB);
                    }
                } @catch (NSException *e) {}
            } else {
                [targetCB performClick:nil];
            }
            result = @{@"status": @"ok", @"checkbox": [targetCB title] ?: @"",
                      @"checked": @([targetCB state] == NSControlStateValueOn),
                      @"checkboxCount": @(found.count)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Checkbox toggle failed"};
}

NSDictionary *SpliceKit_handleDialogPopup(NSDictionary *params) {
    NSString *selection = params[@"select"]; // item title to select
    NSNumber *popupIndex = params[@"popupIndex"] ?: @(0); // which popup (if multiple)
    if (!selection) return @{@"error": @"select parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSWindow *dialogWindow = [NSApp modalWindow];
            if (!dialogWindow) {
                for (NSWindow *window in [NSApp windows]) {
                    NSWindow *sheet = [window attachedSheet];
                    if (sheet) { dialogWindow = sheet; break; }
                }
            }
            if (!dialogWindow) { result = @{@"error": @"No dialog found"}; return; }

            NSMutableArray *popups = [NSMutableArray array];
            const NSUInteger kMaxDialogViewNodes = 8192;
            NSMutableArray *stack = [NSMutableArray array];
            NSView *rootView = [dialogWindow contentView];
            NSArray *rootSubs = rootView ? SpliceKit_safeSubviews(rootView) : nil;
            if (rootSubs) {
                for (NSInteger i = (NSInteger)rootSubs.count - 1; i >= 0; i--) {
                    NSView *v = rootSubs[i];
                    if (v) [stack addObject:v];
                }
            }
            NSUInteger visited = 0;
            while (stack.count > 0 && visited < kMaxDialogViewNodes) {
                NSView *subview = stack.lastObject;
                [stack removeLastObject];
                visited++;
                @try {
                    if ([subview isKindOfClass:[NSPopUpButton class]]) {
                        [popups addObject:subview];
                    }
                    NSArray *subs = SpliceKit_safeSubviews(subview);
                    if (subs) {
                        for (NSInteger i = (NSInteger)subs.count - 1; i >= 0; i--) {
                            NSView *child = subs[i];
                            if (child) [stack addObject:child];
                        }
                    }
                } @catch (NSException *e) {
                    // Skip this view
                }
            }

            NSInteger idx = [popupIndex integerValue];
            if (idx >= 0 && idx < (NSInteger)popups.count) {
                NSPopUpButton *popup = popups[idx];
                [popup selectItemWithTitle:selection];
                if ([popup selectedItem]) {
                    // Trigger the action
                    if ([popup action]) {
                        ((void (*)(id, SEL, id))objc_msgSend)([popup target], [popup action], popup);
                    }
                    result = @{@"status": @"ok", @"selected": selection, @"popupIndex": @(idx)};
                } else {
                    NSMutableArray *available = [NSMutableArray array];
                    for (NSMenuItem *item in [popup itemArray]) {
                        if (![item isSeparatorItem]) [available addObject:[item title]];
                    }
                    result = @{@"error": [NSString stringWithFormat:@"Item '%@' not found. Available: %@",
                                selection, [available componentsJoinedByString:@", "]]};
                }
            } else {
                result = @{@"error": [NSString stringWithFormat:@"Popup index %ld not found (have %lu)",
                            (long)idx, (unsigned long)popups.count]};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Popup select failed"};
}

// BFS helper to find buttons safely in a view hierarchy
static NSWindow *SpliceKit_findDialogWindow(void) {
    NSWindow *dialogWindow = [NSApp modalWindow];
    if (!dialogWindow) {
        for (NSWindow *window in [NSApp windows]) {
            @try {
                NSWindow *sheet = [window attachedSheet];
                if (sheet) { dialogWindow = sheet; break; }
            } @catch (NSException *e) {}
        }
    }
    return dialogWindow;
}

static NSDictionary *SpliceKit_dialogUndoSettleSnapshot(void) {
    id um = SpliceKit_getUndoManager();
    if (!um) return @{@"canUndo": @NO, @"undoActionName": @""};
    BOOL canUndo = ((BOOL (*)(id, SEL))objc_msgSend)(um, @selector(canUndo));
    id undoName = canUndo ? ((id (*)(id, SEL))objc_msgSend)(um, @selector(undoActionName)) : nil;
    NSString *name = [undoName isKindOfClass:[NSString class]] ? undoName : @"";
    return @{@"canUndo": @(canUndo), @"undoActionName": name};
}

static BOOL SpliceKit_dialogUndoSettleChanged(NSDictionary *before, NSDictionary *after) {
    if (!before || !after) return NO;
    if ([before[@"canUndo"] boolValue] != [after[@"canUndo"] boolValue]) return YES;
    return ![[before[@"undoActionName"] description] isEqualToString:[after[@"undoActionName"] description]];
}

// After a dialog button click: spin the main run loop until the dialog is gone and, when
// waitForUndo is YES, the library undo snapshot differs (bounded at 2s).
static void SpliceKit_dialogApplySettle(NSMutableDictionary *result, NSDictionary *undoBefore,
                                        BOOL waitForUndo) {
    if (result[@"error"]) return;
    NSDate *start = [NSDate date];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while ([deadline timeIntervalSinceNow] > 0.0) {
        BOOL dialogGone = (SpliceKit_findDialogWindow() == nil);
        if (!waitForUndo) {
            if (dialogGone) {
                result[@"settled"] = @YES;
                result[@"settleMs"] = @0;
                return;
            }
        } else if (dialogGone && SpliceKit_dialogUndoSettleChanged(undoBefore, SpliceKit_dialogUndoSettleSnapshot())) {
            NSInteger ms = (NSInteger)([[NSDate date] timeIntervalSinceDate:start] * 1000.0 + 0.5);
            result[@"settled"] = @YES;
            result[@"settleMs"] = @(ms);
            return;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
    }
    result[@"settled"] = @NO;
}

static BOOL SpliceKit_dialogButtonIsCancelLike(NSButton *btn) {
    @try {
        NSString *keyEq = [btn keyEquivalent] ?: @"";
        NSString *title = [btn title] ?: @"";
        return [keyEq isEqualToString:@"\033"] ||
               [title caseInsensitiveCompare:@"Cancel"] == NSOrderedSame ||
               [title caseInsensitiveCompare:@"Don't Save"] == NSOrderedSame;
    } @catch (NSException *e) { return NO; }
}

static NSButton *SpliceKit_findCancelDialogButton(NSArray<NSButton *> *allButtons) {
    for (NSButton *btn in allButtons) {
        if (SpliceKit_dialogButtonIsCancelLike(btn)) return btn;
    }
    return nil;
}

static NSButton *SpliceKit_findDefaultDialogButton(NSArray<NSButton *> *allButtons) {
    for (NSButton *btn in allButtons) {
        @try {
            if ([[btn keyEquivalent] isEqualToString:@"\r"] && [btn isEnabled]) return btn;
        } @catch (NSException *e) {}
    }
    for (NSButton *btn in allButtons) {
        @try {
            NSString *title = [btn title] ?: @"";
            if (([title caseInsensitiveCompare:@"OK"] == NSOrderedSame ||
                 [title caseInsensitiveCompare:@"Done"] == NSOrderedSame ||
                 [title caseInsensitiveCompare:@"Share"] == NSOrderedSame) &&
                [btn isEnabled]) {
                return btn;
            }
        } @catch (NSException *e) {}
    }
    return nil;
}

static NSArray<NSButton *> *SpliceKit_findButtonsInView(NSView *root) {
    NSMutableArray<NSButton *> *found = [NSMutableArray array];
    if (!root) return found;
    NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count > 0 && found.count < 50) {
        NSView *current = queue[0];
        [queue removeObjectAtIndex:0];
        if (!current) continue;
        @try {
            if ([current isKindOfClass:[NSButton class]]) {
                NSButton *btn = (NSButton *)current;
                if ([btn respondsToSelector:@selector(title)] && [btn title].length > 0) {
                    [found addObject:btn];
                }
            }
            NSArray *subs = SpliceKit_safeSubviews(current);
            if (subs) [queue addObjectsFromArray:subs];
        } @catch (NSException *e) {}
    }
    return found;
}

NSDictionary *SpliceKit_handleDialogDismiss(NSDictionary *params) {
    NSString *action = params[@"action"] ?: @"cancel";

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSWindow *dialogWindow = SpliceKit_findDialogWindow();
            if (!dialogWindow) {
                result = @{@"error": @"No dialog to dismiss"};
                return;
            }

            if (SpliceKit_windowIsSaveOrOpenPanel(dialogWindow)) {
                if (![action isEqualToString:@"cancel"]) {
                    result = SpliceKit_filePanelConfirmUnsupportedError(dialogWindow);
                    return;
                }
                if (SpliceKit_dispatchFilePanelCancel(dialogWindow)) {
                    result = @{@"status": @"ok", @"action": @"cancel", @"dispatch": @"panelAction",
                                 @"panelAction": @"cancel:"};
                    return;
                }
                result = @{@"error": @"Save/open panel did not respond to cancel:"};
                return;
            }

            NSArray<NSButton *> *allButtons = SpliceKit_findButtonsInView([dialogWindow contentView]);
            NSMutableDictionary *answer = nil;
            NSDictionary *undoBefore = nil;
            BOOL waitForUndo = NO;

            if ([action isEqualToString:@"cancel"]) {
                NSButton *cancelBtn = SpliceKit_findCancelDialogButton(allButtons);
                if (cancelBtn) {
                    [cancelBtn performClick:nil];
                    answer = [@{@"status": @"ok", @"action": @"cancel", @"clicked": [cancelBtn title]} mutableCopy];
                    waitForUndo = NO;
                } else if (SpliceKit_dispatchFilePanelCancel(dialogWindow)) {
                    answer = [@{@"status": @"ok", @"action": @"cancel", @"dispatch": @"panelAction",
                                 @"panelAction": @"cancel:"} mutableCopy];
                    waitForUndo = NO;
                } else {
                    [dialogWindow performClose:nil];
                    if (!SpliceKit_findDialogWindow()) {
                        answer = [@{@"status": @"ok", @"action": @"close"} mutableCopy];
                        waitForUndo = NO;
                    } else {
                        NSWindow *stillOpen = SpliceKit_findDialogWindow();
                        NSArray<NSButton *> *remaining = SpliceKit_findButtonsInView([stillOpen contentView]);
                        NSButton *defaultBtn = SpliceKit_findDefaultDialogButton(remaining);
                        if (defaultBtn) {
                            undoBefore = SpliceKit_dialogUndoSettleSnapshot();
                            [defaultBtn performClick:nil];
                            answer = [@{@"status": @"ok", @"action": @"cancel", @"clicked": [defaultBtn title],
                                         @"fellBackToDefault": @YES} mutableCopy];
                            waitForUndo = YES;
                        } else if (SpliceKit_dispatchFilePanelCancel(dialogWindow)) {
                            answer = [@{@"status": @"ok", @"action": @"cancel", @"dispatch": @"panelAction",
                                         @"panelAction": @"cancel:"} mutableCopy];
                            waitForUndo = NO;
                        } else {
                            result = @{@"error": @"No Cancel or default button found"};
                            return;
                        }
                    }
                }
            } else {
                NSButton *targetBtn = SpliceKit_findDefaultDialogButton(allButtons);
                if (targetBtn) {
                    undoBefore = SpliceKit_dialogUndoSettleSnapshot();
                    [targetBtn performClick:nil];
                    answer = [@{@"status": @"ok", @"action": action, @"clicked": [targetBtn title]} mutableCopy];
                    waitForUndo = YES;
                } else {
                    result = @{@"error": @"No default/OK button found"};
                    return;
                }
            }

            SpliceKit_dialogApplySettle(answer, undoBefore, waitForUndo);
            result = answer;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Dismiss failed"};
}
