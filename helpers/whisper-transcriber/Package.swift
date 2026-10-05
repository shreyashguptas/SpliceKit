// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "whisper-transcriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned exactly, like FluidAudio in parakeet-transcriber: a floating
        // `from:` drifts to whatever is newest, and a renamed API then breaks a
        // clean checkout. Sources/main.swift is built and tested against 0.18.0.
        // Package.resolved (committed) pins the transitive packages too.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.18.0"),
    ],
    targets: [
        .executableTarget(
            name: "whisper-transcriber",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources"
        ),
    ]
)
