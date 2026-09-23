#!/data/data/com.termux/files/usr/bin/bash
# Part of: Titan 2 Elite Debian Chroot - a full Debian/KDE desktop running
# alongside Android on a Unihertz Titan 2 Elite phone.
# Installs Debian and KDE into /data/adb/debian. Run once, at the start.
#
# New to this project? Read README.md first, it explains the whole setup:
# https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Debian-Chroot
#
# install_chroot.sh - one-time installation of the current Debian stable release
# (fully upgraded) with a lean KDE Plasma desktop into a rooted chroot at
# /data/adb/debian, tuned for the Unihertz Titan 2 Elite.
#
# Requires, in Termux:  pkg install curl tar xz-utils
# Options:  FULL_KDE=0  lean install: no recommends, no kde-plasma-desktop metapackage
#           KEEP_DOCS=1 keep documentation and man pages
#
# Steps: ask for the desktop user, find the current stable codename and rootfs,
# unpack it, configure apt and dpkg for speed, install the packages in one pass,
# create the user, apply the one-time KDE settings, copy in the helper programs
# and any saved Klassy build, and install the Plasma Drawer launcher.
set -eo pipefail
. "$(dirname "$(realpath "$0")")/chroot_common.sh"
escalate
fix_data_mount

CURL="$TERMUX_PREFIX/bin/curl"
TAR="$TERMUX_PREFIX/bin/tar"
for b in "$CURL" "$TAR" "$TERMUX_PREFIX/bin/xz"; do
    [ -x "$b" ] || die "Missing $(basename "$b"). In Termux run: pkg install curl tar xz-utils"
done
[ "$(uname -m)" = "aarch64" ] || die "Expected aarch64, got $(uname -m)."

echo "========================================================"
echo "   TITAN 2 ELITE DEBIAN CHROOT INSTALLER"
echo "========================================================"

# ---------- user details ----------
# TITAN_USER, TITAN_PASS and TITAN_PASS_FILE may be supplied in the environment for a fully
# non-interactive install (the Titan 2 Elite Optimiser app sets them so it can install in the
# background). When none are set, the installer prompts exactly as it always has.
#
# TITAN_PASS_FILE is preferred over TITAN_PASS: it names an app-private, root-readable file
# holding the password, so the password never appears on a command line (where `ps` could see
# it). We read it as root and shred it immediately.
if [ -n "${TITAN_USER:-}" ]; then
    RAW_USER="$TITAN_USER"
else
    read -r -p "[?] Desktop username: " RAW_USER
fi
CHROOT_USER="$(printf '%s' "$RAW_USER" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')"
case "$CHROOT_USER" in
    ""|[0-9-]*) die "Username must start with a letter or underscore (got '$CHROOT_USER')." ;;
esac
[ "$CHROOT_USER" != "$RAW_USER" ] && warn "Using sanitized username: $CHROOT_USER"

if [ -n "${TITAN_PASS_FILE:-}" ]; then
    CHROOT_PASS="$(su -c "cat '$TITAN_PASS_FILE'" 2>/dev/null)"
    su -c "rm -f '$TITAN_PASS_FILE'" 2>/dev/null || true
    [ -n "$CHROOT_PASS" ] || die "TITAN_PASS_FILE was set but empty or unreadable."
elif [ -n "${TITAN_PASS:-}" ]; then
    CHROOT_PASS="$TITAN_PASS"
    [ -n "$CHROOT_PASS" ] || die "TITAN_PASS was set but empty."
else
    while true; do
        read -r -s -p "[?] Password for $CHROOT_USER: " CHROOT_PASS; echo
        [ -n "$CHROOT_PASS" ] || { warn "Password cannot be empty."; continue; }
        read -r -s -p "[?] Confirm password: " CONFIRM; echo
        [ "$CHROOT_PASS" = "$CONFIRM" ] && break
        warn "Passwords do not match."
    done
fi

# ---------- find latest Debian stable ----------
info "Asking deb.debian.org which release is current stable..."
CODENAME="$("$CURL" -fsSL https://deb.debian.org/debian/dists/stable/Release \
    | sed -n 's/^Codename: *//p' | head -n1 || true)"
[ -n "$CODENAME" ] || die "Could not determine Debian stable codename (network/DNS?)."
log "Current Debian stable: $CODENAME"

LXC_BASE="https://images.linuxcontainers.org/images/debian/$CODENAME/arm64/default"
BUILD="$("$CURL" -fsSL "$LXC_BASE/" | grep -o 'href="[0-9]\{8\}_[0-9]\{2\}[:%3A]*[0-9]\{2\}/"' \
    | sed 's/href="//; s/\/"$//' | sort | tail -n1 || true)"
[ -n "$BUILD" ] || die "No rootfs build found at $LXC_BASE/ (new release not built yet?)."
ROOTFS_URL="$LXC_BASE/$BUILD/rootfs.tar.xz"
log "Rootfs: $ROOTFS_URL"

# ---------- tear down any previous install safely ----------
kill_chroot_procs
umount_chroot
sleep 1
chroot_has_mounts && die "Mounts still active under $CHROOT_DIR; reboot and retry. Refusing to rm -rf."

info "Wiping $CHROOT_DIR, then downloading and unpacking in one go..."
rm -rf "$CHROOT_DIR"
mkdir -p "$CHROOT_DIR"
# Download -> xz -> tar as one stream: unpacking happens while the download runs
# and nothing is written to flash twice.
"$CURL" -fL --retry 3 "$ROOTFS_URL" \
    | "$TERMUX_PREFIX/bin/xz" -dc -T0 \
    | "$TAR" -xf - -C "$CHROOT_DIR" --numeric-owner --exclude='./dev/*' \
    || die "Download/extraction failed (network?)."
[ -f "$CHROOT_DIR/etc/debian_version" ] || die "Extraction failed: no /etc/debian_version."

# ---------- Android-specific base config ----------
mkdir -p "$CHROOT_DIR/etc" "$CHROOT_DIR/usr/sbin"
rm -f "$CHROOT_DIR/etc/resolv.conf"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$CHROOT_DIR/etc/resolv.conf"
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 titan\n' > "$CHROOT_DIR/etc/hosts"
echo titan > "$CHROOT_DIR/etc/hostname"
# Don't let package postinsts try to start services inside a chroot.
printf '#!/bin/sh\nexit 101\n' > "$CHROOT_DIR/usr/sbin/policy-rc.d"
chmod 755 "$CHROOT_DIR/usr/sbin/policy-rc.d"

# Full archive: main + contrib + non-free(-firmware), updates and security.
rm -f "$CHROOT_DIR/etc/apt/sources.list"
mkdir -p "$CHROOT_DIR/etc/apt/sources.list.d"
KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
COMPONENTS="main contrib non-free non-free-firmware"
printf '%s\n' \
    "Types: deb" \
    "URIs: http://deb.debian.org/debian" \
    "Suites: $CODENAME $CODENAME-updates" \
    "Components: $COMPONENTS" \
    "Signed-By: $KEYRING" \
    "" \
    "Types: deb" \
    "URIs: http://security.debian.org/debian-security" \
    "Suites: $CODENAME-security" \
    "Components: $COMPONENTS" \
    "Signed-By: $KEYRING" \
    > "$CHROOT_DIR/etc/apt/sources.list.d/debian.sources"

# ---------- speed: dpkg/apt tuning ----------
# unsafe-io skips per-file fsync (the biggest dpkg cost on phone flash).
mkdir -p "$CHROOT_DIR/etc/dpkg/dpkg.cfg.d" "$CHROOT_DIR/etc/apt/apt.conf.d"
echo force-unsafe-io > "$CHROOT_DIR/etc/dpkg/dpkg.cfg.d/90-titan-unsafe-io"
if [ "${KEEP_DOCS:-0}" != 1 ]; then
    # Skip docs, man pages and non-English translations: far less to unpack.
    printf '%s\n' \
        'path-exclude=/usr/share/doc/*' \
        'path-include=/usr/share/doc/*/copyright' \
        'path-exclude=/usr/share/man/*' \
        'path-exclude=/usr/share/info/*' \
        'path-exclude=/usr/share/locale/*' \
        'path-include=/usr/share/locale/en*' \
        'path-include=/usr/share/locale/locale.alias' \
        > "$CHROOT_DIR/etc/dpkg/dpkg.cfg.d/91-titan-nodoc"
fi
printf '%s\n' \
    'Acquire::Languages "none";' \
    'Acquire::Retries "3";' \
    'Acquire::Queue-Mode "access";' \
    'Acquire::http::Pipeline-Depth "10";' \
    'APT::Install-Suggests "0";' \
    'Dpkg::Use-Pty "0";' \
    > "$CHROOT_DIR/etc/apt/apt.conf.d/90-titan-speed"
# During the install only: run dpkg triggers (icon caches, fontconfig, mime,
# ldconfig...) once at the end instead of after every package.
printf '%s\n' \
    'DPkg::NoTriggers "true";' \
    'PackageManager::Configure "smart";' \
    'DPkg::ConfigurePending "true";' \
    'DPkg::TriggersPending "true";' \
    > "$CHROOT_DIR/etc/apt/apt.conf.d/95-titan-install-triggers"

# Remembered display/desktop settings from a previous install (boot_desktop.sh keeps
# a copy outside the chroot). Without this a fresh install starts from the defaults:
# panel height and hiding, corner padding, title buttons, window radius, reserved
# space for maximised windows and the launcher choice would all be lost.
if [ -f "$TERMUX_HOME/titan-display.conf" ]; then
    mkdir -p "$CHROOT_DIR/etc"
    cp -f "$TERMUX_HOME/titan-display.conf" "$CHROOT_DIR/etc/titan-display.conf"
    info "Restored your saved desktop settings from ~/titan-display.conf."
    info "  (DETECT_DISPLAY=1 ./boot_desktop.sh starts from freshly detected defaults instead.)"
fi
if [ -f "$TERMUX_HOME/titan-addons-bundle.tar.gz" ] && [ -f "$TERMUX_HOME/titan-addons-bundle.key" ]; then
    # A saved Klassy + rounded-corners build: the first boot unpacks it instead of compiling.
    mkdir -p "$CHROOT_DIR/usr/local/share/titan-addons"
    cp -f "$TERMUX_HOME/titan-addons-bundle.tar.gz" "$CHROOT_DIR/usr/local/share/titan-addons/bundle.tar.gz"
    cp -f "$TERMUX_HOME/titan-addons-bundle.key" "$CHROOT_DIR/usr/local/share/titan-addons/bundle.key"
    info "Copied the saved Klassy/rounded-corners build into the chroot."
fi
mount_chroot
install_systemctl_shim   # stops the "System has not been booted with systemd" noise
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


info "Android network groups (fixes apt 'Temporary failure resolving')..."
run_in_chroot '
    groupadd -g 3003 aid_inet    2>/dev/null || true
    groupadd -g 3004 aid_net_raw 2>/dev/null || true
    usermod -g aid_inet _apt     2>/dev/null || true
'

# What gets installed. The default is the complete kde-plasma-desktop metapackage
# with recommends, so the
# desktop has everything it expects. FULL_KDE=0 installs the lean set instead (no SDDM,
# Discover, KDE Connect, wallet manager, Kate part...).
PKGS="locales tzdata sudo dbus dbus-x11 ca-certificates curl git xdg-user-dirs ninja-build ccache
    python3 python3-evdev python3-xlib
    plasma-desktop plasma-workspace kwin-x11 systemsettings plasma-integration plasma-widgets-addons kpackagetool6 kmenuedit plasma-discover packagekit appstream polkitd
    kio-extras kde-cli-tools polkit-kde-agent-1 plasma-pa pulseaudio-utils
    breeze breeze-icon-theme kde-config-gtk-style breeze-gtk-theme
    fonts-noto-core fonts-noto-mono
    konsole dolphin firefox-esr nano libnotify-bin kdialog gnupg xdg-utils x11-xserver-utils x11-xkb-utils libgl1-mesa-dri"
PKGS="$(printf '%s' "$PKGS" | tr '\n' ' ')"      # one line: it is spliced into a shell command below
# Full install by default: recommends pulled in as well, so nothing the desktop expects
# is quietly missing. FULL_KDE=0 gives the older lean set (no recommends, no metapackage),
# which is a much smaller download but leaves some pieces out.
APT_INSTALL="apt-get install -y --no-install-recommends"
if [ "${FULL_KDE:-1}" = 1 ]; then
    PKGS="$PKGS kde-plasma-desktop xdotool mesa-utils wget"
    APT_INSTALL="apt-get install -y"
fi

info "Installing KDE Plasma (latest $CODENAME point release) in one pass..."
run_in_chroot "
    set -e
    # man-db rebuilds its index after every package; turn that off.
    echo 'man-db man-db/auto-update boolean false' | debconf-set-selections
    rm -f /var/lib/man-db/auto-update
    # Only generate the one locale we use.
    echo 'locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8' | debconf-set-selections
    echo 'locales locales/default_environment_locale select en_US.UTF-8' | debconf-set-selections
    apt-get update
    # Skip any package name this release doesn't have instead of failing.
    want=''; for p in $PKGS; do
        if apt-cache show \"\$p\" >/dev/null 2>&1; then want=\"\$want \$p\"; else echo \"[!] no such package: \$p (skipped)\"; fi
    done
    # Pending point-release upgrades go into the same dpkg run as the install.
    upg=\"\$(apt-get -s full-upgrade 2>/dev/null | awk '/^Inst /{print \$2}' | tr '\\n' ' ')\"
    # A saved Klassy build is tied to one KWin version: install exactly that one when
    # the archive still has it, and hold it, so the build is never redone.
    bver=\"\$(sed -n 's/^kwin=\\([^ ]*\\).*/\\1/p' /usr/local/share/titan-addons/bundle.key 2>/dev/null)\"
    if [ -n \"\$bver\" ] && apt-cache madison kwin-x11 | grep -q \" \$bver \"; then
        pin=''; for k in kwin-x11 kwin-common kwin-data libkwin6 kwin-x11-data; do
            apt-cache madison \$k 2>/dev/null | grep -q \" \$bver \" && pin=\"\$pin \$k=\$bver\"; done
        echo \"[*] Pinning KWin to \$bver to match the saved Klassy build\"
        want=\"\$(printf '%s' \"\$want\" | sed 's/ kwin-x11\\b//')\"
    else
        pin=''; [ -n \"\$bver\" ] && echo \"[!] Saved Klassy build is for KWin \$bver, which the archive no longer has; it will need one rebuild.\"
    fi
    $APT_INSTALL \$want \$upg \$pin
    apt-get clean
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale -a 2>/dev/null | grep -qi en_US.utf8 || locale-gen
    update-locale LANG=en_US.UTF-8
    # Discover's catalogue (AppStream metadata arrives with apt update once appstream is installed).
    apt-get update -qq >/dev/null 2>&1; appstreamcli refresh --force >/dev/null 2>&1 || true
    # nano as the system editor (git, sudoedit, crontab and friends).
    update-alternatives --set editor /bin/nano >/dev/null 2>&1 || true
    printf 'EDITOR=nano\\nVISUAL=nano\\n' > /etc/environment.d/90-titan-editor.conf 2>/dev/null || true
    grep -q '^export EDITOR' /etc/profile.d/titan-editor.sh 2>/dev/null || printf 'export EDITOR=nano VISUAL=nano\\n' > /etc/profile.d/titan-editor.sh
"
rm -f "$CHROOT_DIR/etc/apt/apt.conf.d/95-titan-install-triggers"

info "Creating user $CHROOT_USER (uid 1000)..."
run_in_chroot "
    useradd -m -s /bin/bash -u 1000 -G sudo,aid_inet,aid_net_raw,audio,video,input $CHROOT_USER
    dbus-uuidgen --ensure
"
printf '%s:%s\n' "$CHROOT_USER" "$CHROOT_PASS" | chroot "$CHROOT_DIR" /usr/sbin/chpasswd
unset CHROOT_PASS CONFIRM
tune_kde "$CHROOT_USER"

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
    info "Created applications.menu; rebuilding the application database."
    chroot "$CHROOT_DIR" /bin/su - "$CHROOT_USER" -c 'kbuildsycoca6 --noincremental >/dev/null 2>&1' || true
fi
# Plasma Drawer, the default app launcher (a phone-style full-screen icon grid).
# Not fatal if it fails: boot_desktop.sh retries later.
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
info "Installing Plasma Drawer launcher..."
chroot "$CHROOT_DIR" /bin/su - "$CHROOT_USER" -c /usr/local/bin/titan-install-drawer \
    && log "Plasma Drawer installed." || warn "Plasma Drawer could not be installed now ($(tail -n1 "$CHROOT_DIR/tmp/titan_drawer.log" 2>/dev/null)); the first boot will try again."

for f in titan_input_bridge.py titan_display.py titan_notify_bridge.py; do
    [ -f "$TERMUX_HOME/$f" ] && install -m 755 "$TERMUX_HOME/$f" "$CHROOT_DIR/usr/local/bin/$f"
done
[ -f "$TERMUX_HOME/titan_addons.sh" ] && install -m 755 "$TERMUX_HOME/titan_addons.sh" "$CHROOT_DIR/usr/local/bin/titan-build-addons"
[ -f "$TERMUX_HOME/titan_wine.sh" ] && install -m 755 "$TERMUX_HOME/titan_wine.sh" "$CHROOT_DIR/usr/local/bin/titan-setup-wine"
[ -f "$TERMUX_HOME/titan_repos.sh" ] && install -m 755 "$TERMUX_HOME/titan_repos.sh" "$CHROOT_DIR/usr/local/bin/titan-repos"

run_in_chroot '. /etc/os-release; echo "Installed: $PRETTY_NAME, point release $(cat /etc/debian_version)"'

kill_chroot_procs
umount_chroot
echo "========================================================"
echo "   INSTALL COMPLETE. Now run: ./boot_desktop.sh"
echo "========================================================"
