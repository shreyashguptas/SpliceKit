//
//  SpliceKitMenus.h
//  Declarations shared between SpliceKit.m, SpliceKitMenus.m and SpliceKitOTIO.m.
//  Private to those files. The functions below were file-static before SpliceKit.m
//  was split; they are declared hidden so they stay out of the exported symbols.
//

#ifndef SpliceKitMenus_h
#define SpliceKitMenus_h

#import <AppKit/AppKit.h>

@interface SpliceKitMenuController : NSObject <NSMenuDelegate>
+ (instancetype)shared;
- (void)toggleTranscriptPanel:(id)sender;
- (void)toggleCaptionPanel:(id)sender;
- (void)toggleLiveCamPanel:(id)sender;
- (void)toggleSections:(id)sender;
- (void)toggleOverviewBar:(id)sender;
- (void)toggleCommandPalette:(id)sender;
- (void)toggleLuaPanel:(id)sender;
- (void)runLuaScript:(id)sender;
- (void)openLuaScriptsFolder:(id)sender;
- (void)toggleEffectDragAsAdjustmentClip:(id)sender;
- (void)toggleViewerPinchZoom:(id)sender;
- (void)toggleVideoOnlyKeepsAudioDisabled:(id)sender;
- (void)toggleSuppressAutoImport:(id)sender;
- (void)toggleTimelinePerformanceMode:(id)sender;
- (void)editLLadder:(id)sender;
- (void)editJLadder:(id)sender;
- (void)setDefaultConformFit:(id)sender;
- (void)setDefaultConformFill:(id)sender;
- (void)setDefaultConformNone:(id)sender;
- (void)openSecondaryTimeline:(id)sender;
- (void)syncSecondaryTimelineRoot:(id)sender;
- (void)openSelectedInSecondaryTimeline:(id)sender;
- (void)focusPrimaryTimeline:(id)sender;
- (void)focusSecondaryTimeline:(id)sender;
- (void)closeSecondaryTimeline:(id)sender;
- (void)toggleSecondaryBrowser:(id)sender;
- (void)toggleSecondaryTimelineIndex:(id)sender;
- (void)toggleSecondaryAudioMeters:(id)sender;
- (void)toggleSecondaryEffectsBrowser:(id)sender;
- (void)toggleSecondaryTransitionsBrowser:(id)sender;
- (void)toggleMixerPanel:(id)sender;
- (void)toggleMuteAudio:(id)sender;
- (void)exportOTIO:(id)sender;
- (void)importOTIO:(id)sender;
- (void)toggleLiveCamPanel:(id)sender;
- (void)updateLiveCamToolbarButtonState:(BOOL)active;
@property (nonatomic, weak) NSButton *toolbarButton;
@property (nonatomic, weak) NSButton *paletteToolbarButton;
@property (nonatomic, weak) NSButton *liveCamToolbarButton;
@property (nonatomic, strong) NSMenu *luaScriptsMenu;
@end

// Already exported before the split; declared here so the other files can call them.

#pragma mark - Defined in SpliceKitOTIO.m

NSString *SpliceKit_otioToFCPXML(NSString *otioPath);

#pragma GCC visibility push(hidden)

#pragma mark - Defined in SpliceKitMenus.m

void SpliceKit_installMenu(void);

#pragma GCC visibility pop

@interface SpliceKitMenuController (Toolbar)
+ (void)installToolbarButton;
@end

#endif /* SpliceKitMenus_h */
