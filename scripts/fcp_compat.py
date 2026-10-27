#!/usr/bin/env python3
"""Check a Final Cut Pro release for the classes and methods SpliceKit relies on.

SpliceKit calls Final Cut Pro's private Objective-C classes, methods and instance
variables by name. When Apple renames or removes one in an update, the call fails
or, worse, crashes FCP, and nothing says so until someone hits it live. This script
makes that visible before the patched copy is rebuilt from a new release:

  1. It collects every FCP name SpliceKit's source refers to (Sources/, mcp/, lua/):
     classes (NSClassFromString, objc_getClass), selectors (@selector,
     NSSelectorFromString, the SpliceKit_*Selector helpers), instance variables and
     KVC keys, plus every other identifier-shaped string literal in the ObjC source.
  2. It reads the names each FCP binary carries (`strings` over every Mach-O file in
     the app's MacOS, Frameworks and PlugIns folders; SpliceKit's own files are
     skipped, so a patched copy reads the same as the App Store one).
  3. `baseline` keeps the names that the tested release has, in
     patcher/fcp-names-baseline.txt. `scan` reports the ones a release no longer has.

A name that is gone is a lead, not a verdict: the method may have moved to another
class or been renamed, and an "other string" may be a plain dictionary key that only
happened to match. Each one is listed with the lines that use it.

Usage:
    python3 scripts/fcp_compat.py scan [--app APP]       # make fcp-compat
    python3 scripts/fcp_compat.py baseline [--app APP]   # make fcp-baseline
    python3 scripts/fcp_compat.py version [--app APP]    # "12.4 454072"

APP defaults to the App Store copy: /Applications/Final Cut Pro.app, else
/Applications/Final Cut Pro Creator Studio.app. Runs on the system python3 (3.9).
"""

import argparse
import os
import plistlib
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BASELINE = REPO / "patcher" / "fcp-names-baseline.txt"
TESTED_VERSION_FILE = REPO / "FCP_TESTED_VERSION"
DEFAULT_APPS = (
    "/Applications/Final Cut Pro.app",
    "/Applications/Final Cut Pro Creator Studio.app",
)

IDENT = r"[A-Za-z_][A-Za-z0-9_]*"
SEL = IDENT + r"(?::(?:" + IDENT + r":)*)?"

# Names SpliceKit hands to the ObjC runtime: a missing one is a real break.
CALLED_RES = (
    re.compile(r'NSClassFromString\(\s*@"(' + IDENT + r')"'),
    re.compile(r'objc_(?:getClass|lookUpClass|getMetaClass)\(\s*"(' + IDENT + r')"'),
    re.compile(r'NSSelectorFromString\(\s*@"(' + SEL + r')"'),
    re.compile(r'sel_(?:registerName|getUid)\(\s*"(' + SEL + r')"'),
    re.compile(r'@selector\(\s*(' + SEL + r')\s*\)'),
    re.compile(r'(?:class_getInstanceVariable|object_getInstanceVariable|object_setInstanceVariable)'
               r'\([^,()]+,\s*"(' + IDENT + r')"'),
    re.compile(r'SpliceKit_\w*(?:Selector|ForKey)\w*\([^,()]+,\s*@"(' + SEL + r')"'),
    re.compile(r'valueForKey(?:Path)?:\s*@"([A-Za-z0-9_.]+)"'),
)
# Every other identifier- or selector-shaped ObjC string literal. Many are JSON keys
# or log words, so a missing one is only worth a look.
OBJC_LITERAL_RE = re.compile(r'@"(' + SEL + r')"')
# In the Python tools and Lua scripts only strings shaped like FCP class names or
# selectors count; everything else there is a dictionary key.
SCRIPT_LITERAL_RE = re.compile(r'''["']((?:FF|PE|TL|LK|OZ|PC|FM|TX|MI|CK)[A-Z]\w+|''' + IDENT + r''':(?:''' + IDENT + r''':)*)["']''')

OBJC_SUFFIXES = {".m", ".mm", ".h", ".def"}
PRINTABLE_RE = re.compile(rb"[\x20-\x7e]{2,}")


def source_files():
    for root, suffixes in ((REPO / "Sources", OBJC_SUFFIXES),
                           (REPO / "mcp" / "splicekit_mcp", {".py"}),
                           (REPO / "lua", {".lua"})):
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            if path.suffix in suffixes and path.is_file():
                yield path


def collect_source_names():
    """{name: {"called": bool, "uses": ["path:line", ...]}} for every name in the source."""
    names = {}

    def note(name, called, where):
        entry = names.setdefault(name, {"called": False, "uses": []})
        entry["called"] = entry["called"] or called
        if len(entry["uses"]) < 6 and where not in entry["uses"]:
            entry["uses"].append(where)

    for path in source_files():
        rel = path.relative_to(REPO)
        objc = path.suffix in OBJC_SUFFIXES
        text = path.read_text(encoding="utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            where = "%s:%d" % (rel, lineno)
            if objc:
                called = set()
                for pattern in CALLED_RES:
                    for match in pattern.findall(line):
                        # A KVC key path is several keys, each one a method.
                        called.update(part for part in match.split(".") if part)
                for name in called:
                    note(name, True, where)
                for name in OBJC_LITERAL_RE.findall(line):
                    # Three letters or fewer ("pcm", "SIG") match some FCP string by chance.
                    if name not in called and len(name) > 3:
                        note(name, False, where)
            else:
                for name in SCRIPT_LITERAL_RE.findall(line):
                    note(name, True, where)
    return names


def is_macho(path):
    try:
        with open(path, "rb") as handle:
            magic = handle.read(4)
    except OSError:
        return False
    return magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe",
                     b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce", b"\xbe\xba\xfe\xca")


def app_binaries(app):
    contents = Path(app) / "Contents"
    for sub in ("MacOS", "Frameworks", "PlugIns"):
        base = contents / sub
        if not base.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            # SpliceKit's own framework and plugin bundles, in a patched copy.
            dirnames[:] = [d for d in dirnames if "SpliceKit" not in d]
            for filename in filenames:
                path = os.path.join(dirpath, filename)
                if not os.path.islink(path) and is_macho(path):
                    yield path


def app_strings(app, wanted):
    """The members of `wanted` that appear as a string in any of the app's binaries."""
    def scan(path):
        out = subprocess.run(["strings", "-a", "-n", "2", path], capture_output=True)
        lines = out.stdout.splitlines()
        if out.returncode != 0:
            # `strings` refuses a file whose Mach-O header it cannot parse; read the
            # printable runs ourselves.
            with open(path, "rb") as handle:
                lines = PRINTABLE_RE.findall(handle.read())
        found = set()
        for raw in lines:
            word = raw.decode("utf-8", "replace").strip()
            if word in wanted:
                found.add(word)
        return found

    found = set()
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        for part in pool.map(scan, list(app_binaries(app))):
            found |= part
    return found


def app_version(app):
    with open(Path(app) / "Contents" / "Info.plist", "rb") as handle:
        info = plistlib.load(handle)
    return str(info.get("CFBundleShortVersionString", "?")), str(info.get("CFBundleVersion", "?"))


def default_app():
    for candidate in DEFAULT_APPS:
        if os.path.isdir(candidate):
            return candidate
    sys.exit("Final Cut Pro not found in /Applications; pass --app")


def read_baseline():
    if not BASELINE.is_file():
        sys.exit("No baseline at %s; run: make fcp-baseline" % BASELINE.relative_to(REPO))
    header, called, other = {}, set(), set()
    for line in BASELINE.read_text(encoding="utf-8").splitlines():
        if line.startswith("# fcp:"):
            version, _, build = line[len("# fcp:"):].strip().partition(" ")
            header = {"version": version, "build": build}
        elif line and not line.startswith("#"):
            kind, _, name = line.partition(" ")
            (called if kind == "called" else other).add(name)
    return header, called, other


def tested_version():
    values = {}
    if TESTED_VERSION_FILE.is_file():
        for line in TESTED_VERSION_FILE.read_text(encoding="utf-8").splitlines():
            key, sep, value = line.partition("=")
            if sep and not key.startswith("#"):
                values[key.strip()] = value.strip()
    return values.get("version", "?"), values.get("build", "?")


def cmd_baseline(app):
    version, build = app_version(app)
    tested = tested_version()
    if (version, build) != tested:
        print("[!] %s is %s (%s), but FCP_TESTED_VERSION says %s (%s)."
              % (app, version, build, tested[0], tested[1]))
        print("    Write the baseline from the release you checked, and update FCP_TESTED_VERSION to it.")
    names = collect_source_names()
    present = app_strings(app, set(names))
    lines = [
        "# The FCP names SpliceKit refers to that this Final Cut Pro release has.",
        "# Generated by: make fcp-baseline (scripts/fcp_compat.py). Do not edit by hand.",
        "# make fcp-compat reports the ones a newer release no longer has.",
        "# called = handed to the ObjC runtime (class, selector, ivar, KVC key);",
        "# other  = any other string literal that matched.",
        "# fcp: %s %s" % (version, build),
    ]
    for name in sorted(present):
        lines.append("%s %s" % ("called" if names[name]["called"] else "other", name))
    BASELINE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    called = sum(1 for n in present if names[n]["called"])
    print("[+] Wrote %s from Final Cut Pro %s (%s): %d names (%d called, %d other strings)."
          % (BASELINE.relative_to(REPO), version, build, len(present), called, len(present) - called))
    return 0


def cmd_scan(app):
    version, build = app_version(app)
    header, base_called, base_other = read_baseline()
    names = collect_source_names()
    # Only names the source still uses: a baseline entry whose code was deleted is moot.
    check = {n for n in (base_called | base_other) if n in names}
    present = app_strings(app, check)
    gone = sorted(check - present)
    gone_called = [n for n in gone if n in base_called or names[n]["called"]]
    gone_other = [n for n in gone if n not in gone_called]

    print("Final Cut Pro %s (%s) at %s" % (version, build, app))
    print("Compared with the baseline from %s (%s): %d FCP names SpliceKit uses, %d still there."
          % (header.get("version", "?"), header.get("build", "?"), len(check), len(check) - len(gone)))
    if not gone:
        print("[+] Nothing SpliceKit names has gone from this release.")
        print("    Still run the live checks: a method can keep its name and change what it does.")
        return 0
    if gone_called:
        print("\n[X] GONE, and SpliceKit calls them (classes, methods, ivars, keys): %d" % len(gone_called))
        for name in gone_called:
            print("    %-44s %s" % (name, ", ".join(names[name]["uses"])))
    if gone_other:
        print("\n[!] Gone, other strings (often plain dictionary keys; worth a look): %d" % len(gone_other))
        for name in gone_other:
            print("    %-44s %s" % (name, ", ".join(names[name]["uses"])))
    print("\nFind what replaced each one: explore_class / search_methods in the patched app on this")
    print("release, or `strings` over its Frameworks. Then fix the code, run the live checks,")
    print("and update FCP_TESTED_VERSION + make fcp-baseline.")
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("command", choices=("scan", "baseline", "version"))
    parser.add_argument("--app", help="Final Cut Pro app bundle (default: the App Store copy)")
    args = parser.parse_args()
    app = args.app or default_app()
    if args.command == "version":
        print("%s %s" % app_version(app))
        return 0
    if args.command == "baseline":
        return cmd_baseline(app)
    return cmd_scan(app)


if __name__ == "__main__":
    sys.exit(main())
