# Changelog

All notable user-facing changes to SpliceKit. This fork has no release feed
and no auto-update: build from the repository with `make install`, and update
by pulling it. Entries below the fork point describe upstream releases as they
shipped and mention features (Sparkle updates, Sentry reporting, log upload)
that this fork has removed.

## [Unreleased]

### Added
- **`get_audio_levels`: the audio of the timeline as numbers and a picture.** For one
  clip (its primary-storyline neighbours come along, summary only, so the cuts on both
  sides are compared), a list of clips, a time range or the whole timeline (first 100
  clips with audio), the peak and RMS level per slice (50 ms by default; longer for long
  clips) in dBFS, placed in timeline seconds, with the silence at each clip's start and
  end, the slices at full scale, the loudest moment, the first and last 100 ms, a
  sparkline per clip, a waveform strip returned as inline MCP image content, and for
  neighbouring primary-storyline clips that were both analysed the level jump at the cut
  (or the transition on the cut, under which FCP crossfades attached audio). The decoding
  runs in a new helper, `tools/audio-levels.swift` (AVFoundation audio decoding inside
  Final Cut Pro's process deadlocks), streaming so memory stays flat on long clips, built
  and ad-hoc signed by `make install` (patcher step 3c, which now also builds the silence
  detector the command palette's silence remover needs) and looked up in the patched
  app's SpliceKit.framework/Resources first. The bridge RPC is `timeline.getAudioLevels`;
  the clip-to-source-file mapping is the one `get_clip_info` reports. These are
  SpliceKit's measurements of the source media as decoded, not FCP's meters or
  waveforms: FCP's volume, fades, effects, retiming and the mix are not applied, and the
  answer says so. First run against a live Final Cut Pro: QA run 2 on FCP 12.3 (see Fixed below);
  `tests/live_timeline_reads_check.py --audio-check` re-runs it.
- **`add_clip_to_timeline`: a range of a browser clip onto the timeline.** The
  range (`start_seconds`/`end_seconds` from the clip's first frame) is written
  to FCP's pasteboard and placed with FCP's Edit > Paste (insert, the effect of
  W) or Paste as Connected Clip (connect, the effect of Q) at the playhead
  (`at_seconds` moves it first; for these two this is FCP's three-point edit),
  or appended at the end of the primary storyline (the effect of E); connect
  can be backtimed (Shift-Q); `dry_run` resolves without editing. The bridge
  (`browser.placeClip`) re-reads the timeline before and after (by object
  identity, so the 2000-handle table limit cannot fool it) and reports the
  placed clip, whether the range was honored and whether it landed where
  asked, within two frames (at least 50 ms), plus anything else the edit
  created. No overwrite: FCP has no paste that overwrites. Not yet run
  against a live Final Cut Pro; `tests/live_timeline_reads_check.py
  --place-check` does that. The legacy `browser.appendClip` / `insertClip` /
  `connectClip` answers keep `clip` as the name and gain the same report
  (`placementVerified` is now a real check). The server's instructions are now
  a task-organized map of the editing tools (developer/debug families are left
  out on purpose).

### Changed
- **The MCP server now runs on the official MCP Python SDK 2.x** (`mcp>=2.2,<3`,
  `MCPServer`), which implements the current stable protocol revision
  2026-07-28. Older clients that still use the legacy `initialize` handshake
  connect exactly as before. Tool annotations are built as the SDK's
  `ToolAnnotations` model, and the server reports SpliceKit's version to the
  client. An unexpected exception inside a tool now reaches the client as a
  `ToolError` carrying the exception text, instead of the SDK's bare
  "Error executing tool" message.
- **`make install` verifies the whole chain before it reports success.** The
  MCP server is started as a stdio subprocess and driven with the official SDK
  (`tests/mcp_server_check.py`): both connect modes, every tool, resource and
  prompt against a stand-in bridge; then the patched Final Cut Pro is opened
  and read from through the same server. New targets: `make mcp-check`,
  `make mcp-check-live`; new install flag `--no-launch`; the patcher gained
  `--yes` and leaves the MCP config to `make install`
  (`SPLICEKIT_SKIP_MCP_CONFIG=1`). `make install` now finds a Homebrew
  keg-only Python, treats a running Claude Desktop (config not written) as
  an unfinished install, and no longer swallows Ctrl-C after a menu.

### Fixed
- **The retime note called a variable-frame-rate file's average rate its nominal rate** (QA run
  4: a 30 fps screen recording with dropped frames, averaging 29.74 fps, was reported as
  "nominally 29.740 fps"). `AVAssetTrack.nominalFrameRate` is frame count over duration. The
  helper now also reads the rate the track's shortest frame duration corresponds to
  (`minFrameDuration`; not reported above 240 fps) and answers both as what they are
  (`videoFrameRateAverage`, `videoFrameRateShortest`; `videoFrameRate` stays the average); the
  note names both, calls a file whose readings differ a variable-frame-rate recording, asserts
  FCP's Rate Conform only when both differ from the project's rate and says the question is open
  when they straddle it (a 29.97 fps file in a 600-tick timescale reads 30.000 by its shortest
  frame). Not yet re-run against that file.
- **`list_menus(validate=True)` did not resolve the Edit > Undo title, and reported the item
  disabled while an undoable step existed** (QA run 4): AppKit resolves Undo / Redo through the
  key window, and with Final Cut Pro in the background, the state SpliceKit is normally driven
  in, validation leaves them "Undo" / "Redo" and disabled. `menu.list` now also returns
  `undoState` (canUndo / canRedo and the action names, read from the library document's undo
  manager, which is what Edit > Undo and `history_action` act on) for the Edit menu or the whole
  menu bar, and a `note` that action names resolve in the title regardless of focus while enabled
  states follow the key window. Measured on 12.3 with FCP not frontmost: title reads e.g. Undo Trim,
  disabled.
- **Window captures reported success on a one-colour image** (QA run 4: Viewer chrome around
  black gap content fooled the first flat test). `viewer.capture`, `timeline.capture`,
  `inspector.capture` and `timeline.captureClipFrame` now test the captured image for a single
  flat colour (32×32 downscale, uniform border trimmed per edge, inner pixels within 2/255) and
  answer `flat`, `flatColor` and a `warning`; the status stays ok because a flat frame can be real
  (a black frame). The MCP tools print the warning; the live check says the frame is not verified.
- **The dialog summary picked up a popup's value as a field** (QA run 4: "Compound Clip Name: /
  Library: / Item 1"): labels ending in a colon are taken first now, other text only when fewer
  than two of those exist.
- **`get_clip_info` invented a source media file for a compound clip** (QA run 3, the surviving
  half of run 2's compound-clip bug): for a compound clip on the timeline (FCP: reference clip,
  its `isReferenceClip` flag; a multicam or synchronized clip answers the same flag) it named the
  first media file found inside, read the compound's
  own inner range as that file's start timecode, and decoded frames from it, which at some times
  showed footage the Viewer never plays there. The bridge now applies the same
  `isCompoundClip` / `isReferenceClip` reading `get_audio_levels` uses (plus the nested-source
  depth check): such a clip reports `containerKind`, no `sourceMedia`, no start point and no
  frame, with a `sourceMediaError` / `frameError` saying why and pointing at
  `capture_clip_frame`. Connected clips now carry the same `isReferenceClip` / `isCompound`
  flags as spine items, `get_timeline_clips` marks them `[reference clip]` / `[compound clip]`
  in its text with a one-line legend, and `tests/live_timeline_reads_check.py --clip-info-check`
  now picks an ordinary clip first, checks a second frame at 80% into it (the requested time, the
  file time and the decoder's actual time must agree) and fails when a container clip is given a
  source file or a media-file frame.
- **`get_audio_levels` read 3 dB high on dual-mono files** (QA run 3: every figure exactly
  +3.0 dB above ffmpeg's volumedetect on three files; a file whose true peak is -2.9 dBFS would
  have been counted as at full scale). The helper decoded a mono mixdown; an exact +3.0 dB is
  what a power-preserving mixdown gives for two channels carrying the same signal. The helper
  (`tools/audio-levels.swift`) now decodes up to eight audio tracks, each at its own channel
  count, and pools the channels: a slice's peak is the loudest sample in any channel and its RMS
  is over all channels' samples, by construction the figures volumedetect gives for the same range
  of a file with one audio track (not yet re-measured against ffmpeg on a Mac) (`channelsMode:
  "pooled"`; several audio tracks are pooled, each weighted by its channels). On ordinary stereo
  files the peak now reads the true per-channel maximum, up to 3 dB above the old mixdown's peak
  where the two channels' peaks do not coincide, so full-scale counts can rise there; the RMS is
  unchanged. The mono mixdown remains only as the fallback when no track decodes that way, is
  named `mixdownMono` in the answer with its +3 dB caveat, and the header now says how channels
  are treated. `channels="separate"` now reports each channel of the first track (up to eight,
  no longer two) with its own peak max, RMS mean and full-scale count next to the pooled line;
  the QA report's "summary line missing in separate mode" could not be reproduced offline (the
  renderer prints it unconditionally), so this round adds the per-channel figures instead.
- **`get_audio_levels` can now say when a frame-rate conform explains the retime flag.** The
  helper reports the media file's video frame rate; when FCP's `isRetimed` is true and that rate
  differs from the project's, the note says the file is rate-conformed (FCP's Rate Conform),
  that a conform on its own was seen to set the flag (QA run 3) and that FCP's conform keeps the
  mapping, and that a speed change on top of it cannot be told apart; when the rates match, that
  a conform is unlikely to be the reason and the clip is most likely retimed. QA run 3
  established the case: a 30 fps, variable-frame-rate .mp4 screen recording in a 29.97 fps project answered
  `isRetimed` = true at 100% speed, both 29.97 fps .mov files answered false (QA run 4: that
  .mp4 is a variable-frame-rate recording averaging 29.74 fps; see above).
- **A trim inside a `begin_edit` group logged no `[Trim]` line** (QA run 3); one line per trim
  now, naming the group, its own closed undo step, or why none could be opened.
- **The pending-dialog note named the Compound Clip Name sheet "Window"** (QA run 3): AppKit's
  placeholder title. `detect_dialog` and the `dialogPending` note now carry a `summary` built
  from the sheet's field labels ("sheet with the fields Compound Clip Name: / In Event: /
  Starting Timecode:") when the title is a placeholder.
- **`list_menus` could not show a validated title such as Edit > "Undo Trim"** (QA run 3): it
  read the static titles. `list_menus(validate=True)` (RPC `menu.list` `validate`) now runs
  each listed menu's validation first, what AppKit does when the menu opens, so titles set on
  validation and the enabled states are current. Off by default. QA run 4: with Final Cut Pro in
  the background this does not resolve Undo / Redo (see the run-4 entry above).
- **`get_audio_levels` skipped every clip whose media file carries a start timecode** ("the
  clip lies entirely before the start of its media file"; QA run 2: three of five clips, the
  ones with audio). The clip's start point in its source media was read from
  `trimStartTime` / `trimmedOffset`, which FCP 12.3's clips do not answer, and the media's
  timecode origin (`unclippedRange.start`, tens of thousands of seconds for a camera file)
  was then subtracted from a zero that had never been read. The start point now comes from
  the clip's `clippedRange` (the reading the transcript panel's clip-to-file conversion has
  always used), then the older selectors; when none answers, the levels start at the file's
  start and the answer says so instead of subtracting anything; a helper "empty range" is
  reported as a mapping that does not fit, naming the readings. `get_clip_info` reads the
  start point the same way.
- **`trim_clip` could not be undone** ("Cannot undo - nothing to undo"): `operationTrimEdit`
  changed the model without an undoable action. The trim is now one undo step, "Trim",
  opened and closed with the same `actionBegin:` / `actionEnd:save:error:` pair
  `begin_edit` uses (inside an open `begin_edit` group, that group's step covers it); the
  answer names the step. The live check restores the edge with a compensating trim when
  an undo fails, instead of leaving the timeline changed.
- **A compound clip was not detected and was analysed against the wrong file.** On the
  timeline a compound clip is an `FFAnchoredClip` that answers `isReferenceClip` = YES
  (verified on 12.3; an ordinary clip's `FFAnchoredCollection` answers NO to both
  `isCompoundClip` and `isReferenceClip`). Both flags are asked now: `isCompoundClip` gives
  `kind: compound clip`, `isReferenceClip` alone gives `kind: reference clip` (a compound,
  multicam or synchronized clip stands in for an event clip the same way, so it is not
  called a compound clip); `get_timeline_clips` carries `isCompound` or `isReferenceClip`,
  and `get_audio_levels` skips both. Independently, it skips any clip whose first media
  component was found two or more containers down, since nothing says which part of the
  clip that file is.
- **`timeline_action` said "ok" while Final Cut Pro was waiting on a sheet** (QA run 2:
  `createCompoundClip` and its Compound Clip Name sheet). The answer now carries
  `dialogPending`, the dialog's description and a note pointing at `detect_dialog` /
  `click_dialog_button` / `dismiss_dialog` when a sheet or modal dialog is open after the
  action. The check runs at the RPC entry only, so batch actions, `blade_at_times`, the
  command palette and Lua, which run actions in loops, are unaffected.
- **`add_clip_to_timeline` reported `status: ok` with nothing placed.** An edit after which
  no new clip appears is an error now (the pasteboard replacement and playhead move are
  reported with it). A project (FCP's `isProject`), including the open timeline's own, is
  refused as a source, and `browser_list_clips` marks projects with `isProject: true`.
- **`select_clip_in_lane`'s `candidatesInLane` counted only the clips before the match**;
  it counts the whole lane.
- **End times were truncated when a clip started at time zero**: `start + duration` was
  formed by integer division in the start's timescale (timescale 1 at zero), so an
  18.018 s clip ended at 18.000 s in `get_timeline_clips` and `get_audio_levels` while
  `get_clip_info` said 18.018 s. The sum is now exact when one timescale is a multiple of the
  other and rounded otherwise, in every reader.
- **The "retimed clip" note overstated what is known.** FCP's `isRetimed` flag was true on
  two clips whose file range mapped 1:1; the flag may also cover a frame-rate conform.
  The note and the tool text now say which flag answered and that SpliceKit cannot tell a
  speed change from a conform.
- **The log said nothing useful about any of this.** `~/Library/Logs/SpliceKit/splicekit.log`
  now records each clip `get_audio_levels` skips, with its reason, and each helper run
  (file, range, time), the undo step a trim opened, a placement after which nothing
  appeared, and a dialog left open by an action.
- **Ordinary clips were classified as compound clips.** Final Cut Pro wraps every clip
  that carries both video and audio in an `FFAnchoredCollection`, and SpliceKit read that
  class name as "compound clip": `get_clip_info` said `kind: compound clip` for camera
  footage, `get_audio_levels` skipped every such clip ("no single source media file") and
  analysed nothing on an ordinary timeline, `trim_clip` refused them, and
  `get_timeline_clips` flagged them `isCompound`. FCP's own `isCompoundClip` flag is asked
  now (FCP 12.3's FFAnchoredCollection answers it: false for those clips, per the QA run on
  a Mac); a multicam flag, when one answers, gives `kind: multicam clip`, skipped by
  `get_audio_levels` the same way. `trim_clip` refuses transitions and storylines (primary
  or connected) only.
- **`tools/audio-levels.swift` did not compile with Swift 6.4** (`as? CMFormatDescription`
  is an error there: "conditional downcast to CoreFoundation type will always succeed"), so
  `make install` produced a patched app without the helper and `get_audio_levels` always
  reported it missing. The cast compares the CF type ID now; that form was compiled and run
  under Swift 6.4 on macOS 27 in the QA session (192 kHz mono, stereo per channel, a 186 s
  file in 0.18 s at 23 MB).
- **`make install` hid that failure behind "Verified on this Mac".** It now checks the
  patched framework for `audio-levels` and `silence-detector`, names any missing one in the
  final banner and exits non-zero; patcher step 3c prints the compiler output. `make
  install-check` reports the helpers and exits non-zero when the app is not patched, a
  helper is missing, the MCP virtualenv is missing or stale, or the live read fails; it
  used to run the live check against a stale virtualenv, print a traceback and exit 0.
- **`add_clip_to_timeline` by `name` or `index` never found a clip** ("Clip not found"):
  the lookup asked events for `ownedClips`, which FCP 12.3 does not answer as an array. It
  now walks the same `displayOwnedClips` listing `browser_list_clips` shows, so `index` is
  that listing's index, and the error says what was searched. It also accepted the handle
  of a clip already on the timeline and appended a copy of it; such handles are refused,
  with FCP's copy and paste named as the way to repeat a timeline clip.
- **`select_clip_in_lane` found no connected clips** ("0 candidates in that lane"): it read
  each spine clip's `anchoredItems` as an NSArray, which FCP does not hand back for every
  clip. Candidates now come from the same walk `get_timeline_clips` reports (lane relative
  to the primary storyline, absolute range, nested clips included), the selection goes
  through the path `select_clips` uses, and the answer carries the clip's range and whether
  it is selected.
- **`import_media(event=...)` failed for every event name** ("No event found"): the lookup
  asked `FFEventRecord` for `name`; it answers `displayName`, the name the browser shows.
  The error now names the event that was asked for.
- **`bridge_status` reported the Mac's uptime as `process_uptime_seconds`** (it read
  `systemUptime`) and a stale version, 3.1.148: the patcher's own clang compile passed no
  `-DSPLICEKIT_VERSION`, so the header's fallback won. Uptime now counts from SpliceKit's
  load into the process (at launch), the patcher passes the version from
  `Version.xcconfig`, and the header fallback reads "unversioned" instead of a number.
- **`tests/live_timeline_reads_check.py` misread refusals**: a JSON-RPC error object was
  tested as if it were a string, so `--place-check` failed on a correct refusal and
  `--audio-check` could not recognise "helper not found". Errors are reduced to their
  message before the checks see them.
- **`Scripts/launch.sh` looked for the patched app under `~/Applications/SpliceKit`**, where
  older patchers put it; `make install` installs "Final Cut Pro Modified.app" in
  `/Applications`, which it checks first now.
- **Bridge round trips are serialized.** The 2.x SDK runs synchronous tools in
  worker threads, so two tool calls can overlap; the shared socket to the bridge
  is now guarded by a lock so responses cannot be mixed up between them.
- **`batch_color_correct` and `batch_apply_effect` with `clip_count=0` are
  bounded at 1000 clips** instead of looping until the bridge reports an error.
- **Startup no longer waits on a busy Final Cut Pro.** The import-time plugin
  probe uses a 2 s timeout (the bridge connect timeout is now 5 s, reads 30 s),
  so the MCP handshake is not held up by a main thread stuck in a dialog.
  `reload_plugin_tools` no longer re-registers tools it already added, and the
  bridge socket is closed at exit. `SPLICEKIT_HOST` other than loopback is
  refused unless `SPLICEKIT_ALLOW_REMOTE=1`.

### Removed
- **Every remaining path that could send data off this Mac, except the user's
  own actions.** The dylib's Sentry stubs and their call sites (breadcrumbs,
  launch phases, RPC exception capture), the patcher's Sentry SDK and Sparkle
  auto-update packages, the "Check for Updates" command, the "Share Logs"
  button (which uploaded the latest FCP crash report and SpliceKit logs to
  filebin.net), the `SUFeedURL` / `SUPublicEDKey` / `SUEnableAutomaticChecks`
  keys, the `appcast.xml` feed and the `release.sh` script (Sentry dSYM upload,
  Sparkle signing, GitHub release) are gone. Crash handling is the local
  NSException/signal logger writing under `~/Library/Logs/SpliceKit`. What
  still talks to the network is listed in `docs/THIRD_PARTY_DEPENDENCIES.md`:
  the loopback bridge, the Vision Pro preview on the local network, and
  downloads the user starts (URL import, transcriber and Gemma models, the
  `mcp` and `mlx-lm` packages from PyPI, install-time Homebrew/Python and
  `insert_dylib`).

## [3.3.9] — 2026-08-29

### Added
- **LiveCam now shows a live dBFS audio monitor directly below the microphone
  selector.** The larger color-coded meter includes a numerical peak readout,
  peak-hold marker, headroom scale, and a held clipping warning.
- **Optional Logitech MX Master 4 haptic feedback is now supported through the
  included Logi Options+ plugin source.** SpliceKit emits typed events for FCP's
  native haptics as well as clip and playhead snapping, with editable waveform
  mappings for the mouse.

### Changed
- **LiveCam's green-screen pipeline now remains bounded during long sessions.**
  Mask history uses materialized pooled buffers, adaptive inference timing, and
  the selected capture resolution instead of accumulating lazy image graphs or
  silently falling back to a larger camera format.
- **Smooth Scroll now animates FCP's native playhead at display refresh.** It
  reuses one display link, hands the first frame off cleanly, and safely restores
  FCP's scrolling behavior after interactions or when the feature is disabled.

### Fixed
- **LiveCam recordings no longer force mono USB microphones through a fixed
  stereo writer format.** Audio encoding now follows AVFoundation's
  session-aware recommendation, preserves the microphone's native capture
  format, and runs callbacks on an audio-priority queue. This removes the
  Shure MVX2U's unnecessary real-time mono-to-stereo conversion and protects
  capture from 4K video pressure. LiveCam status and logs now also report the
  source sample rate, channel count, and any source-timestamp discontinuities
  separately from writer back-pressure drops.
- **The LiveCam audio monitor now decodes each Core Media buffer using its live
  channel layout and buffer count.** This fixes the meter appearing correctly
  but remaining frozen with microphones that supply a variable-sized
  `AudioBufferList`.
- **Smooth Scroll now handles duplicate playback notifications and FCP 12.3's
  anchored timeline state correctly.** Native scrolling is reliably restored
  when playback ends, a user interacts with the timeline, or the timeline is
  torn down.

## [3.3.2] — 2026-04-21

### Changed
- **SpliceKit is now authoritative for BRAW playback even when third-party
  Media Extensions are installed.** Apple prioritises Media Extension
  video decoders (e.g. BRAW Toolbox's Decoder.appex) over legacy
  in-process VT registrations. SpliceKit now overrides four
  `FFMediaExtensionManager` predicates so FCP's Media Extension routing
  consistently sees the in-process VT decoder as authoritative for the
  six BRAW FourCCs (`braw`, `brxq`, `brst`, `brvn`, `brs2`, `brxh`):
  - `copyDecoderInfo:` returns nil — Media Extension lookup misses,
    decoder selection falls through to `VTRegisterVideoDecoder`'s
    in-process registry where `SpliceKitBRAW_registerInProcessDecoder`
    has bound all six variants to `SpliceKitBRAWInProcess_CreateInstance`.
  - `copyProcessorInfo:` returns nil — same routing intent for the RAW
    processor side (SpliceKit handles BRAW RAW adjustments in-process
    via the `FFSourceVideoFig.setRAWAdjustmentInfo:` hook in
    `SpliceKitBRAWRAW.mm`; we don't want a third-party RAW processor
    inserted into the pipeline).
  - `isAppExclusiveDecoder:` returns YES — signals "the in-app decoder
    is exclusive for this codec, skip Media Extension lookup".
  - `isDecoderUsingMediaExtension:` returns NO — callers that gate on
    this predicate (cache invalidation, Inspector display,
    asset-rep-provider selection) believe FCP is using the in-process
    path even when a third-party Media Extension is registered for the
    codec.

  Other codecs are still routed to whichever Media Extension claims
  them (Sony Raw via nablet, AVI/MKV via QLVideo, etc.). The first
  redirect for each FourCC logs one line so it's visible at startup;
  subsequent calls are silent.

  Known limitation: this only changes decoder/processor selection.
  Format reader selection (the .braw container parser) lives below FCP
  in `mediaextensiond` and is not yet redirected — Apple resolves
  format readers by UTI lookup before the asset reaches `FFAsset`, so
  if BRAW Toolbox's `FormatReader.appex` is installed it can still win
  that lookup. Disabling its format reader requires either OS-level
  `pluginkit -e ignore` (heavy-handed; affects all apps) or shipping
  SpliceKit's own format reader as a competing Media Extension; both
  are tracked separately.

### Fixed
- **Crash in FCP's thumbnail manager when an installed Media Extension
  returns nil for a VTExtensionProperties key.** FCP's thumbnail dispatch
  thread calls `-[FFMediaExtensionManager copyDecoderInfo:]`, which calls
  Apple's `VTCopyVideoDecoderExtensionProperties`. That function builds a
  CFDictionary of six required keys (extension identifier, name, URL, host
  bundle name, host bundle URL, codec name) by querying the matched
  Media Extension. If any value resolves to nil — for example, an
  extension whose `CodecInfo` array does not declare an entry for the
  FourCC the format description carries — VT calls
  `__setObject:forKey:` with nil and `__NSDictionaryM` raises
  `NSInvalidArgumentException`. The exception unwinds to FCP's uncaught
  handler and abort()s the process. SpliceKit now wraps non-BRAW codec
  lookups in a `@try`/`@catch` that swallows that one specific exception
  (matched on `__setObject:forKey:` + `object cannot be nil` reason text)
  and returns nil, mirroring the `kVTCouldNotFindExtensionErr` path that
  FCP already handles cleanly. Any other exception is re-raised so we
  don't hide unrelated bugs. (BRAW codecs avoid the original method
  entirely under the routing change above, so they can't reach the
  crash.) First catch logs in full; subsequent catches throttle to one
  log line per minute with a running count.
- **LiveCam camera/microphone access is restored.** Re-signing Final Cut
  Pro with `--entitlements` replaces Apple's full entitlement set on the
  bundle, which stripped `com.apple.security.device.camera`,
  `com.apple.security.device.microphone`, and
  `com.apple.security.device.audio-input` so LiveCam's "Allow Camera"
  button did nothing and TCC silently denied every request. The patcher
  now injects the three device entitlements into every codesign invocation
  (BRAW plugin bundles, framework, app bundle) and signs with
  `--options runtime` so the hardened runtime is engaged. The modded
  app's `Info.plist` also gains `NSCameraUsageDescription` and
  `NSMicrophoneUsageDescription` so TCC has a consent string to show.
- **Final Cut Pro is now launched via `NSWorkspace.openApplication`
  instead of `Process()`.** macOS TCC tracks a "responsible process" for
  privacy decisions; spawning FCP through fork+exec from the patcher made
  the patcher the responsible process for all of FCP's subsequent
  camera/mic requests, so tccd checked the patcher's entitlements and
  declined. Routing through LaunchServices makes FCP its own top-level
  process and lets TCC evaluate FCP's own entitlements.
- **Patcher install + update now strip extended attributes immediately
  before each `codesign` invocation.** The initial post-copy sweep can be
  invalidated by the steps in between it and signing (insert_dylib
  rewriting the Mach-O, PlistBuddy edits to `Info.plist`, BRAW bundle
  copies from quarantined sources), which re-attach
  `com.apple.FinderInfo` or resource forks and trigger codesign's
  "resource fork, Finder information, or similar detritus not allowed"
  rejection. The extra strip runs as the first step of the sign shell
  pipeline in both the fresh-install and update paths, on both the
  Developer ID and ad-hoc fallback attempts.
- **"Launch FCP" now surfaces a clear error when the modded bundle is
  missing.** `canLaunchFCP` only inspects patcher state (not patching,
  not already launching, not running); it does not verify the bundle is
  still on disk. If the user deleted the modded app or the patch never
  completed, `NSWorkspace.openApplication` surfaced this as a raw
  `NSCocoaErrorDomain Code 4` Sentry event with no actionable guidance.
  A `FileManager.fileExists` pre-flight at the top of `launch()` now
  catches this case and writes a clear "run the patch again" message to
  the patcher log instead.
- **Build fails fast on undefined `SpliceKit_` symbols.** The dylib was
  built with `-undefined dynamic_lookup`, so missing implementation files
  were never caught at link time — they only surfaced in production as
  `PC=0x0` crashes inside `safeInstall` blocks at launch. The build
  system now scans `nm -u build/SpliceKit` for any unresolved
  `_SpliceKit_*` symbol and fails the build if one is present. Three
  latent crash sites that would have triggered this were fixed in the
  same pass.

## [3.2.10] — 2026-04-20

### Fixed
- **Crash on first install of the overview bar.** Two call sites were
  hitting the FFAnchoredCollectionImageCreation renderer synchronously
  before the child panel had finished attaching and the active sequence
  had finished becoming current, so the renderer occasionally landed on
  a half-built graph and crashed. Both paths now go through a single
  `scheduleInitialRerender` helper that defers the invalidate + rerender
  via `performSelector:afterDelay:`, so the first paint always lands
  after the run-loop turn where the collection is actually renderable.
- **Smooth Scroll now respects the Continuous Scrolling preference.** The
  gate that decided whether to engage the 120 Hz centered-scroll takeover
  was reading `keepsPlayheadCenteredDuringPlayback` on TLKScrollingTimeline
  — which reads correct by name but is actually a rate-derived computed
  value set only during fast-forward / rewind (and always off at the
  default playback rate of 1.0). Swapped the gate over to the real
  user-facing `scrollDuringPlayback` flag on TLKTimelineView
  (backed by the `FFScrollDuringPlaybackKey` NSUserDefaults key and
  pushed into the view from
  `-[FFAnchoredTimelineModule updateTimelineScrollDuringPlaybackToMatchUserDefaults]`).
  Now:
  - Continuous Scrolling ON → Apple's step-based centering is paused
    and our display-link-driven scroll is authoritative, so the
    timeline content slides continuously under a stationary playhead.
  - Continuous Scrolling OFF → we leave Apple's native edge-tracking
    alone and just draw the smooth 120 Hz playhead line on top, so the
    playhead slides smoothly across the viewport until it reaches the
    side threshold and FCP's autoscroller takes over.

## [3.2.09] — 2026-04-20

### Added
- **Smooth Scroll** — a new master toggle in the Splices menu (on by
  default) that replaces Final Cut's 24/30 Hz playback-centering step
  scroll with a proper 120 Hz display-link-driven path. The clip view
  follows the playhead continuously instead of hopping sideways once per
  source frame; on a ProMotion display the timeline content now actually
  slides smoothly under a stationary playhead line during centered
  playback. Toggle from *Splices → Smooth Scroll*, or via the
  `timelinePerformanceMode` bridge option. Three sub-features are
  individually exposed as bridge options for A/B:
  - `timelinePlayheadOverlay` — draws a cosmetic playhead line at the
    display refresh rate by extrapolating
    `-[TLKTimelineView _setPlayheadTime_NoKVO:animate:]` samples forward
    via `-[TLKTimelineView locationRangeForTime:]`, and pauses
    `TLKScrollingTimeline` during playback so Apple's step-scroll doesn't
    fight our smooth path. Clip view bounds are updated directly via
    `setBoundsOrigin:` + `reflectScrolledClipView:` on every tick, with a
    safety gate that falls back to overlay-only if the clip-view or
    time-to-x mapping can't be resolved. Apple's real playhead layer is
    hidden during playback so only one line is visible.
  - `timelineInteractionSuspend` — observes
    `TLKEventHandlerDid{Start,Stop}TrackingNotification` (marquee-zoom,
    scroll-bar drag, range drag) and swizzles
    `-[TLKTimelineHandler magnifyWithEvent:]` to cover pinch (which runs
    its own inline event loop and never posts tracking notifications).
    While an interaction is active, `setDisableFilmstripLayerUpdates:YES`
    + `setSuspendLayerUpdatesForAnchoredClips:YES` +
    `setMinThumbnailCount:0` are applied so the per-cell
    `FFFilmstripCell` rebuild (which otherwise fails
    `isEquivalentToFilmstripCell:` on every zoom step because
    `timeRange`, `frame.size`, and `audioHeight` all change) goes away;
    one coalesced `_reloadVisibleLayers` runs on tracking end. Prior
    state is saved per-view via an ObjC-boxed associated object (ARC
    frees it when the view deallocs).
  - `tlkOptimizedReload` — swizzles
    `+[TLKUserDefaults optimizedReload]` so the hidden
    `TLKOptimizedReload` flag actually takes effect. Apple's
    `_loadUserDefaults` in current FCP reads `TLKItemLayerContentsOperations`
    and `TLKEnableUpdateFilmstripsForItemComponentFragments` from plist
    but never wires the `optimizedReload` bit to any NSUserDefaults key;
    we override the getter so the optimized ripple-adjustment skip in
    `-[TLKLayoutManager _performHorizontalLayoutForItemsAdded:...]` is
    reachable.

### Fixed
- **MCP bridge no longer gets poisoned by event frames.** The server's
  default for event delivery flipped to opt-in — clients must call
  `events.subscribe` to receive `method:"event"` frames. Previously a
  single-socket JSON-RPC client (like the MCP bridge) could have the
  next tool call consume an unsolicited event as its response and
  permanently desync the socket. The Python bridge client also now
  skips any frame that lacks a matching `id` or that carries a `method`
  field, so stray notifications can't be consumed as responses.
- **Async `command.completed` reports `status:"error"` for normal RPC
  failures**, not only for ObjC exceptions. Clients no longer have to
  peek inside the nested `result` payload to tell whether the command
  succeeded.
- **Per-client socket writes are now atomic AND ordered.** Every
  connected fd has a dedicated serial `dispatch_queue_t`; both RPC
  replies and event broadcasts route through it so bytes can't
  interleave mid-line and events B/C can't overtake event A on the same
  socket. Replaces the earlier mix of `fwrite`/`fflush` on the RPC path
  with raw `write()` on the async path.
- **Timeline overview bar now tears down its notification observers on
  uninstall.** Block-based `addObserverForName:...usingBlock:` returns
  opaque tokens that the previous `removeObserver:bar` call couldn't
  reach; toggling the feature off then back on stacked duplicate
  observers and left hidden rerenders scheduled. Tokens are now
  captured in a single array and released explicitly.
- **`TLKOptimizedReload` toggle no longer sticks permanently off** when
  the first call happens to disable it (the previous `dispatch_once`
  plus early-return ate the one-shot token).

## [3.2.07] — 2026-04-19

### Fixed
- **HEVC MP4s tagged `hev1` now import into Final Cut.** Apple's
  AVFoundation / QuickTime / Final Cut decoder only accepts HEVC when the
  MP4 sample-entry is `hvc1` (parameter sets in extradata); files muxed
  with `hev1` — including most Dolby Vision iTunes rips — played in VLC
  but showed up as unimportable in FCP. The hook extension filter now
  covers `.mp4`/`.m4v`/`.mov` alongside the Matroska family, detects the
  `hev1` tag via AVURLAsset's codec FourCC, and retags the file for
  Final Cut.
- **Zero-duplication fast path for large HEVC retags.** A full
  stream-copy remux of a 19 GB DV rip would have to write out another
  19 GB (and needs the headroom to do it). Instead we use APFS
  `clonefile()` to make an instant COW snapshot, `mmap` the tail 64 MB
  of the clone (where the moov box sits on non-faststart MP4s), find
  the `hev1` sample-entry by its box-size prefix, and overwrite 2 bytes
  in place (`e`→`v`, `v`→`c`). Total extra disk: a single modified
  block (~KB). Total runtime: a few seconds. The original file on disk
  is untouched — only the clone is modified.

## [3.2.06] — 2026-04-19

### Fixed
- **MKV shadow-remux now handles h264, hevc, av1, prores** (and mpeg4 /
  mpeg2video) — the previous pass only covered VP9/VP8, so typical WEB-DL
  releases (h264 + E-AC3 + subrip) failed to import. Audio is handled
  independently: aac/mp3/ac3/eac3/alac/pcm stream-copy, everything else
  transcodes to AAC 192k stereo so the shadow MP4 is guaranteed playable.
- **HEVC Main-10 10-bit MKVs are now decoded in FCP.** Apple's
  AVFoundation/FCP only accepts HEVC with the `hvc1` sample-entry tag;
  ffmpeg defaults to `hev1` from Matroska input, which plays in VLC but
  refuses to open in Final Cut. We force `-tag:v hvc1` on HEVC sources.
- **Subtitle / attachment streams no longer break the remux.** Explicit
  `-map 0:v:0 -map 0:a:0?` replaces `-map 0`, so subrip subtitles (two per
  episode on most WEB releases) and font attachments are dropped instead
  of failing the MP4 mux.
- **B-frame display order survives the CFR timestamp rewrite.** New
  `setts` expression rewrites DTS to a clean `N·frameTicks` grid while
  preserving each packet's source PTS–DTS offset (snapped to whole
  frame-durations). VP9/VP8 behaviour is unchanged (offset term collapses
  to 0); h264/hevc/av1 now keep their B-frame reordering instead of all
  frames collapsing to `pts==dts`.
- **Media Import "Processing files for import…" no longer stalls.** The
  hook short-circuits for any non-`.mkv`/`.webm`/`.mka`/`.mk3d`
  extension (previously it ran ffprobe on every file in the tree — a
  `~/Movies/` with Motion Templates and JDownloader sub-folders meant
  thousands of pointless probes) and uses a deterministic
  `basename.<hash>.mp4` shadow path so re-entering the hook for the same
  source (3–5× per Media Import row) hits the existing shadow instead of
  respawning ffmpeg.

### Changed
- **Menu renamed from "Enhancements" to "Splices"** in Final Cut's menu
  bar. The Debug menu-bar dropdown is no longer installed — the Debug
  prefs pane still rebuilds, just doesn't clutter the menu bar.

## [3.2.05] — 2026-04-18

### Added
- **MKV / WebM imports.** Drop .mkv or .webm files onto Final Cut and SpliceKit
  generates a shadow MP4 remux on the fly. FCP sees a native container; the
  original file stays untouched on disk.
- **Highest Quality toggle for URL imports.** New checkbox in the
  "Import URL to Library" / "Import URL to Timeline" dialog (and a
  `highest_quality` parameter on the MCP `import_url` tool) fetches the highest
  available resolution from YouTube / Vimeo — 1080p, 1440p, or 4K via VP9 / AV1
  — instead of YouTube's 720p progressive-mp4 cap. Leave it off for the fast
  720p path.
- **Share Logs** button in the Patcher status panel — one-click upload of the
  latest Final Cut Pro crash log plus SpliceKit logs to filebin.net, with the
  link copied to the clipboard.

### Fixed
- **URL import FCPXML parse failure** when the downloaded filename contained
  ampersands or other XML-reserved characters (e.g. a YouTube title containing
  "PS5 & PS5 Pro"). `NSURL.absoluteString` leaves `&` literal in file URLs; we
  now XML-escape the `src=` URL before it lands in the generated FCPXML, so
  `FFXMLTranslationTask` accepts it.
- **URL import progress HUD.** Finer-grained updates (~5× more frequent), the
  live percent is embedded in the status text, and the duplicate
  "Downloading YouTube media… 100.0% 72%" readout is gone. Spinner now stays
  vertically centered against the label whether it wraps to one line or two.
- **LiveCam** mask kernel dispatch and shader-coordinate fix resolves
  subject-lift / green-screen edge artifacts on some machines.
- **BRAW** settings inspector locks to a dark appearance to match FCP's other
  inspectors.

### Developer / Setup
- `.mcp.json` now points at the `mcp-setup` venv interpreter, so Claude Desktop
  MCP works without hand-editing Python paths.
- MCP `import_url` tool gained `highest_quality: bool = False` for programmatic
  access to the new quality toggle.

---

## Older releases

For full notes on prior releases, see the
[GitHub Releases page](https://github.com/elliotttate/SpliceKit/releases).
Highlights:

- **v3.2.04** — LiveCam: native webcam booth with subject-lift green screen and
  ProRes 4444 alpha capture.
- **v3.2.03** — URL import workflow for direct media and YouTube VOD URLs
  (Command Palette, Lua, MCP).
- **v3.2.02** — Fixed jerky Effects-browser sidebar scroll on installs with
  many effects.
- **v3.2.01** — Native Blackmagic BRAW color grading (Gamma, Gamut, ISO,
  tone curve, LUT, etc.) with in-process decoder.
- **v3.1.151** — Ship BRAW plugin bundles in the patcher so BRAW works on
  fresh installs.
- **v3.1.150** — Serialize BRAW ReleaseClip through the work queue to fix a
  tear-down crash.
- **v3.1.149** — Native Blackmagic RAW playback in FCP via the BRAW SDK.
