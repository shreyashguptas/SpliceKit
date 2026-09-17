// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "parakeet-transcriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned exactly. This source is written against FluidAudio 0.13.6 and
        // will not compile on either side of it:
        //   - 0.13.7+ renamed `transcribe(_:source:)` to `transcribe(_:decoderState:)`
        //   - 0.13.1 and earlier have no `AsrModelVersion.tdtCtc110m`
        // The declaration used to be `from: "0.12.0"`, which floats to the newest
        // 0.x — it had drifted to 0.15.7, so a clean checkout failed to build,
        // nothing installed the binary, and the transcript panel reported a
        // missing file rather than a broken build. Package.resolved is committed
        // next to this for the same reason: reproducible on a new machine.
        //
        // 0.13.6 also declares `dependencies: []` — no transitive packages, and
        // none of the precompiled NemoTextProcessing.xcframework that 0.14+ pulls
        // from a GitHub release. Keep it that way when bumping this pin.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.13.6"),
    ],
    targets: [
        .executableTarget(
            name: "parakeet-transcriber",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources"
        ),
    ]
)
