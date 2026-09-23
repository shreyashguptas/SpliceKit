//
//  SpliceKitCommandPalette+AIPostProcess.m
//  Turning a model's answer into actions: post-processing of AI output, and the
//  keyword fallback used when no model is available.
//

#import "SpliceKitCommandPalette+Private.h"

@implementation SpliceKitCommandPalette (AIPostProcess)

#pragma mark - Post-Process AI Output

- (NSArray<NSDictionary *> *)postProcessActions:(NSArray *)actions query:(NSString *)query {
    // Known effect names — if the LLM puts these as timeline actions, fix them
    static NSSet *effectNames = nil;
    static NSSet *transitionNames = nil;
    static NSSet *validTimelineActions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        effectNames = [NSSet setWithArray:@[
            @"Gaussian Blur", @"Zoom Blur", @"Radial Blur", @"Prism Blur", @"Channel Blur", @"Soft Focus",
            @"Sharpen", @"Unsharp Mask", @"Keyer", @"Luma Keyer", @"Chroma Keyer",
            @"Black & White", @"Sepia", @"Tint", @"Negative", @"Color Monochrome",
            @"Vignette", @"Bloom", @"Glow", @"Gloom", @"Aged Film", @"Bad TV", @"Vintage", @"Film Grain",
            @"Underwater", @"Earthquake", @"Fisheye", @"Mirror", @"Kaleidoscope", @"Pixellate",
            @"Light Rays", @"Lens Flare", @"Light Wrap",
            @"Noise Reduction", @"Stabilization", @"Rolling Shutter", @"Broadcast Safe",
            @"Draw Mask", @"Shape Mask", @"Vignette Mask", @"Image Mask",
            @"Drop Shadow", @"Letterbox", @"Flipped", @"Invert", @"Posterize", @"Tilt-Shift",
            @"Custom LUT", @"Bump Map", @"Color Correction", @"Night Vision", @"X-Ray", @"Prism",
        ]];
        transitionNames = [NSSet setWithArray:@[
            @"Cross Dissolve", @"Flow", @"Fade To Color", @"Wipe", @"Push",
            @"Slide", @"Spin", @"Doorway", @"Page Curl", @"Star", @"Band", @"Zoom",
            @"Bloom", @"Mosaic",
        ]];
        validTimelineActions = [NSSet setWithArray:@[
            // Editing basics
            @"blade", @"bladeAll", @"delete", @"cut", @"copy", @"paste", @"undo", @"redo",
            @"selectAll", @"deselectAll", @"selectClipAtPlayhead", @"selectToPlayhead",
            @"pasteAsConnected", @"copyTimecode", @"insertGap", @"insertPlaceholder",
            // Trim
            @"trimToPlayhead", @"extendEditToPlayhead", @"trimStart", @"trimEnd",
            @"joinClips", @"replaceWithGap",
            @"nudgeLeft", @"nudgeRight", @"nudgeLeftBig", @"nudgeRightBig",
            @"nudgeUp", @"nudgeDown",
            @"rollEditLeft", @"rollEditRight", @"slipLeft", @"slipRight",
            @"rippleTrimStartToPlayhead", @"rippleTrimEndToPlayhead",
            // Range / In-Out
            @"setRangeStart", @"setRangeEnd", @"clearRange", @"setClipRange",
            // Navigation
            @"nextEdit", @"previousEdit",
            @"timelineHistoryBack", @"timelineHistoryForward",
            // Markers
            @"addMarker", @"addTodoMarker", @"addChapterMarker", @"deleteMarker",
            @"deleteMarkersInSelection", @"nextMarker", @"previousMarker",
            // Transitions
            @"addTransition",
            // Color
            @"addColorBoard", @"addColorWheels", @"addColorCurves", @"addColorAdjustment",
            @"addHueSaturation", @"addEnhanceLightAndColor", @"balanceColor", @"matchColor",
            @"showColorInspector", @"nextColorEffect", @"previousColorEffect",
            @"resetColorBoard", @"toggleAllColorOff",
            @"addMagneticMask", @"smartConform",
            // Audio
            @"adjustVolumeUp", @"adjustVolumeDown", @"detachAudio",
            @"addChannelEQ", @"enhanceAudio", @"matchAudio",
            @"addAudioFadeIn", @"addAudioFadeOut", @"applyAudioFades",
            @"volumeMute", @"addDefaultAudioEffect",
            @"expandAudio", @"expandAudioComponents",
            // Titles
            @"addBasicTitle", @"addBasicLowerThird",
            // Speed / Retime
            @"retimeNormal", @"retimeFast2x", @"retimeFast4x", @"retimeFast8x", @"retimeFast20x",
            @"retimeSlow50", @"retimeSlow25", @"retimeSlow10", @"retimeReverse", @"retimeHold",
            @"freezeFrame", @"retimeBladeSpeed", @"retimeSpeedRampToZero", @"retimeSpeedRampFromZero",
            @"retimeCustomSpeed", @"retimeInstantReplayHalf", @"retimeInstantReplayQuarter",
            @"retimeReset", @"retimeOpticalFlow", @"retimeFrameBlending", @"retimeFloorFrame",
            // Keyframes
            @"addKeyframe", @"deleteKeyframes", @"removeAllKeyframesFromClip",
            @"nextKeyframe", @"previousKeyframe",
            // Clip operations
            @"solo", @"disable", @"enableDisable", @"createCompoundClip",
            @"breakApartClipItems", @"addAdjustmentClip",
            @"liftFromPrimaryStoryline", @"overwriteToPrimaryStoryline",
            @"connectClipToPrimaryStoryline", @"createStoryline",
            @"collapseToConnectedStoryline", @"collapseToClip",
            @"synchronizeClips", @"makeClipsUnique", @"renameClip",
            @"addToSoloedClips", @"openInTimeline", @"backToParent",
            // Auditions
            @"createAudition", @"finalizeAudition", @"nextAuditionPick", @"previousAuditionPick",
            // Multicam
            @"createMulticamClip",
            @"switchAngle01", @"switchAngle02", @"switchAngle03", @"switchAngle04",
            @"cutAndSwitchAngle01", @"cutAndSwitchAngle02", @"cutAndSwitchAngle03", @"cutAndSwitchAngle04",
            // Captions
            @"addCaption", @"splitCaption", @"resolveOverlaps", @"duplicateCaption", @"importCaptions",
            // Effects
            @"removeEffects", @"pasteEffects", @"pasteAttributes", @"removeAttributes", @"copyAttributes",
            @"resetAllParameters", @"toggleSelectedEffectsOff", @"addDefaultVideoEffect",
            @"autoReframe", @"addVideoGenerator",
            // Transform
            @"showTransformControls", @"showCropControls", @"showDistortControls",
            // Rating
            @"favorite", @"reject", @"unrate",
            @"rateAsFavorite", @"rateAsReject", @"removeRating", @"removeAllRatings",
            @"hideClip",
            // View / UI
            @"zoomToFit", @"zoomIn", @"zoomOut", @"verticalZoomToFit", @"zoomToSamples",
            @"toggleSnapping", @"toggleSkimming", @"toggleClipSkimming", @"toggleAudioSkimming",
            @"toggleInspector", @"toggleTimeline", @"toggleTimelineIndex", @"toggleInspectorHeight",
            @"toggleEventViewer",
            @"showVideoAnimation", @"showAudioAnimation", @"soloAnimation",
            @"showTrackingEditor", @"showCinematicEditor", @"showMagneticMaskEditor",
            @"enableBeatDetection", @"togglePrecisionEditor",
            @"showAudioLanes", @"expandSubroles", @"showDuplicateRanges", @"showKeywordEditor",
            @"beatDetectionGrid", @"timelineScrolling", @"enterFullScreen",
            @"toggleDuplicateDetection",
            @"increaseClipHeight", @"decreaseClipHeight",
            @"showClipNames", @"toggleClipAppearanceAudioWaveformsAction",
            // Render / Export
            @"renderSelection", @"renderAll", @"deleteRenderFiles",
            @"analyzeAndFix", @"exportXML", @"shareSelection",
            // Project / Library
            @"duplicateProject", @"snapshotProject", @"projectProperties", @"libraryProperties",
            @"closeLibrary", @"mergeEvents", @"deleteGeneratedFiles",
            @"newProject", @"newEvent", @"importMedia", @"showProjectProperties",
            @"consolidateMedia", @"transcodeMedia",
            // Find
            @"find", @"findAndReplaceTitle",
            // Reveal
            @"revealInBrowser", @"revealProjectInBrowser", @"revealInFinder", @"moveToTrash",
            // Keywords
            @"addKeywordGroup1", @"addKeywordGroup2", @"addKeywordGroup3", @"addKeywordGroup4",
            @"addKeywordGroup5", @"addKeywordGroup6", @"addKeywordGroup7",
            @"removeAllKeywords", @"removeAnalysisKeywords",
            // Roles
            @"showRoleEditor", @"editRoles",
            @"assignDefaultVideoRole", @"assignDefaultAudioRole",
            // Window / App
            @"recordVoiceover", @"backgroundTasks", @"showPreferences",
            // Edit modes
            @"connectEditAudio", @"connectEditVideo",
            @"insertEditAudio", @"insertEditVideo",
            @"appendEditAudio", @"appendEditVideo",
            @"overwriteEditAudio", @"overwriteEditVideo",
            @"avEditModeAudio", @"avEditModeVideo", @"avEditModeBoth",
            @"replaceFromStart", @"replaceFromEnd", @"replaceWhole",
            // Navigation go-to
            @"goToInspector", @"goToTimeline", @"goToViewer", @"goToColorBoard",
        ]];
    });

    // Map hallucinated timeline action names to correct effect/transition
    static NSDictionary *hallToEffect = nil;
    static NSDictionary *hallToTransition = nil;
    static dispatch_once_t onceToken2;
    dispatch_once(&onceToken2, ^{
        hallToEffect = @{
            // Blur family
            @"addGaussianBlur": @"Gaussian Blur", @"addBlur": @"Gaussian Blur",
            @"blur": @"Gaussian Blur", @"gaussianBlur": @"Gaussian Blur",
            @"applyBlur": @"Gaussian Blur", @"addSoftFocus": @"Soft Focus",
            @"softFocus": @"Soft Focus", @"addZoomBlur": @"Zoom Blur",
            @"addRadialBlur": @"Radial Blur", @"addPrismBlur": @"Prism Blur",
            @"addChannelBlur": @"Channel Blur",
            // Keyers
            @"addKeyer": @"Keyer", @"addLumaKeyer": @"Luma Keyer",
            @"addChromaKeyer": @"Chroma Keyer", @"chromaKey": @"Chroma Keyer",
            @"greenScreen": @"Keyer", @"removeBackground": @"Keyer",
            // Color looks
            @"addVignette": @"Vignette", @"addSharpen": @"Sharpen",
            @"sharpenVideo": @"Sharpen", @"addUnsharpMask": @"Unsharp Mask",
            @"addSepia": @"Sepia", @"sepiaFilter": @"Sepia", @"sepiaTone": @"Sepia",
            @"addBlackAndWhite": @"Black & White", @"blackAndWhite": @"Black & White",
            @"bw": @"Black & White", @"desaturate": @"Black & White", @"grayscale": @"Black & White",
            @"addTint": @"Tint", @"tint": @"Tint",
            @"addNegative": @"Negative", @"negative": @"Negative",
            @"addColorMonochrome": @"Color Monochrome",
            @"addVintage": @"Vintage", @"vintage": @"Vintage", @"retro": @"Vintage",
            // Stylize
            @"addFilmGrain": @"Film Grain", @"filmGrain": @"Film Grain", @"grain": @"Film Grain",
            @"addAgedFilm": @"Aged Film", @"agedFilm": @"Aged Film", @"oldFilm": @"Aged Film",
            @"addBadTV": @"Bad TV", @"badTV": @"Bad TV", @"staticEffect": @"Bad TV",
            @"addBloom": @"Bloom", @"bloom": @"Bloom",
            @"addGlow": @"Glow", @"glow": @"Glow",
            @"addGloom": @"Gloom", @"gloom": @"Gloom",
            // Distortion
            @"addUnderwater": @"Underwater", @"underwater": @"Underwater",
            @"addEarthquake": @"Earthquake", @"earthquake": @"Earthquake", @"shake": @"Earthquake",
            @"addFisheye": @"Fisheye", @"fisheye": @"Fisheye",
            @"addMirror": @"Mirror", @"mirror": @"Mirror",
            @"addKaleidoscope": @"Kaleidoscope", @"kaleidoscope": @"Kaleidoscope",
            // Pixelate / Mosaic
            @"addPixellate": @"Pixellate", @"pixelate": @"Pixellate", @"mosaic": @"Pixellate",
            @"addPosterize": @"Posterize", @"posterize": @"Posterize",
            // Light
            @"addLightRays": @"Light Rays", @"lightRays": @"Light Rays", @"godRays": @"Light Rays",
            @"addLensFlare": @"Lens Flare", @"lensFlare": @"Lens Flare",
            @"addLightWrap": @"Light Wrap", @"lightWrap": @"Light Wrap",
            // Correction / Fix
            @"stabilize": @"Stabilization", @"addStabilization": @"Stabilization",
            @"stabilizeVideo": @"Stabilization", @"reduceShake": @"Stabilization",
            @"addNoiseReduction": @"Noise Reduction", @"noiseReduction": @"Noise Reduction",
            @"reduceNoise": @"Noise Reduction", @"denoise": @"Noise Reduction",
            @"addRollingShutter": @"Rolling Shutter", @"fixRollingShutter": @"Rolling Shutter",
            @"addBroadcastSafe": @"Broadcast Safe",
            // Masks
            @"addDrawMask": @"Draw Mask", @"drawMask": @"Draw Mask",
            @"addShapeMask": @"Shape Mask", @"shapeMask": @"Shape Mask",
            @"addImageMask": @"Image Mask",
            // Other
            @"addLetterbox": @"Letterbox", @"letterbox": @"Letterbox", @"cinemaScope": @"Letterbox",
            @"addDropShadow": @"Drop Shadow", @"dropShadow": @"Drop Shadow", @"shadow": @"Drop Shadow",
            @"addFlipped": @"Flipped", @"flip": @"Flipped", @"flipHorizontal": @"Flipped",
            @"flipVertical": @"Flipped", @"mirrorHorizontal": @"Flipped",
            @"addInvert": @"Invert", @"invertColors": @"Invert", @"invert": @"Invert",
            @"addTiltShift": @"Tilt-Shift", @"tiltShift": @"Tilt-Shift", @"miniature": @"Tilt-Shift",
            @"addCustomLUT": @"Custom LUT", @"lut": @"Custom LUT", @"applyLUT": @"Custom LUT",
            @"addBumpMap": @"Bump Map",
            @"addColorCorrection": @"Color Correction",
            @"addNightVision": @"Night Vision", @"nightVision": @"Night Vision",
            @"addXRay": @"X-Ray", @"xray": @"X-Ray",
            @"addPrism": @"Prism", @"prism": @"Prism",
            @"blendVideo": @"Flipped",
        };
        hallToTransition = @{
            @"crossDissolve": @"Cross Dissolve", @"addCrossDissolve": @"Cross Dissolve",
            @"dissolve": @"Cross Dissolve",
            @"flow": @"Flow", @"addFlow": @"Flow",
            @"fadeToColor": @"Fade To Color", @"fadeToBlack": @"Fade To Color",
            @"fade": @"Fade To Color", @"addFade": @"Fade To Color",
            @"wipe": @"Wipe", @"addWipe": @"Wipe",
            @"push": @"Push", @"addPush": @"Push",
            @"slide": @"Slide", @"addSlide": @"Slide",
            @"spin": @"Spin", @"addSpin": @"Spin",
            @"pageCurl": @"Page Curl", @"addPageCurl": @"Page Curl",
            @"star": @"Star", @"addStar": @"Star",
            @"zoom": @"Zoom", @"addZoom": @"Zoom",
            @"band": @"Band", @"addBand": @"Band",
            @"doorway": @"Doorway", @"addDoorway": @"Doorway",
            @"addMosaic": @"Mosaic",
        };
    });

    NSMutableArray *result = [NSMutableArray array];

    for (NSDictionary *act in actions) {
        if (![act isKindOfClass:[NSDictionary class]]) continue;

        NSMutableDictionary *fixed = [act mutableCopy];
        NSString *type = fixed[@"type"];
        NSString *action = fixed[@"action"];
        NSString *name = fixed[@"name"];

        // Fix 1: timeline action with "name" field that matches a transition name
        if ([type isEqualToString:@"timeline"] && [action isEqualToString:@"addTransition"] && name) {
            if ([transitionNames containsObject:name]) {
                fixed = [@{@"type": @"transition", @"name": name} mutableCopy];
                SpliceKit_log(@"[AppleAI-fix] timeline.addTransition(%@) -> transition(%@)", name, name);
            }
        }
        // Fix 2: timeline action with "name" field that matches an effect name
        else if ([type isEqualToString:@"timeline"] && name) {
            if ([effectNames containsObject:name]) {
                fixed = [@{@"type": @"effect", @"name": name} mutableCopy];
                SpliceKit_log(@"[AppleAI-fix] timeline.%@(name=%@) -> effect(%@)", action, name, name);
            }
        }
        // Fix 3: timeline action whose action name IS an effect name
        else if ([type isEqualToString:@"timeline"] && action && [effectNames containsObject:action]) {
            fixed = [@{@"type": @"effect", @"name": action} mutableCopy];
            SpliceKit_log(@"[AppleAI-fix] timeline.action(%@) -> effect(%@)", action, action);
        }
        // Fix 4: hallucinated timeline action name maps to an effect
        else if ([type isEqualToString:@"timeline"] && action && hallToEffect[action]) {
            NSString *effectName = hallToEffect[action];
            fixed = [@{@"type": @"effect", @"name": effectName} mutableCopy];
            SpliceKit_log(@"[AppleAI-fix] timeline.%@ -> effect(%@)", action, effectName);
        }
        // Fix 5: hallucinated timeline action name maps to a transition
        else if ([type isEqualToString:@"timeline"] && action && hallToTransition[action]) {
            NSString *transName = hallToTransition[action];
            fixed = [@{@"type": @"transition", @"name": transName} mutableCopy];
            SpliceKit_log(@"[AppleAI-fix] timeline.%@ -> transition(%@)", action, transName);
        }
        // Fix 6: invalid action type (e.g. "audio" instead of "timeline")
        else if (type && ![type isEqualToString:@"timeline"] && ![type isEqualToString:@"playback"]
                 && ![type isEqualToString:@"seek"] && ![type isEqualToString:@"effect"]
                 && ![type isEqualToString:@"transition"] && ![type isEqualToString:@"repeat_pattern"]
                 && ![type isEqualToString:@"scene_detect"] && ![type isEqualToString:@"scene_markers"]) {
            // Try to map the action to a valid timeline action
            if (action && [validTimelineActions containsObject:action]) {
                fixed[@"type"] = @"timeline";
                SpliceKit_log(@"[AppleAI-fix] %@.%@ -> timeline.%@", type, action, action);
            } else if (action && hallToEffect[action]) {
                fixed = [@{@"type": @"effect", @"name": hallToEffect[action]} mutableCopy];
            }
        }
        // Fix 7: playback action that should be timeline (e.g. detachAudio in playback)
        else if ([type isEqualToString:@"playback"] && action && [validTimelineActions containsObject:action]) {
            if (![@[@"playPause", @"goToStart", @"goToEnd", @"nextFrame", @"prevFrame", @"nextFrame10", @"prevFrame10", @"playAroundCurrent"] containsObject:action]) {
                fixed[@"type"] = @"timeline";
                SpliceKit_log(@"[AppleAI-fix] playback.%@ -> timeline.%@", action, action);
            }
        }
        // Fix 7b: "pause" or "play" as playback action -> playPause
        else if ([type isEqualToString:@"playback"] && ([action isEqualToString:@"pause"] || [action isEqualToString:@"play"])) {
            fixed[@"action"] = @"playPause";
            SpliceKit_log(@"[AppleAI-fix] playback.%@ -> playback.playPause", action);
        }

        // Fix 8: drop invalid timeline actions (not in known set and not a hallucination we mapped)
        if ([fixed[@"type"] isEqualToString:@"timeline"] && fixed[@"action"]
            && ![validTimelineActions containsObject:fixed[@"action"]]) {
            SpliceKit_log(@"[AppleAI-fix] dropping invalid timeline.%@", fixed[@"action"]);
            continue; // skip this action entirely
        }

        [result addObject:fixed];
    }

    // Fix 9: limit to 10 actions max to prevent over-generation
    if (result.count > 10) {
        SpliceKit_log(@"[AppleAI-fix] trimming %lu actions to 10", (unsigned long)result.count);
        result = [[result subarrayWithRange:NSMakeRange(0, 10)] mutableCopy];
    }

    // Fix 10: deduplicate consecutive identical actions (except seek)
    NSMutableArray *deduped = [NSMutableArray array];
    NSDictionary *prev = nil;
    for (NSDictionary *act in result) {
        if (prev && [act isEqualToDictionary:prev] && ![act[@"type"] isEqualToString:@"seek"]) {
            SpliceKit_log(@"[AppleAI-fix] dedup: skipping duplicate %@.%@", act[@"type"], act[@"action"] ?: act[@"name"]);
            continue;
        }
        [deduped addObject:act];
        prev = act;
    }

    // Fix 11: if AI returned garbage but we have good keyword fallback, prefer it
    if (deduped.count == 0) {
        NSArray *fallback = [self keywordFallback:query];
        if (fallback.count > 0) {
            SpliceKit_log(@"[AppleAI-fix] all actions filtered, using keyword fallback (%lu)", (unsigned long)fallback.count);
            return fallback;
        }
    }

    // Fix 12: if query clearly matches an effect/transition keyword but AI returned none,
    // supplement with keyword fallback. This catches cases where the model returns valid
    // but wrong actions (e.g. addColorBoard for "add vignette").
    if (deduped.count > 0) {
        NSArray *fallback = [self keywordFallback:query];
        if (fallback.count > 0) {
            BOOL hasEffect = NO, hasTransition = NO;
            for (NSDictionary *a in deduped) {
                if ([a[@"type"] isEqualToString:@"effect"]) hasEffect = YES;
                if ([a[@"type"] isEqualToString:@"transition"]) hasTransition = YES;
            }
            BOOL fallbackHasEffectOrTransition = NO;
            for (NSDictionary *a in fallback) {
                if ([a[@"type"] isEqualToString:@"effect"] || [a[@"type"] isEqualToString:@"transition"]) {
                    fallbackHasEffectOrTransition = YES;
                    break;
                }
            }
            if (!hasEffect && !hasTransition && fallbackHasEffectOrTransition) {
                SpliceKit_log(@"[AppleAI-fix] AI missed effect/transition, using keyword fallback instead");
                return fallback;
            }
            // Fix 12b: if AI returned 3+ unrelated actions (hallucination) but keyword fallback
            // gives a clean 1-2 action answer, prefer the fallback. The on-device model often
            // hallucinates multi-action sequences for simple commands.
            if (deduped.count >= 3 && fallback.count <= 2) {
                SpliceKit_log(@"[AppleAI-fix] AI hallucinated %lu actions, keyword fallback has %lu — preferring fallback",
                              (unsigned long)deduped.count, (unsigned long)fallback.count);
                return fallback;
            }
        }
    }

    return deduped;
}

#pragma mark - Keyword Fallback (when AI unavailable)

- (NSArray<NSDictionary *> *)keywordFallback:(NSString *)query {
    NSString *q = [query lowercaseString];
    NSMutableArray *actions = [NSMutableArray array];

    // ── Undo / Redo ──
    if ([q containsString:@"undo"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"undo"}];
    } else if ([q containsString:@"redo"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"redo"}];
    }
    // ── Playback ──
    else if ([q containsString:@"play"] || [q containsString:@"pause"] || [q containsString:@"stop"]) {
        [actions addObject:@{@"type": @"playback", @"action": @"playPause"}];
    } else if ([q containsString:@"beginning"] || [q containsString:@"start"] || [q containsString:@"rewind"]) {
        [actions addObject:@{@"type": @"playback", @"action": @"goToStart"}];
    } else if ([q containsString:@"go to the end"] || [q containsString:@"go to end"] || [q containsString:@"jump to end"]) {
        [actions addObject:@{@"type": @"playback", @"action": @"goToEnd"}];
    } else if ([q containsString:@"next frame"] || [q containsString:@"advance one frame"] || [q containsString:@"forward one frame"]) {
        [actions addObject:@{@"type": @"playback", @"action": @"nextFrame"}];
    } else if ([q containsString:@"previous frame"] || [q containsString:@"prev frame"] || [q containsString:@"back one frame"]) {
        [actions addObject:@{@"type": @"playback", @"action": @"prevFrame"}];
    } else if ([q containsString:@"10 frame"] || [q containsString:@"ten frame"]) {
        if ([q containsString:@"back"] || [q containsString:@"prev"]) {
            [actions addObject:@{@"type": @"playback", @"action": @"prevFrame10"}];
        } else {
            [actions addObject:@{@"type": @"playback", @"action": @"nextFrame10"}];
        }
    }
    // ── Blade / Cut ──
    else if ([q containsString:@"blade all"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"bladeAll"}];
    } else if ([q containsString:@"cut"] || [q containsString:@"split"] || [q containsString:@"blade"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"blade"}];
    }
    // ── Delete ──
    else if ([q containsString:@"replace"] && [q containsString:@"gap"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"replaceWithGap"}];
    } else if ([q containsString:@"join"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"joinClips"}];
    } else if ([q containsString:@"trim to playhead"] || [q containsString:@"trim to the playhead"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"trimToPlayhead"}];
    } else if ([q containsString:@"trim"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"trimToPlayhead"}];
    } else if ([q containsString:@"delete render"] || [q containsString:@"clear render"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"deleteRenderFiles"}];
    } else if ([q containsString:@"delete generated"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"deleteGeneratedFiles"}];
    } else if ([q containsString:@"delete"] || [q containsString:@"remove"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"delete"}];
    }
    // ── Transitions (by specific name) ──
    else if ([q containsString:@"cross dissolve"]) {
        [actions addObject:@{@"type": @"transition", @"name": @"Cross Dissolve"}];
    } else if ([q containsString:@"flow transition"] || [q containsString:@"add flow"] || [q containsString:@"apply flow"]) {
        [actions addObject:@{@"type": @"transition", @"name": @"Flow"}];
    } else if ([q containsString:@"wipe"]) {
        [actions addObject:@{@"type": @"transition", @"name": @"Wipe"}];
    } else if ([q containsString:@"push transition"]) {
        [actions addObject:@{@"type": @"transition", @"name": @"Push"}];
    } else if ([q containsString:@"spin transition"]) {
        [actions addObject:@{@"type": @"transition", @"name": @"Spin"}];
    } else if ([q containsString:@"page curl"]) {
        [actions addObject:@{@"type": @"transition", @"name": @"Page Curl"}];
    } else if ([q containsString:@"slide transition"]) {
        [actions addObject:@{@"type": @"transition", @"name": @"Slide"}];
    } else if ([q containsString:@"zoom transition"]) {
        [actions addObject:@{@"type": @"transition", @"name": @"Zoom"}];
    } else if ([q containsString:@"star transition"]) {
        [actions addObject:@{@"type": @"transition", @"name": @"Star"}];
    } else if ([q containsString:@"fade to"] || [q containsString:@"fade out"]) {
        [actions addObject:@{@"type": @"transition", @"name": @"Fade To Color"}];
    } else if ([q containsString:@"transition"] || [q containsString:@"dissolve"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"addTransition"}];
    }
    // ── Markers ──
    else if ([q containsString:@"marker"]) {
        if ([q containsString:@"remove all"] || [q containsString:@"delete all"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"selectAll"}];
            [actions addObject:@{@"type": @"timeline", @"action": @"deleteMarkersInSelection"}];
        } else if ([q containsString:@"chapter"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"addChapterMarker"}];
        } else if ([q containsString:@"todo"] || [q containsString:@"to-do"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"addTodoMarker"}];
        } else if ([q containsString:@"delete"] || [q containsString:@"remove"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"deleteMarker"}];
        } else if ([q containsString:@"next"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"nextMarker"}];
        } else if ([q containsString:@"previous"] || [q containsString:@"prev"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"previousMarker"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"addMarker"}];
        }
    }
    // ── Color correction ──
    else if ([q containsString:@"color wheel"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"addColorWheels"}];
    } else if ([q containsString:@"color curve"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"addColorCurves"}];
    } else if ([q containsString:@"hue"] && [q containsString:@"sat"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"addHueSaturation"}];
    } else if ([q containsString:@"enhance"] && ([q containsString:@"light"] || [q containsString:@"color"])) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"addEnhanceLightAndColor"}];
    } else if ([q containsString:@"balance"] && [q containsString:@"color"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"balanceColor"}];
    } else if ([q containsString:@"color"] || [q containsString:@"grade"] || [q containsString:@"correct"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"addColorBoard"}];
    }
    // ── Speed ──
    else if ([q containsString:@"slow"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        if ([q containsString:@"10"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"retimeSlow10"}];
        } else if ([q containsString:@"25"] || [q containsString:@"quarter"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"retimeSlow25"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"retimeSlow50"}];
        }
    } else if ([q containsString:@"fast"] || [q containsString:@"speed up"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        if ([q containsString:@"20"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"retimeFast20x"}];
        } else if ([q containsString:@"8"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"retimeFast8x"}];
        } else if ([q containsString:@"4"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"retimeFast4x"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"retimeFast2x"}];
        }
    } else if ([q containsString:@"reverse"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"retimeReverse"}];
    } else if ([q containsString:@"freeze"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"freezeFrame"}];
    } else if ([q containsString:@"hold"] && [q containsString:@"frame"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"retimeHold"}];
    } else if ([q containsString:@"normal speed"] || [q containsString:@"reset speed"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"retimeNormal"}];
    } else if ([q containsString:@"blade speed"] || [q containsString:@"speed segment"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"retimeBladeSpeed"}];
    }
    // ── Titles ──
    else if ([q containsString:@"lower third"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"addBasicLowerThird"}];
    } else if ([q containsString:@"title"] || [q containsString:@"text overlay"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"addBasicTitle"}];
    }
    // ── Audio ──
    else if ([q containsString:@"volume up"] || [q containsString:@"louder"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"adjustVolumeUp"}];
    } else if ([q containsString:@"volume down"] || [q containsString:@"quieter"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"adjustVolumeDown"}];
    } else if ([q containsString:@"detach audio"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"detachAudio"}];
    }
    // ── Selection & Organization ──
    else if ([q containsString:@"select all"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectAll"}];
    } else if ([q containsString:@"deselect"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"deselectAll"}];
    } else if ([q containsString:@"select"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
    } else if ([q containsString:@"compound"] || [q containsString:@"nest"] || [q containsString:@"group"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"createCompoundClip"}];
    } else if ([q containsString:@"solo"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"solo"}];
    } else if ([q containsString:@"disable"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"disable"}];
    }
    // ── View ──
    else if ([q containsString:@"zoom to fit"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"zoomToFit"}];
    } else if ([q containsString:@"zoom in"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"zoomIn"}];
    } else if ([q containsString:@"zoom out"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"zoomOut"}];
    } else if ([q containsString:@"snapping"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"toggleSnapping"}];
    } else if ([q containsString:@"render"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"renderAll"}];
    } else if ([q containsString:@"export"] || [q containsString:@"xml"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"exportXML"}];
    } else if ([q containsString:@"analyze"] || [q containsString:@"fix"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"analyzeAndFix"}];
    } else if ([q containsString:@"adjustment layer"] || [q containsString:@"adjustment clip"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"addAdjustmentClip"}];
    }
    // ── App ──
    else if ([q containsString:@"preference"] || [q containsString:@"settings"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"showPreferences"}];
    }
    // ── Trim ──
    else if ([q containsString:@"nudge"] || [q containsString:@"shift clip"]) {
        if ([q containsString:@"up"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"nudgeUp"}];
        } else if ([q containsString:@"down"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"nudgeDown"}];
        } else if ([q containsString:@"left"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"nudgeLeft"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"nudgeRight"}];
        }
    } else if ([q containsString:@"trim start"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"trimStart"}];
    } else if ([q containsString:@"trim end"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"trimEnd"}];
    } else if ([q containsString:@"extend edit"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"extendEditToPlayhead"}];
    } else if ([q containsString:@"roll edit"]) {
        if ([q containsString:@"left"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"rollEditLeft"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"rollEditRight"}];
        }
    } else if ([q containsString:@"slip"]) {
        if ([q containsString:@"left"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"slipLeft"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"slipRight"}];
        }
    }
    // ── Range / In-Out ──
    else if ([q containsString:@"mark in"] || [q containsString:@"in point"] || [q containsString:@"range start"] || [q containsString:@"set in"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"setRangeStart"}];
    } else if ([q containsString:@"mark out"] || [q containsString:@"out point"] || [q containsString:@"range end"] || [q containsString:@"set out"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"setRangeEnd"}];
    } else if ([q containsString:@"clear range"] || [q containsString:@"clear in"] || [q containsString:@"remove range"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"clearRange"}];
    }
    // ── Audio extras ──
    else if ([q containsString:@"mute"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"volumeMute"}];
    } else if ([q containsString:@"fade in"] && [q containsString:@"audio"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"addAudioFadeIn"}];
    } else if ([q containsString:@"fade out"] && [q containsString:@"audio"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"addAudioFadeOut"}];
    } else if ([q containsString:@"channel eq"] || [q containsString:@"equaliz"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"addChannelEQ"}];
    } else if ([q containsString:@"enhance audio"] || [q containsString:@"audio enhance"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"enhanceAudio"}];
    } else if ([q containsString:@"match audio"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"matchAudio"}];
    } else if ([q containsString:@"expand audio"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"expandAudioComponents"}];
    }
    // ── Multicam ──
    else if ([q containsString:@"multicam"] || [q containsString:@"multi-cam"] || [q containsString:@"multi cam"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"createMulticamClip"}];
    } else if ([q containsString:@"switch"] && [q containsString:@"angle"]) {
        if ([q containsString:@"4"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"switchAngle04"}];
        } else if ([q containsString:@"3"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"switchAngle03"}];
        } else if ([q containsString:@"2"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"switchAngle02"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"switchAngle01"}];
        }
    } else if ([q containsString:@"camera"] && ([q containsString:@"switch"] || [q containsString:@"cam"])) {
        if ([q containsString:@"4"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"switchAngle04"}];
        } else if ([q containsString:@"3"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"switchAngle03"}];
        } else if ([q containsString:@"2"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"switchAngle02"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"switchAngle01"}];
        }
    }
    // ── Rating ──
    else if ([q containsString:@"favorite"] || [q containsString:@"favourite"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"favorite"}];
    } else if ([q containsString:@"reject"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"reject"}];
    } else if ([q containsString:@"unrate"] || [q containsString:@"remove rating"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"unrate"}];
    }
    // ── Captions ──
    else if ([q containsString:@"caption"] || [q containsString:@"subtitle"]) {
        if ([q containsString:@"split"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"splitCaption"}];
        } else if ([q containsString:@"overlap"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"resolveOverlaps"}];
        } else if ([q containsString:@"import"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"importCaptions"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"addCaption"}];
        }
    }
    // ── Project / Library ──
    else if ([q containsString:@"duplicate project"] || [q containsString:@"copy project"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"duplicateProject"}];
    } else if ([q containsString:@"snapshot"] || [q containsString:@"backup project"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"snapshotProject"}];
    } else if ([q containsString:@"project properties"] || [q containsString:@"project settings"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"projectProperties"}];
    } else if ([q containsString:@"library properties"] || [q containsString:@"library info"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"libraryProperties"}];
    } else if ([q containsString:@"close library"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"closeLibrary"}];
    } else if ([q containsString:@"merge event"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"mergeEvents"}];
    } else if ([q containsString:@"delete generated"] || [q containsString:@"free space"] || [q containsString:@"free up"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"deleteGeneratedFiles"}];
    } else if ([q containsString:@"delete render"] || [q containsString:@"clear cache"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"deleteRenderFiles"}];
    } else if ([q containsString:@"import media"] || [q containsString:@"import file"] || [q containsString:@"add files"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"importMedia"}];
    } else if ([q containsString:@"new project"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"newProject"}];
    } else if ([q containsString:@"new event"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"newEvent"}];
    } else if ([q containsString:@"consolidate"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"consolidateMedia"}];
    } else if ([q containsString:@"transcode"] || [q containsString:@"proxy"] || [q containsString:@"optimiz"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"transcodeMedia"}];
    }
    // ── Reveal / Find ──
    else if ([q containsString:@"reveal"] && [q containsString:@"finder"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"revealInFinder"}];
    } else if ([q containsString:@"show in finder"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"revealInFinder"}];
    } else if ([q containsString:@"find and replace"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"findAndReplaceTitle"}];
    } else if ([q containsString:@"search"] || [q containsString:@"find text"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"find"}];
    }
    // ── Clip operations ──
    else if ([q containsString:@"lift"] && [q containsString:@"storyline"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"liftFromPrimaryStoryline"}];
    } else if ([q containsString:@"overwrite"] && [q containsString:@"primary"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"overwriteToPrimaryStoryline"}];
    } else if ([q containsString:@"break apart"] || [q containsString:@"ungroup"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"breakApartClipItems"}];
    } else if ([q containsString:@"sync"] && [q containsString:@"clip"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"synchronizeClips"}];
    } else if ([q containsString:@"make unique"] || [q containsString:@"independent cop"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"makeClipsUnique"}];
    } else if ([q containsString:@"rename clip"] || [q containsString:@"rename the clip"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"renameClip"}];
    } else if ([q containsString:@"open in timeline"] || [q containsString:@"dive in"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"openInTimeline"}];
    } else if ([q containsString:@"back to parent"] || [q containsString:@"exit compound"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"backToParent"}];
    }
    // ── View toggles ──
    else if ([q containsString:@"inspector"]) {
        if ([q containsString:@"toggle"] || [q containsString:@"show"] || [q containsString:@"hide"] || [q containsString:@"open"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"toggleInspector"}];
        }
    } else if ([q containsString:@"timeline index"] || [q containsString:@"sidebar"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"toggleTimelineIndex"}];
    } else if ([q containsString:@"full screen"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"enterFullScreen"}];
    } else if ([q containsString:@"precision editor"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"togglePrecisionEditor"}];
    } else if ([q containsString:@"audio lane"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"showAudioLanes"}];
    } else if ([q containsString:@"video animation"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"showVideoAnimation"}];
    } else if ([q containsString:@"audio animation"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"showAudioAnimation"}];
    } else if ([q containsString:@"clip height"] || [q containsString:@"clip taller"] || [q containsString:@"clip bigger"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"increaseClipHeight"}];
    } else if ([q containsString:@"clip shorter"] || [q containsString:@"clip smaller"] || [q containsString:@"compact"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"decreaseClipHeight"}];
    } else if ([q containsString:@"waveform"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"toggleClipAppearanceAudioWaveformsAction"}];
    }
    // ── Speed extras ──
    else if ([q containsString:@"speed ramp"] || [q containsString:@"ramp"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        if ([q containsString:@"from zero"] || [q containsString:@"from freeze"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"retimeSpeedRampFromZero"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"retimeSpeedRampToZero"}];
        }
    } else if ([q containsString:@"optical flow"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"retimeOpticalFlow"}];
    } else if ([q containsString:@"frame blending"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"retimeFrameBlending"}];
    } else if ([q containsString:@"instant replay"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"retimeInstantReplayHalf"}];
    }
    // ── Transform / Spatial ──
    else if ([q containsString:@"transform"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"showTransformControls"}];
    } else if ([q containsString:@"crop"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"showCropControls"}];
    } else if ([q containsString:@"distort"] || [q containsString:@"corner pin"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"showDistortControls"}];
    }
    // ── Magnetic mask ──
    else if ([q containsString:@"magnetic mask"] || [q containsString:@"object mask"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"addMagneticMask"}];
    } else if ([q containsString:@"smart conform"] || [q containsString:@"auto reframe"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"autoReframe"}];
    }
    // ── Keywords ──
    else if ([q containsString:@"keyword"]) {
        if ([q containsString:@"remove all"] || [q containsString:@"clear"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"removeAllKeywords"}];
        } else if ([q containsString:@"editor"] || [q containsString:@"show"] || [q containsString:@"open"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"showKeywordEditor"}];
        }
    }
    // ── Voiceover ──
    else if ([q containsString:@"voiceover"] || [q containsString:@"voice over"] || [q containsString:@"narrat"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"recordVoiceover"}];
    }
    // ── Background tasks ──
    else if ([q containsString:@"background task"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"backgroundTasks"}];
    }
    // ── Roles ──
    else if ([q containsString:@"role"]) {
        if ([q containsString:@"edit"] || [q containsString:@"manage"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"editRoles"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"showRoleEditor"}];
        }
    }
    // ── Auditions ──
    else if ([q containsString:@"audition"]) {
        if ([q containsString:@"finalize"] || [q containsString:@"commit"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"finalizeAudition"}];
        } else if ([q containsString:@"next"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"nextAuditionPick"}];
        } else if ([q containsString:@"prev"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"previousAuditionPick"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"createAudition"}];
        }
    }
    // ── Effects (by keyword) ──
    else if ([q containsString:@"luma keyer"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Luma Keyer"}];
    } else if ([q containsString:@"chroma keyer"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Chroma Keyer"}];
    } else if ([q containsString:@"keyer"] || [q containsString:@"green screen"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Keyer"}];
    } else if ([q containsString:@"blur"] || [q containsString:@"gaussian"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Gaussian Blur"}];
    } else if ([q containsString:@"vignette"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Vignette"}];
    } else if ([q containsString:@"sharpen"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Sharpen"}];
    } else if ([q containsString:@"stabiliz"] || [q containsString:@"camera shake"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Stabilization"}];
    } else if ([q containsString:@"rolling shutter"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Rolling Shutter"}];
    } else if ([q containsString:@"noise reduction"] || [q containsString:@"denoise"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Noise Reduction"}];
    } else if ([q containsString:@"black and white"] || [q containsString:@"b&w"] || [q containsString:@"monochrome"] || [q containsString:@"grayscale"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Black & White"}];
    } else if ([q containsString:@"sepia"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Sepia"}];
    } else if ([q containsString:@"aged film"] || [q containsString:@"old film"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Aged Film"}];
    } else if ([q containsString:@"film grain"] || [q containsString:@"grain"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Film Grain"}];
    } else if ([q containsString:@"bloom"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Bloom"}];
    } else if ([q containsString:@"glow"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Glow"}];
    } else if ([q containsString:@"letterbox"] || [q containsString:@"cinema bar"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Letterbox"}];
    } else if ([q containsString:@"drop shadow"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Drop Shadow"}];
    } else if ([q containsString:@"lens flare"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Lens Flare"}];
    } else if ([q containsString:@"light ray"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Light Rays"}];
    } else if ([q containsString:@"tilt"] && [q containsString:@"shift"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Tilt-Shift"}];
    } else if ([q containsString:@"flip"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Flipped"}];
    } else if ([q containsString:@"invert"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Invert"}];
    } else if ([q containsString:@"posterize"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Posterize"}];
    } else if ([q containsString:@"pixelat"] || [q containsString:@"pixellat"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Pixellate"}];
    } else if ([q containsString:@"underwater"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Underwater"}];
    } else if ([q containsString:@"night vision"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Night Vision"}];
    } else if ([q containsString:@"x-ray"] || [q containsString:@"xray"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"X-Ray"}];
    } else if ([q containsString:@"bad tv"] || [q containsString:@"static"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Bad TV"}];
    } else if ([q containsString:@"earthquake"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Earthquake"}];
    } else if ([q containsString:@"fisheye"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Fisheye"}];
    } else if ([q containsString:@"kaleidoscope"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Kaleidoscope"}];
    } else if ([q containsString:@"vintage"] || [q containsString:@"retro look"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Vintage"}];
    } else if ([q containsString:@"broadcast safe"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Broadcast Safe"}];
    } else if ([q containsString:@"custom lut"] || [q containsString:@"apply lut"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Custom LUT"}];
    }

    return actions;
}

@end
