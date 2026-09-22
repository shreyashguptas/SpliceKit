#!/bin/bash
#
# Launch modded FCP with SpliceKit dylib injected
#

# Where the patched copy lives: `make install` puts it in /Applications as
# "Final Cut Pro Modified.app"; the ~/Applications/SpliceKit paths are installs
# made by older versions of the patcher.
MODDED_MODIFIED="${SPLICEKIT_DEST_DIR:-/Applications}/${SPLICEKIT_APP_NAME:-Final Cut Pro Modified}"
MODDED_MODIFIED="${MODDED_MODIFIED%.app}.app"
MODDED_STANDARD="$HOME/Applications/SpliceKit/Final Cut Pro.app"
MODDED_CREATOR="$HOME/Applications/SpliceKit/Final Cut Pro Creator Studio.app"
if [ -d "$MODDED_MODIFIED" ]; then
    MODDED_APP="$MODDED_MODIFIED"
elif [ -d "$MODDED_STANDARD" ]; then
    MODDED_APP="$MODDED_STANDARD"
elif [ -d "$MODDED_CREATOR" ]; then
    MODDED_APP="$MODDED_CREATOR"
else
    MODDED_APP="$MODDED_MODIFIED"
fi
DYLIB="$MODDED_APP/Contents/Frameworks/SpliceKit.framework/Versions/A/SpliceKit"

if [ ! -f "$DYLIB" ]; then
    echo "ERROR: SpliceKit dylib not found at: $DYLIB"
    echo "Run 'make install' first."
    exit 1
fi

echo "=== Launching Final Cut Pro with SpliceKit ==="
echo "  Bridge: 127.0.0.1:9876 (JSON-RPC)"
echo "  PID will appear in Console.app under [SpliceKit]"
echo ""

export DYLD_INSERT_LIBRARIES="$DYLIB"
exec "$MODDED_APP/Contents/MacOS/Final Cut Pro"
