//
//  SpliceKitMenus.m
//  The SpliceKit menu in the menu bar (SpliceKitMenuController and its actions),
//  the Lua scripts submenu and the toolbar buttons in the main window.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitLua.h"
#import "SpliceKitPlugins.h"
#import "SpliceKitCommandPalette.h"
#import "SpliceKitDebugUI.h"
#import "SpliceKitLiveCam.h"
#import "SpliceKitURLImport.h"
#import "SpliceKitMKV.h"
#import "SpliceKitVP9.h"
#import "SpliceKitProcess.h"
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Security/Security.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <math.h>
#import <signal.h>
#import <execinfo.h>
#import <time.h>
#import <setjmp.h>
#import <pthread.h>
#import "SpliceKitMenus.h"

#pragma mark - SpliceKit Menu
//
// We add our own top-level "SpliceKit" menu to FCP's menu bar, right before Help.
// It has entries for the transcript editor, command palette, and a submenu of
// toggleable options (effect drag, pinch zoom, etc).
//

@implementation SpliceKitMenuController

+ (instancetype)shared {
    static SpliceKitMenuController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)toggleTranscriptPanel:(id)sender {
    Class panelClass = objc_getClass("SpliceKitTranscriptPanel");
    if (!panelClass) {
        SpliceKit_log(@"SpliceKitTranscriptPanel class not found");
        return;
    }
    id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
    BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(panel, @selector(isVisible));
    if (visible) {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
    } else {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
    }
    // Update toolbar button pressed state
    BOOL nowVisible = !visible;
    [self updateToolbarButtonState:nowVisible];
}

- (void)toggleCaptionPanel:(id)sender {
    Class panelClass = objc_getClass("SpliceKitCaptionPanel");
    if (!panelClass) {
        SpliceKit_log(@"SpliceKitCaptionPanel class not found");
        return;
    }
    id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
    BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(panel, @selector(isVisible));
    if (visible) {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
    } else {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
    }
}

- (void)toggleMixerPanel:(id)sender {
    Class panelClass = objc_getClass("SpliceKitMixerPanel");
    if (!panelClass) {
        SpliceKit_log(@"SpliceKitMixerPanel class not found");
        return;
    }
    id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
    BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(panel, @selector(isVisible));
    if (visible) {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
    } else {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
    }
}

- (void)toggleLiveCamPanel:(id)sender {
    Class panelClass = objc_getClass("SpliceKitLiveCamPanel");
    if (!panelClass) {
        SpliceKit_log(@"SpliceKitLiveCamPanel class not found");
        return;
    }
    id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
    BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(panel, @selector(isVisible));
    if (visible) {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
    } else {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
    }
    [self updateLiveCamToolbarButtonState:!visible];
}

- (void)toggleCommandPalette:(id)sender {
    [[SpliceKitCommandPalette sharedPalette] togglePalette];
}

- (void)toggleLuaPanel:(id)sender {
    Class panelClass = objc_getClass("SpliceKitLuaPanel");
    if (!panelClass) {
        SpliceKit_log(@"SpliceKitLuaPanel class not found");
        return;
    }
    id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
    BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(panel, @selector(isVisible));
    if (visible) {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
    } else {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
    }
}

- (void)toggleSections:(id)sender {
    // Toggle the sections bar. If it's visible, hide it. If hidden, show it
    // (loading saved sections from the current project if available).
    NSDictionary *state = SpliceKit_handleSectionsGet(@{});
    BOOL installed = [state[@"installed"] boolValue];
    if (installed) {
        SpliceKit_handleSectionsHide(@{});
    } else {
        SpliceKit_handleSectionsShow(@{});
    }
}

- (void)toggleOverviewBar:(id)sender {
    SpliceKit_setTimelineOverviewBarEnabled(!SpliceKit_isTimelineOverviewBarEnabled());
}

- (void)toggleTimelinePerformanceMode:(id)sender {
    SpliceKit_setTimelinePerformanceModeEnabled(!SpliceKit_isTimelinePerformanceModeEnabled());
}

- (void)toggleMuteAudio:(id)sender {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SpliceKit_handleTimelineAction(@{@"action": @"toggleMuteAudio"});
    });
}

#pragma mark - OpenTimelineIO Import / Export

- (void)exportOTIO:(id)sender {
    // Step 1: Export FCPXML from FCP to a temp file
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *tmpFcpxml = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_otio_menu_export.fcpxml"];
        NSDictionary *exportResult = SpliceKit_handleFCPXMLExport(@{@"path": tmpFcpxml});
        if (exportResult[@"error"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Export Failed";
                alert.informativeText = [NSString stringWithFormat:@"Could not export timeline: %@", exportResult[@"error"]];
                alert.alertStyle = NSAlertStyleWarning;
                [alert addButtonWithTitle:@"OK"];
                [alert runModal];
            });
            return;
        }

        // Step 2: Show save panel on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            NSSavePanel *panel = [NSSavePanel savePanel];
            panel.title = @"Export Timeline (OpenTimelineIO)";
            panel.nameFieldStringValue = @"Timeline.otio";
            panel.allowedContentTypes = @[
                [UTType typeWithFilenameExtension:@"otio"],
                [UTType typeWithFilenameExtension:@"otioz"],
                [UTType typeWithFilenameExtension:@"otiod"],
                [UTType typeWithFilenameExtension:@"fcpxml"],
                [UTType typeWithFilenameExtension:@"fcpxmld"],
                [UTType typeWithFilenameExtension:@"edl"],
                [UTType typeWithFilenameExtension:@"aaf"],
            ];
            panel.allowsOtherFileTypes = YES;

            if ([panel runModal] != NSModalResponseOK || !panel.URL) {
                [[NSFileManager defaultManager] removeItemAtPath:tmpFcpxml error:nil];
                return;
            }

            NSString *outPath = panel.URL.path;
            NSString *ext = outPath.pathExtension.lowercaseString;

            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSFileManager *fm = [NSFileManager defaultManager];

                if ([ext isEqualToString:@"fcpxml"] || [ext isEqualToString:@"fcpxmld"]) {
                    NSError *fileErr = nil;
                    [fm removeItemAtPath:outPath error:nil];

                    if ([ext isEqualToString:@"fcpxml"]) {
                        [fm copyItemAtPath:tmpFcpxml toPath:outPath error:&fileErr];
                    } else {
                        NSString *infoPath = [outPath stringByAppendingPathComponent:@"Info.fcpxml"];
                        [fm createDirectoryAtPath:outPath withIntermediateDirectories:YES attributes:nil error:&fileErr];
                        if (!fileErr) {
                            [fm copyItemAtPath:tmpFcpxml toPath:infoPath error:&fileErr];
                        }
                    }

                    [fm removeItemAtPath:tmpFcpxml error:nil];

                    if (fileErr) {
                        SpliceKit_log(@"[OTIO] Export error: %@", fileErr.localizedDescription);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            NSAlert *alert = [[NSAlert alloc] init];
                            alert.messageText = @"Export Failed";
                            alert.informativeText = fileErr.localizedDescription ?: @"Could not write the exported file.";
                            alert.alertStyle = NSAlertStyleWarning;
                            [alert addButtonWithTitle:@"OK"];
                            [alert runModal];
                        });
                    } else {
                        SpliceKit_log(@"[OTIO] Exported to %@ (%@)", outPath, ext.uppercaseString);
                    }
                    return;
                }

                // Step 3: Convert FCPXML → target format using Python/OTIO
                NSString *pyScript =
                    @"import sys\n"
                    @"import opentimelineio as otio\n"
                    @"\n"
                    @"def pick_fcpx_adapter():\n"
                    @"    preferred = ('fcpxml', 'fcpx_xml')\n"
                    @"    try:\n"
                    @"        available = set(otio.adapters.available_adapter_names())\n"
                    @"    except Exception:\n"
                    @"        available = set()\n"
                    @"    for name in preferred:\n"
                    @"        if name in available:\n"
                    @"            return name\n"
                    @"    return preferred[0]\n"
                    @"\n"
                    @"src_path, dst_path = sys.argv[1:3]\n"
                    @"with open(src_path, 'r', encoding='utf-8') as fh:\n"
                    @"    result = otio.adapters.read_from_string(fh.read(), pick_fcpx_adapter())\n"
                    @"timeline = result\n"
                    @"if hasattr(result, '__iter__') and not isinstance(result, otio.schema.Timeline):\n"
                    @"    for item in result:\n"
                    @"        if isinstance(item, otio.schema.Timeline):\n"
                    @"            timeline = item\n"
                    @"            break\n"
                    @"otio.adapters.write_to_file(timeline, dst_path)\n"
                    @"print('OK')\n";

                int status = -1;
                NSData *outData = nil, *errData = nil;
                NSError *err = nil;
                SpliceKitProcessOutcome outcome = SpliceKit_runProcess(@"/usr/bin/env",
                    @[@"python3", @"-c", pyScript, tmpFcpxml, outPath], nil, SpliceKitProcessOptionsNone, 0,
                    &status, &outData, &errData, &err);
                if (outcome != SpliceKitProcessExited) {
                    SpliceKit_log(@"[OTIO] Export launch error: %@", err);
                    [[NSFileManager defaultManager] removeItemAtPath:tmpFcpxml error:nil];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSAlert *alert = [[NSAlert alloc] init];
                        alert.messageText = @"Export Failed";
                        alert.informativeText = [NSString stringWithFormat:@"Could not launch Python: %@", err.localizedDescription];
                        [alert addButtonWithTitle:@"OK"];
                        [alert runModal];
                    });
                    return;
                }
                NSString *stdoutStr = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
                NSString *stderrStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];

                [[NSFileManager defaultManager] removeItemAtPath:tmpFcpxml error:nil];

                if (status != 0 || ![stdoutStr containsString:@"OK"]) {
                    SpliceKit_log(@"[OTIO] Export error: %@", stderrStr);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSAlert *alert = [[NSAlert alloc] init];
                        alert.messageText = @"Export Failed";
                        alert.informativeText = stderrStr.length > 0 ? stderrStr : @"Unknown error during OTIO conversion";
                        alert.alertStyle = NSAlertStyleWarning;
                        [alert addButtonWithTitle:@"OK"];
                        [alert runModal];
                    });
                } else {
                    SpliceKit_log(@"[OTIO] Exported to %@ (%@)", outPath, ext.uppercaseString);
                }
            });
        });
    });
}

- (void)importOTIO:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Import Timeline (OpenTimelineIO)";
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"otio"],
        [UTType typeWithFilenameExtension:@"otioz"],
        [UTType typeWithFilenameExtension:@"otiod"],
        [UTType typeWithFilenameExtension:@"edl"],
        [UTType typeWithFilenameExtension:@"aaf"],
        [UTType typeWithFilenameExtension:@"fcpxml"],
        [UTType typeWithFilenameExtension:@"fcpxmld"],
    ];
    panel.allowsOtherFileTypes = YES;
    panel.allowsMultipleSelection = NO;

    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;

    NSString *inPath = panel.URL.path;
    NSString *ext = inPath.pathExtension.lowercaseString;

    // .fcpxml/.fcpxmld files → import directly into the active library.
    if ([ext isEqualToString:@"fcpxml"] || [ext isEqualToString:@"fcpxmld"]) {
        NSString *openPath = inPath;
        if ([ext isEqualToString:@"fcpxmld"]) {
            openPath = [inPath stringByAppendingPathComponent:@"Info.fcpxml"];
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *readErr = nil;
            NSString *fcpxmlStr = [NSString stringWithContentsOfFile:openPath
                                                             encoding:NSUTF8StringEncoding
                                                                error:&readErr];
            if (!fcpxmlStr) {
                SpliceKit_log(@"[OTIO] Import read error: %@", readErr.localizedDescription);
                return;
            }
            NSDictionary *importResult = SpliceKit_handleFCPXMLImport(@{
                @"xml": fcpxmlStr,
                @"internal": @YES
            });
            if (importResult[@"error"]) {
                SpliceKit_log(@"[OTIO] Import error: %@", importResult[@"error"]);
            } else {
                SpliceKit_log(@"[OTIO] Imported %@ from %@", ext.uppercaseString, inPath);
            }
        });
        return;
    }

    // .otio files → native ObjC conversion to FCPXML, then direct import.
    if ([ext isEqualToString:@"otio"]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *fcpxmlStr = SpliceKit_otioToFCPXML(inPath);
            if (!fcpxmlStr) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText = @"Import Failed";
                    alert.informativeText = @"Could not convert .otio to FCPXML. Check the log for details.";
                    alert.alertStyle = NSAlertStyleWarning;
                    [alert addButtonWithTitle:@"OK"];
                    [alert runModal];
                });
                return;
            }

            SpliceKit_log(@"[OTIO] Converted %@ → FCPXML (%lu bytes)",
                          inPath.lastPathComponent, (unsigned long)fcpxmlStr.length);
            NSDictionary *importResult = SpliceKit_handleFCPXMLImport(@{
                @"xml": fcpxmlStr,
                @"internal": @YES
            });
            if (importResult[@"error"]) {
                SpliceKit_log(@"[OTIO] Import error: %@", importResult[@"error"]);
            } else {
                SpliceKit_log(@"[OTIO] Imported .otio from %@", inPath);
            }
        });
        return;
    }

    // Other OTIO formats (.otioz/.otiod/.edl/.aaf) → Python/OTIO conversion to FCPXML, then import
    if ([ext isEqualToString:@"otioz"] ||
        [ext isEqualToString:@"otiod"] ||
        [ext isEqualToString:@"edl"] ||
        [ext isEqualToString:@"aaf"]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_otio_import.fcpxml"];
            NSString *pyScript =
                @"import sys\n"
                @"import opentimelineio as otio\n"
                @"\n"
                @"def pick_fcpx_adapter():\n"
                @"    preferred = ('fcpxml', 'fcpx_xml')\n"
                @"    try:\n"
                @"        available = set(otio.adapters.available_adapter_names())\n"
                @"    except Exception:\n"
                @"        available = set()\n"
                @"    for name in preferred:\n"
                @"        if name in available:\n"
                @"            return name\n"
                @"    return preferred[0]\n"
                @"\n"
                @"src_path, dst_path = sys.argv[1:3]\n"
                @"result = otio.adapters.read_from_file(src_path)\n"
                @"timeline = result\n"
                @"if hasattr(result, '__iter__') and not isinstance(result, otio.schema.Timeline):\n"
                @"    for item in result:\n"
                @"        if isinstance(item, otio.schema.Timeline):\n"
                @"            timeline = item\n"
                @"            break\n"
                @"xml = otio.adapters.write_to_string(timeline, pick_fcpx_adapter())\n"
                @"with open(dst_path, 'w', encoding='utf-8') as fh:\n"
                @"    fh.write(xml)\n"
                @"print('OK')\n";

            int status = -1;
            NSData *outData = nil, *errData = nil;
            NSError *launchErr = nil;
            SpliceKitProcessOutcome outcome = SpliceKit_runProcess(@"/usr/bin/env",
                @[@"python3", @"-c", pyScript, inPath, tmpPath], nil, SpliceKitProcessOptionsNone, 0,
                &status, &outData, &errData, &launchErr);
            if (outcome != SpliceKitProcessExited) {
                SpliceKit_log(@"[OTIO] Import launch error: %@", launchErr.localizedDescription);
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText = @"Import Failed";
                    alert.informativeText = launchErr.localizedDescription ?: @"Could not launch Python for OTIO import.";
                    alert.alertStyle = NSAlertStyleWarning;
                    [alert addButtonWithTitle:@"OK"];
                    [alert runModal];
                });
                return;
            }

            NSString *stdoutStr = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
            NSString *stderrStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];

            if (status != 0 || ![stdoutStr containsString:@"OK"]) {
                [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
                SpliceKit_log(@"[OTIO] Import conversion error: %@", stderrStr);
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText = @"Import Failed";
                    alert.informativeText = stderrStr.length > 0 ? stderrStr : @"Unknown error during OTIO conversion";
                    alert.alertStyle = NSAlertStyleWarning;
                    [alert addButtonWithTitle:@"OK"];
                    [alert runModal];
                });
                return;
            }

            NSURL *fcpxmlURL = [NSURL fileURLWithPath:tmpPath];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSWorkspace sharedWorkspace] openURLs:@[fcpxmlURL]
                               withApplicationAtURL:[[NSBundle mainBundle] bundleURL]
                                      configuration:[NSWorkspaceOpenConfiguration configuration]
                                  completionHandler:^(NSRunningApplication *app, NSError *openErr) {
                    if (openErr) {
                        SpliceKit_log(@"[OTIO] Import error: %@", openErr.localizedDescription);
                    } else {
                        SpliceKit_log(@"[OTIO] Imported %@ from %@", ext.uppercaseString, inPath);
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                        dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                        [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
                    });
                }];
            });
        });
        return;
    }

    // Unsupported format
    SpliceKit_log(@"[OTIO] Unsupported format: .%@", ext);
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(toggleSections:)) {
        NSDictionary *state = SpliceKit_handleSectionsGet(@{});
        menuItem.state = [state[@"installed"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    } else if (menuItem.action == @selector(toggleOverviewBar:)) {
        menuItem.state = SpliceKit_isTimelineOverviewBarEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    } else if (menuItem.action == @selector(toggleTimelinePerformanceMode:)) {
        menuItem.state = SpliceKit_isTimelinePerformanceModeEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    }
    return YES;
}

#pragma mark - Lua Scripts Menu

// Run a .lua script when its menu item is clicked.
// The full path is stored in the menu item's representedObject.
- (void)runLuaScript:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    NSString *path = item.representedObject;
    if (!path) return;

    SpliceKit_log(@"[Lua] Running script: %@", [path lastPathComponent]);

    // Run on a background thread so the menu dismisses immediately
    // and the main thread stays free for SpliceKit_executeOnMainThread callbacks.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = SpliceKitLua_executeFile(path);
        NSString *error = result[@"error"];
        NSString *output = result[@"output"];
        if (error) {
            SpliceKit_log(@"[Lua] Error in %@: %@", [path lastPathComponent], error);
        } else if (output.length > 0) {
            SpliceKit_log(@"[Lua] %@: %@", [path lastPathComponent], output);
        } else {
            SpliceKit_log(@"[Lua] %@ completed", [path lastPathComponent]);
        }
    });
}

// Open the scripts folder in Finder so the user can add/edit scripts.
- (void)openLuaScriptsFolder:(id)sender {
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *scriptsDir = [appSupport stringByAppendingPathComponent:@"SpliceKit/lua/menu"];
    // Create the directory if it doesn't exist yet
    [[NSFileManager defaultManager] createDirectoryAtPath:scriptsDir
                              withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:scriptsDir]];
}

// NSMenuDelegate — rebuild the Lua Scripts submenu every time it opens.
// This picks up newly added/removed scripts without restarting FCP.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != self.luaScriptsMenu) return;

    [menu removeAllItems];

    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *menuDir = [appSupport stringByAppendingPathComponent:@"SpliceKit/lua/menu"];

    // Create the directory if it doesn't exist
    [[NSFileManager defaultManager] createDirectoryAtPath:menuDir
                              withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];

    // Enumerate .lua files, sorted alphabetically
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:menuDir error:nil];
    NSMutableArray *luaFiles = [NSMutableArray array];
    for (NSString *file in files) {
        if ([file.pathExtension isEqualToString:@"lua"]) {
            [luaFiles addObject:file];
        }
    }
    [luaFiles sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    if (luaFiles.count == 0) {
        NSMenuItem *emptyItem = [[NSMenuItem alloc]
            initWithTitle:@"No scripts — add .lua files to menu/ folder"
                   action:nil
            keyEquivalent:@""];
        emptyItem.enabled = NO;
        [menu addItem:emptyItem];
    } else {
        for (NSString *file in luaFiles) {
            // Display name: strip .lua extension and leading numbers/underscores
            // "01_blade_every_2s.lua" → "blade every 2s"
            NSString *displayName = [file stringByDeletingPathExtension];
            // Strip leading "01_", "02_" etc. for ordering without showing numbers
            NSRegularExpression *regex = [NSRegularExpression
                regularExpressionWithPattern:@"^\\d+[_\\-\\s]+"
                                     options:0 error:nil];
            displayName = [regex stringByReplacingMatchesInString:displayName
                                                         options:0
                                                           range:NSMakeRange(0, displayName.length)
                                                withTemplate:@""];
            // Replace underscores with spaces
            displayName = [displayName stringByReplacingOccurrencesOfString:@"_" withString:@" "];

            NSString *fullPath = [menuDir stringByAppendingPathComponent:file];

            NSMenuItem *item = [[NSMenuItem alloc]
                initWithTitle:displayName
                       action:@selector(runLuaScript:)
                keyEquivalent:@""];
            item.target = [SpliceKitMenuController shared];
            item.representedObject = fullPath;
            item.enabled = YES;

            // Read the first comment line for a tooltip
            NSString *content = [NSString stringWithContentsOfFile:fullPath
                                                         encoding:NSUTF8StringEncoding
                                                            error:nil];
            if (content) {
                // Look for first "-- " comment line
                for (NSString *line in [content componentsSeparatedByString:@"\n"]) {
                    NSString *trimmed = [line stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
                    if ([trimmed hasPrefix:@"-- "] && trimmed.length > 3) {
                        item.toolTip = [trimmed substringFromIndex:3];
                        break;
                    } else if ([trimmed hasPrefix:@"--[["]) {
                        // Multi-line comment — grab the next non-empty line
                        continue;
                    } else if (trimmed.length > 0 && ![trimmed hasPrefix:@"--"]) {
                        break; // hit code, stop looking
                    } else if (trimmed.length > 2 && [trimmed hasPrefix:@"  "]) {
                        // Indented line inside --[[ block — use as tooltip
                        item.toolTip = [trimmed stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
                        break;
                    }
                }
            }

            [menu addItem:item];
        }
    }

    [menu addItem:[NSMenuItem separatorItem]];

    // "Open Scripts Folder" item at the bottom
    NSMenuItem *openFolderItem = [[NSMenuItem alloc]
        initWithTitle:@"Open Scripts Folder..."
               action:@selector(openLuaScriptsFolder:)
        keyEquivalent:@""];
    openFolderItem.target = [SpliceKitMenuController shared];
    openFolderItem.enabled = YES;
    [menu addItem:openFolderItem];
}

- (void)toggleEffectDragAsAdjustmentClip:(id)sender {
    BOOL newState = !SpliceKit_isEffectDragAsAdjustmentClipEnabled();
    SpliceKit_setEffectDragAsAdjustmentClipEnabled(newState);
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        [(NSMenuItem *)sender setState:newState ? NSControlStateValueOn : NSControlStateValueOff];
    }
}

- (void)toggleViewerPinchZoom:(id)sender {
    BOOL newState = !SpliceKit_isViewerPinchZoomEnabled();
    SpliceKit_setViewerPinchZoomEnabled(newState);
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        [(NSMenuItem *)sender setState:newState ? NSControlStateValueOn : NSControlStateValueOff];
    }
}

- (void)toggleVideoOnlyKeepsAudioDisabled:(id)sender {
    BOOL newState = !SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled();
    SpliceKit_setVideoOnlyKeepsAudioDisabledEnabled(newState);
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        [(NSMenuItem *)sender setState:newState ? NSControlStateValueOn : NSControlStateValueOff];
    }
}

- (void)toggleSuppressAutoImport:(id)sender {
    BOOL newState = !SpliceKit_isSuppressAutoImportEnabled();
    SpliceKit_setSuppressAutoImportEnabled(newState);
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        [(NSMenuItem *)sender setState:newState ? NSControlStateValueOn : NSControlStateValueOff];
    }
}

// --- Playback Speed ladder editors ---

static NSString *SpliceKit_ladderToString(NSArray<NSNumber *> *ladder) {
    NSMutableArray *strs = [NSMutableArray array];
    for (NSNumber *n in ladder) {
        float v = [n floatValue];
        if (v == (int)v) [strs addObject:[NSString stringWithFormat:@"%d", (int)v]];
        else [strs addObject:[NSString stringWithFormat:@"%.1f", v]];
    }
    return [strs componentsJoinedByString:@", "];
}

static NSArray<NSNumber *> *SpliceKit_parseLadderString(NSString *str) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *part in [str componentsSeparatedByString:@","]) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length > 0) {
            float val = [trimmed floatValue];
            if (val > 0.0f) [result addObject:@(val)];
        }
    }
    // Sort ascending
    [result sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [a compare:b];
    }];
    return result;
}

- (void)editLLadder:(id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"L Key Speeds";
        alert.informativeText = @"Each press of L advances to the next speed.\nEnter values separated by commas:";
        [alert addButtonWithTitle:@"Save"];
        [alert addButtonWithTitle:@"Cancel"];
        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
        input.stringValue = SpliceKit_ladderToString(SpliceKit_getLLadder());
        alert.accessoryView = input;
        [alert.window makeFirstResponder:input];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            NSArray *speeds = SpliceKit_parseLadderString(input.stringValue);
            if (speeds.count > 0) {
                SpliceKit_setLLadder(speeds);
                if ([sender isKindOfClass:[NSMenuItem class]])
                    [(NSMenuItem *)sender setTitle:
                        [NSString stringWithFormat:@"L Speeds: %@", SpliceKit_ladderToString(speeds)]];
            }
        }
    });
}

- (void)editJLadder:(id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"J Key Speeds";
        alert.informativeText = @"Each press of J advances to the next reverse speed.\nEnter values separated by commas:";
        [alert addButtonWithTitle:@"Save"];
        [alert addButtonWithTitle:@"Cancel"];
        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
        input.stringValue = SpliceKit_ladderToString(SpliceKit_getJLadder());
        alert.accessoryView = input;
        [alert.window makeFirstResponder:input];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            NSArray *speeds = SpliceKit_parseLadderString(input.stringValue);
            if (speeds.count > 0) {
                SpliceKit_setJLadder(speeds);
                if ([sender isKindOfClass:[NSMenuItem class]])
                    [(NSMenuItem *)sender setTitle:
                        [NSString stringWithFormat:@"J Speeds: %@", SpliceKit_ladderToString(speeds)]];
            }
        }
    });
}

- (void)setDefaultConformFit:(id)sender {
    SpliceKit_setDefaultSpatialConformType(@"fit");
    [self _updateConformMenuFromSender:sender];
}

- (void)setDefaultConformFill:(id)sender {
    SpliceKit_setDefaultSpatialConformType(@"fill");
    [self _updateConformMenuFromSender:sender];
}

- (void)setDefaultConformNone:(id)sender {
    SpliceKit_setDefaultSpatialConformType(@"none");
    [self _updateConformMenuFromSender:sender];
}

- (void)openSecondaryTimeline:(id)sender {
    NSDictionary *result = SpliceKit_dualTimelineOpen(@{});
    if (result[@"error"]) {
        SpliceKit_log(@"[DualTimeline] Open failed: %@", result[@"error"]);
        NSBeep();
    }
}

- (void)syncSecondaryTimelineRoot:(id)sender {
    NSDictionary *result = SpliceKit_dualTimelineSyncRoot(@{});
    if (result[@"error"]) {
        SpliceKit_log(@"[DualTimeline] Sync root failed: %@", result[@"error"]);
        NSBeep();
    }
}

- (void)openSelectedInSecondaryTimeline:(id)sender {
    NSDictionary *result = SpliceKit_dualTimelineOpenSelectedInSecondary(@{});
    if (result[@"error"]) {
        SpliceKit_log(@"[DualTimeline] Open selected failed: %@", result[@"error"]);
        NSBeep();
    }
}

- (void)focusPrimaryTimeline:(id)sender {
    NSDictionary *result = SpliceKit_dualTimelineFocus(@{@"pane": @"primary"});
    if (result[@"error"]) {
        SpliceKit_log(@"[DualTimeline] Focus primary failed: %@", result[@"error"]);
        NSBeep();
    }
}

- (void)focusSecondaryTimeline:(id)sender {
    NSDictionary *result = SpliceKit_dualTimelineFocus(@{@"pane": @"secondary"});
    if (result[@"error"]) {
        SpliceKit_log(@"[DualTimeline] Focus secondary failed: %@", result[@"error"]);
        NSBeep();
    }
}

- (void)closeSecondaryTimeline:(id)sender {
    NSDictionary *result = SpliceKit_dualTimelineClose(@{});
    if (result[@"error"]) {
        SpliceKit_log(@"[DualTimeline] Close failed: %@", result[@"error"]);
        NSBeep();
    }
}

- (void)_toggleSecondaryPanelNamed:(NSString *)panel {
    NSDictionary *result = SpliceKit_dualTimelineTogglePanel(@{
        @"pane": @"secondary",
        @"panel": panel ?: @"",
    });
    if (result[@"error"]) {
        SpliceKit_log(@"[DualTimeline] Toggle %@ failed: %@", panel ?: @"panel", result[@"error"]);
        NSBeep();
    }
}

- (void)toggleSecondaryBrowser:(id)sender {
    [self _toggleSecondaryPanelNamed:@"browser"];
}

- (void)toggleSecondaryTimelineIndex:(id)sender {
    [self _toggleSecondaryPanelNamed:@"timelineIndex"];
}

- (void)toggleSecondaryAudioMeters:(id)sender {
    [self _toggleSecondaryPanelNamed:@"audioMeters"];
}

- (void)toggleSecondaryEffectsBrowser:(id)sender {
    [self _toggleSecondaryPanelNamed:@"effectsBrowser"];
}

- (void)toggleSecondaryTransitionsBrowser:(id)sender {
    [self _toggleSecondaryPanelNamed:@"transitionsBrowser"];
}

- (void)_updateConformMenuFromSender:(id)sender {
    if (![sender isKindOfClass:[NSMenuItem class]]) return;
    NSMenu *menu = [(NSMenuItem *)sender menu];
    if (!menu) return;
    NSString *current = SpliceKit_getDefaultSpatialConformType();
    for (NSMenuItem *item in menu.itemArray) {
        NSString *tag = nil;
        if (item.action == @selector(setDefaultConformFit:)) tag = @"fit";
        else if (item.action == @selector(setDefaultConformFill:)) tag = @"fill";
        else if (item.action == @selector(setDefaultConformNone:)) tag = @"none";
        if (tag) {
            item.state = [current isEqualToString:tag] ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
}

- (void)updateToolbarButtonState:(BOOL)active {
    NSButton *btn = self.toolbarButton;
    if (!btn) return;
    btn.state = active ? NSControlStateValueOn : NSControlStateValueOff;
    // Match FCP's native toolbar style — active buttons get a blue accent tint
    if (active) {
        btn.contentTintColor = [NSColor controlAccentColor];
        btn.bezelColor = [NSColor colorWithWhite:0.0 alpha:0.5];
    } else {
        btn.contentTintColor = nil;
        btn.bezelColor = nil;
    }
}

- (void)updateLiveCamToolbarButtonState:(BOOL)active {
    NSButton *btn = self.liveCamToolbarButton;
    if (!btn) return;
    btn.state = active ? NSControlStateValueOn : NSControlStateValueOff;
    if (active) {
        btn.contentTintColor = [NSColor controlAccentColor];
        btn.bezelColor = [NSColor colorWithWhite:0.0 alpha:0.5];
    } else {
        btn.contentTintColor = nil;
        btn.bezelColor = nil;
    }
}

@end

void SpliceKit_installMenu(void) {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu) {
        SpliceKit_log(@"No main menu found - skipping menu install");
        return;
    }

    // Create "Splices" top-level menu
    NSMenu *bridgeMenu = [[NSMenu alloc] initWithTitle:@"Splices"];

    NSMenuItem *transcriptItem = [[NSMenuItem alloc]
        initWithTitle:@"Transcript Editor"
               action:@selector(toggleTranscriptPanel:)
        keyEquivalent:@"t"];
    transcriptItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    transcriptItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:transcriptItem];

    NSMenuItem *captionItem = [[NSMenuItem alloc]
        initWithTitle:@"Social Captions"
               action:@selector(toggleCaptionPanel:)
        keyEquivalent:@"c"];
    captionItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    captionItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:captionItem];

    NSMenuItem *liveCamItem = [[NSMenuItem alloc]
        initWithTitle:@"LiveCam"
               action:@selector(toggleLiveCamPanel:)
        keyEquivalent:@""];
    liveCamItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:liveCamItem];

    NSMenuItem *paletteItem = [[NSMenuItem alloc]
        initWithTitle:@"Command Palette"
               action:@selector(toggleCommandPalette:)
        keyEquivalent:@"p"];
    paletteItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    paletteItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:paletteItem];

    NSMenuItem *luaItem = [[NSMenuItem alloc]
        initWithTitle:@"Lua REPL"
               action:@selector(toggleLuaPanel:)
        keyEquivalent:@"l"];
    luaItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    luaItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:luaItem];

    NSMenuItem *sectionsItem = [[NSMenuItem alloc]
        initWithTitle:@"Sections"
               action:@selector(toggleSections:)
        keyEquivalent:@"s"];
    sectionsItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    sectionsItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:sectionsItem];

    NSMenuItem *overviewItem = [[NSMenuItem alloc]
        initWithTitle:@"Overview"
               action:@selector(toggleOverviewBar:)
        keyEquivalent:@""];
    overviewItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:overviewItem];

    NSMenuItem *perfModeItem = [[NSMenuItem alloc]
        initWithTitle:@"Smooth Scroll"
               action:@selector(toggleTimelinePerformanceMode:)
        keyEquivalent:@""];
    perfModeItem.target = [SpliceKitMenuController shared];
    perfModeItem.toolTip = @"120Hz centered-scroll playback, suspended filmstrip "
                           @"updates during pinch/scroll, and Apple's hidden "
                           @"TLKOptimizedReload fast-path.";
    [bridgeMenu addItem:perfModeItem];

    NSMenuItem *mixerItem = [[NSMenuItem alloc]
        initWithTitle:@"Audio Mixer"
               action:@selector(toggleMixerPanel:)
        keyEquivalent:@"m"];
    mixerItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    mixerItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:mixerItem];

    [bridgeMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *muteAudioItem = [[NSMenuItem alloc]
        initWithTitle:@"Mute Audio"
               action:@selector(toggleMuteAudio:)
        keyEquivalent:@"m"];
    muteAudioItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    muteAudioItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:muteAudioItem];

    // --- Lua Scripts submenu (dynamically populated) ---
    NSMenu *luaScriptsMenu = [[NSMenu alloc] initWithTitle:@"Lua Scripts"];
    luaScriptsMenu.delegate = [SpliceKitMenuController shared];
    luaScriptsMenu.autoenablesItems = NO;
    [SpliceKitMenuController shared].luaScriptsMenu = luaScriptsMenu;
    NSMenuItem *luaScriptsMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Lua Scripts"
               action:nil
        keyEquivalent:@""];
    luaScriptsMenuItem.submenu = luaScriptsMenu;
    [bridgeMenu addItem:luaScriptsMenuItem];

    // --- Dual Timeline submenu ---
    [bridgeMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *dualTimelineMenu = [[NSMenu alloc] initWithTitle:@"Dual Timeline"];
    SpliceKitMenuController *mc = [SpliceKitMenuController shared];

    NSMenuItem *openSecondaryItem = [[NSMenuItem alloc]
        initWithTitle:@"Open Secondary Timeline"
               action:@selector(openSecondaryTimeline:)
        keyEquivalent:@""];
    openSecondaryItem.target = mc;
    [dualTimelineMenu addItem:openSecondaryItem];

    NSMenuItem *syncRootItem = [[NSMenuItem alloc]
        initWithTitle:@"Clone Primary Root to Secondary"
               action:@selector(syncSecondaryTimelineRoot:)
        keyEquivalent:@""];
    syncRootItem.target = mc;
    [dualTimelineMenu addItem:syncRootItem];

    NSMenuItem *openSelectedItem = [[NSMenuItem alloc]
        initWithTitle:@"Open Selection in Secondary"
               action:@selector(openSelectedInSecondaryTimeline:)
        keyEquivalent:@""];
    openSelectedItem.target = mc;
    [dualTimelineMenu addItem:openSelectedItem];

    [dualTimelineMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *focusPrimaryItem = [[NSMenuItem alloc]
        initWithTitle:@"Focus Primary Timeline"
               action:@selector(focusPrimaryTimeline:)
        keyEquivalent:@""];
    focusPrimaryItem.target = mc;
    [dualTimelineMenu addItem:focusPrimaryItem];

    NSMenuItem *focusSecondaryItem = [[NSMenuItem alloc]
        initWithTitle:@"Focus Secondary Timeline"
               action:@selector(focusSecondaryTimeline:)
        keyEquivalent:@""];
    focusSecondaryItem.target = mc;
    [dualTimelineMenu addItem:focusSecondaryItem];

    NSMenuItem *closeSecondaryItem = [[NSMenuItem alloc]
        initWithTitle:@"Close Secondary Timeline"
               action:@selector(closeSecondaryTimeline:)
        keyEquivalent:@""];
    closeSecondaryItem.target = mc;
    [dualTimelineMenu addItem:closeSecondaryItem];

    [dualTimelineMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *secondaryWindowMenu = [[NSMenu alloc] initWithTitle:@"Secondary Window"];

    NSMenuItem *secondaryBrowserItem = [[NSMenuItem alloc]
        initWithTitle:@"Toggle Browser"
               action:@selector(toggleSecondaryBrowser:)
        keyEquivalent:@""];
    secondaryBrowserItem.target = mc;
    [secondaryWindowMenu addItem:secondaryBrowserItem];

    NSMenuItem *secondaryTimelineIndexItem = [[NSMenuItem alloc]
        initWithTitle:@"Toggle Timeline Index"
               action:@selector(toggleSecondaryTimelineIndex:)
        keyEquivalent:@""];
    secondaryTimelineIndexItem.target = mc;
    [secondaryWindowMenu addItem:secondaryTimelineIndexItem];

    NSMenuItem *secondaryAudioMetersItem = [[NSMenuItem alloc]
        initWithTitle:@"Toggle Audio Meters"
               action:@selector(toggleSecondaryAudioMeters:)
        keyEquivalent:@""];
    secondaryAudioMetersItem.target = mc;
    [secondaryWindowMenu addItem:secondaryAudioMetersItem];

    NSMenuItem *secondaryEffectsItem = [[NSMenuItem alloc]
        initWithTitle:@"Toggle Effects Browser"
               action:@selector(toggleSecondaryEffectsBrowser:)
        keyEquivalent:@""];
    secondaryEffectsItem.target = mc;
    [secondaryWindowMenu addItem:secondaryEffectsItem];

    NSMenuItem *secondaryTransitionsItem = [[NSMenuItem alloc]
        initWithTitle:@"Toggle Transitions Browser"
               action:@selector(toggleSecondaryTransitionsBrowser:)
        keyEquivalent:@""];
    secondaryTransitionsItem.target = mc;
    [secondaryWindowMenu addItem:secondaryTransitionsItem];

    NSMenuItem *secondaryWindowMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Secondary Window"
               action:nil
        keyEquivalent:@""];
    secondaryWindowMenuItem.submenu = secondaryWindowMenu;
    [dualTimelineMenu addItem:secondaryWindowMenuItem];

    NSMenuItem *dualTimelineMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Dual Timeline"
               action:nil
        keyEquivalent:@""];
    dualTimelineMenuItem.submenu = dualTimelineMenu;
    [bridgeMenu addItem:dualTimelineMenuItem];

    // --- Playback Speed submenu ---
    [bridgeMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *speedMenu = [[NSMenu alloc] initWithTitle:@"Playback Speed"];

    NSMenuItem *lItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"L Speeds: %@",
                       SpliceKit_ladderToString(SpliceKit_getLLadder())]
               action:@selector(editLLadder:)
        keyEquivalent:@""];
    lItem.target = mc;
    [speedMenu addItem:lItem];

    NSMenuItem *jItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"J Speeds: %@",
                       SpliceKit_ladderToString(SpliceKit_getJLadder())]
               action:@selector(editJLadder:)
        keyEquivalent:@""];
    jItem.target = mc;
    [speedMenu addItem:jItem];

    NSMenuItem *speedMenuItem = [[NSMenuItem alloc] initWithTitle:@"Playback Speed" action:nil keyEquivalent:@""];
    speedMenuItem.submenu = speedMenu;
    [bridgeMenu addItem:speedMenuItem];

    // --- Options submenu ---
    [bridgeMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *optionsMenu = [[NSMenu alloc] initWithTitle:@"Options"];

    NSMenuItem *effectDragItem = [[NSMenuItem alloc]
        initWithTitle:@"Effect Drag as Adjustment Clip"
               action:@selector(toggleEffectDragAsAdjustmentClip:)
        keyEquivalent:@""];
    effectDragItem.target = [SpliceKitMenuController shared];
    effectDragItem.state = SpliceKit_isEffectDragAsAdjustmentClipEnabled()
        ? NSControlStateValueOn : NSControlStateValueOff;
    [optionsMenu addItem:effectDragItem];

    NSMenuItem *pinchZoomItem = [[NSMenuItem alloc]
        initWithTitle:@"Viewer Pinch-to-Zoom"
               action:@selector(toggleViewerPinchZoom:)
        keyEquivalent:@""];
    pinchZoomItem.target = [SpliceKitMenuController shared];
    pinchZoomItem.state = SpliceKit_isViewerPinchZoomEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    [optionsMenu addItem:pinchZoomItem];

    NSMenuItem *videoOnlyKeepsAudioItem = [[NSMenuItem alloc]
        initWithTitle:@"Video-Only Edit Keeps Audio (Disabled)"
               action:@selector(toggleVideoOnlyKeepsAudioDisabled:)
        keyEquivalent:@""];
    videoOnlyKeepsAudioItem.target = [SpliceKitMenuController shared];
    videoOnlyKeepsAudioItem.state = SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled()
        ? NSControlStateValueOn : NSControlStateValueOff;
    [optionsMenu addItem:videoOnlyKeepsAudioItem];

    NSMenuItem *suppressAutoImportItem = [[NSMenuItem alloc]
        initWithTitle:@"Suppress Auto Import Window on Device Connect"
               action:@selector(toggleSuppressAutoImport:)
        keyEquivalent:@""];
    suppressAutoImportItem.target = [SpliceKitMenuController shared];
    suppressAutoImportItem.state = SpliceKit_isSuppressAutoImportEnabled()
        ? NSControlStateValueOn : NSControlStateValueOff;
    [optionsMenu addItem:suppressAutoImportItem];

    // --- Default Spatial Conform submenu ---
    NSMenu *conformMenu = [[NSMenu alloc] initWithTitle:@"Default Spatial Conform"];
    NSString *currentConform = SpliceKit_getDefaultSpatialConformType();

    NSMenuItem *conformFitItem = [[NSMenuItem alloc]
        initWithTitle:@"Fit (Default)" action:@selector(setDefaultConformFit:) keyEquivalent:@""];
    conformFitItem.target = [SpliceKitMenuController shared];
    conformFitItem.state = [currentConform isEqualToString:@"fit"] ? NSControlStateValueOn : NSControlStateValueOff;
    [conformMenu addItem:conformFitItem];

    NSMenuItem *conformFillItem = [[NSMenuItem alloc]
        initWithTitle:@"Fill" action:@selector(setDefaultConformFill:) keyEquivalent:@""];
    conformFillItem.target = [SpliceKitMenuController shared];
    conformFillItem.state = [currentConform isEqualToString:@"fill"] ? NSControlStateValueOn : NSControlStateValueOff;
    [conformMenu addItem:conformFillItem];

    NSMenuItem *conformNoneItem = [[NSMenuItem alloc]
        initWithTitle:@"None" action:@selector(setDefaultConformNone:) keyEquivalent:@""];
    conformNoneItem.target = [SpliceKitMenuController shared];
    conformNoneItem.state = [currentConform isEqualToString:@"none"] ? NSControlStateValueOn : NSControlStateValueOff;
    [conformMenu addItem:conformNoneItem];

    NSMenuItem *conformMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Default Spatial Conform" action:nil keyEquivalent:@""];
    conformMenuItem.submenu = conformMenu;
    [optionsMenu addItem:conformMenuItem];

    NSMenuItem *optionsMenuItem = [[NSMenuItem alloc] initWithTitle:@"Options" action:nil keyEquivalent:@""];
    optionsMenuItem.submenu = optionsMenu;
    [bridgeMenu addItem:optionsMenuItem];

    // Add the menu to the menu bar (before the last item which is usually "Help")
    NSMenuItem *bridgeMenuItem = [[NSMenuItem alloc] initWithTitle:@"Splices" action:nil keyEquivalent:@""];
    bridgeMenuItem.submenu = bridgeMenu;

    NSInteger helpIndex = [mainMenu indexOfItemWithTitle:@"Help"];
    if (helpIndex >= 0) {
        [mainMenu insertItem:bridgeMenuItem atIndex:helpIndex];
    } else {
        [mainMenu addItem:bridgeMenuItem];
    }

    // --- Add OTIO Import/Export items to FCP's File menu ---
    // FCP's File menu structure:
    //   File > Import (submenu) > Media..., XML..., Captions...
    //   File > Export XML...
    // We add "OpenTimelineIO..." into the Import submenu (after XML...)
    // and "Export to OpenTimelineIO..." after "Export XML..."
    NSMenu *fileMenu = nil;
    for (NSMenuItem *item in mainMenu.itemArray) {
        if ([item.title isEqualToString:@"File"] && item.submenu) {
            fileMenu = item.submenu;
            break;
        }
    }
    if (fileMenu) {
        NSMenuItem *importOTIOItem = [[NSMenuItem alloc]
            initWithTitle:@"OpenTimelineIO..."
                   action:@selector(importOTIO:)
            keyEquivalent:@""];
        importOTIOItem.target = [SpliceKitMenuController shared];

        NSMenuItem *exportOTIOItem = [[NSMenuItem alloc]
            initWithTitle:@"Export OpenTimelineIO..."
                   action:@selector(exportOTIO:)
            keyEquivalent:@""];
        exportOTIOItem.target = [SpliceKitMenuController shared];

        // Find the "Import" submenu and add our item after "XML..."
        for (NSInteger i = 0; i < fileMenu.numberOfItems; i++) {
            NSMenuItem *item = [fileMenu itemAtIndex:i];
            if ([item.title isEqualToString:@"Import"] && item.submenu) {
                NSMenu *importSubmenu = item.submenu;
                // Find "XML..." to insert after it
                NSInteger xmlIndex = -1;
                for (NSInteger j = 0; j < importSubmenu.numberOfItems; j++) {
                    if ([[importSubmenu itemAtIndex:j].title containsString:@"XML"]) {
                        xmlIndex = j;
                        break;
                    }
                }
                if (xmlIndex >= 0) {
                    [importSubmenu insertItem:importOTIOItem atIndex:xmlIndex + 1];
                } else {
                    [importSubmenu addItem:importOTIOItem];
                }
                break;
            }
        }

        // Find "Export XML..." and add our export after it
        for (NSInteger i = 0; i < fileMenu.numberOfItems; i++) {
            NSString *title = [fileMenu itemAtIndex:i].title;
            if ([title containsString:@"Export XML"]) {
                [fileMenu insertItem:exportOTIOItem atIndex:i + 1];
                break;
            }
        }

        SpliceKit_log(@"OTIO import/export added to File menu");
    }

    SpliceKit_log(@"SpliceKit menu installed (Ctrl+Option+T Transcript, Ctrl+Option+C Captions, Cmd+Shift+P Palette, Ctrl+Option+L Lua REPL)");
}

static NSString * const kSpliceKitLiveCamToolbarID = @"SpliceKitLiveCamItemID";
static NSString * const kSpliceKitTranscriptToolbarID = @"SpliceKitTranscriptItemID";
static NSString * const kSpliceKitPaletteToolbarID = @"SpliceKitPaletteItemID";
static IMP sOriginalToolbarItemForIdentifier = NULL;

// We swizzle FCP's toolbar delegate so it knows about our custom toolbar items.
// When FCP asks "what item goes at this identifier?", we intercept our IDs and
// return our buttons. Everything else passes through to the original handler.
static id SpliceKit_toolbar_itemForItemIdentifier(id self, SEL _cmd, NSToolbar *toolbar,
                                                   NSString *identifier, BOOL willInsert) {
    if ([identifier isEqualToString:kSpliceKitLiveCamToolbarID]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:kSpliceKitLiveCamToolbarID];
        item.label = @"LiveCam";
        item.paletteLabel = @"Open LiveCam";
        item.toolTip = @"LiveCam";

        NSImage *icon = [NSImage imageWithSystemSymbolName:@"camera.viewfinder"
                                  accessibilityDescription:@"LiveCam"];
        if (!icon) icon = [NSImage imageNamed:NSImageNameQuickLookTemplate];
        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
            configurationWithPointSize:13 weight:NSFontWeightMedium];
        icon = [icon imageWithSymbolConfiguration:config];

        NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 32, 25)];
        [button setButtonType:NSButtonTypePushOnPushOff];
        button.bezelStyle = NSBezelStyleTexturedRounded;
        button.bordered = YES;
        button.image = icon;
        button.alternateImage = icon;
        button.imagePosition = NSImageOnly;
        button.target = [SpliceKitMenuController shared];
        button.action = @selector(toggleLiveCamPanel:);

        [SpliceKitMenuController shared].liveCamToolbarButton = button;
        item.view = button;
        return item;
    }
    if ([identifier isEqualToString:kSpliceKitTranscriptToolbarID]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:kSpliceKitTranscriptToolbarID];
        item.label = @"Transcript";
        item.paletteLabel = @"Transcript Editor";
        item.toolTip = @"Transcript Editor";

        NSImage *icon = [NSImage imageWithSystemSymbolName:@"text.quote"
                                  accessibilityDescription:@"Transcript Editor"];
        if (!icon) icon = [NSImage imageNamed:NSImageNameListViewTemplate];
        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
            configurationWithPointSize:13 weight:NSFontWeightMedium];
        icon = [icon imageWithSymbolConfiguration:config];

        NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 32, 25)];
        [button setButtonType:NSButtonTypePushOnPushOff];
        button.bezelStyle = NSBezelStyleTexturedRounded;
        button.bordered = YES;
        button.image = icon;
        button.alternateImage = icon;
        button.imagePosition = NSImageOnly;
        button.target = [SpliceKitMenuController shared];
        button.action = @selector(toggleTranscriptPanel:);

        [SpliceKitMenuController shared].toolbarButton = button;
        item.view = button;

        return item;
    }
    if ([identifier isEqualToString:kSpliceKitPaletteToolbarID]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:kSpliceKitPaletteToolbarID];
        item.label = @"Commands";
        item.paletteLabel = @"Command Palette";
        item.toolTip = @"Command Palette (Cmd+Shift+P)";

        NSImage *icon = [NSImage imageWithSystemSymbolName:@"command"
                                  accessibilityDescription:@"Command Palette"];
        if (!icon) icon = [NSImage imageNamed:NSImageNameSmartBadgeTemplate];
        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
            configurationWithPointSize:13 weight:NSFontWeightMedium];
        icon = [icon imageWithSymbolConfiguration:config];

        NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 32, 25)];
        [button setButtonType:NSButtonTypeMomentaryPushIn];
        button.bezelStyle = NSBezelStyleTexturedRounded;
        button.bordered = YES;
        button.image = icon;
        button.imagePosition = NSImageOnly;
        button.target = [SpliceKitMenuController shared];
        button.action = @selector(toggleCommandPalette:);

        [SpliceKitMenuController shared].paletteToolbarButton = button;
        item.view = button;

        return item;
    }
    // Call original
    return ((id (*)(id, SEL, NSToolbar *, NSString *, BOOL))sOriginalToolbarItemForIdentifier)(
        self, _cmd, toolbar, identifier, willInsert);
}

@implementation SpliceKitMenuController (Toolbar)

+ (void)installToolbarButton {
    // FCP's main window isn't ready immediately at launch — we need to wait
    // for it. We use a two-pronged approach: listen for the notification,
    // and also poll as a fallback in case we missed it.
    __block id observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowDidBecomeMainNotification
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            NSWindow *window = note.object;
            if (window.toolbar) {
                [[NSNotificationCenter defaultCenter] removeObserver:observer];
                observer = nil;
                [SpliceKitMenuController addToolbarButtonToWindow:window];
            }
        }];

    // Also poll as fallback in case the notification already fired
    [self installToolbarButtonAttempt:0];
}

+ (void)installToolbarButtonAttempt:(int)attempt {
    if (attempt >= 30) {
        // 30 seconds is plenty. If there's no toolbar by now, something's wrong.
        SpliceKit_log(@"No main window for toolbar button after %d attempts", attempt);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // FCP sometimes has multiple windows — check all of them
        for (NSWindow *w in [NSApp windows]) {
            if (w.toolbar && w.toolbar.items.count > 0) {
                [SpliceKitMenuController addToolbarButtonToWindow:w];
                return;
            }
        }
        [self installToolbarButtonAttempt:attempt + 1];
    });
}

+ (void)addToolbarButtonToWindow:(NSWindow *)window {
    @try {
        NSToolbar *toolbar = window.toolbar;
        if (!toolbar) {
            SpliceKit_log(@"No toolbar on main window");
            return;
        }

        // We need to teach FCP's toolbar delegate about our custom item IDs.
        // The cleanest way is to swizzle the delegate's itemForItemIdentifier: method.
        id delegate = toolbar.delegate;
        if (!delegate) {
            SpliceKit_log(@"No toolbar delegate");
            return;
        }

        if (!sOriginalToolbarItemForIdentifier) {
            SEL sel = @selector(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:);
            Method m = class_getInstanceMethod([delegate class], sel);
            if (m) {
                sOriginalToolbarItemForIdentifier = method_getImplementation(m);
                method_setImplementation(m, (IMP)SpliceKit_toolbar_itemForItemIdentifier);
                SpliceKit_log(@"Swizzled toolbar delegate %@ for custom item", NSStringFromClass([delegate class]));
            }
        }

        // Guard against double-insertion — can happen if both the notification
        // and the polling fallback fire. Also clean up stale items (no view).
        BOOL hasLiveCam = NO, hasTranscript = NO, hasPalette = NO;
        for (NSInteger i = (NSInteger)toolbar.items.count - 1; i >= 0; i--) {
            NSToolbarItem *ti = toolbar.items[(NSUInteger)i];
            if ([ti.itemIdentifier isEqualToString:kSpliceKitLiveCamToolbarID]) {
                if (ti.view) {
                    if ([ti.view isKindOfClass:[NSButton class]])
                        [SpliceKitMenuController shared].liveCamToolbarButton = (NSButton *)ti.view;
                    hasLiveCam = YES;
                } else {
                    [toolbar removeItemAtIndex:(NSUInteger)i];
                }
            } else if ([ti.itemIdentifier isEqualToString:kSpliceKitTranscriptToolbarID]) {
                if (ti.view) {
                    if ([ti.view isKindOfClass:[NSButton class]])
                        [SpliceKitMenuController shared].toolbarButton = (NSButton *)ti.view;
                    hasTranscript = YES;
                } else {
                    [toolbar removeItemAtIndex:(NSUInteger)i];
                }
            } else if ([ti.itemIdentifier isEqualToString:kSpliceKitPaletteToolbarID]) {
                if (ti.view) {
                    if ([ti.view isKindOfClass:[NSButton class]])
                        [SpliceKitMenuController shared].paletteToolbarButton = (NSButton *)ti.view;
                    hasPalette = YES;
                } else {
                    [toolbar removeItemAtIndex:(NSUInteger)i];
                }
            }
        }
        if (hasLiveCam && hasTranscript && hasPalette) {
            SpliceKit_log(@"All toolbar buttons already present — skipping");
            return;
        }

        // Insert our buttons just before the flexible space — that's where
        // they look most natural, grouped with FCP's own tool buttons.
        NSUInteger insertIdx = toolbar.items.count;
        for (NSUInteger i = 0; i < toolbar.items.count; i++) {
            NSToolbarItem *ti = toolbar.items[i];
            if ([ti.itemIdentifier isEqualToString:NSToolbarFlexibleSpaceItemIdentifier]) {
                insertIdx = i;
                break;
            }
        }
        if (!hasLiveCam) {
            [toolbar insertItemWithItemIdentifier:kSpliceKitLiveCamToolbarID atIndex:insertIdx];
            SpliceKit_log(@"LiveCam toolbar button inserted at index %lu", (unsigned long)insertIdx);
            insertIdx++;
        }
        if (!hasPalette) {
            [toolbar insertItemWithItemIdentifier:kSpliceKitPaletteToolbarID atIndex:insertIdx];
            SpliceKit_log(@"Command Palette toolbar button inserted at index %lu", (unsigned long)insertIdx);
            insertIdx++;
        }
        if (!hasTranscript) {
            [toolbar insertItemWithItemIdentifier:kSpliceKitTranscriptToolbarID atIndex:insertIdx];
            SpliceKit_log(@"Transcript toolbar button inserted at index %lu", (unsigned long)insertIdx);
        }

    } @catch (NSException *e) {
        SpliceKit_log(@"Failed to install toolbar button: %@", e.reason);
    }
}

@end
