"""Tools: titles and generators — list the installed templates, add one at an exact
time / length / lane with its text and parameters, read and change a title on the
timeline. Bridge: titles.list, titles.add, titles.getParameters, titles.setParameters
(Sources/Bridge/SpliceKitServerTitles.m)."""

import json

from ..registry import DESTRUCTIVE, READ, splicekit_tool
from ..bridge import _err, bridge


_LIST_LIMIT = 300
_STYLE_KEYS = ("font", "size", "bold", "italic", "color", "alignment")


def _json_value(value, name: str, kinds: tuple):
    """Accept the value itself or its JSON text (some MCP clients send objects as strings)."""
    if value is None or value == "":
        return None
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        if kinds != (str,) and text[0] in "[{":
            try:
                value = json.loads(text)
            except json.JSONDecodeError as e:
                raise ValueError(f"{name} is not valid JSON: {e}")
    if not isinstance(value, kinds):
        raise ValueError(f"{name} must be {' or '.join(k.__name__ for k in kinds)}")
    return value


def _change_params(text, text_fields, font, size, bold, italic, color, alignment, parameters) -> dict:
    """The text / style / parameter keys titles.add and titles.setParameters share."""
    params: dict = {}
    if text:
        params["text"] = text
    fields = _json_value(text_fields, "text_fields", (list,))
    if fields is not None:
        params["textFields"] = fields
    for key, value in zip(_STYLE_KEYS, (font, size, bold, italic, color, alignment)):
        if value is not None and value != "":
            params[key] = value
    values = _json_value(parameters, "parameters", (dict,))
    if values:
        params["parameters"] = values
    return params


def _bridge_error(r) -> str:
    message = r.get("error", r) if isinstance(r, dict) else r
    if isinstance(message, dict):
        message = message.get("message", message)
    lines = [f"Error: {message}"]
    for c in (r.get("candidates") or []) if isinstance(r, dict) else []:
        where = " / ".join(x for x in (c.get("category"), c.get("theme")) if x)
        lines.append(f"  {c.get('name')}  ({where})  effect_id={c.get('effectID')}")
    return "\n".join(lines)


def _secs(value) -> str:
    return f"{value:.3f}s" if isinstance(value, (int, float)) and not isinstance(value, bool) else "?"


def _value(v) -> str:
    if isinstance(v, bool):
        return "on" if v else "off"
    if isinstance(v, float):
        return f"{v:g}"
    if isinstance(v, list):
        return "[" + ", ".join(_value(x) for x in v) + "]"
    return str(v)


def _field_line(f: dict) -> str:
    style = []
    if f.get("font"):
        style.append(f"{f['font']}{' bold' if f.get('bold') else ''}{' italic' if f.get('italic') else ''}")
    if f.get("size") is not None:
        style.append(f"{_value(f['size'])} pt")
    if f.get("color"):
        style.append(f["color"])
    if f.get("alignment"):
        style.append(f["alignment"])
    return f"  [{f.get('index', '?')}] {json.dumps(f.get('text', ''), ensure_ascii=False)}" + (
        f"  ({', '.join(style)})" if style else "")


def _param_line(p: dict) -> str:
    kind = p.get("kind", "?")
    line = f"  {p.get('key')}: {_value(p.get('value'))}  [{kind}"
    if kind == "percent":
        line += ", %"
    elif kind == "angle":
        line += ", degrees"
    if "min" in p and "max" in p:
        line += f", {_value(p['min'])}..{_value(p['max'])}"
    line += "]"
    if p.get("options"):
        line += f"  options: {', '.join(p['options'])}"
    if p.get("keyframes"):
        line += f"  ({p['keyframes']} keyframes: read-only here)"
    if kind == "unsupported":
        line = f"  {p.get('key')}: ({p.get('channelClass', 'unknown')} parameter, not readable or settable here)"
    return line


def _change_lines(r: dict) -> list:
    lines = []
    for f in r.get("textFields") or []:
        if "before" in f:  # a plan: before / after
            lines.append(f"  text [{f['after'].get('index')}]: {json.dumps(f['before'].get('text', ''), ensure_ascii=False)}"
                         f" -> {json.dumps(f['after'].get('text', ''), ensure_ascii=False)}")
        else:
            lines.append(_field_line(f))
    for p in r.get("parameters") or []:
        now = p.get("after", p.get("requested"))
        lines.append(f"  {p.get('key')}: {_value(p.get('before'))} -> {_value(now)}")
    return lines


@splicekit_tool("list_titles", READ, title="List titles and generators")
def list_titles(kind: str = "all", filter: str = "", category: str = "", theme: str = "") -> str:
    """Every installed title and generator (Apple's and any you added in Motion), with its
    category, theme and effect ID — the browser's Titles and Generators sidebar.

    Many templates share a name ("Bug", "Left" and "Upper" are each in a dozen themes);
    the theme tells them apart, and the effect ID names one exactly. Pass either to
    add_title.

    Args:
        kind: "title", "generator" or "all".
        filter: text to match in the name, category or theme (e.g. "lower third").
        category: only this category (e.g. "Lower Thirds", "Elements").
        theme: only this theme (e.g. "Kinetic").
    """
    r = bridge.call("titles.list", kind=kind, filter=filter, category=category, theme=theme)
    if _err(r):
        return _bridge_error(r)
    items = r.get("items") or []
    if not items:
        return "No installed title or generator matches."
    lines = [f"{len(items)} match{'es' if len(items) != 1 else ''} (kind  category / theme  name  effect_id):"]
    for it in items[:_LIST_LIMIT]:
        where = " / ".join(x for x in (it.get("category"), it.get("theme")) if x)
        shared = "  (name shared: use theme or effect_id)" if it.get("nameIsShared") else ""
        lines.append(f"  {it.get('kind'):9s} {where}  {it.get('name')}  effect_id={it.get('effectID')}{shared}")
    if len(items) > _LIST_LIMIT:
        lines.append(f"  ... and {len(items) - _LIST_LIMIT} more: narrow with filter, category or theme")
    return "\n".join(lines)


@splicekit_tool("add_title", DESTRUCTIVE, title="Add a title or generator")
def add_title(name: str = "", effect_id: str = "", at_seconds: float | None = None,
              duration_seconds: float = 10.0, lane: int | str | None = None,
              text: str = "", text_fields: list | str | None = None,
              font: str = "", size: float | None = None, bold: bool | None = None,
              italic: bool | None = None, color: str | list | None = None, alignment: str = "",
              parameters: dict | str | None = None, kind: str = "", category: str = "",
              theme: str = "", dry_run: bool = False) -> str:
    """Connect a title or generator at an exact time, length and lane — with its words,
    text style and inspector settings — in one call and one undo step ("Add Title" /
    "Add Generator"). No playhead move, no pasteboard.

    Workflow:
        list_titles(filter="lower third")                       # pick a template
        add_title(name="Essential Lower Third", at_seconds=12, duration_seconds=4,
                  text_fields=["Ada Lovelace", "Mathematician"],
                  parameters={"Bar Color": "#1E90FF"}, dry_run=True)
        add_title(...same, without dry_run)                     # answer gives the handle
        get_title_parameters(handle)                            # every setting it has

    Args:
        name: template name, e.g. "Basic Title", "Shapes". A name several templates
              share is refused with the candidates: add theme / category, or use effect_id.
        effect_id: the template's effect ID from list_titles (exact; wins over name).
        at_seconds: timeline seconds of its first frame, as get_timeline_clips reports
              times. Default: the playhead. Snapped to frames. Must be over the primary
              storyline (a connected clip needs a clip or gap under its start).
        duration_seconds: length (default 10). Snapped to frames.
        lane: 1, 2, ... above the primary storyline, -1, ... below; omit (or "auto") for
              the lowest free lane above, which is where FCP's Connect puts a title. A
              lane that already holds a clip in that time range is refused, so nothing
              else on the timeline moves.
        text: the first text field's words. text_fields sets several, in order:
              ["Name", "Role"], or [{"index": 1, "text": "Role", "color": "#FFD400"}].
        font, size, bold, italic, color ("#RRGGBB"), alignment (left / center / right /
              justified): style for the first text field (or put them in a text_fields entry).
        parameters: {inspector label: value} for the template's own settings — a menu by
              its option text, a checkbox true / false, a color "#RRGGBB", a number (percent
              0-100, an angle in degrees), a point [x, y]. Unknown labels are refused with
              the list; get_title_parameters shows them on a placed title.
        kind: "title" or "generator", to narrow name.
        category, theme: narrow name (see list_titles).
        dry_run: report the template, placement and changes; add nothing.

    Undo with history_action("undo").
    """
    params: dict = {}
    try:
        params.update(_change_params(text, text_fields, font, size, bold, italic, color, alignment, parameters))
    except ValueError as e:
        return f"Error: {e}"
    for key, value in (("name", name), ("effectID", effect_id), ("kind", kind),
                       ("category", category), ("theme", theme)):
        if value:
            params[key] = value
    if at_seconds is not None:
        params["atSeconds"] = at_seconds
    params["durationSeconds"] = duration_seconds
    if lane is not None and lane != "":
        params["lane"] = lane
    if dry_run:
        params["dryRun"] = True
    r = bridge.call("titles.add", **params)
    if _err(r):
        return _bridge_error(r)
    t = r.get("template") or {}
    where = " / ".join(x for x in (t.get("category"), t.get("theme")) if x)
    head = "DRY RUN -- nothing was added." if r.get("status") == "dry_run" else (
        f"Added: handle {r.get('handle')}" + ("" if r.get("verified") else
                                               "  (WARNING: the read-back placement differs; check get_timeline_clips)"))
    lines = [head,
             f"  {t.get('kind', 'title')} {t.get('name')} ({where})  effect_id={t.get('effectID')}",
             f"  lane {r.get('lane')}, {_secs(r.get('start'))} - {_secs(r.get('end'))} ({_secs(r.get('duration'))})"]
    lines += _change_lines(r)
    if r.get("status") != "dry_run":
        lines.append(f'  One undo step ("{r.get("undoName")}"): history_action("undo").')
    return "\n".join(lines)


@splicekit_tool("get_title_parameters", READ, title="Read a title's settings")
def get_title_parameters(handle: str) -> str:
    """Everything FCP's Title / Generator inspector shows for a title or generator on the
    timeline: each text field (words, font, size, bold / italic, color, alignment) and
    each published parameter with its kind, current value, range and menu options.

    Args:
        handle: the title or generator's handle from get_timeline_clips().

    The parameter names and values are what set_title_parameters takes.
    """
    r = bridge.call("titles.getParameters", handle=handle)
    if _err(r):
        return _bridge_error(r)
    where = " / ".join(x for x in (r.get("category"), r.get("theme")) if x)
    lines = [f"{r.get('kind', 'title')} {r.get('name')} ({r.get('template')}{', ' + where if where else ''})",
             f"  handle {handle}, lane {r.get('lane')}, {_secs(r.get('start'))} - {_secs(r.get('end'))}",
             f"  effect_id={r.get('effectID')}"]
    fields = r.get("textFields") or []
    lines.append(f"Text fields ({len(fields)}):" if fields else "Text fields: none")
    lines += [_field_line(f) for f in fields]
    params = r.get("parameters") or []
    lines.append(f"Parameters ({len(params)}):" if params else "Parameters: none")
    lines += [_param_line(p) for p in params]
    return "\n".join(lines)


@splicekit_tool("set_title_parameters", DESTRUCTIVE, title="Change a title's text and settings")
def set_title_parameters(handle: str, text: str = "", text_fields: list | str | None = None,
                         font: str = "", size: float | None = None, bold: bool | None = None,
                         italic: bool | None = None, color: str | list | None = None,
                         alignment: str = "", parameters: dict | str | None = None,
                         dry_run: bool = False) -> str:
    """Change a title or generator's words, text style and inspector settings, in one call
    and one undo step ("Set Title Text" for text alone, else "Edit Title"; inside a
    begin_edit group it joins the group). Every value is checked before anything changes.

    Args:
        handle: the title or generator's handle from get_timeline_clips().
        text: new words for the first text field (keeps the template's look).
        text_fields: several fields, in order: ["Name", "Role"], or objects
              [{"index": 1, "text": "Role", "font": "Futura", "size": 48, "color": "#FFD400"}].
        font (family or PostScript name), size (points), bold, italic, color ("#RRGGBB"
              or [r, g, b] 0-1), alignment (left / center / right / justified): style for the
              whole first field (use text_fields for another field).
        parameters: {inspector label: value}: a menu by option text (or index), a checkbox
              true / false, a color "#RRGGBB", a number (percent 0-100, angle in degrees),
              a point [x, y]. get_title_parameters lists the labels, kinds, ranges and
              options; anything else is refused with that list. A keyframed parameter is
              left alone (setting one value would erase its animation).
        dry_run: report before -> after; change nothing.

    Undo with history_action("undo"): it restores the words, style and settings, and redo
    re-applies them.
    """
    try:
        params = _change_params(text, text_fields, font, size, bold, italic, color, alignment, parameters)
    except ValueError as e:
        return f"Error: {e}"
    params["handle"] = handle
    if dry_run:
        params["dryRun"] = True
    r = bridge.call("titles.setParameters", **params)
    if _err(r):
        return _bridge_error(r)
    head = "DRY RUN -- nothing was changed." if r.get("status") == "dry_run" else f"Changed {handle}:"
    lines = [head] + _change_lines(r)
    if r.get("status") != "dry_run":
        lines.append(f'  One undo step ("{r.get("undoName")}"): history_action("undo").')
    return "\n".join(lines)
