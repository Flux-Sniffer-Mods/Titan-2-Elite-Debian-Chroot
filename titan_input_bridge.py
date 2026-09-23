#!/usr/bin/env python3
"""
Part of: Titan 2 Elite Debian Chroot - a full Debian/KDE desktop running
alongside Android on a Unihertz Titan 2 Elite phone.
Routes the keyboard, touchscreen and volume keys between Linux and Android.

New to this project? Read README.md first, it explains the whole setup:
https://github.com/Flux-Sniffer-Mods/Titan-2-Elite-Debian-Chroot

titan_input_bridge.py - input bridge for the Titan 2 Elite (runs as root inside the
chroot, started by boot_desktop.sh).

It grabs the physical keyboard, the touchscreen and the volume rocker at the
kernel level and decides, per event, whether it belongs to the Linux desktop or to
Android.

Which way input goes depends on what is on screen (the boot script writes
/tmp/titan_route once a second):

  Desktop (Termux:X11) in front
    * Keyboard is typed straight into X via XTest, so the Titan keymap (Pastiera's
      Alt/Sym layers) applies and Pastiera never sees the keys.
    * Touchscreen is taken over and turned into Android-style gestures:
        tap = click, drag = scroll (flicks glide), long-press + lift = right click,
        long-press + drag = mouse drag, two-finger drag = scroll,
        two-finger tap = right click.
      Touches near an edge snap the pointer to that edge (reveals the panel).
  Any Android app in front (or the route file is stale)
    * Keyboard goes to Android through an exact clone of the Titan keyboard,
      so Pastiera and the Titan's own key layout work as normal.
    * Touchscreen is left alone.

Home / app-switch / back / power always go to Android, so you can always leave.

  titan_input_bridge.py --list     show input devices and which ones are used
  titan_input_bridge.py --debug    print raw key codes WITHOUT grabbing
"""
import argparse
import os
import select
import signal
import subprocess
import sys
import time

try:
    import evdev
    from evdev import UInput, ecodes as e
except ImportError:
    print("ERROR: python3-evdev not installed (apt-get install python3-evdev)", flush=True)
    sys.exit(1)

ROUTE_FILE = "/tmp/titan_route"
CONF_FILE = "/etc/titan-display.conf"
ROUTE_MAX_AGE = 4.0                     # seconds; stale route file => Android
SYM_CODE = 253                          # Titan Sym key (no standard name)
# Physical code -> X key. Sym becomes Right Alt (253+8 is beyond X's 255 keycode
# limit); the Titan's Ctrl keys report non-standard codes and become Left Ctrl.
X_KEY_REMAP = {SYM_CODE: e.KEY_RIGHTALT, 65: e.KEY_LEFTCTRL, 151: e.KEY_LEFTCTRL, 251: e.KEY_LEFTCTRL}
ANDROID_ALWAYS = {e.KEY_HOME, e.KEY_BACK, e.KEY_APPSELECT, e.KEY_POWER,
                  e.KEY_VOLUMEUP, e.KEY_VOLUMEDOWN, e.KEY_MENU, e.KEY_SEARCH}

LETTERS = set(range(e.KEY_Q, e.KEY_P + 1)) | set(range(e.KEY_A, e.KEY_L + 1)) | set(range(e.KEY_Z, e.KEY_M + 1))
NAME_HINTS = ("pastiera", "titan", "aw9523", "keypad", "keyboard")
UINPUT_ERR = getattr(evdev, "UInputError", OSError)


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def load_conf():
    conf = {"TOUCH_GESTURES": "1", "LONGPRESS_MS": "500"}
    try:
        with open(CONF_FILE) as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    conf[k] = v
    except OSError:
        pass
    return conf


# ----------------------------------------------------------------- devices
def is_virtual(dev):
    node = os.path.basename(dev.path)
    return "/virtual/" in os.path.realpath(f"/sys/class/input/{node}/device")


def kbd_score(dev):
    if is_virtual(dev):
        return -1
    keys = set(dev.capabilities().get(e.EV_KEY, []))
    if len(keys & LETTERS) < 20:
        return -1
    return len(keys & LETTERS) + (10 if any(h in dev.name.lower() for h in NAME_HINTS) else 0)


def is_touchscreen(dev):
    if is_virtual(dev):
        return False
    abs_codes = [c for c, _ in dev.capabilities().get(e.EV_ABS, [])]
    return (e.ABS_MT_POSITION_X in abs_codes and e.ABS_MT_POSITION_Y in abs_codes
            and e.INPUT_PROP_DIRECT in dev.input_props())


def is_volume_keys(dev):
    """Any device that can send the volume keys (rocker, PMIC keys, headset jack):
    not our keyboard, not virtual. Each is cloned so everything else it sends
    (Power, headset buttons) still reaches Android."""
    if is_virtual(dev):
        return False
    keys = set(dev.capabilities().get(e.EV_KEY, []))
    return (e.KEY_VOLUMEUP in keys or e.KEY_VOLUMEDOWN in keys) and len(keys & LETTERS) < 20


def open_all():
    devs = []
    for path in evdev.list_devices():
        try:
            devs.append(evdev.InputDevice(path))
        except OSError as ex:
            log(f"cannot open {path}: {ex}")
    return devs


def find_devices():
    """Wait for the keyboard; the touchscreen is optional."""
    while True:
        if not os.path.isdir("/dev/input") or not os.listdir("/dev/input"):
            log("ERROR: /dev/input is empty inside the chroot (is it bind-mounted?)")
        else:
            devs = open_all()
            kbds = sorted((d for d in devs if kbd_score(d) > 0), key=kbd_score, reverse=True)
            touch = next((d for d in devs if is_touchscreen(d)), None)
            vol = [d for d in devs if is_volume_keys(d) and d.path != kbds[0].path] if kbds else []
            if kbds:
                return kbds[0], touch, vol
            log("No QWERTY keyboard found yet (try --list). Retrying...")
        time.sleep(2)


def make_native_clone(phys):
    """Exact identity + capabilities of the real keyboard, so Android uses its own
    key layout / character map (Pastiera, Alt/Sym, Home, touch-scroll)."""
    info = phys.info
    ident = dict(name=phys.name, vendor=info.vendor, product=info.product,
                 version=info.version, bustype=info.bustype, phys=phys.phys or "")
    skip = (e.EV_SYN, e.EV_FF, e.EV_REP)
    for _ in range(20):
        try:
            try:
                return UInput.from_device(phys, filtered_types=skip, input_props=phys.input_props(), **ident)
            except TypeError:
                return UInput.from_device(phys, filtered_types=skip, **ident)
        except (OSError, UINPUT_ERR) as ex:
            log(f"ERROR: cannot create uinput device ({ex}); is /dev/uinput in the chroot?")
            time.sleep(2)
    sys.exit(1)


# ----------------------------------------------------------------- session helpers
def desktop_user():
    try:
        with open("/etc/passwd") as f:
            for line in f:
                p = line.split(":")
                if len(p) > 3 and p[2] == "1000":
                    return p[0]
    except OSError:
        pass
    return "root"


def session_env():
    """DISPLAY + DBUS_SESSION_BUS_ADDRESS of the user's plasmashell, or ''."""
    try:
        pids = subprocess.run(["pgrep", "-x", "plasmashell"], capture_output=True, text=True).stdout.split()
        for pid in pids:
            with open(f"/proc/{pid}/environ", "rb") as f:
                for item in f.read().split(b"\0"):
                    if item.startswith(b"DBUS_SESSION_BUS_ADDRESS="):
                        addr = item.split(b"=", 1)[1].decode()
                        return f"DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS='{addr}'"
    except OSError:
        pass
    return ""


# ----------------------------------------------------------------- X side
class XInjector:
    """Types and clicks into the X server with XTest. Connects lazily."""

    def __init__(self):
        self.d = None
        self.next_try = 0.0
        self.width = self.height = 0

    def ready(self):
        if self.d is not None:
            return True
        if time.time() < self.next_try:
            return False
        self.next_try = time.time() + 3
        try:
            from Xlib import display
            d = display.Display(os.environ.get("DISPLAY", ":0"))
            if not d.has_extension("XTEST"):
                log("X server has no XTEST extension; keys stay on the Android path")
                return False
            scr = d.screen()
            self.d, self.width, self.height = d, scr.width_in_pixels, scr.height_in_pixels
            log(f"connected to X ({self.width}x{self.height})")
            return True
        except Exception as ex:
            if not getattr(self, "_warned", False):
                log(f"X not reachable yet ({ex}); will keep trying")
                self._warned = True
            return False

    def _fake(self, *args, **kw):
        from Xlib.ext import xtest
        try:
            xtest.fake_input(self.d, *args, **kw)
            self.d.flush()
            return True
        except Exception as ex:
            log(f"lost X connection ({ex})")
            self.d = None
            return False

    def key(self, code, down):
        from Xlib import X
        return self._fake(X.KeyPress if down else X.KeyRelease, code + 8)

    def move(self, x, y):
        from Xlib import X
        return self._fake(X.MotionNotify, x=int(x), y=int(y))

    def button(self, b, down):
        from Xlib import X
        return self._fake(X.ButtonPress if down else X.ButtonRelease, b)

    def click(self, b):
        self.button(b, True)
        self.button(b, False)

    def active_is_fullscreen(self):
        try:
            root = self.d.screen().root
            aw = root.get_full_property(self.d.intern_atom("_NET_ACTIVE_WINDOW"), 0)
            if not aw or not aw.value:
                return False
            win = self.d.create_resource_object("window", aw.value[0])
            st = win.get_full_property(self.d.intern_atom("_NET_WM_STATE"), 0)
            return bool(st) and self.d.intern_atom("_NET_WM_STATE_FULLSCREEN") in list(st.value)
        except Exception as ex:
            log(f"fullscreen check failed: {ex}")
            return False

    def leave_fullscreen(self):
        """Swipe-up from the bottom: if the active window is full-screen, toggle it
        off through KWin's 'Window Fullscreen' action, so the panel comes back."""
        if not self.active_is_fullscreen():
            return
        env = session_env()
        if not env:
            log("no Plasma session bus found; cannot toggle full-screen")
            return
        cmd = (f"{env} dbus-send --session --dest=org.kde.kglobalaccel /component/kwin "
               "org.kde.kglobalaccel.Component.invokeShortcut string:'Window Fullscreen'")
        subprocess.Popen(["su", desktop_user(), "-c", cmd],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log("bottom-edge swipe: left full-screen")


# ----------------------------------------------------------------- touch gestures
class TouchGestures:
    """Android-style touch on top of the X pointer:
         tap                      -> left click
         drag                     -> scroll (content follows the finger; flicks glide)
         long-press, then lift    -> right click
         long-press, then drag    -> left-button drag (select text, move windows)
         two-finger drag          -> scroll
         two-finger tap           -> right click
       Touches near an edge snap the pointer to that edge (reveals the panel)."""
    MOVE_PX = 22           # finger travel (physical px) before a touch counts as moving
    STILL_PX = 8           # more than this before the long-press timer fires = not a long-press
    TWO_TAP_MS = 300       # max duration of a two-finger tap
    EDGE_PX = 14           # touches this close to a side/top edge snap to it
    BOTTOM_PX = 40         # touches this close to the bottom edge count as "on the edge" (panel)
    EDGE_SWIPE_PX = 90     # upward travel from the bottom edge that counts as "swipe up"
    EDGE_HOLD_S = 0.7      # keep the pointer pressed against the edge this long after lift
    FLING_MIN = 700        # px/s needed at lift-off to start gliding
    FLING_DECAY = 0.94     # speed kept per 16 ms while gliding

    def __init__(self, dev, x, longpress_ms, scroll_px=36):
        self.dev, self.x = dev, x
        self.long_s = longpress_ms / 1000.0
        self.scroll_px = max(8, scroll_px)
        ax, ay = dev.absinfo(e.ABS_MT_POSITION_X), dev.absinfo(e.ABS_MT_POSITION_Y)
        self.ax, self.ay = (ax.min, ax.max), (ay.min, ay.max)
        self.grabbed = False
        self.slot = 0
        self.pos = {}            # slot -> [raw_x, raw_y]  (kept: the kernel omits unchanged values)
        self.active = set()      # slots with a finger down
        self.fling = None        # [vx, vy, last_time] while gliding
        self.reset()

    def reset(self):
        self.state = "idle"      # idle | pending | scroll | drag | two | edge | done
        self.t0 = 0.0
        self.start = (0, 0)
        self.held = False        # long-press time reached
        self.last = None         # last finger / centroid position while scrolling
        self.acc = [0.0, 0.0]    # scroll distance not yet sent as notches
        self.axis = None         # one-finger scroll is locked to one axis
        self.samples = []        # (time, x, y) for fling speed
        self.scrolled = False
        self.edge_hold = 0.0     # keep nudging the pointer at the bottom edge until this time
        self.edge_x = 0
        self.wobbled = False     # finger moved (a little) before the long-press timer: not a long-press

    # -- grab management
    def set_active(self, active):
        if active and not self.grabbed:
            try:
                self.dev.grab()
                self.grabbed = True
                self.active.clear()
                self.fling = None
                self.reset()
                log("touchscreen: desktop gestures on")
            except OSError as ex:
                log(f"touchscreen grab failed: {ex}")
        elif not active and self.grabbed:
            self.release_all()
            try:
                self.dev.ungrab()
            except OSError:
                pass
            self.grabbed = False
            log("touchscreen: back to Android")

    def release_all(self):
        if self.state == "drag" and self.x.d is not None:
            self.x.button(1, False)
        self.fling = None
        self.reset()

    # -- coordinates
    def to_screen(self, rx, ry):
        w, h = self.x.width or 1080, self.x.height or 1200
        x = (rx - self.ax[0]) * (w - 1) / max(1, self.ax[1] - self.ax[0])
        y = (ry - self.ay[0]) * (h - 1) / max(1, self.ay[1] - self.ay[0])
        if x < self.EDGE_PX: x = 0
        if y < self.EDGE_PX: y = 0
        if x > w - 1 - self.EDGE_PX: x = w - 1
        if y > h - 1 - self.BOTTOM_PX: y = h - 1
        return [x, y]

    # -- raw events
    def handle(self, ev):
        if ev.type == e.EV_ABS:
            if ev.code == e.ABS_MT_SLOT:
                self.slot = ev.value
            elif ev.code == e.ABS_MT_TRACKING_ID:
                if ev.value < 0:
                    self.active.discard(self.slot)
                else:
                    self.active.add(self.slot)
            elif ev.code == e.ABS_MT_POSITION_X:
                self.pos.setdefault(self.slot, [None, None])[0] = ev.value
            elif ev.code == e.ABS_MT_POSITION_Y:
                self.pos.setdefault(self.slot, [None, None])[1] = ev.value
        elif ev.type == e.EV_SYN and ev.code == e.SYN_REPORT:
            self.frame()

    def points(self):
        pts = []
        for slot in sorted(self.active):
            raw = self.pos.get(slot)
            if raw and None not in raw:
                pts.append(self.to_screen(*raw))
        return pts

    # -- gesture state machine (runs once per touch frame)
    def frame(self, now=None):
        pts = self.points()
        n = len(pts)
        now = time.time() if now is None else now
        if self.state == "idle":
            if n >= 1:
                self.fling = None                        # a new touch stops any glide
            if n == 1:
                self.state, self.t0, self.start = "pending", now, tuple(pts[0])
                self.x.move(*pts[0])
                if pts[0][1] >= (self.x.height or 1200) - 1:
                    # On the bottom edge: this is a panel gesture, never a click/scroll.
                    self.state, self.edge_x = "edge", pts[0][0]
            elif n >= 2:
                self.begin_two(pts, now)
        elif self.state == "edge":
            # Bottom-edge gesture: the pointer is pressed against the edge (which is
            # what reveals a hidden panel) and kept there a moment after the finger
            # lifts; a clear upward swipe also leaves full-screen.
            if n == 0:
                hold, ex = now + self.EDGE_HOLD_S, self.start[0]
                self.reset()
                self.edge_hold, self.edge_x = hold, ex
            elif self.start[1] - pts[0][1] > self.EDGE_SWIPE_PX:
                self.x.leave_fullscreen()
                self.state = "done"
        elif self.state == "done":
            if n == 0:
                self.reset()
        elif self.state == "pending":
            if n == 0:
                self.x.move(*self.start)
                self.x.click(3 if self.held else 1)      # long-press + lift = right click
                log(f"gesture: {'long-press' if self.held else 'tap'} at {int(self.start[0])},{int(self.start[1])}")
                self.reset()
            elif n >= 2:
                self.begin_two(pts, now)
            elif not self.held and self.dist(pts[0], self.start) > self.STILL_PX:
                self.wobbled = True                       # a slow scroll start is not a long-press
                if self.dist(pts[0], self.start) > self.MOVE_PX:
                    self.begin_scroll(pts[0], now)
            elif self.dist(pts[0], self.start) > self.MOVE_PX:
                if self.held:                            # long-press + move = drag
                    self.state = "drag"
                    log(f"gesture: drag (after long-press) from {int(self.start[0])},{int(self.start[1])}")
                    self.x.move(*self.start)
                    self.x.button(1, True)
                    self.x.move(*pts[0])
                else:                                    # plain move = scroll
                    self.begin_scroll(pts[0], now)
        elif self.state == "scroll":
            if n == 0:
                self.start_fling(now)
                self.reset()
            elif n >= 2:
                self.begin_two(pts, now)
            else:
                self.scroll_to(pts[0], now)
        elif self.state == "drag":
            if n == 0:
                self.x.button(1, False)
                self.reset()
            else:
                self.x.move(*pts[0])
        elif self.state == "two":
            if n == 0:
                if not self.scrolled and now - self.t0 < self.TWO_TAP_MS / 1000:
                    self.x.click(3)                     # two-finger tap = right click
                self.reset()
            elif n >= 2:
                c = self.centroid(pts)
                self.scroll_by(c[0] - self.last[0], c[1] - self.last[1])
                self.last = c

    def begin_scroll(self, p, now):
        self.state = "scroll"
        log(f"gesture: scroll from {int(self.start[0])},{int(self.start[1])}")
        self.x.move(*self.start)                         # scroll the window under the finger
        dx, dy = p[0] - self.start[0], p[1] - self.start[1]
        self.axis = "y" if abs(dy) >= abs(dx) else "x"
        self.last = list(self.start)
        self.samples = [(now, *self.start)]
        self.scroll_to(p, now)

    def tick(self, now=None):
        """Called about every 50 ms: long-press timer, fling gliding, edge dwell."""
        now = time.time() if now is None else now
        if self.state == "edge" or now < self.edge_hold:
            # KWin only counts an edge as "hit" while the pointer keeps arriving at it,
            # so a single move is not enough: keep it moving along the edge line.
            h = (self.x.height or 1200) - 1
            self.edge_x = self.edge_x + (1 if int(now * 20) % 2 else -1)
            self.x.move(self.edge_x, h)
        if self.state == "pending" and not self.held and not self.wobbled and now - self.t0 >= self.long_s:
            self.held = True
        if self.fling is not None:
            vx, vy, t = self.fling
            dt = now - t
            if dt <= 0:
                return
            self.scroll_by(vx * dt, vy * dt)
            k = self.FLING_DECAY ** (dt / 0.016)
            vx, vy = vx * k, vy * k
            self.fling = None if max(abs(vx), abs(vy)) < 150 else [vx, vy, now]

    # -- scrolling helpers
    def scroll_to(self, p, now):
        dx, dy = p[0] - self.last[0], p[1] - self.last[1]
        if self.axis == "y":
            dx = 0
        else:
            dy = 0
        self.scroll_by(dx, dy)
        self.last = list(p)
        self.samples.append((now, p[0], p[1]))
        self.samples = [s for s in self.samples if now - s[0] <= 0.1]

    def start_fling(self, now):
        if len(self.samples) < 2:
            return
        (t0, x0, y0), (t1, x1, y1) = self.samples[0], self.samples[-1]
        if now - t1 > 0.08 or t1 - t0 < 0.01:           # finger stopped before lifting
            return
        vx, vy = (x1 - x0) / (t1 - t0), (y1 - y0) / (t1 - t0)
        if self.axis == "y":
            vx = 0
        else:
            vy = 0
        if max(abs(vx), abs(vy)) >= self.FLING_MIN:
            self.fling = [vx, vy, now]
            self.acc = [0.0, 0.0]

    def scroll_by(self, dx, dy):
        # Natural scrolling: content follows the finger, like Android.
        # Finger down (dy > 0) -> button 4 (scroll up); right (dx > 0) -> button 6.
        self.acc[0] += dx
        self.acc[1] += dy
        step = self.scroll_px
        while abs(self.acc[1]) >= step:
            up = self.acc[1] > 0
            self.x.click(4 if up else 5)
            self.acc[1] += -step if up else step
            self.scrolled = True
        while abs(self.acc[0]) >= step:
            right = self.acc[0] > 0
            self.x.click(6 if right else 7)
            self.acc[0] += -step if right else step
            self.scrolled = True

    def begin_two(self, pts, now):
        self.state, self.t0, self.scrolled = "two", now, False
        self.acc = [0.0, 0.0]
        self.last = self.centroid(pts)

    @staticmethod
    def centroid(pts):
        return [sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts)]

    @staticmethod
    def dist(a, b):
        return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5


# ----------------------------------------------------------------- routing
def current_route():
    try:
        if time.time() - os.path.getmtime(ROUTE_FILE) > ROUTE_MAX_AGE:
            return "android"
        with open(ROUTE_FILE) as f:
            return "x11" if f.read().strip() == "x11" else "android"
    except OSError:
        return "android"


class Bridge:
    def __init__(self, kbd, touch, conf, vol=None):
        self.kbd = kbd
        self.vols = list(vol or [])                   # rocker device(s)
        self.vol_clones = {d.fd: make_native_clone(d) for d in self.vols}
        self.vol_grabbed = False
        self.native = make_native_clone(kbd)
        self.x = XInjector()
        self.touch = None
        if touch is not None and conf.get("TOUCH_GESTURES", "1") == "1":
            self.touch = TouchGestures(touch, self.x, int(conf.get("LONGPRESS_MS", "500")),
                                       int(conf.get("SCROLL_PX", "36")))
        self.x_down = set()       # keys currently held on the X side
        self.kbd_touching, self.kbd_last_y, self.kbd_acc = False, None, 0.0
        # Keyboard touch surface: its Y range is mapped so a swipe of the whole
        # keyboard height is about 8 wheel clicks.
        try:
            ay = kbd.absinfo(getattr(e, "ABS_MT_POSITION_Y", 0x36)) if getattr(e, "ABS_MT_POSITION_Y", 0x36) in dict(kbd.capabilities().get(e.EV_ABS, [])) else kbd.absinfo(getattr(e, "ABS_Y", 1))
            span = max(1, ay.max - ay.min)
        except Exception:
            span = 1000
        self.kbd_scale = 1.0
        self.kbd_step = max(4.0, span / 8.0)
        self.route = "android"
        self.next_route_check = 0.0
        # Screenshot combo (Power + Volume Down). While the desktop is in front the
        # rocker is diverted here, so Android never sees Volume Down and its own combo
        # cannot fire; the bridge spots the pair itself and asks for the screenshot.
        self.power_down = False
        self.voldown_held = False
        self.power_swallowed = False
        self.native_dirty = False
        log(f"keyboard: {kbd.path} ({kbd.name})")
        log(f"touch: {touch.path + ' (' + touch.name + ')' if self.touch else 'not handled'}")
        log("volume keys: " + (", ".join(f"{d.path} ({d.name})" for d in self.vols) or "no device found; left to Android"))

    def update_route(self):
        now = time.time()
        if now < self.next_route_check:
            return
        self.next_route_check = now + 0.25
        want = current_route()
        if want == "x11" and not self.x.ready():
            want = "android"
        if want != self.route:
            if self.route == "x11":
                for code in list(self.x_down):   # never leave keys stuck in X
                    self.x.key(code, False)
                self.x_down.clear()
            self.route = want
            log(f"route -> {want}")
        if self.touch:
            self.touch.set_active(self.route == "x11" and self.x.d is not None)
        self.set_volume_grab(self.route == "x11")

    def set_volume_grab(self, want):
        """The rocker is grabbed once (and cloned) so Android keeps getting Power and
        everything else through the clone; only this flag decides where the volume
        keys go: to boot_desktop.sh (desktop in front) or on to Android."""
        self.vol_grabbed = want and bool(self.vols)

    def android_request(self, cmd):
        try:
            with open("/tmp/titan_android_cmd", "a") as f:
                f.write(cmd + "\n")
        except OSError as ex:
            log(f"{cmd} request failed: {ex}")

    def on_volume(self, dev, ev):
        """Every event from a rocker device, whichever app is in front."""
        clone = self.vol_clones[dev.fd]
        divert = self.vol_grabbed and ev.type == e.EV_KEY and ev.code in (e.KEY_VOLUMEUP, e.KEY_VOLUMEDOWN)
        # Power is normally passed straight through to Android. While the rocker is
        # diverted, a Power press that lands on top of a held Volume Down means the
        # screenshot combo: take the shot and swallow that press, so Android does not
        # also show the power menu. The matching release is swallowed with it.
        if ev.type == e.EV_KEY and ev.code == e.KEY_POWER:
            if ev.value == 1:
                self.power_down = True
                if self.vol_grabbed and self.voldown_held:
                    self.power_swallowed = True
                    self.android_request("screenshot")
                    return
            elif ev.value == 0:
                self.power_down = False
                if self.power_swallowed:
                    self.power_swallowed = False
                    return
            elif self.power_swallowed:
                return                                  # held: keep swallowing repeats
        if divert:
            if ev.code == e.KEY_VOLUMEDOWN:
                self.voldown_held = ev.value != 0
            if ev.value == 1:
                if ev.code == e.KEY_VOLUMEDOWN and self.power_down:
                    self.android_request("screenshot")  # Power was already held
                else:
                    self.android_request("volume_up" if ev.code == e.KEY_VOLUMEUP else "volume_down")
            return
        if ev.type == e.EV_SYN:
            clone.syn()
        else:
            clone.write(ev.type, ev.code, ev.value)      # Power etc. pass straight through

    def on_key(self, ev):
        """Everything the keyboard device sends: keys, and its touch-scroll surface."""
        code = ev.code
        # Keyboard's touch surface (the Titan keys are capacitive): while the desktop
        # is in front, sliding a finger on the keys scrolls the window under the pointer.
        if self.route == "x11" and ev.type in (e.EV_ABS, e.EV_REL):
            self.on_kbd_touch(ev)
            return
        if self.route == "x11" and ev.type == e.EV_KEY and code in (getattr(e, "BTN_TOUCH", 330), getattr(e, "BTN_TOOL_FINGER", 325)):
            self.kbd_touching = ev.value == 1
            self.kbd_last_y = None
            self.kbd_acc = 0.0
            return
        to_x = (ev.type == e.EV_KEY and code < 0x100 and code not in ANDROID_ALWAYS
                and self.route == "x11") or (ev.type == e.EV_KEY and code in self.x_down)
        if to_x:
            xcode = X_KEY_REMAP.get(code, code)
            if xcode + 8 > 255:
                to_x = False
            elif ev.value == 2:
                return                              # X does its own key repeat
            elif ev.value == 1:
                if self.x.key(xcode, True):
                    self.x_down.add(code)
                return
            else:
                self.x.key(xcode, False)
                self.x_down.discard(code)
                return
        if ev.type == e.EV_SYN:
            if ev.code == e.SYN_REPORT and self.native_dirty:
                self.native.syn()
                self.native_dirty = False
            return
        self.native.write(ev.type, ev.code, ev.value)
        self.native_dirty = True

    def on_kbd_touch(self, ev):
        """Keyboard touch surface -> wheel clicks (finger down = scroll down)."""
        if self.x.d is None:
            return
        if ev.type == e.EV_REL:
            if ev.code == getattr(e, "REL_WHEEL", 8) and ev.value:
                for _ in range(abs(ev.value)):
                    self.x.click(4 if ev.value > 0 else 5)
            return
        if ev.code not in (getattr(e, "ABS_Y", 1), getattr(e, "ABS_MT_POSITION_Y", 0x36)):
            return
        if not getattr(self, "kbd_touching", False) and ev.code == getattr(e, "ABS_Y", 1):
            self.kbd_touching = True                 # some firmwares send no BTN_TOUCH
        y = ev.value
        if getattr(self, "kbd_last_y", None) is None:
            self.kbd_last_y, self.kbd_acc = y, 0.0
            return
        self.kbd_acc += (y - self.kbd_last_y) * self.kbd_scale
        self.kbd_last_y = y
        step = self.kbd_step
        while abs(self.kbd_acc) >= step:
            down = self.kbd_acc > 0
            self.x.click(5 if down else 4)
            self.kbd_acc += -step if down else step

    def run(self):
        try:
            self.kbd.grab()
            log(f"grabbed {self.kbd.path}")
        except OSError as ex:
            log(f"WARNING: could not grab keyboard: {ex}. Keys will arrive twice.")
        for d in list(self.vols):
            try:
                d.grab()
                log(f"grabbed {d.path} ({d.name}); everything but the volume keys passes through its clone")
            except OSError as ex:
                log(f"WARNING: could not grab {d.path}: {ex}")
                self.vols.remove(d)
        fds = {self.kbd.fd: self.kbd}
        if self.touch:
            fds[self.touch.dev.fd] = self.touch.dev
        for d in self.vols:
            fds[d.fd] = d
        while True:
            self.update_route()
            r, _, _ = select.select(list(fds), [], [], 0.05)
            for fd in r:
                dev = fds[fd]
                for ev in dev.read():
                    try:
                        if dev is self.kbd:
                            self.on_key(ev)
                        elif dev in self.vols:
                            self.on_volume(dev, ev)
                        elif self.touch and self.touch.grabbed:
                            self.touch.handle(ev)
                    except OSError:
                        raise
                    except Exception as ex:                # a bug must not stop the bridge
                        log(f"ERROR handling event {ev.type}/{ev.code}/{ev.value}: {ex!r}")
            if self.touch and self.touch.grabbed:
                self.touch.tick()
            if self.touch and self.touch.fling is not None and not self.touch.grabbed:
                self.touch.fling = None

    def shutdown(self):
        if self.touch:
            self.touch.set_active(False)
        self.set_volume_grab(False)
        for d in self.vols:
            try:
                d.ungrab()
            except OSError:
                pass
        for code in list(self.x_down):
            self.x.key(code, False)
        try:
            self.kbd.ungrab()
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    if args.list:
        for d in open_all():
            tag = ("virtual" if is_virtual(d) else "TOUCHSCREEN" if is_touchscreen(d)
                   else "VOLUME" if is_volume_keys(d) else f"kbd-score={kbd_score(d)}")
            print(f"{d.path:22} {tag:12} {d.name}")
        return

    kbd, touch, vol = find_devices()
    if args.debug:
        log(f"Debug on {kbd.path} ({kbd.name}); press keys, Ctrl+C to stop. Not grabbed.")
        for ev in kbd.read_loop():
            if ev.type == e.EV_KEY and ev.value in (0, 1):
                name = e.KEY.get(ev.code, e.BTN.get(ev.code, "?"))
                log(f"code={ev.code:4} {name} {'down' if ev.value else 'up'}")
        return

    os.environ.setdefault("DISPLAY", ":0")
    bridge = Bridge(kbd, touch, load_conf(), vol)
    signal.signal(signal.SIGTERM, lambda *_: (bridge.shutdown(), sys.exit(0)))
    while True:
        try:
            bridge.run()
        except OSError as ex:
            log(f"input device lost ({ex}); searching again...")
            bridge.shutdown()
            time.sleep(1)
            kbd, touch, vol = find_devices()
            bridge = Bridge(kbd, touch, load_conf(), vol)


if __name__ == "__main__":
    main()
