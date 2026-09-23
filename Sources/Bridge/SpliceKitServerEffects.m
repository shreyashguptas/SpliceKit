//
//  SpliceKitServerEffects.m
//  SpliceKit - Effect discovery, effects.* browse and apply handlers, and title /
//  generator insertion through the pasteboard.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Effect Discovery

NSDictionary *SpliceKit_handleEffectList(NSDictionary *params) {
    NSString *filter = params[@"filter"];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline"};
                return;
            }

            // Get the sequence's effect registry via the sequence
            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) {
                result = @{@"error": @"No sequence"};
                return;
            }

            // Try to get effects from the FFEffectRegistry
            Class registryClass = objc_getClass("FFEffectRegistry");
            if (!registryClass) {
                result = @{@"error": @"FFEffectRegistry class not found"};
                return;
            }

            // Get the shared registry
            SEL regSel = NSSelectorFromString(@"registry:");
            id registry = nil;
            if ([registryClass respondsToSelector:regSel]) {
                registry = ((id (*)(id, SEL, id))objc_msgSend)((id)registryClass, regSel, nil);
            }
            if (!registry) {
                // Try alternate: sharedRegistry
                SEL sharedSel = NSSelectorFromString(@"sharedRegistry");
                if ([registryClass respondsToSelector:sharedSel]) {
                    registry = ((id (*)(id, SEL))objc_msgSend)((id)registryClass, sharedSel);
                }
            }

            if (registry) {
                NSString *h = SpliceKit_storeHandle(registry);
                result = @{@"handle": h, @"class": NSStringFromClass([registry class]),
                           @"message": @"Use get_object_property to explore the registry"};
            } else {
                result = @{@"error": @"Could not get FFEffectRegistry instance"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

NSDictionary *SpliceKit_handleGetClipEffects(NSDictionary *params) {
    NSString *clipHandle = params[@"handle"];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id clip = nil;
            if (clipHandle) {
                clip = SpliceKit_resolveHandle(clipHandle);
            }

            if (!clip) {
                // Get first selected clip
                id timeline = SpliceKit_getActiveTimelineModule();
                if (!timeline) { result = @{@"error": @"No timeline"}; return; }

                SEL selSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
                if ([timeline respondsToSelector:selSel]) {
                    id selected = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, selSel, NO, NO);
                    if ([selected respondsToSelector:@selector(firstObject)]) {
                        clip = ((id (*)(id, SEL))objc_msgSend)(selected, @selector(firstObject));
                    }
                }
            }

            if (!clip) { result = @{@"error": @"No clip found (provide handle or select a clip)"}; return; }

            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"clipClass"] = NSStringFromClass([clip class]);
            if ([clip respondsToSelector:@selector(displayName)]) {
                info[@"clipName"] = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName)) ?: @"";
            }

            // Get effect stack
            SEL esSel = @selector(effectStack);
            if ([clip respondsToSelector:esSel]) {
                id effectStack = ((id (*)(id, SEL))objc_msgSend)(clip, esSel);
                if (effectStack) {
                    NSString *esHandle = SpliceKit_storeHandle(effectStack);
                    info[@"effectStackHandle"] = esHandle;
                    info[@"effectStackClass"] = NSStringFromClass([effectStack class]);
                    info[@"effectStackDescription"] = [[effectStack description] substringToIndex:
                        MIN((NSUInteger)500, [[effectStack description] length])];
                }
            }

            // Try to get effects array.
            // -effects can list one object twice: the effect stack exposes it in
            // visibleEffects and again through its intrinsic channels (transform,
            // compositing, crop, volume). storeHandle keys by pointer, so both
            // visits printed the same handle. Keep the first occurrence's order.
            // Identity, not name: two different effects may share a display name.
            SEL efSel = NSSelectorFromString(@"effects");
            if ([clip respondsToSelector:efSel]) {
                id effects = ((id (*)(id, SEL))objc_msgSend)(clip, efSel);
                if ([effects isKindOfClass:[NSArray class]]) {
                    NSMutableArray *efList = [NSMutableArray array];
                    NSMutableSet<NSString *> *seenEffects = [NSMutableSet set];
                    for (id effect in (NSArray *)effects) {
                        if (!effect) continue;
                        NSString *pointerKey = SpliceKit_handlePointerKey(effect);
                        if (pointerKey.length > 0 && [seenEffects containsObject:pointerKey]) continue;
                        if (pointerKey.length > 0) [seenEffects addObject:pointerKey];
                        NSMutableDictionary *ef = [NSMutableDictionary dictionary];
                        ef[@"class"] = NSStringFromClass([effect class]);
                        if ([effect respondsToSelector:@selector(displayName)]) {
                            ef[@"name"] = ((id (*)(id, SEL))objc_msgSend)(effect, @selector(displayName)) ?: @"";
                        }
                        if ([effect respondsToSelector:@selector(effectID)]) {
                            ef[@"effectID"] = ((id (*)(id, SEL))objc_msgSend)(effect, @selector(effectID)) ?: @"";
                        }
                        NSString *efHandle = SpliceKit_storeHandle(effect);
                        ef[@"handle"] = efHandle;
                        [efList addObject:ef];
                    }
                    info[@"effects"] = efList;
                    info[@"effectCount"] = @(efList.count);
                }
            }

            result = info;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

#pragma mark - Effects Browse & Apply Handlers
//
// Browse and apply FCP's effect library (376+ transitions, 200+ filters, generators,
// titles, audio effects). We query the effect registry at runtime and apply effects
// through FCP's pasteboard + drag infrastructure.
//

// Generalized handler that lists effects filtered by type(s)
NSDictionary *SpliceKit_handleEffectsListAvailable(NSDictionary *params) {
    NSString *filter = params[@"filter"];
    NSString *typeFilter = params[@"type"]; // "filter", "transition", "generator", "title", "audio", or nil for all

    // Map friendly type names to internal type strings
    NSDictionary *typeMap = @{
        @"filter":     @"effect.video.filter",
        @"transition": @"effect.video.transition",
        @"generator":  @"effect.video.generator",
        @"title":      @"effect.video.title",
        @"audio":      @"effect.audio.effect",
    };

    NSString *internalType = typeFilter ? typeMap[[typeFilter lowercaseString]] : nil;

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            Class ffEffect = objc_getClass("FFEffect");
            if (!ffEffect) { result = @{@"error": @"FFEffect class not found"}; return; }

            id allIDs = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect, @selector(userVisibleEffectIDs));
            if (!allIDs) { result = @{@"error": @"No effect IDs returned"}; return; }

            SEL typeSel = @selector(effectTypeForEffectID:);
            SEL nameSel = @selector(displayNameForEffectID:);
            SEL catSel = @selector(categoryForEffectID:);

            NSMutableArray *effects = [NSMutableArray array];

            for (NSString *effectID in allIDs) {
                @autoreleasepool {
                    id type = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, effectID);
                    if (![type isKindOfClass:[NSString class]]) continue;
                    NSString *typeStr = (NSString *)type;

                    // Filter by type if requested
                    if (internalType && ![typeStr isEqualToString:internalType]) continue;

                    // Skip transitions if no type filter (they have their own handler)
                    if (!typeFilter && [typeStr isEqualToString:@"effect.video.transition"]) continue;

                    id name = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, effectID);
                    id category = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, catSel, effectID);

                    NSString *displayName = [name isKindOfClass:[NSString class]] ? (NSString *)name : @"Unknown";
                    NSString *catName = [category isKindOfClass:[NSString class]] ? (NSString *)category : @"";

                    // Derive friendly type name
                    NSString *friendlyType = @"filter";
                    if ([typeStr isEqualToString:@"effect.video.generator"]) friendlyType = @"generator";
                    else if ([typeStr isEqualToString:@"effect.video.title"]) friendlyType = @"title";
                    else if ([typeStr isEqualToString:@"effect.audio.effect"]) friendlyType = @"audio";
                    else if ([typeStr isEqualToString:@"effect.video.transition"]) friendlyType = @"transition";

                    // Apply name filter (with normalization for underscores, &, etc.)
                    if (filter.length > 0) {
                        NSString *lowerFilter = [filter lowercaseString];
                        BOOL matches = [[displayName lowercaseString] containsString:lowerFilter] ||
                                       [[catName lowercaseString] containsString:lowerFilter];
                        if (!matches) {
                            // Normalize: strip non-alphanumeric for fuzzy match
                            NSString *(^norm)(NSString *) = ^NSString *(NSString *s) {
                                NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
                                NSString *lower = [s lowercaseString];
                                for (NSUInteger i = 0; i < lower.length; i++) {
                                    unichar c = [lower characterAtIndex:i];
                                    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
                                        [out appendFormat:@"%C", c];
                                }
                                return out;
                            };
                            matches = [norm(displayName) containsString:norm(filter)] ||
                                      [norm(catName) containsString:norm(filter)];
                        }
                        if (!matches) continue;
                    }

                    [effects addObject:@{
                        @"name": displayName,
                        @"effectID": effectID,
                        @"category": catName,
                        @"type": friendlyType,
                    }];
                }
            }

            [effects sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"name"] compare:b[@"name"]];
            }];

            result = @{@"effects": effects, @"count": @(effects.count)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to list effects"};
}

static NSString *SpliceKit_normalizedEffectName(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) return @"";

    NSString *lower = [[name lowercaseString] stringByReplacingOccurrencesOfString:@"&" withString:@"and"];
    NSMutableString *out = [NSMutableString stringWithCapacity:lower.length];
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
            [out appendFormat:@"%C", c];
        }
    }
    return out;
}

static NSDictionary *SpliceKit_effectDescriptorForID(Class ffEffect,
                                                     NSString *effectID,
                                                     NSString *requiredType) {
    if (effectID.length == 0) return @{@"error": @"effectID is empty"};

    SEL typeSel = @selector(effectTypeForEffectID:);
    SEL nameSel = @selector(displayNameForEffectID:);
    SEL catSel = @selector(categoryForEffectID:);

    id typeObj = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, effectID);
    NSString *type = [typeObj isKindOfClass:[NSString class]] ? typeObj : @"";
    if (requiredType.length > 0 && ![type isEqualToString:requiredType]) {
        return @{@"error": [NSString stringWithFormat:@"Effect '%@' is type '%@', expected '%@'",
                            effectID, type.length > 0 ? type : @"unknown", requiredType]};
    }

    id nameObj = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, effectID);
    id categoryObj = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, catSel, effectID);

    return @{
        @"effectID": effectID,
        @"name": [nameObj isKindOfClass:[NSString class]] ? nameObj : effectID,
        @"category": [categoryObj isKindOfClass:[NSString class]] ? categoryObj : @"",
        @"type": type,
    };
}

NSDictionary *SpliceKit_resolveEffectDescriptor(NSString *effectID,
                                                       NSString *name,
                                                       NSString *requiredType) {
    Class ffEffect = objc_getClass("FFEffect");
    if (!ffEffect) return @{@"error": @"FFEffect class not found"};

    if (effectID.length > 0) {
        return SpliceKit_effectDescriptorForID(ffEffect, effectID, requiredType);
    }
    if (name.length == 0) {
        return @{@"error": @"effectID or name parameter required"};
    }

    id allIDs = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect, @selector(userVisibleEffectIDs));
    if (!allIDs) return @{@"error": @"No effect IDs returned"};

    SEL typeSel = @selector(effectTypeForEffectID:);
    SEL nameSel = @selector(displayNameForEffectID:);
    NSString *lowerName = [name lowercaseString];
    NSString *normalizedName = SpliceKit_normalizedEffectName(name);

    NSString *fallbackContains = nil;
    for (NSString *eid in allIDs) {
        id typeObj = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, eid);
        NSString *type = [typeObj isKindOfClass:[NSString class]] ? typeObj : @"";
        if (requiredType.length > 0 && ![type isEqualToString:requiredType]) continue;

        id displayObj = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
        if (![displayObj isKindOfClass:[NSString class]]) continue;
        NSString *display = displayObj;
        if ([[display lowercaseString] isEqualToString:lowerName] ||
            [SpliceKit_normalizedEffectName(display) isEqualToString:normalizedName]) {
            return SpliceKit_effectDescriptorForID(ffEffect, eid, requiredType);
        }
        if (!fallbackContains && [[display lowercaseString] containsString:lowerName]) {
            fallbackContains = eid;
        }
    }

    if (fallbackContains.length > 0) {
        return SpliceKit_effectDescriptorForID(ffEffect, fallbackContains, requiredType);
    }

    return @{@"error": [NSString stringWithFormat:@"No effect found matching '%@'", name]};
}

NSDictionary *SpliceKit_handleEffectsApply(NSDictionary *params) {
    NSString *effectID = params[@"effectID"];
    NSString *name = params[@"name"];

    if (!effectID && !name) {
        return @{@"error": @"effectID or name parameter required"};
    }

    __block NSDictionary *result = nil;
    __block NSString *resolvedID = effectID;

    SpliceKit_executeOnMainThread(^{
        @try {
            Class ffEffect = objc_getClass("FFEffect");
            if (!ffEffect) { result = @{@"error": @"FFEffect class not found"}; return; }

            // Resolve name -> effectID if needed
            if (!resolvedID && name) {
                id allIDs = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect, @selector(userVisibleEffectIDs));
                SEL typeSel = @selector(effectTypeForEffectID:);
                SEL nameSel = @selector(displayNameForEffectID:);
                NSString *lowerName = [name lowercaseString];

                // Normalize: strip non-alphanumeric, replace "&" with "and" for fuzzy comparison
                // so "Black and White" matches "Black & White" and vice versa
                NSString *(^normalize)(NSString *) = ^NSString *(NSString *s) {
                    NSString *lower = [[s lowercaseString] stringByReplacingOccurrencesOfString:@"&" withString:@"and"];
                    NSMutableString *out = [NSMutableString stringWithCapacity:lower.length];
                    for (NSUInteger i = 0; i < lower.length; i++) {
                        unichar c = [lower characterAtIndex:i];
                        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
                            [out appendFormat:@"%C", c];
                    }
                    return out;
                };
                NSString *normalizedName = normalize(name);

                // Helper: check if effectID is a built-in FCP effect (not third-party)
                BOOL (^isBuiltIn)(NSString *) = ^BOOL(NSString *eid) {
                    return [eid hasPrefix:@"..."] || [eid hasPrefix:@"/"];
                };

                // Search in three phases: exact, normalized, partial.
                // Always prefer built-in over third-party across ALL phases.
                NSString *thirdPartyFallback = nil;

                // Phase 1: Exact match (case-insensitive)
                for (NSString *eid in allIDs) {
                    id type = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, eid);
                    if ([type isKindOfClass:[NSString class]] &&
                        [(NSString *)type isEqualToString:@"effect.video.transition"]) continue;

                    id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                    if ([dn isKindOfClass:[NSString class]] &&
                        [[(NSString *)dn lowercaseString] isEqualToString:lowerName]) {
                        if (isBuiltIn(eid)) {
                            resolvedID = eid;
                            break;
                        } else if (!thirdPartyFallback) {
                            thirdPartyFallback = eid;
                        }
                    }
                }

                // Phase 2: Normalized match (handles &/and, underscores, punctuation)
                if (!resolvedID) {
                    for (NSString *eid in allIDs) {
                        id type = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, eid);
                        if ([type isKindOfClass:[NSString class]] &&
                            [(NSString *)type isEqualToString:@"effect.video.transition"]) continue;

                        id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                        if ([dn isKindOfClass:[NSString class]] &&
                            [normalize((NSString *)dn) isEqualToString:normalizedName]) {
                            if (isBuiltIn(eid)) {
                                resolvedID = eid;
                                break;
                            } else if (!thirdPartyFallback) {
                                thirdPartyFallback = eid;
                            }
                        }
                    }
                }

                // Phase 3: Partial/substring match
                if (!resolvedID) {
                    for (NSString *eid in allIDs) {
                        id type = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, eid);
                        if ([type isKindOfClass:[NSString class]] &&
                            [(NSString *)type isEqualToString:@"effect.video.transition"]) continue;

                        id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                        if ([dn isKindOfClass:[NSString class]] &&
                            [[(NSString *)dn lowercaseString] containsString:lowerName]) {
                            if (isBuiltIn(eid)) {
                                resolvedID = eid;
                                break;
                            } else if (!thirdPartyFallback) {
                                thirdPartyFallback = eid;
                            }
                        }
                    }
                }

                // Only use third-party if no built-in match was found in any phase
                if (!resolvedID) resolvedID = thirdPartyFallback;
                if (!resolvedID) {
                    result = @{@"error": [NSString stringWithFormat:@"No effect found matching '%@'", name]};
                    return;
                }
            }

            // Use FFAddEffectCommand to apply the effect to selected items
            Class cmdClass = objc_getClass("FFAddEffectCommand");
            Class selMgr = objc_getClass("PESelectionManager");
            if (!cmdClass || !selMgr) {
                result = @{@"error": @"FFAddEffectCommand or PESelectionManager not found"};
                return;
            }

            // Get effect class for selected items lookup
            id effectClass = ((id (*)(id, SEL, id))objc_msgSend)(
                (id)ffEffect, @selector(classForEffectID:), resolvedID);

            // Get selected items from the media browser container module
            // or fall back to timeline selection
            id app = [NSApplication sharedApplication];
            id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));

            // Try to get the browser module to find selected items
            SEL browserSel = NSSelectorFromString(@"mediaBrowserContainerModule");
            id browserModule = nil;
            if ([delegate respondsToSelector:browserSel]) {
                browserModule = ((id (*)(id, SEL))objc_msgSend)(delegate, browserSel);
            }

            // Get selected items appropriate for this effect
            NSArray *items = nil;
            if (browserModule) {
                SEL itemsSel = NSSelectorFromString(@"_newSelectedItemsForAddEffectOperationForEffectClass:");
                if ([browserModule respondsToSelector:itemsSel]) {
                    items = ((id (*)(id, SEL, id))objc_msgSend)(browserModule, itemsSel, effectClass);
                }
            }

            // If no items from browser, try getting selected clips from timeline
            if (!items || [(NSArray *)items count] == 0) {
                id timelineModule = SpliceKit_getActiveTimelineModule();
                if (timelineModule) {
                    SEL selItemsSel = NSSelectorFromString(@"selectedItems");
                    if ([timelineModule respondsToSelector:selItemsSel]) {
                        items = ((id (*)(id, SEL))objc_msgSend)(timelineModule, selItemsSel);
                    }
                }
            }

            if (!items || [(NSArray *)items count] == 0) {
                result = @{@"error": @"No clips selected. Select a clip first with timeline_action('selectClipAtPlayhead')"};
                return;
            }

            // Create and execute FFAddEffectCommand
            id cmd = ((id (*)(id, SEL))objc_msgSend)((id)cmdClass, @selector(alloc));
            SEL initSel = NSSelectorFromString(@"initWithEffectID:items:");
            cmd = ((id (*)(id, SEL, id, id))objc_msgSend)(cmd, initSel, resolvedID, items);

            // Set timeline context
            id mgr = ((id (*)(id, SEL))objc_msgSend)((id)selMgr, @selector(defaultSelectionManager));
            if (mgr) {
                id ctx = ((id (*)(id, SEL))objc_msgSend)(mgr, @selector(timelineContext));
                if (ctx) {
                    ((void (*)(id, SEL, id))objc_msgSend)(cmd, @selector(setContext:), ctx);
                }
            }

            BOOL success = ((BOOL (*)(id, SEL))objc_msgSend)(cmd, @selector(execute));

            id appliedName = ((id (*)(id, SEL, id))objc_msgSend)(
                (id)ffEffect, @selector(displayNameForEffectID:), resolvedID);

            if (success) {
                result = @{
                    @"status": @"ok",
                    @"effect": [appliedName isKindOfClass:[NSString class]] ? appliedName : @"Unknown",
                    @"effectID": resolvedID,
                };
            } else {
                result = @{@"error": [NSString stringWithFormat:@"Failed to apply effect '%@'",
                           [appliedName isKindOfClass:[NSString class]] ? appliedName : resolvedID]};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result ?: @{@"error": @"Failed to apply effect"};
}

#pragma mark - Title/Generator Insert (via Pasteboard)

NSDictionary *SpliceKit_handleTitleInsert(NSDictionary *params) {
    NSString *effectID = params[@"effectID"];
    NSString *name = params[@"name"];

    if (!effectID && !name) {
        return @{@"error": @"effectID or name parameter required"};
    }

    __block NSDictionary *result = nil;
    __block NSString *resolvedID = effectID;

    SpliceKit_executeOnMainThread(^{
        @try {
            Class ffEffect = objc_getClass("FFEffect");
            if (!ffEffect) { result = @{@"error": @"FFEffect class not found"}; return; }

            // Resolve name -> effectID if needed
            if (!resolvedID && name) {
                id allIDs = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect, @selector(userVisibleEffectIDs));
                SEL nameSel = @selector(displayNameForEffectID:);
                NSString *lowerName = [name lowercaseString];

                // Normalize: strip non-alphanumeric chars for fuzzy comparison
                NSString *(^normalize)(NSString *) = ^NSString *(NSString *s) {
                    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
                    NSString *lower = [s lowercaseString];
                    for (NSUInteger i = 0; i < lower.length; i++) {
                        unichar c = [lower characterAtIndex:i];
                        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
                            [out appendFormat:@"%C", c];
                    }
                    return out;
                };
                NSString *normalizedName = normalize(name);

                // Exact match first
                for (NSString *eid in allIDs) {
                    id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                    if ([dn isKindOfClass:[NSString class]] &&
                        [[(NSString *)dn lowercaseString] isEqualToString:lowerName]) {
                        resolvedID = eid;
                        break;
                    }
                }
                // Normalized match
                if (!resolvedID) {
                    for (NSString *eid in allIDs) {
                        id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                        if ([dn isKindOfClass:[NSString class]] &&
                            [normalize((NSString *)dn) isEqualToString:normalizedName]) {
                            resolvedID = eid;
                            break;
                        }
                    }
                }
                // Partial match fallback
                if (!resolvedID) {
                    for (NSString *eid in allIDs) {
                        id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                        if ([dn isKindOfClass:[NSString class]] &&
                            [[(NSString *)dn lowercaseString] containsString:lowerName]) {
                            resolvedID = eid;
                            break;
                        }
                    }
                }
                if (!resolvedID) {
                    result = @{@"error": [NSString stringWithFormat:@"No title/generator found matching '%@'", name]};
                    return;
                }
            }

            // Use FCP's own pasteboard mechanism to insert titles/generators.
            // This is how addBasicTitle: works internally:
            // 1. Write effectID to FFPasteboard
            // 2. Call anchorWithPasteboard: on the timeline module
            Class ffPasteboard = objc_getClass("FFPasteboard");
            if (!ffPasteboard) {
                result = @{@"error": @"FFPasteboard class not found"};
                return;
            }

            // Create pasteboard and write effect ID
            id pb = ((id (*)(id, SEL))objc_msgSend)((id)ffPasteboard, @selector(alloc));
            pb = ((id (*)(id, SEL, id))objc_msgSend)(pb,
                NSSelectorFromString(@"initWithName:"),
                @"com.apple.nle.custompasteboard");

            id nsPb = ((id (*)(id, SEL))objc_msgSend)(pb, NSSelectorFromString(@"pasteboard"));
            ((void (*)(id, SEL))objc_msgSend)(nsPb, @selector(clearContents));

            NSArray *effectIDs = @[resolvedID];
            ((void (*)(id, SEL, id, id))objc_msgSend)(pb,
                NSSelectorFromString(@"writeEffectIDs:project:"),
                effectIDs, nil);

            // Get timeline module and insert via anchor
            id timelineModule = SpliceKit_getActiveTimelineModule();
            if (!timelineModule) {
                result = @{@"error": @"No active timeline module"};
                return;
            }

            // Check if a title is already selected (replace mode) or insert new (anchor mode)
            SEL anchorSel = NSSelectorFromString(@"anchorWithPasteboard:backtimed:trackType:");
            if ([timelineModule respondsToSelector:anchorSel]) {
                ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                    timelineModule, anchorSel,
                    @"com.apple.nle.custompasteboard", NO, @"all");
            } else {
                result = @{@"error": @"Timeline module does not support anchorWithPasteboard:"};
                return;
            }

            id appliedName = ((id (*)(id, SEL, id))objc_msgSend)(
                (id)ffEffect, @selector(displayNameForEffectID:), resolvedID);

            result = @{
                @"status": @"ok",
                @"title": [appliedName isKindOfClass:[NSString class]] ? appliedName : @"Unknown",
                @"effectID": resolvedID,
            };

        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result ?: @{@"error": @"Failed to insert title"};
}
