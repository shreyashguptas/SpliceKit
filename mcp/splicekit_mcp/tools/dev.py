"""Tools: build, deploy and restart Final Cut Pro."""

from ..config import REPO_ROOT
from ..registry import splicekit_tool
from ..bridge import _err, bridge


# ============================================================
# Deploy & Restart FCP
# ============================================================
# One-shot command to resolve modded app, quit FCP, build/deploy, relaunch,
# and wait for the bridge to come back online.

@splicekit_tool("deploy_and_restart")
def deploy_and_restart(skip_build: bool = False) -> str:
    """Build SpliceKit, deploy to the modded FCP app, and restart FCP.

    This automates the entire deploy cycle:
    1. Resolve the modded FCP app path (same precedence as the Makefile)
    2. Quit Final Cut Pro and wait for the process to exit
    3. Run `make deploy` (builds dylib + copies to framework path + re-signs)
    4. Relaunch the modded FCP
    5. Wait for the SpliceKit bridge to come online (up to 30 seconds)

    Args:
        skip_build: If True, skip `make deploy` and just restart FCP.
                    Useful when you've already built and just need to relaunch.

    Returns success/failure status and bridge connection state.
    """
    import subprocess, os, time as _time

    project_dir = REPO_ROOT
    results = []

    modded_modified = "/Applications/Final Cut Pro Modified.app"
    modded_standard = os.path.expanduser("~/Applications/SpliceKit/Final Cut Pro.app")
    modded_creator = os.path.expanduser(
        "~/Applications/SpliceKit/Final Cut Pro Creator Studio.app"
    )
    modded_app = None
    for candidate in (modded_modified, modded_standard, modded_creator):
        if os.path.isdir(candidate):
            modded_app = candidate
            break
    if modded_app is None:
        return (
            "Error: modded FCP not found at "
            f"{modded_modified}, {modded_standard}, or {modded_creator}"
        )

    def _fcp_is_running() -> bool:
        try:
            proc = subprocess.run(
                ["pgrep", "-x", "Final Cut Pro"],
                capture_output=True,
                timeout=5,
            )
            return proc.returncode == 0
        except Exception:
            return False

    def _quit_through_bridge() -> bool:
        """Ask Final Cut Pro to quit itself, the way the Quit menu item does.

        SIGTERM is not good enough here. Final Cut Pro flushes its library metadata on a
        real -[NSApplication terminate:], not on a signal: killed with pkill it comes back
        with library changes from the session undone, which is how three scratch projects
        that had just been removed reappeared after a restart. This tool runs against the
        user's real libraries, so it asks the app to quit and only falls back to a signal
        when the bridge cannot be reached at all.

        This is the app's own AppKit method called in-process over the bridge. It is not
        AppleScript, not a synthetic key event and not the accessibility API.
        """
        try:
            app = bridge.call(
                "system.callMethodWithArgs",
                target="NSApplication", selector="sharedApplication",
                args=[], classMethod=True, returnHandle=True,
            )
            handle = (app or {}).get("handle")
            if not handle:
                return False
            bridge.call(
                "system.callMethodWithArgs",
                target=handle, selector="terminate:",
                args=[{"type": "nil"}], classMethod=False,
            )
            return True
        except Exception:
            return False

    # Step 2: Quit FCP before deploy (make deploy removes the in-app framework)
    if _fcp_is_running():
        if not _quit_through_bridge():
            results.append("Bridge unreachable; fell back to SIGTERM")
            try:
                subprocess.run(
                    ["pkill", "-x", "Final Cut Pro"], capture_output=True, timeout=5
                )
            except Exception as e:
                return f"Error sending quit to Final Cut Pro: {e}"

        quit_deadline = _time.time() + 30
        while _time.time() < quit_deadline:
            if not _fcp_is_running():
                results.append("Quit FCP: OK")
                break
            _time.sleep(0.5)
        else:
            return (
                "Error: Final Cut Pro did not exit within 30s after SIGTERM. "
                "Not running make deploy — quit FCP manually (Cmd+Q) and retry."
            )
    else:
        results.append("FCP was not running")

    # Step 3: Build and deploy (only after FCP has exited)
    if not skip_build:
        try:
            proc = subprocess.run(
                ["make", "deploy"],
                cwd=project_dir,
                capture_output=True,
                text=True,
                timeout=900,
            )
            if proc.returncode != 0:
                return f"Build failed (exit {proc.returncode}):\n{proc.stderr}\n{proc.stdout}"
            results.append("Build + deploy: OK")
        except subprocess.TimeoutExpired:
            return (
                "Error: make deploy timed out after 900s. "
                "The app's SpliceKit.framework may already have been replaced; "
                "check the modded app and relaunch manually if needed."
            )
        except Exception as e:
            return f"Error running make deploy: {e}"

    # Step 4: Relaunch
    try:
        subprocess.Popen(["open", modded_app])
        results.append(f"Launched: {os.path.basename(modded_app)}")
    except Exception as e:
        return f"Error launching FCP: {e}"

    # Step 5: Wait for bridge
    # Drop the existing connection so we don't use a stale socket
    bridge.reset()

    max_wait = 30
    start = _time.time()
    connected = False
    while _time.time() - start < max_wait:
        _time.sleep(2)
        try:
            r = bridge.call("system.version")
            if not _err(r):
                connected = True
                break
        except Exception:
            pass
        bridge.reset()  # reset on failure

    if connected:
        results.append(f"Bridge connected ({_time.time() - start:.1f}s)")
        return "\n".join(results)
    else:
        results.append(f"Bridge NOT connected after {max_wait}s — FCP may still be loading")
        return "\n".join(results)
