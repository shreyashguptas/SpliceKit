#!/usr/bin/env python3
"""Read or update the "splicekit" entry in a Claude Desktop config file.

Kept deliberately small and dependency-free so it runs under any system
python3. Merges into the existing config: other MCP servers and every
unrelated preference are preserved untouched.

Usage:
    claude_config.py show  <config.json>
    claude_config.py write <config.json> <python-path> <server-path>
"""
from __future__ import annotations

import json
import sys


def load(path: str) -> dict:
    try:
        with open(path) as handle:
            cfg = json.load(handle)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as exc:
        sys.exit(f"[X] {path} is not valid JSON ({exc}). Fix or remove it, then re-run.")
    if not isinstance(cfg, dict):
        sys.exit(f"[X] {path} is not a JSON object. Fix or remove it, then re-run.")
    return cfg


def servers_of(cfg: dict, path: str) -> dict:
    """Return the mcpServers mapping, refusing anything that isn't one.

    A hand-edited config can easily end up with a list or a string here. Bailing
    out with an explanation beats a traceback the user has to decode.
    """
    servers = cfg.setdefault("mcpServers", {})
    if not isinstance(servers, dict):
        sys.exit(
            f"[X] {path} has an \"mcpServers\" value of type "
            f"{type(servers).__name__}, expected an object. Fix it, then re-run."
        )
    return servers


def show(path: str) -> int:
    entry = servers_of(load(path), path).get("splicekit")
    if isinstance(entry, dict):
        print("[+] splicekit entry present:")
        print(f"      command: {entry.get('command')}")
        print(f"      args:    {entry.get('args')}")
        return 0
    if entry is not None:
        print(f"[!] splicekit entry is a {type(entry).__name__}, expected an object")
        return 1
    print("[!] No splicekit entry yet")
    return 1


def write(path: str, python_path: str, server_path: str) -> int:
    cfg = load(path)
    servers = servers_of(cfg, path)
    preserved = sorted(name for name in servers if name != "splicekit")
    servers["splicekit"] = {"command": python_path, "args": [server_path]}

    with open(path, "w") as handle:
        json.dump(cfg, handle, indent=2)
        handle.write("\n")

    print(f"[+] splicekit entry written to {path}")
    if preserved:
        print(f"[+] Left untouched: {', '.join(preserved)}")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[1] == "show":
        return show(argv[2])
    if len(argv) >= 5 and argv[1] == "write":
        return write(argv[2], argv[3], argv[4])
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
