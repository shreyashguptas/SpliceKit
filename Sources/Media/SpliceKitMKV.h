#pragma once

#import <Foundation/Foundation.h>

// Host-side bootstrap for the SpliceKit MKV/WebM format reader plugin. Runs
// at did-launch, finds the bundle inside FCP.app/Contents/PlugIns/FormatReaders/,
// and triggers MediaToolbox + ProCore registration so FCP picks up the reader
// without waiting for its own plugin-scan cycle.
void SpliceKitMKV_Bootstrap(void);

// Phased bootstrap parallel to SpliceKitURLImport_bootstrapAtLaunchPhase.
// Accepts @"will-launch" or @"did-launch" (anything else is treated as
// did-launch). Register the provider/plugin shims as early as
// possible so the Media Import browser's very first node-enumeration pass
// sees them.
void SpliceKitMKV_bootstrapAtLaunchPhase(NSString *phase);
