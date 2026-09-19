# SpliceKit

An MCP server for Final Cut Pro, so Claude or any other MCP client can read and
edit your timeline: open projects, list and inspect clips, blade, trim, add clips
from the browser, apply effects and transitions, work from a transcript, export.
It also adds a Command Palette inside Final Cut Pro (Cmd+Shift+P).

This is my build of [SpliceKit](https://github.com/elliotttate/SpliceKit) by
Elliott Tate. The only way to get it is to build it from this repository. There
are no downloads, no auto-update and no crash or usage reporting; nothing is sent
anywhere. If you want the original project and its releases, go to the link above.

## What it does to your Mac

It never touches your Final Cut Pro. It makes a copy of it at
`/Applications/Final Cut Pro Modified.app` (about 7 GB), injects the SpliceKit
library built from this checkout, and re-signs the copy. Everything runs inside
that copy: a local bridge on `127.0.0.1:9876` that the MCP server talks to. Your
original app, libraries and media are unchanged, and you can keep using them
with either app.

## Install

You need a Mac on macOS 14 or newer with Final Cut Pro in `/Applications`
(developed against Final Cut Pro 12.3) and about 10 GB of free disk space. Quit
Final Cut Pro and Claude Desktop first. Then:

```bash
git clone https://github.com/shreyashguptas/SpliceKit.git
cd SpliceKit
make install
```

That one command does the whole install and asks before it installs anything:

1. Xcode Command Line Tools and a Python 3.10+ (offered if missing; macOS ships 3.9).
2. The patched copy of Final Cut Pro, built from this checkout.
3. The MCP server in its own virtualenv, checked end to end over the real MCP
   protocol before it is wired into Claude Desktop and Claude Code.
4. The patched app opened and read from through that server, so "it works" is
   verified, not assumed.

It is safe to re-run; every step checks whether it already did its work. To see
what is and isn't set up without changing anything, run `make install-check`.

## Use

Open "Final Cut Pro Modified". Press Cmd+Shift+P for the Command Palette. Claude
Desktop and Claude Code are configured by the install (fully quit and reopen
Claude Desktop once). For any other MCP client, use the virtualenv's Python as
the command and this checkout's server as the argument:

```json
{
  "mcpServers": {
    "splicekit": {
      "command": "/Users/yourname/.venvs/splicekit-mcp/bin/python",
      "args": ["/absolute/path/to/SpliceKit/mcp/server.py"]
    }
  }
}
```

The patched Final Cut Pro has to be running for the server to have anything to
talk to.

## Uninstall

```bash
./patcher/patch_fcp.sh --app-name "Final Cut Pro Modified" --uninstall
```

## More

The tool-by-tool guide is [CLAUDE.md](CLAUDE.md); the rest is under [docs/](docs/).
What touches the network, and when, is listed in
[docs/THIRD_PARTY_DEPENDENCIES.md](docs/THIRD_PARTY_DEPENDENCIES.md).

MIT licensed; see [LICENSE](LICENSE).
