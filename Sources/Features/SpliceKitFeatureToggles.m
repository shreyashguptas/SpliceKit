//
//  SpliceKitFeatureToggles.m
//  SpliceKit - Small option-controlled behaviours: video-only edits keep audio
//  disabled, no auto import on device connect, default spatial conform type, the
//  spring-loaded blade tool, and the options.get / options.set handlers.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Video-Only Keeps Audio Disabled

// When FCP's AV edit mode is "Video Only", the normal behavior strips audio entirely.
// This feature intercepts the four video-only edit methods on FFEditActionMgr and
// instead performs a normal (both A+V) edit, then disables the audio component sources
// on the newly-added clips. The result: clips land with audio present but disabled
// in the inspector, so users can re-enable it later.

static NSString * const kSpliceKitVideoOnlyKeepsAudioDisabled = @"SpliceKitVideoOnlyKeepsAudioDisabled";
static IMP sOrigInsertVideo = NULL;
static IMP sOrigAppendVideo = NULL;
static IMP sOrigOverwriteVideo = NULL;
static IMP sOrigAnchorVideo = NULL;
static BOOL sVideoOnlyKeepsAudioInstalled = NO;

BOOL SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kSpliceKitVideoOnlyKeepsAudioDisabled];
}

void SpliceKit_setVideoOnlyKeepsAudioDisabledEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kSpliceKitVideoOnlyKeepsAudioDisabled];
    if (enabled) {
        SpliceKit_installVideoOnlyKeepsAudioDisabled();
    }
    SpliceKit_log(@"[VideoOnlyKeepsAudio] %@", enabled ? @"Enabled" : @"Disabled");
}

// Get selected items from the timeline module (snapshot for before/after comparison)
static NSArray *SpliceKit_videoOnlyGetSelectedItems(id timelineModule) {
    if (!timelineModule) return @[];
    SEL sel = NSSelectorFromString(@"selectedItems");
    if (![timelineModule respondsToSelector:sel]) return @[];
    id items = ((id (*)(id, SEL))objc_msgSend)(timelineModule, sel);
    return [items isKindOfClass:[NSArray class]] ? [items copy] : @[];
}

// Build a set of pointer values for fast identity comparison
static NSSet *SpliceKit_videoOnlyPointerSet(NSArray *items) {
    NSMutableSet *set = [NSMutableSet setWithCapacity:items.count];
    for (id item in items) {
        [set addObject:[NSValue valueWithNonretainedObject:item]];
    }
    return set;
}

// Disable audio component sources on clips that are in selectedAfter but not in selectedBefore
static void SpliceKit_videoOnlyDisableNewClipAudio(id timelineModule, NSArray *selectedBefore) {
    if (!timelineModule) return;

    NSArray *selectedAfter = SpliceKit_videoOnlyGetSelectedItems(timelineModule);
    if (!selectedAfter.count) return;

    NSSet *beforeSet = SpliceKit_videoOnlyPointerSet(selectedBefore);

    // Get the sequence for undo grouping
    id sequence = nil;
    SEL seqSel = NSSelectorFromString(@"sequence");
    if ([timelineModule respondsToSelector:seqSel]) {
        sequence = ((id (*)(id, SEL))objc_msgSend)(timelineModule, seqSel);
    }

    // Begin undoable action
    NSString *actionName = @"Disable Audio";
    if (sequence) {
        SEL beginSel = NSSelectorFromString(@"actionBegin:");
        if ([sequence respondsToSelector:beginSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(sequence, beginSel, actionName);
        }
    }

    NSInteger disabledCount = 0;
    for (id clip in selectedAfter) {
        if ([beforeSet containsObject:[NSValue valueWithNonretainedObject:clip]])
            continue; // Not a new clip

        SEL hasSel = NSSelectorFromString(@"hasAudioComponentSources");
        if (![clip respondsToSelector:hasSel]) continue;
        if (!((BOOL (*)(id, SEL))objc_msgSend)(clip, hasSel)) continue;

        // Get all audio component sources (0 = all, not just active)
        SEL acsSel = NSSelectorFromString(@"audioComponentSources:");
        if (![clip respondsToSelector:acsSel]) continue;
        id sources = ((id (*)(id, SEL, unsigned int))objc_msgSend)(clip, acsSel, (unsigned int)0);
        if (![sources isKindOfClass:[NSArray class]]) continue;

        for (id source in (NSArray *)sources) {
            SEL enabledSel = NSSelectorFromString(@"enabled");
            if (![source respondsToSelector:enabledSel]) continue;
            if (!((BOOL (*)(id, SEL))objc_msgSend)(source, enabledSel)) continue;

            SEL setEnabledSel = NSSelectorFromString(@"setEnabled:");
            if ([source respondsToSelector:setEnabledSel]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(source, setEnabledSel, NO);
                disabledCount++;
            }
        }
    }

    // End undoable action
    if (sequence) {
        SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
        if ([sequence respondsToSelector:endSel]) {
            ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                sequence, endSel, actionName, YES, nil);
        }
    }

    if (disabledCount > 0) {
        SpliceKit_log(@"[VideoOnlyKeepsAudio] Disabled %ld audio component sources on new clips",
                      (long)disabledCount);
    }
}

// --- Swizzled edit methods ---
// Each intercepts the video-only variant, calls the "both" variant instead,
// then disables audio on newly-added clips.

static void SpliceKit_swizzled_insertWithSelectedMediaVideo(id self, SEL _cmd, id sender) {
    if (!SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled()) {
        ((void (*)(id, SEL, id))sOrigInsertVideo)(self, _cmd, sender);
        return;
    }
    id timeline = SpliceKit_getActiveTimelineModule();
    NSArray *before = SpliceKit_videoOnlyGetSelectedItems(timeline);
    ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(@"insertWithSelectedMedia:"), sender);
    SpliceKit_videoOnlyDisableNewClipAudio(timeline, before);
}

static void SpliceKit_swizzled_appendWithSelectedMediaVideo(id self, SEL _cmd, id sender) {
    if (!SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled()) {
        ((void (*)(id, SEL, id))sOrigAppendVideo)(self, _cmd, sender);
        return;
    }
    id timeline = SpliceKit_getActiveTimelineModule();
    NSArray *before = SpliceKit_videoOnlyGetSelectedItems(timeline);
    ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(@"appendWithSelectedMedia:"), sender);
    SpliceKit_videoOnlyDisableNewClipAudio(timeline, before);
}

static void SpliceKit_swizzled_overwriteWithSelectedMediaVideo(id self, SEL _cmd, id sender) {
    if (!SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled()) {
        ((void (*)(id, SEL, id))sOrigOverwriteVideo)(self, _cmd, sender);
        return;
    }
    id timeline = SpliceKit_getActiveTimelineModule();
    NSArray *before = SpliceKit_videoOnlyGetSelectedItems(timeline);
    ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(@"overwriteWithSelectedMedia:"), sender);
    SpliceKit_videoOnlyDisableNewClipAudio(timeline, before);
}

static void SpliceKit_swizzled_anchorWithSelectedMediaVideo(id self, SEL _cmd, id sender) {
    if (!SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled()) {
        ((void (*)(id, SEL, id))sOrigAnchorVideo)(self, _cmd, sender);
        return;
    }
    id timeline = SpliceKit_getActiveTimelineModule();
    NSArray *before = SpliceKit_videoOnlyGetSelectedItems(timeline);
    ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(@"anchorWithSelectedMedia:"), sender);
    SpliceKit_videoOnlyDisableNewClipAudio(timeline, before);
}

void SpliceKit_installVideoOnlyKeepsAudioDisabled(void) {
    if (sVideoOnlyKeepsAudioInstalled) return;
    if (!SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled()) return;

    Class cls = objc_getClass("FFEditActionMgr");
    if (!cls) {
        SpliceKit_log(@"[VideoOnlyKeepsAudio] FFEditActionMgr class not found");
        return;
    }

    struct { SEL sel; IMP *origPtr; IMP newImp; } swizzles[] = {
        { NSSelectorFromString(@"insertWithSelectedMediaVideo:"),
          &sOrigInsertVideo,
          (IMP)SpliceKit_swizzled_insertWithSelectedMediaVideo },
        { NSSelectorFromString(@"appendWithSelectedMediaVideo:"),
          &sOrigAppendVideo,
          (IMP)SpliceKit_swizzled_appendWithSelectedMediaVideo },
        { NSSelectorFromString(@"overwriteWithSelectedMediaVideo:"),
          &sOrigOverwriteVideo,
          (IMP)SpliceKit_swizzled_overwriteWithSelectedMediaVideo },
        { NSSelectorFromString(@"anchorWithSelectedMediaVideo:"),
          &sOrigAnchorVideo,
          (IMP)SpliceKit_swizzled_anchorWithSelectedMediaVideo },
    };

    for (int i = 0; i < 4; i++) {
        Method m = class_getInstanceMethod(cls, swizzles[i].sel);
        if (m && !*swizzles[i].origPtr) {
            *swizzles[i].origPtr = method_setImplementation(m, swizzles[i].newImp);
            SpliceKit_log(@"[VideoOnlyKeepsAudio] Swizzled -[FFEditActionMgr %@]",
                          NSStringFromSelector(swizzles[i].sel));
        }
    }

    sVideoOnlyKeepsAudioInstalled = YES;
    SpliceKit_log(@"[VideoOnlyKeepsAudio] Swizzle installed");
}

#pragma mark - Suppress Auto Import on Device Connect

// When a card, camera, or iOS device mounts while FCP is running, FCP auto-opens
// the Import Media window. This feature suppresses that by swizzling the class
// methods on PEImportOrganizerContainerModule that handle the mount notifications.
//
// We can't swizzle the +startObserving... class methods because they already ran
// at FCP launch (long before our dylib was injected). So instead we swizzle the
// handlers themselves — when enabled, they just log and return without opening
// the import window.

static NSString * const kSpliceKitSuppressAutoImport = @"SpliceKitSuppressAutoImport";
static IMP sOrigVolumeDidMount = NULL;
static IMP sOrigRadVolumeDidMount = NULL;
static BOOL sSuppressAutoImportInstalled = NO;

BOOL SpliceKit_isSuppressAutoImportEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kSpliceKitSuppressAutoImport];
}

void SpliceKit_setSuppressAutoImportEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kSpliceKitSuppressAutoImport];
    if (enabled) {
        SpliceKit_installSuppressAutoImport();
    }
    SpliceKit_log(@"[SuppressAutoImport] %@", enabled ? @"Enabled" : @"Disabled");
}

// Swizzled +[PEImportOrganizerContainerModule volumeDidMount:]
// Handles SD cards, USB drives, and other NSWorkspace volume mount notifications.
static void SpliceKit_swizzled_volumeDidMount(id self, SEL _cmd, id notification) {
    if (SpliceKit_isSuppressAutoImportEnabled()) {
        SpliceKit_log(@"[SuppressAutoImport] Blocked +volumeDidMount: (notification=%@)",
                      [notification name] ?: @"<nil>");
        return;
    }
    ((void (*)(id, SEL, id))sOrigVolumeDidMount)(self, _cmd, notification);
}

// Swizzled +[PEImportOrganizerContainerModule radVolumeDidMount:]
// Handles iOS device / RAD volume mount notifications.
static void SpliceKit_swizzled_radVolumeDidMount(id self, SEL _cmd, id notification) {
    if (SpliceKit_isSuppressAutoImportEnabled()) {
        SpliceKit_log(@"[SuppressAutoImport] Blocked +radVolumeDidMount: (notification=%@)",
                      [notification name] ?: @"<nil>");
        return;
    }
    ((void (*)(id, SEL, id))sOrigRadVolumeDidMount)(self, _cmd, notification);
}

void SpliceKit_installSuppressAutoImport(void) {
    if (sSuppressAutoImportInstalled) return;

    Class cls = objc_getClass("PEImportOrganizerContainerModule");
    if (!cls) {
        SpliceKit_log(@"[SuppressAutoImport] PEImportOrganizerContainerModule class not found");
        return;
    }

    // These are class methods, not instance methods — use object_getClass to get
    // the metaclass so class_getInstanceMethod finds them correctly.
    Class metaCls = object_getClass((id)cls);
    if (!metaCls) {
        SpliceKit_log(@"[SuppressAutoImport] Failed to get metaclass");
        return;
    }

    struct { SEL sel; IMP *origPtr; IMP newImp; } swizzles[] = {
        { NSSelectorFromString(@"volumeDidMount:"),
          &sOrigVolumeDidMount,
          (IMP)SpliceKit_swizzled_volumeDidMount },
        { NSSelectorFromString(@"radVolumeDidMount:"),
          &sOrigRadVolumeDidMount,
          (IMP)SpliceKit_swizzled_radVolumeDidMount },
    };

    BOOL anySwizzled = NO;
    for (int i = 0; i < 2; i++) {
        Method m = class_getInstanceMethod(metaCls, swizzles[i].sel);
        if (m && !*swizzles[i].origPtr) {
            *swizzles[i].origPtr = method_setImplementation(m, swizzles[i].newImp);
            SpliceKit_log(@"[SuppressAutoImport] Swizzled +[PEImportOrganizerContainerModule %@]",
                          NSStringFromSelector(swizzles[i].sel));
            anySwizzled = YES;
        } else if (!m) {
            SpliceKit_log(@"[SuppressAutoImport] Method not found: +%@",
                          NSStringFromSelector(swizzles[i].sel));
        }
    }

    if (!anySwizzled) {
        SpliceKit_log(@"[SuppressAutoImport] No methods were swizzled — will retry on next enable");
        return;
    }

    sSuppressAutoImportInstalled = YES;
    SpliceKit_log(@"[SuppressAutoImport] Swizzle installed");
}

#pragma mark - Default Spatial Conform Type

// FCP defaults to "Fit" (letterbox/pillarbox) when a clip's native resolution
// doesn't match the project. This feature overrides the default to "Fill" or "None"
// for every newly created clip, regardless of how it's added (keyboard edit, drag &
// drop, paste, etc.).
//
// Mechanism: swizzle -[FFHeConformEffect createChannelsInFolder:]. This is called
// when FCP builds a new conform effect — i.e. whenever a new clip is placed on the
// timeline. For clips loaded from an existing project, the archived channel values
// overwrite our modified default after creation, so saved projects are unaffected.
//
// The conform type lives in the _chType ivar (CHChannelEnum) on FFHeConformEffect.
// Its strings array is ["Fit", "Fill", "None"] → int values 0, 1, 2.

static NSString * const kSpliceKitDefaultSpatialConformType = @"SpliceKitDefaultSpatialConformType";
static IMP sOrigCreateChannelsInFolder = NULL;
static BOOL sDefaultConformInstalled = NO;

NSString *SpliceKit_getDefaultSpatialConformType(void) {
    NSString *val = [[NSUserDefaults standardUserDefaults] stringForKey:kSpliceKitDefaultSpatialConformType];
    if (val && ([val isEqualToString:@"fit"] || [val isEqualToString:@"fill"] || [val isEqualToString:@"none"])) {
        return val;
    }
    return @"fit"; // default
}

void SpliceKit_setDefaultSpatialConformType(NSString *value) {
    if (!value) value = @"fit";
    value = [value lowercaseString];
    if (!([value isEqualToString:@"fit"] || [value isEqualToString:@"fill"] || [value isEqualToString:@"none"])) {
        SpliceKit_log(@"[DefaultConform] Invalid value '%@', ignoring (must be fit/fill/none)", value);
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:kSpliceKitDefaultSpatialConformType];
    if (![value isEqualToString:@"fit"]) {
        SpliceKit_installDefaultSpatialConformType();
    }
    SpliceKit_log(@"[DefaultConform] Set to '%@'", value);
}

// Map string type to CHChannelEnum integer value on FFHeConformEffect._chType.
// The channel's strings array is ["Fit", "Fill", "None"], so: 0 = Fit, 1 = Fill, 2 = None.
static int SpliceKit_conformTypeToInt(NSString *type) {
    if ([type isEqualToString:@"fill"]) return 1;
    if ([type isEqualToString:@"none"]) return 2;
    return 0; // "fit" default
}

// Swizzled -[FFHeConformEffect createChannelsInFolder:]
// Called when FCP builds a new conform effect for a clip. We let the original
// create the channels (including _chType with default "Fit"), then immediately
// override _chType's int value to the user's preference.
static void SpliceKit_swizzled_createChannelsInFolder(id self, SEL _cmd, id folder) {
    // Call original to create all channels normally
    ((void (*)(id, SEL, id))sOrigCreateChannelsInFolder)(self, _cmd, folder);

    NSString *conformType = SpliceKit_getDefaultSpatialConformType();
    if ([conformType isEqualToString:@"fit"]) return; // FCP default, nothing to change

    @try {
        id chType = [self valueForKey:@"_chType"];
        if (!chType) return;

        int targetInt = SpliceKit_conformTypeToInt(conformType);
        SEL setIntSel = NSSelectorFromString(@"setIntValue:");
        if ([chType respondsToSelector:setIntSel]) {
            ((void (*)(id, SEL, int))objc_msgSend)(chType, setIntSel, targetInt);
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[DefaultConform] Exception in createChannelsInFolder: swizzle: %@", e.reason);
    }
}

void SpliceKit_installDefaultSpatialConformType(void) {
    if (sDefaultConformInstalled) return;

    Class cls = objc_getClass("FFHeConformEffect");
    if (!cls) {
        SpliceKit_log(@"[DefaultConform] FFHeConformEffect class not found");
        return;
    }

    SEL sel = NSSelectorFromString(@"createChannelsInFolder:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        SpliceKit_log(@"[DefaultConform] -[FFHeConformEffect createChannelsInFolder:] not found");
        return;
    }

    sOrigCreateChannelsInFolder = method_setImplementation(m, (IMP)SpliceKit_swizzled_createChannelsInFolder);
    sDefaultConformInstalled = YES;
    SpliceKit_log(@"[DefaultConform] Swizzled -[FFHeConformEffect createChannelsInFolder:] (current: %@)",
                  SpliceKit_getDefaultSpatialConformType());
}

#pragma mark - Spring-Loaded Blade Tool
//
// Hold Option to temporarily switch to the blade tool. Release to revert to the
// previous tool. Uses NSEvent flagsChanged monitor — no UI automation.
//

static NSString * const kSpliceKitSpringLoadedBlade = @"SpliceKitSpringLoadedBlade";
static id sSpringLoadedBladeMonitor = nil;
static BOOL sSpringLoadedBladeActive = NO;       // Option is held, blade tool is engaged
static NSString *sSpringLoadedBladePreviousTool = nil;  // tool selector to restore on release

// Map from selectTool* selectors back to tool names (for logging)
static NSString *SpliceKit_currentToolSelector(void) {
    // Query the timeline module's edit mode to determine current tool.
    // FFAnchoredTimelineModule tracks editMode as an int:
    //   0=arrow, 1=trim, 2=placement, 3=range, 4=zoom, 5=hand, 6=blade
    // We read it via the validate pattern: check which selectTool* action is "on".
    __block NSString *currentSelector = @"selectToolArrow:";

    SpliceKit_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));

            // Try each tool selector — the one that validates as "on" is current.
            // FCP uses NSMenuItem validation to track tool state.
            NSArray *toolSelectors = @[
                @"selectToolArrow:",
                @"selectToolTrim:",
                @"selectToolBlade:",
                @"selectToolPlacement:",
                @"selectToolHand:",
                @"selectToolZoom:",
                @"selectToolRangeSelection:",
            ];

            for (NSString *selName in toolSelectors) {
                SEL sel = NSSelectorFromString(selName);
                // Create a temporary menu item to validate against
                NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:sel keyEquivalent:@""];
                // Find the target responder
                id target = ((id (*)(id, SEL, SEL, id, id))objc_msgSend)(
                    app, @selector(targetForAction:to:from:), sel, nil, nil);
                if (target && [target respondsToSelector:@selector(validateMenuItem:)]) {
                    BOOL valid = ((BOOL (*)(id, SEL, id))objc_msgSend)(
                        target, @selector(validateMenuItem:), item);
                    if (valid && item.state == NSControlStateValueOn) {
                        currentSelector = selName;
                        break;
                    }
                }
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[SpringBlade] Failed to detect current tool: %@", e.reason);
        }
    });

    return currentSelector;
}

void SpliceKit_installSpringLoadedBlade(void) {
    if (sSpringLoadedBladeMonitor) return;  // Already installed

    sSpringLoadedBladeMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged
        handler:^NSEvent *(NSEvent *event) {
            BOOL optionDown = (event.modifierFlags & NSEventModifierFlagOption) != 0;

            if (optionDown && !sSpringLoadedBladeActive) {
                // Option just pressed — save current tool and switch to blade
                NSString *current = SpliceKit_currentToolSelector();
                if (![current isEqualToString:@"selectToolBlade:"]) {
                    sSpringLoadedBladePreviousTool = current;
                    sSpringLoadedBladeActive = YES;
                    SpliceKit_sendAppAction(@"selectToolBlade:");
                    SpliceKit_log(@"[SpringBlade] Option held — switched to blade (was %@)", current);
                }
            } else if (!optionDown && sSpringLoadedBladeActive) {
                // Option released — restore previous tool
                sSpringLoadedBladeActive = NO;
                if (sSpringLoadedBladePreviousTool) {
                    SpliceKit_sendAppAction(sSpringLoadedBladePreviousTool);
                    SpliceKit_log(@"[SpringBlade] Option released — restored %@", sSpringLoadedBladePreviousTool);
                    sSpringLoadedBladePreviousTool = nil;
                }
            }

            return event;  // Always pass through — don't consume modifier events
        }];

    SpliceKit_log(@"[SpringBlade] Installed: hold Option for blade, release to revert");
}

void SpliceKit_uninstallSpringLoadedBlade(void) {
    if (sSpringLoadedBladeMonitor) {
        [NSEvent removeMonitor:sSpringLoadedBladeMonitor];
        sSpringLoadedBladeMonitor = nil;
    }
    // If blade is currently active, restore previous tool
    if (sSpringLoadedBladeActive && sSpringLoadedBladePreviousTool) {
        SpliceKit_sendAppAction(sSpringLoadedBladePreviousTool);
    }
    sSpringLoadedBladeActive = NO;
    sSpringLoadedBladePreviousTool = nil;
    SpliceKit_log(@"[SpringBlade] Uninstalled");
}

BOOL SpliceKit_isSpringLoadedBladeEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id storedValue = [defaults objectForKey:kSpliceKitSpringLoadedBlade];
    if (!storedValue) return YES;  // Default enabled
    return [defaults boolForKey:kSpliceKitSpringLoadedBlade];
}

void SpliceKit_setSpringLoadedBladeEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kSpliceKitSpringLoadedBlade];
    if (enabled) {
        SpliceKit_installSpringLoadedBlade();
    } else {
        SpliceKit_uninstallSpringLoadedBlade();
    }
}

#pragma mark - Bridge Options (options.get / options.set)

NSDictionary *SpliceKit_handleOptionsGet(NSDictionary *params) {
    return @{
        @"effectDragAsAdjustmentClip": @(SpliceKit_isEffectDragAsAdjustmentClipEnabled()),
        @"viewerPinchZoom": @(SpliceKit_isViewerPinchZoomEnabled()),
        @"videoOnlyKeepsAudioDisabled": @(SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled()),
        @"suppressAutoImport": @(SpliceKit_isSuppressAutoImportEnabled()),
        @"springLoadedBlade": @(SpliceKit_isSpringLoadedBladeEnabled()),
        @"lLadder": SpliceKit_getLLadder(),
        @"jLadder": SpliceKit_getJLadder(),
        @"defaultSpatialConformType": SpliceKit_getDefaultSpatialConformType(),
        @"sidebarCoalesceLiveScroll": @(SpliceKit_isSidebarCoalesceLiveScrollEnabled()),
        @"timelineOverviewBar": @(SpliceKit_isTimelineOverviewBarEnabled()),
        @"timelinePerformanceMode": @(SpliceKit_isTimelinePerformanceModeEnabled()),
        @"timelineInteractionSuspend": @(SpliceKit_isTimelineInteractionSuspendEnabled()),
        @"timelinePlayheadOverlay": @(SpliceKit_isTimelinePlayheadOverlayEnabled()),
        @"tlkOptimizedReload": @(SpliceKit_isTLKOptimizedReloadEnabled()),
    };
}

NSDictionary *SpliceKit_handleOptionsSet(NSDictionary *params) {
    NSString *option = params[@"option"];
    if (!option) return @{@"error": @"'option' parameter required"};

    if ([option isEqualToString:@"viewerPinchZoom"]) {
        NSNumber *enabled = params[@"enabled"];
        if (!enabled) return @{@"error": @"'enabled' parameter required (true/false)"};
        SpliceKit_setViewerPinchZoomEnabled([enabled boolValue]);
        return @{@"status": @"ok", @"viewerPinchZoom": @(SpliceKit_isViewerPinchZoomEnabled())};
    } else if ([option isEqualToString:@"effectDragAsAdjustmentClip"]) {
        NSNumber *enabled = params[@"enabled"];
        if (!enabled) return @{@"error": @"'enabled' parameter required (true/false)"};
        SpliceKit_setEffectDragAsAdjustmentClipEnabled([enabled boolValue]);
        return @{@"status": @"ok",
                 @"effectDragAsAdjustmentClip": @(SpliceKit_isEffectDragAsAdjustmentClipEnabled())};
    } else if ([option isEqualToString:@"videoOnlyKeepsAudioDisabled"]) {
        NSNumber *enabled = params[@"enabled"];
        if (!enabled) return @{@"error": @"'enabled' parameter required (true/false)"};
        SpliceKit_setVideoOnlyKeepsAudioDisabledEnabled([enabled boolValue]);
        return @{@"status": @"ok",
                 @"videoOnlyKeepsAudioDisabled": @(SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled())};
    } else if ([option isEqualToString:@"suppressAutoImport"]) {
        NSNumber *enabled = params[@"enabled"];
        if (!enabled) return @{@"error": @"'enabled' parameter required (true/false)"};
        SpliceKit_setSuppressAutoImportEnabled([enabled boolValue]);
        return @{@"status": @"ok",
                 @"suppressAutoImport": @(SpliceKit_isSuppressAutoImportEnabled())};
    } else if ([option isEqualToString:@"springLoadedBlade"]) {
        NSNumber *enabled = params[@"enabled"];
        if (!enabled) return @{@"error": @"'enabled' parameter required (true/false)"};
        SpliceKit_setSpringLoadedBladeEnabled([enabled boolValue]);
        return @{@"status": @"ok",
                 @"springLoadedBlade": @(SpliceKit_isSpringLoadedBladeEnabled())};
    } else if ([option isEqualToString:@"lLadder"]) {
        NSArray *value = params[@"value"];
        if (!value) return @{@"error": @"'value' parameter required (array of numbers)"};
        SpliceKit_setLLadder(value);
        return @{@"status": @"ok", @"lLadder": SpliceKit_getLLadder()};
    } else if ([option isEqualToString:@"jLadder"]) {
        NSArray *value = params[@"value"];
        if (!value) return @{@"error": @"'value' parameter required (array of numbers)"};
        SpliceKit_setJLadder(value);
        return @{@"status": @"ok", @"jLadder": SpliceKit_getJLadder()};
    } else if ([option isEqualToString:@"defaultSpatialConformType"]) {
        NSString *value = params[@"value"];
        if (!value) {
            // Backward compat: accept enabled bool (true -> "fill", false -> "fit")
            NSNumber *enabled = params[@"enabled"];
            if (enabled) {
                value = [enabled boolValue] ? @"fill" : @"fit";
            } else {
                return @{@"error": @"'value' parameter required (\"fit\", \"fill\", or \"none\")"};
            }
        }
        value = [value lowercaseString];
        if (!([value isEqualToString:@"fit"] || [value isEqualToString:@"fill"] || [value isEqualToString:@"none"])) {
            return @{@"error": [NSString stringWithFormat:
                @"Invalid value '%@'. Must be \"fit\", \"fill\", or \"none\".", value]};
        }
        SpliceKit_setDefaultSpatialConformType(value);
        return @{@"status": @"ok",
                 @"defaultSpatialConformType": SpliceKit_getDefaultSpatialConformType()};
    } else if ([option isEqualToString:@"sidebarCoalesceLiveScroll"]) {
        NSNumber *enabled = params[@"enabled"];
        if (!enabled) return @{@"error": @"'enabled' parameter required (true/false)"};
        SpliceKit_setSidebarCoalesceLiveScrollEnabled([enabled boolValue]);
        return @{@"status": @"ok",
                 @"sidebarCoalesceLiveScroll": @(SpliceKit_isSidebarCoalesceLiveScrollEnabled())};
    } else if ([option isEqualToString:@"timelineOverviewBar"]) {
        NSNumber *enabled = params[@"enabled"];
        if (!enabled) return @{@"error": @"'enabled' parameter required (true/false)"};
        SpliceKit_setTimelineOverviewBarEnabled([enabled boolValue]);
        return @{@"status": @"ok",
                 @"timelineOverviewBar": @(SpliceKit_isTimelineOverviewBarEnabled())};
    } else if ([option isEqualToString:@"timelinePerformanceMode"]) {
        NSNumber *enabled = params[@"enabled"];
        if (!enabled) return @{@"error": @"'enabled' parameter required (true/false)"};
        SpliceKit_setTimelinePerformanceModeEnabled([enabled boolValue]);
        return @{@"status": @"ok",
                 @"timelinePerformanceMode": @(SpliceKit_isTimelinePerformanceModeEnabled()),
                 @"timelineInteractionSuspend": @(SpliceKit_isTimelineInteractionSuspendEnabled()),
                 @"timelinePlayheadOverlay": @(SpliceKit_isTimelinePlayheadOverlayEnabled()),
                 @"tlkOptimizedReload": @(SpliceKit_isTLKOptimizedReloadEnabled())};
    } else if ([option isEqualToString:@"timelineInteractionSuspend"]) {
        NSNumber *enabled = params[@"enabled"];
        if (!enabled) return @{@"error": @"'enabled' parameter required (true/false)"};
        SpliceKit_setTimelineInteractionSuspendEnabled([enabled boolValue]);
        return @{@"status": @"ok",
                 @"timelineInteractionSuspend": @(SpliceKit_isTimelineInteractionSuspendEnabled())};
    } else if ([option isEqualToString:@"timelinePlayheadOverlay"]) {
        NSNumber *enabled = params[@"enabled"];
        if (!enabled) return @{@"error": @"'enabled' parameter required (true/false)"};
        SpliceKit_setTimelinePlayheadOverlayEnabled([enabled boolValue]);
        return @{@"status": @"ok",
                 @"timelinePlayheadOverlay": @(SpliceKit_isTimelinePlayheadOverlayEnabled())};
    } else if ([option isEqualToString:@"tlkOptimizedReload"]) {
        NSNumber *enabled = params[@"enabled"];
        if (!enabled) return @{@"error": @"'enabled' parameter required (true/false)"};
        SpliceKit_setTLKOptimizedReloadEnabled([enabled boolValue]);
        return @{@"status": @"ok",
                 @"tlkOptimizedReload": @(SpliceKit_isTLKOptimizedReloadEnabled())};
    }

    return @{@"error": [NSString stringWithFormat:@"Unknown option: %@", option]};
}
