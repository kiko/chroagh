#!/bin/sh
# In theory, this could be run using Chrome installed in /opt/google/chrome/chrome.
# For some reason Chrome segfaults though (27.0.1453.76 beta)

CHROMIUM="/usr/bin/chromium"

ARGS="--pack-extension=croutonclip"

if [ -f croutonclip.pem ]; then
    ARGS="$ARGS --pack-extension-key=croutonclip.pem"
fi

$CHROMIUM $ARGS

