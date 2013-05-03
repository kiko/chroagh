#!/bin/sh -e
# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

APPLICATION="${0##*/}"
SCRIPTDIR="${SCRIPTDIR:-"`dirname "$0"`/../.."}"
CHROOTBINDIR="$SCRIPTDIR/chroot-bin"
CHROOTETCDIR="$SCRIPTDIR/chroot-etc"
INSTALLERDIR="$SCRIPTDIR/installer/arch"
HOSTBINDIR="$SCRIPTDIR/host-bin"
TARGETSDIR="$SCRIPTDIR/targets/arch"
SRCDIR="$SCRIPTDIR/src"

ARCH="`uname -m`"
DOWNLOADONLY=''
ENCRYPT=''
KEYFILE=''
MIRROR='unspecified'
NAME=''
PREFIX='/usr/local'
PROXY='unspecified'
TARBALL=''
TARGETS=''
TARGETFILE=''
UPDATE=''

USAGE="$APPLICATION [options] -t targets
$APPLICATION [options] -d -f tarball

Constructs a Archlinux-based chroot for running alongside Chromium OS.

Only ARM architecture is suppported/tested at this time (Samsung Chromebook ARM).

If run with -f, a tarball is used to bootstrap the chroot. If specified with -d,
the tarball is created for later use with -f.

This must be run as root unless -d is specified AND fakeroot is installed AND
/tmp is mounted exec and dev.

It is highly recommended to run this from a crosh shell (Ctrl+Alt+T), not VT2.

Options:
    -a ARCH     The architecture to prepare the chroot for. Default: $ARCH
    -d          Downloads the bootstrap tarball but does not prepare the chroot.
    -e          Encrypt the chroot with ecryptfs using a passphrase.
    -f TARBALL  The tarball to use, or download to in the case of -d.
                When using a prebuilt tarball, -a and -r are ignored.
    -k KEYFILE  File or directory to store the (encrypted) encryption keys in.
                If unspecified, the keys will be stored in the chroot if doing a
                first encryption, or auto-detected on existing chroots.
    -m MIRROR   Mirror to use for pacman.
    -n NAME     Name of the chroot. Default is \"alarm\".
    -p PREFIX   The root directory in which to install the bin and chroot
                subdirectories and data. Default: $PREFIX
    -P PROXY    Set an HTTP proxy for the chroot; effectively sets http_proxy.
                Specify an empty string to remove a proxy when updating.
    -t TARGETS  Comma-separated list of environment targets to install.
                Specify help to print out potential targets.
    -T TARGETFILE  Path to a custom target definition file that gets applied to
                the chroot as if it were a target in the $APPLICATION bundle.
    -u          If the chroot exists, runs the preparation step again.
                You can use this to install new targets or update old ones.
                Passing this parameter twice will force an update even if the
                specified release does not match the one already installed.
    -V          Prints the version of the installer to stdout.

Be aware that dev mode is inherently insecure, even if you have a strong
password in your chroot! Anyone can simply switch VTs and gain root access
unless you've permanently assigned a Chromium OS root password. Encrypted
chroots require you to set a Chromium OS root password, but are still only as
secure as the passphrases you assign to them."

# Function to exit with exit code $1, spitting out message $@ to stderr
error() {
    local ecode="$1"
    shift
    echo "$*" 1>&2
    exit "$ecode"
}

# Process arguments
while getopts 'a:def:k:m:n:p:P:s:t:T:uV' f; do
    case "$f" in
    a) ARCH="$OPTARG";;
    d) DOWNLOADONLY='y';;
    e) ENCRYPT='-e';;
    f) TARBALL="$OPTARG";;
    k) KEYFILE="$OPTARG";;
    m) MIRROR="$OPTARG";;
    n) NAME="$OPTARG";;
    p) PREFIX="`readlink -f "$OPTARG"`";;
    P) PROXY="$OPTARG";;
    t) TARGETS="$TARGETS${TARGETS:+","}$OPTARG";;
    T) TARGETFILE="$OPTARG";;
    u) UPDATE="$((UPDATE+1))";;
    V) echo "$APPLICATION: version ${VERSION:-"git"}"; exit 0;;
    \?) error 2 "$USAGE";;
    esac
done
shift "$((OPTIND-1))"

if [ ! "$ARCH" = "armv7l" ]; then
    error 2 "Only ARM architecture is supported (armv7l)"
fi

# If targets weren't specified, we should just print help text.
if [ -z "$DOWNLOADONLY" -a -z "$TARGETS" -a -z "$TARGETFILE" ]; then
    error 2 "$USAGE"
fi

# There should never be any extra parameters.
if [ ! $# = 0 ]; then
    error 2 "$USAGE"
fi

# Confirm or list targets if requested (and download only isn't chosen)
if [ -z "$DOWNLOADONLY" ]; then
    t="${TARGETS%,},"
    while [ -n "$t" ]; do
        TARGET="${t%%,*}"
        t="${t#*,}"
        if [ -z "$TARGET" ]; then
            continue
        elif [ "$TARGET" = 'help' -o "$TARGET" = 'list' ]; then
            TARGETS='help'
            echo "Available targets:" 1>&2
            for t in "$TARGETSDIR/"*; do
                TARGET="${t##*/}"
                if [ "${TARGET%common}" = "$TARGET" ]; then
                    (. "$t") 1>&2
                fi
            done
            exit 2
        elif [ ! "${TARGET%common}" = "$TARGET" ] || \
             [ ! -r "$TARGETSDIR/$TARGET" ] || \
             ! (TARGETS='check'; . "$TARGETSDIR/$TARGET"); then
            error 2 "Invalid target \"$TARGET\"."
        fi
    done
    if [ -n "$TARGETFILE" ]; then
        if [ ! -r "$TARGETFILE" ]; then
            error 2 "Could not find \"$TARGETFILE\"."
        elif [ ! -f "$TARGETFILE" ]; then
            error 2 "\"$TARGETFILE\" is not a target definition file."
        fi
    fi
fi

# If we're not running as root, we must be downloading and have fakeroot and
# have an exec and dev /tmp
if grep -q '.* /tmp .*\(nodev\|noexec\)' /proc/mounts; then
    NOEXECTMP=y
else
    NOEXECTMP=n
fi
FAKEROOT=''
if [ ! "$USER" = root -a ! "$UID" = 0 ]; then
    FAKEROOT=fakeroot
    if [ "$NOEXECTMP" = y -o -z "$DOWNLOADONLY" ] \
            || ! hash "$FAKEROOT" 2>/dev/null; then
        error 2 "$APPLICATION must be run as root."
    fi
fi

# If we are only downloading, we need a destination tarball
if [ -n "$DOWNLOADONLY" -a -z "$TARBALL" ]; then
    error 2 "$USAGE"
fi

# Check if we're running from a tty, which does not interact well with X11
if [ -z "$DOWNLOADONLY" ] && \
        readlink -f "/proc/$$/fd/0" | grep -q '^/dev/tty'; then
    echo \
"WARNING: It is highly recommended that you run $APPLICATION from a crosh shell
(Ctrl+Alt+T in Chromium OS), not from a VT. If you continue to run this from a
VT, you're gonna have a bad time. Press Ctrl-C at any point to abort." 1>&2
    sleep 5
fi

# Set http_proxy if a proxy is specified.
if [ ! "$PROXY" = 'unspecified' ]; then
    export http_proxy="$PROXY" https_proxy="$PROXY" ftp_proxy="$PROXY"
fi

# Done with parameter processing!
# Make sure we always have echo when this script exits
TRAP="stty echo 2>/dev/null || true;$TRAP"
trap "$TRAP" INT HUP 0

# Deterime directories, and fix NAME if it was not specified.
BIN="$PREFIX/bin"
CHROOTS="$PREFIX/chroots"
CHROOT="$CHROOTS/${NAME:=alarm}"

# Confirm we have write access to the directory before starting.
NODOWNLOAD=''
if [ -z "$DOWNLOADONLY" ]; then
    create='-n'
    if [ -d "$CHROOT" ] && ! rmdir "$CHROOT" 2>/dev/null; then
        if [ -z "$UPDATE" ]; then
            error 1 "$CHROOT already has stuff in it!
Either delete it, specify a different name (-n), or specify -u to update it."
        fi
        NODOWNLOAD='y'
        create=''
        echo "$CHROOT already exists; updating it..." 1>&2
    elif [ -n "$UPDATE" ]; then
        error 1 "$CHROOT does not exist; cannot update."
    fi

    # Mount the chroot and update CHROOT path
    if [ -n "$KEYFILE" ]; then
        CHROOT="`sh -e "$HOSTBINDIR/mount-chroot" -k "$KEYFILE" \
                            $create $ENCRYPT -p -c "$CHROOTS" "$NAME"`"
    else
        CHROOT="`sh -e "$HOSTBINDIR/mount-chroot" \
                            $create $ENCRYPT -p -c "$CHROOTS" "$NAME"`"
    fi

    # Auto-unmount the chroot when the script exits
    TRAP="sh -e '$HOSTBINDIR/unmount-chroot' \
                    -y -c '$CHROOTS' '$NAME' 2>/dev/null || true;$TRAP"
    trap "$TRAP" INT HUP 0

    # Sanity-check the release if we're updating
    if [ -n "$NODOWNLOAD" ] \
            && ! grep -q "ID=archarm\$" "$CHROOT/etc/os-release" ; then
        if [ ! "$UPDATE" = 2 ]; then
            error 1 \
"Chroot doesn't look like ArchLinux! Please correct the -r option, or specify a second -u to
change the release, upgrading the chroot (dangerous)."
        else
            echo "WARNING: Considering the chroot as ArchLinux..." 2>&1
            echo "Press Control-C to abort; upgrade will continue in 5 seconds." 1>&2
            sleep 5
        fi
    fi

    mkdir -p "$BIN"
fi

# Check and update dev boot settings. This may fail on old systems; ignore it.
if [ -z "$DOWNLOADONLY" ] && \
    boot="`crossystem dev_boot_usb dev_boot_legacy dev_boot_signed_only`"; then
    # db_usb and db_legacy be off, db_signed_only should be on.
    echo "$boot" | {
        read usb legacy signed
        suggest=''
        if [ ! "$usb" = 0 ]; then
            echo "WARNING: USB booting is enabled; consider disabling it." 1>&2
            suggest="$suggest dev_boot_usb=0"
        fi
        if [ ! "$legacy" = 0 ]; then
            echo "WARNING: Legacy booting is enabled; consider disabling it." 1>&2
            suggest="$suggest dev_boot_legacy=0"
        fi
        if [ -n "$suggest" ]; then
            if [ ! "$signed" = 1 ]; then
                echo "WARNING: Signed boot verification is disabled; consider enabling it." 1>&2
                suggest="$suggest dev_boot_signed_only=1"
            fi
            echo "You can use the following command: sudo crossystem$suggest" 1>&2
            sleep 5
        elif [ ! "$signed" = 1 ]; then
            # Only enable signed booting if the user hasn't enabled alternate
            # boot options, since those are opt-in.
            echo "WARNING: Signed boot verification is disabled; enabling it for security." 1>&2
            echo "You can disable it again using: sudo crossystem dev_boot_signed_only=0" 1>&2
            crossystem dev_boot_signed_only=1 || true
            sleep 2
        fi
    }
fi

# Unpack the tarball if appropriate
if [ -z "$NODOWNLOAD" -a -z "$DOWNLOADONLY" ]; then
    echo "Installing provided chroot to $CHROOT" 1>&2
    if [ -n "$TARBALL" ]; then
        # Unpack the chroot
        echo 'Unpacking chroot environment...' 1>&2
        tar -C "$CHROOT" --strip-components=1 -xf "$TARBALL"
    fi
elif [ -z "$NODOWNLOAD" ]; then
    echo "Downloading bootstrap to $TARBALL" 1>&2
fi

# Download the bootstrap data if appropriate
if [ -z "$NODOWNLOAD" ] && [ -n "$DOWNLOADONLY" -o -z "$TARBALL" ]; then
	error 2 "Sorry, I cannot bootstrap Arch Linux. Please download a chroot and specifiy it with -f."
fi

# Ensure that /usr/local/bin and /etc/crouton exist
mkdir -p "$CHROOT/usr/local/bin" "$CHROOT/etc/crouton"

# Create the setup script inside the chroot
echo 'Preparing chroot environment...' 1>&2
VAREXPAND="s #ARCH $ARCH ;s #MIRROR $MIRROR ;s #PROXY $PROXY ;s #VERSION $VERSION ;"
sed -e "$VAREXPAND" "$INSTALLERDIR/prepare.sh" > "$CHROOT/prepare.sh"
# Create a file for target deduplication
TARGETDEDUPFILE="`mktemp --tmpdir=/tmp "$APPLICATION.XXX"`"
rmtargetdedupfile="rm -f '$TARGETDEDUPFILE'"
TRAP="$rmtargetdedupfile;$TRAP"
trap "$TRAP" INT HUP 0
# Run each target, appending stdout to the prepare script.
unset SIMULATE
if [ -n "$TARGETFILE" ]; then
    TARGET="`readlink -f "$TARGETFILE"`"
    (. "$TARGET") >> "$CHROOT/prepare.sh"
fi
t="${TARGETS%,},post-common,"
while [ -n "$t" ]; do
    TARGET="${t%%,*}"
    t="${t#*,}"
    if [ -n "$TARGET" ]; then
        (. "$TARGETSDIR/$TARGET") >> "$CHROOT/prepare.sh"
    fi
done
chmod 500 "$CHROOT/prepare.sh"
# Delete the temp file
eval "$rmtargetdedupfile"

# Run the setup script inside the chroot
sh -e "$HOSTBINDIR/enter-chroot" -c "$CHROOTS" -n "$NAME" -x '/prepare.sh'

echo "Done! You can enter the chroot using enter-chroot." 1>&2
