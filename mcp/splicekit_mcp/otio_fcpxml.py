"""OpenTimelineIO <-> FCPXML conversion helpers (no bridge calls)."""

import copy
from fractions import Fraction
from pathlib import Path
from xml.etree import ElementTree as ET


def _otio_prepare_for_fcp(timeline):
    """Prepare an OTIO timeline for FCP import.

    - Converts non-title GeneratorReference clips to gaps
    - Preserves title generators (the adapter writes them as <title> elements)
    - Returns the modified timeline (in-place)
    """
    import opentimelineio as otio
    if not isinstance(timeline, otio.schema.Timeline):
        return timeline
    for track in timeline.tracks:
        for i, item in enumerate(list(track)):
            if (isinstance(item, otio.schema.Clip) and
                    isinstance(item.media_reference, otio.schema.GeneratorReference)):
                if not _otio_is_title_generator_reference(item.media_reference):
                    track[i] = otio.schema.Gap(source_range=item.source_range)
    return timeline


def _otio_is_title_generator_reference(media_reference):
    """Detect title-like GeneratorReference metadata across adapter variants."""
    title_generator_kinds = {"Title", "title", "fcpx.title"}
    gen_kind = getattr(media_reference, "generator_kind", "")
    if gen_kind in title_generator_kinds:
        return True

    parameters = getattr(media_reference, "parameters", {}) or {}
    if not isinstance(parameters, dict):
        return False
    return bool(parameters.get("text_xml") or parameters.get("text_style_def_xml"))


def _otio_fcpx_adapter_candidates():
    """Return compatible FCPXML adapter names in preference order."""
    import opentimelineio as otio

    preferred = ("fcpxml", "fcpx_xml")
    try:
        available = set(otio.adapters.available_adapter_names())
    except Exception:
        available = set()

    ordered = [name for name in preferred if name in available]
    if ordered:
        return ordered
    return list(preferred)


def _otio_with_fcpx_adapter(operation):
    """Run an OTIO adapter operation against the supported FCPXML adapter names."""
    errors = []
    for adapter_name in _otio_fcpx_adapter_candidates():
        try:
            return operation(adapter_name)
        except Exception as exc:
            errors.append(f"{adapter_name}: {exc}")
    raise RuntimeError("No working FCPXML adapter found (" + "; ".join(errors) + ")")


def _otio_fcpxml_parse_root(fcpxml_str):
    """Parse FCPXML text into an ElementTree root."""

    return ET.fromstring(fcpxml_str)


def _otio_fcpx_time_to_seconds(value):
    """Convert an FCPXML time attribute (e.g. ``28s``, ``300/30s``) to seconds."""
    if not value:
        return 0.0
    text = str(value).strip()
    if not text:
        return 0.0
    if text.endswith("s"):
        text = text[:-1].strip()
    if "/" in text:
        num, den = text.split("/", 1)
        return float(num) / float(den)
    try:
        return float(text)
    except ValueError:
        return 0.0


def _otio_fcpx_sequence_rate(sequence_elem, resources_elem, default_rate=30):
    """Resolve the frame rate for a ``<sequence>`` from its format resource."""
    format_id = sequence_elem.get("format") if sequence_elem is not None else None
    if not format_id or resources_elem is None:
        return default_rate
    for fmt in resources_elem.findall("format"):
        if fmt.get("id") == format_id:
            frame_duration = fmt.get("frameDuration", "")
            seconds = _otio_fcpx_time_to_seconds(frame_duration)
            if seconds > 0:
                return round(1.0 / seconds)
    return default_rate


# --- FCPXML -> OTIO, without the adapter ------------------------------------
#
# otio-fcpx-xml-adapter 1.0 was the only reader here, and it lost the timeline:
# exporting a project of three storyline clips plus one connected clip reported
# "1 track, 2 clips", every clip came back as a MissingReference, and re-importing
# produced gaps. Three separate causes — a compound clip it crashes on, anchored
# clips it does not place on a lane, and media references it does not carry — so
# the FCPXML Final Cut Pro writes is now read directly. The adapter stays as a
# fallback for FCPXML shapes this does not recognise.

_FCPX_TIMED_TAGS = {
    "asset-clip", "clip", "ref-clip", "video", "audio", "title", "gap",
    "sync-clip", "mc-clip", "transition", "audition",
}


def _otio_fcpx_fraction(value, default="0s"):
    """An FCPXML time ("1001/30000s", "20s", "0s") as an exact Fraction of seconds."""

    text = (value if value is not None else default)
    text = str(text).strip()
    if text.endswith("s"):
        text = text[:-1]
    if not text:
        return Fraction(0)
    if "/" in text:
        numerator, denominator = text.split("/", 1)
        return Fraction(int(numerator), int(denominator))
    return Fraction(text)


def _otio_fcpx_format_time(value):
    """A Fraction of seconds back as an FCPXML time string."""

    value = Fraction(value)
    if value.denominator == 1:
        return f"{value.numerator}s"
    return f"{value.numerator}/{value.denominator}s"


def _otio_fcpx_media_spine(resources_elem, ref):
    """The spine inside the ``<media>`` resource a ``<ref-clip>`` points at."""
    if resources_elem is None or not ref:
        return None
    for media in resources_elem.findall("media"):
        if media.get("id") != ref:
            continue
        sequence = media.find("sequence")
        if sequence is not None:
            return sequence.find("spine")
    return None


_OTIO_FCPX_MAX_COMPOUND_DEPTH = 8


def _otio_fcpx_ref_clip_as_gap(ref_clip):
    """A ``<gap>`` holding the place of a ``<ref-clip>`` that cannot be expanded.

    Leaving the raw ``<ref-clip>`` in the spine looks harmless — it keeps the timing —
    but its ``ref`` points at a ``<media>`` id, and nothing downstream resolves one: it
    becomes a Clip with a MissingReference, which is a clip the receiving application
    cannot play, with nothing in the clip itself to say why. A gap says the same thing
    honestly and keeps the timeline the right length, which is what the note alongside it
    describes.
    """
    gap = ET.Element("gap")
    gap.set("name", ref_clip.get("name", "gap"))
    gap.set("offset", ref_clip.get("offset", "0s"))
    gap.set("duration", ref_clip.get("duration", "0s"))
    gap.set("start", "0s")

    # Anything anchored to it travels with it, at the same point on the timeline.
    #
    # An anchored child's `offset` is in its host's local time, and the reader works out
    # where it lands as host_offset + (child_offset - host_start). Dropping the host's
    # `start` to 0 without touching the children moved every one of them later by exactly
    # the discarded `start` — which is any compound clip not played from its first frame,
    # the ordinary case. The children are rebased instead.
    ref_start = _otio_fcpx_fraction(ref_clip.get("start"))
    for child in list(ref_clip):
        if child.tag not in _FCPX_TIMED_TAGS or not child.get("lane"):
            continue
        moved = copy.deepcopy(child)
        moved.set("offset", _otio_fcpx_format_time(
            _otio_fcpx_fraction(child.get("offset")) - ref_start))
        gap.append(moved)
    return gap


def _otio_fcpx_expand_ref_clip(ref_clip, inner_spine, resources_elem=None,
                               notes=None, _seen=frozenset()):
    """One ``<ref-clip>`` as the clips it actually contains, trimmed as it is trimmed.

    A compound clip can hold another compound clip. Those inner ``<ref-clip>`` elements
    live in ``<resources>``, not under the project, so the flattening pass never walked
    to them: one was copied through untouched and later resolved against the asset index,
    where a ``<media>`` id matches no ``<asset>``, so it turned into a clip with a
    MissingReference while the note still said the compound clip had been flattened.
    Expansion now recurses, carrying the resource index with it, and refuses to follow a
    compound clip that contains itself.
    """

    ref_offset = _otio_fcpx_fraction(ref_clip.get("offset"))
    ref_start = _otio_fcpx_fraction(ref_clip.get("start"))
    ref_end = ref_start + _otio_fcpx_fraction(ref_clip.get("duration"))
    if notes is None:
        notes = []

    expanded = []
    for inner in inner_spine:
        if inner.tag not in _FCPX_TIMED_TAGS:
            continue
        inner_offset = _otio_fcpx_fraction(inner.get("offset"))
        inner_end = inner_offset + _otio_fcpx_fraction(inner.get("duration"))
        visible_from = max(inner_offset, ref_start)
        visible_to = min(inner_end, ref_end)
        if visible_to <= visible_from:
            continue  # trimmed out of the compound clip entirely
        clip = copy.deepcopy(inner)
        clip.set("offset", _otio_fcpx_format_time(ref_offset + (visible_from - ref_start)))
        clip.set("duration", _otio_fcpx_format_time(visible_to - visible_from))
        if inner.tag != "gap":
            clip.set("start", _otio_fcpx_format_time(
                _otio_fcpx_fraction(inner.get("start")) + (visible_from - inner_offset)))
        clip.attrib.pop("lane", None)

        # A compound clip inside this one. `clip` already carries timeline offset and the
        # in-point into the nested media, which is exactly what this function expects.
        if clip.tag == "ref-clip" and resources_elem is not None:
            nested_ref = clip.get("ref", "")
            name = clip.get("name", "?")
            if nested_ref in _seen or len(_seen) >= _OTIO_FCPX_MAX_COMPOUND_DEPTH:
                notes.append(
                    f"compound clip {name!r} replaced with a gap: it is nested inside itself"
                    if nested_ref in _seen else
                    f"compound clip {name!r} replaced with a gap: nested more than "
                    f"{_OTIO_FCPX_MAX_COMPOUND_DEPTH} compound clips deep")
                expanded.append(_otio_fcpx_ref_clip_as_gap(clip))
                continue
            nested_spine = _otio_fcpx_media_spine(resources_elem, nested_ref)
            if nested_spine is None:
                notes.append(f"compound clip {name!r} replaced with a gap: "
                             "its contents are not in this document")
                expanded.append(_otio_fcpx_ref_clip_as_gap(clip))
                continue
            sub = _otio_fcpx_expand_ref_clip(clip, nested_spine, resources_elem,
                                             notes, _seen | {nested_ref})
            if sub:
                notes.append(f"compound clip {name!r} nested inside another one "
                             f"flattened into {len(sub)} clip(s)")
                expanded.extend(sub)
                continue
            # Its media resolved but held nothing usable — an empty <spine>, or a body
            # entirely trimmed away. Still a ref-clip nothing downstream can resolve.
            notes.append(f"compound clip {name!r} replaced with a gap: "
                         "there is nothing in it")
            expanded.append(_otio_fcpx_ref_clip_as_gap(clip))
            continue

        expanded.append(clip)

    # The compound clip's own connected clips move onto whichever of the expanded
    # clips now covers the moment they were anchored at. An anchored offset is in its
    # parent's local time, so it is converted to timeline time and back again.
    visible_span_end = ref_offset + (ref_end - ref_start)
    for child in list(ref_clip):
        if child.tag not in _FCPX_TIMED_TAGS or not child.get("lane"):
            continue
        anchored_at = ref_offset + (_otio_fcpx_fraction(child.get("offset")) - ref_start)
        host = None
        for candidate in expanded:
            candidate_offset = _otio_fcpx_fraction(candidate.get("offset"))
            if candidate_offset <= anchored_at < candidate_offset + _otio_fcpx_fraction(
                    candidate.get("duration")):
                host = candidate
                break
        if host is None:
            # It used to fall back to expanded[0], which silently moved a connected clip
            # anchored in a trimmed-away part of the compound clip onto the first visible
            # clip, at an offset that meant nothing. If the moment it was anchored to is
            # not on the timeline any more, neither is it — and that gets reported.
            if not (ref_offset <= anchored_at < visible_span_end):
                notes.append(
                    f"connected clip {child.get('name', '?')!r} dropped: it was anchored "
                    f"inside the part of compound clip {ref_clip.get('name', '?')!r} that "
                    "is trimmed off")
            else:
                notes.append(
                    f"connected clip {child.get('name', '?')!r} dropped: nothing in "
                    f"compound clip {ref_clip.get('name', '?')!r} covers the moment it "
                    "was anchored at")
            continue
        moved = copy.deepcopy(child)
        moved.set("offset", _otio_fcpx_format_time(
            _otio_fcpx_fraction(host.get("start"))
            + (anchored_at - _otio_fcpx_fraction(host.get("offset")))))
        host.append(moved)
    return expanded


def _otio_fcpx_flatten_ref_clips(project_elem, resources_elem):
    """Replace every ``<ref-clip>`` with the clips it contains, in place.

    OTIO has no compound clip, and the previous answer was to swap each one for a
    gap of the same length: the QA timeline's compound clip, and the connected clip
    anchored inside it, simply vanished. Flattening is what any editor without
    compound clips would receive, and it keeps the media. Returns a list of notes
    for the caller to report.
    """
    notes = []
    for spine in project_elem.iter("spine"):
        rebuilt = []
        changed = False
        for child in list(spine):
            if child.tag != "ref-clip":
                rebuilt.append(child)
                continue
            # These two checks are the top-level twins of the ones inside
            # _otio_fcpx_expand_ref_clip, and they kept the raw <ref-clip> long after the
            # nested ones stopped: a compound clip sitting directly in the project's spine
            # whose <media> is missing, has no <sequence>, or has an empty <spine> still
            # came back as an unplayable clip.
            inner_spine = _otio_fcpx_media_spine(resources_elem, child.get("ref", ""))
            if inner_spine is None:
                rebuilt.append(_otio_fcpx_ref_clip_as_gap(child))
                changed = True
                notes.append(f"compound clip {child.get('name', '?')!r} replaced with a "
                             "gap: its contents are not in this document")
                continue
            expanded = _otio_fcpx_expand_ref_clip(child, inner_spine, resources_elem,
                                                  notes, frozenset({child.get("ref", "")}))
            if not expanded:
                rebuilt.append(_otio_fcpx_ref_clip_as_gap(child))
                changed = True
                notes.append(f"compound clip {child.get('name', '?')!r} replaced with a "
                             "gap: there is nothing in it")
                continue
            changed = True
            anchored = sum(1 for c in child if c.tag in _FCPX_TIMED_TAGS and c.get("lane"))
            notes.append(
                f"compound clip {child.get('name', '?')!r} flattened into "
                f"{len(expanded)} clip(s)"
                + (f", {anchored} connected clip(s) re-anchored" if anchored else "")
                + " — OTIO has no compound clip")
            rebuilt.extend(expanded)
        if changed:
            for child in list(spine):
                spine.remove(child)
            for child in rebuilt:
                spine.append(child)

    # A compound clip does not have to sit in the spine. Connect one to a clip — B-roll,
    # an insert, a titled sequence — and it hangs off its host on a lane instead, which
    # the walk above never reaches, because that only iterates the direct children of a
    # <spine>. The reader then handed the raw <ref-clip> to make_item, which resolves a
    # `ref` against the asset index; a <media> id matches no <asset>, so it came back as
    # an unplayable clip with no note beside it — and that happened even when the compound
    # clip's contents were perfectly good.
    # One walk from the root over the tree as it is now, with an explicit stack.
    #
    # Three attempts have lived here. project_elem.iter() is a live iterator, so an element
    # inserted while the walk ran was visited by that same walk, and a compound clip
    # connected inside itself expanded forever. Snapshotting with list() stopped the hang
    # but held on to replaced elements, which are removed from the tree yet keep their own
    # children, so the walk reached those detached subtrees and reported a second,
    # caveat-less flattening for content that never landed. Recursing instead fixed both
    # and broke a third thing: ordinary nesting then consumed Python stack frames, and a
    # document around 500 levels deep — no compound clips involved — died with a
    # RecursionError where it used to read fine.
    #
    # A stack of elements to visit has none of those problems. Children are read after the
    # host's own anchored clips have been replaced, so a detached element is never queued,
    # nothing that is queued can be reached twice, and depth costs a list entry rather than
    # a stack frame. Only the compound-clip nesting still recurses, and that is bounded at
    # _OTIO_FCPX_MAX_COMPOUND_DEPTH.
    stack = [(project_elem, frozenset(), 0)]
    while stack:
        host, seen, depth = stack.pop()
        opened = _otio_fcpx_flatten_anchored(host, resources_elem, notes, seen, depth)
        queued = set()
        for item, item_seen, item_depth in opened:
            stack.append((item, item_seen, item_depth))
            queued.add(id(item))
        for child in list(host):
            if id(child) not in queued:
                stack.append((child, seen, depth))
    return notes


def _otio_fcpx_flatten_anchored(host, resources_elem, notes, seen, depth):
    """Replace every ``<ref-clip>`` anchored to `host` with the clips it holds.

    Answers what it put there, each with the compound clips opened to reach it and how
    deep that is, for the caller to carry on from. `seen` is what stops a connected
    compound clip that contains a connection back to itself expanding forever; `depth`
    bounds a chain that never repeats an id but goes on too long.

    One host only. Walking the rest of the tree is the caller's job, and is deliberately
    not recursion — see the comment above.
    """
    anchored = [c for c in list(host) if c.tag == "ref-clip" and c.get("lane")]
    if not anchored:
        return []
    if depth > _OTIO_FCPX_MAX_COMPOUND_DEPTH:
        notes.append("a chain of connected compound clips goes more than "
                     f"{_OTIO_FCPX_MAX_COMPOUND_DEPTH} deep; the rest is not opened")
        return []

    opened = []
    for ref in anchored:
        ref_id = ref.get("ref", "")
        lane = ref.get("lane")
        name = ref.get("name", "?")
        at = list(host).index(ref)

        if ref_id in seen:
            replacement = [_otio_fcpx_ref_clip_as_gap(ref)]
            notes.append(f"connected compound clip {name!r} replaced with a gap: "
                         "it is connected inside itself")
        else:
            inner_spine = _otio_fcpx_media_spine(resources_elem, ref_id)
            expanded = []
            if inner_spine is not None:
                expanded = _otio_fcpx_expand_ref_clip(
                    ref, inner_spine, resources_elem, notes, seen | {ref_id})
            if expanded:
                replacement = expanded
                notes.append(
                    f"connected compound clip {name!r} flattened into "
                    f"{len(expanded)} clip(s) on the same lane — OTIO has no compound clip")
            else:
                replacement = [_otio_fcpx_ref_clip_as_gap(ref)]
                notes.append(
                    f"connected compound clip {name!r} replaced with a gap: "
                    + ("its contents are not in this document" if inner_spine is None
                       else "there is nothing in it"))

        # Expansion drops `lane`, since a spine item has none. These stay connected.
        for item in replacement:
            item.set("lane", lane)
        host.remove(ref)
        for offset, item in enumerate(replacement):
            host.insert(at + offset, item)
        for item in replacement:
            opened.append((item, seen | {ref_id}, depth + 1))

        if depth >= 1:
            notes.append(
                f"connected compound clip {name!r} was itself connected to another "
                "connected clip; only one level of connection is carried, so its "
                "contents do not reach the timeline")
    return opened


def _otio_fcpx_asset_index(resources_elem):
    """``id`` -> resource element, for every asset, effect, format and media."""
    index = {}
    if resources_elem is None:
        return index
    for child in resources_elem:
        resource_id = child.get("id")
        if resource_id:
            index[resource_id] = child
    return index


def _otio_fcpx_asset_for(element, resources):
    """The ``<asset>`` resource an item plays, following ``ref`` through a wrapper."""
    ref = element.get("ref")
    if not ref:
        for child in element:
            if child.tag in ("video", "audio") and child.get("ref"):
                ref = child.get("ref")
                break
    return resources.get(ref) if ref else None


def _otio_fcpx_media_url(element, resources):
    """The file URL an item plays, following ``ref`` into ``<resources>``."""
    asset = _otio_fcpx_asset_for(element, resources)
    if asset is None:
        return None
    src = asset.get("src")
    if src:
        return src
    media_rep = asset.find("media-rep") if hasattr(asset, "find") else None
    if media_rep is not None and media_rep.get("src"):
        return media_rep.get("src")
    return None


def _otio_fcpx_sequence_format_rate(sequence_elem, resources, default=30):
    """Frames per second for a ``<sequence>``, from its format's frameDuration."""

    format_elem = resources.get(sequence_elem.get("format")) if sequence_elem is not None else None
    if format_elem is None:
        for element in resources.values():
            if element.tag == "format" and element.get("frameDuration"):
                format_elem = element
                break
    if format_elem is None or not format_elem.get("frameDuration"):
        return Fraction(default)
    frame = _otio_fcpx_fraction(format_elem.get("frameDuration"))
    if frame <= 0:
        return Fraction(default)
    return 1 / frame


def _otio_fcpx_build_timeline(project_elem, resources_elem):
    """One FCPXML ``<project>`` as an OTIO timeline. Returns (timeline, notes)."""
    import opentimelineio as otio
    from opentimelineio import opentime

    resources = _otio_fcpx_asset_index(resources_elem)
    notes = _otio_fcpx_flatten_ref_clips(project_elem, resources_elem)

    sequence = project_elem.find("sequence")
    if sequence is None:
        raise ValueError("project has no <sequence>")
    spine = sequence.find("spine")
    if spine is None:
        raise ValueError("sequence has no <spine>")

    rate = _otio_fcpx_sequence_format_rate(sequence, resources)
    float_rate = float(rate)

    def frames(seconds):
        return opentime.RationalTime(round(float(seconds) * float_rate), float_rate)

    timeline = otio.schema.Timeline(name=project_elem.get("name", "Timeline"))
    timeline.metadata["fcpx_sequence_duration_seconds"] = float(
        _otio_fcpx_fraction(sequence.get("duration")))

    def make_item(element, host_offset, host_start):
        """An OTIO item for one FCPXML element, or None when it carries no time."""
        if element.tag == "gap":
            return otio.schema.Gap(source_range=opentime.TimeRange(
                frames(0), frames(_otio_fcpx_fraction(element.get("duration")))))
        source_start = _otio_fcpx_fraction(element.get("start"))
        duration = _otio_fcpx_fraction(element.get("duration"))
        url = _otio_fcpx_media_url(element, resources)
        if url:
            reference = otio.schema.ExternalReference(target_url=url)
            # The whole extent of the media, from the <asset> it came from. Leaving it
            # out writes "available_range": null, and a reader has no way to tell how
            # much of the file is there beyond the part this clip uses.
            asset = _otio_fcpx_asset_for(element, resources)
            if asset is not None and asset.get("duration"):
                reference.available_range = opentime.TimeRange(
                    frames(_otio_fcpx_fraction(asset.get("start"))),
                    frames(_otio_fcpx_fraction(asset.get("duration"))))
        elif element.tag in ("title", "video"):
            reference = otio.schema.GeneratorReference(
                name=element.get("name", "") or element.tag)
        else:
            reference = otio.schema.MissingReference()
        clip = otio.schema.Clip(
            name=element.get("name", "") or element.tag,
            media_reference=reference,
            source_range=opentime.TimeRange(frames(source_start), frames(duration)))
        clip.metadata["fcpx"] = {
            "tag": element.tag,
            "timeline_offset_seconds": float(
                host_offset + (_otio_fcpx_fraction(element.get("offset")) - host_start)),
        }
        return clip

    # Lane 0 is the primary storyline; each anchored lane becomes its own track, so
    # a connected clip survives instead of being dropped on the floor.
    lanes = {}
    for child in spine:
        if child.tag not in _FCPX_TIMED_TAGS:
            continue
        offset = _otio_fcpx_fraction(child.get("offset"))
        if child.tag == "transition":
            lanes.setdefault(0, []).append(("transition", offset, child))
            continue
        lanes.setdefault(0, []).append(("item", offset, child))
        host_start = _otio_fcpx_fraction(child.get("start"))
        for anchored in child:
            if anchored.tag not in _FCPX_TIMED_TAGS or not anchored.get("lane"):
                continue
            lane = int(anchored.get("lane"))
            anchored_at = offset + (_otio_fcpx_fraction(anchored.get("offset")) - host_start)
            lanes.setdefault(lane, []).append(("item", anchored_at, anchored))

    for lane in sorted(lanes):
        entries = sorted(lanes[lane], key=lambda e: e[1])
        track = otio.schema.Track(name=str(lane), kind=otio.schema.TrackKind.Video)
        # Starts at zero, not at the first item: a connected clip anchored twelve
        # seconds in needs twelve seconds of gap before it or it lands at the head of
        # the timeline.
        playhead = _otio_fcpx_fraction("0s")
        for kind, offset, element in entries:
            if kind == "transition":
                # Half on each side of the cut, which is where Final Cut Pro centres it.
                half = _otio_fcpx_fraction(element.get("duration")) / 2
                track.append(otio.schema.Transition(
                    name=element.get("name", "Transition"),
                    transition_type=otio.schema.TransitionTypes.SMPTE_Dissolve,
                    in_offset=frames(half), out_offset=frames(half)))
                continue
            if playhead is not None and offset > playhead:
                track.append(otio.schema.Gap(source_range=opentime.TimeRange(
                    frames(0), frames(offset - playhead))))
            item = make_item(element, offset, _otio_fcpx_fraction(element.get("offset")))
            if item is None:
                continue
            track.append(item)
            playhead = offset + _otio_fcpx_fraction(element.get("duration"))
        timeline.tracks.append(track)

    return timeline, notes


def _otio_sanitize_fcpx_project_element(project_elem):
    """Return a copy of ``project_elem`` safe for otio-fcpx-xml-adapter 1.0.

    The published adapter crashes on nested ``<ref-clip>`` compound timelines; a
    gap with the same timing preserves project duration for interchange summaries.
    """

    project = ET.fromstring(ET.tostring(project_elem, encoding="unicode"))
    for parent in project.iter():
        for child in list(parent):
            if child.tag != "ref-clip":
                continue
            gap = ET.Element(
                "gap",
                offset=child.get("offset", "0s"),
                name=child.get("name", ""),
                duration=child.get("duration", "0s"),
            )
            idx = list(parent).index(child)
            parent.remove(child)
            parent.insert(idx, gap)
    return project


def _otio_build_fcpx_project_document(resources_elem, project_elem, fcpxml_version="1.14"):
    """Wrap resources + project in a standalone ``<fcpxml>`` document."""

    root = ET.Element("fcpxml", version=fcpxml_version)
    root.append(ET.fromstring(ET.tostring(resources_elem, encoding="unicode")))
    root.append(ET.fromstring(ET.tostring(project_elem, encoding="unicode")))
    return ET.tostring(root, encoding="unicode")


def _otio_should_skip_fcpx_library_project(project_elem):
    """Skip FCP scene-detection projects that are not user timelines."""
    name = project_elem.get("name", "")
    return name.endswith(" - Scenes")


def _otio_inject_fcpx_spine_transitions(timeline, spine_elem, default_rate):
    """Insert OTIO ``Transition`` objects for ``<transition>`` spine items."""

    import opentimelineio as otio
    from opentimelineio import opentime

    if spine_elem is None:
        return

    spine_children = list(spine_elem)
    if not any(child.tag == "transition" for child in spine_children):
        return

    video_track = None
    for track in timeline.tracks:
        if track.kind == otio.schema.TrackKind.Video:
            video_track = track
            break
    if video_track is None:
        return

    clip_items = [item for item in video_track if isinstance(item, otio.schema.Clip)]
    if not clip_items:
        return

    rebuilt = otio.schema.Track(name=video_track.name, kind=video_track.kind)
    clip_index = 0
    for child in spine_children:
        if child.tag == "clip":
            if clip_index >= len(clip_items):
                break
            rebuilt.append(copy.deepcopy(clip_items[clip_index]))
            clip_index += 1
        elif child.tag == "transition":
            rate = default_rate
            if clip_index < len(clip_items):
                clip = clip_items[clip_index]
                if clip.source_range and clip.source_range.duration.rate > 0:
                    rate = clip.source_range.duration.rate
            duration_seconds = _otio_fcpx_time_to_seconds(child.get("duration", "0s"))
            half_frames = max(1, round((duration_seconds / 2.0) * rate))
            rebuilt.append(
                otio.schema.Transition(
                    name=child.get("name", "Transition"),
                    in_offset=opentime.RationalTime(half_frames, rate),
                    out_offset=opentime.RationalTime(half_frames, rate),
                )
            )

    while clip_index < len(clip_items):
        rebuilt.append(copy.deepcopy(clip_items[clip_index]))
        clip_index += 1

    for track_index, track in enumerate(timeline.tracks):
        if track is video_track:
            timeline.tracks[track_index] = rebuilt
            break


def _otio_apply_fcpx_project_metadata(timeline, project_elem, resources_elem):
    """Attach FCP sequence duration and spine transitions to an OTIO timeline."""
    sequence_elem = project_elem.find("sequence")
    if sequence_elem is None:
        return
    rate = _otio_fcpx_sequence_rate(sequence_elem, resources_elem)
    duration_attr = sequence_elem.get("duration")
    if duration_attr:
        timeline.metadata["fcpx_sequence_duration_seconds"] = _otio_fcpx_time_to_seconds(duration_attr)
    spine_elem = sequence_elem.find("spine")
    _otio_inject_fcpx_spine_transitions(timeline, spine_elem, rate)


def _otio_enhance_fcpx_read_result(result, root_elem):
    """Post-process adapter output using the source FCPXML tree."""
    import opentimelineio as otio

    resources_elem = root_elem.find("resources")
    project_elem = root_elem.find("project")
    if project_elem is not None:
        timeline = _otio_first_timeline(result)
        if isinstance(timeline, otio.schema.Timeline):
            _otio_apply_fcpx_project_metadata(timeline, project_elem, resources_elem)
        return result

    library_elem = root_elem.find("library")
    if library_elem is None:
        return result

    projects = []
    for event in library_elem.findall("event"):
        for project in event.findall("project"):
            projects.append(project)

    timelines = _otio_all_timelines(result, collection_fallback=False)
    for timeline, project in zip(timelines, projects):
        if isinstance(timeline, otio.schema.Timeline):
            _otio_apply_fcpx_project_metadata(timeline, project, resources_elem)
    return result


def _otio_read_fcpx_library_collection(root_elem):
    """Read a ``<library>`` document one project at a time."""
    import opentimelineio as otio

    resources_elem = root_elem.find("resources")
    if resources_elem is None:
        raise RuntimeError("FCPXML library is missing a <resources> block.")

    fcpxml_version = root_elem.get("version", "1.14")
    library_elem = root_elem.find("library")
    library_name = library_elem.get("location", "Library") if library_elem is not None else "Library"
    collection = otio.schema.SerializableCollection(name=library_name)

    for event in library_elem.findall("event"):
        for project in event.findall("project"):
            if _otio_should_skip_fcpx_library_project(project):
                continue
            timeline = _otio_fcpx_read_project(project, resources_elem, fcpxml_version)
            if isinstance(timeline, otio.schema.Timeline):
                collection.append(timeline)

    if not len(collection):
        raise RuntimeError("No readable timelines found in FCPXML library.")
    return collection


def _otio_fcpx_read_project(project_elem, resources_elem, fcpxml_version="1.14"):
    """One ``<project>`` as an OTIO timeline, read directly, adapter as the fallback.

    Notes about what could not be carried across (a compound clip flattened, say) end
    up in the timeline's metadata under ``splicekit_notes`` so export_otio can report
    them instead of quietly dropping things.
    """

    import opentimelineio as otio

    project_copy = copy.deepcopy(project_elem)
    try:
        timeline, notes = _otio_fcpx_build_timeline(project_copy, resources_elem)
        if notes:
            timeline.metadata["splicekit_notes"] = list(notes)
        return timeline
    except Exception as direct_error:  # noqa: BLE001 - fall back, then report both
        project_xml = _otio_build_fcpx_project_document(
            resources_elem,
            _otio_sanitize_fcpx_project_element(project_elem),
            fcpxml_version=fcpxml_version,
        )
        timeline = _otio_with_fcpx_adapter(
            lambda adapter_name: otio.adapters.read_from_string(project_xml, adapter_name)
        )
        if isinstance(timeline, otio.schema.Timeline):
            _otio_apply_fcpx_project_metadata(timeline, project_elem, resources_elem)
            timeline.metadata["splicekit_notes"] = [
                f"read with otio-fcpx-xml-adapter, not directly ({direct_error}); "
                "a compound clip becomes a gap and connected clips are dropped"
            ]
        return timeline


def _otio_read_fcpx_string(fcpxml_str):
    """Read FCPXML into OTIO: directly when the shape is understood, adapter otherwise."""
    import opentimelineio as otio

    root = _otio_fcpxml_parse_root(fcpxml_str)
    if root.find("library") is not None:
        return _otio_read_fcpx_library_collection(root)

    resources_elem = root.find("resources")
    project_elem = root.find("project")
    if project_elem is None:
        event_elem = root.find("event")
        if event_elem is not None:
            project_elem = event_elem.find("project")
    if project_elem is not None and resources_elem is not None:
        return _otio_fcpx_read_project(project_elem, resources_elem,
                                       root.get("version", "1.14"))

    result = _otio_with_fcpx_adapter(
        lambda adapter_name: otio.adapters.read_from_string(fcpxml_str, adapter_name)
    )
    return _otio_enhance_fcpx_read_result(result, root)


def _otio_write_fcpx_string(timeline, fcpxml_version=None):
    """Write FCPXML using whichever adapter name is installed.

    The modern PR #7 adapter accepts ``fcpxml_version`` for version-aware
    FCPXML 1.0-1.14 output. Older adapters reject that kwarg, so retry without
    it before moving to the next adapter name.
    """
    import opentimelineio as otio

    def write(adapter_name):
        if fcpxml_version:
            try:
                return otio.adapters.write_to_string(
                    timeline,
                    adapter_name,
                    fcpxml_version=fcpxml_version,
                )
            except TypeError as exc:
                if "fcpxml_version" not in str(exc):
                    raise
        return otio.adapters.write_to_string(timeline, adapter_name)

    return _otio_with_fcpx_adapter(write)


def _otio_fcpxmld_info_path(package_path):
    """Return the FCPXML document entrypoint for a `.fcpxmld` package."""

    package = Path(package_path)
    if not package.exists():
        raise FileNotFoundError(f"FCPXML package does not exist: '{package}'.")
    if not package.is_dir():
        raise NotADirectoryError(f"FCPXML package path is not a directory: '{package}'.")

    info_path = package / "Info.fcpxml"
    if not info_path.is_file():
        raise FileNotFoundError(f"FCPXML package is missing 'Info.fcpxml': '{package}'.")
    return info_path


def _otio_read_fcpx_document(path):
    """Read a `.fcpxml` document or `.fcpxmld` package entrypoint."""

    document_path = Path(path)
    if document_path.is_dir() or document_path.suffix.lower() == ".fcpxmld":
        document_path = _otio_fcpxmld_info_path(document_path)

    return document_path.read_text(encoding="utf-8")


def _otio_fcpxml_clean_for_paste(fcpxml_str):
    """Clean FCPXML for FCP's pasteboard import.

    - Strips <library> wrapper (pasteboard merges into active library)
    - Strips standalone <asset-clip> elements at event level (browser clutter)
    """
    lines = fcpxml_str.split("\n")
    clean = []
    for line in lines:
        s = line.strip()
        if s in ("<library>", "</library>"):
            continue
        if s.startswith("<asset-clip ") and s.endswith("/>"):
            if (len(line) - len(line.lstrip())) <= 16:
                continue
        clean.append(line)
    return "\n".join(clean)


def _otio_first_timeline(result):
    """Extract the first Timeline from an OTIO read result."""
    timelines = _otio_all_timelines(result, collection_fallback=False)
    if timelines:
        return timelines[0]
    return result

def _otio_all_timelines(result, collection_fallback=True):
    """Extract all Timelines from an OTIO read result."""
    import opentimelineio as otio
    if isinstance(result, otio.schema.Timeline):
        return [result]
    if isinstance(result, otio.schema.SerializableCollection):
        timelines = []
        if hasattr(result, "find_children"):
            timelines = list(result.find_children(descended_from_type=otio.schema.Timeline))
        if not timelines:
            timelines = [
                child
                for item in result
                for child in _otio_all_timelines(item, collection_fallback=False)
            ]
        if timelines:
            return timelines
        return list(result) if collection_fallback else []
    return [result] if collection_fallback else []

def _otio_timeline_summary(timeline):
    """Build a summary dict for an OTIO timeline."""
    import opentimelineio as otio
    info = {"name": getattr(timeline, "name", "unknown")}
    if isinstance(timeline, otio.schema.Timeline):
        info["tracks"] = len(timeline.tracks)
        info["clips"] = len(list(timeline.find_clips()))
        metadata = getattr(timeline, "metadata", None) or {}
        sequence_seconds = metadata.get("fcpx_sequence_duration_seconds")
        if sequence_seconds is not None:
            info["duration_seconds"] = round(float(sequence_seconds), 3)
        else:
            total_dur = timeline.duration()
            if total_dur and total_dur.value > 0 and total_dur.rate > 0:
                info["duration_seconds"] = round(total_dur.value / total_dur.rate, 3)
        # What could not be carried across, said out loud rather than dropped: OTIO
        # has no compound clip, so one gets flattened, and that is worth knowing
        # before the file goes to another editor.
        notes = metadata.get("splicekit_notes")
        if notes:
            info["not_carried_across"] = list(notes)
    return info


def _otio_detect_rate(timeline):
    """Auto-detect frame rate from an OTIO timeline. Returns 24 as default."""
    import opentimelineio as otio
    raw_rate = 24
    if isinstance(timeline, otio.schema.Timeline):
        for clip in timeline.find_clips():
            if clip.source_range and clip.source_range.duration.rate > 1:
                raw_rate = clip.source_range.duration.rate
                break
        else:
            dur = timeline.duration()
            if dur and dur.rate > 1:
                raw_rate = dur.rate
    return _otio_normalize_rate(raw_rate)


def _otio_normalize_rate(rate):
    """Map common approximate frame rates to exact SMPTE values.

    The FCPXML adapter returns integer rates (29 for 29.97fps) and user input
    may use approximate values (29.97). The EDL adapter needs exact fractional
    rates (30000/1001) for drop-frame timecode support.
    """
    rate_map = {
        23: 24000 / 1001,    # 23.976
        23.98: 24000 / 1001,
        23.976: 24000 / 1001,
        24: 24,
        25: 25,
        29: 30000 / 1001,    # 29.97 (FCPXML adapter returns 29)
        29.97: 30000 / 1001,
        30: 30,
        47: 48000 / 1001,
        47.95: 48000 / 1001,
        48: 48,
        50: 50,
        59: 60000 / 1001,    # 59.94
        59.94: 60000 / 1001,
        60: 60,
    }
    # Check exact match first, then closest integer
    if rate in rate_map:
        return rate_map[rate]
    rounded = round(rate)
    if rounded in rate_map:
        return rate_map[rounded]
    return rate
