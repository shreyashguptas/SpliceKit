#!/usr/bin/env python3
"""
live_titles_check.py — titles.* against a LIVE Final Cut Pro, every change undone.

    python3 tests/live/live_titles_check.py [--project NAME]

Needs a throwaway project open (default "Titles Test") whose primary storyline runs from
0 s to at least 20 s; it refuses to run on any other project name. Every add and edit
it makes is undone with one undo and checked: the timeline and the title's settings must
be back where they started.

Covers: the catalog (themes tell apart the many templates sharing a name), adding a
title and a generator at an exact time / length / lane with text and parameters,
"auto" and explicit lanes, a lane below the primary storyline, the refusals (ambiguous
name, occupied lane, lane 0, time outside the storyline, unknown parameter, bad menu
option, bad color, out-of-range number, missing text field), dry runs, text style
(font, bold, size, color, alignment), undo / redo / undo of an edit, and edits inside
a timeline.beginEdit group (one undo step for the group).
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from live_rpc import rpc  # noqa: E402

FAILS = []


def call(method, params=None, timeout=120):
    r = rpc(method, params or {}, timeout=timeout)
    if "error" in r:
        return {"error": r["error"].get("message", r["error"])}
    return r.get("result", {})


def check(label, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}" + (f"  ({detail})" if detail and not ok else ""))
    if not ok:
        FAILS.append(label)


def connected():
    state = call("timeline.getDetailedState", {"limit": 200})
    items = state.get("connectedItems") or []
    return sorted((round(c.get("startTime", {}).get("seconds", -1), 3), c.get("lane"), c.get("name"))
                  for c in items)


def undo(expected):
    r = call("timeline.action", {"action": "undo"})
    check(f"undo is one step named '{expected}'", r.get("actionName") == expected, str(r))


def redo(expected):
    r = call("timeline.action", {"action": "redo"})
    check(f"redo '{expected}'", r.get("actionName") == expected, str(r))


def settings(handle):
    p = call("titles.getParameters", {"handle": handle})
    return ([(f["text"], f.get("color"), f.get("size"), f.get("font"), f.get("alignment"))
             for f in p.get("textFields", [])],
            {x["key"]: x.get("value") for x in p.get("parameters", [])})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default="Titles Test")
    args = ap.parse_args()

    opened = call("project.open", {"name": args.project})
    if opened.get("project") != args.project:
        print(f"refusing to run: could not open the throwaway project {args.project!r}: {opened}")
        return 2
    baseline = connected()
    print(f"project {args.project!r}: {len(baseline)} connected clips")

    print("\n[catalog]")
    bugs = call("titles.list", {"kind": "title", "filter": "Bug"}).get("items", [])
    themes = {b["theme"] for b in bugs if b["name"] == "Bug"}
    check("many 'Bug' titles, each with its own theme", len(bugs) > 1 and len(themes) == len(
        [b for b in bugs if b["name"] == "Bug"]), str(len(bugs)))
    check("shared names are flagged", all(b.get("nameIsShared") for b in bugs if b["name"] == "Bug"))
    gens = call("titles.list", {"kind": "generator"}).get("items", [])
    check("generators listed", any(g["name"] == "Shapes" for g in gens))

    print("\n[refusals: nothing may change]")
    r = call("titles.add", {"name": "Bug", "atSeconds": 1, "durationSeconds": 2})
    check("ambiguous name refused with candidates", "error" in r and "candidates" in str(r) or "templates match" in str(r), str(r)[:200])
    r = call("titles.add", {"name": "Basic Title", "atSeconds": 4, "durationSeconds": 2, "lane": 1})
    check("occupied lane refused", "already has a clip" in str(r), str(r)[:200])
    r = call("titles.add", {"name": "Basic Title", "atSeconds": 4, "durationSeconds": 2, "lane": 0})
    check("lane 0 refused", "lane 0" in str(r), str(r)[:200])
    r = call("titles.add", {"name": "Basic Title", "atSeconds": 999, "durationSeconds": 2})
    check("time outside the storyline refused", "outside the primary storyline" in str(r), str(r)[:200])
    r = call("titles.add", {"name": "Basic Title", "atSeconds": 1, "durationSeconds": 2, "dryRun": True})
    check("dry run reports and adds nothing", r.get("status") == "dry_run", str(r)[:200])
    check("timeline unchanged after refusals and dry run", connected() == baseline)

    print("\n[add a title: exact time, length, lane, text, parameters]")
    r = call("titles.add", {"name": "Bug", "theme": "Kinetic", "atSeconds": 1.0, "durationSeconds": 2.5,
                            "textFields": ["Kinetic bug"]})
    check("theme picks one of the shared names", r.get("status") == "ok", str(r)[:300])
    check("placed exactly (1.0-3.5 s) and verified", r.get("verified") and abs(r.get("start", -1) - 1.0) < 0.02
          and abs(r.get("end", -1) - 3.5) < 0.02, str(r)[:300])
    check("auto lane is the lowest free one", r.get("lane", 0) >= 1, str(r.get("lane")))
    undo("Add Title")
    check("one undo removes it", connected() == baseline)

    r = call("titles.add", {"name": "Essential Lower Third", "atSeconds": 8, "durationSeconds": 3, "lane": 3,
                            "textFields": ["Name", "Role"],
                            "parameters": {"Bar Color": "#22AA55", "Title Animation": "None", "Build In": False}})
    h = r.get("handle")
    check("lower third added on lane 3 at 8-11 s", r.get("status") == "ok" and r.get("lane") == 3 and r.get("verified"), str(r)[:300])
    texts, params = settings(h)
    check("its text fields were set", [t[0] for t in texts] == ["Name", "Role"], str(texts))
    check("its parameters were set", params.get("Bar Color") == "#22AA55" and params.get("Title Animation") == "None"
          and params.get("Build In") is False, str(params))
    redo_target = "Add Title"
    undo(redo_target)
    check("undo removes the styled title", connected() == baseline)
    redo(redo_target)
    check("redo puts it back", len(connected()) == len(baseline) + 1)
    undo(redo_target)

    print("\n[add a generator, and a lane below the storyline]")
    r = call("titles.add", {"name": "Shapes", "kind": "generator", "atSeconds": 9, "durationSeconds": 2,
                            "parameters": {"Shape": "Heart", "Fill Color": "#FF0000", "Outline": False,
                                           "Drop Shadow Opacity": 40, "Drop Shadow Angle": 90, "Center": [0.3, 0.6]}})
    g = r.get("handle")
    check("generator added", r.get("status") == "ok" and r.get("verified"), str(r)[:300])
    _, gp = settings(g)
    check("generator parameters read back in inspector units",
          gp.get("Shape") == "Heart" and gp.get("Fill Color") == "#FF0000" and gp.get("Outline") is False
          and abs(gp.get("Drop Shadow Opacity", 0) - 40) < 0.01 and abs(gp.get("Drop Shadow Angle", 0) - 90) < 0.01
          and [round(v, 3) for v in gp.get("Center", [])] == [0.3, 0.6], str(gp))
    undo("Add Generator")
    r = call("titles.add", {"name": "Basic Title", "atSeconds": 1, "durationSeconds": 1, "lane": -1})
    check("lane -1 (below the storyline) accepted", r.get("status") == "ok" and r.get("lane") == -1, str(r)[:300])
    undo("Add Title")
    check("timeline back at baseline", connected() == baseline)

    print("\n[edit an existing title]")
    r = call("titles.add", {"name": "Essential Lower Third", "atSeconds": 8, "durationSeconds": 3, "lane": 3})
    h = r.get("handle")
    before = settings(h)
    for label, params, needle in [
        ("unknown parameter refused, names listed", {"parameters": {"Nope": 1}}, "This template has"),
        ("bad menu option refused, options listed", {"parameters": {"Title Animation": "Spin"}}, "Options:"),
        ("bad color refused", {"parameters": {"Bar Color": "red"}}, "is a color"),
        ("out-of-range number refused", {"parameters": {"Bar Opacity": 5}}, "must be between"),
        ("missing text field refused", {"textFields": [{"index": 7, "text": "x"}]}, "does not exist"),
        ("unknown font refused", {"text": "x", "font": "No Such Font 123"}, "No font called"),
        ("text and text_fields together refused", {"text": "x", "textFields": ["y"]}, "not both"),
    ]:
        r = call("titles.setParameters", dict(params, handle=h))
        check(label, needle in str(r), str(r)[:200])
    check("refusals changed nothing", settings(h) == before, str(settings(h)))
    r = call("titles.setParameters", {"handle": h, "text": "Dry", "dryRun": True})
    check("dry run changes nothing", r.get("status") == "dry_run" and settings(h) == before)

    r = call("titles.setParameters", {"handle": h, "text": "Styled", "font": "Futura", "bold": True, "size": 90,
                                       "color": "#FF8800", "alignment": "center"})
    texts, _ = settings(h)
    check("text style applied (font, size, color, alignment)",
          texts[0][0] == "Styled" and texts[0][1] == "#FF8800" and texts[0][2] == 90 and texts[0][3] == "Futura"
          and texts[0][4] == "center", str(texts[0]))
    check("text-only edit is named 'Set Title Text'", r.get("undoName") == "Set Title Text", str(r.get("undoName")))
    undo("Set Title Text")
    check("undo restores text and style", settings(h) == before, str(settings(h)))

    r = call("titles.setParameters", {"handle": h, "textFields": [{"text": "A"}, {"text": "B"}],
                                       "parameters": {"Bar Opacity": 0.5, "Subtitle": False}})
    after = settings(h)
    check("text + parameters edit is named 'Edit Title'", r.get("undoName") == "Edit Title", str(r.get("undoName")))
    undo("Edit Title")
    check("undo restores both", settings(h) == before, str(settings(h)))
    redo("Edit Title")
    check("redo re-applies both", settings(h) == after, str(settings(h)))
    undo("Edit Title")
    check("undo after redo restores both again", settings(h) == before, str(settings(h)))

    print("\n[inside a beginEdit group]")
    call("timeline.beginEdit", {"name": "Titles group"})
    call("titles.setParameters", {"handle": h, "text": "Grouped"})
    r2 = call("titles.add", {"name": "Basic Title", "atSeconds": 12, "durationSeconds": 1, "lane": 4})
    call("timeline.endEdit", {})
    check("both changes made", settings(h)[0][0][0] == "Grouped" and r2.get("status") == "ok", str(r2)[:200])
    undo("Titles group")
    check("one undo reverts the whole group", settings(h) == before and len(connected()) == len(baseline) + 1,
          str(settings(h)))

    undo("Add Title")
    check("timeline back at baseline at the end", connected() == baseline, str(connected()))

    print(f"\n{'ALL PASSED' if not FAILS else f'{len(FAILS)} FAILED: ' + ', '.join(FAILS)}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
