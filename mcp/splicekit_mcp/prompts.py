"""MCP prompts: workflow templates for common editing scenarios."""

from .app import mcp


# ============================================================
# MCP Prompts
# ============================================================
# Workflow templates for common editing scenarios. Each prompt
# provides role context, step-by-step guidance, and attaches
# the instructions resource for operating rules.


@mcp.prompt(name="edit_podcast",
            description="Multi-participant podcast editing: silence removal, leveling, chapter markers")
def prompt_edit_podcast(episode_name: str = "", participants: str = "") -> str:
    """Guide for editing a podcast episode in FCP."""
    return f"""You are an expert podcast editor working in Final Cut Pro via SpliceKit.

Task: Edit the podcast episode{f' "{episode_name}"' if episode_name else ''}{f' with participants: {participants}' if participants else ''}.

## Workflow
1. **Setup**: Open the project and review the timeline with get_timeline_clips()
2. **Silence removal**: Use detect_scene_changes() to find dead air, then blade_at_times() to cut silent sections
3. **Audio leveling**: Check levels across participants — use timeline_action("adjustVolumeUp/Down") to balance
4. **Cleanup**: Remove filler words, long pauses, and false starts by selecting and deleting clips
5. **Chapter markers**: Add chapter markers at topic transitions using timeline_action("addChapterMarker")
6. **Transitions**: Add cross dissolves between segments with apply_transition_to_all_clips() or individual apply_transition()
7. **Export**: Use generate_fcpxml() to export, or share_project() for direct export

## Tips
- Use capture_timeline() frequently to verify your edits visually
- Use batch_timeline_actions() for efficient multi-step editing
- Silence detection threshold can be tuned with set_silence_threshold()
"""


@mcp.prompt(name="edit_music_video",
            description="Beat-synced music video editing with scene detection and montage assembly")
def prompt_edit_music_video(song_name: str = "", style: str = "bar") -> str:
    """Guide for editing a music video synced to beats."""
    return f"""You are an expert music video editor working in Final Cut Pro via SpliceKit.

Task: Edit a music video{f' for "{song_name}"' if song_name else ''} with cuts synced to the music.

## Workflow
1. **Analyze music**: Use detect_beats() to find beat positions, then analyze_song_structure() for sections
2. **Score clips**: Use montage_analyze_clips() to rank available footage
3. **Plan the edit**: Use montage_plan_edit() with style="{style}" to map clips to musical segments
4. **Assemble**: Use montage_assemble() to build the timeline, or montage_auto() for one-shot creation
5. **Refine**: Review with capture_viewer(), adjust individual clips, add effects
6. **Transitions**: Add transitions at cut points — apply_transition_to_all_clips() for uniform look, or individual apply_transition() for variety
7. **Color**: Select clips and apply color correction with timeline_action("addColorBoard") or timeline_action("addColorCurves")

## Beat Sync Tips
- "beat" style cuts on every beat (fast, energetic)
- "bar" style cuts on every measure (balanced, standard)
- "section" style cuts on verse/chorus boundaries (cinematic, slower)
- Use blade_at_times() to manually cut at specific beat positions
"""


@mcp.prompt(name="social_media_reformat",
            description="Reformat a timeline for social media: aspect ratio, captions, pacing")
def prompt_social_media(platform: str = "instagram", source_project: str = "") -> str:
    """Guide for reformatting content for social media platforms."""
    specs = {
        "instagram": {"aspect": "9:16 (1080x1920)", "duration": "15-60s", "captions": True},
        "tiktok": {"aspect": "9:16 (1080x1920)", "duration": "15-60s", "captions": True},
        "youtube_shorts": {"aspect": "9:16 (1080x1920)", "duration": "up to 60s", "captions": True},
        "youtube": {"aspect": "16:9 (1920x1080)", "duration": "any", "captions": True},
        "twitter": {"aspect": "16:9 or 1:1", "duration": "up to 2:20", "captions": True},
    }
    spec = specs.get(platform, specs["instagram"])

    return f"""You are a social media content editor working in Final Cut Pro via SpliceKit.

Task: Reformat{f' "{source_project}"' if source_project else ' the current project'} for {platform}.

## Target Specs
- Aspect ratio: {spec['aspect']}
- Duration: {spec['duration']}
- Captions: {'Required for accessibility' if spec['captions'] else 'Optional'}

## Workflow
1. **Review source**: get_timeline_clips() to understand the current edit
2. **Trim for length**: Identify the strongest {spec['duration']} segment — blade and remove excess
3. **Add captions**: Use open_transcript() to transcribe, then generate_captions() for subtitles
4. **Style captions**: Use set_caption_style() and set_caption_grouping() for platform-appropriate look
5. **Pacing**: Tighten cuts — social content needs faster pacing than long-form
6. **Visual polish**: Add effects, color correction, titles as needed
7. **Export**: share_project() or generate FCPXML

## Social Media Tips
- Front-load the hook in the first 3 seconds
- Captions are essential — most viewers watch without sound
- Use generate_social_captions() for word-by-word highlighting style
- Keep text and key visuals in the center safe zone for 9:16
"""


@mcp.prompt(name="color_grade",
            description="Color grading workflow: correction, look development, consistency")
def prompt_color_grade(look: str = "", mood: str = "") -> str:
    """Guide for color grading a project in FCP."""
    return f"""You are a professional colorist working in Final Cut Pro via SpliceKit.

Task: Color grade the current project{f' with a {look} look' if look else ''}{f' for a {mood} mood' if mood else ''}.

## Workflow
1. **Review**: get_timeline_clips() and capture_viewer() to assess current color state
2. **Primary correction** (per clip):
   - Select clip: timeline_action("selectClipAtPlayhead")
   - Add Color Board: timeline_action("addColorBoard") for basic lift/gamma/gain
   - Or Color Wheels: timeline_action("addColorWheels") for more control
   - Or Color Curves: timeline_action("addColorCurves") for precise curve adjustments
3. **Look development**: Use timeline_action("addHueSaturation") for selective color shifts
4. **Consistency**: Apply the same correction across similar clips using copy/paste attributes
5. **Verify**: capture_viewer() after each correction to check the result

## Color Tools Available
- addColorBoard — basic 3-way (global, shadows, midtones, highlights)
- addColorWheels — lift/gamma/gain wheels
- addColorCurves — RGB curves
- addColorAdjustment — exposure, saturation, black point
- addHueSaturation — selective hue shifts
- addEnhanceLightAndColor — FCP's auto enhancement
- balanceColor — automatic white balance
- matchColor — match color between clips

## Tips
- Always correct exposure/white balance first, then add creative looks
- Use capture_viewer() frequently to compare before/after
- Work clip-by-clip for narrative, or batch for documentary/event
"""


@mcp.prompt(name="rough_cut_assembly",
            description="Assemble a rough cut from clips: import, arrange, basic transitions")
def prompt_rough_cut(project_name: str = "", clip_folder: str = "") -> str:
    """Guide for assembling a rough cut from raw footage."""
    return f"""You are an assistant editor assembling a rough cut in Final Cut Pro via SpliceKit.

Task: Build a rough cut{f' for "{project_name}"' if project_name else ''}{f' from clips in {clip_folder}' if clip_folder else ''}.

## Workflow
1. **Review footage**: get_timeline_clips() to see what's in the timeline, or montage_analyze_clips() to score available clips
2. **Arrange clips**: Use the montage tools for automated assembly, or manually:
   - Position playhead where you want to place each clip
   - Use FCPXML for precise placement: generate_fcpxml() + import_fcpxml()
3. **Rough ordering**: Get the story structure right before fine-tuning
4. **Basic transitions**: apply_transition_to_all_clips() for uniform cross dissolves, or apply_transition() at specific cuts
5. **Timing**: Adjust clip durations, add gaps for pacing
6. **Review**: capture_timeline() for layout overview, capture_viewer() for content check

## Assembly Tips
- Start with the strongest clips, fill in secondary footage later
- Don't worry about perfect timing in a rough cut — focus on story order
- Use markers (timeline_action("addMarker")) to flag sections needing attention
- Use todo markers (timeline_action("addTodoMarker")) for notes on missing content
"""


@mcp.prompt(name="caption_workflow",
            description="Full captioning pipeline: transcribe, generate, style, and export captions")
def prompt_caption_workflow(language: str = "en", export_format: str = "srt") -> str:
    """Guide for the complete captioning workflow."""
    return f"""You are a captioning specialist working in Final Cut Pro via SpliceKit.

Task: Create captions for the current timeline in {language}, export as {export_format.upper()}.

## Workflow
1. **Transcribe**: open_transcript() to start the Parakeet speech-to-text engine
2. **Review transcript**: get_transcript() to read the text, search_transcript() to find specific words
3. **Clean up**: delete_transcript_words() to remove filler, move_transcript_words() to fix ordering
4. **Remove silence**: delete_transcript_silences() to clean dead air (tune with set_silence_threshold())
5. **Generate captions**: generate_captions() to create subtitle track from transcript
6. **Style**: set_caption_style() for font, size, position; set_caption_grouping() for line breaks
7. **Verify**: verify_captions() to check timing and content, capture_viewer() to see visual result
8. **Export**: export_captions_srt() for SRT or export_captions_txt() for plain text

## Caption Tips
- Use generate_social_captions() for word-by-word highlighting (TikTok/Reels style)
- Parakeet v3 supports multilingual transcription
- SRT is universal; use it for YouTube, Vimeo, social platforms
- Always verify_captions() before export to catch timing issues
"""


@mcp.prompt(name="documentary_editing",
            description="Documentary editing: interview structure, B-roll, narrative pacing")
def prompt_documentary(topic: str = "") -> str:
    """Guide for documentary-style editing."""
    return f"""You are a documentary editor working in Final Cut Pro via SpliceKit.

Task: Edit a documentary{f' about "{topic}"' if topic else ''}.

## Workflow
1. **Organize**: Review all clips with get_timeline_clips(), use markers to tag key moments
2. **Structure**: Build the narrative arc — establish the story spine with interview clips
3. **Transcribe**: Use open_transcript() + get_transcript() to find the best soundbites
4. **Assemble**: Place interview clips in story order using FCPXML or montage tools
5. **B-roll**: Layer supporting footage above the primary storyline:
   - select_clip_in_lane(lane=1) to work with connected clips
   - Use blade_at_times() to trim B-roll to match interview pacing
6. **Transitions**: Add dissolves at section breaks, hard cuts within scenes
7. **Audio**: Balance interview audio, add ambient sound, music bed
8. **Captions**: Full caption workflow for accessibility
9. **Review**: capture_viewer() and capture_timeline() throughout

## Documentary Tips
- Let interviews drive the structure, B-roll supports the narrative
- Use chapter markers (timeline_action("addChapterMarker")) at major sections
- Use todo markers for sections needing pickup shots or additional footage
- Color correct interviews for consistency, grade B-roll for mood
"""
