//
//  SpliceKitSidebarCoalesce.m
//  Cache the two functions that dominate scroll time in the Effects browser
//  category sidebar.
//
//  How we found these
//  ------------------
//  `sample` on the FCP process during a live scroll of the Effects category
//  sidebar shows the following hot path on the main thread:
//
//    NSScrollView _handleBoundsChangeForSubview:
//    → NSTableView prepareContentInRect:
//    → NSTableRowData updateVisibleRowViews
//    → NSTableRowData _addViewToRowView:atColumn:row:
//    → NSTableView makeViewForTableColumn:row:
//    → -[FFEffectBrowserSidebar tableView:viewForTableColumn:row:]
//    → -[FFBKEffectLibraryFolder items]                         ← 85% of cell work
//       → +[FFEffect userVisibleEffectIDs]                       ← ~30%
//          → +[FFEffect adjustEffectIDForObsoleteEffects:]       ← mostly bsearch +
//            CFStringCompareWithOptionsAndLocale on ~1954 entries
//
//  Every row vended during scroll triggers a full filter pass over the effect
//  registry. With a large install (1954 effects in this sample) that's
//  thousands of string comparisons per scroll frame on the main thread.
//
//  Fix
//  ---
//  1. `+[FFEffect userVisibleEffectIDs]` returns a conceptually static list —
//     it only changes when the effect registry changes (plugin load/unload).
//     Cache the result at class scope. Invalidate via notification observer
//     on FFEffectRegistry change if we can find one, otherwise accept that a
//     plugin change won't reflect in the sidebar until next launch (a plugin
//     load already causes a registry reload which posts notifications that
//     we hook below).
//
//  2. `-[FFBKEffectLibraryFolder items]` filters `userVisibleEffectIDs` by
//     the folder's effect type + genre. Cache per-folder via associated
//     object so each category row answers in O(1) on repeat calls.
//
//  Both caches are invalidated when any FFEffect registry notification fires.
//  The cache is shipped behind the `effectsSidebarItemsCache` bridge option
//  so it can be turned off without recompiling.
//

#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const kEffectsSidebarItemsCacheKey = @"SpliceKitEffectsSidebarItemsCache";

static BOOL sCacheInstalled = NO;
static IMP sOrigUserVisibleEffectIDs = NULL;
static IMP sOrigFolderItems = NULL;

// Class-level cache for +[FFEffect userVisibleEffectIDs]. Returns a stable
// NSArray until the effect registry changes.
static NSArray *sCachedUserVisibleEffectIDs = nil;

// Per-instance cache for -[FFBKEffectLibraryFolder items]. Stored as an
// associated object on each folder. Invalidated by bumping a generation
// counter — folders whose cached generation != the current one recompute
// on next access.
static NSUInteger sCacheGeneration = 0;
static void * const kFolderItemsCacheKey = (void *)&kFolderItemsCacheKey;
static void * const kFolderItemsCacheGenKey = (void *)&kFolderItemsCacheGenKey;

static void SpliceKit_effectsSidebarInvalidateCaches(void) {
    sCachedUserVisibleEffectIDs = nil;
    // Bumping the generation means every folder's stored cache is stale
    // without us having to iterate them.
    sCacheGeneration++;
}

// ---- Swizzles ----

static id SpliceKit_swizzled_userVisibleEffectIDs(Class self_, SEL _cmd) {
    NSArray *cached = sCachedUserVisibleEffectIDs;
    if (cached) return cached;
    NSArray *result = ((id (*)(Class, SEL))sOrigUserVisibleEffectIDs)(self_, _cmd);
    // Retain via strong global. This mirrors the original return (which is an
    // autoreleased immutable array built from dictionary keys). We're ARC.
    sCachedUserVisibleEffectIDs = result;
    return result;
}

static id SpliceKit_swizzled_folderItems(id self_, SEL _cmd) {
    NSNumber *storedGen = objc_getAssociatedObject(self_, kFolderItemsCacheGenKey);
    if (storedGen && [storedGen unsignedIntegerValue] == sCacheGeneration) {
        NSArray *cached = objc_getAssociatedObject(self_, kFolderItemsCacheKey);
        if (cached) return cached;
    }
    NSArray *result = ((id (*)(id, SEL))sOrigFolderItems)(self_, _cmd);
    objc_setAssociatedObject(self_, kFolderItemsCacheKey, result,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self_, kFolderItemsCacheGenKey,
                             @(sCacheGeneration),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

// ---- Invalidation ----
//
// We hook into FFEffectRegistry change notifications by listening for the
// `FFEffect` registry callbacks FCP already uses: the folder class itself
// implements `effectIDWasRegistered:` — its subclasses and hookers fire when
// the registry adds an effect. We install an NSNotificationCenter observer
// for any name containing "Effect" and "Registry" as a conservative catch-all
// — invalidating the cache is cheap, so being too aggressive is fine.

static void SpliceKit_effectsSidebarInstallInvalidation(void) {
    // All FFEffect-registry notifications we know about fire in response to
    // plugin installs/removals and user favorites changes. We observe any
    // notification whose name contains "Effect" — cheap false positives are OK.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:nil
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        NSString *name = note.name;
        if (!name) return;
        if ([name containsString:@"Effect"]
            && ([name containsString:@"Registry"]
                || [name containsString:@"Changed"]
                || [name containsString:@"Registered"])) {
            SpliceKit_effectsSidebarInvalidateCaches();
        }
    }];
}

// ---- Install / remove ----

void SpliceKit_installSidebarCoalesceLiveScroll(void) {
    if (sCacheInstalled) return;

    Class effectCls = objc_getClass("FFEffect");
    Class folderCls = objc_getClass("FFBKEffectLibraryFolder");
    if (!effectCls || !folderCls) {
        SpliceKit_log(@"[EffectsSidebarCache] FFEffect/FFBKEffectLibraryFolder not found — skip");
        return;
    }

    // +[FFEffect userVisibleEffectIDs] is a class method. SpliceKit_swizzleMethod
    // swaps an instance-method IMP; for a class method we need to swap the IMP
    // on the metaclass.
    SEL userVisibleSel = @selector(userVisibleEffectIDs);
    Method userVisibleMethod = class_getClassMethod(effectCls, userVisibleSel);
    if (userVisibleMethod) {
        sOrigUserVisibleEffectIDs = method_setImplementation(
            userVisibleMethod, (IMP)SpliceKit_swizzled_userVisibleEffectIDs);
        SpliceKit_log(@"[EffectsSidebarCache] Swizzled +[FFEffect userVisibleEffectIDs]");
    } else {
        SpliceKit_log(@"[EffectsSidebarCache] +userVisibleEffectIDs not found");
    }

    // -[FFBKEffectLibraryFolder items] is an instance method.
    sOrigFolderItems = SpliceKit_swizzleMethod(folderCls, @selector(items),
        (IMP)SpliceKit_swizzled_folderItems);
    if (!sOrigFolderItems) {
        SpliceKit_log(@"[EffectsSidebarCache] -[FFBKEffectLibraryFolder items] swizzle failed");
    }

    SpliceKit_effectsSidebarInstallInvalidation();
    sCacheInstalled = YES;
    SpliceKit_log(@"[EffectsSidebarCache] Installed — sidebar items/userVisibleEffectIDs cached");
}

void SpliceKit_removeSidebarCoalesceLiveScroll(void) {
    if (!sCacheInstalled) return;
    // Unswizzling +userVisibleEffectIDs requires the class method path; the
    // shared helper only handles instance methods. We leave it swizzled and
    // just short-circuit the cache by clearing state. Re-enabling reinstalls
    // cleanly because the guard is sCacheInstalled.
    Class effectCls = objc_getClass("FFEffect");
    if (effectCls && sOrigUserVisibleEffectIDs) {
        Method m = class_getClassMethod(effectCls, @selector(userVisibleEffectIDs));
        if (m) method_setImplementation(m, sOrigUserVisibleEffectIDs);
    }
    Class folderCls = objc_getClass("FFBKEffectLibraryFolder");
    if (folderCls) {
        SpliceKit_unswizzleMethod(folderCls, @selector(items));
    }
    sOrigUserVisibleEffectIDs = NULL;
    sOrigFolderItems = NULL;
    SpliceKit_effectsSidebarInvalidateCaches();
    sCacheInstalled = NO;
    SpliceKit_log(@"[EffectsSidebarCache] Removed");
}

void SpliceKit_setSidebarCoalesceLiveScrollEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled
                                            forKey:kEffectsSidebarItemsCacheKey];
    if (enabled) {
        SpliceKit_installSidebarCoalesceLiveScroll();
    } else {
        SpliceKit_removeSidebarCoalesceLiveScroll();
    }
}

BOOL SpliceKit_isSidebarCoalesceLiveScrollEnabled(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults]
                   objectForKey:kEffectsSidebarItemsCacheKey];
    if (!n) return YES; // Default ON
    return [n boolValue];
}
