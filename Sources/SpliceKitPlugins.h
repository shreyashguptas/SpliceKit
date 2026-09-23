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

// Scan the plugins directory, parse manifests, and load all enabled plugins.
// Called once from SpliceKit_appDidLaunch() after Lua is initialized.
void SpliceKitPlugins_loadAll(void);

#endif /* SpliceKitPlugins_h */
