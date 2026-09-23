#!/usr/bin/env python3
"""The docs name real MCP tools, and the tool reference lists every tool.

(a) Every tool the server registers appears in docs/reference/mcp-tools.md.
(b) Every call-like `snake_name(` written in code (a fenced block or an inline code
    span) in .claude/CLAUDE.md, docs/guides and docs/reference names a registered tool,
    unless it is on DOC_CALL_ALLOWLIST below. A name only counts when it contains an
    underscore; a name right after "." or ":" is skipped (Lua sk.* functions, Python
    calls like json.loads, RPC names written with dots such as timeline.addMarkers),
    and so are fences in languages that are not tool calls (Objective-C, Swift, C, shell).

Offline: the tools come from tests/support/server_loader.py, no FCP and no mcp package.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from support.server_loader import load_server_module  # noqa: E402

REPO = Path(__file__).resolve().parents[1]
TOOL_REFERENCE = REPO / "docs" / "reference" / "mcp-tools.md"
CHECKED_DOCS = (
    [REPO / ".claude" / "CLAUDE.md"]
    + sorted((REPO / "docs" / "guides").glob("*.md"))
    + sorted((REPO / "docs" / "reference").glob("*.md"))
)

# Fence languages whose calls are not MCP tool calls (C functions such as
# dispatch_async( or objc_msgSend(, shell commands).
NON_TOOL_FENCES = {"objc", "objective-c", "swift", "c", "cpp", "bash", "sh", "zsh", "shell", "csharp", "cs"}

# Call-like snake_case names in the docs that are not MCP tools, each with its reason.
# Keep this small: a name that should be a tool is a doc bug, not an allowlist entry.
DOC_CALL_ALLOWLIST = {
    "check_fn": "Lua: the callback parameter of the wait_for() helper in guides/lua-scripting.md",
    "swift_demangle": "C: libswiftCore's demangler, named where get_image_symbols is described",
}


def _code_segments(text):
    """Yield (fence_language, code) for every fenced block and inline code span."""
    fence = re.compile(r"^(```+|~~~+)([^\n`]*)\n(.*?)^\1[ \t]*$", re.S | re.M)
    rest = []
    last = 0
    for m in fence.finditer(text):
        rest.append(text[last:m.start()])
        last = m.end()
        yield m.group(2).strip().lower(), m.group(3)
    rest.append(text[last:])
    for chunk in rest:
        for span in re.finditer(r"`([^`\n]+)`", chunk):
            yield "", span.group(1)


CALL = re.compile(r"(?<![\w.:$@-])([a-z][a-z0-9]*(?:_[a-z0-9]+)+)\(")
# A definition, not a call: "def name(", "function name(", "local function name(".
DEFINITION = re.compile(r"\b(?:def|function|func)\s+([a-z][a-z0-9_]*)\s*\(")


def doc_calls(path):
    """Tool-like calls written in code in one doc: {name: first line number}.

    Functions the doc defines itself (in any of its code blocks) are not calls to tools."""
    text = path.read_text(encoding="utf-8")
    segments = [(lang, code) for lang, code in _code_segments(text)
                if not (lang.split() and lang.split()[0] in NON_TOOL_FENCES)]
    defined = {name for _, code in segments for name in DEFINITION.findall(code)}
    found = {}
    for lang, code in segments:
        for m in CALL.finditer(code):
            name = m.group(1)
            if name in defined:
                continue
            if name not in found:
                found[name] = text[: text.find(code)].count("\n") + 1 + code[: m.start()].count("\n")
    return found


class DocsToolNameTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        module = load_server_module()
        cls.tools = {entry["name"] for entry in module.mcp.tools}

    def test_tool_list_loaded(self):
        self.assertGreater(len(self.tools), 100)

    def test_every_tool_is_in_the_tool_reference(self):
        text = TOOL_REFERENCE.read_text(encoding="utf-8")
        missing = sorted(n for n in self.tools if not re.search(r"(?<![\w])" + re.escape(n) + r"(?![\w])", text))
        self.assertEqual(missing, [], f"tools missing from {TOOL_REFERENCE.relative_to(REPO)}")

    def test_doc_calls_name_registered_tools(self):
        unknown = []
        for path in CHECKED_DOCS:
            for name, line in sorted(doc_calls(path).items()):
                if name in self.tools or name in DOC_CALL_ALLOWLIST:
                    continue
                unknown.append(f"{path.relative_to(REPO)}:{line}: {name}(")
        self.assertEqual(unknown, [], "calls in the docs that name no registered MCP tool "
                                      "(fix the doc, or add the name to DOC_CALL_ALLOWLIST with a reason)")

    def test_scanner_reads_code_and_skips_the_rest(self):
        import tempfile
        doc = (
            "Prose mentions not_a_call(here) outside code.\n"
            "`get_timeline_clips()` and `made_up_tool(1)` in spans.\n"
            "```lua\nsk.rpc_call(1)\nlocal function my_helper(x) end\nmy_helper(2)\n```\n"
            "```objc\ndispatch_async(q, ^{});\n```\n"
            "```\njson.loads(x)\nblade_at_times([1.0])\n```\n"
        )
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as fh:
            fh.write(doc)
        try:
            found = set(doc_calls(Path(fh.name)))
        finally:
            Path(fh.name).unlink()
        self.assertEqual(found, {"get_timeline_clips", "made_up_tool", "blade_at_times"})

    def test_allowlist_entries_are_not_tools(self):
        self.assertEqual(sorted(set(DOC_CALL_ALLOWLIST) & self.tools), [])


if __name__ == "__main__":
    unittest.main()
