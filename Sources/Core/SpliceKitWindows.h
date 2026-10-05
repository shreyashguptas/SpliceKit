//
//  SpliceKitWindows.h
//  How every SpliceKit tool window inside Final Cut Pro behaves: the Transcript Editor,
//  Social Captions, the Audio Mixer, the Log, the Lua REPL and the windows Lua scripts open.
//
//  - A standard macOS title bar: close, minimize, resize.
//  - Above FCP's own windows only while FCP is the active app; behind the next app's
//    windows like any other window once you switch away. Never on top of every app.
//  - Shown on the Space (desktop) you are on, centred in front of FCP's editing window on
//    that window's display, so a window can never be lost on another desktop or display.
//  - Still an NSPanel, so it never becomes FCP's main window: menu commands keep reaching
//    the timeline while one of these has keyboard focus.
//
//  Everything declared here is hidden: it never shows up in the dylib's exports.
//

#ifndef SpliceKitWindows_h
#define SpliceKitWindows_h

#import <AppKit/AppKit.h>

#pragma GCC visibility push(hidden)

// The style mask for a tool window: a standard title bar with close, minimize and resize.
#define SpliceKitToolWindowStyleMask (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | \
                                      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)

// Gives a freshly made panel the behaviour above. Call once, right after creating it;
// it replaces setting level, floatingPanel, hidesOnDeactivate and collectionBehavior.
void SpliceKit_adoptToolWindow(NSPanel *panel);

// Shows the window the way every show should: un-minimized, centred in front of FCP's
// editing window on the current Space, key and in front. Use it instead of
// makeKeyAndOrderFront: whenever a tool window is opened.
void SpliceKit_presentToolWindow(NSPanel *panel);

// YES when the window is on screen where the user is looking: visible, on the active
// Space and not minimized. A toggle hides the window only then; otherwise it presents it.
BOOL SpliceKit_toolWindowIsShownHere(NSWindow *window);

// FCP's editing window: the main window while FCP is active, otherwise its largest
// visible window that is not a panel. nil when FCP has no window on screen.
NSWindow *SpliceKit_fcpHostWindow(NSWindow *exclude);

#pragma GCC visibility pop

#endif /* SpliceKitWindows_h */
