//
//  SpliceKitWindows.m
//  The shared tool-window behaviour declared in SpliceKitWindows.h.
//

#import "SpliceKitWindows.h"

// Every adopted window, held weakly: a window that goes away drops out on its own.
static NSHashTable<NSPanel *> *sToolWindows = nil;

// Floats the adopted windows above FCP's own while FCP is active, and drops them to the
// normal level when another app comes forward. WillResignActive runs while FCP is still
// frontmost, so a window lands just above FCP's windows and the next app covers it.
static void SpliceKit_setToolWindowsFloating(BOOL floating) {
    for (NSPanel *panel in sToolWindows.allObjects) {
        // floatingPanel sets the level: NSFloatingWindowLevel or NSNormalWindowLevel.
        panel.floatingPanel = floating;
    }
}

static void SpliceKit_installActivationObservers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sToolWindows = [NSHashTable weakObjectsHashTable];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:NSApplicationWillResignActiveNotification object:nil
                             queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            SpliceKit_setToolWindowsFloating(NO);
        }];
        [center addObserverForName:NSApplicationDidBecomeActiveNotification object:nil
                             queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            SpliceKit_setToolWindowsFloating(YES);
        }];
    });
}

void SpliceKit_adoptToolWindow(NSPanel *panel) {
    if (!panel) return;
    SpliceKit_installActivationObservers();
    [sToolWindows addObject:panel];

    // Stays on screen when another app is in front, behind that app's windows.
    panel.hidesOnDeactivate = NO;
    panel.floatingPanel = NSApp.isActive;
    // Comes to the Space the user is on when it is shown, instead of staying on the one
    // it was first opened on, and may join FCP's Space when FCP is full screen.
    panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
                               NSWindowCollectionBehaviorFullScreenAuxiliary;
}

NSWindow *SpliceKit_fcpHostWindow(NSWindow *exclude) {
    NSWindow *main = NSApp.mainWindow;
    if (main && main != exclude && main.isVisible) return main;
    NSWindow *best = nil;
    for (NSWindow *w in NSApp.windows) {
        if (w == exclude || !w.isVisible || [w isKindOfClass:[NSPanel class]]) continue;
        if (!best || w.frame.size.width * w.frame.size.height >
                     best.frame.size.width * best.frame.size.height) {
            best = w;
        }
    }
    return best;
}

// Centres the window over FCP's editing window on that window's display, whatever
// position it was left at. A position remembered on another display or Space is how
// these windows got lost before.
static void SpliceKit_placeInFrontOfFCP(NSPanel *panel) {
    NSWindow *host = SpliceKit_fcpHostWindow(panel);
    NSScreen *screen = host.screen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;

    NSRect frame = panel.frame;
    frame.size.width = MAX(panel.minSize.width, MIN(frame.size.width, visible.size.width));
    frame.size.height = MAX(panel.minSize.height, MIN(frame.size.height, visible.size.height));

    // Centre on the part of FCP's window that is on this display.
    NSRect target = host ? NSIntersectionRect(host.frame, visible) : NSZeroRect;
    if (NSIsEmptyRect(target)) target = visible;
    frame.origin.x = NSMidX(target) - frame.size.width / 2.0;
    frame.origin.y = NSMidY(target) - frame.size.height / 2.0;

    // Keep the whole window, title bar included, on the display.
    frame.origin.x = MIN(MAX(frame.origin.x, NSMinX(visible)), NSMaxX(visible) - frame.size.width);
    frame.origin.y = MIN(MAX(frame.origin.y, NSMinY(visible)), NSMaxY(visible) - frame.size.height);
    [panel setFrame:frame display:NO];
}

void SpliceKit_presentToolWindow(NSPanel *panel) {
    if (!panel) return;
    if (panel.isMiniaturized) [panel deminiaturize:nil];
    SpliceKit_placeInFrontOfFCP(panel);
    panel.floatingPanel = NSApp.isActive;
    [panel makeKeyAndOrderFront:nil];
}

BOOL SpliceKit_toolWindowIsShownHere(NSWindow *window) {
    return window.isVisible && window.isOnActiveSpace && !window.isMiniaturized;
}
