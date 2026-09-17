import Foundation

// Crash and error reporting for the patcher app — REMOVED.
//
// This fork is private and does not report crashes, errors, or breadcrumbs to
// any remote service. The upstream implementation linked the Sentry Cocoa SDK
// and uploaded to a hardcoded third-party DSN; it has been deleted.
//
// The call sites in SpliceKitApp.swift and PatcherModel.swift are kept working
// by the no-op API below, so the patcher app still builds unchanged. Nothing
// here touches the network.

/// Local stand-in for the Sentry SDK's level type, kept so existing call sites
/// that pass `level: .error` still compile without the SDK present.
enum SentryLevel {
    case none
    case debug
    case info
    case warning
    case error
    case fatal
}

enum PatcherSentry {

    static func start() {
    }

    static func addBreadcrumb(_ message: String,
                              category: String = "patcher.log",
                              level: SentryLevel = .info,
                              data: [String: Any] = [:]) {
        _ = (message, category, level, data)
    }

    static func capture(error: Error, context: String, extras: [String: Any] = [:]) {
        _ = (error, context, extras)
    }

    static func captureMessage(_ message: String,
                               level: SentryLevel = .warning,
                               context: String,
                               extras: [String: Any] = [:]) {
        _ = (message, level, context, extras)
    }
}
