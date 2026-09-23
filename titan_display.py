#!/usr/bin/env python3
"""
Copyright (C) 2026 Flux-Sniffer-Mods. Licensed under GPL-3.0-or-later;
see the LICENSE file or <https://www.gnu.org/licenses/>. No warranty.

Part of: Titan 2 Elite Debian Chroot - a full Debian/KDE desktop running
alongside Android on a Unihertz Titan 2 Elite phone.
Sets the panel layout, screen margins and launcher inside the KDE session.

New to this project? Read README.md first, it explains the whole setup:
https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Debian-Chroot

titan_display.py - Plasma session helper for the Titan 2 Elite (KDE autostart).

Responsibilities, in the order they run:
* Compositing: not handled here. With LATE_COMPOSITING=1 the session launcher
  starts KWin composited before the splash exists; otherwise KWin starts
  composited on its own. Either way there is no toggle to perform after login.
* Reserved space: optionally keeps maximised windows below the camera cutout
  (TOP_RESERVE) and above the bottom corners (BOTTOM_RESERVE).
* Panel: builds the touch layout once (corner spacers sized to the rounded
  corners, launcher, tasks, tray, phone status, clock; hides under windows) and
  afterwards only adjusts sizes, keeping whatever the user changed. A full rebuild
  happens only on request (RESET_PANEL=1).
* Launcher: applies the Kickoff/Dashboard/Drawer settings, writing only values
  that differ so the launcher is not reloaded needlessly.

Settings live in /etc/titan-display.conf (written by boot_desktop.sh).
The panel is set up once; after that your own Plasma edits are kept.
RESET_PANEL=1 ./boot_desktop.sh re-applies the Titan layout.
Log: /tmp/titan_display.log
"""
import os
import re
import subprocess
import sys
import time

LOG = open("/tmp/titan_display.log", "w", buffering=1)


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, file=LOG)


def load_conf():
    conf = {"CORNER_RADIUS": "100", "DISPLAY_SCALE": "1.5", "TOP_RESERVE": "0",
            "PANEL_HEIGHT": "36", "SCREEN_W": "1080", "PANEL_HIDING": "dodgewindows"}
    try:
        with open("/etc/titan-display.conf") as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    conf[k] = v
    except OSError:
        log("config missing, using defaults")
    return conf


def reserve_space(top, bottom):
    """Invisible reservation for maximised windows: a 1x1 dock window hidden in the
    rounded top-left corner claims `top` and `bottom` px via its strut. The
    wallpaper and panel still use the whole screen; only maximised windows are kept
    below the camera cutout and above the tightest part of the bottom corners.
    True full-screen (F11, video) ignores this, as it should."""
    from Xlib import X, Xatom, display
    d = display.Display()
    scr = d.screen()
    width = scr.width_in_pixels
    win = scr.root.create_window(0, 0, 1, 1, 0, scr.root_depth, X.InputOutput,
                                 X.CopyFromParent, background_pixel=scr.black_pixel)
    atom = d.intern_atom
    win.set_wm_name("titan-safe-area")
    win.set_wm_normal_hints(flags=1 | 2)  # USPosition | USSize
    win.change_property(atom("_NET_WM_WINDOW_TYPE"), Xatom.ATOM, 32,
                        [atom("_NET_WM_WINDOW_TYPE_DOCK")])
    win.change_property(atom("_NET_WM_STATE"), Xatom.ATOM, 32,
                        [atom("_NET_WM_STATE_STICKY"), atom("_NET_WM_STATE_SKIP_TASKBAR"),
                         atom("_NET_WM_STATE_SKIP_PAGER")])
    win.change_property(atom("_NET_WM_DESKTOP"), Xatom.CARDINAL, 32, [0xFFFFFFFF])
    # left, right, top, bottom
    win.change_property(atom("_NET_WM_STRUT"), Xatom.CARDINAL, 32, [0, 0, top, bottom])
    # + left_y0, left_y1, right_y0, right_y1, top_x0, top_x1, bottom_x0, bottom_x1
    win.change_property(atom("_NET_WM_STRUT_PARTIAL"), Xatom.CARDINAL, 32,
                        [0, 0, top, bottom, 0, 0, 0, 0,
                         0, width - 1 if top else 0, 0, width - 1 if bottom else 0])
    win.map()
    d.flush()
    log(f"maximised windows kept {top}px from the top, {bottom}px from the bottom")
    return d


def dbus(*args):
    return subprocess.run(["dbus-send", "--session", "--print-reply", *args],
                          capture_output=True, text=True)


def plasma_running():
    r = dbus("--dest=org.freedesktop.DBus", "/org/freedesktop/DBus",
             "org.freedesktop.DBus.NameHasOwner", "string:org.kde.plasmashell")
    return "boolean true" in r.stdout


def corner_inset(radius, panel_px):
    """How far in from the side the rounded corner cuts, measured a quarter of the
    way up the panel (where the icons start). Physical px."""
    import math
    y = radius - panel_px * 0.25          # distance from corner centre, vertically
    if y <= 0:
        return 0
    return max(0.0, radius - math.sqrt(max(0.0, radius * radius - y * y)))


STAMP = os.path.expanduser("~/.config/.titan_panel_applied")


def script_version():
    """A fingerprint of this file: any change to the panel logic re-applies the panel
    (non-destructively when it is already ours), no manual version bump needed."""
    import hashlib
    try:
        with open(__file__, "rb") as f:
            return hashlib.md5(f.read()).hexdigest()[:8]
    except OSError:
        return "v0"


def launcher_js(conf):
    """The launcherConfig() JS function (and the values it needs) for the current config."""
    scale = float(conf["DISPLAY_SCALE"])
    full = round(int(conf["SCREEN_W"]) / scale)
    popup_h = round(int(conf.get("SCREEN_H", "1200")) / scale) - int(conf.get("PANEL_HEIGHT", "52")) - 60
    want = conf.get("LAUNCHER", "kickoff")
    have_drawer = os.path.isdir(os.path.expanduser("~/.local/share/plasma/plasmoids/p-connor.plasma-drawer"))
    have_dash = os.path.isdir("/usr/share/plasma/plasmoids/org.kde.plasma.kickerdash")
    launcher = ("p-connor.plasma-drawer" if want == "drawer" and have_drawer else
                "org.kde.plasma.kickerdash" if want == "dashboard" and have_dash else
                "org.kde.plasma.kickoff")
    drawer_cfg = 'w.writeConfig("disableAnimations", true);'
    js = f"""
function launcherConfig(l) {{
    l.currentConfigGroup = ["General"];
    // Write a setting only when it actually differs; reload the launcher only if
    // something was written. Otherwise Kickoff is left alone on every boot.
    var n = 0;
    function setIf(k, v) {{
        var cur = String(l.readConfig(k, "\\u0000"));
        if (cur != String(v)) {{ l.writeConfig(k, v); n++; }}
    }}
    if (l.type == "p-connor.plasma-drawer") {{ setIf("disableAnimations", true); if (n) out.push("drawer settings written"); return; }}
    setIf("icon", "start-here-kde-plasma");
    setIf("applicationsDisplay", 0);
    setIf("favoritesDisplay", 0);
    setIf("compactMode", false);
    setIf("showActionButtonCaptions", false);
    setIf("primaryActions", 3);
    setIf("systemFavorites", "lock-screen,logout");
    setIf("alphaSort", true);
    setIf("pin", false);
    setIf("popupWidth", {full - 60});
    setIf("popupHeight", {popup_h});
    if (n) {{
        try {{ l.reloadConfig(); }} catch (e) {{ out.push("launcher reload: " + e); }}
        out.push("launcher " + l.type + ": " + n + " settings written");
    }}
}}
var LAUNCHERS = ["org.kde.plasma.kickoff", "org.kde.plasma.kickerdash", "p-connor.plasma-drawer"];
"""
    return js, launcher


def apply_launcher_only(conf):
    js, _ = launcher_js(conf)
    script = js + """
var out = [];
panels().forEach(function (p) {{ p.widgets().forEach(function (w) {{ if (LAUNCHERS.indexOf(w.type) >= 0) launcherConfig(w); }}); }});
print(out.join("; "));
""".replace("{{", "{").replace("}}", "}")
    r = dbus("--dest=org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell.evaluateScript", f"string:{script}")
    log(f"launcher settings re-applied; rc={r.returncode} out={r.stdout.strip()[-200:]}")


def fit_panel(conf):
    # Apply our panel layout once. Afterwards the panel is yours: edits made in
    # Plasma are kept. It is only re-applied when you change a panel setting on
    # the boot command line (scale, corners, height, hiding) or ask for a reset.
    key = "|".join(conf.get(k, "") for k in
                   ("DISPLAY_SCALE", "CORNER_RADIUS", "PANEL_HEIGHT", "PANEL_HIDING", "CORNER_PAD", "LAUNCHER")) + "|" + script_version()
    try:
        with open(STAMP) as f:
            if f.read().strip() == key:
                log("panel already set up; keeping your layout as-is")
                apply_launcher_only(conf)
                if os.path.exists("/tmp/titan_plasma_restart"):
                    os.remove("/tmp/titan_plasma_restart")
                    log("restart requested (patched widget); restarting plasmashell once")
                    subprocess.Popen(["plasmashell", "--replace"], start_new_session=True,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return
    except OSError:
        pass
    for _ in range(120):
        if plasma_running():
            break
        time.sleep(1)
    else:
        log("plasmashell never appeared; panel unchanged")
        return
    time.sleep(3)  # let the panels finish loading
    scale = float(conf["DISPLAY_SCALE"])
    width, radius = int(conf["SCREEN_W"]), int(conf["CORNER_RADIUS"])
    height = int(conf["PANEL_HEIGHT"])                       # logical px
    full = round(width / scale)                              # logical px
    popup_h = round(int(conf.get("SCREEN_H", "1200")) / scale) - int(conf.get("PANEL_HEIGHT", "52")) - 60
    spacer = round((corner_inset(radius, height * scale) + 6) / scale) + int(conf.get("CORNER_PAD", "16"))
    hiding = conf.get("PANEL_HIDING", "dodgewindows")
    # Application Dashboard comes from plasma-widgets-addons (boot_desktop.sh installs it);
    # until it is there, Kickoff is set up as a grid of large icons.
    have_dash = "true" if os.path.isdir("/usr/share/plasma/plasmoids/org.kde.plasma.kickerdash") else "false"
    rebuild = "true" if os.path.exists("/tmp/titan_panel_rebuild") else "false"
    if rebuild == "true":
        log("full panel rebuild requested (RESET_PANEL=1)")
    # Every property in its own try: Plasma versions differ in what they support.
    # Touch layout, rebuilt from scratch:
    #   [corner][launcher][tasks ......][expanding][system tray][clock][corner]
    # Fixed corner spacers keep everything inside the rounded corners; the expanding
    # spacer pushes the tray and clock to the right and leaves a clean tap area.
    launcher_fn, launcher = launcher_js(conf)
    script = launcher_fn + f"""
var out = [];
function set(o, k, v) {{ try {{ o[k] = v; }} catch (e) {{ out.push(k + ": " + e); }} }}
function ours(w) {{ w.currentConfigGroup = ["General"]; return w.type == "org.kde.plasma.panelspacer" && String(w.readConfig("titanCorner", "")) == "true"; }}
// Only load what is useful here. (The media controller keeps trying to reach
// PipeWire, which does not exist in the chroot.)
function trayConfig(s) {{
    s.currentConfigGroup = ["General"];
    s.writeConfig("scaleIconsToFit", true);   // one row, sized from the panel like the task icons
    s.writeConfig("extraItems", ["org.kde.plasma.volume", "org.kde.plasma.notifications", "org.kde.plasma.clipboard", "org.kde.plasma.devicenotifier"]);
    s.writeConfig("knownItems", ["org.kde.plasma.volume", "org.kde.plasma.notifications", "org.kde.plasma.clipboard", "org.kde.plasma.devicenotifier"]);
    s.writeConfig("hiddenItems", ["org.kde.plasma.clipboard", "org.kde.plasma.devicenotifier"]);
}}
// A panel we built before: only resize it and its corner spacers, keep every
// widget the user added or pinned since.
var mine = {rebuild} ? [] : panels().filter(function (p) {{ return p.location == "bottom" && p.widgets().filter(ours).length == 2; }});
if (mine.length) {{
    mine.forEach(function (p) {{
        set(p, "floating", false); set(p, "opacity", "opaque"); set(p, "height", {height}); set(p, "lengthMode", "fill");
        set(p, "maximumLength", {full}); set(p, "minimumLength", {full});
        set(p, "hiding", "{hiding}"); if (p.hiding != "{hiding}") set(p, "hiding", "autohide");
        p.widgets().filter(ours).forEach(function (w) {{ w.writeConfig("length", {spacer}); }});
        // Launcher -> Application Dashboard, and the lock/logout buttons if missing.
        // Positions come from the current visual order: launcher slot = right after the
        // first corner spacer; lock/logout = right before the last corner spacer.
        p.currentConfigGroup = ["General"];
        var order = String(p.readConfig("AppletOrder", "")).split(";").filter(function (x) {{ return x != ""; }});
        var ids = p.widgets().map(function (w) {{ return String(w.id); }});
        order = order.filter(function (x) {{ return ids.indexOf(x) >= 0; }});
        ids.forEach(function (x) {{ if (order.indexOf(x) < 0) order.push(x); }});
        var corners = p.widgets().filter(ours).map(function (w) {{ return String(w.id); }});
        corners.sort(function (a, b) {{ return order.indexOf(a) - order.indexOf(b); }});   // left corner first
        var changed = false, structural = false;   // structural = widgets added/removed/swapped: needs a restart
        p.widgets().forEach(function (w) {{ if (LAUNCHERS.indexOf(w.type) >= 0) launcherConfig(w); }});
        p.widgets().forEach(function (w) {{
            if (LAUNCHERS.indexOf(w.type) >= 0 && w.type != "{launcher}") {{
                var d = p.addWidget("{launcher}");
                launcherConfig(d);
                var i = order.indexOf(String(w.id));
                if (i >= 0) order[i] = String(d.id); else order.splice(order.indexOf(corners[0]) + 1, 0, String(d.id));
                w.remove(); changed = true; structural = true;
            }}
        }});
        p.widgets().forEach(function (w) {{ if (w.type == "org.titan.session") {{ w.remove(); changed = true; structural = true; }} }});
        // Keep the fixed widgets in their places:
        // launcher right after the first corner spacer, lock/logout right before the last one.
        function moveTo(id, index) {{ var i = order.indexOf(id); if (i < 0 || i == index) return; order.splice(i, 1); if (i < index) index--; order.splice(index, 0, id); changed = true; }}
        if (corners.length == 2) {{ moveTo(corners[0], 0); moveTo(corners[1], order.length - 1); }}
        p.widgets().forEach(function (w) {{
            if (LAUNCHERS.indexOf(w.type) >= 0) moveTo(String(w.id), corners.length ? order.indexOf(corners[0]) + 1 : 0);
        }});
        var alive = p.widgets().map(function (w) {{ return String(w.id); }});
        order = order.filter(function (x) {{ return alive.indexOf(x) >= 0; }});
        // Order fixes are written quietly (they apply at the next start); only a
        // structural change is worth a Plasma restart now.
        if (changed) {{ p.currentConfigGroup = ["General"]; p.writeConfig("AppletOrder", order.join(";")); }}
        if (structural) out.push("ORDER_CHANGED");
        p.widgets().forEach(function (w) {{
            if (w.type == "org.kde.plasma.systemtray") trayConfig(w);
            if (w.type == "org.kde.plasma.digitalclock") {{ w.currentConfigGroup = ["Appearance"]; w.writeConfig("autoFontAndSize", false); w.writeConfig("fontSize", 16); }}
        }});
        out.push("panel@" + p.location + " adjusted in place, widgets kept");
    }});
    print(out.join("; "));
}} else {{
function corner(p) {{
    var w = p.addWidget("org.kde.plasma.panelspacer");
    w.currentConfigGroup = ["General"];
    w.writeConfig("expanding", false); w.writeConfig("length", {spacer}); w.writeConfig("titanCorner", "true");
}}
var bottoms = panels().filter(function (p) {{ return p.location == "bottom"; }});
if (bottoms.length == 0) {{ var np = new Panel; np.location = "bottom"; bottoms = [np]; }}
bottoms.forEach(function (p, i) {{
    if (i > 0) {{ p.remove(); return; }}
    p.widgets().forEach(function (w) {{ w.remove(); }});
    set(p, "floating", false);
    set(p, "opacity", "opaque");
    set(p, "height", {height});
    set(p, "lengthMode", "fill");
    set(p, "alignment", "center");
    set(p, "offset", 0);
    set(p, "maximumLength", {full});
    set(p, "minimumLength", {full});
    set(p, "hiding", "{hiding}");
    if (p.hiding != "{hiding}") set(p, "hiding", "autohide");
    corner(p);
    var launcher = p.addWidget("{launcher}");
    launcherConfig(launcher);
    var t = p.addWidget("org.kde.plasma.icontasks");
    t.currentConfigGroup = ["General"];
    t.writeConfig("iconSpacing", 1);
    t.writeConfig("showOnlyCurrentDesktop", false);
    // Only two pinned launchers on a 4" panel; running apps show up as they open.
    t.writeConfig("launchers", ["preferred://browser", "preferred://filemanager", "applications:org.kde.konsole.desktop"]);
    var x = p.addWidget("org.kde.plasma.panelspacer");
    x.currentConfigGroup = ["General"]; x.writeConfig("expanding", true);
    var s = p.addWidget("org.kde.plasma.systemtray");
    // Keep the tray to what matters here; the rest stays behind its arrow.
    trayConfig(s);
    try {{ p.addWidget("org.titan.phonestatus"); }} catch (e) {{ out.push("phonestatus: " + e); }}
    // Compact 24-hour clock in a fixed, readable size instead of one that fills the panel.
    var c = p.addWidget("org.kde.plasma.digitalclock");
    c.currentConfigGroup = ["Appearance"];
    c.writeConfig("showDate", false);
    c.writeConfig("use24hFormat", 2);
    c.writeConfig("autoFontAndSize", false);
    c.writeConfig("fontSize", 16);
    corner(p);
    out.push("panel@" + p.location + " hiding=" + p.hiding + " widgets=" + p.widgets().length);
}});
// The desktop's own top panel, if any, is not wanted on a 4" screen.
panels().forEach(function (p) {{ if (p.location == "top") p.remove(); }});
print(out.join("; "));
}}
"""
    r = dbus("--dest=org.kde.plasmashell", "/PlasmaShell",
             "org.kde.PlasmaShell.evaluateScript", f"string:{script}")
    log(f"panel -> full width {full}, spacers {spacer}, height {height} (logical px), "
        f"hiding {hiding}; rc={r.returncode} out={r.stdout.strip()} err={r.stderr.strip()}")
    if r.returncode == 0:
        with open(STAMP, "w") as f:
            f.write(key + "\n")
        try:
            os.remove("/tmp/titan_panel_rebuild")
        except OSError:
            pass
    if os.path.exists("/tmp/titan_plasma_restart"):
        try:
            os.remove("/tmp/titan_plasma_restart")
        except OSError:
            pass
        log("restart requested (patched widget); restarting plasmashell once")
        subprocess.Popen(["plasmashell", "--replace"], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    elif "ORDER_CHANGED" in r.stdout:
        # Widget order is only read when Plasma loads; one restart to apply it.
        log("widget order changed; restarting plasmashell once")
        subprocess.Popen(["plasmashell", "--replace"], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def battery_percentage():
    """Leave the charge percentage to the Phone widget, not Plasma's battery widget.

    The two sit side by side in the panel. Plasma's draws the battery icon; the Phone
    widget shows the number, because that one comes from Android itself (dumpsys
    battery) rather than from what Plasma can read inside the chroot. So Plasma's copy
    of the percentage is turned off here to avoid showing it twice.

    That widget lives inside the system tray, which the panel script cannot reach, so
    the setting is written straight into the applet config file. Its group path is not
    fixed - the containment and applet numbers differ per machine - so the file is read
    to find the applet whose plugin is org.kde.plasma.battery, and its own group is
    then written with kwriteconfig6. Best effort: a missing widget is not an error."""
    cfg = os.path.expanduser("~/.config/plasma-org.kde.plasma.desktop-appletsrc")
    try:
        with open(cfg, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        log("battery percentage: no applet config yet, skipped")
        return
    group, found = None, None
    for line in lines:
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            group = s
        elif s == "plugin=org.kde.plasma.battery" and group:
            found = group
            break
    if not found:
        log("battery percentage: Plasma's battery widget not in the tray, nothing to change")
        return
    # "[Containments][2][Applets][14]" -> the arguments kwriteconfig6 wants
    parts = re.findall(r"\[([^\]]+)\]", found)
    args = []
    for seg in parts + ["Configuration", "General"]:
        args += ["--group", seg]
    r = subprocess.run(["kwriteconfig6", "--file", cfg, *args, "--key", "showPercentage", "false"],
                       capture_output=True, text=True)
    if r.returncode == 0:
        log(f"battery percentage left to the Phone widget; Plasma's shows the icon only ({found})")
    else:
        log(f"battery percentage: kwriteconfig6 failed: {r.stderr.strip()[:120]}")


def main():
    conf = load_conf()
    log(f"config: {conf}")
    d = None
    top, bottom = int(conf["TOP_RESERVE"]), int(conf.get("BOTTOM_RESERVE", "0"))
    if top > 0 or bottom > 0:
        try:
            d = reserve_space(top, bottom)
        except Exception as ex:
            log(f"space reservation failed: {ex}")

    fit_panel(conf)
    try:
        battery_percentage()
    except Exception as ex:
        log(f"battery percentage failed: {ex}")
    if d is not None:
        while True:          # keep the reservation alive for the session
            d.next_event()


if __name__ == "__main__":
    try:
        main()
    except Exception as ex:
        log(f"fatal: {ex!r}")
        sys.exit(1)
