#!/bin/sh -e
# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Usage: prepare.sh arch mirror release proxy version
ARCH="${1:-"#ARCH"}"
MIRROR="${2:-"#MIRROR"}"
PROXY="${3:-"#PROXY"}"
VERSION="${4:-"#VERSION"}"

# compile: Grabs the necessary dependencies and then compiles a C file from
# stdin to the specified output and strips it.
# $1: name; target is /usr/local/bin/crouton$1
# $2: linker flags, quoted together
# $3+: any package dependencies other than gcc and libc-dev.
compile() {
    local out="/usr/local/bin/crouton$1" linker="$2"
    echo "Installing dependencies for $out..." 1>&2
    shift 2
    pacman -Su base-devel $* --noconfirm --needed
    echo "Compiling $out..." 1>&2
    ret=0
    if ! gcc -xc -Os - $linker -o "$out" || ! strip "$out"; then
        ret=1
    fi
    return $ret
}

# aurcompile: compile package from AUR
# $1: name; target is /usr/local/bin/crouton$1
aurcompile() {
    echo "Compiling $1 from AUR..." 1>&2
    # Make sure base-devel is installed
    pacman -Su base-devel --noconfirm --needed
    # Create a user to do the compilation
    if ! cat /etc/shadow | grep -q aur; then
        useradd aur -u 1999
    fi
    PACKAGE=$1
    PACKAGE2=`echo $PACKAGE | sed -e 's/\(..\).*/\1/'`
    pushd .
    cd /tmp
    su aur -c "wget https://aur.archlinux.org/packages/$PACKAGE2/$PACKAGE/$PACKAGE.tar.gz"
    su aur -c "tar vxf $PACKAGE.tar.gz"
    cd $PACKAGE
    su aur -c "sed -i -e 's/\(arch=(.*\))/\1 '"'"'armv7h'"'"')/' PKGBUILD"
    su aur -c makepkg
    pacman -U $PACKAGE-*.pkg.tar.xz --noconfirm
    cd ..
    su aur -c "rm -rf $PACKAGE"
    su aur -c "rm $PACKAGE.tar.gz"
    popd
    return 0
}


# Fixes the tty keyboard mode. keyboard-configuration puts tty1~6 in UTF8 mode,
# assuming they are consoles. Since everything other than tty2 can be an X11
# session, we need to revert those back to RAW. keyboard-configuration could be
# reconfigured after bootstrap, dpkg --configure -a, or dist-upgrade.
fixkeyboardmode() {
    if hash kbd_mode 2>/dev/null; then
        for tty in 1 3 4 5 6; do
            kbd_mode -s -C "/dev/tty$tty"
        done
    fi
}

# We need all paths to do administrative things
export PATH='/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin'

# Apply the proxy for this script
if [ ! "$PROXY" = 'unspecified' -a "${PROXY#"#"}" = "$PROXY" ]; then
    export http_proxy="$PROXY" https_proxy="$PROXY" ftp_proxy="$PROXY"
fi

# Fix the keyboard mode early on (this will be called again after dist-upgrade).
fixkeyboardmode

# The rest is dictated by the selected targets.
# Note that we install targets before adding the user, since targets may affect
# /etc/skel or other default parts. The user is added in post-common, which is
# always added to targets.
