#!/usr/bin/env python3
"""
Copyright (C) 2026 Flux-Sniffer-Mods. Licensed under GPL-3.0-or-later;
see the LICENSE file or <https://www.gnu.org/licenses/>. No warranty.

Part of: Titan 2 Elite Debian Chroot - a full Debian/KDE desktop running
alongside Android on a Unihertz Titan 2 Elite phone.
Copies Linux notifications into the Android notification shade.

New to this project? Read README.md first, it explains the whole setup:
https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Debian-Chroot

titan_notify_bridge.py - forwards Plasma notifications to Android (KDE autostart).

Listens to every org.freedesktop.Notifications.Notify call on the session bus
(via dbus-monitor) and appends one line per notification to /tmp/titan_notify.queue:
    tag <TAB> title <TAB> body <TAB> app <TAB> progress (0-100, or empty)
boot_desktop.sh watches that file from the Android side and posts each line as an
Android notification. Plasma itself is put in Do Not Disturb by boot_desktop.sh,
so nothing shows twice.
"""
import re
import subprocess
import sys
import time

QUEUE = "/tmp/titan_notify.queue"
STRING = re.compile(r'^\s+string "(.*)"$')
UINT = re.compile(r'^\s+uint32 (\d+)$')


def unescape(s):
    return s.encode("utf-8").decode("unicode_escape", errors="replace").encode("latin-1", errors="replace").decode("utf-8", errors="replace")


def clean(s):
    s = re.sub(r"<[^>]+>", "", s)                  # notifications may carry basic HTML
    return s.replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def icon_is_phone(icon):
    return icon.strip() == "phone"


def write(tag, title, body, app, progress):
    with open(QUEUE, "a") as f:
        f.write(f"{tag}\t{title}\t{body}\t{app}\t{progress}\n")


def main():
    counter = int(time.time()) % 100000
    proc = subprocess.Popen(
        ["dbus-monitor", "--session", "interface='org.freedesktop.Notifications',member='Notify'"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors="replace")
    fields = None          # collecting app, replaces_id, icon, summary, body
    pending = None         # [tag, title, body, app, progress] waiting for its hints
    want_value = False
    for line in proc.stdout:
        if "member=Notify" in line and "method call" in line:
            if pending:
                write(*pending)
            fields, pending, want_value = [], None, False
            continue
        if pending is not None:
            # Hints block: 'string "value"' is followed by 'variant int32 N' (a progress bar).
            if 'string "value"' in line:
                want_value = True
            elif want_value:
                m = re.search(r"int32 (-?\d+)", line)
                if m:
                    pending[4] = str(max(0, min(100, int(m.group(1)))))
                    want_value = False
            continue
        if fields is None:
            continue
        m = STRING.match(line) or UINT.match(line)
        if m:
            fields.append(m.group(1))
        if len(fields) == 5:
            app, rid, _icon, summary, body = fields
            fields = None
            summary, body, app = clean(unescape(summary)), clean(unescape(body)), clean(unescape(app))
            if not summary and not body:
                continue
            if icon_is_phone(_icon):                   # came from Android in the first place
                continue
            if rid.isdigit() and int(rid) > 0:      # updates replace the same Android notification
                tag = f"{app or 'linux'}-{rid}"
            else:
                counter += 1
                tag = f"linux-{counter}"
            pending = [tag, summary or app, body, app, ""]
    if pending:
        write(*pending)
    sys.exit(proc.wait())


if __name__ == "__main__":
    main()
