#!/bin/sh
# Part of: Titan 2 Elite Debian Chroot - a full Debian/KDE desktop running
# alongside Android on a Unihertz Titan 2 Elite phone.
# Optional: sets up Wine and Box64 so Windows programs can run.
#
# New to this project? Read README.md first, it explains the whole setup:
# https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Debian-Chroot
#
# titan_wine.sh - x86 and Windows program support inside the Debian chroot
# (installed there as /usr/local/bin/titan-setup-wine and run once, in the
# background, by boot_desktop.sh).
#   * enables amd64, i386 and armhf packages next to arm64 (dpkg multiarch), so
#     "apt install foo:amd64" just works and the binaries run through Box64
#   * installs Box64 (x86-64 -> arm64) and Box86 (x86 -> arm32) from Debian, or from
#     the Box64/Box86 project's own apt repos if Debian has no build
#   * installs Debian's x86-64 and x86 Wine builds, wrappers so "wine prog.exe" works
#     with or without binfmt, and makes .exe files open with Wine from Dolphin
#   titan-setup-wine [--check|--force|--reset]
#     --check  exit 0 = done      --force  redo the whole setup
#     --reset  throw away the Wine prefix (~/.wine) and create a fresh one
set -u
STATE=/usr/local/share/titan-wine
LOGF=/var/log/titan-wine.log
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MODE="${1:-run}"
mkdir -p "$STATE"
VERSION=1
[ "$MODE" = --check ] && { [ "$(cat "$STATE/done" 2>/dev/null)" = "$VERSION" ] && exit 0 || exit 1; }
[ "$MODE" = --force ] && rm -f "$STATE/done"
if [ "$MODE" = --reset ]; then
    u="$(awk -F: '$3 == 1000 { print $1 }' /etc/passwd)"
    rm -rf "/home/$u/.wine" "/home/$u/.cache/wine" "/home/$u/.local/share/applications/wine"
    rm -f "$STATE/done"
fi
[ "$(cat "$STATE/done" 2>/dev/null)" = "$VERSION" ] && exit 0
exec >>"$LOGF" 2>&1
exec 9>"$STATE/lock"; flock -n 9 || exit 0
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
USER_NAME="$(awk -F: '$3 == 1000 { print $1 }' /etc/passwd)"
notify() {   # notify <title> <body> [percent]  best effort, via the running Plasma session
    local pid env hint=""; pid="$(pgrep -u "$USER_NAME" -x plasmashell 2>/dev/null | head -n1)"
    [ -n "$pid" ] && [ -r "/proc/$pid/environ" ] || return 0
    [ -n "${3:-}" ] && hint="-h int:value:$3"
    env="DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS='$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')'"
    su "$USER_NAME" -c "$env notify-send -a 'Titan Wine setup' -i wine -r 907002 -u low -t 0 $hint '$1' '$2'" >/dev/null 2>&1 || true
}
have() { dpkg-query -W -f '${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
avail() { apt-cache show "$1" >/dev/null 2>&1; }
log "---- titan-setup-wine ($MODE)"

# ----------------------------------------------------------------- multiarch
for a in amd64 i386 armhf; do dpkg --print-foreign-architectures | grep -qx "$a" || dpkg --add-architecture "$a"; done
notify "Wine setup" "Enabling x86, x86-64 and armhf packages..." 5
apt-get update -qq || { log "apt update failed"; exit 1; }

# ----------------------------------------------------------------- Box64 / Box86
notify "Wine setup" "Installing Box64 and Box86..." 20
if ! have box64; then
    if avail box64; then apt-get install -y -qq --no-install-recommends box64
    else
        log "Debian has no box64; using the Box64 project's apt repo"
        install -m 644 /dev/null /etc/apt/keyrings/box64.gpg 2>/dev/null || mkdir -p /etc/apt/keyrings
        curl -fsSL https://ryanfortner.github.io/box64-debs/KEY.gpg | gpg --dearmor -o /etc/apt/keyrings/box64.gpg
        echo "deb [signed-by=/etc/apt/keyrings/box64.gpg arch=arm64] https://ryanfortner.github.io/box64-debs/debian ./" > /etc/apt/sources.list.d/box64.list
        apt-get update -qq && apt-get install -y -qq --no-install-recommends box64-generic-arm
    fi
fi
if ! have box86:armhf && ! have box86; then
    if avail box86:armhf; then apt-get install -y -qq --no-install-recommends box86:armhf
    elif avail box86; then apt-get install -y -qq --no-install-recommends box86
    else
        log "Debian has no box86; using the Box86 project's apt repo"
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://ryanfortner.github.io/box86-debs/KEY.gpg | gpg --dearmor -o /etc/apt/keyrings/box86.gpg
        echo "deb [signed-by=/etc/apt/keyrings/box86.gpg arch=armhf] https://ryanfortner.github.io/box86-debs/debian ./" > /etc/apt/sources.list.d/box86.list
        apt-get update -qq && apt-get install -y -qq --no-install-recommends box86-generic-arm:armhf
    fi
fi
command -v box64 >/dev/null || { log "box64 not installed"; notify "Wine setup failed" "Box64 could not be installed; see /var/log/titan-wine.log" ; exit 1; }
command -v box86 >/dev/null || log "box86 not installed: 32-bit x86 programs won't run (64-bit ones will)"

# ----------------------------------------------------------------- Wine (x86-64 + x86 builds)
notify "Wine setup" "Installing Wine (x86-64 and x86 builds, ~700 MB)..." 40
PK="wine wine64:amd64"
avail wine32:i386 && command -v box86 >/dev/null && PK="$PK wine32:i386"
avail fonts-wine && PK="$PK fonts-wine"
apt-get install -y -qq --no-install-recommends $PK || log "wine install had errors (continuing)"
# Protect the x86 layer: held packages are never removed by apt to satisfy some other
# install (it refuses instead, and says so). They are not upgraded either; run
# "apt-mark unhold" on them first if you ever want to update Wine or Box64.
HOLD=""
for p in wine wine64:amd64 wine32:i386 libwine:amd64 libwine:i386 box64 box64-generic-arm box86:armhf box86-generic-arm:armhf; do
    have "$p" && HOLD="$HOLD $p"
done
[ -n "$HOLD" ] && apt-mark hold $HOLD >/dev/null 2>&1 && log "held against removal/upgrade:$HOLD"

# Wrappers: with binfmt the kernel starts Box64 by itself; without, these do. Box64
# also relaunches wine's own helpers (wineserver, preloader) through itself.
W64="$(ls /usr/lib/wine/wine64 /usr/lib/wine/wine64-preloader 2>/dev/null | head -n1)"; [ -n "$W64" ] || W64=/usr/lib/wine/wine64
printf '%s\n' '#!/bin/sh' '# Windows program -> Wine (x86-64 build) -> Box64. Used by "wine", .exe double-click and binfmt.' \
    'export WINEPREFIX="${WINEPREFIX:-$HOME/.wine}" WINEARCH=win64 BOX64_LOG="${BOX64_LOG:-0}" BOX64_NOBANNER=1' \
    '# Box64 settings that keep Wine stable on ARM phones (strict memory ordering, no huge blocks).' \
    'export BOX64_DYNAREC_STRONGMEM="${BOX64_DYNAREC_STRONGMEM:-1}" BOX64_DYNAREC_BIGBLOCK="${BOX64_DYNAREC_BIGBLOCK:-0}"' \
    'export BOX64_DYNAREC_SAFEFLAGS="${BOX64_DYNAREC_SAFEFLAGS:-1}" BOX64_MAXCPU="${BOX64_MAXCPU:-4}"' \
    'export WINEDEBUG="${WINEDEBUG:--all}" WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"' \
    'export WINEESYNC=0 WINEFSYNC=0' \
    'if [ -x /usr/lib/wine/wine64 ]; then exec box64 /usr/lib/wine/wine64 "$@"; fi' \
    'exec box64 /usr/bin/wine "$@"' > /usr/local/bin/wine-run
chmod 755 /usr/local/bin/wine-run
ln -sf wine-run /usr/local/bin/wine
ln -sf wine-run /usr/local/bin/wine64
printf '%s\n' '#!/bin/sh' 'exec box64 /usr/bin/wineserver "$@"' > /usr/local/bin/wineserver; chmod 755 /usr/local/bin/wineserver
printf '%s\n' '#!/bin/sh' 'exec /usr/local/bin/wine-run winecfg "$@"' > /usr/local/bin/winecfg; chmod 755 /usr/local/bin/winecfg
printf '%s\n' '#!/bin/sh' 'export BOX64_LOG=0 BOX64_NOBANNER=1; exec box64 "$@"' > /usr/local/bin/x86_64; chmod 755 /usr/local/bin/x86_64

# .exe files open with Wine from the desktop; a launcher entry for winecfg.
mkdir -p /usr/local/share/applications
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Wine (Windows program)' 'Exec=/usr/local/bin/wine-run %f' \
    'Icon=wine' 'NoDisplay=true' 'MimeType=application/x-ms-dos-executable;application/x-msdownload;application/vnd.microsoft.portable-executable;application/x-msi;' \
    > /usr/local/share/applications/titan-wine.desktop
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Wine configuration' 'Exec=/usr/local/bin/winecfg' 'Icon=wine' 'Categories=System;' \
    > /usr/local/share/applications/titan-winecfg.desktop
update-desktop-database /usr/local/share/applications 2>/dev/null || true
[ -n "$USER_NAME" ] && su - "$USER_NAME" -c 'xdg-mime default titan-wine.desktop application/x-ms-dos-executable application/x-msdownload application/vnd.microsoft.portable-executable application/x-msi' 2>/dev/null || true

# First Wine prefix now (slow, several minutes), so the first .exe does not wait for it.
if [ -n "$USER_NAME" ] && [ ! -d "/home/$USER_NAME/.wine" ]; then
    notify "Wine setup" "Creating the Wine prefix (a few minutes)..." 80
    log "wineboot --init (output follows)"
    su - "$USER_NAME" -c 'DISPLAY=:0 timeout 900 /usr/local/bin/wine-run wineboot --init 2>&1 | tail -n 40; DISPLAY=:0 timeout 120 /usr/local/bin/wineserver -w' \
        || log "wineboot did not finish cleanly (see above); Wine will try again on first use"
    [ -f "/home/$USER_NAME/.wine/system.reg" ] && log "prefix created" || log "prefix NOT created"
fi

printf '%s\n' "$VERSION" > "$STATE/done"
log "done: box64=$(box64 --version 2>/dev/null | head -n1) box86=$(command -v box86 >/dev/null && echo yes || echo no) wine=$(dpkg-query -W -f '${Version}' wine 2>/dev/null)"
notify "Wine ready" "Run .exe files from Dolphin or 'wine prog.exe'. x86-64 Linux programs run through Box64." 100
