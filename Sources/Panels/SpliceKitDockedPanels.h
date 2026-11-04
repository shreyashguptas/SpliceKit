//
//  SpliceKitDockedPanels.h
//  Panels that open inside Final Cut Pro's main window instead of as separate windows:
//  the Transcript Editor and FCP's own Background Tasks list.
//
//  - They sit in the top row, between the Viewer and the Inspector. Opening one makes the
//    Viewer narrower, closing it gives the room back, the way the Inspector opens and closes.
//  - Each is a LunaKit module (LKViewModule), the building block of FCP's own panes, put in
//    the top-row container (PEUpperDeckContainer).
//  - None of them is ever written into FCP's saved window layout or workspaces, so a
//    workspace never names a module that does not exist at the next launch.
//  - When FCP's main window has no top row (a layout FCP has not got yet), or the row is
//    too narrow for one more pane (a portrait display), the show functions answer NO and
//    the caller falls back to a separate window.
//
//  Everything declared here is hidden: it never shows up in the dylib's exports.
//

#ifndef SpliceKitDockedPanels_h
#define SpliceKitDockedPanels_h

#import <AppKit/AppKit.h>

#pragma GCC visibility push(hidden)

// Shows `view` docked under `identifier`, making its module the first time; `label` names it
// for FCP and `minSize` is the smallest it may be made. A second call shows it again. NO when
// there is nowhere to dock it. Main thread only.
BOOL SpliceKit_dockShowView(NSString *identifier, NSString *label, NSView *view, NSSize minSize);

// YES when the top row has room for this panel next to the panes it already shows, each at
// its smallest (or the panel is already open). SpliceKit_dockShowView checks it too; call it
// first when the view must stay where it is if it cannot dock.
BOOL SpliceKit_dockHasRoom(NSString *identifier, NSSize minSize);

// Hides the docked panel, taking the keyboard focus out of it; its view stays alive for the
// next show.
void SpliceKit_dockHide(NSString *identifier);

// YES when the docked panel is open in FCP's main window.
BOOL SpliceKit_dockIsShown(NSString *identifier);

// Background Tasks (Window > Background Tasks, ⌘9, and the progress dial in the toolbar)
// opens and closes docked. Install once at startup.
void SpliceKit_installDockedBackgroundTasks(void);

// Opens Background Tasks docked, or closes it when it is open. NO when it cannot be docked.
BOOL SpliceKit_dockToggleBackgroundTasks(void);
BOOL SpliceKit_dockBackgroundTasksIsShown(void);

#pragma GCC visibility pop

#endif /* SpliceKitDockedPanels_h */
