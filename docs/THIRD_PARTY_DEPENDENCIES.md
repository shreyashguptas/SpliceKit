# Third-party dependencies

What this fork pulls in from outside, when, and how to remove it.

Everything below is optional: it exists only to make on-device transcription
work. Final Cut Pro itself, the injected dylib, the bridge and the MCP server
have **no** third-party dependencies — they build from the source in this repo
against Apple's own frameworks.

`make install` downloads only what it needs to build and run (Homebrew and
Python if they are missing, the `mcp` package, `insert_dylib`, and the
transcriber packages when a helper needs rebuilding; all listed in the last
section), and nothing phones home. Crash reporting (Sentry),
the patcher's update feed (Sparkle) and its log upload (filebin.net) were
removed from this fork entirely; crashes are logged locally under
`~/Library/Logs/SpliceKit`. The section "What talks to the network" at the end
lists every remaining outbound path and who starts it.

---

## Build time

The small audio helpers (`tools/audio-levels.swift` for `get_audio_levels`,
`tools/silence-detector.swift` for the silence remover) are single files compiled
with the `swiftc` that ships with the Command Line Tools; they use only Apple's
AVFoundation and Accelerate frameworks and fetch nothing. The rest of this section
is about the transcription helpers.

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

---

## What talks to the network

Every code path in this repository that opens a network connection, who
starts each one, and where it goes. There is no analytics, no usage reporting,
no update check and no crash upload anywhere in the tree; this section is what
is left.

### Loopback only (never leaves this Mac)

| Path | Where | Goes to |
| --- | --- | --- |
| JSON-RPC bridge inside Final Cut Pro | `Sources/SpliceKitServer.m` (`INADDR_LOOPBACK`) | listens on 127.0.0.1:9876 only |
| MCP server, `Scripts/splicekit_client.py`, `tools/splicekit-watchdog.py`, `tools/fcp_runtime_export.py`, the mixer app, the Loupedeck haptics plugin | `mcp/server.py` and the named files, `Plugins/LogiHaptics/.../FCPHapticsPlugin.cs` | connect to 127.0.0.1:9876; the MCP server refuses a non-loopback `SPLICEKIT_HOST` unless `SPLICEKIT_ALLOW_REMOTE=1` |
| Command palette helper scripts | the Swift helper that the Apple Intelligence engines spawn, and the Gemma engine's port probe | 127.0.0.1:9876 and 127.0.0.1:8080 |
| Test suites | `tests/` | a fake bridge on 127.0.0.1 |

### Only when you start it inside Final Cut Pro

| Feature | What happens | Goes to |
| --- | --- | --- |
| Transcript / caption panels, Parakeet or Whisper engine | model download on first use (table above); recognition is on-device | huggingface.co |
| Transcript panel, Apple Speech engine | `SFSpeechRecognizer` with `requiresOnDeviceRecognition = YES` set on every request (`Sources/SpliceKitTranscriptPanel.m`), so recognition stays on this Mac where macOS supports it | Apple framework, on-device |
| Command palette, Apple Intelligence engines (the default) | Apple's FoundationModels framework (Apple's on-device model); SpliceKit adds no network call of its own beyond the loopback bridge | Apple frameworks |
| Command palette, "Gemma 4" engine | talks to an `mlx_lm.server` on this Mac at http://localhost:8080; if `mlx-lm` is missing it runs `pip install mlx-lm`, and the server downloads the model (`unsloth/gemma-4-E4B-it-UD-MLX-4bit` unless `SpliceKitGemmaModel` says otherwise) on first start; selecting the engine and sending a query is the consent, there is no second prompt | PyPI, huggingface.co, then loopback |
| URL import | downloads the URL you pasted: direct media links with `NSURLSession`, YouTube/Vimeo through `yt-dlp` and `ffmpeg` found on PATH (or `SPLICEKIT_YTDLP_PATH` / `SPLICEKIT_FFMPEG_PATH`); `make url-import-tools` only symlinks binaries already on PATH and prints a `brew install` hint otherwise; it downloads nothing | the site you gave it |

### Only during installation (`make install`)

Homebrew and Python sit behind a yes/no prompt; `Scripts/install.sh` answers
yes for you with `--yes`, or when it is not run from a terminal (a pipe, CI).
The other rows have no prompt of their own: they run when what they fetch is
missing, as part of the one-command install.

| Step | Command | Goes to |
| --- | --- | --- |
| Homebrew, if missing (prompted) | `Scripts/install.sh` | raw.githubusercontent.com (Homebrew's installer), then Homebrew's own mirrors |
| Python 3.10+, if missing (prompted) | `brew install python@3.13` | Homebrew |
| MCP virtualenv, on first install | `make mcp-setup`: `pip install -r mcp/requirements.txt` | PyPI |
| `insert_dylib`, if not already built | `patcher/patch_fcp.sh` (`git clone`), GUI patcher (`curl`) | github.com/tyilo/insert_dylib |
| Transcriber helpers, if they need rebuilding | SwiftPM (tables above) | github.com (FluidAudio, WhisperKit) |
| Optional OTIO tools | `pip install opentimelineio ...`, only if you run it | PyPI |

### Links that open your browser

The patcher's "SpliceKit Help" menu item opens `https://splicekit.fcp.cafe/installation/`
when you click it. Nothing is fetched until then.

### What is deliberately not here

Removed from this fork, with their configuration and call sites: the Sentry
SDK and its stubs (dylib and patcher), the Sparkle update feed (`SUFeedURL`,
`appcast.xml`, "Check for Updates"), the patcher's "Share Logs" upload to
filebin.net, and `release.sh` (dSYM upload, feed signing). The GitHub Pages
site under `docs/` has no analytics script.
