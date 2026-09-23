# Social Media Captions

Word-by-word highlighted, animated caption titles (the style of TikTok / Reels captions),
built from a transcript of the timeline and placed on it as connected Motion titles. For FCP's
own caption objects (editable in FCP's caption editor, exportable as ITT/SRT/SCC) use
`generate_native_captions()` instead; both are listed in
[mcp-tools.md](../reference/mcp-tools.md#captions). How the pipeline works inside is in
[caption-system.md](../internals/caption-system.md).

## Quick start

```
open_captions()                                    # open panel + transcribe timeline
open_captions(style="bold_pop")                    # open with preset style
get_caption_state()                                # check transcription progress + segments
get_caption_styles()                               # list all 13 style presets
set_caption_style(preset_id="neon_glow")           # apply a preset
set_caption_style(preset_id="bold_pop", font_size=80, position="center")  # customize
set_caption_grouping(mode="words", max_words=4)    # control word grouping
generate_captions(style="bold_pop")                # generate + paste to user's timeline
verify_captions()                                  # inspect titles to verify text/font
get_title_text()                                   # read text/font from selected title
export_captions_srt(path="/tmp/captions.srt")      # export SRT subtitles
export_captions_txt(path="/tmp/captions.txt")      # export plain text
```

Generates word-by-word highlighted, animated caption titles as FCPXML. The pipeline:
1. Imports FCPXML into a temp project (resolves Motion template)
2. Copies titles from temp project to clipboard (native format)
3. Pastes as connected storyline onto the user's actual timeline
4. Applies position offset via ObjC transform (not FCPXML adjust-transform)
5. Self-verifies: inspects first title's CHChannelText for text/font/size
6. Cleans up the temp project

No drag-and-drop, no dialogs, captions land directly on the user's timeline.

**Style presets** (13 built-in): `bold_pop`, `neon_glow`, `clean_minimal`, `handwritten`,
`gradient_fire`, `outline_bold`, `shadow_deep`, `karaoke`, `typewriter`, `bounce_fun`,
`subtitle_pro`, `social_bold`, `social_reels`

**Positions**: bottom (default lower third), center, top, custom

**Animations**: none, fade, pop, slide_up, typewriter, bounce

**Word grouping modes**: social (2-3 words, 0.5s silence break — best for TikTok/Reels),
words (max N per group), sentence (by punctuation), time (max seconds), chars (max characters)

Each caption is a `<title>` element with `<text-style>` attributes. Word-by-word
highlight uses multiple `<text-style>` refs per title — the active word gets the
highlight color, others get the base text color.

**Title text inspection**: `get_title_text()` reads text content, font family, font name,
and point size from the selected Motion title's CHChannelText channel. `verify_captions()`
walks connected titles on the timeline and checks text/fontSize against the expected style.

## Other caption tools

- `set_caption_words(words)` — supply words with timing yourself (for example from an SRT
  file or another transcription service); this bypasses transcription.
- `generate_native_captions(grouping="word", language="en", format="ITT")` and
  `verify_native_captions()` — FCP's native captions with word-level timing, and a check of
  what landed in the caption lane.
- `remove_captions(native=True, dry_run=False)` — delete caption items from the open
  sequence: native captions, or with `native=False` the social title captions.
- `close_captions()` — close the captions panel.
- `cleanup_temp_projects(dry_run=True)` — scratch projects the pipeline left behind.
