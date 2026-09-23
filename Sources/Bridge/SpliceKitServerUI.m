//
//  SpliceKitServerUI.m
//  SpliceKit - Menu execute and list, panel toggles, workspaces, role assignment and
//  tool selection.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Menu Execute Handler
//
// Navigate and click any FCP menu item by path, e.g. ["File", "New", "Project..."].
// This is the escape hatch for actions that don't have a known ObjC selector.
//

NSDictionary *SpliceKit_handleMenuExecute(NSDictionary *params) {
    NSArray *menuPath = params[@"menuPath"];
    if (![menuPath isKindOfClass:[NSArray class]] || menuPath.count < 2) {
        // Say which of the two it is: "array required" when an array WAS given, just
        // a one-entry one, sends the caller looking for a serialisation problem.
        return @{@"error": [menuPath isKindOfClass:[NSArray class]]
            ? [NSString stringWithFormat:
                 @"menuPath needs at least a menu and an item, got %lu entry: %@",
                 (unsigned long)menuPath.count, menuPath]
            : @"menuPath array required (e.g. [\"File\", \"New\", \"Project...\"])"};
    }

    BOOL dryRun = [params[@"dry_run"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            NSMenu *mainMenu = ((id (*)(id, SEL))objc_msgSend)(app, @selector(mainMenu));
            if (!mainMenu) {
                result = @{@"error": @"No main menu found"};
                return;
            }

            // Navigate through the menu hierarchy
            NSMenu *currentMenu = mainMenu;
            NSMenuItem *targetItem = nil;

            for (NSUInteger i = 0; i < menuPath.count; i++) {
                NSString *title = menuPath[i];
                NSMenuItem *item = nil;

                // Search for matching menu item (case-insensitive, trimmed)
                for (NSInteger j = 0; j < [currentMenu numberOfItems]; j++) {
                    NSMenuItem *candidate = [currentMenu itemAtIndex:j];
                    NSString *candidateTitle = [candidate title];
                    // Match exact or without trailing ellipsis/dots
                    if ([candidateTitle caseInsensitiveCompare:title] == NSOrderedSame ||
                        [[candidateTitle stringByReplacingOccurrencesOfString:@"…" withString:@""]
                            caseInsensitiveCompare:
                            [title stringByReplacingOccurrencesOfString:@"..." withString:@""]] == NSOrderedSame ||
                        [[candidateTitle stringByReplacingOccurrencesOfString:@"…" withString:@""]
                            caseInsensitiveCompare:title] == NSOrderedSame) {
                        item = candidate;
                        break;
                    }
                }

                if (!item) {
                    // Build list of available items for error message
                    NSMutableArray *available = [NSMutableArray array];
                    for (NSInteger j = 0; j < [currentMenu numberOfItems]; j++) {
                        NSMenuItem *candidate = [currentMenu itemAtIndex:j];
                        if (![candidate isSeparatorItem]) {
                            [available addObject:[candidate title]];
                        }
                    }
                    result = @{@"error": [NSString stringWithFormat:@"Menu item '%@' not found. Available: %@",
                                title, [available componentsJoinedByString:@", "]]};
                    return;
                }

                if (i == menuPath.count - 1) {
                    // Last item - this is the target
                    targetItem = item;
                } else {
                    // Navigate into submenu
                    NSMenu *submenu = [item submenu];
                    if (!submenu) {
                        result = @{@"error": [NSString stringWithFormat:@"'%@' has no submenu", title]};
                        return;
                    }
                    currentMenu = submenu;
                }
            }

            if (!targetItem) {
                result = @{@"error": @"Target menu item not found"};
                return;
            }

            SEL action = [targetItem action];
            id target = [targetItem target];
            NSString *itemTitle = [targetItem title];
            BOOL enabled = [targetItem isEnabled];

            // dry_run=true: describe what would fire without firing it. Use
            // validateMenuItem: to probe the intended target; modal detection
            // is a heuristic based on trailing ellipsis in the menu title.
            if (dryRun) {
                BOOL validates = enabled;
                id validateTarget = target;
                if (action) {
                    if (target && [target respondsToSelector:@selector(validateMenuItem:)]) {
                        @try {
                            validates = ((BOOL (*)(id, SEL, id))objc_msgSend)(
                                target, @selector(validateMenuItem:), targetItem);
                        } @catch (NSException *e) { validates = enabled; }
                    } else if (!target) {
                        // Responder-chain action — walk the chain to see who'd handle it.
                        id responder = [[app keyWindow] firstResponder];
                        while (responder) {
                            if ([responder respondsToSelector:action]) {
                                validateTarget = responder;
                                break;
                            }
                            responder = [responder nextResponder];
                        }
                    }
                }
                BOOL likelyModal = [itemTitle hasSuffix:@"…"] || [itemTitle hasSuffix:@"..."];
                result = @{
                    @"dry_run": @YES,
                    @"menuItem": itemTitle ?: @"",
                    @"enabled": @(enabled),
                    @"validates": @(validates),
                    @"action": action ? NSStringFromSelector(action) : [NSNull null],
                    @"target_class": validateTarget
                                     ? NSStringFromClass([validateTarget class])
                                     : @"responder chain",
                    @"likely_modal": @(likelyModal),
                    @"would_fire": @(enabled && action != NULL),
                    @"note": @"No action was performed. Remove dry_run=true to execute.",
                };
                return;
            }

            if (!enabled) {
                result = @{@"error": [NSString stringWithFormat:@"Menu item '%@' is disabled",
                            itemTitle]};
                return;
            }

            // Execute the menu item's action
            if (action) {
                if (target) {
                    ((void (*)(id, SEL, id))objc_msgSend)(target, action, targetItem);
                } else {
                    // Send through responder chain
                    ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                        app, @selector(sendAction:to:from:), action, nil, targetItem);
                }
                result = @{@"status": @"ok", @"menuItem": itemTitle ?: @"",
                          @"action": NSStringFromSelector(action)};
            } else {
                result = @{@"error": @"Menu item has no action"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Menu execute failed"};
}

NSDictionary *SpliceKit_handleMenuList(NSDictionary *params) {
    NSString *menuName = params[@"menu"]; // optional: specific top-level menu
    NSNumber *depth = params[@"depth"] ?: @(2);
    // validate: run each listed menu's validation first (-[NSMenu update], what AppKit
    // does when the menu opens), so titles set on validation (Edit > Undo <name>) and
    // the enabled states are current. Off by default: it validates every listed item.
    BOOL validate = [params[@"validate"] respondsToSelector:@selector(boolValue)] && [params[@"validate"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            NSMenu *mainMenu = ((id (*)(id, SEL))objc_msgSend)(app, @selector(mainMenu));
            if (!mainMenu) {
                result = @{@"error": @"No main menu found"};
                return;
            }

            // Recursive helper to build menu tree
            __block id __weak (^weakBuildMenu)(NSMenu *, int);
            __block id (^buildMenu)(NSMenu *, int);
            weakBuildMenu = buildMenu = ^id(NSMenu *menu, int maxDepth) {
                NSMutableArray *items = [NSMutableArray array];
                if (validate) {
                    @try { [menu update]; } @catch (NSException *e) {}
                }
                for (NSInteger i = 0; i < [menu numberOfItems]; i++) {
                    NSMenuItem *item = [menu itemAtIndex:i];
                    if ([item isSeparatorItem]) continue;

                    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                    entry[@"title"] = [item title];
                    entry[@"enabled"] = @([item isEnabled]);
                    entry[@"checked"] = @([item state] == NSControlStateValueOn);

                    NSString *shortcut = [item keyEquivalent];
                    if (shortcut.length > 0) {
                        NSMutableString *combo = [NSMutableString string];
                        NSEventModifierFlags mods = [item keyEquivalentModifierMask];
                        if (mods & NSEventModifierFlagCommand) [combo appendString:@"⌘"];
                        if (mods & NSEventModifierFlagShift) [combo appendString:@"⇧"];
                        if (mods & NSEventModifierFlagOption) [combo appendString:@"⌥"];
                        if (mods & NSEventModifierFlagControl) [combo appendString:@"⌃"];
                        [combo appendString:shortcut];
                        entry[@"shortcut"] = combo;
                    }

                    if ([item hasSubmenu] && maxDepth > 0) {
                        entry[@"submenu"] = weakBuildMenu([item submenu], maxDepth - 1);
                    } else if ([item hasSubmenu]) {
                        entry[@"hasSubmenu"] = @YES;
                    }

                    [items addObject:entry];
                }
                return items;
            };

            if (menuName) {
                // Find specific top-level menu
                for (NSInteger i = 0; i < [mainMenu numberOfItems]; i++) {
                    NSMenuItem *item = [mainMenu itemAtIndex:i];
                    if ([[item title] caseInsensitiveCompare:menuName] == NSOrderedSame && [item hasSubmenu]) {
                        result = @{@"menu": menuName, @"items": buildMenu([item submenu], depth.intValue),
                                   @"validated": @(validate)};
                        return;
                    }
                }
                result = @{@"error": [NSString stringWithFormat:@"Menu '%@' not found", menuName]};
            } else {
                // List all top-level menus
                result = @{@"menus": buildMenu(mainMenu, depth.intValue), @"validated": @(validate)};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    if (!result) return @{@"error": @"Menu list failed"};
    if (result[@"error"]) return result;
    // Edit > Undo / Redo action names resolve in the menu titles regardless of focus; enabled
    // states are AppKit menu validation through the key window (false whenever FCP is not
    // frontmost). The library document's undo manager holds the real step — what Edit > Undo
    // and history_action act on — and is reported as undoState alongside.
    if (!menuName || [menuName caseInsensitiveCompare:@"Edit"] == NSOrderedSame) {
        __block NSDictionary *undoState = nil;
        SpliceKit_executeOnMainThread(^{
            @try {
                id um = SpliceKit_getUndoManager();
                if (!um) return;
                BOOL canUndo = ((BOOL (*)(id, SEL))objc_msgSend)(um, @selector(canUndo));
                BOOL canRedo = ((BOOL (*)(id, SEL))objc_msgSend)(um, @selector(canRedo));
                id undoName = canUndo ? ((id (*)(id, SEL))objc_msgSend)(um, @selector(undoActionName)) : nil;
                id redoName = canRedo ? ((id (*)(id, SEL))objc_msgSend)(um, @selector(redoActionName)) : nil;
                undoState = @{
                    @"canUndo": @(canUndo),
                    @"canRedo": @(canRedo),
                    @"undoActionName": [undoName isKindOfClass:[NSString class]] ? undoName : @"",
                    @"redoActionName": [redoName isKindOfClass:[NSString class]] ? redoName : @"",
                    @"source": @"the library document's undo manager (what Edit > Undo and history_action act on)",
                };
            } @catch (NSException *e) { undoState = nil; }
        });
        NSMutableDictionary *r = [result mutableCopy];
        if (undoState) r[@"undoState"] = undoState;
        r[@"note"] = @"Undo / Redo action names resolve in the menu titles regardless of focus; enabled states are "
                     @"AppKit menu validation through the key window, so they are false whenever Final Cut Pro is "
                     @"not frontmost. undoState is read from the document's undo manager and is always accurate.";
        result = r;
    }
    return result;
}

#pragma mark - View/Panel Toggle Handler

NSDictionary *SpliceKit_handleViewToggle(NSDictionary *params) {
    NSString *panel = params[@"panel"];
    if (!panel) return @{@"error": @"panel parameter required"};

    // Panel name -> what FCP 12.3's View / Window menus send. A selector string goes
    // through the responder chain; a menu path is used where the action reads its menu
    // item (the Effects / Transitions browser toggles read the item's tag, and Angles / 360
    // exist in both the Viewer and Event Viewer submenus with one selector), so the item
    // itself is the sender, exactly as when the menu is chosen.
    NSDictionary *panelMap = @{
        @"inspector":       @"toggleInspector:",
        @"timeline":        @"toggleTimeline:",
        @"browser":         @"toggleOrganizer:",                       // Window > Show in Workspace > Browser
        @"eventViewer":     @"toggleEventViewer:",
        @"effectsBrowser":  @[@"Window", @"Show in Workspace", @"Effects"],
        @"transitionsBrowser": @[@"Window", @"Show in Workspace", @"Transitions"],
        @"videoScopes":     @"toggleVideoScopes:",
        @"histogram":       @"showHistogram:",                         // PEAppController; the scopes' own view menu
        @"vectorscope":     @"showVectorscope:",
        @"waveform":        @"showWaveform:",
        @"audioMeter":      @"toggleAudioMeter:",                      // Window > Show in Workspace > Audio Meters
        @"keywordEditor":   @"toggleKeywordEditor:",
        @"timelineIndex":   @"toggleTimelineIndex:",
        @"precisionEditor": @"togglePrecisionEditor:",                 // View > Show Precision Editor
        @"retimeEditor":    @"toggleRetimeEditor:",
        @"videoAnimation":  @"showTimelineCurveEditor:",
        @"audioAnimation":  @"showTimelineCurveEditor:",
        @"multicamViewer":  @[@"View", @"Show in Viewer", @"Angles"],
        @"360viewer":       @[@"View", @"Show in Viewer", @"360"],
        @"fullscreenViewer": @"sendFullScreen:",                       // View > Playback > Play Full Screen
        @"backgroundTasks": @"goToBackgroundTaskList:",
        @"voiceover":       @"toggleVoiceoverRecordView:",
        @"comparisonViewer": @"toggleCompareViewer:",                  // Window > Show in Workspace > Comparison Viewer
    };
    // Names kept for compatibility that FCP 12.3 has no command for.
    NSDictionary *unavailable = @{
        @"audioCurves": @"there is no audio curves panel; use audioAnimation (Clip > Show Audio Animation)",
    };

    if (unavailable[panel]) {
        return @{@"error": [NSString stringWithFormat:@"Panel '%@' is not available in this Final Cut Pro version: %@.",
                            panel, unavailable[panel]]};
    }
    id target = panelMap[panel];
    if (!target) {
        NSArray *names = [[panelMap.allKeys arrayByAddingObjectsFromArray:unavailable.allKeys]
                          sortedArrayUsingSelector:@selector(compare:)];
        return @{@"error": [NSString stringWithFormat:@"Unknown panel '%@'. Available: %@",
                    panel, [names componentsJoinedByString:@", "]]};
    }
    if ([target isKindOfClass:[NSArray class]]) {
        NSMutableDictionary *r = [SpliceKit_handleMenuExecute(@{@"menuPath": target}) mutableCopy];
        if (!r[@"error"]) r[@"panel"] = panel;
        return r;
    }
    return SpliceKit_sendAppAction(target);
}

#pragma mark - Workspace Handler

NSDictionary *SpliceKit_handleWorkspace(NSDictionary *params) {
    NSString *workspace = params[@"workspace"];
    if (!workspace) return @{@"error": @"workspace parameter required"};

    NSDictionary *workspaceMap = @{
        @"default":       @"Default",
        @"organize":      @"Organize",
        @"colorEffects":  @"Color & Effects",
        @"dualDisplays":  @"Dual Displays",
    };

    NSString *menuTitle = workspaceMap[workspace];
    if (!menuTitle) {
        return @{@"error": [NSString stringWithFormat:@"Unknown workspace '%@'. Available: default, organize, colorEffects, dualDisplays", workspace]};
    }

    return SpliceKit_handleMenuExecute(@{@"menuPath": @[@"Window", @"Workspaces", menuTitle]});
}

#pragma mark - Roles Handler

static NSString *SpliceKit_formatRolesAssignMenuError(NSString *menuError,
                                                      NSString *menuCategory,
                                                      NSString *roleName) {
    if (!menuError.length) return @"Failed to assign role via menu";

    NSRange availRange = [menuError rangeOfString:@"Available: "];
    if (availRange.location != NSNotFound) {
        NSString *suffix = [menuError substringFromIndex:availRange.location + availRange.length];
        NSString *trimmed = [suffix stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) {
            return [NSString stringWithFormat:
                @"Cannot assign role '%@' via Modify > %@: the submenu enumerated no items. "
                @"Final Cut Pro only populates Assign Roles menus when it is the frontmost "
                @"application. Bring Final Cut Pro to the front, keep a clip selected, and retry.",
                roleName, menuCategory];
        }
    }
    return menuError;
}

NSDictionary *SpliceKit_handleRolesAssign(NSDictionary *params) {
    NSString *roleType = params[@"type"]; // "audio", "video", "caption"
    NSString *roleName = params[@"role"]; // e.g. "Dialogue", "Music", "Effects"
    if (!roleType || !roleName) {
        return @{@"error": @"type and role parameters required"};
    }

    NSString *menuCategory;
    if ([roleType isEqualToString:@"audio"]) menuCategory = @"Assign Audio Roles";
    else if ([roleType isEqualToString:@"video"]) menuCategory = @"Assign Video Roles";
    else if ([roleType isEqualToString:@"caption"]) menuCategory = @"Assign Caption Roles";
    else return @{@"error": @"type must be 'audio', 'video', or 'caption'"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module"};
                return;
            }

            SEL selectedSel = NSSelectorFromString(@"selectedItems");
            id selectedItems = nil;
            if ([timeline respondsToSelector:selectedSel]) {
                selectedItems = ((id (*)(id, SEL))objc_msgSend)(timeline, selectedSel);
            }
            if (![selectedItems isKindOfClass:[NSArray class]] || [(NSArray *)selectedItems count] == 0) {
                result = @{@"error": @"No clip selected. Select a clip first."};
                return;
            }

            NSDictionary *menuResult = SpliceKit_handleMenuExecute(
                @{@"menuPath": @[@"Modify", menuCategory, roleName]});
            if (menuResult[@"error"]) {
                result = @{
                    @"error": SpliceKit_formatRolesAssignMenuError(
                        menuResult[@"error"], menuCategory, roleName),
                };
                return;
            }
            result = @{
                @"status": @"ok",
                @"type": roleType,
                @"role": roleName,
                @"method": @"menu",
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to assign role"};
}

#pragma mark - Tool Selection Handler

NSDictionary *SpliceKit_handleToolSelect(NSDictionary *params) {
    NSString *tool = params[@"tool"];
    if (!tool) return @{@"error": @"tool parameter required"};

    NSDictionary *toolMap = @{
        @"select":    @"selectToolArrow:",
        @"trim":      @"selectToolTrim:",
        @"blade":     @"selectToolBlade:",
        @"position":  @"selectToolPlacement:",
        @"hand":      @"selectToolHand:",
        @"zoom":      @"selectToolZoom:",
        @"range":     @"selectToolRangeSelection:",
    };

    NSString *selector = toolMap[tool];
    if (!selector) {
        return @{@"error": [NSString stringWithFormat:@"Unknown tool '%@'. Available: %@",
                    tool, [[toolMap allKeys] componentsJoinedByString:@", "]]};
    }

    return SpliceKit_sendAppAction(selector);
}
