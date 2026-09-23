# Part of: Titan 2 Elite Debian Chroot - a full Debian/KDE desktop running
# alongside Android on a Unihertz Titan 2 Elite phone.
# Shared code used by install_chroot.sh and boot_desktop.sh. Not run on its own.
#
# New to this project? Read README.md first, it explains the whole setup:
# https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Debian-Chroot
#
# chroot_common.sh - shared helpers for install_chroot.sh and boot_desktop.sh.
# Sourced, not run. Everything here executes as root on the Android side; the
# system tools (mount, chroot, mknod, dumpsys, settings) come from /system/bin.
#
# Contents:
#   - logging and root escalation (with forwarding of the command-line settings)
#   - process and mount management for the chroot
#   - the display configuration (/etc/titan-display.conf inside the chroot), its
#     defaults, migrations between versions, and command-line overrides
#   - one-time KDE tuning for a small touch screen

CHROOT_DIR="${CHROOT_DIR:-/data/adb/debian}"
TERMUX_PREFIX="/data/data/com.termux/files/usr"
TERMUX_HOME="/data/data/com.termux/files/home"

# Report the failing line instead of exiting silently (main shell only).
set -o errtrace
trap '[ "$BASHPID" = "$$" ] && printf "\033[1;31m[-]\033[0m Failed at %s line %s: %s\n" "${BASH_SOURCE[0]##*/}" "$LINENO" "$BASH_COMMAND" >&2' ERR

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; exit 1; }

# Re-run the calling script as root with a sane PATH (toybox first, Termux after).
# Options users can set on the command line, e.g.  FAST_UI=0 ./boot_desktop.sh
# Display/desktop settings that are remembered in the chroot (see detect_display).
DISPLAY_SETTINGS="TOP_INSET CORNER_RADIUS CUTOUT_RIGHT DISPLAY_SCALE TOP_RESERVE BOTTOM_RESERVE PANEL_HEIGHT PANEL_HIDING TOUCH_GESTURES LONGPRESS_MS SCROLL_PX COMPOSITING LATE_COMPOSITING ANIMATIONS WINDOW_RADIUS ADDONS NOTIFY_FORWARD NOTIFY_STYLE TITLE_BUTTONS CORNER_PAD SPACER_PX SPLASH LAUNCHER"
PASS_VARS="CHROOT_DIR FULL_KDE ROUTE_DEBUG ROUTE_RECENTS FAST_UI KEEP_DOCS KEEP_SELINUX DETECT_DISPLAY RESET_PANEL REBUILD_ADDONS RESET_WINDOWS HOLD_KWIN WINE WINE_RESET WINE_REDO REPOS GPU KWIN_GPU EXIT_TO $DISPLAY_SETTINGS"

# Re-run the calling script as root with a sane PATH (toybox first, Termux after).
# su drops the environment, so the options above are forwarded explicitly.
escalate() {
    local self v fwd=""
    self="$(realpath "$0")"
    if [ "$(id -u)" -ne 0 ]; then
        for v in $PASS_VARS; do
            [ -n "${!v:-}" ] && fwd="$fwd $v=$(printf '%q' "${!v}")"
        done
        info "Requesting root via Magisk..."
        exec su -c "env -u LD_PRELOAD PATH=/system/bin:/system/xbin:$TERMUX_PREFIX/bin \
            TERMUX_UID=$(id -u) HOME=/data/local/tmp$fwd $TERMUX_PREFIX/bin/bash '$self'"
    fi
    unset LD_PRELOAD
    export PATH="/system/bin:/system/xbin:$TERMUX_PREFIX/bin"
    export TMPDIR="$TERMUX_PREFIX/tmp"
    mkdir -p "$TMPDIR"
    TERMUX_UID="${TERMUX_UID:-$(stat -c %u "$TERMUX_HOME")}"
}

# /data is mounted nosuid,nodev on Android: breaks sudo, dbus helper, device nodes.
fix_data_mount() {
    mount -o remount,suid,dev /data 2>/dev/null \
        || warn "Could not remount /data suid,dev (sudo inside the chroot may fail)."
}

# Kill every process whose root directory is inside the chroot.
# One `ls` over /proc instead of a readlink fork per process (much faster on a phone).
kill_chroot_procs() {
    local pids
    pids="$( { ls -l /proc/[0-9]*/root 2>/dev/null || true; } | awk -v c="$CHROOT_DIR" '
        $NF == c || index($NF, c "/") == 1 { split($(NF-2), a, "/"); print a[3] }')"
    [ -n "$pids" ] && { kill -9 $pids 2>/dev/null || true; }
    return 0
}

# Kill Termux:X11 (app + server) and wait until the old server has really exited,
# otherwise the new one finds display :0 still taken. The server renames itself
# "termux-x11", so both names are needed.
kill_x11() {
    pkill -9 -f com.termux.x11 2>/dev/null || true
    pkill -9 -f termux-x11     2>/dev/null || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        pgrep -f termux-x11 >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    warn "An old X server is still running; reboot the phone if X fails to start."
}

# Unmount everything under the chroot, deepest first.
umount_chroot() {
    local m
    for m in $(grep " $CHROOT_DIR/" /proc/mounts | cut -d' ' -f2 | sort -r || true); do
        umount -l "$m" 2>/dev/null || true
    done
}

chroot_has_mounts() { grep -q " $CHROOT_DIR/" /proc/mounts; }

# Recreate a host character device inside the chroot's /dev with the same
# major:minor. (Android's toybox mount can't bind a single device file; it
# mistakes it for a disk image and tries losetup.)
clone_node() {
    [ -c "$1" ] || return 0
    local mm
    mm="$(ls -l "$1" | awk '{ gsub(",", "", $5); print $5, $6 }')"
    set -- "$1" $mm
    rm -f "$CHROOT_DIR$1"
    mknod -m 666 "$CHROOT_DIR$1" c "$2" "$3" || warn "Could not create $1 in the chroot"
}

mount_chroot() {
    local C="$CHROOT_DIR" spec
    mkdir -p "$C/proc" "$C/sys" "$C/dev" "$C/tmp"
    chmod 1777 "$C/tmp"

    mount -t proc  proc  "$C/proc"
    mount -t sysfs sysfs "$C/sys"
    mount -t tmpfs -o mode=755,dev,suid,exec tmpfs "$C/dev"
    mkdir -p "$C/dev/pts" "$C/dev/shm" "$C/dev/input" "$C/dev/dri"
    mount -t devpts -o newinstance,gid=5,mode=620,ptmxmode=0666 devpts "$C/dev/pts"
    mount -t tmpfs -o mode=1777 tmpfs "$C/dev/shm"

    # The standard character devices. mknod can be refused (SELinux, or a kernel
    # that forbids it here); it used to fail silently, leaving /dev/null absent on a
    # root-owned mode=755 tmpfs. Everything then run as the desktop user failed on
    # its very first "2>/dev/null" with "cannot create /dev/null: Permission denied",
    # which quietly broke the window look, the panel and anything else scripted.
    # So: check the result, and bind the host's own node in when mknod will not work.
    make_node() {   # make_node <name> <major> <minor>
        local p="$C/dev/$1"
        rm -f "$p" 2>/dev/null
        if mknod -m 666 "$p" c "$2" "$3" 2>/dev/null; then chmod 666 "$p" 2>/dev/null; return 0; fi
        [ -e "/dev/$1" ] || return 1
        # Android's toybox mount often refuses to bind a single device file, so this
        # is a best effort; the check below says plainly if it did not work.
        : > "$p" 2>/dev/null || return 1
        mount --bind "/dev/$1" "$p" 2>/dev/null || { rm -f "$p"; return 1; }
    }
    for spec in "null 1 3" "zero 1 5" "full 1 7" "random 1 8" "urandom 1 9" "tty 5 0"; do
        set -- $spec
        make_node "$1" "$2" "$3" || warn "Could not provide /dev/$1 inside the chroot."
    done
    # /dev/null has to work for an ordinary user or nothing scripted will run.
    if ! chroot "$C" /bin/sh -c ': > /dev/null' 2>/dev/null; then
        warn "/dev/null in the chroot is not writable; scripted settings (window look, panel) will fail."
        warn "  mknod was refused here - check SELinux, or mount $C/dev with dev,suid,exec."
    fi
    ln -sf pts/ptmx        "$C/dev/ptmx"
    ln -sf /proc/self/fd   "$C/dev/fd"
    ln -sf /proc/self/fd/0 "$C/dev/stdin"
    ln -sf /proc/self/fd/1 "$C/dev/stdout"
    ln -sf /proc/self/fd/2 "$C/dev/stderr"

    # Input: the bridge needs the real event nodes AND uinput.
    mount --bind /dev/input "$C/dev/input"
    clone_node /dev/uinput
    [ -d /dev/dri ] && mount --bind /dev/dri "$C/dev/dri"
    clone_node /dev/mali0

    # /run fresh each boot; /var/run must stay a symlink to /run.
    mkdir -p "$C/run"
    mount -t tmpfs -o mode=755 tmpfs "$C/run"
    mkdir -p "$C/run/dbus" "$C/run/lock"
    if [ ! -L "$C/var/run" ]; then rm -rf "$C/var/run"; ln -s /run "$C/var/run"; fi
}

# systemd isn't PID 1 in a chroot, so package scripts that call systemctl print
# "System has not been booted with systemd" / "Host is down". Divert the real
# binary and install a quiet shim (queries say "not active", everything else no-ops).
install_systemctl_shim() {
    local C="$CHROOT_DIR"
    [ -f "$C/usr/bin/systemctl.real" ] && return 0
    [ -e "$C/usr/bin/systemctl" ] || return 0
    chroot "$C" /usr/bin/dpkg-divert --local --rename \
        --divert /usr/bin/systemctl.real --add /usr/bin/systemctl >/dev/null
    printf '%s\n' '#!/bin/sh' \
        '# Chroot shim: systemd is not running here. Real binary: systemctl.real' \
        'for a in "$@"; do case "$a" in' \
        '  is-active|is-enabled|is-failed|is-system-running) exit 1 ;;' \
        'esac; done' \
        'exit 0' > "$C/usr/bin/systemctl"
    chmod 755 "$C/usr/bin/systemctl"
}

# Screen geometry and desktop sizing, cached in the chroot's /etc/titan-display.conf.
# Cutout and corner radius are read from Android once. Any value can be set on the
# command line and is remembered, e.g.:
#   DISPLAY_SCALE=1.25 ./boot_desktop.sh     smaller UI, more space
#   TOP_RESERVE=110 ./boot_desktop.sh        keep maximised windows below the camera (default 0 = full screen)
#   BOTTOM_RESERVE=37 ./boot_desktop.sh      keep maximised windows off the bottom corners (default 0)
#   TOUCH_GESTURES=0 ./boot_desktop.sh       use Termux:X11's own touch handling instead
#   LONGPRESS_MS=400 ./boot_desktop.sh       quicker long-press (right click / start drag)
#   SCROLL_PX=24 ./boot_desktop.sh           faster scrolling (finger px per scroll step)
#   PANEL_HEIGHT=40 ./boot_desktop.sh        slimmer panel (logical px, default 48 for touch)
#   TITLE_BUTTONS=left ./boot_desktop.sh     window buttons: right (default, inside the corner), left, center
#   CORNER_PAD=40 ./boot_desktop.sh          extra padding from the rounded corners (title buttons + panel ends; default 32)
#   SPACER_PX=24 ./boot_desktop.sh           width one titlebar spacer button buys, logical px (default 20);
#                                            raise to push the window buttons further from the screen corner
#   PANEL_HIDING=none ./boot_desktop.sh      always show the panel
#                (dodgewindows = hide under windows [default], autohide = always hide)
#   COMPOSITING=0 ./boot_desktop.sh          turn KWin compositing off again (faster, square windows)
#   LATE_COMPOSITING=1 ./boot_desktop.sh     start KWin (composited) before the splash exists,
#                                             so the compositor never starts over a drawn screen
#   WINDOW_RADIUS=32 ./boot_desktop.sh       corner radius of floating windows (logical px, default 24)
#   ANIMATIONS=0 ./boot_desktop.sh           turn Qt/Plasma animations off again (faster, but
#                                            scrolling becomes instant instead of smooth)
#   ADDONS=0 ./boot_desktop.sh               don't build/install Klassy + rounded corners
#   REBUILD_ADDONS=1 ./boot_desktop.sh       rebuild Klassy + rounded corners from scratch
#   HOLD_KWIN=0 ./boot_desktop.sh            let apt upgrade KWin again (the saved build then needs a rebuild)
#   RESET_WINDOWS=1 ./boot_desktop.sh        re-apply the Titan window look after editing it yourself
#   NOTIFY_FORWARD=0 ./boot_desktop.sh       show Linux notifications in Plasma instead of as Android ones
#   NOTIFY_STYLE=toast ./boot_desktop.sh     Android toasts (needs Termux:API) instead of notifications
#                                            (default: notification; "both" does toast + notification)
#   LAUNCHER=dashboard ./boot_desktop.sh     app launcher: kickoff (touch grid, default), dashboard (KDE's
#                                            full-screen Application Dashboard), drawer (Plasma Drawer)
#   SPLASH=0 ./boot_desktop.sh               no splash screen at login
#   EXIT_TO=termux ./boot_desktop.sh         after the session: termux (default from a terminal) or home
#                                            (default from a Termux:Widget task) screen
#   GPU=0 ./boot_desktop.sh                  no GPU: draw everything on the CPU (llvmpipe)
#   KWIN_GPU=1 ./boot_desktop.sh             let KWin's compositor use the GPU too (default: apps only;
#                                            KWin on the GPU tends to lose compositing = square corners)
#   GPU=angle ./boot_desktop.sh              GPU through ANGLE instead of the phone's native OpenGL ES
#                (default: GPU=1, the phone's Mali GPU via Termux's virgl server, when installed)
#   REPOS=0 ./boot_desktop.sh                skip adding the extra package sources (titan_repos.sh)
#   WINE=0 ./boot_desktop.sh                 skip the Box64/Box86 + Wine setup
#   WINE_RESET=1 ./boot_desktop.sh           fresh Wine prefix (~/.wine) if Wine misbehaves
#   WINE_REDO=1 ./boot_desktop.sh            redo the whole Box64/Box86/Wine setup
#   ROUTE_RECENTS=0 ./boot_desktop.sh        don't treat an on-screen quickstep/overview window as
#                                            Android (the desktop then keeps the touchscreen in Recents)
#   ROUTE_DEBUG=1 ./boot_desktop.sh          log what Android reports about the focused window each second
#   DETECT_DISPLAY=1 ./boot_desktop.sh       re-read cutout/corners from Android
DISPLAY_CONF_REL="/etc/titan-display.conf"
DISPLAY_CONF_VERSION=19

# Ask Android about the screen. Sets ANDROID_TOP (cutout band height), ANDROID_RADIUS
# (largest corner radius) and ANDROID_CUTOUT_RIGHT (right edge of the camera hole), px.
read_android_display() {
    local dump
    info "Reading screen cutout and corner radius from Android..."
    dump="$(dumpsys display 2>/dev/null || true)"
    ANDROID_TOP="$(printf '%s' "$dump" | grep -o 'insets=Rect([0-9]*, [0-9]*' | head -n1 | sed 's/.*, //' || true)"
    ANDROID_RADIUS="$(printf '%s' "$dump" | grep -o 'radius=[0-9]*' | cut -d= -f2 | sort -n | tail -n1 || true)"
    # Bounds=[left, top, right, bottom] rects of the cutout; the top one is the camera hole.
    ANDROID_CUTOUT_RIGHT="$(printf '%s' "$dump" | grep -o 'Bounds=\[[^]]*\]' | head -n1 \
        | grep -o 'Rect([0-9]*, [0-9]* - [0-9]*, [0-9]*)' | sed -n 2p | sed 's/.* - //; s/,.*//' || true)"
    [ -n "$ANDROID_TOP" ] && [ "$ANDROID_TOP" -gt 0 ] 2>/dev/null \
        || { ANDROID_TOP=100; warn "Cutout not reported; using ${ANDROID_TOP}px."; }
    [ -n "$ANDROID_RADIUS" ] && [ "$ANDROID_RADIUS" -gt 0 ] 2>/dev/null \
        || { ANDROID_RADIUS=100; warn "Corner radius not reported; using ${ANDROID_RADIUS}px."; }
    [ -n "$ANDROID_CUTOUT_RIGHT" ] && [ "$ANDROID_CUTOUT_RIGHT" -gt 0 ] 2>/dev/null \
        || ANDROID_CUTOUT_RIGHT="$ANDROID_TOP"   # assume the hole is about as wide as the band is tall
}

detect_display() {
    local conf="$CHROOT_DIR$DISPLAY_CONF_REL" v w old_version
    # Values given on the command line win and are remembered.
    DISPLAY_GIVEN=""
    for v in $DISPLAY_SETTINGS; do
        eval "w=\"\${$v:-}\""
        [ -n "$w" ] && DISPLAY_GIVEN="$DISPLAY_GIVEN $v"
        eval "want_$v=\"\$w\""
    done
    CONF_VERSION=0
    if [ -f "$conf" ] && [ "${DETECT_DISPLAY:-0}" != 1 ]; then
        . "$conf"
    else
        read_android_display
        TOP_INSET="$ANDROID_TOP"; CORNER_RADIUS="$ANDROID_RADIUS"; CUTOUT_RIGHT="$ANDROID_CUTOUT_RIGHT"
        CONF_VERSION="$DISPLAY_CONF_VERSION"
    fi
    # Upgrade older configs.
    old_version="${CONF_VERSION:-0}"
    if [ "$old_version" -lt 2 ]; then          # v2: roomier 1.5x scale, slimmer panel
        DISPLAY_SCALE=1.5; TOP_RESERVE=0; PANEL_HEIGHT=36
    fi
    if [ "$old_version" -lt 4 ]; then          # v4: maximised windows fill the whole screen
        TOP_RESERVE=0; BOTTOM_RESERVE=0
    fi
    if [ "$old_version" -lt 5 ] && [ -z "${CUTOUT_RIGHT:-}" ]; then   # v5: camera hole position
        read_android_display
        CUTOUT_RIGHT="$ANDROID_CUTOUT_RIGHT"
    fi
    # Defaults for anything still unset.
    DISPLAY_SCALE="${DISPLAY_SCALE:-1.5}"; TOP_RESERVE="${TOP_RESERVE:-0}"; BOTTOM_RESERVE="${BOTTOM_RESERVE:-0}"
    PANEL_HEIGHT="${PANEL_HEIGHT:-52}"; PANEL_HIDING="${PANEL_HIDING:-dodgewindows}"
    TOUCH_GESTURES="${TOUCH_GESTURES:-1}"; LONGPRESS_MS="${LONGPRESS_MS:-500}"; SCROLL_PX="${SCROLL_PX:-36}"
    COMPOSITING="${COMPOSITING:-1}"; LATE_COMPOSITING="${LATE_COMPOSITING:-0}"; ANIMATIONS="${ANIMATIONS:-1}"; ADDONS="${ADDONS:-1}"; CUTOUT_RIGHT="${CUTOUT_RIGHT:-$TOP_INSET}"
    [ "$old_version" -lt 11 ] && [ "${NOTIFY_STYLE:-toast}" = toast ] && NOTIFY_STYLE=notification   # v11: standard notifications
    # v12: Termux:X11 runs immersive, and Android hides heads-up pop-ups over immersive apps;
    # "both" = a toast on screen right away + the notification in the shade. Taller panel.
    [ "$old_version" -lt 12 ] && [ "${NOTIFY_STYLE:-}" = notification ] && NOTIFY_STYLE=both
    [ "$old_version" -lt 12 ] && [ "${PANEL_HEIGHT:-48}" = 48 ] && PANEL_HEIGHT=58
    [ "$old_version" -lt 13 ] && [ "${PANEL_HEIGHT:-58}" = 58 ] && PANEL_HEIGHT=50   # v13: one consistent panel size
    [ "$old_version" -lt 14 ] && [ "${NOTIFY_STYLE:-}" = both ] && NOTIFY_STYLE=notification   # v14: silent shade only
    [ "$old_version" -lt 15 ] && [ "${LAUNCHER:-dashboard}" = dashboard ] && LAUNCHER=drawer   # v15: Plasma Drawer launcher
    [ "$old_version" -lt 16 ] && [ "${PANEL_HEIGHT:-50}" = 50 ] && PANEL_HEIGHT=60             # v16: one touch size for every panel item
    [ "$old_version" -lt 17 ] && [ "${LAUNCHER:-}" = drawer ] && LAUNCHER=dashboard              # v17: launcher default changed
    [ "$old_version" -lt 18 ] && [ "${PANEL_HEIGHT:-60}" = 60 ] && PANEL_HEIGHT=52             # v18: panel-driven sizes for every item
    [ "$old_version" -lt 18 ] && [ "${LAUNCHER:-}" = dashboard ] && LAUNCHER=drawer              # v18: Drawer works once the menu file exists
    [ "$old_version" -lt 19 ] && [ "${LAUNCHER:-}" = drawer ] && LAUNCHER=kickoff                # v19: Kickoff icon grid is the default
    [ "$old_version" -lt 19 ] && [ "${LAUNCHER:-}" = drawer ] && LAUNCHER=kickoff                # v19: Kickoff in touch/grid form
    NOTIFY_FORWARD="${NOTIFY_FORWARD:-1}"; NOTIFY_STYLE="${NOTIFY_STYLE:-notification}"; SPLASH="${SPLASH:-0}"; LAUNCHER="${LAUNCHER:-kickoff}"
    for v in $DISPLAY_SETTINGS; do
        eval "w=\"\$want_$v\""
        [ -n "$w" ] && eval "$v=\"\$w\""
    done
    # v6: maximised windows are square (the screen rounds them); floating windows get a
    # window-sized radius instead of the screen's. Replace the old screen-sized default.
    if [ "$old_version" -lt 6 ] && [ -n "${WINDOW_RADIUS:-}" ] \
       && [ "$WINDOW_RADIUS" = "$(awk -v r="$CORNER_RADIUS" -v s="$DISPLAY_SCALE" 'BEGIN { printf "%d", r / s + 0.5 }')" ]; then
        WINDOW_RADIUS=""
    fi
    WINDOW_RADIUS="${WINDOW_RADIUS:-24}"
    # v7: touch layout — taller panel unless you set your own height.
    [ "$old_version" -lt 7 ] && [ "${PANEL_HEIGHT:-36}" = 36 ] && PANEL_HEIGHT=48
    [ "$old_version" -lt 9 ] && [ "${TITLE_BUTTONS:-}" != left ] && TITLE_BUTTONS=right   # v9: big buttons on the right
    [ "$old_version" -lt 10 ] && [ "${CORNER_PAD:-16}" = 16 ] && CORNER_PAD=32   # v10: more room from the corners
    TITLE_BUTTONS="${TITLE_BUTTONS:-right}"; CORNER_PAD="${CORNER_PAD:-32}"; SPACER_PX="${SPACER_PX:-20}"
    {
        printf '%s\n' "CONF_VERSION=$DISPLAY_CONF_VERSION" "SCREEN_W=1080" "SCREEN_H=1200"
        for v in $DISPLAY_SETTINGS; do eval "printf '%s=%s\\n' \"$v\" \"\$$v\""; done
    } > "$conf"
    log "Display: scale ${DISPLAY_SCALE}x, corners ${CORNER_RADIUS}px, camera hole to ${CUTOUT_RIGHT}px, compositing $([ "$COMPOSITING" = 1 ] && echo on || echo off), window radius ${WINDOW_RADIUS}"
}

# Returns 0 if a setting was given on this boot's command line: display_given COMPOSITING
display_given() { case " $DISPLAY_GIVEN " in *" $1 "*) return 0 ;; esac; return 1; }

run_in_chroot() {  # run a bash command as root inside the chroot with a clean env
    chroot "$CHROOT_DIR" /usr/bin/env -i HOME=/root TERM="${TERM:-xterm-256color}" \
        LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        /bin/bash -c "$1"
}

# KWin compositing on/off. With LATE_COMPOSITING=1 the session launcher (written by
# boot_desktop.sh) starts KWin itself, composited, on a blank screen before the splash
# exists - so the Enabled key is the same either way.
apply_compositing() {   # apply_compositing <user> <0|1>
    local enabled=false
    [ "$2" = 1 ] && enabled=true
    chroot "$CHROOT_DIR" /bin/su - "$1" -c "
        K=\$(command -v kwriteconfig6 || command -v kwriteconfig5) || exit 0
        \$K --file kwinrc --group Compositing --key Enabled $enabled
        \$K --file kwinrc --group Compositing --key Backend OpenGL
        \$K --file kwinrc --group Compositing --key GLCore false
        \$K --file kwinrc --group Compositing --key OpenGLIsUnsafe false
        \$K --file kwinrc --group Compositing --key WindowsBlockCompositing false"
}

# One-time KDE tuning for a CPU-rendered phone desktop. Runs as the desktop user
# in a single chroot call; a stamp file makes later boots skip it.
TUNE_VERSION=9
tune_kde() {
    local user="$1" stamp="$CHROOT_DIR/home/$1/.config/.titan_tuned" ANIM="${ANIMATIONS:-1}"
    TUNE_APPLIED=0
    [ "$(cat "$stamp" 2>/dev/null)" = "$TUNE_VERSION" ] && return 0
    TUNE_APPLIED=1
    info "Applying one-time KDE speed tuning..."
    chroot "$CHROOT_DIR" /bin/su - "$user" -c '
        K=$(command -v kwriteconfig6 || command -v kwriteconfig5) || {
            mkdir -p ~/.config; printf "[General]\nsystemdBoot=false\n" > ~/.config/startkderc; exit 1; }
        # First boot: with no kdeglobals yet Plasma falls back to light Breeze, so panels
        # and dialogs come up white until the Klassy pass finishes in the background (that
        # pass is where the dark scheme used to be set, and it only runs once Klassy is
        # installed). Seed the file from a dark scheme up front; everything below layers
        # on top. Only when the file is absent, so an existing choice is never overwritten.
        if [ ! -f ~/.config/kdeglobals ]; then
            mkdir -p ~/.config
            for c in KlassyDark BreezeDark; do
                if [ -f "/usr/share/color-schemes/$c.colors" ]; then
                    cp "/usr/share/color-schemes/$c.colors" ~/.config/kdeglobals
                    $K --file kdeglobals --group General --key ColorScheme "$c"
                    break
                fi
            done
        fi
        $K --file baloofilerc     --group "Basic Settings" --key "Indexing-Enabled" false
        $K --file ksmserverrc     --group General    --key loginMode emptySession
        $K --file ksmserverrc     --group General    --key confirmLogout true
        $K --file ksmserverrc     --group General    --key offerShutdown false
        $K --file kscreenlockerrc --group Daemon     --key Autolock false
        $K --file kscreenlockerrc --group Daemon     --key LockOnResume false
        $K --file kwinrc          --group Plugins    --key blurEnabled false
        $K --file kwinrc          --group Plugins    --key contrastEnabled false
        # Plasma 6.4 moved the decoration settings from org.kde.kdecoration2 to
        # org.kde.kdecoration3; write both so the same config works either way.
        for g in org.kde.kdecoration2 org.kde.kdecoration3; do
            $K --file kwinrc      --group $g --key BorderSize None
            $K --file kwinrc      --group $g --key BorderSizeAuto false
        done
        # Qt/Plasma smooth scrolling is animation-driven: with this at 0 every
        # ScrollView jumps instead of gliding. ANIMATIONS=0 restores the fast, instant look.
        $K --file kdeglobals      --group KDE        --key AnimationDurationFactor '"$ANIM"'
        # Touch: Plasma tablet mode (bigger controls and spacing everywhere), single tap
        # opens files, new windows open maximised, no window shading/roll-up on the bar.
        $K --file kdeglobals      --group KDE        --key TabletMode on
        $K --file kdeglobals      --group KDE        --key SingleClick true
        $K --file kwinrc          --group Windows    --key Placement Maximizing
        $K --file kwinrc          --group MouseBindings --key CommandTitlebarWheel Nothing
        $K --file kwinrc          --group Windows    --key TitlebarDoubleClickCommand Maximize
        # Bigger touch targets everywhere: larger default fonts and icons (touch mode
        # already spaces controls out), bigger toolbar/dialog icons, bigger terminal font.
        $K --file kdeglobals      --group General    --key font "Noto Sans,11,-1,5,50,0,0,0,0,0"
        $K --file kdeglobals      --group General    --key menuFont "Noto Sans,11,-1,5,50,0,0,0,0,0"
        $K --file kdeglobals      --group General    --key toolBarFont "Noto Sans,11,-1,5,50,0,0,0,0,0"
        $K --file kdeglobals      --group General    --key smallestReadableFont "Noto Sans,9,-1,5,50,0,0,0,0,0"
        $K --file kdeglobals      --group WM         --key activeFont "Noto Sans,11,-1,5,63,0,0,0,0,0"
        $K --file kdeglobals      --group SmallIcons --key Size 22
        $K --file kdeglobals      --group ToolbarIcons --key Size 32
        $K --file kdeglobals      --group MainToolbarIcons --key Size 32
        $K --file kdeglobals      --group DialogIcons --key Size 48
        $K --file kdeglobals      --group DesktopIcons --key Size 64
        $K --file kdeglobals      --group PanelIcons --key Size 32
        $K --file kdeglobals      --group KDE        --key ScrollbarLeftClickNavigatesByPage false
        $K --file konsolerc       --group "Desktop Entry" --key DefaultProfile Titan.profile
        mkdir -p ~/.local/share/konsole
        printf "[Appearance]\nFont=Noto Sans Mono,12,-1,5,50,0,0,0,0,0\n[General]\nName=Titan\nParent=FALLBACK/\n[Scrolling]\nScrollBarPosition=2\n" > ~/.local/share/konsole/Titan.profile
        $K --file dolphinrc       --group General    --key ShowFullPath false
        $K --file dolphinrc       --group IconsMode  --key PreviewSize 64
        $K --file dolphinrc       --group DetailsMode --key PreviewSize 32
        $K --file startkderc      --group General    --key systemdBoot false
        mkdir -p ~/.config/autostart
        for a in org.kde.discover.notifier baloo_file org.kde.kalendarac \
                 geoclue-demo-agent org.kde.kgpg kdeconnectd org.kde.kdeconnect.daemon; do
            printf "[Desktop Entry]\nHidden=true\n" > ~/.config/autostart/$a.desktop
        done
    ' && echo "$TUNE_VERSION" > "$stamp" \
        || warn "KDE tuning incomplete (kwriteconfig not found); will retry next boot."
}

