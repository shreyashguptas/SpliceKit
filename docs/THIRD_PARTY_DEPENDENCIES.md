# Third-party dependencies

What this fork pulls in from outside, when, and how to remove it.

Everything below is optional: it exists only to make on-device transcription
work. Final Cut Pro itself, the injected dylib, the bridge and the MCP server
have **no** third-party dependencies — they build from the source in this repo
against Apple's own frameworks.

Nothing is downloaded during `make install` unless a transcription helper
actually needs rebuilding, and nothing phones home. Crash and analytics
reporting was removed from this fork entirely (see `Sources/SpliceKitSentry.m`).

---

## Build time

Fetched by SwiftPM when `Scripts/build-transcribers.sh` compiles the helper
CLIs. Pinned to exact revisions in each package's `Package.resolved`, so the
versions do not drift between machines or over time.

### tools/parakeet-transcriber — transcript panel, Parakeet engine

**One dependency. No transitive packages. No prebuilt binaries.**

| Dependency | Source | Version | Licence |
| --- | --- | --- | --- |
| FluidAudio | `github.com/FluidInference/FluidAudio` | exactly 0.13.6 | Apache-2.0 |

FluidAudio 0.13.6 declares `dependencies: []`, so that table is the whole tree.

**Why the pin is exact.** `tools/parakeet-transcriber/Sources/main.swift` only
compiles against 0.13.6, and fails on both sides of it:

| Version | Problem |
| --- | --- |
| 0.13.7 and newer | renamed `transcribe(_:source:)` to `transcribe(_:decoderState:)` |
| 0.13.1 and older | no `AsrModelVersion.tdtCtc110m` |
| 0.14.0 and newer | additionally pulls `NemoTextProcessing.xcframework`, a ~111 MB **precompiled binary** from a GitHub release that cannot be audited as source |

The declaration used to be `from: "0.12.0"`, which floats to the newest 0.x. It
had drifted to 0.15.7, so a clean checkout no longer compiled — and because the
build was never wired into the patcher, the failure was invisible. The
transcript panel just reported "rerun the SpliceKit patcher app or copy the
binary manually to ..." for a binary that had never been built.

`Package.resolved` is committed next to it (`.gitignore` carries a
`!tools/*/Package.resolved` exception) so a new Mac resolves the same revision.

**The keychain prompt.** A first build makes macOS ask whether "a Swift package
wants to use your confidential information stored in github.com in your
keychain". That is `git` consulting the keychain helper for a `github.com`
credential before cloning. FluidAudio is public, so **Deny** is correct and the
fetch proceeds anonymously (it logs a harmless
`Failed to find credentials for 'https://github.com' in keychain: status -128`).

### tools/whisper-transcriber — caption panel, Whisper engines

| Dependency | Source | Version | Licence |
| --- | --- | --- | --- |
| WhisperKit | `github.com/argmaxinc/WhisperKit` | 0.9.0+ | MIT |

**Not built by default.** WhisperKit's dependency tree and model sizes are much
larger than Parakeet's, and the caption panel is a separate feature from the
transcript panel, so it is opt-in:

```sh
./Scripts/build-transcribers.sh --all      # or --only whisper-transcriber
```

Its version is still declared as `from: "0.9.0"`, which floats. If you enable
it, pin it and commit its `Package.resolved` the way Parakeet's is, or it will
eventually break the same way.

## Vendored, not downloaded

| What | Where | Licence |
| --- | --- | --- |
| Lua 5.4.7 | `vendor/lua-5.4.7/` | MIT |

Checked into the repo and compiled from source. Nothing is fetched for it.

---

## Runtime

Downloaded by the helper CLIs on the **first transcription only**, never during
installation. All are CoreML conversions hosted on HuggingFace.

| Model | Source | Size | When |
| --- | --- | --- | --- |
| Parakeet TDT 0.6B v3 | `huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml` | ~475 MB | default transcript engine |
| Parakeet TDT 0.6B v2 | `huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml` | ~475 MB | only if you select v2 |
| Speaker diarization | `huggingface.co/FluidInference/speaker-diarization-coreml` | ~100 MB | only with speaker detection on |
| Whisper large-v3 / turbo | HuggingFace, via WhisperKit | ~800 MB–1.5 GB | only if you use a caption engine |

Transcription itself runs entirely on-device. The download is the only network
access; no audio, transcript or project data leaves the machine.

### Where it all lives

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/FluidAudio/Models/` | Parakeet + diarization models |
| `~/Library/Application Support/SpliceKit/tools/` | the built helper binaries |
| `<patched FCP>.app/.../SpliceKit.framework/Versions/A/Resources/` | the same binaries, travelling with the app |
| `build/*-transcriber` | the cached build output re-used across installs |
| `tools/*/.build/` | SwiftPM checkouts and artifacts |

### Removing everything

```sh
rm -rf ~/Library/Application\ Support/FluidAudio          # downloaded models
rm -rf ~/Library/Application\ Support/SpliceKit/tools     # helper binaries
rm -rf tools/*/.build build/*-transcriber                 # build state
```

Final Cut Pro keeps working; the Parakeet and Whisper engines revert to
reporting that they are unavailable. The FCP Native engine needs none of this.

### Updating

Versions are pinned. To take a newer FluidAudio or WhisperKit:

```sh
cd tools/parakeet-transcriber && swift package update
cd ../.. && make transcribers
```

Commit the changed `Package.resolved` so other machines get the same revision.
