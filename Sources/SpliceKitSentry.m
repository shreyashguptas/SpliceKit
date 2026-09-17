//
//  SpliceKitSentry.m
//  Crash and error reporting for the injected runtime — REMOVED.
//
//  This fork is private and does not report crashes, errors, breadcrumbs, or
//  logs to any remote service. The upstream implementation linked the Sentry
//  Cocoa SDK and uploaded to a hardcoded third-party DSN; it has been deleted.
//
//  The functions declared in SpliceKitSentry.h are kept as no-ops so the rest
//  of the runtime (12 call sites across the Sources tree) links and behaves
//  unchanged. Nothing here touches the network, the filesystem, or disk caches.
//

#import "SpliceKitSentry.h"

BOOL SpliceKit_sentryRuntimeEnabled(void) {
    return NO;
}

NSDictionary *SpliceKit_sentryRuntimeStatus(void) {
    return @{
        @"started": @NO,
        @"enabled": @NO,
        @"logsEnabled": @NO,
        @"sdkEnabled": @NO,
        @"launchPhase": @"unknown",
        @"lastRPCMethod": @"",
        @"configSource": @"crash-reporting-removed",
        @"config": @{},
    };
}

void SpliceKit_sentryStartRuntime(void) {
}

void SpliceKit_sentrySetLaunchPhase(NSString *phase) {
    (void)phase;
}

void SpliceKit_sentrySetLastRPCMethod(NSString *method) {
    (void)method;
}

void SpliceKit_sentryAddBreadcrumb(NSString *category, NSString *message, NSDictionary *data) {
    (void)category; (void)message; (void)data;
}

void SpliceKit_sentryLog(NSString *message, NSString *category, NSDictionary *attributes) {
    (void)message; (void)category; (void)attributes;
}

void SpliceKit_sentryCaptureMessage(NSString *message, NSString *context, NSDictionary *data) {
    (void)message; (void)context; (void)data;
}

void SpliceKit_sentryCaptureException(NSException *exception, NSString *context, NSDictionary *data) {
    (void)exception; (void)context; (void)data;
}

void SpliceKit_sentryCaptureNSError(NSError *error, NSString *context, NSDictionary *data) {
    (void)error; (void)context; (void)data;
}
