# Titan 2 Elite Debian Chroot

Run a full Debian Linux desktop on a rooted Unihertz Titan 2 Elite phone, using the phone's
own physical keyboard, and switch between Linux and Android without rebooting.

The desktop is KDE Plasma. It runs in a *chroot*: a complete Debian system installed in
a folder on the phone's storage, sharing the running Android kernel rather than booting
a second operating system. Android keeps running the whole time. Calls, messages and
notifications still work, and you move between the Linux desktop and Android the same
way you switch between any two apps.

## Quick start

Rooted phone with Magisk, Termux and the Termux:X11 app installed? Paste this one line
into Termux and it does everything: installs the Termux packages, downloads the project,
installs Debian and KDE, then starts the desktop.

```sh
pkg install -y curl tar xz-utils x11-repo git && pkg install -y termux-x11-nightly pulseaudio && rm -rf ~/.titan-src && git clone --depth 1 https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Debian-Chroot.git ~/.titan-src && rm -rf ~/.titan-src/.git ~/.titan-src/*.zip && cp -f ~/.titan-src/* ~/ && bash ~/install_chroot.sh && bash ~/boot_desktop.sh
```

Magisk asks for root permission; grant it. The installer then asks for a desktop
username. Expect 30 to 60 minutes and a few GB of downloads.

> [!WARNING]
> This erases `/data/adb/debian` before installing, so run it only for a first install.
> Already have it set up? Use the update command in [Everyday use](#everyday-use).

Optional extras, worth adding before the line above:

```sh
pkg install -y virglrenderer-android   # GPU acceleration
pkg install -y termux-api              # Android toast messages (needs the Termux:API app)
```

The rest of this file explains what all of that does, and what to change afterwards.

## How the pieces fit together

| Piece | What it does |
| --- | --- |
| Android + Magisk | The phone's own OS. Magisk provides root, which a chroot needs |
| Termux | A terminal app for Android. The install and start scripts run here |
| The chroot | Debian, installed at `/data/adb/debian` |
| Termux:X11 | Displays the Linux desktop on the phone screen |
| The input bridge | Decides, key by key, whether input belongs to Linux or Android |

The input bridge is the part that makes this usable as a daily driver. It takes the
physical keyboard, touchscreen and volume keys at the kernel level, and routes each
event to whichever side is in front: type in Linux, then switch to Android and the same
keyboard types there. Home, Back and Recents always reach Android so you are never
trapped in the desktop.

## Before you start

You need:

- A Unihertz Titan 2 Elite, rooted with [Magisk](https://github.com/topjohnwu/Magisk)
- [Termux](https://termux.dev) installed (from F-Droid or GitHub, not the Play Store)
- The [Termux:X11](https://github.com/termux/termux-x11) app installed
- Around 8 GB free on internal storage
- A network connection you do not mind using for a few GB of downloads

The installation takes 30 to 60 minutes, mostly waiting for packages to download.

Install the Termux packages first. Run this in Termux:

```sh
pkg install -y curl tar xz-utils x11-repo
pkg install -y termux-x11-nightly pulseaudio
pkg install -y termux-api            # optional: Android toast messages
pkg install -y virglrenderer-android # optional: GPU acceleration
```

## Install, one step at a time

The quick start above does all of this in one line. Run the steps separately if you want
to see each part finish, or if the one-liner stopped somewhere and you want to carry on
from that point.

Install the Termux packages:

```sh
pkg install -y curl tar xz-utils x11-repo git
pkg install -y termux-x11-nightly pulseaudio
```

Download the project and copy it into the Termux home folder:

```sh
rm -rf ~/.titan-src && git clone --depth 1 https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Debian-Chroot.git ~/.titan-src && rm -rf ~/.titan-src/.git ~/.titan-src/*.zip && cp -f ~/.titan-src/* ~/
```

Install Debian and KDE. This is the long step:

```sh
bash ~/install_chroot.sh
```

Start the desktop:

```sh
bash ~/boot_desktop.sh
```

> [!WARNING]
> `install_chroot.sh` deletes `/data/adb/debian` before installing. Run it once, for the
> first install. To update an existing setup, use the update command in
> [Everyday use](#everyday-use) instead.

## Everyday use

Start the desktop:

```sh
bash ~/boot_desktop.sh
```

Or tap the **Debian** widget on your Android home screen (see [Home screen
widgets](#home-screen-widgets)).

To leave the desktop, use **Close desktop** in the Linux application launcher, or press
Home to go back to Android with the desktop still running.

Update to the latest version of these scripts without reinstalling Debian:

```sh
pkg install -y git && rm -rf ~/.titan-src && git clone --depth 1 https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Debian-Chroot.git ~/.titan-src && rm -rf ~/.titan-src/.git ~/.titan-src/*.zip && cp -f ~/.titan-src/* ~/ && bash ~/boot_desktop.sh
```

The scripts do not need to be marked executable. They re-run themselves through `bash`
when they ask for root, so `bash ~/boot_desktop.sh` works on any filesystem.

## Home screen widgets

Install the [Termux:Widget](https://github.com/termux/termux-widget) app, then add its widget to the Android home screen and pick a
task. Both tasks run in the background with no terminal window.

| Task | What it does |
| --- | --- |
| `Debian` | Starts the desktop |
| `Stop Debian` | Ends a running session |

Started from a widget, the session returns to the Android home screen when it ends.
Started from a terminal, it returns to Termux. Set `EXIT_TO=home` or `EXIT_TO=termux` to
override that.

## Screenshots

While the desktop is in front, the input bridge holds the volume keys, so Android never
sees Volume Down and its own screenshot shortcut cannot fire. The bridge watches for the
combination itself and saves to `/sdcard/Pictures/Screenshots/`.

Hold **Volume Down**, then tap **Power**. In that order the Power press is consumed by
the bridge. Pressing Power first also takes the screenshot, but Android still receives
that Power press and turns the screen off afterwards.

You can also capture from inside Linux, which avoids the key combination entirely:

```sh
spectacle -f -b -d 5000 -o ~/shot.png
```

## Resetting things

The Linux application launcher has a **Reset Titan settings** entry. Tick any number of
items and press OK:

| Item | What it restores |
| --- | --- |
| Panel layout | The taskbar, back to the layout this project sets up |
| Window look and buttons | Title bar style, button placement and margins |
| KDE touch tuning | Larger fonts and icons, tablet mode, touch-friendly spacing |
| Re-detect screen cutout | Camera hole position and corner rounding, measured again |
| Rebuild Klassy add-ons | Recompiles the window decoration (slow) |
| Restart Plasma session | Restarts the desktop, leaving the chroot running |

The same thing from a terminal, one or more at a time:

```sh
titan-reset panel windows
```

## Settings

Settings are given on the command line and remembered for next time, so each one only
has to be set once:

```sh
DISPLAY_SCALE=1.35 bash ~/boot_desktop.sh
ANIMATIONS=0 bash ~/boot_desktop.sh
CORNER_PAD=8 bash ~/boot_desktop.sh
TITLE_BUTTONS=left bash ~/boot_desktop.sh
```

Commonly useful ones:

| Setting | Effect |
| --- | --- |
| `DISPLAY_SCALE` | Size of everything on screen. Higher is bigger. Default 1.5 |
| `TITLE_BUTTONS` | `right` (default), `left` or `center` |
| `CORNER_PAD` | Extra gap between window buttons and the rounded screen corner |
| `SPACER_PX` | Fine-tunes that gap. Default 20 |
| `ANIMATIONS` | `1` for smooth scrolling (default), `0` for instant and faster |
| `COMPOSITING` | `0` disables desktop effects if things feel slow |
| `SPLASH` | `0` skips the KDE start-up splash screen |
| `LAUNCHER` | `kickoff` or `drawer` |
| `GPU` | `0` disables GPU acceleration if graphics misbehave |

The full list with defaults is in the comment block near the top of `chroot_common.sh`.

## When something goes wrong

Every part writes its own log:

| Log | Covers |
| --- | --- |
| `~/boot_desktop.log` | Start-up, in Termux |
| `/data/adb/debian/tmp/titan_input_bridge.log` | Keyboard, touch and volume keys |
| `/data/adb/debian/tmp/titan_display.log` | Panel and launcher |
| `/data/adb/debian/var/log/titan-addons.log` | Window decoration build |
| `/data/adb/debian/var/log/titan-wine.log` | Wine setup |
| `/data/adb/debian/home/<user>/.cache/titan-session.log` | KDE itself |

A few common situations:

- **Keyboard types into Android instead of Linux**: the bridge decides this from which
  app Android reports as focused. `ROUTE_DEBUG=1 bash ~/boot_desktop.sh` logs that
  decision once a second to `~/boot_desktop.log`.
- **Window buttons sit under the rounded corner**: raise `CORNER_PAD` or `SPACER_PX`.
- **Desktop feels slow**: try `ANIMATIONS=0`, then `COMPOSITING=0`.
- **Graphics glitches**: try `GPU=0`.

## What each file does

All files must sit directly in the Termux home folder (`~`). The scripts find each other
and their helpers by that path, so running them from a subfolder will skip the keyboard
layout, the panel widget and the input bridge.

| File | Purpose |
| --- | --- |
| `install_chroot.sh` | Installs Debian and KDE into `/data/adb/debian`. Run once |
| `boot_desktop.sh` | Starts the desktop. Run every time |
| `chroot_common.sh` | Shared code plus the settings list. Not run directly |
| `titan_input_bridge.py` | Routes keyboard, touch and volume keys between Linux and Android |
| `titan_xkb_symbols` | Keyboard layout for the Titan's physical keys |
| `titan_display.py` | Panel layout, screen margins and launcher choice |
| `titan_phonestatus.qml` | The "Phone" taskbar widget: battery, signal, Wi-Fi |
| `titan_notify_bridge.py` | Sends Linux notifications to the Android notification shade |
| `titan_addons.sh` | Builds the Klassy window decoration and rounded corners |
| `titan_wine.sh` | Optional: Wine and Box64, for running Windows programs |
| `titan_repos.sh` | Optional: extra Debian package sources |
| `titan-addons-bundle.tar.gz` | Prebuilt decoration, so a fresh install skips a long compile |
| `titan-addons-bundle.key` | Records which KWin version that bundle was built against |

## Prebuilt add-ons

`install_chroot.sh` unpacks `titan-addons-bundle.tar.gz` when both bundle files are
present, avoiding a 20 to 40 minute compile on the phone. It reads the KWin version from
`titan-addons-bundle.key` and pins KWin to that version where Debian still offers it.

If the versions no longer match, the scripts say so and leave the bundle alone rather
than rebuilding without being asked. To build a fresh one:

```sh
REBUILD_ADDONS=1 bash ~/boot_desktop.sh
```

To skip the add-ons entirely:

```sh
ADDONS=0 bash ~/boot_desktop.sh
```

## License and credits

Created by [Flux-Sniffer-Mods](https://github.com/Flux-Sniffer-Mods) and released
under the [GNU General Public License v3.0 or later](LICENSE).

The prebuilt add-ons archive contains compiled binaries from Klassy and KDE Rounded
Corners, which are other people's projects under their own licenses.
[THIRD-PARTY.md](THIRD-PARTY.md) records what is in it, who wrote it and where to get
the source. Delete the two `titan-addons-bundle.*` files before installing if you would
rather compile those from source yourself.

This project builds on:

- [Klassy](https://github.com/paulmcauley/klassy) window decoration by Paul McAuley
- [KDE Rounded Corners](https://github.com/matinlotfali/KDE-Rounded-Corners) by Matin Lotfali
- [Plasma Drawer](https://github.com/p-connor/plasma-drawer) launcher by p-connor
- [Termux](https://termux.dev), Termux:X11 and Termux:Widget by the Termux project

## More for the Titan 2 Elite

- [Flux Keyboard](https://github.com/Flux-Sniffer-Mods/Flux-Keyboard): a
  hardware-keyboard input method built on Pastiera and tuned for the Titan 2 Elite, with GIF, emoji and
  symbol search, spell checking and autofill in every app, and a status bar made
  for its display.
- [Titan 2 Elite Telephoto Fix](https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Telephoto-Fix):
  unlocks the hidden 6.8 mm optical telephoto camera and adds telephoto photo and
  video to Google Camera.
