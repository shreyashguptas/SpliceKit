//
//  SpliceKitBridgeMetadata.m
//  Self-describing RPC surface + lightweight liveness probe.
//
//  Registers three endpoints through the plugin registry:
//    bridge.describe     — returns metadata for every known RPC (built-in + plugin)
//    bridge.alive        — cheap probe that doesn't touch the main thread
//    bridge.safetyTags   — returns the set of safety classifications used
//
//  Built-in method metadata comes from SpliceKitRPCTable.def (one row per built-in
//  RPC, shared with the dispatcher in SpliceKitServer.m). Methods registered
//  via SpliceKit_registerPluginMethod already carry their own metadata dict
//  (see SpliceKitPlugins.m — sPluginMethodMeta) and are merged into the output.
//

#import <Foundation/Foundation.h>
#import <unistd.h>
#import "SpliceKit.h"

// The entry bridge.describe returns for one method: its metadata plus `params`, the
// keys its handler reads (with a description where one was written), so a caller
// does not find out by trial and error that fcpxml.import wants `xml` or `path`.
static NSMutableDictionary *SpliceKit_describeEntry(NSString *name, NSDictionary *entry) {
    NSMutableDictionary *out = [entry mutableCopy] ?: [NSMutableDictionary dictionary];
    out[@"name"] = name;
    if (!out[@"params"]) {
        NSDictionary *params = SpliceKit_bridgeParamsForMethod(name);
        if (params) out[@"params"] = params;
    }
    return out;
}

// Safety classifications:
//   safe              — read-only, no side effects on project/library/UI
//   state_dependent   — modifies state, requires current selection/project/timeline
//   modal             — may open a dialog or block the UI
//   destructive       — writes to library/project/clips
//   system            — touches runtime, handles, debug internals
//
// When in doubt, use state_dependent.

static NSDictionary<NSString *, NSDictionary *> *sBuiltinMetadata = nil;

static NSDictionary *meta(NSString *safety, NSString *summary) {
    return @{@"safety": safety, @"summary": summary, @"source": @"builtin"};
}

static void SpliceKit_initBuiltinMetadata(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // One entry per row of SpliceKitRPCTable.def, the list of built-in methods.
        sBuiltinMetadata = @{
#define SK_RPC(name, handler, safety, summary) @name: meta(safety, summary),
#include "SpliceKitRPCTable.def"
#undef SK_RPC
        };
    });
}

NSDictionary *SpliceKit_builtinMetadataForMethod(NSString *method) {
    SpliceKit_initBuiltinMetadata();
    return sBuiltinMetadata[method];
}

static NSDictionary *SpliceKit_handleBridgeDescribe(NSDictionary *params) {
    SpliceKit_initBuiltinMetadata();

    NSString *wanted = params[@"method"];
    NSString *safetyFilter = params[@"safety"];

    // Merge built-in + plugin-registered metadata
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    for (NSString *name in sBuiltinMetadata) {
        merged[name] = sBuiltinMetadata[name];
    }
    NSDictionary *pluginSnapshot = SpliceKit_getPluginMetadataSnapshot();
    for (NSString *name in pluginSnapshot) {
        NSMutableDictionary *entry = [pluginSnapshot[name] mutableCopy] ?: [NSMutableDictionary dictionary];
        if (!entry[@"source"]) entry[@"source"] = @"plugin";
        merged[name] = entry;
    }

    if (wanted) {
        NSDictionary *entry = merged[wanted];
        if (!entry) return @{@"error": [NSString stringWithFormat:@"No metadata for %@", wanted]};
        return SpliceKit_describeEntry(wanted, entry);
    }

    NSMutableArray *methods = [NSMutableArray arrayWithCapacity:merged.count];
    NSUInteger classified = 0;
    for (NSString *name in merged) {
        NSDictionary *entry = merged[name];
        NSString *safety = entry[@"safety"] ?: @"unclassified";
        if (safetyFilter && ![safety isEqualToString:safetyFilter]) continue;
        [methods addObject:SpliceKit_describeEntry(name, entry)];
        if (![safety isEqualToString:@"unclassified"]) classified += 1;
    }
    [methods sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"]];
    }];
    return @{
        @"methods": methods,
        @"count": @(methods.count),
        @"classified": @(classified),
        @"safety_tags": @[@"safe", @"state_dependent", @"modal", @"destructive", @"system", @"unclassified"],
    };
}

static NSDictionary *SpliceKit_handleBridgeAlive(NSDictionary *params) {
    // Deliberately doesn't touch the main thread — purely process-local.
    return @{
        @"alive": @YES,
        @"version": @SPLICEKIT_VERSION,
        @"pid": @(getpid()),
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
    };
}

static NSDictionary *SpliceKit_handleBridgeSafetyTags(NSDictionary *params) {
    return @{
        @"tags": @{
            @"safe": @"Read-only, no side effects.",
            @"state_dependent": @"Modifies state; needs project/selection/timeline.",
            @"modal": @"May open a dialog or block the UI.",
            @"destructive": @"Writes to library/project/clips.",
            @"system": @"Runtime/handles/debug internals.",
            @"unclassified": @"No classification yet — treat as potentially destructive.",
        }
    };
}

void SpliceKit_installBridgeMetadata(void) {
    SpliceKit_initBuiltinMetadata();

    SpliceKit_registerPluginMethod(@"bridge.describe",
        ^NSDictionary *(NSDictionary *params) { return SpliceKit_handleBridgeDescribe(params); },
        @{@"safety": @"safe",
          @"summary": @"Self-describing metadata for every known RPC method.",
          @"source": @"builtin"});

    SpliceKit_registerPluginMethod(@"bridge.alive",
        ^NSDictionary *(NSDictionary *params) { return SpliceKit_handleBridgeAlive(params); },
        @{@"safety": @"safe",
          @"summary": @"Cheap liveness probe — does not touch main thread.",
          @"source": @"builtin"});

    SpliceKit_registerPluginMethod(@"bridge.safetyTags",
        ^NSDictionary *(NSDictionary *params) { return SpliceKit_handleBridgeSafetyTags(params); },
        @{@"safety": @"safe",
          @"summary": @"Enumerate safety classifications and their meanings.",
          @"source": @"builtin"});

    SpliceKit_log(@"[BridgeMetadata] Registered bridge.describe / bridge.alive / bridge.safetyTags (%lu built-in methods catalogued)",
                  (unsigned long)sBuiltinMetadata.count);
}
