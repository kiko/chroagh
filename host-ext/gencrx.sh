#!/bin/sh -e
# For some reason Chrome segfaults at the end of the process
# (version 27.0.1453.116), but the package still looks fine.

EXTFILE="crouton.crx"

cd "`dirname "$0"`"

rm -f $EXTFILE

CHROMIUM="/opt/google/chrome/chrome"
if [ ! -x "$CHROMIUM" ]; then
    CHROMIUM="chromium"
fi

ARGS="--pack-extension=crouton"
if [ -f crouton.pem ]; then
    ARGS="$ARGS --pack-extension-key=crouton.pem"
fi

$CHROMIUM $ARGS || echo "Chromium process error (may not be fatal)" >&2

# Check if extension file was generated
if [ -s "$EXTFILE" ]; then
    echo "crouton Chromium extension generated successfully"
else
    echo "Cannot generate crouton Chromium extension" >&2
    exit 1
fi
