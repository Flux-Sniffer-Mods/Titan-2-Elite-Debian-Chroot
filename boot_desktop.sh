#!/data/data/com.termux/files/usr/bin/bash
# Part of: Titan 2 Elite Debian Chroot - a full Debian/KDE desktop running
# alongside Android on a Unihertz Titan 2 Elite phone.
# Starts the Debian/KDE desktop. This is the script you run every time.
#
# Copyright (C) 2026 Flux-Sniffer-Mods
# This program is free software: you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version. It comes with
# ABSOLUTELY NO WARRANTY. See the LICENSE file, or <https://www.gnu.org/licenses/>.
#
# New to this project? Read README.md first, it explains the whole setup:
# https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Debian-Chroot
#
# boot_desktop.sh - start the KDE Plasma (X11) desktop from the Debian chroot on a
# Unihertz Titan 2 Elite, displayed through Termux:X11.
#
# Requires, in Termux:  pkg install x11-repo && pkg install termux-x11-nightly pulseaudio
# Optional:             pkg install termux-api  (plus the Termux:API app) for toasts
#
# The script runs as root (via Magisk su) and, in order:
#   1. clears any previous session, mounts the chroot, reads the display settings
#   2. starts Termux:X11, PulseAudio (TCP), the system D-Bus and the input bridge
#   3. installs or refreshes the helper programs inside the chroot and writes the
#      desktop user's session profile, autostart entries and one-time KDE settings
#   4. starts background workers: input routing, notification forwarding, phone
#      status, and the one-time Klassy and Wine setups
#   5. launches Plasma and waits for the session to end, then shuts everything down
#
# Every setting (scale, panel, launcher, compositing, ...) is given on the command
# line and remembered; the list with defaults is in chroot_common.sh.
set -eo pipefail
. "$(dirname "$(realpath "$0")")/chroot_common.sh"
# Decide now, before root escalation, whether this was started from a terminal
# (return to Termux at the end) or from a Termux:Widget task (return to the home screen).
EXIT_TO="${EXIT_TO:-$([ -t 0 ] && echo termux || echo home)}"
escalate

LOG="$TERMUX_HOME/boot_desktop.log"
exec > >(tee "$LOG") 2>&1
info "Logging to $LOG"

[ -f "$CHROOT_DIR/etc/passwd" ] || die "No chroot at $CHROOT_DIR. Run install_chroot.sh first."
CHROOT_USER="$(awk -F: '$3 == 1000 {print $1}' "$CHROOT_DIR/etc/passwd")"
[ -n "$CHROOT_USER" ] || die "No uid-1000 user inside the chroot."
log "Chroot user: $CHROOT_USER"
UHOME="$CHROOT_DIR/home/$CHROOT_USER"

# While the desktop is in front, the input bridge takes the touchscreen and keyboard
# away from Android, so Android sees no activity and turns the screen off. Lift its
# screen timeout for exactly that time and put it back when you leave (or on exit).
TIMEOUT_SAVE="$TERMUX_HOME/.config/.titan_screen_timeout"
keep_awake() {
    if [ ! -f "$TIMEOUT_SAVE" ]; then
        settings get system screen_off_timeout 2>/dev/null > "$TIMEOUT_SAVE.new" && mv -f "$TIMEOUT_SAVE.new" "$TIMEOUT_SAVE"
    fi
    settings put system screen_off_timeout 2147483647 2>/dev/null || true
}
restore_timeout() {
    [ -f "$TIMEOUT_SAVE" ] || return 0
    local t; t="$(cat "$TIMEOUT_SAVE")"
    case "$t" in ''|null|2147483647) t=60000 ;; esac
    settings put system screen_off_timeout "$t" 2>/dev/null && rm -f "$TIMEOUT_SAVE"
}
restore_timeout   # a session that did not shut down cleanly may have left the timeout raised

stop_everything() {
    # Nothing in here may abort the shutdown, and nothing in here is an error worth reporting.
    set +e; trap - ERR
    pkill -9 -x kwin_x11 2>/dev/null; pkill -9 -x plasmashell 2>/dev/null
    pkill -9 -f '^startplasma-x11' 2>/dev/null; pkill -9 -f 'python3 -u /usr/local/bin/titan_input_bridge' 2>/dev/null
    pkill -9 -f '/usr/local/bin/titan-wm' 2>/dev/null; rm -f "$CHROOT_DIR/tmp/titan_kwin.pid" 2>/dev/null
    [ -n "${ROUTE_WATCH_PID:-}" ] && kill "$ROUTE_WATCH_PID" 2>/dev/null
    restore_timeout
    [ -n "${NOTIFY_WATCH_PID:-}" ] && kill "$NOTIFY_WATCH_PID" 2>/dev/null
    [ -n "${STATUS_WATCH_PID:-}" ] && kill "$STATUS_WATCH_PID" 2>/dev/null
    kill_chroot_procs
    kill_x11
    pkill -9 -x pulseaudio 2>/dev/null
    su "$TERMUX_UID" -c "$TERMUX_PREFIX/bin/pulseaudio --kill" >/dev/null 2>&1
    pkill -9 -f virgl_test_server 2>/dev/null
    umount_chroot
    set -e; trap '[ "$BASHPID" = "$$" ] && printf "\033[1;31m[-]\033[0m Failed at %s line %s: %s\n" "${BASH_SOURCE[0]##*/}" "$LINENO" "$BASH_COMMAND" >&2' ERR
    return 0
}

cleanup() {
    set +e
    trap - ERR
    info "Session ended, shutting down chroot..."
    sync_addon_bundle 2>/dev/null || true     # a build that finished during the session
    stop_everything
    # Close the (now empty) Termux:X11 app, then go where the session was started from:
    # the Android home screen when launched from a widget/task, Termux when launched
    # from a terminal. EXIT_TO=home|termux overrides.
    am force-stop com.termux.x11 >/dev/null 2>&1 || true
    if [ "${EXIT_TO:-termux}" = termux ]; then
        am start -n com.termux/com.termux.app.TermuxActivity >/dev/null 2>&1 || true
    else
        am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1 || true
    fi
    log "Clean shutdown."
}

# ---------- reset ----------
# A previous run that was interrupted (Ctrl+C) can leave its background watchers
# alive; they would keep writing the same files as this run. End its process group.
BOOT_PID_FILE="$TERMUX_HOME/.titan_boot.pid"
if [ -f "$BOOT_PID_FILE" ]; then
    old="$(cat "$BOOT_PID_FILE" 2>/dev/null || true)"
    # After a device reboot the saved PID means nothing: the kernel hands out PIDs from
    # low numbers again, so it usually names an unrelated Android process by now. Check
    # the PID really is another boot_desktop.sh before touching it - killing a recycled
    # PID's whole process group would take out a system process. ps also exits non-zero
    # for processes it cannot inspect (different SELinux context), which under
    # "set -eo pipefail" aborted this script outright, so its failures are absorbed.
    oldcmd=""
    [ -n "$old" ] && [ -r "/proc/$old/cmdline" ] \
        && oldcmd="$(tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null || true)"
    case "$oldcmd" in
        *boot_desktop.sh*)
            if [ "$old" != "$$" ]; then
                pg="$(ps -o pgid= -p "$old" 2>/dev/null | tr -d ' ')" || pg=""
                self_pg="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" || self_pg=""
                if [ -n "$pg" ] && [ "$pg" != "$self_pg" ]; then
                    kill -9 -- "-$pg" 2>/dev/null || kill -9 "-$pg" 2>/dev/null || true
                fi
            fi
            ;;
    esac
fi
echo "$$" > "$BOOT_PID_FILE"
stop_everything
fix_data_mount
[ "${KEEP_SELINUX:-0}" = 1 ] || setenforce 0 2>/dev/null || warn "setenforce 0 failed"
mount_chroot
trap cleanup EXIT
# "Re-detect screen" asked for from the desktop last session (see titan-reset).
if [ -f "$CHROOT_DIR/tmp/titan_detect_display" ]; then
    rm -f "$CHROOT_DIR/tmp/titan_detect_display"
    DETECT_DISPLAY=1
    info "Re-detecting the screen cutout and corners (requested from the desktop)."
fi
install_systemctl_shim
detect_display
# Clock: give the chroot Android's time zone (the kernel clock is UTC; Plasma shows local time via /etc/localtime).
ATZ="$(getprop persist.sys.timezone 2>/dev/null)"
if [ -n "$ATZ" ] && [ -f "$CHROOT_DIR/usr/share/zoneinfo/$ATZ" ]; then
    ln -sf "/usr/share/zoneinfo/$ATZ" "$CHROOT_DIR/etc/localtime"
    echo "$ATZ" > "$CHROOT_DIR/etc/timezone"
else
    warn "Time zone '$ATZ' not found in the chroot (apt install tzdata); clock will show UTC."
fi

# Stale X locks/sockets are the #1 cause of "server already active" errors.
rm -rf "$CHROOT_DIR/tmp/.X11-unix" "$CHROOT_DIR/tmp/.X0-lock" "$CHROOT_DIR/tmp/.ICE-unix"
mkdir -p "$CHROOT_DIR/tmp/.X11-unix" && chmod 1777 "$CHROOT_DIR/tmp/.X11-unix"

# ---------- X server first: it's the slowest thing to come up, so it boots
# ---------- in the background while everything else below runs.
info "Starting Termux:X11..."
# touchMode=2: Termux:X11's "simulated touchscreen" (drag scrolls, long-press right-clicks)
# for whenever touch is not being handled by the bridge. Its "direct touch" mode hands
# raw touches to apps, most of which turn a drag into a text selection.
X11_PREFS="fullscreen=true hideCutout=true displayResolutionMode=custom displayResolutionCustom=1080x1200 showIMEWhileExternalConnected=false hideEKOnVolDown=false toggleIMEUsingBackKey=false touchMode=2 showAdditionalKbd=false"
X11_STAMP="$TERMUX_HOME/.config/.titan_x11_prefs"
if [ "$(cat "$X11_STAMP" 2>/dev/null)" != "$X11_PREFS" ] && [ -x "$TERMUX_PREFIX/bin/termux-x11-preference" ]; then
    # Slow (spins up a JVM), so only when the settings changed. Check keys with: termux-x11-preference list
    ( su "$TERMUX_UID" -c "$TERMUX_PREFIX/bin/termux-x11-preference $X11_PREFS" >/dev/null 2>&1 \
        || warn "Could not apply all Termux:X11 preferences; set them in the Termux:X11 app if needed."
      mkdir -p "${X11_STAMP%/*}" && echo "$X11_PREFS" > "$X11_STAMP" ) &
fi

if [ -x "$TERMUX_PREFIX/bin/termux-x11" ]; then
    TMPDIR="$CHROOT_DIR/tmp" XKB_CONFIG_ROOT="$CHROOT_DIR/usr/share/X11/xkb" \
        "$TERMUX_PREFIX/bin/termux-x11" :0 -ac &
else
    warn "termux-x11 package missing, falling back to the app's own classpath."
    TMPDIR="$CHROOT_DIR/tmp" XKB_CONFIG_ROOT="$CHROOT_DIR/usr/share/X11/xkb" \
    CLASSPATH="$(pm path com.termux.x11 | cut -d: -f2)" \
        app_process / --nice-name=termux-x11 com.termux.x11.CmdEntryPoint :0 -ac &
fi
( am start -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 \
    || warn "Could not open the Termux:X11 app; open it manually." ) &

# ---------- audio (background; not needed to reach the desktop) ----------
if [ -x "$TERMUX_PREFIX/bin/pulseaudio" ]; then
    su "$TERMUX_UID" -c "env HOME=$TERMUX_HOME TMPDIR=$TERMUX_PREFIX/tmp \
        $TERMUX_PREFIX/bin/pulseaudio --start --exit-idle-time=-1 \
        --load='module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1'" \
        >/dev/null 2>&1 &
else
    warn "Termux pulseaudio not installed; no sound. (pkg install pulseaudio)"
fi

# ---------- system D-Bus ----------
run_in_chroot 'dbus-uuidgen --ensure; chown root:messagebus /run/dbus 2>/dev/null; dbus-daemon --system --fork' \
    || warn "System D-Bus failed to start."

# ---------- helper scripts + their Python modules (installed once) ----------
for f in titan_input_bridge.py titan_display.py titan_notify_bridge.py; do
    if [ -f "$TERMUX_HOME/$f" ] && ! cmp -s "$TERMUX_HOME/$f" "$CHROOT_DIR/usr/local/bin/$f"; then
        install -m 755 "$TERMUX_HOME/$f" "$CHROOT_DIR/usr/local/bin/$f"
    fi
done
if [ -f "$TERMUX_HOME/titan_addons.sh" ] && ! cmp -s "$TERMUX_HOME/titan_addons.sh" "$CHROOT_DIR/usr/local/bin/titan-build-addons"; then
    install -m 755 "$TERMUX_HOME/titan_addons.sh" "$CHROOT_DIR/usr/local/bin/titan-build-addons"
fi
# Saved Klassy + rounded-corners build: keep the Termux-home copy and the chroot
# copy in sync, so a reinstall (or a fresh chroot) unpacks it instead of compiling.
sync_addon_bundle() {
    local c="$CHROOT_DIR/usr/local/share/titan-addons/bundle" h="$TERMUX_HOME/titan-addons-bundle"
    if [ -f "$c.tar.gz" ] && [ -f "$c.key" ] && ! cmp -s "$c.tar.gz" "$h.tar.gz"; then
        cp -f "$c.tar.gz" "$h.tar.gz" && cp -f "$c.key" "$h.key" && chown "$TERMUX_UID:$TERMUX_UID" "$h.tar.gz" "$h.key" \
            && info "Saved the Klassy/rounded-corners build to ~/titan-addons-bundle.tar.gz"
    elif [ -f "$h.tar.gz" ] && [ -f "$h.key" ] && [ ! -f "$c.tar.gz" ]; then
        mkdir -p "${c%/*}" && cp -f "$h.tar.gz" "$c.tar.gz" && cp -f "$h.key" "$c.key"
    fi
}
sync_addon_bundle
# Titan keymap (Alt/Sym layers) installed as a real X layout called "titan", so
# KDE itself applies it every time it (re)sets the keyboard layout.
XKB_SYM="$CHROOT_DIR/usr/share/X11/xkb/symbols/titan"
if [ -f "$TERMUX_HOME/titan_xkb_symbols" ] && ! cmp -s "$TERMUX_HOME/titan_xkb_symbols" "$XKB_SYM"; then
    install -m 644 "$TERMUX_HOME/titan_xkb_symbols" "$XKB_SYM"
fi
KXKB="$UHOME/.config/kxkbrc"
if [ -f "$XKB_SYM" ] && ! grep -q '^LayoutList=.*titan' "$KXKB" 2>/dev/null; then
    # The Titan layout (Alt/Sym layers) must be KDE's active layout; put it back if it
    # was ever reset.
    chroot "$CHROOT_DIR" /bin/su - "$CHROOT_USER" -c '
        K=$(command -v kwriteconfig6 || command -v kwriteconfig5) || exit 0
        $K --file kxkbrc --group Layout --key Use true
        $K --file kxkbrc --group Layout --key LayoutList titan
        $K --file kxkbrc --group Layout --key DisplayNames ""' \
        && info "Keyboard layout set to Titan in KDE."
fi
[ -f "$XKB_SYM" ] || warn "titan_xkb_symbols missing from the Termux home: Alt/Sym layers will not work."
printf '%s\n' '#!/bin/sh' \
    '# Apply the Titan 2 Elite layout (Alt/Sym layers) to the running X server.' \
    'export DISPLAY="${DISPLAY:-:0}"' \
    '[ -f /usr/share/X11/xkb/symbols/titan ] || exit 0' \
    'setxkbmap -layout titan 2>/dev/null && exit 0' \
    '# Fallback: compile here and upload, if the server cannot compile it itself.' \
    'setxkbmap -layout titan -print | xkbcomp -w 0 - "$DISPLAY"' \
    > "$CHROOT_DIR/usr/local/bin/titan-keymap"
chmod 755 "$CHROOT_DIR/usr/local/bin/titan-keymap"

PKGS=""
# Application Dashboard moved to the Plasma add-ons package in Plasma 6.
if [ ! -d "$CHROOT_DIR/usr/share/plasma/plasmoids/org.kde.plasma.kickerdash" ] \
   && ! chroot "$CHROOT_DIR" dpkg-query -W plasma-widgets-addons >/dev/null 2>&1; then
    PKGS="$PKGS plasma-widgets-addons"
fi
# KDE Menu Editor: what "Edit Applications" in the launchers opens.
[ -x "$CHROOT_DIR/usr/bin/kmenuedit" ] || PKGS="$PKGS kmenuedit"
# kdialog: the menu behind "Reset Titan settings" (titan-reset falls back to a
# command-line usage message without it).
[ -x "$CHROOT_DIR/usr/bin/kdialog" ] || PKGS="$PKGS kdialog"
# Discover (the software centre) with its PackageKit/apt backend, AppStream metadata
# for the catalogue, and polkit for the install/remove authorisation prompt.
[ -x "$CHROOT_DIR/usr/bin/plasma-discover" ] || PKGS="$PKGS plasma-discover packagekit appstream polkitd"
[ -d "$CHROOT_DIR/usr/lib/python3/dist-packages/evdev" ] || PKGS="$PKGS python3-evdev"
[ -d "$CHROOT_DIR/usr/lib/python3/dist-packages/Xlib" ]  || PKGS="$PKGS python3-xlib"
if [ -n "$PKGS" ]; then
    info "Installing$PKGS (one time)..."
    run_in_chroot "apt-get update -qq && apt-get install -y -qq --no-install-recommends$PKGS" || warn "Package install failed:$PKGS"
    case "$PKGS" in *plasma-discover*) run_in_chroot 'apt-get update -qq; appstreamcli refresh --force >/dev/null 2>&1 || true' ;; esac
fi

# Discover / PackageKit authorisation. In a chroot polkit has no login session to
# judge by, so the password prompt cannot succeed; instead, members of the sudo
# group (the desktop user) may manage packages without a prompt.
mkdir -p "$CHROOT_DIR/etc/polkit-1/rules.d"
printf '%s\n' 'polkit.addRule(function (action, subject) {' \
    '    if (action.id.indexOf("org.freedesktop.packagekit.") == 0 && subject.isInGroup("sudo")) {' \
    '        return polkit.Result.YES;' \
    '    }' \
    '});' > "$CHROOT_DIR/etc/polkit-1/rules.d/50-titan-packagekit.rules"
chmod 644 "$CHROOT_DIR/etc/polkit-1/rules.d/50-titan-packagekit.rules"
# Discover's catalogue: AppStream metadata comes with "apt update" once appstream is
# installed; refresh the cache now and then so new entries show up.
if [ -x "$CHROOT_DIR/usr/bin/appstreamcli" ] && [ ! -f "$CHROOT_DIR/var/cache/app-info/.titan_refreshed" -o -n "$(find "$CHROOT_DIR/var/cache/app-info/.titan_refreshed" -mtime +7 2>/dev/null)" ]; then
    ( run_in_chroot 'apt-get update -qq >/dev/null 2>&1; appstreamcli refresh --force >/dev/null 2>&1; mkdir -p /var/cache/app-info; touch /var/cache/app-info/.titan_refreshed' ) >/dev/null 2>&1 &
fi

# ---------- route watcher ----------
# Once a second, record whether Termux:X11 is the app in front. The bridge types
# into the desktop only while it is; otherwise keys and touch belong to Android.
# If this stops, the bridge falls back to Android within a few seconds.
route_watch() {
    set +e; trap - ERR
    local f="$CHROOT_DIR/tmp/titan_route" r last="" focus recents cand="" n=0
    while :; do
        # Small, specific query: the full "dumpsys window" is big and got cut off by
        # grep -m1, which made the answer flip between x11 and android every second.
        # Every focus/foreground line Android reports (there can be several, one per
        # display); the desktop is in front if any of them names Termux:X11. If the
        # window service says nothing, ask the activity manager which app is resumed.
        # The first real (non-null) focused window decides: Termux:X11 = desktop; the
        # launcher's Recents/overview, a settings screen, anything else = Android.
        focus="$(dumpsys window windows 2>/dev/null | grep 'mCurrentFocus=' | grep -v 'null' | head -n1 || true)"
        [ -n "$focus" ] || focus="$(dumpsys window windows 2>/dev/null | grep -E 'mFocusedApp=|mFocusedWindow=' | grep -v 'null' | head -n1 || true)"
        [ -n "$focus" ] || focus="$(dumpsys activity activities 2>/dev/null | grep -E 'ResumedActivity' | head -n1 || true)"
        # Overview is quickstep being *active*, which the focus queries above miss because
        # it is an overlay. Matching the quickstep window by name alone is wrong - the
        # launcher keeps it listed permanently, and doing that pinned the route to Android
        # on every poll - so this checks that the window is actually on screen.
        # ROUTE_RECENTS=0 turns it off if a build reports these attributes differently.
        recents=""
        if [ "${ROUTE_RECENTS:-1}" = 1 ]; then
            recents="$(dumpsys window windows 2>/dev/null | awk '
                /Window\{/ && /:[ ]*$/ { inblk = ($0 ~ /[Qq]uickstep|[Rr]ecentsActivity|[Oo]verview/); next }
                inblk && /isOnScreen=true|mHasSurface=true/ { print "recents"; exit }' || true)"
        fi
        [ "${ROUTE_DEBUG:-0}" = 1 ] && printf '[route] focus=%s | recents=%s\n' "${focus:-<none>}" "${recents:-<none>}" >&2
        case "$focus" in
            *com.termux.x11*) r=x11 ;;
            "")               r="$last" ;;          # no answer at all: no change
            *)                r=android ;;
        esac
        [ -n "$recents" ] && r=android
        [ -n "$r" ] || r=android
        # Switch only after the same answer twice in a row (no flapping on transients).
        if [ "$r" = "$cand" ]; then n=$(( n + 1 )); else cand="$r"; n=1; fi
        if [ "$r" != "$last" ] && [ "$n" -ge 2 ]; then
            [ "$r" = x11 ] && keep_awake || restore_timeout
            last="$r"
            info "input route: $r"
            echo "$r" > "$f.new" && mv -f "$f.new" "$f"
        elif [ -z "$last" ]; then
            [ "$r" = x11 ] && keep_awake || restore_timeout
            last="$r"; echo "$r" > "$f.new" && mv -f "$f.new" "$f"
        else
            touch "$f"                                   # keep it fresh for the bridge
        fi
        if [ -f "$CHROOT_DIR/tmp/titan_logout" ]; then
            # Tearing Plasma down runs its own shutdown scripts, and one of those is the
            # hook that writes this marker - so a session restart looks exactly like a
            # logout from here and used to end the whole session. Ignore it while a
            # restart is in progress.
            if [ -f "$CHROOT_DIR/tmp/titan_restarting" ]; then
                rm -f "$CHROOT_DIR/tmp/titan_logout"
            else
                info "Logout requested from the desktop; ending the session."
                rm -f "$CHROOT_DIR/tmp/titan_logout"
                kill_chroot_procs      # the session command below returns, cleanup runs
                exit 0
            fi
        fi
        sleep 1
    done
}
route_watch &
ROUTE_WATCH_PID=$!

# Shows queued Linux notifications on Android: as toasts (Termux:API's termux-toast,
# run as the Termux user), as notifications ("cmd notification post" as the shell
# user; same tag = same notification updated), or both. Toasts for a notification
# that keeps updating itself (build progress) are limited to one every 30 s.
TOAST="$TERMUX_PREFIX/bin/termux-toast"
post_toast() {   # post_toast <text>  (plain short Android toast, default look)
    su "$TERMUX_UID" -c "env PATH=$TERMUX_PREFIX/bin:/system/bin HOME=$TERMUX_HOME TMPDIR=$TERMUX_PREFIX/tmp \
        $TOAST -s $(shq "$1")" >/dev/null 2>&1
}
# Quote for the Android shell (mksh): plain single quotes, safe for any text.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# Android notification. Preferred: Termux:API's termux-notification (pops up at the
# top, can be updated silently, grouped); fallback: "cmd notification post" (no pop-up).
TNOTIFY="$TERMUX_PREFIX/bin/termux-notification"
post_notification() {   # post_notification <tag> <title> <text> <first:0|1> <progress|"">
    local prio=low extra=""                            # silent: shade only, no pop-up, no sound
    if [ -n "$5" ] && [ "$5" -lt 100 ] 2>/dev/null; then extra="--ongoing"; fi
    if [ -x "$TNOTIFY" ]; then
        su "$TERMUX_UID" -c "env PATH=$TERMUX_PREFIX/bin:/system/bin HOME=$TERMUX_HOME TMPDIR=$TERMUX_PREFIX/tmp \
            $TNOTIFY --id $(shq "$1") --group titan-linux --priority $prio --alert-once $extra \
            --title $(shq "$2") --content $(shq "$3")" >/dev/null 2>&1 && return 0
    fi
    su 2000 -c "cmd notification post -S bigtext -t $(shq "$2") $(shq "$1") $(shq "$3")" >/dev/null 2>&1 \
        || cmd notification post -S bigtext -t "$2" "$1" "$3" >/dev/null 2>&1 || true
}
# "App · Title" as the heading, body as the text; the app name is dropped when it
# is just a tool name or already in the title.
format_title() {   # format_title <app> <title>
    case "$1" in ""|notify-send|dbus-send|python3|Titan*) printf '%s' "$2" ;;
        *) case "$2" in *"$1"*) printf '%s' "$2" ;; *) printf '%s · %s' "$1" "$2" ;; esac ;;
    esac
}
# Progress as a bar in the text: ▰▰▰▰▱▱▱▱▱▱ 40%
format_body() {    # format_body <body> <progress>
    local p="$2" n bar=""
    if [ -z "$p" ]; then p="$(printf '%s' "$1" | grep -o '[0-9]\{1,3\}%' | head -n1 | tr -d %)"; fi
    if [ -n "$p" ] && [ "$p" -ge 0 ] 2>/dev/null && [ "$p" -le 100 ] 2>/dev/null; then
        n=$(( p / 10 ))
        bar="$(printf '%*s' "$n" '' | sed 's/ /▰/g')$(printf '%*s' $(( 10 - n )) '' | sed 's/ /▱/g') ${p}%"
        printf '%s\n%s' "$bar" "$1"
    else
        printf '%s' "$1"
    fi
}
notify_watch() {
    set +e; trap - ERR
    local f="$CHROOT_DIR/tmp/titan_notify.queue" done=0 n tag title body app progress first style="$NOTIFY_STYLE" now text
    local last="$CHROOT_DIR/tmp/titan_notify.last"; : > "$last"
    if [ "$style" != notification ] && [ ! -x "$TOAST" ]; then
        warn "termux-toast not found (pkg install termux-api + the Termux:API app); using Android notifications."
        style=notification
    fi
    while :; do
        n="$(wc -l < "$f" 2>/dev/null || echo 0)"
        if [ "$n" -gt "$done" ]; then
            sed -n "$((done + 1)),${n}p" "$f" | while IFS="$(printf '\t')" read -r tag title body app progress; do
                first=1; grep -q "^$tag " "$last" 2>/dev/null && first=0
                grep -q "^$tag " "$last" 2>/dev/null || echo "$tag $(date +%s)" >> "$last"
                case "$style" in
                    toast|both)
                        now="$(date +%s)"
                        # one toast per updating notification every 30 s
                        if ! grep -q "^$tag " "$last" 2>/dev/null \
                           || [ $(( now - $(grep "^$tag " "$last" | cut -d' ' -f2) )) -ge 30 ]; then
                            { grep -v "^$tag " "$last" 2>/dev/null; echo "$tag $now"; } > "$last.new" && mv -f "$last.new" "$last"
                            text="$title${body:+: $body}"
                            [ ${#text} -gt 90 ] && text="$(printf '%.87s' "$text")..."
                            post_toast "$text"
                        fi ;;
                esac
                case "$style" in
                    notification|both)
                        post_notification "$tag" "$(format_title "$app" "$title")" "$(format_body "${body:-$title}" "$progress")" "$first" "$progress" ;;
                esac
            done
            done="$n"
        fi
        sleep 1
    done
}
if [ "$NOTIFY_FORWARD" = 1 ]; then
    notify_watch &
    NOTIFY_WATCH_PID=$!
fi

# Every 15 s: battery, Wi-Fi, mobile signal and notification count from Android,
# for the "Phone status" panel widget.
collect_status() {
    local f="$CHROOT_DIR/tmp/titan_status" bat chg wifi rssi wl cell notif d won temp volt health op vol volmax
    d="$(dumpsys battery 2>/dev/null)"
    bat="$(printf '%s' "$d" | sed -n 's/^ *level: *//p' | head -n1)"
    case "$(printf '%s' "$d" | sed -n 's/^ *status: *//p' | head -n1)" in 2|5) chg=1 ;; *) chg=0 ;; esac
    temp="$(printf '%s' "$d" | sed -n 's/^ *temperature: *//p' | head -n1)"; [ -n "$temp" ] && temp="$(( temp / 10 )).$(( temp % 10 ))"
    volt="$(printf '%s' "$d" | sed -n 's/^ *voltage: *//p' | head -n1)"; [ -n "$volt" ] && [ "$volt" -gt 100 ] 2>/dev/null && volt="$(( volt / 1000 )).$(( (volt % 1000) / 10 ))"
    case "$(printf '%s' "$d" | sed -n 's/^ *health: *//p' | head -n1)" in 2) health=good ;; 3) health=overheated ;; 4) health=dead ;; 5) health=overvoltage ;; 7) health=cold ;; *) health="" ;; esac
    d="$(cmd wifi status 2>/dev/null)"
    case "$d" in *"Wifi is enabled"*) won=1 ;; *) won=0 ;; esac
    wifi="$(printf '%s' "$d" | grep -o 'connected to "[^"]*"' | head -n1 | sed 's/connected to //; s/"//g')"
    rssi="$(printf '%s' "$d" | grep -o 'RSSI: *-*[0-9]*' | head -n1 | grep -o -- '-*[0-9]*$')"
    wl=0; [ -n "$rssi" ] && { [ "$rssi" -ge -85 ] && wl=1; [ "$rssi" -ge -75 ] && wl=2; [ "$rssi" -ge -65 ] && wl=3; [ "$rssi" -ge -55 ] && wl=4; }
    cell="$(dumpsys telephony.registry 2>/dev/null | grep -o 'level=[0-4]\|mLevel=[0-4]\|Level=[0-4]' | grep -o '[0-4]$' | sort -n | tail -n1)"
    [ -n "$cell" ] || cell="$(dumpsys telephony.registry 2>/dev/null | grep -o 'mSignalStrength[^}]*' | grep -o 'level=[0-4]' | grep -o '[0-4]$' | sort -n | tail -n1)"
    op="$(getprop gsm.operator.alpha 2>/dev/null | cut -d, -f1)"
    notif="$(dumpsys notification --noredact 2>/dev/null | grep -c 'NotificationRecord(' || echo 0)"
    d="$(cmd media_session volume --stream 3 --get 2>/dev/null)"
    vol="$(printf '%s' "$d" | grep -o 'volume is [0-9]*' | grep -o '[0-9]*$')"; volmax="$(printf '%s' "$d" | grep -o '\.\.[0-9]*' | grep -o '[0-9]*$')"
    if [ -z "$vol" ]; then   # fall back to the audio service dump: "- STREAM_MUSIC: ... Max: 25 ... Current: 2 (speaker): 10, ..."
        d="$(dumpsys audio 2>/dev/null | awk '/STREAM_MUSIC:/ { on = 1 } on && /Max:/ { print "MAX " $2 }
            on && /streamVolume:/ { v = $0; sub(/.*streamVolume: */, "", v); gsub(/[^0-9]/, "", v); print "CUR " v; exit }
            on && /Current:/ { sub(/.*Current: */, ""); n = split($0, a, /[:,]/); print "CUR " a[2]; exit }')"
        volmax="$(printf '%s' "$d" | awk '/^MAX/ { print $2 }')"; vol="$(printf '%s' "$d" | awk '/^CUR/ { gsub(/[^0-9]/, "", $2); print $2 }')"
    fi
    local t="$f.new.$$"
    printf '%s\n' "BAT=$bat" "CHG=$chg" "BAT_TEMP=$temp" "BAT_VOLT=$volt" "BAT_HEALTH=$health" \
        "WIFI_ON=$won" "WIFI=$wifi" "RSSI=$rssi" "WIFI_LVL=$wl" "CELL=$cell" "OPERATOR=$op" "NOTIF=$notif" \
        "DATA_ON=$(settings get global mobile_data 2>/dev/null)" "AIRPLANE=$(settings get global airplane_mode_on 2>/dev/null)" \
        "BT_ON=$(settings get global bluetooth_on 2>/dev/null)" "SAVER=$(settings get global low_power 2>/dev/null)" \
        "DND=$([ "$(settings get global zen_mode 2>/dev/null)" != 0 ] && echo 1 || echo 0)" \
        "BRIGHT=$(settings get system screen_brightness 2>/dev/null)" "VOL=${vol:-0}" "VOL_MAX=${volmax:-15}" > "$t" \
        && chmod 644 "$t" && mv -f "$t" "$f"
}
wifi_scan() {   # RSSI <TAB> SSID <TAB> flags, strongest first
    local f="$CHROOT_DIR/tmp/titan_wifi_scan"
    # Android throttles app-requested scans (4 per 2 minutes by default) and silently
    # ignores the rest, so "start-scan" returns success while list-scan-results keeps
    # handing back the same cached entries with a growing Age(sec). Turning the throttle
    # off is what makes a refresh actually re-scan.
    settings put global wifi_scan_throttle_enabled 0 >/dev/null 2>&1 || true
    cmd wifi start-scan >/dev/null 2>&1; sleep 4
    cmd wifi list-scan-results 2>/dev/null | awk 'NR > 1 && NF >= 5 {
        ssid = ""; for (i = 5; i <= NF && $i !~ /^\[/; i++) ssid = ssid (ssid == "" ? "" : " ") $i
        if (ssid != "" && !(ssid in seen)) { seen[ssid] = 1; print $3 "\t" ssid "\t" $NF } }' \
        | sort -t"$(printf '\t')" -k1,1nr > "$f.new" && chmod 644 "$f.new" && mv -f "$f.new" "$f"
}
# Requests from the widget (one per line), performed as root on the Android side.
handle_android_cmd() {
    local cmd a1 a2 f="$CHROOT_DIR/tmp/titan_android_cmd" lines shot env
    [ -s "$f" ] || return 0
    lines="$(cat "$f")"; : > "$f"
    printf '%s\n' "$lines" | while IFS="$(printf '\t')" read -r cmd a1 a2 _; do
        [ -n "$cmd" ] || continue
        printf '%s %s\n' "$(date +%H:%M:%S)" "$cmd${a1:+ $a1}" >> "$TERMUX_HOME/android_cmd.log"
        case "$cmd" in
            wifi_on)  cmd wifi set-wifi-enabled enabled  >/dev/null 2>&1; (sleep 2; wifi_scan) & ;;
            wifi_off) cmd wifi set-wifi-enabled disabled >/dev/null 2>&1 ;;
            wifi_scan) wifi_scan & ;;
            wifi_connect)
                if [ -n "$a2" ]; then cmd wifi connect-network "$a1" wpa2 "$a2" >/dev/null 2>&1
                else cmd wifi connect-network "$a1" open >/dev/null 2>&1; fi ;;
            wifi_forget)
                id="$(cmd wifi list-networks 2>/dev/null | awk -v s="$a1" 'NR > 1 { l = $0; sub(/^[ ]*[0-9]+[ ]+/, "", l); sub(/[ ]+[^ ]+$/, "", l); if (l == s) print $1 }' | head -n1)"
                [ -n "$id" ] && cmd wifi forget-network "$id" >/dev/null 2>&1 ;;
            data_on)  svc data enable ;;  data_off) svc data disable ;;
            airplane_on)  cmd connectivity airplane-mode enable  >/dev/null 2>&1 || { settings put global airplane_mode_on 1; am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true >/dev/null 2>&1; } ;;
            airplane_off) cmd connectivity airplane-mode disable >/dev/null 2>&1 || { settings put global airplane_mode_on 0; am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false >/dev/null 2>&1; } ;;
            bt_on)  svc bluetooth enable  >/dev/null 2>&1 || cmd bluetooth_manager enable  >/dev/null 2>&1 ;;
            bt_off) svc bluetooth disable >/dev/null 2>&1 || cmd bluetooth_manager disable >/dev/null 2>&1 ;;
            saver_on)  settings put global low_power 1 ;;  saver_off) settings put global low_power 0 ;;
            dnd_on)  cmd notification set_dnd priority >/dev/null 2>&1 || settings put global zen_mode 1 ;;
            dnd_off) cmd notification set_dnd off      >/dev/null 2>&1 || settings put global zen_mode 0 ;;
            brightness) settings put system screen_brightness_mode 0; settings put system screen_brightness "$a1" ;;
            volume) cmd media_session volume --stream 3 --set "$a1" >/dev/null 2>&1 ;;
            # No Android volume dialog (its focus change is what pops the keyboard app up
            # over the desktop); KDE's own volume display shows the level instead.
            volume_up)   android_volume_step 1 ;;
            volume_down) android_volume_step -1 ;;
            notifications) cmd statusbar expand-notifications >>"$TERMUX_HOME/android_cmd.log" 2>&1 ;;
            # Reset requests from the desktop (see titan-reset). Some apply at once,
            # the rest set a marker the next start picks up.
            reset)
                case "$a1" in
                    panel)
                        rm -f "$UHOME/.config/.titan_panel_applied"
                        touch "$CHROOT_DIR/tmp/titan_panel_rebuild" && chmod 666 "$CHROOT_DIR/tmp/titan_panel_rebuild"
                        env="$(plasma_env)" && chroot "$CHROOT_DIR" /bin/su - "$CHROOT_USER" -c \
                            "$env setsid /usr/bin/python3 /usr/local/bin/titan_display.py >/dev/null 2>&1 &" ;;
                    windows)
                        rm -f "$CHROOT_DIR/usr/local/share/titan-addons/configured"
                        chroot "$CHROOT_DIR" /usr/bin/env -i HOME=/root LANG=C.UTF-8 TITLE_BUTTONS="$TITLE_BUTTONS" \
                            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
                            /usr/local/bin/titan-build-addons --configure >/dev/null 2>&1 & ;;
                    tuning)  rm -f "$UHOME/.config/.titan_tuned" ;;
                    display) touch "$CHROOT_DIR/tmp/titan_detect_display" ;;
                    addons)
                        chroot "$CHROOT_DIR" /usr/bin/env -i HOME=/root LANG=C.UTF-8 TITLE_BUTTONS="$TITLE_BUTTONS" \
                            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
                            /usr/local/bin/titan-build-addons --force >/dev/null 2>&1 & ;;
                    session) touch "$CHROOT_DIR/tmp/titan_restart" ;;
                    *) echo "  unknown reset: $a1" >> "$TERMUX_HOME/android_cmd.log" ;;
                esac ;;
            screenshot)
                # Power + Volume Down while the desktop is in front. The bridge sends this
                # because Android never sees Volume Down then, so its own combo cannot fire.
                shot="/sdcard/Pictures/Screenshots/titan-$(date +%Y%m%d-%H%M%S).png"
                mkdir -p /sdcard/Pictures/Screenshots 2>/dev/null
                if screencap -p "$shot" >>"$TERMUX_HOME/android_cmd.log" 2>&1 && [ -s "$shot" ]; then
                    chmod 644 "$shot" 2>/dev/null
                    # Let the gallery notice the new file (ignored on releases that dropped this).
                    am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$shot" >/dev/null 2>&1 || true
                    plasma_notify "Screenshot" "Screenshot saved" "${shot##*/}" >/dev/null || true
                else
                    plasma_notify "Screenshot" "Screenshot failed" "See ~/android_cmd.log" >/dev/null || true
                fi ;;
            lock) input keyevent 223 >>"$TERMUX_HOME/android_cmd.log" 2>&1 || input keyevent 26 >>"$TERMUX_HOME/android_cmd.log" 2>&1 ;;   # screen off -> Android lock screen
            settings) am start -a android.settings.SETTINGS >>"$TERMUX_HOME/android_cmd.log" 2>&1 ;;
            *) echo "  unknown command: $cmd" >> "$TERMUX_HOME/android_cmd.log" ;;
        esac
    done
    collect_status
}
quick_status() {   # volume + brightness only: cheap, so it can run every 2 s
    local f="$CHROOT_DIR/tmp/titan_status" d vol volmax b
    [ -f "$f" ] || return 0
    d="$(cmd media_session volume --stream 3 --get 2>/dev/null)"
    vol="$(printf '%s' "$d" | grep -o 'volume is [0-9]*' | grep -o '[0-9]*$')"; volmax="$(printf '%s' "$d" | grep -o '\.\.[0-9]*' | grep -o '[0-9]*$')"
    b="$(settings get system screen_brightness 2>/dev/null)"
    [ -n "$vol" ] || return 0
    local t="$f.new.$$"
    { grep -v '^VOL=\|^VOL_MAX=\|^BRIGHT=' "$f"; printf '%s\n' "VOL=$vol" "VOL_MAX=${volmax:-15}" "BRIGHT=$b"; } > "$t" \
        && chmod 644 "$t" && mv -f "$t" "$f"
}
# ---------- Android notifications -> Plasma ----------
# Every few seconds the Android shade is read; each new notification (not ongoing
# ones, not the ones we posted ourselves) becomes a Plasma notification. It is sent
# as "critical" so it shows even though Plasma is in Do Not Disturb (which keeps the
# Linux apps' own popups off; those go to Android). When it leaves the Android
# shade it is closed in Plasma too.
NOTIF_MAP="$CHROOT_DIR/tmp/titan_android_notifs"   # key<TAB>plasma-id per line
: > "$NOTIF_MAP"
plasma_env() {   # DISPLAY + session bus of the user's plasmashell
    local pid; pid="$(pgrep -x plasmashell | head -n1)"; [ -n "$pid" ] && [ -r "/proc/$pid/environ" ] || return 1
    printf "DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS='%s'" "$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')"
}
plasma_notify() {   # plasma_notify <app> <title> <body> [progress%] [replace-id]  -> prints the Plasma notification id
    local env hint="" rep=""; env="$(plasma_env)" || return 1
    [ -n "${4:-}" ] && hint="-h int:value:$4"
    [ -n "${5:-}" ] && rep="-r $5"
    chroot "$CHROOT_DIR" /bin/su "$CHROOT_USER" -c "$env notify-send -p $rep -a $(shq "$1") -i phone -u critical $hint $(shq "$2") $(shq "$3")" 2>/dev/null | tail -n1
}
android_volume_step() {   # +1 / -1 on the media volume, without Android's dialog
    local d v m
    d="$(cmd media_session volume --stream 3 --get 2>/dev/null)"
    v="$(printf '%s' "$d" | grep -o 'volume is [0-9]*' | grep -o '[0-9]*$')"; m="$(printf '%s' "$d" | grep -o '\.\.[0-9]*' | grep -o '[0-9]*$')"
    [ -n "$v" ] && [ -n "$m" ] || { cmd media_session volume --stream 3 --adj $([ "$1" -gt 0 ] && echo raise || echo lower) >/dev/null 2>&1; return; }
    v=$(( v + $1 )); [ "$v" -lt 0 ] && v=0; [ "$v" -gt "$m" ] && v="$m"
    cmd media_session volume --stream 3 --set "$v" >/dev/null 2>&1
    plasma_volume_osd
}
plasma_volume_osd() {   # show Android's media volume in Plasma's on-screen display
    local env d v m pct; env="$(plasma_env)" || return 0
    d="$(cmd media_session volume --stream 3 --get 2>/dev/null)"
    v="$(printf '%s' "$d" | grep -o 'volume is [0-9]*' | grep -o '[0-9]*$')"; m="$(printf '%s' "$d" | grep -o '\.\.[0-9]*' | grep -o '[0-9]*$')"
    [ -n "$v" ] && [ -n "$m" ] && [ "$m" -gt 0 ] || return 0
    pct=$(( v * 100 / m ))
    chroot "$CHROOT_DIR" /bin/su "$CHROOT_USER" -c "$env dbus-send --session --dest=org.kde.plasmashell /org/kde/osdService org.kde.osdService.volumeChanged int32:$pct" >/dev/null 2>&1
}
plasma_close() {    # plasma_close <id>
    local env; env="$(plasma_env)" || return 1
    chroot "$CHROOT_DIR" /bin/su "$CHROOT_USER" -c "$env dbus-send --session --dest=org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications.CloseNotification uint32:$1" >/dev/null 2>&1
}
android_shade() {   # key<TAB>pkg<TAB>flags<TAB>title<TAB>text<TAB>progress%, one per notification
    dumpsys notification --noredact 2>/dev/null | awk '
        /NotificationRecord\(/ { flush(); key = $0; sub(/.*key=/, "", key); sub(/:.*/, "", key)
            pkg = $0; sub(/.*pkg=/, "", pkg); sub(/ .*/, "", pkg)
            flags = $0; if (sub(/.*flags=/, "", flags)) sub(/[ )].*/, "", flags); else flags = "0x0"; title = ""; text = ""; prog = ""; pmax = ""; next }
        /android\.progressMax=/ && key != "" { t = $0; sub(/.*\(/, "", t); sub(/\).*/, "", t); pmax = t }
        /android\.progress=/    && key != "" { t = $0; sub(/.*\(/, "", t); sub(/\).*/, "", t); prog = t }
        /android\.title=/ && key != "" { t = $0; sub(/.*android\.title=[A-Za-z]* \(/, "", t); sub(/\)$/, "", t); title = t }
        /android\.text=/  && key != "" { t = $0; sub(/.*android\.text=[A-Za-z]* \(/, "", t); sub(/\)$/, "", t); text = t }
        function flush() { pct = ""; if (prog != "" && pmax + 0 > 0) pct = int(prog * 100 / pmax)
            if (key != "" && (title != "" || text != "")) printf "%s\t%s\t%s\t%s\t%s\t%s\n", key, pkg, flags, title, text, pct; key = "" }
        END { flush() }'
}
app_label() {       # a readable name from the package: com.whatsapp -> Whatsapp
    printf '%s' "${1##*.}" | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }'
}
sync_android_notifs() {
    local key pkg flags title text pct id seen="" fl old line ongoing
    while IFS="$(printf '\t')" read -r key pkg flags title text pct; do
        [ -n "$key" ] || continue
        case "$pkg" in com.termux|com.termux.api|com.termux.x11|com.android.shell|android|com.android.systemui) continue ;; esac
        # Android reports flags as names ("ONGOING_EVENT|ONLY_ALERT_ONCE|FOREGROUND_SERVICE"),
        # not a number; the old numeric test evaluated those names as empty variables and so
        # always came out 0. Both forms are handled now.
        ongoing=0
        case "$flags" in *ONGOING_EVENT*|*FOREGROUND_SERVICE*) ongoing=1 ;; esac
        case "$flags" in
            0x*|[0-9]*) fl=$(( flags )) 2>/dev/null || fl=0
                        [ $(( fl & 0x42 )) -eq 0 ] || ongoing=1 ;;
        esac
        # Ongoing / foreground-service ones are not messages, unless they carry a progress bar (downloads, uploads).
        [ "$ongoing" -eq 0 ] || [ -n "$pct" ] || continue
        seen="$seen$key
"
        old="$(grep "^$key	" "$NOTIF_MAP" 2>/dev/null | head -n1)"
        if [ -z "$old" ]; then
            id="$(plasma_notify "$(app_label "$pkg")" "${title:-$(app_label "$pkg")}" "$text" "$pct")"
            [ -n "$id" ] && printf '%s\t%s\t%s\n' "$key" "$id" "$pct" >> "$NOTIF_MAP"
        elif [ -n "$pct" ] && [ "$pct" != "$(printf '%s' "$old" | cut -f3)" ]; then
            id="$(printf '%s' "$old" | cut -f2)"        # progress moved: update the same Plasma notification
            plasma_notify "$(app_label "$pkg")" "${title:-$(app_label "$pkg")}" "$text" "$pct" "$id" >/dev/null
            sed -i "s/^$(printf '%s' "$key" | sed 's/[|]/\\|/g')	.*/$(printf '%s\t%s\t%s' "$key" "$id" "$pct")/" "$NOTIF_MAP" 2>/dev/null || true
        fi
    done <<< "$(android_shade)"
    # dismissed on Android -> closed in Plasma
    while IFS="$(printf '\t')" read -r key id pct; do
        [ -n "$key" ] || continue
        case "$seen" in *"$key
"*) printf '%s\t%s\t%s\n' "$key" "$id" "$pct" ;; *) plasma_close "$id" ;; esac
    done < "$NOTIF_MAP" > "$NOTIF_MAP.new" && mv -f "$NOTIF_MAP.new" "$NOTIF_MAP"
}

status_watch() {
    set +e; trap - ERR
    local n=0
    while :; do
        handle_android_cmd
        if [ $(( n % 30 )) -eq 0 ]; then collect_status; else quick_status; fi
        if [ "$NOTIFY_FORWARD" = 1 ] && [ $(( n % 6 )) -eq 0 ]; then sync_android_notifs; fi
        n=$(( n + 1 ))
        sleep 0.5
    done
}
status_watch &
STATUS_WATCH_PID=$!

# ---------- extra package sources (backports, testing pinned low, Mozilla, VS Code, Brave) ----------
if [ -f "$TERMUX_HOME/titan_repos.sh" ] && ! cmp -s "$TERMUX_HOME/titan_repos.sh" "$CHROOT_DIR/usr/local/bin/titan-repos"; then
    install -m 755 "$TERMUX_HOME/titan_repos.sh" "$CHROOT_DIR/usr/local/bin/titan-repos"
fi
if [ "${REPOS:-1}" = 1 ] && [ -x "$CHROOT_DIR/usr/local/bin/titan-repos" ] && ! run_in_chroot 'titan-repos --check'; then
    info "Adding extra package sources in the background (one time). Log: $CHROOT_DIR/var/log/titan-repos.log"
    chroot "$CHROOT_DIR" /usr/bin/env -i HOME=/root LANG=C.UTF-8 PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        /usr/local/bin/titan-repos > "$CHROOT_DIR/var/log/titan-repos.log" 2>&1 &
fi

# ---------- x86 / Windows programs: binfmt (host) + Box64/Box86/Wine (chroot) ----------
# binfmt_misc lets the kernel hand x86 and x86-64 ELF files (and .exe) to Box86/Box64/
# Wine automatically, so they simply run. Registered with the F flag, which opens the
# interpreter now so it keeps working inside the chroot.
setup_binfmt() {
    local d=/proc/sys/fs/binfmt_misc
    [ -f "$d/register" ] || mount -t binfmt_misc binfmt_misc "$d" 2>/dev/null
    if [ ! -f "$d/register" ]; then
        warn "This kernel has no binfmt_misc: x86 programs need 'box64 prog' / 'wine prog.exe' typed out."
        return 0
    fi
    [ -x "$CHROOT_DIR/usr/bin/box64" ] && [ ! -f "$d/titan-box64" ] && printf '%s' \
        ':titan-box64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:'"$CHROOT_DIR"'/usr/bin/box64:POCF' \
        > "$d/register" 2>/dev/null || true
    [ -x "$CHROOT_DIR/usr/bin/box86" ] && [ ! -f "$d/titan-box86" ] && printf '%s' \
        ':titan-box86:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:'"$CHROOT_DIR"'/usr/bin/box86:POCF' \
        > "$d/register" 2>/dev/null || true
    [ -x "$CHROOT_DIR/usr/local/bin/wine-run" ] && [ ! -f "$d/titan-wine" ] && printf '%s' \
        ':titan-wine:M::MZ::'"$CHROOT_DIR"'/usr/local/bin/wine-run:POCF' \
        > "$d/register" 2>/dev/null || true
    if ls "$d" 2>/dev/null | grep -q titan-; then
        info "binfmt: $(ls "$d" | grep titan- | tr '\n' ' ')"
    else
        info "binfmt: nothing registered yet (Box64/Wine not installed yet, or registration refused)"
    fi
    return 0
}
if [ -f "$TERMUX_HOME/titan_wine.sh" ] && ! cmp -s "$TERMUX_HOME/titan_wine.sh" "$CHROOT_DIR/usr/local/bin/titan-setup-wine"; then
    install -m 755 "$TERMUX_HOME/titan_wine.sh" "$CHROOT_DIR/usr/local/bin/titan-setup-wine"
fi
WINE_ARGS=""
[ "${WINE_RESET:-0}" = 1 ] && WINE_ARGS="--reset" && info "Wine prefix will be recreated."
[ "${WINE_REDO:-0}" = 1 ] && WINE_ARGS="--force" && info "Wine setup will be redone."
if [ "${WINE:-1}" = 1 ] && [ -x "$CHROOT_DIR/usr/local/bin/titan-setup-wine" ] \
   && { [ -n "$WINE_ARGS" ] || ! run_in_chroot 'titan-setup-wine --check'; }; then
    info "Setting up Box64/Box86 + Wine in the background. Log: $CHROOT_DIR/var/log/titan-wine.log"
    chroot "$CHROOT_DIR" /usr/bin/env -i HOME=/root LANG=C.UTF-8 \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        /usr/local/bin/titan-setup-wine $WINE_ARGS >/dev/null 2>&1 &
fi
setup_binfmt

# ---------- input bridge ----------
BRIDGE="$CHROOT_DIR/usr/local/bin/titan_input_bridge.py"
if [ -f "$BRIDGE" ]; then
    [ -e /dev/uinput ] || warn "/dev/uinput missing on host; bridge cannot create a virtual keyboard."
    chroot "$CHROOT_DIR" /usr/bin/python3 -u /usr/local/bin/titan_input_bridge.py \
        > "$CHROOT_DIR/tmp/titan_input_bridge.log" 2>&1 &
    info "Input bridge started (log: $CHROOT_DIR/tmp/titan_input_bridge.log)"
fi

# ---------- GPU acceleration: Termux's virgl server (Mali via Android's OpenGL ES) ----------
# Linux programs use Mesa's "virpipe" driver, which forwards OpenGL to a server
# running as the Termux user with access to the phone's GPU. Without the server
# (not installed, or it fails to start) everything falls back to the CPU renderer.
#   pkg install virglrenderer-android
GL_LINES="export GALLIUM_DRIVER=llvmpipe"
VIRGL="$TERMUX_PREFIX/bin/virgl_test_server_android"
pkill -9 -f virgl_test_server 2>/dev/null || true
if [ "${GPU:-1}" != 0 ] && [ -x "$VIRGL" ]; then
    VIRGL_ARGS=""; [ "${GPU:-1}" = angle ] && VIRGL_ARGS="--angle-gl"
    # The server puts its socket in Termux's own tmp directory; that directory is
    # bind-mounted into the chroot as /tmp/termux and Mesa is told where the socket is.
    mkdir -p "$CHROOT_DIR/tmp/termux" && mount --bind "$TERMUX_PREFIX/tmp" "$CHROOT_DIR/tmp/termux" 2>/dev/null || true
    rm -f "$TERMUX_PREFIX/tmp/.virgl_test"
    su "$TERMUX_UID" -c "env HOME=$TERMUX_HOME TMPDIR=$TERMUX_PREFIX/tmp $VIRGL $VIRGL_ARGS" >"$TERMUX_HOME/virgl.log" 2>&1 &
    for _ in $(seq 1 100); do [ -S "$TERMUX_PREFIX/tmp/.virgl_test" ] && break; sleep 0.1; done
    if [ -S "$TERMUX_PREFIX/tmp/.virgl_test" ]; then
        chmod 777 "$TERMUX_PREFIX/tmp/.virgl_test" "$TERMUX_PREFIX/tmp" 2>/dev/null || true
        GL_LINES="export GALLIUM_DRIVER=virpipe VTEST_SOCKET_NAME=/tmp/termux/.virgl_test MESA_GL_VERSION_OVERRIDE=4.3 MESA_GLSL_VERSION_OVERRIDE=430"
        info "GPU acceleration on (virgl${VIRGL_ARGS:+ $VIRGL_ARGS})."
        # The desktop itself (KWin's compositor, the Plasma shell, the splash and the
        # search launcher) stays on the CPU renderer: those and the virgl path do not
        # get on (lost compositing, flicker on window changes). Every application
        # started from the desktop uses the GPU. KWIN_GPU=1 puts KWin on the GPU too.
        for prog in kwin_x11 plasmashell ksplashqml krunner; do
            [ "$prog" = kwin_x11 ] && [ "${KWIN_GPU:-0}" = 1 ] && { rm -f "$CHROOT_DIR/usr/local/bin/$prog"; continue; }
            printf '%s\n' '#!/bin/sh' "# $prog on the CPU renderer while the session uses the GPU (see boot_desktop.sh)." \
                'export GALLIUM_DRIVER=llvmpipe; unset VTEST_SOCKET_NAME' "exec /usr/bin/$prog \"\$@\"" > "$CHROOT_DIR/usr/local/bin/$prog"
            chmod 755 "$CHROOT_DIR/usr/local/bin/$prog"
        done
    else
        warn "virgl server did not start (see ~/virgl.log); using the CPU renderer."
    fi
elif [ "${GPU:-1}" != 0 ]; then
    info "No GPU acceleration: install it with  pkg install virglrenderer-android  (Termux)."
fi
[ "$GL_LINES" = "export GALLIUM_DRIVER=llvmpipe" ] && rm -f "$CHROOT_DIR/usr/local/bin/kwin_x11" "$CHROOT_DIR/usr/local/bin/plasmashell" "$CHROOT_DIR/usr/local/bin/ksplashqml" "$CHROOT_DIR/usr/local/bin/krunner"

# ---------- Termux:Widget shortcuts ----------
# Two entries for the Termux:Widget app (tasks run in the background, no terminal):
#   "Debian"      starts the desktop
#   "Stop Debian" ends a running session cleanly
SC="$TERMUX_HOME/.shortcuts/tasks"
# Earlier versions called these "Linux desktop" / "Stop Linux desktop". Rename in place
# so the task is not duplicated; a home-screen widget pointing at the old name has to be
# re-added, since Termux:Widget identifies a task by its file name.
if [ -f "$SC/Linux desktop" ] && [ ! -f "$SC/Debian" ]; then
    mv -f "$SC/Linux desktop" "$SC/Debian" 2>/dev/null || true
    info "Renamed the Termux:Widget task 'Linux desktop' to 'Debian'; re-add the widget to your home screen."
fi
if [ -f "$SC/Stop Linux desktop" ] && [ ! -f "$SC/Stop Debian" ]; then
    mv -f "$SC/Stop Linux desktop" "$SC/Stop Debian" 2>/dev/null || true
fi
if [ ! -f "$SC/Debian" ]; then
    mkdir -p "$SC"
    printf '%s\n' '#!/data/data/com.termux/files/usr/bin/bash' '# Termux:Widget task: start the Debian desktop (output in ~/boot_desktop.log)' \
        'exec bash "$HOME/boot_desktop.sh" </dev/null' > "$SC/Debian"
    printf '%s\n' '#!/data/data/com.termux/files/usr/bin/bash' '# Termux:Widget task: end the running desktop session cleanly' \
        'su -c "touch /data/adb/debian/tmp/titan_quit" 2>/dev/null' > "$SC/Stop Debian"
    chmod 700 "$SC" "$SC/Debian" "$SC/Stop Debian"
    chown -R "$TERMUX_UID:$TERMUX_UID" "$TERMUX_HOME/.shortcuts"
    info "Termux:Widget tasks created (~/.shortcuts/tasks): 'Debian' and 'Stop Debian'."
fi

# ---------- desktop profile inside chroot ----------
# Font smoothing defaults: written only if missing, because KDE's own font
# settings save to this same file.
mkdir -p "$UHOME/.config/fontconfig"
if [ ! -f "$UHOME/.config/fontconfig/fonts.conf" ]; then
    printf '%s\n' \
        '<?xml version="1.0"?>' \
        '<!DOCTYPE fontconfig SYSTEM "fonts.dtd">' \
        '<fontconfig>' \
        '  <match target="font">' \
        '    <edit mode="assign" name="rgba"><const>rgb</const></edit>' \
        '    <edit mode="assign" name="hinting"><bool>true</bool></edit>' \
        '    <edit mode="assign" name="hintstyle"><const>hintslight</const></edit>' \
        '    <edit mode="assign" name="antialias"><bool>true</bool></edit>' \
        '    <edit mode="assign" name="lcdfilter"><const>lcddefault</const></edit>' \
        '  </match>' \
        '</fontconfig>' \
        > "$UHOME/.config/fontconfig/fonts.conf"
fi

# FAST_UI=1 (default): Plasma draws its panels with Qt's CPU renderer instead of
# emulated OpenGL (llvmpipe), which is usually quicker on a phone.
# Run with FAST_UI=0 if anything draws wrongly.
QUICK_LINE=': # FAST_UI off'
[ "${FAST_UI:-1}" = 1 ] && QUICK_LINE='export QT_QUICK_BACKEND=software QSG_RENDER_LOOP=basic'
# Compositing: KWin draws through OpenGL (llvmpipe). COMPOSITING=0 switches it off.
COMPOSE_LINE=': # compositing on'
[ "$COMPOSITING" = 1 ] || COMPOSE_LINE='export KWIN_COMPOSE=N'

# UI scale for a 401-PPI 4" screen (DISPLAY_SCALE, default 2). GTK only scales by
# whole numbers, so the remainder goes into its font DPI.
GDK_INT="$(awk -v s="$DISPLAY_SCALE" 'BEGIN { i = int(s); if (i < 1) i = 1; print i }')"
GDK_DPI="$(awk -v s="$DISPLAY_SCALE" -v i="$GDK_INT" 'BEGIN { printf "%.3f", s / i }')"
CURSOR_PX="$(awk -v s="$DISPLAY_SCALE" 'BEGIN { printf "%d", 24 * s + 0.5 }')"

# RESET_PANEL=1: forget your panel edits and re-apply the Titan layout this boot.
if [ "${RESET_PANEL:-0}" = 1 ]; then
    rm -f "$UHOME/.config/.titan_panel_applied"
    touch "$CHROOT_DIR/tmp/titan_panel_rebuild" && chmod 666 "$CHROOT_DIR/tmp/titan_panel_rebuild"
    # Plasma Drawer keeps its own app layout; one saved while the menu was missing stays
    # empty for good. A panel reset starts it fresh from the current menu.
    find "$UHOME/.config" "$UHOME/.local/share" -maxdepth 1 -iname '*plasma-drawer*' -exec rm -rf {} + 2>/dev/null || true
    info "Panel will be rebuilt from scratch (pinned items reset; launcher layout reset)."
fi

# Keymap loads once Plasma is up (Plasma may apply its own layout at startup).
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Titan keymap' \
    'Exec=/bin/sh -c "sleep 4; /usr/local/bin/titan-keymap"' 'NoDisplay=true' \
    > "$UHOME/.config/autostart/titan-keymap.desktop"

# Linux -> Android notifications. The chroot side queues every Plasma notification;
# the watcher below posts them as Android notifications. Plasma is put in
# Do Not Disturb so they don't show twice. NOTIFY_FORWARD=0 turns it off.
NOTIFY_QUEUE="$CHROOT_DIR/tmp/titan_notify.queue"
: > "$NOTIFY_QUEUE"; chmod 666 "$NOTIFY_QUEUE"
# Plasma shows its notifications as normal (no Do Not Disturb); the bridge still
# copies them, silently, into the Android shade. NOTIFY_FORWARD=0 stops the copy.
chroot "$CHROOT_DIR" /bin/su - "$CHROOT_USER" -c '
    K=$(command -v kwriteconfig6 || command -v kwriteconfig5) || exit 0
    $K --file plasmanotifyrc --group DoNotDisturb --key Until --delete' 2>/dev/null || true
if [ "$NOTIFY_FORWARD" = 1 ] && [ -f "$CHROOT_DIR/usr/local/bin/titan_notify_bridge.py" ]; then
    printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Titan notifications to Android' \
        'Exec=/usr/bin/python3 /usr/local/bin/titan_notify_bridge.py' 'NoDisplay=true' \
        > "$UHOME/.config/autostart/titan-notify.desktop"
else
    rm -f "$UHOME/.config/autostart/titan-notify.desktop"
fi

# Safe-area helper (camera band + rounded corners) starts with the Plasma session.
mkdir -p "$UHOME/.config/autostart"
if [ -f "$CHROOT_DIR/usr/local/bin/titan_display.py" ]; then
    printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Titan safe area' \
        'Exec=/usr/bin/python3 /usr/local/bin/titan_display.py' 'NoDisplay=true' \
        > "$UHOME/.config/autostart/titan-display.desktop"
fi
printf '%s\n' \
    'export LANG=en_US.UTF-8' \
    'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    'export DISPLAY=:0' \
    'export PULSE_SERVER=tcp:127.0.0.1:4713' \
    'export XDG_RUNTIME_DIR="/tmp/runtime-$USER"' \
    'export XDG_SESSION_TYPE=x11' \
    'export QT_QPA_PLATFORM=xcb' \
    'export LIBGL_ALWAYS_SOFTWARE=1' \
    "$GL_LINES" \
    'export MESA_NO_ERROR=1' \
    'export QT_LOGGING_RULES="kpipewire_logging=false;kf.kirigami.platform.warning=false"' \
    "$COMPOSE_LINE" \
    "export QT_SCALE_FACTOR=$DISPLAY_SCALE" \
    "export GDK_SCALE=$GDK_INT" \
    "export GDK_DPI_SCALE=$GDK_DPI" \
    'export GTK_CSD=0' \
    '# Firefox: take wheel events the classic way; the touch bridge scrolls with wheel clicks.' \
    'export MOZ_USE_XINPUT2=0' \
    "export XCURSOR_SIZE=$CURSOR_PX" \
    "$QUICK_LINE" \
    'mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"' \
    '# Plasma chatter goes to its own log (see ~/.cache/titan-session.log inside the chroot).' \
    'mkdir -p ~/.cache; exec dbus-run-session bash ~/.desktop_session_launch.sh > ~/.cache/titan-session.log 2>&1' \
    > "$UHOME/.desktop_profile"
# ---------- session launcher ----------
# LATE_COMPOSITING=1: start KWin ourselves, composited, while the screen is still
# blank - before startplasma-x11 exists to show the splash. The compositor then
# never initialises on top of something already drawn (that is the black flash).
#
# The catch found the first time round: startplasma-x11 starts its own kwin_x11,
# which replaces ours mid-splash and produces exactly the flash we were avoiding
# (the log showed two KWin inits with a GL context teardown between them). KDEWM
# is Plasma's documented override for "which window manager to run"; pointing it
# at titan-wm below makes plasma stand down when our KWin is already up.
#
# If KDEWM is ignored by this Plasma build, titan-wm just execs kwin_x11 as usual:
# behaviour falls back to what it does today, no worse. LATE_COMPOSITING=0 skips
# all of this and launches plasma exactly as before.
printf '%s\n' '#!/bin/sh' \
    '# Stand in for the window manager when the session launcher already started one.' \
    '# Plasma runs this as $KDEWM; staying alive tells plasma-session the WM is running.' \
    'p=$(cat /tmp/titan_kwin.pid 2>/dev/null)' \
    'if [ -n "$p" ] && [ -d "/proc/$p" ]; then' \
    '    exec tail -f /dev/null' \
    'fi' \
    'exec kwin_x11 "$@"' \
    > "$CHROOT_DIR/usr/local/bin/titan-wm"
chmod 755 "$CHROOT_DIR/usr/local/bin/titan-wm"
if [ "$LATE_COMPOSITING" = 1 ] && [ "$COMPOSITING" = 1 ]; then
    printf '%s\n' '#!/bin/sh' \
        '# Titan: KWin first, on a blank screen, then the rest of the session.' \
        'rm -f /tmp/titan_kwin.pid' \
        'kwin_x11 &' \
        'echo $! > /tmp/titan_kwin.pid' \
        '# Wait (up to 15s) for the compositor to report itself active.' \
        'i=0' \
        'while [ "$i" -lt 150 ]; do' \
        '    dbus-send --session --print-reply --dest=org.kde.KWin /Compositor \' \
        '        org.freedesktop.DBus.Properties.Get string:org.kde.kwin.Compositing string:active 2>/dev/null \' \
        '        | grep -q "boolean true" && break' \
        '    i=$((i + 1))' \
        '    sleep 0.1' \
        'done' \
        'KDEWM=/usr/local/bin/titan-wm; export KDEWM' \
        'exec startplasma-x11' \
        > "$UHOME/.desktop_session_launch.sh"
else
    printf '%s\n' '#!/bin/sh' 'exec startplasma-x11' > "$UHOME/.desktop_session_launch.sh"
fi
chmod 755 "$UHOME/.desktop_session_launch.sh"
chown -R 1000:1000 "$UHOME/.config" "$UHOME/.desktop_profile" "$UHOME/.desktop_session_launch.sh"

# ---------- "Phone status" panel widget: battery, Wi-Fi, signal, notifications ----------
# A tiny Plasma widget (written fresh each boot) that shows what status_watch below
# reads from Android every 15 s into /tmp/titan_status.
PW="$UHOME/.local/share/plasma/plasmoids/org.titan.phonestatus"
mkdir -p "$PW/contents/ui"
printf '%s\n' \
    '{' \
    '    "KPackageStructure": "Plasma/Applet",' \
    '    "KPlugin": {' \
    '        "Id": "org.titan.phonestatus",' \
    '        "Name": "Phone status",' \
    '        "Description": "Battery, Wi-Fi, mobile signal and Android notifications",' \
    '        "Icon": "phone",' \
    '        "Category": "System Information",' \
    '        "Version": "1.0",' \
    '        "Authors": [{ "Name": "Titan 2 Elite chroot" }]' \
    '    },' \
    '    "X-Plasma-API-Minimum-Version": "6.0"' \
    '}' \
    > "$PW/metadata.json"
if [ -f "$TERMUX_HOME/titan_phonestatus.qml" ]; then
    install -m 644 "$TERMUX_HOME/titan_phonestatus.qml" "$PW/contents/ui/main.qml"
else
    warn "titan_phonestatus.qml missing from the Termux home; the phone widget will be empty."
fi
rm -rf "$UHOME/.local/share/plasma/plasmoids/org.titan.session"
# The widget's way of asking Android for things: one tab-separated line per request.
printf '%s\n' '#!/bin/sh' '# titan-android <command> [args...] -> boot_desktop.sh performs it on the Android side.' \
    'f=/tmp/titan_android_cmd' 'd=/tmp/titan_widget_debug.log' \
    'printf "%s called: %s\\n" "$(date +%H:%M:%S)" "$*" >> "$d" 2>/dev/null; chmod 666 "$d" 2>/dev/null' \
    'printf "%s\\t" "$@" >> "$f"; printf "\\n" >> "$f"; chmod 666 "$f" 2>/dev/null; exit 0' \
    > "$CHROOT_DIR/usr/local/bin/titan-android"
chmod 755 "$CHROOT_DIR/usr/local/bin/titan-android"
: > "$CHROOT_DIR/tmp/titan_android_cmd"; chmod 666 "$CHROOT_DIR/tmp/titan_android_cmd"
chown -R 1000:1000 "$UHOME/.local"

# ---------- guaranteed logout ----------
# Plasma runs these scripts when you log out. The marker tells the boot script
# (which has root, outside the chroot) to end the whole session at once; it also
# covers the case where Plasma's own logout leaves things running.
mkdir -p "$UHOME/.config/plasma-workspace/shutdown"
printf '%s\n' '#!/bin/sh' 'touch /tmp/titan_logout' > "$UHOME/.config/plasma-workspace/shutdown/00-titan.sh"
chmod 755 "$UHOME/.config/plasma-workspace/shutdown/00-titan.sh"
mkdir -p "$UHOME/.local/share/applications"
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Log out (end session)' 'Icon=system-log-out' \
    'Exec=/bin/sh -c "qdbus6 org.kde.Shutdown /Shutdown logout 2>/dev/null || qdbus org.kde.Shutdown /Shutdown logout 2>/dev/null; sleep 5; touch /tmp/titan_logout"' \
    'Categories=System;' > "$UHOME/.local/share/applications/titan-logout.desktop"
chown -R 1000:1000 "$UHOME/.config/plasma-workspace" "$UHOME/.local/share/applications"
rm -f "$CHROOT_DIR/tmp/titan_logout"

# ---------- "Reset Titan settings" in the app launcher ----------
# A menu for the reset switches that otherwise need a command line (RESET_PANEL=1 and
# friends). It does not touch anything itself: it asks boot_desktop.sh over the same
# titan-android channel the phone widget uses, because the stamps and the add-on build
# live outside the chroot user's reach.
# kdialog opens tiny by default and clips the labels on a phone screen, so it is given
# an explicit size: most of the screen width and about two thirds of its height, in
# logical px (Qt multiplies by QT_SCALE_FACTOR).
DLG_W="$(awk -v w="${SCREEN_W:-1080}" -v s="$DISPLAY_SCALE" 'BEGIN { printf "%d", (w / s) * 0.94 }')"
DLG_H="$(awk -v h="${SCREEN_H:-1200}" -v s="$DISPLAY_SCALE" 'BEGIN { printf "%d", (h / s) * 0.62 }')"
# Centred horizontally, and pushed below the camera band so the title bar is not under
# the cutout (TOP_INSET is the band height in physical px).
DLG_X="$(awk -v w="${SCREEN_W:-1080}" -v s="$DISPLAY_SCALE" -v d="$DLG_W" 'BEGIN { x = (w / s - d) / 2; if (x < 0) x = 0; printf "%d", x }')"
DLG_Y="$(awk -v i="${TOP_INSET:-100}" -v s="$DISPLAY_SCALE" 'BEGIN { printf "%d", i / s + 24 }')"
printf '%s\n' '#!/bin/sh' \
    '# titan-reset [panel|windows|tuning|display|addons|session ...]' \
    '# With no arguments, asks with kdialog; any number can be ticked.' \
    "G=${DLG_W}x${DLG_H}+${DLG_X}+${DLG_Y}" \
    'sel="$*"' \
    'if [ -z "$sel" ]; then' \
    '    if ! command -v kdialog >/dev/null 2>&1; then' \
    '        echo "kdialog is not installed. Usage: titan-reset panel|windows|tuning|display|addons|session ..." >&2' \
    '        exit 1' \
    '    fi' \
    '    sel="$(kdialog --geometry "$G" --title "Reset Titan settings" --checklist "What should be reset?" \' \
    '        panel   "Panel layout (now)" off \' \
    '        windows "Window look and buttons (now)" off \' \
    '        tuning  "KDE touch tuning (next start)" off \' \
    '        display "Re-detect screen cutout (next start)" off \' \
    '        addons  "Rebuild Klassy add-ons (slow)" off \' \
    '        session "Restart Plasma session" off 2>/dev/null)" || exit 0' \
    'fi' \
    '# kdialog returns the ticked tags space separated and quoted.' \
    'sel="$(printf "%s" "$sel" | tr -d "\"" )"' \
    '[ -n "$sel" ] || exit 0' \
    'rest=""; want_session=""' \
    'for w in $sel; do' \
    '    case "$w" in' \
    '        session) want_session=1 ;;' \
    '        panel|windows|tuning|display|addons) rest="$rest $w" ;;' \
    '        *) echo "unknown reset: $w" >&2; exit 1 ;;' \
    '    esac' \
    'done' \
    '# Everything else is requested first: a session restart would otherwise cut the' \
    '# remaining requests off before boot_desktop.sh had read them.' \
    'for w in $rest; do /usr/local/bin/titan-android reset "$w"; done' \
    'if command -v kdialog >/dev/null 2>&1 && [ -n "$rest" ]; then' \
    '    kdialog --title "Reset Titan settings" --passivepopup "Requested:$rest" 6 >/dev/null 2>&1 &' \
    'fi' \
    'if [ -n "$want_session" ]; then' \
    '    [ -n "$rest" ] && sleep 2' \
    '    /usr/local/bin/titan-android reset session' \
    'fi' \
    'exit 0' \
    > "$CHROOT_DIR/usr/local/bin/titan-reset"
chmod 755 "$CHROOT_DIR/usr/local/bin/titan-reset"
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Reset Titan settings' \
    'Comment=Panel layout, window look, touch tuning, screen detection, add-ons' \
    'Exec=/usr/local/bin/titan-reset' 'Icon=view-refresh' 'Categories=System;Settings;' \
    > "$UHOME/.local/share/applications/titan-reset.desktop"

# "Close desktop" in the app launcher: ends the whole session cleanly from inside.
mkdir -p "$UHOME/.local/share/applications"
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Close desktop' 'Comment=Log out and shut the chroot down' \
    'Exec=/bin/sh -c "touch /tmp/titan_quit"' 'Icon=system-log-out' 'Categories=System;' \
    > "$UHOME/.local/share/applications/titan-close.desktop"

# ---------- splash screen (Plasma's default Breeze; compositing starts behind it) ----------
rm -rf "$UHOME/.local/share/plasma/look-and-feel/org.titan.splash"
if [ "$SPLASH" = 1 ]; then
    chroot "$CHROOT_DIR" /bin/su - "$CHROOT_USER" -c '
        K=$(command -v kwriteconfig6 || command -v kwriteconfig5) || exit 0
        $K --file ksplashrc --group KSplash --key Engine KSplashQML
        $K --file ksplashrc --group KSplash --key Theme org.kde.breeze.desktop' 2>/dev/null || true
else
    chroot "$CHROOT_DIR" /bin/su - "$CHROOT_USER" -c '
        K=$(command -v kwriteconfig6 || command -v kwriteconfig5) || exit 0
        $K --file ksplashrc --group KSplash --key Engine none
        $K --file ksplashrc --group KSplash --key Theme None' 2>/dev/null || true
fi

# Plasma Drawer (and other freedesktop launchers) need /etc/xdg/menus/applications.menu.
# Debian's Plasma ships only plasma-applications.menu: link to it, or write a standard
# menu if that is missing too. Then rebuild KDE's application database once.
mkdir -p "$CHROOT_DIR/etc/xdg/menus"
if [ ! -s "$CHROOT_DIR/etc/xdg/menus/applications.menu" ]; then
    rm -f "$CHROOT_DIR/etc/xdg/menus/applications.menu"
    if [ -f "$CHROOT_DIR/etc/xdg/menus/plasma-applications.menu" ]; then
        ln -s plasma-applications.menu "$CHROOT_DIR/etc/xdg/menus/applications.menu"
    else
printf '%s\n' \
        '<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN" "http://www.freedesktop.org/standards/menu-spec/1.0/menu.dtd">' \
        '<Menu>' \
        '  <Name>Applications</Name>' \
        '  <Directory>kde-main.directory</Directory>' \
        '  <DefaultAppDirs/>' \
        '  <DefaultDirectoryDirs/>' \
        '  <DefaultMergeDirs/>' \
        '  <Include><Category>Core</Category></Include>' \
        '  <Menu><Name>Development</Name><Directory>kde-development.directory</Directory><Include><Category>Development</Category></Include></Menu>' \
        '  <Menu><Name>Education</Name><Directory>kde-education.directory</Directory><Include><Category>Education</Category></Include></Menu>' \
        '  <Menu><Name>Games</Name><Directory>kde-games.directory</Directory><Include><Category>Game</Category></Include></Menu>' \
        '  <Menu><Name>Graphics</Name><Directory>kde-graphics.directory</Directory><Include><Category>Graphics</Category></Include></Menu>' \
        '  <Menu><Name>Internet</Name><Directory>kde-internet.directory</Directory><Include><Category>Network</Category></Include></Menu>' \
        '  <Menu><Name>Multimedia</Name><Directory>kde-multimedia.directory</Directory><Include><Or><Category>AudioVideo</Category><Category>Audio</Category><Category>Video</Category></Or></Include></Menu>' \
        '  <Menu><Name>Office</Name><Directory>kde-office.directory</Directory><Include><Category>Office</Category></Include></Menu>' \
        '  <Menu><Name>Science</Name><Directory>kde-science.directory</Directory><Include><Category>Science</Category></Include></Menu>' \
        '  <Menu><Name>Settings</Name><Directory>kde-settingsmenu.directory</Directory><Include><Category>Settings</Category></Include></Menu>' \
        '  <Menu><Name>System</Name><Directory>kde-system.directory</Directory><Include><Category>System</Category></Include></Menu>' \
        '  <Menu><Name>Utilities</Name><Directory>kde-utilities.directory</Directory><Include><Category>Utility</Category></Include></Menu>' \
        '  <Menu><Name>Lost &amp; Found</Name><Directory>kde-unknown.directory</Directory><OnlyUnallocated/><Include><All/></Include></Menu>' \
        '</Menu>' \
        > "$CHROOT_DIR/etc/xdg/menus/applications.menu"
    fi
    info "Created applications.menu."
fi
# Rebuild KDE's application database before Plasma starts (about a second); a stale
# one is what leaves launchers empty after menu or package changes.
chroot "$CHROOT_DIR" /bin/su - "$CHROOT_USER" -c 'kbuildsycoca6 --noincremental >/dev/null 2>&1' || true
# ---------- Plasma Drawer (LAUNCHER=drawer): a maintained Launchpad-style full-screen grid ----------
printf '%s\n' '#!/bin/sh' \
    '# Install Plasma Drawer (phone-style launcher) for the current user. Log: /tmp/titan_drawer.log' \
    'set -e; exec >/tmp/titan_drawer.log 2>&1; cd /tmp' \
    'dest="$HOME/.local/share/plasma/plasmoids/p-connor.plasma-drawer"' \
    '[ -d "$dest" ] && { echo "already installed"; exit 0; }' \
    'url="$(curl -fsSL https://api.github.com/repos/p-connor/plasma-drawer/releases/latest 2>/dev/null | grep -o "https://[^\"]*\.plasmoid" | head -n1)"' \
    'if [ -z "$url" ]; then   # API blocked/rate-limited: read the release page instead' \
    '    url="$(curl -fsSL https://github.com/p-connor/plasma-drawer/releases/latest 2>/dev/null | grep -o "/p-connor/plasma-drawer/releases/download/[^\"]*\.plasmoid" | head -n1)"' \
    '    [ -n "$url" ] && url="https://github.com$url"' \
    'fi' \
    'if [ -z "$url" ]; then   # expanded assets page' \
    '    tag="$(curl -fsSIL https://github.com/p-connor/plasma-drawer/releases/latest 2>/dev/null | grep -io "^location: .*" | grep -o "[^/]*$" | tr -d "\r")"' \
    '    [ -n "$tag" ] && url="$(curl -fsSL "https://github.com/p-connor/plasma-drawer/releases/expanded_assets/$tag" 2>/dev/null | grep -o "/p-connor/plasma-drawer/releases/download/[^\"]*\.plasmoid" | head -n1)"' \
    '    [ -n "$url" ] && url="https://github.com$url"' \
    'fi' \
    '[ -n "$url" ] || { echo "could not find a .plasmoid download on GitHub"; exit 1; }' \
    'echo "downloading $url"; curl -fL -o drawer.plasmoid "$url"' \
    'if command -v kpackagetool6 >/dev/null 2>&1 && kpackagetool6 -t Plasma/Applet -i drawer.plasmoid; then echo "installed with kpackagetool6"' \
    'else' \
    '    echo "kpackagetool6 unavailable or failed; unpacking by hand"' \
    '    mkdir -p "$dest" && python3 -c "import zipfile,sys; zipfile.ZipFile(\"drawer.plasmoid\").extractall(sys.argv[1])" "$dest"' \
    '    [ -f "$dest/metadata.json" ] || { d=$(find "$dest" -maxdepth 2 -name metadata.json | head -n1); [ -n "$d" ] && cp -a "$(dirname "$d")/." "$dest/"; }' \
    '    [ -f "$dest/metadata.json" ] || { echo "unpack failed"; rm -rf "$dest"; exit 1; }' \
    'fi' \
    'rm -f drawer.plasmoid; echo "done"' \
    > "$CHROOT_DIR/usr/local/bin/titan-install-drawer"
chmod 755 "$CHROOT_DIR/usr/local/bin/titan-install-drawer"
info "Launcher setting: $LAUNCHER (Plasma Drawer installed: $([ -d "$UHOME/.local/share/plasma/plasmoids/p-connor.plasma-drawer" ] && echo yes || echo no))"
if [ "$LAUNCHER" = drawer ] && [ ! -d "$UHOME/.local/share/plasma/plasmoids/p-connor.plasma-drawer" ]; then
    info "Installing Plasma Drawer (one time)..."
    chroot "$CHROOT_DIR" /bin/su - "$CHROOT_USER" -c /usr/local/bin/titan-install-drawer \
        && info "Plasma Drawer installed." \
        || warn "Plasma Drawer install failed: $(tail -n1 "$CHROOT_DIR/tmp/titan_drawer.log" 2>/dev/null). Keeping the current launcher."
fi

# Kickoff needs no patching for a footer without the "Leave"/"More" button: with all
# actions primary (see titan_display.py) it never draws one. Drop any patched copy.
rm -rf "$UHOME/.local/share/plasma/plasmoids/org.kde.plasma.kickoff"

# ---------- KDE's "Lock Screen" = the phone's lock ----------
# Plasma's own lock screen would need password login inside the chroot (easy to get
# locked out). Its greeter is replaced by a stub that asks Android to lock the screen
# (fingerprint/PIN unlock) and returns at once, so KDE never actually locks.
GREET="$(find "$CHROOT_DIR/usr/libexec" "$CHROOT_DIR/usr/lib" -name kscreenlocker_greet -type f 2>/dev/null | head -n1)"
if [ -n "$GREET" ] && [ ! -f "$GREET.real" ]; then
    rel="${GREET#$CHROOT_DIR}"
    chroot "$CHROOT_DIR" /usr/bin/dpkg-divert --local --rename --divert "$rel.real" --add "$rel" >/dev/null 2>&1 \
        && printf '%s\n' '#!/bin/sh' '# Titan: lock via Android instead of KDE (real greeter: kscreenlocker_greet.real)' \
            '/usr/local/bin/titan-android lock' 'exit 0' > "$GREET" && chmod 755 "$GREET" \
        && info "KDE's Lock Screen now locks the phone (fingerprint unlock)."
fi

# ---------- apps that draw their own title bar (Firefox) ----------
# Klassy's margins don't reach those, so Firefox gets a userChrome rule that pads its
# tab bar when maximised: left of the camera hole, right of the rounded corner.
# GTK apps are told to use the KWin/Klassy title bar instead (GTK_CSD=0 above).
FF_SIDE="$(awk -v R="$CORNER_RADIUS" -v s="$DISPLAY_SCALE" 'BEGIN {
    y = R - 21; if (y < 0) y = 0; d = R*R - y*y; if (d < 0) d = 0; printf "%d", (R - sqrt(d)) / s + 3 }')"
FF_LEFT="$(awk -v h="$CUTOUT_RIGHT" -v s="$DISPLAY_SCALE" -v m="$FF_SIDE" 'BEGIN { c = int(h / s + 4); printf "%d", (c > m) ? c : m }')"
for ffdir in "$CHROOT_DIR/usr/lib/firefox-esr" "$CHROOT_DIR/usr/lib/firefox"; do
    [ -d "$ffdir" ] || continue
    mkdir -p "$ffdir/defaults/pref"
    printf '%s\n' '// Titan 2 Elite: allow userChrome.css (tab-bar insets for the notch and corners)' \
        'pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' \
        '// Touch scrolling arrives as wheel clicks: make each one move a decent amount, smoothly.' \
        'pref("mousewheel.default.delta_multiplier_y", 150);' \
        'pref("mousewheel.default.delta_multiplier_x", 150);' \
        'pref("general.smoothScroll", true);' \
        'pref("apz.gtk.kinetic_scroll.enabled", false);' \
        > "$ffdir/defaults/pref/titan.js"
done
# On a fresh chroot Firefox has never run, so there is no profile and the loop below
# matches nothing: the tab-bar margins would only appear after Firefox had been opened
# once AND boot_desktop.sh run again. Create the profile up front so they apply on the
# first launch. Firefox accepts a hand-written profiles.ini and fills in the rest.
if [ -d "$CHROOT_DIR/usr/lib/firefox-esr" ] || [ -d "$CHROOT_DIR/usr/lib/firefox" ]; then
    if [ ! -f "$UHOME/.mozilla/firefox/profiles.ini" ]; then
        mkdir -p "$UHOME/.mozilla/firefox/titan.default"
        printf '%s\n' '[Profile0]' 'Name=default' 'IsRelative=1' 'Path=titan.default' 'Default=1' \
            '' '[General]' 'StartWithLastProfile=1' > "$UHOME/.mozilla/firefox/profiles.ini"
        : > "$UHOME/.mozilla/firefox/titan.default/prefs.js"
        chown -R 1000:1000 "$UHOME/.mozilla"
        info "Created a Firefox profile so the tab-bar margins apply on first launch."
    fi
fi
for prof in "$UHOME"/.mozilla/firefox/*/; do
    # Any profile directory, not just one Firefox has already written prefs.js into:
    # on an existing install a profile can exist unpopulated, and the margins were then
    # skipped every boot with nothing said about it.
    [ -d "$prof" ] || continue
    case "${prof%/}" in *"Crash Reports"|*"Pending Pings") continue ;; esac
    mkdir -p "$prof/chrome"
    printf '%s\n' '/* Titan 2 Elite: written by boot_desktop.sh (edit chroot_common.sh margins, not this) */' \
        ":root[sizemode=\"maximized\"] #TabsToolbar { padding-left: ${FF_LEFT}px !important; padding-right: ${FF_SIDE}px !important; }" \
        > "$prof/chrome/userChrome.css"
    chown -R 1000:1000 "$prof/chrome"
done
chmod 4755 "$CHROOT_DIR/usr/bin/sudo" 2>/dev/null || true
tune_kde "$CHROOT_USER"
apply_compositing "$CHROOT_USER" "$COMPOSITING"
# Keep a copy of the display/desktop settings outside the chroot. install_chroot.sh
# wipes $CHROOT_DIR, so without this every remembered setting (panel height and
# hiding, corner padding, title buttons, window radius, reserved space, launcher...)
# would be lost on a reinstall and the desktop would come back with the defaults.
if ! cmp -s "$CHROOT_DIR$DISPLAY_CONF_REL" "$TERMUX_HOME/titan-display.conf"; then
    cp -f "$CHROOT_DIR$DISPLAY_CONF_REL" "$TERMUX_HOME/titan-display.conf" 2>/dev/null \
        && chown "$TERMUX_UID:$TERMUX_UID" "$TERMUX_HOME/titan-display.conf" 2>/dev/null \
        && info "Saved the desktop settings to ~/titan-display.conf (restored by install_chroot.sh)."
fi
# RESET_WINDOWS=1: forget your decoration/rounded-corner edits and re-apply the Titan look.
[ "${RESET_WINDOWS:-0}" = 1 ] && rm -f "$CHROOT_DIR/usr/local/share/titan-addons/configured" \
    && info "Window look will be re-applied."

# ---------- Klassy + rounded-corners effect (built once, in the background) ----------
# titan-build-addons decides for itself what is left to do: build (first time, or
# after a KWin upgrade), apply the window look (first time, or after WINDOW_RADIUS
# changes / RESET_WINDOWS=1), then reload KWin live.
if [ "$ADDONS" = 1 ] && [ -x "$CHROOT_DIR/usr/local/bin/titan-build-addons" ]; then
    ADDON_ARGS=""; todo=1
    if [ "${REBUILD_ADDONS:-0}" = 1 ]; then
        ADDON_ARGS="--force"
    else
        run_in_chroot 'titan-build-addons --check' && todo=0 || todo=$?
    fi
    if [ "$todo" = 3 ] || [ "$todo" = 2 ]; then
        if [ "$todo" = 3 ]; then
            warn "Saved Klassy/rounded-corners build is for a different KWin version. Not rebuilding by itself: REBUILD_ADDONS=1 ./boot_desktop.sh compiles once."
        else
            warn "Klassy/rounded-corners build failed last time; REBUILD_ADDONS=1 ./boot_desktop.sh retries. Log: $CHROOT_DIR/var/log/titan-addons.log"
        fi
        # The title buttons and titlebar margins are plain kdecoration settings that work
        # with any decoration, Breeze included. Apply them even when the build is unusable,
        # instead of leaving the window with no minimise/maximise/close buttons.
        chroot "$CHROOT_DIR" /usr/bin/env -i HOME=/root LANG=C.UTF-8 HOLD_KWIN="${HOLD_KWIN:-1}" TITLE_BUTTONS="$TITLE_BUTTONS" \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            /usr/local/bin/titan-build-addons --configure >/dev/null 2>&1 \
            && info "Applied the window look (title buttons and margins) without the add-on build." 
    elif [ "$todo" != 0 ]; then
        [ -f "$CHROOT_DIR/usr/local/share/titan-addons/installed" ] && [ -z "$ADDON_ARGS" ] \
            && info "Applying the window look in the background." \
            || info "Building Klassy + rounded corners in the background (20-40 min first time; keep the desktop open). Log: $CHROOT_DIR/var/log/titan-addons.log"
        chroot "$CHROOT_DIR" /usr/bin/env -i HOME=/root LANG=C.UTF-8 HOLD_KWIN="${HOLD_KWIN:-1}" TITLE_BUTTONS="$TITLE_BUTTONS" \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            /usr/local/bin/titan-build-addons $ADDON_ARGS >/dev/null 2>&1 &
    fi
fi

# ---------- wait for X ----------
for _ in $(seq 1 100); do
    [ -S "$CHROOT_DIR/tmp/.X11-unix/X0" ] && break
    sleep 0.1
done
[ -S "$CHROOT_DIR/tmp/.X11-unix/X0" ] || die "X server socket never appeared (check the log above)."
log "X server is up."
grep -hE 'ERROR|WARNING|Grabbed' "$CHROOT_DIR/tmp/titan_input_bridge.log" 2>/dev/null || true

# ---------- session ----------
log "Launching KDE Plasma as $CHROOT_USER (session log: $UHOME/.cache/titan-session.log)..."
chroot "$CHROOT_DIR" /bin/su - "$CHROOT_USER" -c "bash ~/.desktop_profile" &
SESSION_PID=$!
sleep 15
# Watchdog. The session is over when: the session process is gone (or a zombie: a
# killed background job stays one until reaped, so plain kill -0 lies), Plasma's
# shell has been gone for a few seconds, or a logout/close was requested from the
# desktop (Plasma's shutdown hook writes titan_logout, the launcher entry titan_quit).
session_alive() {
    [ -d "/proc/$SESSION_PID" ] || return 1
    [ "$(awk '{ print $3 }' "/proc/$SESSION_PID/stat" 2>/dev/null)" != Z ]
}
while session_alive; do
    # Restart requested from the desktop (titan-reset session). Only Plasma goes down:
    # the chroot stays mounted and X, the input bridge and the watchers keep running, so
    # none of the shutdown/cleanup sequence runs.
    if [ -f "$CHROOT_DIR/tmp/titan_restart" ]; then
        rm -f "$CHROOT_DIR/tmp/titan_restart"
        # Tells route_watch (and the checks below) that the logout marker Plasma is about
        # to write is ours, not the user asking to leave.
        touch "$CHROOT_DIR/tmp/titan_restarting"
        info "Restarting the Plasma session (chroot, X server and input bridge stay up)..."
        # Every one of these exits non-zero when there is nothing to kill (pkill returns 1
        # on no match, wait reports the job's own status), and under "set -e" that aborted
        # the script straight into the EXIT trap - i.e. the full shutdown this restart is
        # meant to avoid. None of them is an error worth stopping for.
        pkill -9 -x plasmashell 2>/dev/null || true
        pkill -9 -x kwin_x11 2>/dev/null || true
        pkill -9 -f '^startplasma-x11' 2>/dev/null || true
        pkill -9 -f '/usr/local/bin/titan-wm' 2>/dev/null || true
        rm -f "$CHROOT_DIR/tmp/titan_kwin.pid"
        kill -9 "$SESSION_PID" 2>/dev/null || true
        wait "$SESSION_PID" 2>/dev/null || true
        rm -f "$CHROOT_DIR/tmp/titan_logout" "$CHROOT_DIR/tmp/titan_quit"
        chroot "$CHROOT_DIR" /bin/su - "$CHROOT_USER" -c "bash ~/.desktop_profile" &
        SESSION_PID=$!
        sleep 15
        # Anything the old session's shutdown scripts wrote on their way out.
        rm -f "$CHROOT_DIR/tmp/titan_logout" "$CHROOT_DIR/tmp/titan_quit" "$CHROOT_DIR/tmp/titan_restarting"
        continue
    fi
    if [ -f "$CHROOT_DIR/tmp/titan_quit" ] || [ -f "$CHROOT_DIR/tmp/titan_logout" ]; then
        info "Logout requested from the desktop."; break
    fi
    if ! pgrep -x plasmashell >/dev/null 2>&1; then
        sleep 4
        pgrep -x plasmashell >/dev/null 2>&1 || { info "Plasma session ended (plasmashell gone)."; break; }
    fi
    sleep 2
done
rm -f "$CHROOT_DIR/tmp/titan_quit" "$CHROOT_DIR/tmp/titan_logout" "$CHROOT_DIR/tmp/titan_restart" "$CHROOT_DIR/tmp/titan_restarting"
kill "$SESSION_PID" 2>/dev/null || true
