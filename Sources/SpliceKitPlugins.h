//
//  SpliceKitPlugins.h
//  SpliceKit — Plugin discovery and loading.
//
//  Scans ~/Library/Application Support/SpliceKit/plugins/ for subdirectories
//  containing a plugin.json manifest. Loads Lua and/or native plugins in
//  dependency order.
//

#ifndef SpliceKitPlugins_h
#define SpliceKitPlugins_h

#import <Foundation/Foundation.h>
#import "SpliceKit.h"

// Scan the plugins directory, parse manifests, and load all enabled plugins.
// Called once from SpliceKit_appDidLaunch() after Lua is initialized.
void SpliceKitPlugins_loadAll(void);

#pragma mark - Plugin method registry

// Methods plugins register (Lua and native), defined in SpliceKitPlugins.m.
// SpliceKit_handleRequest dispatches to them after its built-in methods. Hidden:
// these were file-static in SpliceKitServer.m and are not exported from the dylib.
#pragma GCC visibility push(hidden)
extern NSMutableDictionary<NSString *, SpliceKitMethodHandler> *sPluginHandlers;
void SpliceKit_ensurePluginRegistryInit(void);
NSDictionary *SpliceKit_handlePluginListMethods(NSDictionary *params);
NSDictionary *SpliceKit_handlePluginList(NSDictionary *params);
#pragma GCC visibility pop

#endif /* SpliceKitPlugins_h */
