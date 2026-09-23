#!/bin/sh
# Part of: Titan 2 Elite Debian Chroot - a full Debian/KDE desktop running
# alongside Android on a Unihertz Titan 2 Elite phone.
# Optional: adds extra Debian package sources (backports, Mozilla, VS Code).
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
# titan_repos.sh - additional package sources for the Titan 2 Elite Debian chroot,
# for newer software than Debian stable ships (installed there as
# /usr/local/bin/titan-repos; boot_desktop.sh runs it once).
#
# What it adds (arm64 builds only; sources without arm64 packages are useless here):
#   trixie-backports   Debian's own newer builds of selected packages, safe alongside
#                      stable: "apt install -t trixie-backports kicad"
#   testing            Debian testing, pinned low: never used unless asked for with
#                      "apt install -t testing <package>". Pulls in newer libraries
#                      when needed; the usual way to get the latest KiCad, Blender...
#   Mozilla            current Firefox (not the ESR release)
#   Microsoft          Visual Studio Code
#   Brave              Brave browser
# Snap does not work in a chroot (needs systemd) and Flatpak needs kernel features
# Android does not provide; AppImages run with the usual "chmod +x" when arm64 builds exist.
#
#   titan-repos [--check]        (--check: exit 0 = already set up)
set -u
STATE=/usr/local/share/titan-repos
VERSION=1
[ "${1:-}" = --check ] && { [ "$(cat "$STATE/done" 2>/dev/null)" = "$VERSION" ] && exit 0 || exit 1; }
export DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p "$STATE" /etc/apt/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d
log() { printf '[titan-repos] %s\n' "$*"; }
. /etc/os-release
CODENAME="${VERSION_CODENAME:-trixie}"
apt-get install -y -qq --no-install-recommends curl gnupg ca-certificates >/dev/null 2>&1 || true

# ---- Debian backports (same keyring as the main archive)
printf '%s\n' "Types: deb" "URIs: http://deb.debian.org/debian" "Suites: $CODENAME-backports" \
    "Components: main contrib non-free non-free-firmware" "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg" \
    > /etc/apt/sources.list.d/backports.sources
log "added $CODENAME-backports"

# ---- Debian testing, pinned so nothing is taken from it unless explicitly requested
printf '%s\n' "Types: deb" "URIs: http://deb.debian.org/debian" "Suites: testing" \
    "Components: main contrib non-free non-free-firmware" "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg" \
    > /etc/apt/sources.list.d/testing.sources
printf '%s\n' "Package: *" "Pin: release a=testing" "Pin-Priority: 100" > /etc/apt/preferences.d/90-testing-low
log "added testing (pinned to priority 100: only with apt install -t testing ...)"

add_key_repo() {   # add_key_repo <name> <key url> <deb line>
    if curl -fsSL "$2" | gpg --dearmor -o "/etc/apt/keyrings/$1.gpg" 2>/dev/null; then
        printf '%s\n' "$3" > "/etc/apt/sources.list.d/$1.list"
        log "added $1"
    else
        log "could not fetch the key for $1 (no network?); skipped"
    fi
}
# ---- Mozilla (current Firefox), preferred over Debian's firefox-esr for the "firefox" package
add_key_repo mozilla https://packages.mozilla.org/apt/repo-signing-key.gpg \
    "deb [signed-by=/etc/apt/keyrings/mozilla.gpg arch=arm64] https://packages.mozilla.org/apt mozilla main"
printf '%s\n' "Package: *" "Pin: origin packages.mozilla.org" "Pin-Priority: 1000" > /etc/apt/preferences.d/mozilla
# ---- Microsoft (Visual Studio Code)
add_key_repo microsoft https://packages.microsoft.com/keys/microsoft.asc \
    "deb [signed-by=/etc/apt/keyrings/microsoft.gpg arch=arm64] https://packages.microsoft.com/repos/code stable main"
# ---- Brave browser
add_key_repo brave https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
    "deb [signed-by=/etc/apt/keyrings/brave.gpg arch=arm64] https://brave-browser-apt-release.s3.brave.com/ stable main"

apt-get update -qq 2>&1 | grep -v '^W: ' || true
printf '%s\n' "$VERSION" > "$STATE/done"
log "done. Examples:"
log "  apt install -t $CODENAME-backports kicad        newer KiCad from backports (if present)"
log "  apt install -t testing kicad                    latest KiCad from Debian testing"
log "  apt install firefox                             current Firefox (Mozilla)"
log "  apt install code                                Visual Studio Code"
