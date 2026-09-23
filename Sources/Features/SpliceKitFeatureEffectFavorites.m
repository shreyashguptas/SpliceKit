//
//  SpliceKitFeatureEffectFavorites.m
//  SpliceKit - Favorites in the Effects Browser context menu.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Effect Browser Favorites (context menu)

// Swizzle -[FFEffectLibraryItemView menu] to add "Add to Favorites" / "Remove from Favorites"
// This uses FCP's built-in favorites API (FFEffect favoriteEffectIDs:video:filterUnregisteredEffects:)

static IMP sOrigEffectLibraryItemViewMenu = NULL;
static BOOL sEffectFavoritesSwizzleInstalled = NO;

static id SpliceKit_swizzled_effectLibraryItemViewMenu(id self, SEL _cmd) {
    // Call original
    id menu = ((id (*)(id, SEL))sOrigEffectLibraryItemViewMenu)(self, _cmd);

    @try {
        // Get the effect item and its effectID
        id effectItem = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"effectItem"));
        if (!effectItem) return menu;

        id effectID = ((id (*)(id, SEL))objc_msgSend)(effectItem, NSSelectorFromString(@"effectID"));
        if (!effectID) return menu;

        // Create menu if nil (consumer UI returns nil)
        if (!menu) {
            Class menuClass = NSClassFromString(@"LKMenu") ?: [NSMenu class];
            menu = [[menuClass alloc] initWithTitle:@""];
        }

        // Determine effect type (video or audio) for the favorites API
        Class ffEffectClass = NSClassFromString(@"FFEffect");
        if (!ffEffectClass) return menu;

        SEL typeSel = @selector(effectTypeForEffectID:);
        id effectType = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffectClass, typeSel, effectID);

        BOOL isAudio = effectType && [effectType isEqualToString:@"effect.audio.effect"];
        BOOL isVideo = effectType && ([effectType isEqualToString:@"effect.video.filter"] ||
                       [effectType isEqualToString:@"effect.video.transition"] ||
                       [effectType isEqualToString:@"effect.video.title"] ||
                       [effectType isEqualToString:@"effect.video.generator"]);

        if (!isAudio && !isVideo) return menu;

        // Check if already favorited
        NSArray *favorites = ((id (*)(id, SEL, BOOL, BOOL, BOOL))objc_msgSend)(
            (id)ffEffectClass, NSSelectorFromString(@"favoriteEffectIDs:video:filterUnregisteredEffects:"),
            NO, isVideo, NO);
        BOOL isFavorite = [favorites containsObject:effectID];

        // Add separator before our items
        if ([menu numberOfItems] > 0) {
            [menu addItem:[NSMenuItem separatorItem]];
        }

        // Add the favorite/unfavorite menu item
        if (isFavorite) {
            NSString *title = isAudio ? @"Remove from Audio Favorites" : @"Remove from Favorites";
            SEL action = isAudio
                ? NSSelectorFromString(@"removeFavoriteAudioEffect:")
                : NSSelectorFromString(@"removeFavoriteVideoEffect:");
            [menu addItemWithTitle:title action:action keyEquivalent:@""];
        } else {
            NSString *title = isAudio ? @"Add to Audio Favorites" : @"Add to Favorites";
            SEL action = isAudio
                ? NSSelectorFromString(@"addFavoriteAudioEffect:")
                : NSSelectorFromString(@"addFavoriteVideoEffect:");
            [menu addItemWithTitle:title action:action keyEquivalent:@""];
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Favorites] Exception in menu swizzle: %@", e.reason);
    }

    return menu;
}

void SpliceKit_installEffectFavoritesSwizzle(void) {
    if (sEffectFavoritesSwizzleInstalled) return;

    SpliceKit_executeOnMainThread(^{
        if (sEffectFavoritesSwizzleInstalled) return;

        // Try multiple class name variants — FCP may use different names across versions
        const char *classNames[] = {
            "FFEffectLibraryItemView",
            "Flexo.FFEffectLibraryItemView",
            "_TtC5Flexo25FFEffectLibraryItemView",
            NULL
        };

        Class cls = Nil;
        for (int i = 0; classNames[i] != NULL; i++) {
            cls = objc_getClass(classNames[i]);
            if (cls) break;
        }

        // Brute-force search through all loaded classes
        if (!cls) {
            unsigned int classCount = 0;
            Class *allClasses = objc_copyClassList(&classCount);
            if (allClasses) {
                for (unsigned int i = 0; i < classCount; i++) {
                    const char *name = class_getName(allClasses[i]);
                    if (name && strstr(name, "EffectLibraryItemView")) {
                        SpliceKit_log(@"[Favorites] Found candidate class: %s", name);
                        cls = allClasses[i];
                        break;
                    }
                }
                free(allClasses);
            }
        }

        if (!cls) {
            static int retryCount = 0;
            if (retryCount < 15) {
                retryCount++;
                if (retryCount <= 2) {
                    SpliceKit_log(@"[Favorites] EffectLibraryItemView not found, retrying... (%d)", retryCount);
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        SpliceKit_installEffectFavoritesSwizzle();
                    });
            } else {
                SpliceKit_log(@"[Favorites] EffectLibraryItemView never loaded after %d attempts", retryCount);
            }
            return;
        }

        SEL menuSel = @selector(menu);
        Method menuMethod = class_getInstanceMethod(cls, menuSel);
        if (!menuMethod) {
            SpliceKit_log(@"[Favorites] -[%s menu] not found", class_getName(cls));
            return;
        }

        sOrigEffectLibraryItemViewMenu = method_setImplementation(
            menuMethod, (IMP)SpliceKit_swizzled_effectLibraryItemViewMenu);
        sEffectFavoritesSwizzleInstalled = YES;
        SpliceKit_log(@"[Favorites] Swizzled -[%s menu] for favorites context menu", class_getName(cls));

        // Swizzle add/remove favorite methods to refresh the view after changes
        NSArray *favSelNames = @[
            @"addFavoriteVideoEffect:",
            @"removeFavoriteVideoEffect:",
            @"addFavoriteAudioEffect:",
            @"removeFavoriteAudioEffect:",
        ];
        for (NSString *selName in favSelNames) {
            SEL favSel = NSSelectorFromString(selName);
            Method favMethod = class_getInstanceMethod(cls, favSel);
            if (!favMethod) continue;
            IMP origFav = method_getImplementation(favMethod);
            method_setImplementation(favMethod,
                imp_implementationWithBlock(^(id self_, id sender) {
                    // Call original
                    ((void (*)(id, SEL, id))origFav)(self_, favSel, sender);

                    // Refresh: rebuild arrangedItems from fresh favorites, then updateFilter
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
                        @try {
                            // Get this effect's type
                            id effectItem = ((id (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"effectItem"));
                            if (!effectItem) return;
                            id effID = ((id (*)(id, SEL))objc_msgSend)(effectItem, NSSelectorFromString(@"effectID"));
                            if (!effID) return;
                            Class ffEffect = NSClassFromString(@"FFEffect");
                            id effType = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, @selector(effectTypeForEffectID:), effID);

                            // Walk up to find collection view -> module
                            NSView *v = self_;
                            while (v) {
                                if ([NSStringFromClass([v class]) containsString:@"EffectLibraryCollectionView"]) {
                                    SEL tSel = NSSelectorFromString(@"targetModules");
                                    if (![v respondsToSelector:tSel]) break;
                                    for (id mod in ((id (*)(id, SEL))objc_msgSend)(v, tSel)) {
                                        if (![mod respondsToSelector:NSSelectorFromString(@"updateFilter")]) continue;

                                        // Rebuild arrangedItems with fresh favorites for this type
                                        if (effType && ffEffect) {
                                            BOOL isVideo = ![effType isEqualToString:@"effect.audio.effect"];
                                            NSArray *favIDs = ((id (*)(id, SEL, BOOL, BOOL, BOOL))objc_msgSend)(
                                                (id)ffEffect, NSSelectorFromString(@"favoriteEffectIDs:video:filterUnregisteredEffects:"),
                                                NO, isVideo, YES);
                                            Class itemClass = NSClassFromString(@"FFBKEffectLibraryItem");
                                            if (itemClass) {
                                                NSMutableArray *fresh = [NSMutableArray array];
                                                for (id fid in favIDs) {
                                                    id ft = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, @selector(effectTypeForEffectID:), fid);
                                                    if (!ft || ![ft isEqualToString:effType]) continue;
                                                    id item = ((id (*)(id, SEL, id))objc_msgSend)(
                                                        ((id (*)(id, SEL))objc_msgSend)((id)itemClass, @selector(alloc)),
                                                        NSSelectorFromString(@"initWithEffectID:"), fid);
                                                    if (item) [fresh addObject:item];
                                                }
                                                ((void (*)(id, SEL, id))objc_msgSend)(mod, NSSelectorFromString(@"setArrangedItems:"), fresh);
                                            }
                                        }

                                        ((void (*)(id, SEL))objc_msgSend)(mod, NSSelectorFromString(@"updateFilter"));
                                        break;
                                    }
                                    break;
                                }
                                v = [v superview];
                            }
                        } @catch (NSException *e) {
                            SpliceKit_log(@"[Favorites] Refresh exception: %@", e.reason);
                        }
                    });
                }));
        }
        SpliceKit_log(@"[Favorites] Swizzled add/remove favorite methods for auto-refresh");

        // Also swizzle masterSubitems to inject "Favorites" category in sidebar
        Class folderClass = objc_getClass("FFBKEffectLibraryFolder");
        if (!folderClass) folderClass = SpliceKit_findLoadedClassNamed("FFBKEffectLibraryFolder");
        if (folderClass) {
            // Create a runtime subclass for the Favorites folder
            Class favFolderClass = objc_allocateClassPair(folderClass, "SpliceKitFavoritesFolder", 0);
            if (favFolderClass) {
                // Override -items to return favorited effects
                IMP itemsImp = imp_implementationWithBlock(^id(id self_) {
                    @try {
                        Class ffEffect = NSClassFromString(@"FFEffect");
                        Class itemClass = NSClassFromString(@"FFBKEffectLibraryItem");
                        if (!ffEffect || !itemClass) {
                            SpliceKit_log(@"[Favorites] items: missing classes");
                            return @[];
                        }

                        // Get effect type from this folder
                        id effType = ((id (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"effectType"));
                        BOOL isVideo = !(effType && [effType isEqualToString:@"effect.audio.effect"]);

                        NSArray *favIDs = ((id (*)(id, SEL, BOOL, BOOL, BOOL))objc_msgSend)(
                            (id)ffEffect, NSSelectorFromString(@"favoriteEffectIDs:video:filterUnregisteredEffects:"),
                            NO, isVideo, YES);

                        // Filter to only favorites matching this tab's effect type
                        SEL typeSel = @selector(effectTypeForEffectID:);
                        NSMutableArray *items = [NSMutableArray array];
                        for (id effectID in favIDs) {
                            id thisType = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, effectID);
                            if (!thisType || ![thisType isEqualToString:effType]) continue;

                            id item = ((id (*)(id, SEL))objc_msgSend)((id)itemClass, @selector(alloc));
                            item = ((id (*)(id, SEL, id))objc_msgSend)(item, NSSelectorFromString(@"initWithEffectID:"), effectID);
                            if (item) {
                                [items addObject:item];
                            }
                        }
                        return items;
                    } @catch (NSException *e) {
                        SpliceKit_log(@"[Favorites] Exception in favorites items: %@", e.reason);
                        return @[];
                    }
                });
                class_addMethod(favFolderClass, NSSelectorFromString(@"items"),
                    itemsImp, "@@:");

                // Override -detailSubitems to return same as items (used by syncToEffectFolder:)
                IMP detailImp = imp_implementationWithBlock(^id(id self_) {
                    return ((id (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"items"));
                });
                class_addMethod(favFolderClass, NSSelectorFromString(@"detailSubitems"),
                    detailImp, "@@:");

                // Override -itemDisplayName to return "★ Favorites"
                IMP nameImp = imp_implementationWithBlock(^id(id self_) {
                    return @"\u2605 Favorites";
                });
                class_addMethod(favFolderClass, NSSelectorFromString(@"itemDisplayName"),
                    nameImp, "@@:");

                // Override -drawAsTopLevel to return NO (shows as regular sidebar row)
                IMP topLevelImp = imp_implementationWithBlock(^BOOL(id self_) {
                    return NO;
                });
                class_addMethod(favFolderClass, NSSelectorFromString(@"drawAsTopLevel"),
                    topLevelImp, "B@:");

                // Override -hasMasterSubitems to return NO
                IMP noSubImp = imp_implementationWithBlock(^BOOL(id self_) {
                    return NO;
                });
                class_addMethod(favFolderClass, NSSelectorFromString(@"hasMasterSubitems"),
                    noSubImp, "B@:");

                objc_registerClassPair(favFolderClass);
                SpliceKit_log(@"[Favorites] Created SpliceKitFavoritesFolder runtime class");
            }

            // Swizzle masterSubitems to inject favorites folder at position 0
            SEL masterSel = NSSelectorFromString(@"masterSubitems");
            Method masterMethod = class_getInstanceMethod(folderClass, masterSel);
            if (masterMethod) {
                static IMP sOrigMasterSubitems = NULL;
                sOrigMasterSubitems = method_setImplementation(masterMethod,
                    imp_implementationWithBlock(^id(id self_) {
                        NSMutableArray *result = [((id (*)(id, SEL))sOrigMasterSubitems)(self_, masterSel) mutableCopy];

                        @try {
                            // Only inject at the top-level (not in subcategory folders)
                            id effType = ((id (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"effectType"));
                            BOOL isSubAll = ((BOOL (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"isSubcategoryAll"));
                            BOOL isSubNew = ((BOOL (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"isSubcategoryNew"));
                            id genre = ((id (*)(id, SEL))objc_msgSend)(self_, NSSelectorFromString(@"genre"));

                            if (isSubAll || isSubNew || genre) return result;

                            // Check if there are any favorites for this specific effect type
                            Class ffEffect = NSClassFromString(@"FFEffect");
                            BOOL isVideo = !(effType && [effType isEqualToString:@"effect.audio.effect"]);
                            NSArray *favIDs = ((id (*)(id, SEL, BOOL, BOOL, BOOL))objc_msgSend)(
                                (id)ffEffect, NSSelectorFromString(@"favoriteEffectIDs:video:filterUnregisteredEffects:"),
                                NO, isVideo, YES);

                            // Filter to only favorites matching this tab's type
                            SEL typeSel = @selector(effectTypeForEffectID:);
                            NSUInteger matchCount = 0;
                            for (id fid in favIDs) {
                                id ft = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, fid);
                                if (ft && [ft isEqualToString:effType]) matchCount++;
                            }

                            if (matchCount > 0) {
                                Class favClass = objc_getClass("SpliceKitFavoritesFolder");
                                if (favClass) {
                                    id favFolder = ((id (*)(id, SEL))objc_msgSend)((id)favClass, @selector(alloc));
                                    favFolder = ((id (*)(id, SEL, id, id, BOOL, BOOL))objc_msgSend)(
                                        favFolder,
                                        NSSelectorFromString(@"initWithEffectType:genre:isSubcategoryAll:isSubcategoryNew:"),
                                        effType, nil, YES, NO);
                                    if (favFolder) {
                                        [result insertObject:favFolder atIndex:0];
                                    }
                                }
                            }
                        } @catch (NSException *e) {
                            SpliceKit_log(@"[Favorites] Exception injecting favorites folder: %@", e.reason);
                        }

                        return result;
                    }));
                SpliceKit_log(@"[Favorites] Swizzled -[FFBKEffectLibraryFolder masterSubitems] for sidebar");
            }
        }
    });
}
