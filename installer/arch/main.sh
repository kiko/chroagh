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

ARCH="`uname -m |  sed -e 's i.86 i686 ;s arm.* armv7h ;'`"
DOWNLOADONLY=''
ENCRYPT=''
KEYFILE=''
MIRRORSET=''
MIRROR=''
REPOS=''
MIRROR86='http://mirrors.kernel.org/archlinux/$repo/os/$arch' 
REPOS86='core community extra'
MIRRORARM='http://mirror.archlinuxarm.org/armv7h/$repo'
REPOSARM='core community extra alarm aur'
NAME=''
PREFIX='/usr/local'
PROXY='unspecified'
TARBALL=''
TARGETS=''
TARGETFILE=''
UPDATE=''

USAGE="$APPLICATION arch [options] -t targets
$APPLICATION arch [options] -d -f tarball

Constructs a Archlinux-based chroot for running alongside Chromium OS.

If run with -f, a tarball is used to bootstrap the chroot. If specified with -d,
the tarball is created for later use with -f.

This must be run as root.

It is highly recommended to run this from a crosh shell (Ctrl+Alt+T), not VT2.

Options:
    -a ARCH     The architecture to prepare the chroot for. Default: $ARCH
    -d          Downloads the bootstrap tarball but does not prepare the chroot.
    -e          Encrypt the chroot with ecryptfs using a passphrase.
                If specified twice, prompt to change the encryption passphrase.
    -f TARBALL  The tarball to use, or download to in the case of -d.
                When using a prebuilt tarball, -a and -r are ignored.
    -k KEYFILE  File or directory to store the (encrypted) encryption keys in.
                If unspecified, the keys will be stored in the chroot if doing a
                first encryption, or auto-detected on existing chroots.
    -m MIRROR   Mirror to use for bootstrapping and pacman.
                Default for x86/amd64: $MIRROR86
                Default for arm7h: $MIRRORARM
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
    e) ENCRYPT="${ENCRYPT:-"-"}e";;
    f) TARBALL="$OPTARG";;
    k) KEYFILE="$OPTARG";;
    m) MIRRORSET='y'; MIRROR="$OPTARG";;
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

# If targets weren't specified, we should just print help text.
if [ -z "$DOWNLOADONLY" -a -z "$TARGETS" -a -z "$TARGETFILE" ]; then
    error 2 "$USAGE"
fi

# There should never be any extra parameters.
if [ ! $# = 0 ]; then
    error 2 "$USAGE"
fi

# If MIRROR wasn't specified, choose it based on ARCH.
if [ -z "$MIRROR" ]; then
    if [ "$ARCH" = 'x86_64' -o "$ARCH" = 'i686' ]; then
        MIRROR="$MIRROR86"
    else
        MIRROR="$MIRRORARM"
    fi
fi

if [ "$ARCH" = 'x86_64' -o "$ARCH" = 'i686' ]; then
    REPOS="$REPOS86"
else
    REPOS="$REPOSARM"
fi

if [ "${MIRROR#*\$repo}" = "$MIRROR" ]; then
    error 2 "Mirror does not contain \$repo: you probably forgot to add single quotes (') around the URL ($MIRROR)."
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

if [ ! "$USER" = root -a ! "$UID" = 0 ]; then
    error 2 "$APPLICATION must be run as root."
fi

# If we are only downloading, we need a destination tarball
if [ -n "$DOWNLOADONLY" -a -z "$TARBALL" ]; then
    echo "If we are only downloading (-d), we need a destination tarball (-f)" 1>&2
    error 2 "$USAGE"
fi

# If we are only downloading, we cannot update
if [ -n "$DOWNLOADONLY" -a -n "$UPDATE" ]; then
    echo "If we are only downloading (-d), we cannot update (-u)" 1>&2
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
        && ! ([ "$ARCH" = "armv7h" ] && grep -q "ID=archarm\$" "$CHROOT/etc/os-release") \
        && ! ([ "$ARCH" != "armv7h" ] && grep -q "ID=arch\$" "$CHROOT/etc/os-release"); then
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
    #This code has been adapted from a script found on the Arch Linux Wiki:
    # https://wiki.archlinux.org/index.php/Install_from_Existing_Linux

    # Packages to install in the bootstrap chroot
    PACKAGES_BOOTSTRAP="acl attr bzip2 curl expat glibc gpgme libarchive libassuan libgpg-error libssh2 openssl pacman xz zlib pacman-mirrorlist coreutils bash grep gawk file tar ncurses readline libcap util-linux pcre gcc-libs lzo2 arch-install-scripts"

    # Packages to install in the target 
    PACKAGES_TARGET="bash bzip2 coreutils cryptsetup diffutils file filesystem findutils gawk gcc-libs gettext glibc grep gzip heirloom-mailx inetutils iproute2 iputils less licenses man-db man-pages nano pacman pacman-mirrorlist perl procps-ng psmisc sed shadow sysfsutils tar texinfo usbutils util-linux vi which"
    # Temporarily add libsigsegv (gawk missing dependency)
    # https://github.com/archlinuxarm/PKGBUILDs/issues/438
    PACKAGES_TARGET="$PACKAGES_TARGET libsigsegv"

    LIST=`mktemp --tmpdir=/tmp "$APPLICATION.XXX"`
    FETCHDIR=`mktemp -d --tmpdir=/tmp "$APPLICATION.XXX"`

    # Paranoid mode: make sure $FETCHDIR really exists, the trap
    # below could lead to bad results otherwise
    if [ ! -d $FETCHDIR ]; then
        error 2 "FETCHIR=$FETCHDIR is not a directory"
    fi

    # Make sure tmp files are cleaned on on exit
    # Most likely safer than rm -rf $FETCHDIR
    # FIXME: TRAP is executed twice, hence the need to make sure rmdir does not fail
    TRAP="rm -f $FETCHDIR/*; rmdir $FETCHDIR 2>/dev/null || true; rm -f $LIST;$TRAP"
    trap "$TRAP" INT HUP 0

    echo "Fetching repository packages list..."
    # Create a list with urls for the arch packages
    for REPO in $REPOS; do
	    echo "Fetching $REPO..."
	    MIRRORBASE=`echo $MIRROR | sed -e "s/\\$repo/$REPO/" -e "s/\\$arch/$ARCH/"`
            wget -q -O- "$MIRRORBASE" |sed  -n "s|.*href=\"\\([^\"]*\\).*|$MIRRORBASE/\\1|p"|grep -v 'sig$'|uniq >> $LIST  
    done

    echo "Downloading and extracting packages..."
    # Download and extract each package.
    for PACKAGE in $PACKAGES_BOOTSTRAP; do
        URL=`grep "$PACKAGE-[0-9]" $LIST|head -n1`
        if [ -z "$URL" ]; then
            error 2 "Cannot find package $PACKAGE"
        fi
        FILE=`echo $URL|sed 's/.*\/\([^\/][^\/]*\)$/\1/'`
        wget "$URL" -c -O "$FETCHDIR/$FILE" 
        tar xfk "$FETCHDIR/$FILE" -C "$CHROOT"
    done
            
    # Copy packages tarballs for faster installation
    mkdir -p "$CHROOT/var/cache/pacman/pkg"
    mv $FETCHDIR/* $CHROOT/var/cache/pacman/pkg
    
    # Hash for empty password  Created by doing: openssl passwd -1 -salt ihlrowCo and entering an empty password (just press enter)
    echo 'root:$1$ihlrowCo$sF0HjA9E8up9DYs258uDQ0:10063:0:99999:7:::' > "$CHROOT/etc/shadow"
    echo "root:x:0:0:root:/root:/bin/bash" > "$CHROOT/etc/passwd" 
    touch "$CHROOT/etc/group"
    echo "archbootstrap" > "$CHROOT/etc/hostname"
    test -e "$CHROOT/etc/mtab" || echo "rootfs / rootfs rw 0 0" > "$CHROOT/etc/mtab"
    sed -ni '/^[ \t]*CheckSpace/ !p' "$CHROOT/etc/pacman.conf"
    sed -i "s/^[ \t]*SigLevel[ \t].*/SigLevel = Never/" "$CHROOT/etc/pacman.conf"
    echo "Server = $MIRROR" > "$CHROOT/etc/pacman.d/mirrorlist"

    ln -s /usr/lib "$CHROOT/lib"
    # Link /lib64. Critical on x86_64, harmless on other architectures.
    ln -s /usr/lib "$CHROOT/lib64"

    # We could use pacstrap to install the base packages, but it does not like not being able
    # to do mount --bind (which cannot be done inside the chroot for some reason)

    NEWCHROOT="$CHROOT/mnt"
    echo "Creating install root at $NEWCHROOT"
    mkdir -m 0755 -p "$NEWCHROOT"/var/cache/pacman/pkg
    mkdir -m 0755 -p "$NEWCHROOT"/var/lib/pacman
    mkdir -m 0755 -p "$NEWCHROOT"/var/log
    mkdir -m 0755 -p "$NEWCHROOT"/dev
    mkdir -m 0755 -p "$NEWCHROOT"/run
    mkdir -m 0755 -p "$NEWCHROOT"/etc
    mkdir -m 1777 -p "$NEWCHROOT"/tmp
    mkdir -m 0555 -p "$NEWCHROOT"/sys
    mkdir -m 0555 -p "$NEWCHROOT"/proc

    sh -e "$HOSTBINDIR/enter-chroot" -c "$CHROOTS" -n "$NAME" -x /usr/bin/pacman -r /mnt -Sy $PACKAGES_TARGET --noconfirm

    echo "Swapping content of bootstrap and install root..."
    mkdir -p "$CHROOT"/bootstrap
    for dir in "$CHROOT"/*
    do
	    if [ ! $dir = "$CHROOT"/bootstrap ]; then
		    mv $dir "$CHROOT"/bootstrap
	    fi
    done

    mv "$CHROOT"/bootstrap/mnt/* "$CHROOT"
    cp -a "$CHROOT"/bootstrap/etc/pacman.d/mirrorlist "$CHROOT"/etc/pacman.d/
    rm -rf "$CHROOT"/bootstrap

    # Tar it up if we're only downloading
    if [ -n "$DOWNLOADONLY" ]; then
        echo 'Compressing bootstrap files...' 1>&2
        tar -C "$CHROOTS" -cajf "$TARBALL" "$CHROOT"
        echo 'Done!' 1>&2
        echo "NOTE: chroot has been leftover in $CHROOT." 1>&2
        echo "You can finish the installation by running the same command, using -u and -t parameters, and removing -f and -d parameters." 1>&2
        echo "Alternatively, you can delete the chroot by running:" 1>&2
        echo "sudo delete-chroot $NAME" 1>&2
        exit 0
    fi
fi

# Ensure that /usr/local/bin and /etc/crouton exist
mkdir -p "$CHROOT/usr/local/bin" "$CHROOT/etc/crouton"

mirror="$MIRROR"
if [ -z $MIRRORSET ]; then
    mirror=''
fi

# Create the setup script inside the chroot
echo 'Preparing chroot environment...' 1>&2
VAREXPAND="s #ARCH $ARCH ;s #MIRROR $mirror ;s #PROXY $PROXY ;s #VERSION $VERSION ;"
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
