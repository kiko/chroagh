chroagh
=======

chroagh is a fork of [crouton](https://github.com/dnschneid/crouton), that
allows you to run another Linux distribution side by side with Chromium OS.

The main idea of this branch is to get people to test features before they
are pushed to crouton, especially for Arch Linux users. Expect things to break,
and please file bug reports when they do!

This is essentially crouton, with the following branches merged:
 - croagh+arch: Add support for Arch Linux.
 - clipboard: Clipboard synchronization support. (install with `-t extension`)

Usage
-----

These instructions assume you are using a Samsung Chromebook ARM, and that
you want to install Arch Linux.

### Switch your device to developer mode

First, switch your Chromebook into developer mode (careful, this will erase
all your data), see the instructions
[here](http://www.chromium.org/chromium-os/developer-information-for-chrome-os-devices/samsung-arm-chromebook).
It will take about 15 minutes. From then on, on each boot-up, you will need
to press Ctrl+D.

### Create the chroot

  1. Launch a crosh shell (Ctrl+Alt+T, you can paste in the console using
     Ctrl+Shift+V), then enter `shell`.
  2. Download and extract chroagh:

        cd ~/Downloads
        wget https://api.github.com/repos/drinkcat/chroagh/tarball -O chroagh.tar.gz
        tar xvf chroagh.tar.gz
        cd drinkcat-chroagh-*

  3. Create the rootfs (replace `alarm` by `arch` on x86):

        sudo sh -e installer/main.sh -r alarm -t xfce

    (you can specify a mirror by adding
    `-m 'http://tw.mirror.archlinuxarm.org/armv7h/$repo'`: just change the
    country code from `tw` to somewhere near you. Be careful to keep the single
    quotes around the mirror URL)

### Start the chroot

  * `sudo enter-chroot` to launch a bash shell
  * `sudo startxfce4` to start XFCE in a separate screen (you can switch
    between screens with Ctrl+Alt+Shift+Back or Ctrl+Alt+Shift+Forward)

Notes on git tree
-----------------
This repository is a bit strange, because we constantly rebase on
[`dnschneid/crouton`](https://github.com/dnschneid/crouton)

That means you need to do the following to fetch modifications from the tree:

        git fetch --all
        git reset --hard origin/master

Be careful, as this will erase any other commit you did in your own `master` branch.

Original documentation follows:

crouton: Chromium OS Universal Chroot Environment
=================================================

crouton is a set of scripts that bundle up into an easy-to-use,
Chromium OS-centric chroot generator. Currently Ubuntu and Debian are
supported (using debootstrap behind the scenes), but "Chromium OS Debian,
Ubuntu, and Probably Other Distros Eventually Chroot Environment" doesn't
acronymize as well (crodupodece is admittedly pretty fun to say, though).


"crouton"...an acronym?
-----------------------
It stands for _ChRomium Os Universal chrooT envirONment_
...or something like that. Do capitals really matter if caps-lock has been
(mostly) banished, and the keycaps are all lower-case?

Moving on...


Who's this for?
---------------
Anyone who wants to run straight Linux on their Chromium OS device, and doesn't
care about physical security. You're also better off having some knowledge of
Linux tools and the command line in case things go funny, but it's not strictly
necessary.


What's a chroot?
----------------
Like virtualization, chroots provide the guest OS with their own, segregated
file system to run in, allowing applications to run in a different binary
environment from the host OS. Unlike virtualization, you are *not* booting a
second OS; instead, the guest OS is running using the Chromium OS system. The
benefit to this is that there is zero speed penalty since everything is run
natively, and you aren't wasting RAM to boot two OSes at the same time. The
downside is that you must be running the correct chroot for your hardware, the
software must be compatible with Chromium OS's kernel, and machine resources are
inextricably tied between the host Chromium OS and the guest OS. What this means
is that while the chroot cannot directly access files outside of its view, it
*can* access all of your hardware devices, including the entire contents of
memory. A root exploit in your guest OS will essentially have unfettered access
to the rest of Chromium OS.

...but hey, you can run TuxRacer!


Prerequisites
-------------
You need a device running Chromium OS that has been switched to developer mode.
Note that developer mode, in its default configuration, is *completely
insecure*, so don't expect a password in your chroot to keep anyone from your
data. crouton does support encrypting chroots, but the encryption is only as
strong as the quality of your passphrase. Consider this your warning.

That's it! Surprised?


Usage
-----
crouton is a powerful tool, and there are a *lot* of features, but basic usage
is as simple as possible by design.

If you're just here to use crouton, you can grab the latest release from
[goo.gl/fd3zc](http://goo.gl/fd3zc). Download it, pop open a shell
(Ctrl+Alt+T, type `shell` and hit enter), and run `sh -e ~/Downloads/crouton` to
see the help text. See the "examples" section for some usage examples.

If you're modifying crouton, you'll probably want to clone or download the repo
and then either run `installer/main.sh` directly, or use `make` to build your
very own `crouton`. You can also download the latest release, cd into the
Downloads folder, and run `sh -e crouton -x` to extract out the juicy scripts
contained within, but you'll be missing build-time stuff like the Makefile.

crouton uses the concept of "targets" to decide what to install. While you will
have apt-get in your chroot, some targets may need minor hacks to avoid issues
when running in the chrooted environment. As such, if you expect to want
something that is fulfilled by a target, install that target when you make the
chroot and you'll have an easier time. You can see the list of available targets
by running `sh -e ~/Downloads/crouton -t help`.

Once you've set up your chroot, you can easily enter it using the
newly-installed `enter-chroot` command, or one of the target-specific
start\* commands. Ta-da! That was easy.


Examples
--------

### The easy way (assuming you want an Ubuntu LTS with Xfce)
  1. Download `crouton`
  2. Open a shell (Ctrl+Alt+T, type `shell` and hit enter) and run
     `sudo sh -e ~/Downloads/crouton -t xfce`
  3. Wait patiently and answer the prompts like a good person.
  4. Done! You can jump straight to your Xfce session by running
     `sudo enter-chroot startxfce4` or, as a special shortcut, `sudo startxfce4`
  5. Cycle through Chromium OS and your running graphical chroots using
     Ctrl+Alt+Shift+Back and Ctrl+Alt+Shift+Forward.
  6. Exit the chroot by logging out of Xfce.

### With encryption!
  1. Add the `-e` parameter when you run crouton to create an encrypted chroot.
  2. You can get some extra protection on your chroot by storing the decryption
     key separately from the place the chroot is stored. Use the `-k` parameter
     to specify a file or directory to store the keys in (such as a USB drive or
     SD card) when you create the chroot. Beware that if you lose this file,
     your chroot will not be decryptable. That's kind of the point, of course.

### Hey now, Ubuntu 12.04 is pretty old; I'm young and hip
  1. The `-r` parameter specifies which distro you want to use.
  2. Run `sh -e ~/Downloads/crouton -r list` to list the recognized releases and
     which distros they belong to.

### I don't always use Linux, but when I do, I use CLI
  1. You can save a chunk of space by ditching X and just installing
     command-line tools using `-t core` or `-t cli-extra`
  2. Enter the chroot in as many crosh shells as you want simultaneously using
     `sudo enter-chroot`
  3. Use the [Crosh Window](http://goo.gl/eczLT) extension to keep Chromium OS
     from eating standard keyboard shortcuts.

### A new version of crouton came out; my chroot is therefore obsolete and sad
  1. Check for updates, download the latest version, and see what's new by
     running `croutonversion -u -d -c` from the chroot (run `croutonversion -h`
     to see what those parameters actually do).
  2. Exit the chroot and run `sudo sh -e ~/Downloads/crouton -t xfce -u`
     (substitute xfce for whichever targets you want to update).
  3. You can use this with `-e` to encrypt a non-encrypted chroot, but make sure
     you don't interrupt the operation.

### A backup a day keeps the price-gouging data restoration services away
  1. `sudo edit-chroot -b chrootname` backs up your chroot to a timestamped
     tarball in the current directory. Chroots are named either via the `-n`
     parameter when created or by the release name if -n was not specified.
  2. `sudo edit-chroot -r chrootname` restores the chroot from the most recent
     timestamped tarball. You can explicitly specify the tarball with `-f`

*Unlike with Chromium OS, the data in your chroot isn't synced to the cloud.*

### This chroot's name/location/password/existence sucks. How to fix?
  1. Check out the `edit-chroot` command; it likely does what you need it to do.
  2. If you set a Chromium OS root password, you can change it with
     `sudo chromeos-setdevpasswd`
  3. You can change the password inside your chroot with `passwd`

### I want to install the chroot to another location
  1. Use `-p` to specify the directory in which to install the chroot and
     scripts. Be sure to quote or escape spaces.
  2. When entering the chroot, either specify the full path of the enter-chroot
     or start* scripts (i.e. `sudo sh -e /path/to/enter-chroot`), or use the
     `-c` parameter to explicitly specify the chroots directory.

### Downloading bootstrap files over and over again is a waste of time
  1. Download `crouton`
  2. Open a shell (Ctrl+Alt+T, type `shell` and hit enter) and run
     `sudo sh -e ~/Downloads/crouton -d -f ~/Downloads/mybootstrap.tar.bz2`
  3. You can then create chroots using the tarball by running
     `sudo sh -e ~/Downloads/crouton -f ~/Downloads/mybootstrap.tar.bz2`

*This is the quickest way to create multiple chroots at once, since you won't
have to determine and download the bootstrap files every time.*

### Targets are cool. Abusing them for fun and profit is even cooler
  1. You can make your own target files (start by copying one of the existing
     ones) and then use them with any version of crouton via the `-T` parameter.

*This is great for automating common tasks when creating chroots.*

### Help! I've created a monster that must be slain!
  1. The delete-chroot command is your sword, shield, and only true friend.
     `sudo delete-chroot evilchroot`


Tips
----

  * Chroots are cheap! Create multiple ones using `-n`, break them, then make
    new, better ones!
  * You can change the distro mirror from the default by using `-m`
  * Behind a proxy? `-P` lets you specify one.
  * A script is installed in your chroot called `brightness`. You can assign
    this to keyboard shortcuts to adjust the brightness of the screen (e.g.
    `brightness up`) or keyboard (e.g. `brightness k down`).
  * Multiple monitors will work fine in the chroot, but you may have to switch
    to Chromium OS and back to enable them.
  * You can make commands run in the background so that you can close the
    terminal. This is particularly useful for desktop environments: try running
    `sudo startxfce4 -b`
  * Want to disable Chromium OS's power management? Run `croutonpowerd -i`
  * Only want power management disabled for the duration of a command?
    `croutonpowerd -i command and arguments` will automatically stop inhibiting
    power management when the command exits.
  * Have a Pixel or two or 4.352 million? `-t touch` improves touch support.
  * Want more tips? Check the [wiki](https://github.com/dnschneid/crouton/wiki).


Issues?
-------
Running another OS in a chroot is a pretty messy technique (although it's hidden
behind very pretty scripts), and these scripts are relatively new, so problems
are not surprising. Check the issue tracker and file a bug if your issue isn't
there. When filing a new bug, include the output of `croutonversion` run from
inside the chroot (if possible).


Can I help?
-----------
Yes!


But how?
--------
There's a way For Everyone to help!

  * Something broken? File a bug! Bonus points if you try to fix it.
  * Want to try and break something? Look through [requests for testing](https://github.com/dnschneid/crouton/issues?labels=needstesting&state=open)
    and then do your best to brutally rip the author's work to shreds.
  * Look through [open issues](https://github.com/dnschneid/crouton/issues?state=open)
    and see if there's a topic or application you happen to have experience
    with. And then, preferably, share that experience with others.
  * Find issues that need [wiki entries](https://github.com/dnschneid/crouton/issues?labels=needswiki&state=open,closed)
    and add the relevant info to the [wiki](https://github.com/dnschneid/crouton/wiki).
    Or just add things to/improve things in the wiki in general, but do try to
    keep it relevant and organized.
  * Really like a certain desktop environment? Open or comment on a bug with
    steps to get things working well. Or better yet, create a pull request with
    a new target.
  * Feel like hacking around with Chromium OS integration? Fork crouton, improve
    integration, and create a pull request.
  * Is your distro underrepresented? Want to contribute to the elusive and
    mythical beast known as "croagh"? Fork crouton, add the distro, and create a
    pull request.


License
-------
crouton (including this eloquently-written README) is copyright &copy; 2013 The
Chromium OS Authors. All rights reserved. Use of the source code included here
is governed by a BSD-style license that can be found in the LICENSE file in the
source tree.
