//
//  SpliceKitDockedPanels.m
//  The docked panels declared in SpliceKitDockedPanels.h.
//
//  FCP's main window is a tree of LunaKit modules (PEMainWindowModule -> ... ->
//  PEUpperDeckContainer, which holds the Browser, the Viewers and the Inspector). A docked
//  panel is one more module in that container, inserted just before the Inspector; showing
//  and hiding it is the container's own unhideSubmodule: / hideSubmodule:, so FCP lays the
//  row out and the Viewer gives up or takes back the room.
//
//  Background Tasks stays FCP's module (PEBackgroundTaskModule) in its own window module;
//  only its view is shown in the dock. That window module stays hidden, so the module is
//  told it is open (its own -moduleDidUnhide, -isHidden NO) for as long as it is docked.
//

#import "SpliceKitDockedPanels.h"
#import "SpliceKit.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const kUpperDeckID = @"PEUpperDeckContainer";
static NSString * const kInspectorID = @"PEInspectorColorSwapModule";
static NSString * const kBackgroundTasksModuleID = @"PEBackgroundTasks";
static NSString * const kBackgroundTasksDockID = @"SpliceKitBackgroundTasks";

// Our modules by identifier. They live as long as FCP: a hidden one keeps its view.
static NSMutableDictionary<NSString *, id> *sDockModules = nil;
static char kDockMinSizeKey;
static char kDockHostViewKey;

// The view each docked module owns; the panel's own view fills it.
@interface SpliceKitDockedPanelView : NSView
@end

@implementation SpliceKitDockedPanelView
@end

#pragma mark - Module helpers

static id SpliceKit_dockSend(id target, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

// For methods that return nothing: SpliceKit_dockSend would keep whatever is in the
// return register as an object.
static void SpliceKit_dockSendVoid(id target, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL))objc_msgSend)(target, sel);
}

static BOOL SpliceKit_dockSendBool(id target, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, sel);
}

static void SpliceKit_dockSendObject(id target, NSString *selectorName, id argument) {
    SEL sel = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(target, sel, argument);
}

static id SpliceKit_dockSubmodule(id module, NSString *identifier) {
    SEL sel = NSSelectorFromString(@"submoduleWithIdentifier:");
    if (![module respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(module, sel, identifier);
}

// FCP's editing window's root module. Not the second window the dual timeline opens.
static id SpliceKit_dockMainWindowModule(void) {
    Class mainModuleClass = objc_getClass("PEMainWindowModule");
    if (!mainModuleClass) return nil;
    for (NSWindow *window in NSApp.windows) {
        id delegate = window.delegate;
        if ([delegate isKindOfClass:mainModuleClass]) return delegate;
    }
    return nil;
}

static id SpliceKit_dockUpperDeck(void) {
    return SpliceKit_dockSubmodule(SpliceKit_dockMainWindowModule(), kUpperDeckID);
}

// LKViewModule with a minimum size of our choosing, so FCP's layout never squeezes a
// panel to nothing when the Viewer and Inspector want the room.
static Class SpliceKit_dockModuleClass(void) {
    static Class cls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = objc_getClass("LKViewModule");
        SEL minSizeSel = NSSelectorFromString(@"viewMinSize");
        Method minSize = base ? class_getInstanceMethod(base, minSizeSel) : NULL;
        if (!minSize) {
            SpliceKit_log(@"[Dock] LKViewModule -viewMinSize not found; panels open as windows");
            return;
        }
        Class made = objc_allocateClassPair(base, "SpliceKitDockedModule", 0);
        if (!made) {
            cls = objc_getClass("SpliceKitDockedModule");
            return;
        }
        IMP minSizeImp = imp_implementationWithBlock(^NSSize(id module) {
            NSValue *value = objc_getAssociatedObject(module, &kDockMinSizeKey);
            return value ? value.sizeValue : NSMakeSize(300, 200);
        });
        class_addMethod(made, minSizeSel, minSizeImp, method_getTypeEncoding(minSize));
        objc_registerClassPair(made);
        cls = made;
    });
    return cls;
}

#pragma mark - Keeping docked panels out of saved layouts

// A layout without our modules: every array entry whose Identifier is one of ours is
// dropped, at any depth. That covers the module tree ("Submodules") and the top row's
// split view, which lists each pane's size under "items". Returns the same object when
// there is none.
static id SpliceKit_dockLayoutWithoutDockedModules(id layout) {
    if (sDockModules.count == 0) return layout;
    if ([layout isKindOfClass:[NSArray class]]) {
        NSMutableArray *kept = [NSMutableArray arrayWithCapacity:[layout count]];
        BOOL changed = NO;
        for (id entry in layout) {
            id identifier = [entry isKindOfClass:[NSDictionary class]] ? entry[@"Identifier"] : nil;
            if ([identifier isKindOfClass:[NSString class]] && sDockModules[identifier]) {
                changed = YES;
                continue;
            }
            id filtered = SpliceKit_dockLayoutWithoutDockedModules(entry);
            if (filtered != entry) changed = YES;
            [kept addObject:filtered];
        }
        return changed ? kept : layout;
    }
    if (![layout isKindOfClass:[NSDictionary class]]) return layout;

    __block NSMutableDictionary *copy = nil;
    [(NSDictionary *)layout enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        id filtered = SpliceKit_dockLayoutWithoutDockedModules(value);
        if (filtered == value) return;
        if (!copy) copy = [layout mutableCopy];
        copy[key] = filtered;
    }];
    return copy ?: layout;
}

// FCP saves the window layout (the quit-time workspace, Window > Workspaces > Save) from
// -layoutDictionary, which LKViewModule and LKContainerModule each implement.
static void SpliceKit_dockFilterLayoutsOf(NSString *className) {
    Class cls = objc_getClass(className.UTF8String);
    SEL sel = NSSelectorFromString(@"layoutDictionary");
    if (!cls) return;

    // Only the class's own implementation: wrapping an inherited one would wrap it twice.
    BOOL own = NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { own = YES; break; }
    }
    free(methods);
    if (!own) return;

    __block IMP original = NULL;
    IMP wrapper = imp_implementationWithBlock(^id(id module) {
        id layout = original ? ((id (*)(id, SEL))original)(module, sel) : nil;
        return SpliceKit_dockLayoutWithoutDockedModules(layout);
    });
    original = SpliceKit_swizzleMethod(cls, sel, wrapper);
    if (!original) SpliceKit_log(@"[Dock] Could not filter %@ -layoutDictionary", className);
}

static void SpliceKit_dockInstallLayoutFilter(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SpliceKit_dockFilterLayoutsOf(@"LKViewModule");
        SpliceKit_dockFilterLayoutsOf(@"LKContainerModule");
    });
}

#pragma mark - Showing and hiding

static NSUInteger SpliceKit_dockInsertIndex(id deck) {
    NSArray *submodules = SpliceKit_dockSend(deck, @"submodules");
    if (![submodules isKindOfClass:[NSArray class]]) return 0;
    for (NSUInteger i = 0; i < submodules.count; i++) {
        id identifier = SpliceKit_dockSend(submodules[i], @"identifier");
        if ([identifier isKindOfClass:[NSString class]] && [identifier isEqualToString:kInspectorID]) return i;
    }
    return submodules.count;
}

BOOL SpliceKit_dockShowView(NSString *identifier, NSString *label, NSView *view, NSSize minSize) {
    if (identifier.length == 0 || !view) return NO;
    id deck = SpliceKit_dockUpperDeck();
    Class moduleClass = SpliceKit_dockModuleClass();
    if (!deck || !moduleClass) return NO;

    @try {
        if (!sDockModules) sDockModules = [NSMutableDictionary dictionary];
        id module = sDockModules[identifier];
        if (!module) {
            SpliceKit_dockInstallLayoutFilter();
            module = [[moduleClass alloc] init];
            SpliceKit_dockSendObject(module, @"setIdentifier:", identifier);
            SpliceKit_dockSendObject(module, @"setLabel:", label ?: identifier);
            NSView *host = [[SpliceKitDockedPanelView alloc] initWithFrame:NSMakeRect(0, 0, minSize.width, minSize.height)];
            host.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
            objc_setAssociatedObject(module, &kDockHostViewKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            SpliceKit_dockSendObject(module, @"setView:", host);
            sDockModules[identifier] = module;
        }
        objc_setAssociatedObject(module, &kDockMinSizeKey, [NSValue valueWithSize:minSize],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        NSView *host = objc_getAssociatedObject(module, &kDockHostViewKey);
        if (view.superview != host) {
            [view removeFromSuperview];
            view.translatesAutoresizingMaskIntoConstraints = YES;
            view.frame = host.bounds;
            view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [host addSubview:view];
        }

        // A workspace switch can rebuild the top row without our module: put it back.
        id supermodule = SpliceKit_dockSend(module, @"supermodule");
        if (supermodule != deck) {
            if (supermodule) SpliceKit_dockSendVoid(module, @"removeFromSupermodule");
            SEL insertSel = NSSelectorFromString(@"insertSubmodule:atIndex:");
            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(deck, insertSel, module,
                                                               SpliceKit_dockInsertIndex(deck));
        }
        if (SpliceKit_dockSendBool(module, @"isHidden")) {
            SpliceKit_dockSendObject(deck, @"unhideSubmodule:", module);
        }
        return host.window != nil;
    } @catch (NSException *e) {
        SpliceKit_log(@"[Dock] Could not dock %@: %@", identifier, e.reason);
        return NO;
    }
}

void SpliceKit_dockHide(NSString *identifier) {
    id module = identifier ? sDockModules[identifier] : nil;
    id supermodule = SpliceKit_dockSend(module, @"supermodule");
    if (!supermodule || SpliceKit_dockSendBool(module, @"isHidden")) return;
    @try {
        SpliceKit_dockSendObject(supermodule, @"hideSubmodule:", module);
    } @catch (NSException *e) {
        SpliceKit_log(@"[Dock] Could not hide %@: %@", identifier, e.reason);
    }
}

BOOL SpliceKit_dockIsShown(NSString *identifier) {
    id module = identifier ? sDockModules[identifier] : nil;
    if (!module || !SpliceKit_dockSend(module, @"supermodule")) return NO;
    if (SpliceKit_dockSendBool(module, @"isHidden")) return NO;
    NSView *host = objc_getAssociatedObject(module, &kDockHostViewKey);
    return host.window.isVisible && !host.isHiddenOrHasHiddenAncestor;
}

#pragma mark - Background Tasks

static __weak id sBackgroundTaskModule = nil;

// FCP's Background Tasks module, which lives in the floating "Background Tasks" window.
static id SpliceKit_dockBackgroundTaskModule(void) {
    id module = sBackgroundTaskModule;
    if (module) return module;
    for (NSWindow *window in NSApp.windows) {
        module = SpliceKit_dockSubmodule(window.delegate, kBackgroundTasksModuleID);
        if (module) {
            sBackgroundTaskModule = module;
            return module;
        }
    }
    return nil;
}

BOOL SpliceKit_dockBackgroundTasksIsShown(void) {
    return SpliceKit_dockIsShown(kBackgroundTasksDockID);
}

// YES while the module is open in the dock. Its own window module stays hidden, and FCP's
// module drops every new task while it is hidden (-backgroundTaskQueue:didAddTask: asks
// -isHidden), so this answers -isHidden for it.
static BOOL sBackgroundTasksLive = NO;

// FCP's own open and close steps for the module, minus the window. -moduleDidUnhide
// subscribes it to task progress, loads the running tasks and shows their rows;
// -moduleDidHide undoes that. -moduleDidUnhide also restyles the view's window as a HUD,
// which throws in the main window, so it runs while the view is in no window.
static void SpliceKit_dockSetBackgroundTasksLive(id module, BOOL live) {
    if (sBackgroundTasksLive == live) return;
    sBackgroundTasksLive = live;
    @try {
        SpliceKit_dockSendVoid(module, live ? @"moduleDidUnhide" : @"moduleDidHide");
    } @catch (NSException *e) {
        SpliceKit_log(@"[Dock] Background Tasks %@: %@", live ? @"open" : @"close", e.reason);
    }
}

BOOL SpliceKit_dockToggleBackgroundTasks(void) {
    id module = SpliceKit_dockBackgroundTaskModule();
    if (SpliceKit_dockIsShown(kBackgroundTasksDockID)) {
        SpliceKit_dockHide(kBackgroundTasksDockID);
        SpliceKit_dockSetBackgroundTasksLive(module, NO);
        return YES;
    }
    NSView *view = SpliceKit_dockSend(module, @"view");
    if (![view isKindOfClass:[NSView class]] || !SpliceKit_dockUpperDeck()) return NO;

    // Its own window would be left empty: keep it closed.
    NSWindow *home = view.window;
    if (home && ![home.delegate isKindOfClass:objc_getClass("PEMainWindowModule")]) [home orderOut:nil];
    [view removeFromSuperview];
    SpliceKit_dockSetBackgroundTasksLive(module, YES);
    if (SpliceKit_dockShowView(kBackgroundTasksDockID, @"Background Tasks", view, NSMakeSize(300, 160))) {
        return YES;
    }
    SpliceKit_dockSetBackgroundTasksLive(module, NO);
    return NO;
}

// -isHidden for FCP's Background Tasks module: shown while it is open in the dock.
static void SpliceKit_dockInstallBackgroundTasksVisibility(void) {
    Class cls = objc_getClass("PEBackgroundTaskModule");
    SEL sel = NSSelectorFromString(@"isHidden");
    Method inherited = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!inherited) {
        SpliceKit_log(@"[Dock] -[PEBackgroundTaskModule isHidden] not found; docked rows may not update");
        return;
    }
    IMP original = method_getImplementation(inherited);
    IMP replacement = imp_implementationWithBlock(^BOOL(id module) {
        if (sBackgroundTasksLive && module == sBackgroundTaskModule) return NO;
        return ((BOOL (*)(id, SEL))original)(module, sel);
    });
    // Its own method when it inherits one, so LunaKit's other modules keep theirs.
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(inherited))) {
        SpliceKit_swizzleMethod(cls, sel, replacement);
    }
}

// Every way FCP opens Background Tasks: Window > Background Tasks (⌘9) goes to the app
// controller, the toolbar's progress dial to the main window module. Each opens it docked,
// and falls back to FCP's own window when it cannot be docked.
static void SpliceKit_dockRouteBackgroundTasks(NSString *className, NSString *selectorName) {
    Class cls = objc_getClass(className.UTF8String);
    SEL sel = NSSelectorFromString(selectorName);
    if (!cls || !class_getInstanceMethod(cls, sel)) {
        SpliceKit_log(@"[Dock] -[%@ %@] not found; Background Tasks keeps its window", className, selectorName);
        return;
    }
    __block IMP original = NULL;
    IMP wrapper = imp_implementationWithBlock(^(id target, id sender) {
        if (SpliceKit_dockToggleBackgroundTasks()) return;
        if (original) ((void (*)(id, SEL, id))original)(target, sel, sender);
    });
    original = SpliceKit_swizzleMethod(cls, sel, wrapper);
}

void SpliceKit_installDockedBackgroundTasks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SpliceKit_dockRouteBackgroundTasks(@"PEAppController", @"goToBackgroundTaskList:");
        SpliceKit_dockRouteBackgroundTasks(@"PEAppController", @"toggleBackgroundTasksList:");
        SpliceKit_dockRouteBackgroundTasks(@"PEMainWindowModule", @"toggleBackgroundTasksList:");
        SpliceKit_dockInstallBackgroundTasksVisibility();
        SpliceKit_log(@"[Dock] Background Tasks opens in the main window");
    });
}
