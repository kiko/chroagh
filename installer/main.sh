#!/bin/sh -e
# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

APPLICATION="${0##*/}"

USAGE="$APPLICATION distribution [options]

Constructs a chroot for running alongside Chromium OS.

Run
# $APPLICATION ubuntu
or
# $APPLICATION archlinux
for distribution specific options.
"

# Function to exit with exit code $1, spitting out message $@ to stderr
error() {
    local ecode="$1"
    shift
    echo "$*" 1>&2
    exit "$ecode"
}

OS=$1

# If OS isn't specified, we should just print help text.
if [ -z "$OS" ]; then
    error 2 "$USAGE"
fi

if [ ! -x "$OS/main.sh" ]; then
    error 2 "$OS/main.sh does not exists."
fi

$OS/main.sh ${*:2}

