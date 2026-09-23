#!/usr/bin/env python3
"""Generate Sources/SpliceKitBridgeParams.m: the parameters each bridge RPC reads.

bridge.describe used to give a method's safety tag and a one-line summary only, so
a parameter such as fcpxml.import's `xml` (and the absence of `path`) was found by
trial and error. The handlers are the only complete record of what each method
reads, so this script reads them: for every method dispatched in
SpliceKit_handleRequest to `result = SpliceKit_handleX(params)`, it collects the
keys the handler reads from `params` (`params[@"key"]`, `helper(params, @"key")`),
following calls that pass `params` on, two levels deep.

A few methods carry hand-written descriptions (DESCRIBED below); those win over the
inferred list for the keys they name.

Run after changing a handler's parameters:
    python3 tools/gen_bridge_params.py
tests/test_bridge_params_generated.py fails when the generated file is stale.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SOURCES = REPO / "Sources"
OUTPUT = SOURCES / "SpliceKitBridgeParams.m"

DISPATCH_RE = re.compile(
    r'\[method isEqualToString:@"([^"]+)"\]\)\s*\{\s*result\s*=\s*(SpliceKit_\w+)\(params\)')
FUNC_RE_TMPL = r'^(?:static\s+)?NSDictionary\s*\*\s*{name}\s*\(\s*NSDictionary\s*\*\s*params\s*\)\s*\{{'
KEY_RES = [
    re.compile(r'params\[@"([A-Za-z_][A-Za-z0-9_]*)"\]'),
    re.compile(r'\(\s*params\s*,\s*@"([A-Za-z_][A-Za-z0-9_]*)"'),
]
CALL_RE = re.compile(r'\b(SpliceKit_\w+)\(\s*params\s*[,)]')

# Hand-written descriptions for methods whose parameters are not obvious from their
# names. Keys listed here are described; any other key the handler reads is still
# listed (as "read by the handler").
DESCRIBED: dict[str, dict[str, str]] = {
    "fcpxml.import": {
        "xml": "string: the FCPXML document (this or path)",
        "path": "string: a .fcpxml file on this Mac, plain path or file:// URL (this or xml)",
        "internal": "bool: import through FCP's pasteboard importer (no library chooser). Default true with path, false with xml",
        "library": "string: name of the open library to import into (default: the one the XML's <library location> names, else the first open library)",
        "async": "bool: start the import and return a jobId at once; poll fcpxml.importStatus",
        "mainThreadTimeout": "number: seconds to wait for FCP's main thread (default 20; 3600 with async)",
        "allowFileFallback": "bool: if the internal import fails, open the file with FCP instead (may show the library chooser)",
    },
    "fcpxml.importStatus": {
        "jobId": "string: the job from fcpxml.import async=true (omit to list every job)",
    },
    "transcript.open": {
        "fileURL": "string: transcribe this file instead of the timeline; plain path, ~/path or file:// URL",
        "forceRetranscribe": "bool: discard the cached transcript (and stop a run in progress) and transcribe again",
        "primaryStorylineOnly": "bool: transcribe only the primary storyline (connected clips left out); remembered",
        "timelineStart": "number: file mode, timeline seconds the file's first word is shifted to",
    },
    "transcript.getState": {
        "wordsOnly": "bool: words and counts only (no text, silences or gap histogram)",
        "fields": "array or comma-separated string: word keys to return (index,text,startTime,endTime,duration,confidence,speaker)",
        "startSeconds": "number: only words/silences overlapping this timeline window",
        "endSeconds": "number: end of that window",
        "offset": "int: skip this many (windowed) words",
        "limit": "int: return at most this many words; nextOffset gives the next page",
        "includeWords": "bool (default true)",
        "includeSilences": "bool (default true unless wordsOnly)",
        "includeText": "bool (default true unless wordsOnly)",
        "includeGapBuckets": "bool (default true unless wordsOnly)",
        "includeSkipped": "bool: list clips the last run left out and why (default true)",
    },
    "timeline.captureClipFrame": {
        "handle": "string: clip handle from timeline.getDetailedState",
        "frameTime": "number: timeline seconds (default the clip's midpoint)",
        "frameMaxWidth": "int: 64-1920 (default 960)",
        "path": "string: where to write the PNG",
        "restorePlayhead": "bool (default true)",
        "renderTimeout": "number: seconds to wait for the Viewer to show the new frame (default 5, max 15)",
    },
}


def function_body(name: str, sources: dict[Path, str]) -> str | None:
    pattern = re.compile(FUNC_RE_TMPL.format(name=re.escape(name)), re.M)
    for text in sources.values():
        m = pattern.search(text)
        if not m:
            continue
        end = text.find("\n}\n", m.end())
        return text[m.end(): end if end != -1 else len(text)]
    return None


def keys_for(name: str, sources: dict[Path, str], depth: int = 0, seen: set[str] | None = None) -> set[str]:
    seen = seen if seen is not None else set()
    if name in seen or depth > 2:
        return set()
    seen.add(name)
    body = function_body(name, sources)
    if body is None:
        return set()
    keys: set[str] = set()
    for regex in KEY_RES:
        keys.update(regex.findall(body))
    for callee in CALL_RE.findall(body):
        if callee != name:
            keys |= keys_for(callee, sources, depth + 1, seen)
    return keys


def objc_string(text: str) -> str:
    return '@"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def generate() -> str:
    sources = {p: p.read_text(encoding="utf-8") for p in sorted(SOURCES.rglob("*.m"))}
    server = sources[SOURCES / "SpliceKitServer.m"]
    start = server.index("NSDictionary *SpliceKit_handleRequest")
    end = server.index("#pragma mark - Client Handler", start)
    dispatch = DISPATCH_RE.findall(server[start:end])

    table: dict[str, dict[str, str]] = {}
    for method, handler in dispatch:
        keys = keys_for(handler, sources)
        keys.discard("async")  # the dispatcher's, not the handler's
        described = DESCRIBED.get(method, {})
        entry = {k: "read by the handler" for k in sorted(keys)}
        entry.update(described)
        table[method] = entry
    for method, described in DESCRIBED.items():
        table.setdefault(method, {}).update(described)

    lines = [
        "// GENERATED by tools/gen_bridge_params.py -- do not edit by hand.",
        "// The parameters each bridge RPC method reads, for bridge.describe.",
        "",
        "#import <Foundation/Foundation.h>",
        "",
        "NSDictionary<NSString *, NSString *> *SpliceKit_bridgeParamsForMethod(NSString *method) {",
        "    static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *table = nil;",
        "    static dispatch_once_t once;",
        "    dispatch_once(&once, ^{",
        "        table = @{",
    ]
    for method in sorted(table):
        params = table[method]
        if params:
            inner = ", ".join(f"{objc_string(k)}: {objc_string(v)}" for k, v in sorted(params.items()))
            lines.append(f"            {objc_string(method)}: @{{{inner}}},")
        else:
            lines.append(f"            {objc_string(method)}: @{{}},")
    lines += [
        "        };",
        "    });",
        "    return table[method];",
        "}",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    text = generate()
    if "--check" in sys.argv:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current != text:
            print(f"{OUTPUT.relative_to(REPO)} is stale: run python3 tools/gen_bridge_params.py")
            return 1
        return 0
    OUTPUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
