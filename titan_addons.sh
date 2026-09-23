#!/bin/sh
# Part of: Titan 2 Elite Debian Chroot - a full Debian/KDE desktop running
# alongside Android on a Unihertz Titan 2 Elite phone.
# Builds the Klassy window decoration and the rounded-corners effect.
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
# titan_addons.sh - window add-ons for the Titan 2 Elite desktop, built inside the
# Debian chroot (installed there as /usr/local/bin/titan-build-addons and started in
# the background by boot_desktop.sh).
#   * Klassy           window decoration: rounded corners, titlebar margins
#   * Rounded corners  KWin effect (KDE-Rounded-Corners): rounds every window
# Idempotent: builds once, rebuilds after a KWin upgrade, applies the Titan window
# look once (after that, System Settings changes are kept). A finished build is
# saved as a bundle (bundle.tar.gz + bundle.key in $STATE); boot_desktop.sh copies
# it out to the Termux home, and a matching bundle is unpacked instead of rebuilt.
#   titan-build-addons            build if needed, then apply the look if needed
#   titan-build-addons --check    exit 0 = nothing to do, 1 = work to do, 2 = last build failed
#   titan-build-addons --force    rebuild from scratch and re-apply the look
# Log: /var/log/titan-addons.log
set -u
STATE=/usr/local/share/titan-addons
SRC=/usr/local/src/titan-addons
# The add-ons' own .kcfg definitions say which file and group each setting lives in.
# They are kept here (and inside the saved bundle) because a bundle install never
# clones the sources: without them the margins would be written to a guessed path.
KCFGS=/usr/local/share/titan-addons/kcfg
CONF=/etc/titan-display.conf
LOGF=/var/log/titan-addons.log
KLASSY_URL=https://github.com/paulmcauley/klassy
ROUNDED_URL=https://github.com/matinlotfali/KDE-Rounded-Corners
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MODE="${1:-run}"
mkdir -p "$STATE" "$SRC" "$KCFGS"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
stamp() { cat "$STATE/$1" 2>/dev/null; }
USER_NAME="$(awk -F: '$3 == 1000 { print $1 }' /etc/passwd)"

# ---- progress notifications in the running Plasma session ----------------
NOTIFY_ID=907001
session_env() {     # prints "DISPLAY=... DBUS_SESSION_BUS_ADDRESS=..." of the user's plasmashell, or nothing
    local pid; pid="$(pgrep -u "$USER_NAME" -x plasmashell 2>/dev/null | head -n1)"
    [ -n "$pid" ] && [ -r "/proc/$pid/environ" ] || return 1
    printf "DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS='%s'" \
        "$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')"
}
notify() {          # notify <title> <body> [percent] [urgency]  (one notification, updated in place)
    local env hint="" urg="${4:-low}" t=0
    env="$(session_env)" || return 0
    [ -n "${3:-}" ] && hint="-h int:value:$3"
    [ "$urg" != low ] && t=15000
    su "$USER_NAME" -c "$env notify-send -a 'Titan add-ons' -i applications-development -r $NOTIFY_ID -u $urg -t $t $hint '$1' '$2'" >/dev/null 2>&1 || true
}
# Follows a cmake build log ("[12/345]" from ninja, "[ 12%]" from make) and keeps the notification's bar current.
watch_build() {     # watch_build <logfile> <label>
    local p pct
    while sleep 10; do
        p="$(tail -c 4000 "$1" 2>/dev/null | grep -o '\[ *[0-9]*/[0-9]*\]\|\[ *[0-9]*%\]' | tail -n1)"
        case "$p" in
            *%*) pct="$(printf '%s' "$p" | tr -dc 0-9)" ;;
            */*) pct=$(( $(printf '%s' "$p" | tr -dc '0-9/' | cut -d/ -f1) * 100 / $(printf '%s' "$p" | tr -dc '0-9/' | cut -d/ -f2) )) ;;
            *) continue ;;
        esac
        notify "Building $2" "$pct% compiled. The desktop stays usable meanwhile." "$pct"
    done
}

# The build is tied to the installed KWin (and BUILD_REV, bumped when build flags change).
BUILD_REV=2
KWIN_VER="$(dpkg-query -W -f '${Version}' kwin-x11 2>/dev/null || dpkg-query -W -f '${Version}' kwin-common 2>/dev/null || echo unknown)"
KEY="kwin=$KWIN_VER rev=$BUILD_REV arch=$(dpkg --print-architecture 2>/dev/null || uname -m)"
BUNDLE="$STATE/bundle.tar.gz"

# Values from the display config decide radius and margins.
CORNER_RADIUS=100; DISPLAY_SCALE=1.5; TOP_INSET=100; CUTOUT_RIGHT=100; WINDOW_RADIUS=30; TITLE_BUTTONS=right; SCREEN_W=1080; CORNER_PAD=16; SPACER_PX=20
[ -f "$CONF" ] && . "$CONF"
CFGKEY="$KEY r=$WINDOW_RADIUS c=$CORNER_RADIUS s=$DISPLAY_SCALE h=$CUTOUT_RIGHT b=${TITLE_BUTTONS:-right} p=$CORNER_PAD sp=${SPACER_PX:-20} look=v12"

case "$MODE" in
    --check)
        [ "$(stamp failed)" = "$KEY" ] && exit 2
        # A saved build for a different KWin: never rebuild on our own (exit 3 = needs a decision).
        [ -f "$BUNDLE" ] && [ "$(stamp bundle.key)" != "$KEY" ] && [ "$(stamp installed)" != "$KEY" ] && exit 3
        [ "$(stamp installed)" = "$KEY" ] && [ "$(stamp configured)" = "$CFGKEY" ] && exit 0
        exit 1 ;;
    --force) rm -f "$STATE/installed" "$STATE/failed" "$STATE/configured" "$BUNDLE" "$STATE/bundle.key"
             rm -rf "$SRC/klassy" "$SRC/rounded" ;;
esac

exec >>"$LOGF" 2>&1
exec 9>"$STATE/lock"
flock -n 9 || { log "another add-on build is already running"; exit 0; }
log "---- titan-build-addons ($MODE) for $KEY"

# --configure: apply the window look only, skipping build and install entirely.
# The button/margin settings below are ordinary kdecoration keys that work with any
# decoration theme, so they must not be trapped behind a build that is missing or
# built against a different KWin (which is what left a fresh install with no
# minimise/maximise/close buttons).
if [ "$MODE" != --configure ]; then
# ================================================================= build
# Parallel jobs: all cores, but no more than RAM allows (~1.5 GB per C++ job).
JOBS="$(awk -v n="$(nproc 2>/dev/null || echo 2)" '/MemTotal/ { m = int($2 / 1572864); if (m < 1) m = 1;
    print (m < n) ? m : n }' /proc/meminfo 2>/dev/null || echo 2)"
# Ninja + ccache (installed with the build deps): faster builds, near-instant
# rebuilds after a KWin upgrade.
export CCACHE_DIR=/var/cache/titan-ccache
CMAKE_COMMON="-DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DKDE_INSTALL_USE_QT_SYS_PATHS=ON -DBUILD_TESTING=OFF"

apt_pick() {     # print only the packages this Debian actually has
    for p in "$@"; do apt-cache show "$p" >/dev/null 2>&1 && printf '%s ' "$p"; done
}

install_deps() {
    log "installing build dependencies (one time, a few hundred MB)..."
    apt-get update -qq || return 1
    apt-get install -y -qq --no-install-recommends libnotify-bin >/dev/null 2>&1 || true
    notify "Titan window add-ons" "Installing build tools (one time, a few hundred MB)..."
    WANT="git cmake g++ make ninja-build ccache extra-cmake-modules gettext pkg-config
        qt6-base-dev qt6-base-private-dev qt6-base-dev-tools qt6-declarative-dev
        qt6-svg-dev qt6-tools-dev qt6-tools-dev-tools libqt6opengl6-dev
        libkf6config-dev libkf6configwidgets-dev libkf6coreaddons-dev libkf6guiaddons-dev
        libkf6i18n-dev libkf6iconthemes-dev libkf6kcmutils-dev libkf6package-dev
        libkf6windowsystem-dev libkf6colorscheme-dev libkf6svg-dev libkf6dbusaddons-dev
        libkf6service-dev libkf6widgetsaddons-dev libkf6crash-dev libkf6kio-dev
        libkirigami-dev libkf6kirigami-dev libkf6kirigami2-dev kirigami2-dev
        libplasma-dev libplasma6-dev frameworkintegration-dev libkf6frameworkintegration-dev libkf6style-dev
        libkf6notifications-dev libkf6xmlgui-dev libkf6globalaccel-dev libkf6newstuff-dev libkf6jobwidgets-dev
        libkdecorations3-dev libkdecorations2-dev kwin-dev kwin-x11-dev
        libepoxy-dev libdrm-dev libxcb1-dev libxcb-xfixes0-dev"
    PKGS="$(apt_pick $WANT)"
    log "packages: $PKGS"
    apt-get install -y -qq --no-install-recommends $PKGS
}

plasma_version() {
    v="$(dpkg-query -W -f '${Version}' plasma-workspace 2>/dev/null | sed 's/^[0-9]*://' | grep -o '^[0-9]*\.[0-9]*')"
    [ -n "$v" ] || v="$(printf '%s' "$KWIN_VER" | sed 's/^[0-9]*://' | grep -o '^[0-9]*\.[0-9]*')"
    printf '%s' "$v"
}

# Copy a project's .kcfg definitions into the staging tree, so they are installed
# with everything else and travel inside the saved bundle. A later install that
# unpacks the bundle instead of compiling then still knows where each setting goes.
stage_kcfg() {   # stage_kcfg <klassy|rounded>
    local d="$SRC/stage$KCFGS/$1"
    mkdir -p "$d" || return 1
    find "$SRC/$1" -name '*.kcfg' -exec cp -f {} "$d/" \; 2>/dev/null
    [ -n "$(ls "$d" 2>/dev/null)" ] || log "  (no .kcfg files found in $1 sources)"
}

# Install into a staging tree (kept for the bundle), then copy onto the system.
stage_install() {
    DESTDIR="$SRC/stage" cmake --install "$SRC/$1/build" >/dev/null || return 1
    cp -a "$SRC/stage/." / || return 1
}

# Save everything both builds installed as one reusable bundle.
export_bundle() {
    [ -d "$SRC/stage" ] || return 0
    tar -C "$SRC/stage" -czf "$BUNDLE.new" . && mv -f "$BUNDLE.new" "$BUNDLE" || return 1
    printf '%s\n' "$KEY" > "$STATE/bundle.key"
    rm -rf "$SRC/stage"
    log "saved build bundle for $KEY ($(du -h "$BUNDLE" | cut -f1)); boot_desktop.sh keeps a copy in the Termux home"
}

# Unpack a saved bundle that matches the installed KWin instead of compiling.
import_bundle() {
    [ -f "$BUNDLE" ] && [ "$(stamp bundle.key)" = "$KEY" ] || return 1
    log "unpacking saved build bundle for $KEY (no compile needed)..."
    tar -C / -xzf "$BUNDLE" || return 1
}

build_klassy() {
    ver="$(plasma_version)"; branch="plasma$ver"
    git ls-remote --heads "$KLASSY_URL" "$branch" 2>/dev/null | grep -q "$branch" || branch=master
    log "building Klassy (branch $branch, Plasma $ver)..."
    # Resume an interrupted build if the checkout is the right branch.
    if [ ! -d "$SRC/klassy/.git" ] || [ "$(cat "$SRC/klassy.branch" 2>/dev/null)" != "$branch" ]; then
        rm -rf "$SRC/klassy"
        git clone -q --depth 1 -b "$branch" "$KLASSY_URL" "$SRC/klassy" || return 1
        printf '%s\n' "$branch" > "$SRC/klassy.branch"
    fi
    GEN=""; command -v ninja >/dev/null 2>&1 && GEN="-G Ninja"
    LAUNCH=""; command -v ccache >/dev/null 2>&1 && LAUNCH="-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
    log "  $JOBS parallel jobs${GEN:+, ninja}${LAUNCH:+, ccache}"
    cmake -S "$SRC/klassy" -B "$SRC/klassy/build" $GEN $LAUNCH $CMAKE_COMMON \
        -DBUILD_QT5=OFF -DBUILD_QT6=ON >"$SRC/klassy-cmake.log" 2>&1 \
        || { tail -n 30 "$SRC/klassy-cmake.log"; return 1; }
    notify "Building Klassy" "Starting the compile..." 0
    watch_build "$SRC/klassy-build.log" Klassy & wpid=$!
    nice -n 10 cmake --build "$SRC/klassy/build" -j"$JOBS" >"$SRC/klassy-build.log" 2>&1; rc=$?
    kill "$wpid" 2>/dev/null
    [ "$rc" = 0 ] || { tail -n 40 "$SRC/klassy-build.log"; return 1; }
    stage_kcfg klassy
    stage_install klassy || return 1
    rm -rf "$SRC/klassy/build"
    log "Klassy installed"
}

build_rounded() {
    log "building rounded-corners effect..."
    if [ ! -d "$SRC/rounded/.git" ]; then
        git clone -q --depth 1 "$ROUNDED_URL" "$SRC/rounded" || return 1
    fi
    # Plasma 6.4+ keeps the X11 headers in kwin-x11-dev (KWIN_X11=ON); 6.3 builds plain.
    GEN=""; command -v ninja >/dev/null 2>&1 && GEN="-G Ninja"
    LAUNCH=""; command -v ccache >/dev/null 2>&1 && LAUNCH="-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
    if ! cmake -S "$SRC/rounded" -B "$SRC/rounded/build" $GEN $LAUNCH $CMAKE_COMMON -DKWIN_X11=ON \
            >"$SRC/rounded-cmake.log" 2>&1; then
        rm -rf "$SRC/rounded/build"
        cmake -S "$SRC/rounded" -B "$SRC/rounded/build" $GEN $LAUNCH $CMAKE_COMMON \
            >"$SRC/rounded-cmake.log" 2>&1 || { tail -n 30 "$SRC/rounded-cmake.log"; return 1; }
    fi
    notify "Building rounded corners" "Starting the compile..." 0
    watch_build "$SRC/rounded-build.log" "rounded corners" & wpid=$!
    nice -n 10 cmake --build "$SRC/rounded/build" -j"$JOBS" >"$SRC/rounded-build.log" 2>&1; rc=$?
    kill "$wpid" 2>/dev/null
    [ "$rc" = 0 ] || { tail -n 40 "$SRC/rounded-build.log"; return 1; }
    stage_kcfg rounded
    stage_install rounded || return 1
    rm -rf "$SRC/rounded/build"
    log "rounded-corners effect installed"
}

if [ "$(stamp installed)" != "$KEY" ]; then
    if [ "$(stamp failed)" = "$KEY" ]; then
        log "last build failed for this KWin version; REBUILD_ADDONS=1 ./boot_desktop.sh to retry"
        exit 1
    fi
    rm -f "$STATE/configured"
    if import_bundle; then
        printf '%s\n' "$KEY" > "$STATE/installed"
    elif [ -f "$BUNDLE" ] && [ "$MODE" != --force ]; then
        log "saved build is for '$(stamp bundle.key)' but KWin is now '$KEY'. Not rebuilding by itself:"
        log "  REBUILD_ADDONS=1 ./boot_desktop.sh compiles once for the new KWin (then hold it: HOLD_KWIN=1)."
        notify "Window add-ons need a rebuild" "KWin changed. REBUILD_ADDONS=1 ./boot_desktop.sh compiles once." "" normal
        exit 1
    else
        # After a KWin upgrade (or --force) start clean; an interrupted first build resumes.
        [ -n "$(stamp installed)" ] && rm -rf "$SRC/klassy" "$SRC/rounded" "$SRC/stage"
        if install_deps && build_klassy && build_rounded && export_bundle; then
        notify "Titan window add-ons" "Build finished. Applying the window look..."
            printf '%s\n' "$KEY" > "$STATE/installed"; rm -f "$STATE/failed"
            apt-get clean
        else
            printf '%s\n' "$KEY" > "$STATE/failed"
            log "BUILD FAILED (see above and $SRC/*.log). REBUILD_ADDONS=1 ./boot_desktop.sh retries."
            exit 1
        fi
    fi
fi

# Pin KWin so the saved build stays valid across apt upgrades (HOLD_KWIN=0 undoes it).
kwin_pkgs() { dpkg-query -W -f '${Package}\n' 'kwin*' 'libkwin*' 2>/dev/null; }
if [ "${HOLD_KWIN:-1}" = 1 ]; then
    [ "$(stamp held)" = "$KEY" ] || { apt-mark hold $(kwin_pkgs) >/dev/null 2>&1 && printf '%s\n' "$KEY" > "$STATE/held" \
        && log "KWin packages put on hold so this build keeps working ($(kwin_pkgs | tr '\n' ' '))"; }
else
    [ -f "$STATE/held" ] && { apt-mark unhold $(kwin_pkgs) >/dev/null 2>&1; rm -f "$STATE/held"; log "KWin packages released from hold"; }
fi

fi   # end of build/install section (skipped by --configure)

# ================================================================= window look
[ "$(stamp configured)" = "$CFGKEY" ] && exit 0
[ -n "$USER_NAME" ] || { log "no uid-1000 user; cannot apply settings"; exit 1; }

# Titlebar side margins (logical px) so the buttons sit inside the screen's corner
# curve: how far in the curve reaches at button height, plus a gap.
SIDE="$(awk -v R="$CORNER_RADIUS" -v s="$DISPLAY_SCALE" 'BEGIN {
    y = R - 21; if (y < 0) y = 0; d = R*R - y*y; if (d < 0) d = 0
    printf "%d", (R - sqrt(d)) / s + 3 }')"
SIDE=$(( SIDE + CORNER_PAD ))
# The left side also clears the camera hole (its right edge, from Android).
LEFT="$(awk -v h="$CUTOUT_RIGHT" -v s="$DISPLAY_SCALE" -v m="$SIDE" 'BEGIN {
    c = int(h / s + 4); printf "%d", (c > m) ? c : m }')"
log "window look: radius ${WINDOW_RADIUS}px, titlebar margins left ${LEFT}px / right ${SIDE}px (logical)"

CMDS="$STATE/apply.sh"
: > "$CMDS"
emit()   { printf '%s\n' "$*" >> "$CMDS"; }
kgroup() { sed -n 's/.*<group name="\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n1; }
# The group a given entry lives in (a kcfg can hold several groups: Klassy's has
# Global, Windeco, ... and the decoration reads Windeco).
kgroup_of() {   # kcfg entry
    awk -v e="name=\"$2\"" '/<group name="/ { g = $0; sub(/.*<group name="/, "", g); sub(/".*/, "", g) }
        index($0, "<entry") && index($0, e) { print g; exit }' "$1" 2>/dev/null
}
kfile()  { sed -n 's/.*<kcfgfile[^>]*name="\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n1; }
# kchoice <kcfg> <entry> <preferred>...: first preferred value that is a valid choice
# for that enum entry (empty if the entry or none of them exist).
kchoice() {
    local kcfg="$1" entry="$2" choices c; shift 2
    choices="$(awk -v e="name=\"$entry\"" 'index($0, "<entry") && index($0, e) { on = 1 }
        on && /<choice name="/ { c = $0; sub(/.*<choice name="/, "", c); sub(/".*/, "", c); print c }
        on && /<\/entry>/ { exit }' "$kcfg" 2>/dev/null)"
    for c in "$@"; do printf '%s\n' "$choices" | grep -qx "$c" && { printf '%s' "$c"; return 0; }; done
    log "  ('$entry' choices are: $(printf '%s' "$choices" | tr '\n' ' '))"
    return 1
}
# kset <kcfg|-> <file> <group> <key> <value>: only sets keys the add-on's own
# .kcfg defines (names change between versions); with no kcfg, sets it anyway.
kset() {
    local g="$3"
    if [ "$1" = - ] || grep -q "name=\"$4\"" "$1"; then
        [ "$1" != - ] && g="$(kgroup_of "$1" "$4")" && [ -n "$g" ] || g="$3"
        emit "\$K --file '$2' --group '$g' --key '$4' '$5'"
    else
        log "  ('$4' is not a setting in this $(basename "$1"); adjust it in System Settings if needed)"
    fi
}

emit 'K=$(command -v kwriteconfig6 || command -v kwriteconfig5) || exit 1'
# KWin: Klassy for every window, no borders, rounded-corners effect on. Buttons go
# on one side only: left (default) sits just past the camera hole, in space the
# margin leaves empty anyway; right keeps them inside the corner.
# Plasma 6.4 moved the decoration settings from org.kde.kdecoration2 to
# org.kde.kdecoration3. Writing only the old group on a newer KWin leaves the
# default decoration in place, so nothing here (margins included) ever shows up.
# Both groups are written; the one KWin does not use is simply ignored.
deco() { emit "for g in org.kde.kdecoration2 org.kde.kdecoration3; do \$K --file kwinrc --group \$g --key $1 $2; done"; }
deco library org.kde.klassy
deco theme Klassy
deco BorderSize None
deco BorderSizeAuto false
# Klassy's TitleBar*Margin settings are a percentage of the titlebar height and cap at
# 60, which is nowhere near the ~100px screen corner radius, so on their own they leave
# the buttons sitting inside the rounded corner. KWin's spacer button ("_", the character
# KDecoration uses for DecorationButtonType::Spacer) is not capped, so the remaining
# inset is built out of spacers on top of whatever the margin managed.
# SPACER_PX is the width one spacer buys, calibrated on the Titan 2 Elite: three spacers
# were right for a 60px corner inset.
SPACER_PX="${SPACER_PX:-20}"
spacers() {   # spacers <logical px> -> that many underscores
    local n i out=""
    n="$(awk -v p="$1" -v w="$SPACER_PX" 'BEGIN { n = int(p / w + 0.5); if (n < 0) n = 0; if (n > 12) n = 12; print n }')"
    i=0
    while [ "$i" -lt "$n" ]; do out="${out}_"; i=$(( i + 1 )); done
    printf '%s' "$out"
}
# The right side clears the corner curve; the left side clears the camera hole as well,
# which is why LEFT is the larger of the two (see the SIDE/LEFT computation above).
RSPACE="$(spacers "$SIDE")"
LSPACE="$(spacers "$LEFT")"
grp() { [ -n "$1" ] && printf '%s' "$1" || printf "''"; }
log "spacer buttons: left $(( ${#LSPACE} )) right $(( ${#RSPACE} )) (one spacer ~${SPACER_PX}px logical)"
case "$TITLE_BUTTONS" in
    right)
        # Left group is spacers only: it reserves the camera-hole width so nothing
        # in the titlebar starts underneath the cutout.
        deco ButtonsOnLeft "$(grp "$LSPACE")"
        deco ButtonsOnRight "IAX$RSPACE"
        TITLE_ALIGN=AlignCenterFullWidth ;;
    center)
        # KDE decorations only have a left and a right group, so "centre" is the left
        # group pushed in with spacers until it lands mid-screen when maximised
        # (buttons ~26px each + spacing); the title then sits to their right.
        CENTER_PX="$(awk -v w="$SCREEN_W" -v s="$DISPLAY_SCALE" -v l="$LEFT" 'BEGIN {
            c = w / s / 2 - (3 * 26 + 2 * 8) / 2; if (c < l) c = l; printf "%d", c }')"
        deco ButtonsOnLeft "$(spacers "$CENTER_PX")IAX"
        deco ButtonsOnRight "$(grp "$RSPACE")"
        TITLE_ALIGN=AlignLeft ;;
    *)
        # Buttons on the left must start past the camera hole, so the spacers come first.
        deco ButtonsOnLeft "${LSPACE}XIA"
        deco ButtonsOnRight "$(grp "$RSPACE")"
        TITLE_ALIGN=AlignCenterFullWidth ;;
esac
log "title buttons: $TITLE_BUTTONS (left margin ${LEFT}px)"

# A build made by an older version of this script, or a bundle unpacked without ever
# compiling, leaves no .kcfg on disk: every margin would then be written to a guessed
# file and group, and Klassy would simply ignore it. Fetch the definitions once
# (a shallow clone, no compile) so the settings land where Klassy reads them.
if [ -z "$(find "$KCFGS" -name '*.kcfg' 2>/dev/null | head -n1)" ] \
   && [ ! -d "$SRC/klassy" ] && command -v git >/dev/null 2>&1; then
    log "no .kcfg definitions on disk; fetching them (small, no compile)..."
    for spec in "$KLASSY_URL klassy" "$ROUNDED_URL rounded"; do
        set -- $spec
        t="$SRC/kcfg-fetch"
        rm -rf "$t"
        if git clone -q --depth 1 "$1" "$t" 2>/dev/null; then
            mkdir -p "$KCFGS/$2"
            find "$t" -name '*.kcfg' -exec cp -f {} "$KCFGS/$2/" \; 2>/dev/null
        else
            log "  could not fetch $2 definitions (offline?); falling back to defaults"
        fi
        rm -rf "$t"
    done
    log "  definitions on disk now: $(find "$KCFGS" -name '*.kcfg' 2>/dev/null | tr '\n' ' ')"
fi

# Klassy decoration (config file/group read from its kcfg; defaults if not found).
KC="$(find "$KCFGS/klassy" "$SRC/klassy" -name '*.kcfg' -exec grep -ls 'name="WindowCornerRadius"' {} + 2>/dev/null | head -n1)"
[ -n "$KC" ] || KC="$(find "$KCFGS/klassy" "$SRC/klassy" -name '*.kcfg' -exec grep -ls klassyrc {} + 2>/dev/null | head -n1)"
KF="$(kfile "$KC")"; [ -n "$KF" ] || KF=klassy/klassyrc
KG="$(kgroup_of "$KC" WindowCornerRadius)"; [ -n "$KG" ] || KG=Windeco
# Remove any of these keys from the Global group, where they have no effect and could be confusing.
for k in WindowCornerRadius TitleBarLeftMargin TitleBarRightMargin TitleBarTopMargin TitleBarBottomMargin \
         ButtonSpacingLeft ButtonSpacingRight ShadowSize TitleAlignment DrawBorderOnMaximizedWindows \
         LockTitleBarLeftRightMargins LockTitleBarLeftRight ButtonSize; do
    emit "\$K --file '$KF' --group Global --key '$k' --delete 2>/dev/null || true"
done
[ -n "$KC" ] || KC=-
kset "$KC" "$KF" "$KG" WindowCornerRadius "$WINDOW_RADIUS"
kset "$KC" "$KF" "$KG" ScaledCornerRadius false
kset "$KC" "$KF" "$KG" RoundBottomCornersWhenNoBorders true
kset "$KC" "$KF" "$KG" TitleAlignment "$TITLE_ALIGN"
kset "$KC" "$KF" "$KG" LockTitleBarLeftRightMargins false
kset "$KC" "$KF" "$KG" LockTitleBarTopBottomMargins true
kset "$KC" "$KF" "$KG" TitleBarLeftMargin "$LEFT"
kset "$KC" "$KF" "$KG" TitleBarRightMargin "$SIDE"
kset "$KC" "$KF" "$KG" DrawBorderOnMaximizedWindows false
# Touch: full-height rectangular buttons (the whole title-bar height is the tap
# target), large icons, a taller title bar, room between the buttons.
if [ "$KC" != - ]; then
    v="$(kchoice "$KC" ButtonShape ShapeFullHeightRectangle ShapeFullHeightRoundedRectangle ShapeLargeRoundedSquare ShapeLargeCircle)" \
        && kset "$KC" "$KF" "$KG" ButtonShape "$v"
    v="$(kchoice "$KC" IconSize IconVeryLarge IconGiant IconLarge IconHumongous)" \
        && kset "$KC" "$KF" "$KG" IconSize "$v"
    v="$(kchoice "$KC" SystemIconSize SystemIcon32 SystemIcon28 SystemIcon24 SystemIcon22)" \
        && kset "$KC" "$KF" "$KG" SystemIconSize "$v"
else
    kset "$KC" "$KF" "$KG" ButtonShape ShapeFullHeightRectangle
    kset "$KC" "$KF" "$KG" IconSize IconVeryLarge
fi
kset "$KC" "$KF" "$KG" FullHeightButtonWidthMarginLeft 10
kset "$KC" "$KF" "$KG" FullHeightButtonWidthMarginRight 10
kset "$KC" "$KF" "$KG" LockFullHeightButtonWidthMargins true
kset "$KC" "$KF" "$KG" FullHeightButtonSpacingLeft 4
kset "$KC" "$KF" "$KG" FullHeightButtonSpacingRight 4
kset "$KC" "$KF" "$KG" ButtonSpacingLeft 8
kset "$KC" "$KF" "$KG" ButtonSpacingRight 8
kset "$KC" "$KF" "$KG" TitleBarTopMargin 6
kset "$KC" "$KF" "$KG" TitleBarBottomMargin 6
kset "$KC" "$KF" "$KG" ShadowSize ShadowNone
[ "$KC" != - ] && log "  klassy button/size settings it offers: $(grep -o 'entry name="[^"]*"' "$KC" | grep -iE 'button|size|radius' | cut -d'"' -f2 | tr '\n' ' ')"

# Rounded-corners effect: floating windows only. A maximised window is left square
# so it runs right into the screen's own rounded corners with no gap or sliver; the
# glass does the rounding. (Klassy already squares its corners when maximised, and
# its titlebar margins keep the buttons out of the corners and the camera hole.)
RC="$(find "$KCFGS/rounded" "$SRC/rounded" -name '*.kcfg' 2>/dev/null | head -n1)"
RF="$(kfile "$RC")"; [ -n "$RF" ] || RF=kwinrc
RG="$(kgroup "$RC")"; [ -n "$RG" ] || RG=Round-Corners
[ -n "$RC" ] || RC=-
kset "$RC" "$RF" "$RG" Size "$WINDOW_RADIUS"
kset "$RC" "$RF" "$RG" InactiveCornerRadius "$WINDOW_RADIUS"
kset "$RC" "$RF" "$RG" DisableRoundMaximize true
kset "$RC" "$RF" "$RG" DisableRoundTile true
kset "$RC" "$RF" "$RG" OutlineThickness 0
kset "$RC" "$RF" "$RG" InactiveOutlineThickness 0
kset "$RC" "$RF" "$RG" ShadowSize 0

# Klassy's own colour scheme and widget style, so panels, popups and apps match the decoration.
[ -f /usr/share/color-schemes/KlassyDark.colors ] && \
    emit 'command -v plasma-apply-colorscheme >/dev/null && plasma-apply-colorscheme KlassyDark >/dev/null 2>&1 || $K --file kdeglobals --group General --key ColorScheme KlassyDark'
# A glob inside [ ] fails as soon as it matches more than one path (and the plugin is
# not always called klassy6.so), so the style was quietly skipped. Look for it properly.
[ -n "$(ls /usr/lib/*/qt6/plugins/styles/klassy*.so 2>/dev/null | head -n1)" ] \
    && emit '$K --file kdeglobals --group KDE --key widgetStyle klassy'
if su - "$USER_NAME" -c "sh '$CMDS'"; then
    printf '%s\n' "$CFGKEY" > "$STATE/configured"
    log "window look applied"
else
    log "applying the window look failed (see $CMDS)"
    exit 1
fi

# Make the running KWin pick it up now: reconfigure over the session bus, or
# restart it in place if that is not possible.
pid="$(pgrep -u "$USER_NAME" -x kwin_x11 | head -n1)"
if [ -n "$pid" ] && [ -r "/proc/$pid/environ" ]; then
    addr="$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')"
    if su "$USER_NAME" -c "DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS='$addr' dbus-send --session --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure"; then
        log "KWin reloaded: Klassy + rounded corners are live"
        notify "Window add-ons ready" "Klassy and rounded corners are now active." "" normal
    else
        su "$USER_NAME" -c "DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS='$addr' LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe kwin_x11 --replace >/dev/null 2>&1 &" \
            && log "KWin restarted with the new look" || log "could not reload KWin; the look appears at the next boot"
    fi
fi
