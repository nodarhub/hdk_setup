#!/usr/bin/env python3
"""Nodar Launcher — interactive terminal menu for Hammerhead & nodar_viewer.

On first launch (or when packages are not installed), acts as an installer:
prompts for a customer UUID, detects system configuration, downloads and
installs hammerhead + nodar_viewer .deb packages and a sample dataset.

After installation (or if packages are already present), shows the launcher
menu for day-to-day use.

ASCII art sourced from nodar::hammerhead_ascii (lib/include/nodar/hammerhead_ascii.hpp).
Configuration is read from ~/.config/nodar/nodar_launcher.cfg, with a fallback to
nodar_launcher.cfg placed next to this script.
"""

import configparser
import curses
import glob
import http.client
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import textwrap
import urllib.error
import urllib.parse
import urllib.request
import zipfile

# ── Paths ─────────────────────────────────────────────────────────────────────

HERE           = os.path.dirname(os.path.abspath(__file__))
NODAR_DIR             = os.path.expanduser("~/.config/nodar")
UUID_FILE             = os.path.join(NODAR_DIR, "uuid")
ACTIVATION_KEY_FILE   = os.path.join(NODAR_DIR, "activation_key")
LICENSE_ENC_FILE      = os.path.join(NODAR_DIR, "license.enc")
DOWNLOAD_DIR   = os.path.join(NODAR_DIR, "downloads")
CFG_FILE       = os.path.join(NODAR_DIR, "nodar_launcher.cfg")
CFG_FILE_LOCAL = os.path.join(HERE, "nodar_launcher.cfg")

# ── Installer constants ───────────────────────────────────────────────────────

BASE_URL        = "https://downloads.nodarsensor.net"
DATASET_URL     = (
    "https://dz2ajpir85e0i.cloudfront.net/files/public-datasets"
    "/daytime-highway-01/nodar_data_day_highway_01_minimal.zip"
)
DATASET_ZIP     = "nodar_data_day_highway_01_minimal.zip"
CONFIG_BASE_URL = "https://dz2ajpir85e0i.cloudfront.net/files/docs/config"
CONFIG_FILES    = ["master_config.ini", "intrinsics.ini", "extrinsics.ini"]

UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}"
    r"-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
ACT_KEY_RE = re.compile(r"^[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}$")

# ── Layout ────────────────────────────────────────────────────────────────────

MIN_W    = 80
MIN_ROWS = 24   # download screen: 6 items × 3 rows from iy=4, status at rows-2
MIN_ROWS_DISPLAYING_LOGO = 28  # extra 2 rows for activation-key section in menu

# ── ASCII art ─────────────────────────────────────────────────────────────────

LOGO = [
    r"                                ###",
    r"                                ###",
    r"########     ########    ##########   ###### ###  ### ###",
    r"###   ####  ####  ####  ####   ####  ####   ####  #######",
    r"###    ###  ###    ###  ###     ###  ###     ###  ###",
    r"###    ###  ####  ####  ####   ####  ####   ####  ###",
    r"###    ###   ########    ##########   ##########  ###",
]

# ── UUID management ───────────────────────────────────────────────────────────

def _load_uuid():
    try:
        val = open(UUID_FILE).read().strip()
        return val or None
    except OSError:
        return None


def _save_uuid(uuid):
    os.makedirs(NODAR_DIR, exist_ok=True)
    with open(UUID_FILE, "w") as f:
        f.write(uuid + "\n")


def _load_activation_key():
    try:
        val = open(ACTIVATION_KEY_FILE).read().strip()
        return val or None
    except OSError:
        return None


def _save_activation_key(key):
    os.makedirs(NODAR_DIR, exist_ok=True)
    with open(ACTIVATION_KEY_FILE, "w") as f:
        f.write(key + "\n")

# ── System detection ──────────────────────────────────────────────────────────

def _is_installed(cmd):
    try:
        subprocess.run(
            [cmd, "--version"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=5,
        )
        return True
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return False


def _detect_arch():
    return {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "")


def _detect_ubuntu():
    try:
        return subprocess.check_output(
            ["lsb_release", "-rs"], stderr=subprocess.DEVNULL, text=True,
        ).strip()
    except Exception:
        return ""


def _detect_cuda():
    """Return CUDA version string (e.g. '12.2') or raise RuntimeError."""
    try:
        out = subprocess.check_output(
            ["nvcc", "--version"], stderr=subprocess.STDOUT, text=True,
        )
        m = re.search(r"release (\d+\.\d+)", out)
        if m:
            return m.group(1)
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass

    candidates = sorted(glob.glob("/usr/local/cuda*/bin/nvcc"))
    if candidates:
        try:
            out = subprocess.check_output(
                [candidates[-1], "--version"], stderr=subprocess.STDOUT, text=True,
            )
            m = re.search(r"release (\d+\.\d+)", out)
            if m:
                return m.group(1)
        except Exception:
            pass
        cuda_bin = os.path.dirname(candidates[-1])
        raise RuntimeError(
            "CUDA is installed but its bin/ directory is not on your PATH.\n"
            "\n"
            "Add this to ~/.bashrc or ~/.profile, then restart your shell:\n"
            "\n"
            f"  export PATH={cuda_bin}:$PATH"
        )

    raise RuntimeError(
        "CUDA toolkit not found.\n"
        "Please install the CUDA toolkit and ensure nvcc is on your PATH."
    )

# ── Package API ───────────────────────────────────────────────────────────────

def _uuid_info(uuid):
    """Return (product, valid_until_str) from the download server.

    Uses http.client directly so that redirects are never auto-followed —
    urllib's OpenerDirector continues to follow redirects even when
    HTTPRedirectHandler is removed from its handlers list, because the
    handler's methods remain registered in the internal dispatch dicts.
    """
    parsed = urllib.parse.urlparse(BASE_URL)
    host   = parsed.netloc
    path   = f"/{uuid}"

    try:
        conn = http.client.HTTPSConnection(host, timeout=15)
        conn.request("GET", path)
        resp     = conn.getresponse()
        status   = resp.status
        location = resp.getheader("Location", "")
        conn.close()
    except OSError as e:
        raise RuntimeError(f"Network error: {e}")

    if status in (301, 302, 303, 307, 308):
        pass  # location captured above
    elif status == 403:
        raise RuntimeError("License ID not recognised or license expired.")
    elif status == 200:
        raise RuntimeError(
            "Unexpected 200 response — the server did not redirect to a product URL."
        )
    else:
        raise RuntimeError(f"Server returned HTTP {status}.")

    if not location:
        raise RuntimeError("Server sent a redirect with no Location header.")

    qs      = urllib.parse.parse_qs(urllib.parse.urlparse(location).query)
    product = qs.get("product", [""])[0]
    valid   = urllib.parse.unquote_plus(qs.get("downloads_valid_until", [""])[0])
    if not product:
        raise RuntimeError("Could not determine product type from server response.")
    return product, valid


def _fetch_json(url):
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            return json.loads(r.read())
    except Exception as e:
        raise RuntimeError(f"Failed to fetch package list: {e}")


def _fetch_package_list(uuid, product):
    hh_url = f"{BASE_URL}/json/hh/listing.json?uuid={uuid}&product={product}"
    gd_url = f"{BASE_URL}/json/gd/listing.json?uuid={uuid}&product={product}"
    if product == "hammerhead":
        return _fetch_json(hh_url)
    elif product == "hammerhead_gd":
        hh = _fetch_json(hh_url) or []
        try:
            gd = _fetch_json(gd_url) or []
        except RuntimeError:
            gd = []
        seen, combined = set(), []
        for pkg in hh + gd:
            fn = pkg.get("filename", "")
            if fn not in seen:
                seen.add(fn)
                combined.append(pkg)
        return combined
    else:
        raise RuntimeError(f"Unknown product type: {product!r}")


def _filter_packages(packages, arch, ubuntu, cuda):
    f = [p for p in packages if p.get("platform") != "windows"]

    if arch:
        m = [p for p in f if p.get("arch") == arch]
        if m:
            f = m
    if ubuntu:
        m = [p for p in f if p.get("ubuntu") in (ubuntu, "")]
        if m:
            f = m
    if cuda:
        m = [p for p in f if p.get("cuda") in (cuda, "")]
        if m:
            f = m

    vers = sorted(
        {p["version"] for p in f if p.get("version")},
        key=lambda v: [int(x) for x in v.split(".")],
    )
    if vers:
        f = [p for p in f if p.get("version") == vers[-1]]

    non_ros2 = [p for p in f if p.get("middleware") != "ros2"]
    if non_ros2 and len(non_ros2) < len(f):
        f = non_ros2

    gd_hh  = [p for p in f if p.get("program") == "hammerhead" and "-gd-" in p.get("filename", "")]
    nongd  = [p for p in f if p.get("program") == "hammerhead" and "-gd-" not in p.get("filename", "")]
    others = [p for p in f if p.get("program") != "hammerhead"]
    if gd_hh and nongd:
        f = gd_hh + others

    return f


def _download_file(url, dest, progress_cb=None):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": "nodar-launcher/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        total = int(resp.headers.get("Content-Length", 0))
        done  = 0
        with open(dest, "wb") as f:
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                f.write(chunk)
                done += len(chunk)
                if progress_cb:
                    progress_cb(done, total)

# ── Config loading ────────────────────────────────────────────────────────────

def _detect_version(hammerhead_cmd):
    try:
        out = subprocess.check_output(
            hammerhead_cmd + ["--version"],
            stderr=subprocess.STDOUT, text=True, timeout=5,
        )
        return out.splitlines()[0].split()[1]
    except Exception:
        return "?.?.?"


def load_config():
    parser = configparser.ConfigParser()
    parser["commands"] = {
        "hammerhead":    "hammerhead",
        "nodar_viewer":  "nodar_viewer",
        "master_config": "~/.config/nodar/config/master_config.ini",
    }
    parser.read([CFG_FILE_LOCAL, CFG_FILE])

    def _cmd(key):
        return shlex.split(os.path.expanduser(parser.get("commands", key)))

    def _path(key):
        return os.path.expanduser(parser.get("commands", key))

    hcmd   = _cmd("hammerhead")
    active = next(
        (p for p in [CFG_FILE, CFG_FILE_LOCAL] if os.path.exists(p)), CFG_FILE
    )
    return {
        "hammerhead":    hcmd,
        "nodar_viewer":  _cmd("nodar_viewer"),
        "master_config": _path("master_config"),
        "version":       _detect_version(hcmd),
        "cfg_file":      active,
    }

# ── Drawing helpers ───────────────────────────────────────────────────────────

def _hline(win, y, x, w, left=None, right=None):
    if left  is None: left  = curses.ACS_LTEE
    if right is None: right = curses.ACS_RTEE
    try:
        win.addch(y, x,         left)
        win.addch(y, x + w - 1, right)
        win.hline(y, x + 1, curses.ACS_HLINE, w - 2)
    except curses.error:
        pass


def _box(win, y, x, h, w):
    """Draw a border rectangle and return the inner canvas (iy, ix, ih, iw)."""
    try:
        win.addch(y,         x,         curses.ACS_ULCORNER)
        win.addch(y,         x + w - 1, curses.ACS_URCORNER)
        win.addch(y + h - 1, x,         curses.ACS_LLCORNER)
    except curses.error:
        pass
    try:
        win.addch(y + h - 1, x + w - 1, curses.ACS_LRCORNER)
    except curses.error:
        pass
    try:
        win.hline(y,         x + 1, curses.ACS_HLINE, w - 2)
        win.hline(y + h - 1, x + 1, curses.ACS_HLINE, w - 2)
        win.vline(y + 1, x,          curses.ACS_VLINE, h - 2)
        win.vline(y + 1, x + w - 1,  curses.ACS_VLINE, h - 2)
    except curses.error:
        pass
    return y + 1, x + 1, h - 2, w - 2


def _put(win, y, x, text, attr=0, max_w=None, wrap=False):
    """Draw text at (y, x) and return the next available row index.

    With wrap=True and max_w set, text is word-wrapped across multiple rows.
    Without wrap (default), text is truncated to max_w characters.
    """
    if wrap and max_w:
        lines = textwrap.wrap(text, max_w) or [""]
        for i, line in enumerate(lines):
            try:
                win.addstr(y + i, x, line, attr)
            except curses.error:
                pass
        return y + len(lines)
    if max_w is not None:
        text = text[:max_w]
    try:
        win.addstr(y, x, text, attr)
    except curses.error:
        pass
    return y + 1

# ── Color init ────────────────────────────────────────────────────────────────

def _init_colors(stdscr):
    curses.curs_set(0)
    if curses.has_colors():
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_BLUE,   -1)
        curses.init_pair(2, curses.COLOR_WHITE,  -1)
        curses.init_pair(3, curses.COLOR_BLACK,  curses.COLOR_WHITE)
        curses.init_pair(4, curses.COLOR_YELLOW, -1)
        curses.init_pair(5, curses.COLOR_GREEN,  -1)

    def cp(n, extra=0):
        return (curses.color_pair(n) | extra) if curses.has_colors() else extra

    return {
        "art":    cp(1, curses.A_BOLD),
        "normal": cp(2),
        "sel":    cp(3, curses.A_BOLD),
        "hint":   cp(4),
        "desc":   cp(5),
        "dim":    cp(2, curses.A_DIM),
        "status": cp(2, curses.A_BOLD),
        "bold":   cp(2, curses.A_BOLD),
        "err":    cp(4, curses.A_BOLD),
    }

# ── Frame drawing ─────────────────────────────────────────────────────────────

def _draw_frame(stdscr, colors, subtitle):
    """Draw the outer box, logo (when space permits), subtitle, and separator.

    Returns (iy, ix, ih, iw, sep_x, sep_w) where iy is the first row callers
    may draw content (one past the header separator), and (sep_x, sep_w) are
    the x and width to pass to _hline for any additional separator lines.
    The header separator row is therefore iy - 1, inferrable by callers if needed.
    """
    rows, cols = stdscr.getmaxyx()
    box_iy, ix, _, iw = _box(stdscr, 0, 0, rows, cols)

    if rows >= MIN_ROWS_DISPLAYING_LOGO:
        logo_max_w = max(len(l) for l in LOGO)
        logo_x     = ix + (iw - logo_max_w) // 2
        for i, line in enumerate(LOGO):
            _put(stdscr, box_iy + i, logo_x, line, colors["art"], iw)
        subtitle_row = box_iy + len(LOGO) + 1
    else:
        subtitle_row = box_iy + 1

    _put(stdscr, subtitle_row, ix + (iw - len(subtitle)) // 2, subtitle, colors["hint"])
    if rows >= MIN_ROWS_DISPLAYING_LOGO:
        sep_row = subtitle_row + 1
    else:
        sep_row = subtitle_row + 2
    _hline(stdscr, sep_row, 0, cols)

    iy = sep_row + 1
    ih = rows - 1 - iy
    return iy, ix, ih, iw, 0, cols


def _wait_size_ok(stdscr):
    """Block until the terminal meets MIN_W×MIN_ROWS; any key re-checks."""
    while True:
        rows, cols = stdscr.getmaxyx()
        if cols >= MIN_W and rows >= MIN_ROWS:
            break
        stdscr.erase()
        msg = (f"  Terminal too small — need {MIN_W}×{MIN_ROWS},"
               f" currently {cols}×{rows}.  Resize to continue or ctrl+c to abort.")
        _put(stdscr, rows // 2, max(0, (cols - len(msg)) // 2), msg, curses.A_BOLD, cols, wrap=True)
        stdscr.refresh()
        stdscr.getch()

# ── Setup screen (UUID + activation key) ─────────────────────────────────────

def _fmt_act_key(buf):
    """Format raw key chars (max 20 uppercase alnum, no dashes) as XXXXX-XXXXX-XXXXX-XXXXX."""
    s = "".join(buf)
    parts = [s[i:i+5] for i in range(0, len(s), 5)]
    return "-".join(parts)


def _setup_screen(stdscr, colors, need_uuid, need_key, pre_uuid=None):
    """Collect License ID and/or activation key from the user.

    Returns (uuid_str, key_str) — each is None when not required — or None on quit.
    Both fields are shown when needed; Tab switches focus between them.
    The activation key is stored as-typed but displayed auto-formatted (XXXXX-XXXXX-XXXXX-XXXXX).
    """
    # "License ID    : " and "Activation Key : " are both 17 chars
    LABEL_W  = 17
    UUID_W   = 36
    KEY_DISP = 23   # display width: XXXXX-XXXXX-XXXXX-XXXXX
    KEY_MAX  = 20   # raw chars (no dashes)

    LIC_EXAMPLE = "https://downloads.nodarsensor.net/12345678-9abc-def0-1234-56789abcdef0"

    uuid_buf = list(pre_uuid) if pre_uuid else []
    key_buf  = []   # raw chars only — dashes inserted on display
    error    = ""
    field    = 0 if need_uuid else 1  # 0 = License ID active, 1 = activation key active
    curses.curs_set(1)

    while True:
        _wait_size_ok(stdscr)
        rows, cols = stdscr.getmaxyx()
        stdscr.erase()

        iy, ix, ih, iw, sep_x, sep_w = _draw_frame(
            stdscr, colors, "Nodar Launcher  ·  First-time Setup"
        )

        my = iy + 1

        # Main instruction line
        if need_uuid and need_key:
            desc = "Please enter your License ID and activation key (from the email you received)."
        elif need_uuid:
            desc = "Please enter your License ID."
        else:
            desc = "Please enter your activation key (from the email you received)."

        my = _put(stdscr, my, ix + 3, "Welcome to the Nodar HDK Launcher.", colors["normal"], iw - 4)
        my += 1  # blank line
        my = _put(stdscr, my, ix + 3, desc, colors["normal"], iw - 4, wrap=True)
        my += 1  # blank line

        # License ID location hint
        if need_uuid:
            my = _put(stdscr, my, ix + 3,
                      "Your License ID is in the URL from Nodar — after the last slash:",
                      colors["dim"], iw - 4)
            my = _put(stdscr, my, ix + 3, f"  {LIC_EXAMPLE}", colors["dim"], iw - 4)
            my += 1  # blank line

        field_x  = ix + 3 + LABEL_W
        uuid_row = key_row = None

        if need_uuid:
            uuid_row = my
            active   = (field == 0)
            _put(stdscr, my, ix + 3, "License ID    : ",
                 colors["bold"] if active else colors["dim"])
            _put(stdscr, my, field_x, ("".join(uuid_buf)).ljust(UUID_W),
                 colors["sel"] if active else colors["normal"])
            my += 1

        if need_key:
            if need_uuid:
                my += 1  # blank line between the two fields
            key_row = my
            active  = (field == 1)
            _put(stdscr, my, ix + 3, "Activation Key : ",
                 colors["bold"] if active else colors["dim"])
            _put(stdscr, my, field_x, _fmt_act_key(key_buf).ljust(KEY_DISP),
                 colors["sel"] if active else colors["normal"])
            my += 1

        if error:
            my += 1
            _put(stdscr, my, ix + 3, error, colors["err"], iw - 4)

        if need_uuid and need_key:
            tab_hint = "  Tab  Switch    Enter  Confirm (key optional)    Esc  Quit  "
        elif need_key:
            tab_hint = "  Enter  Confirm (or skip key)    Esc  Quit  "
        else:
            tab_hint = "  Enter  Confirm    Esc  Quit  "
        _put(stdscr, rows - 2, ix + (iw - len(tab_hint)) // 2, tab_hint, colors["hint"])

        try:
            if field == 0 and uuid_row is not None:
                stdscr.move(uuid_row, field_x + min(len(uuid_buf), UUID_W - 1))
            elif field == 1 and key_row is not None:
                stdscr.move(key_row, field_x + len(_fmt_act_key(key_buf)))
        except curses.error:
            pass

        stdscr.refresh()
        k = stdscr.getch()

        if k == ord("\t") and need_uuid and need_key:
            field = 1 - field
            error = ""
        elif k in (curses.KEY_ENTER, ord("\n"), ord("\r")):
            valid = True
            if need_uuid:
                if not UUID_RE.match("".join(uuid_buf).strip()):
                    error = "Invalid License ID — expected: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
                    valid = False
            if valid and need_key and key_buf:
                # non-empty key must match the full format
                if not ACT_KEY_RE.match(_fmt_act_key(key_buf)):
                    error = "Invalid key — expected format: XXXXX-XXXXX-XXXXX-XXXXX"
                    valid = False
            if valid:
                curses.curs_set(0)
                return (
                    "".join(uuid_buf).strip() if need_uuid else None,
                    _fmt_act_key(key_buf) if (need_key and key_buf) else None,
                )
        elif k in (curses.KEY_BACKSPACE, 127, 8):
            if field == 0 and uuid_buf:
                uuid_buf.pop()
            elif field == 1 and key_buf:
                key_buf.pop()
            error = ""
        elif k == 27:  # Esc — 'q' is a valid key character so not used as quit
            curses.curs_set(0)
            return None
        elif 32 <= k < 128:
            if field == 0 and len(uuid_buf) < UUID_W:
                uuid_buf.append(chr(k))
                error = ""
            elif field == 1 and len(key_buf) < KEY_MAX:
                c = chr(k).upper()
                if c.isalnum():  # letters and digits only; dashes auto-inserted on display
                    key_buf.append(c)
                    error = ""

# ── Fetch packages and confirm ────────────────────────────────────────────────

def _fetch_and_confirm(stdscr, colors, uuid,
                       subtitle="Nodar Launcher  ·  Installation",
                       installed_versions=None):
    """Detect system, fetch matching packages, and confirm the operation.

    When installed_versions is provided as (hh_ver, nv_ver), both are compared
    against the fetched packages:
      - both up to date → shows a message and returns "up_to_date"
      - either is newer → shows installed → available table, then confirms

    Returns [hh_pkg, nv_pkg] on confirmation, "up_to_date" when no update is
    needed, or None on cancellation / error.
    """
    rows, cols = stdscr.getmaxyx()
    stdscr.erase()
    iy, ix, ih, iw, sep_x, sep_w = _draw_frame(stdscr, colors, subtitle)
    my = iy + 1

    content_lines = []  # replay buffer for resize: (text, color) or None for blank

    def line(text, color=None):
        nonlocal my
        c = color or colors["normal"]
        content_lines.append((text, c))
        _put(stdscr, my, ix + 3, text, c, iw - 4)
        my += 1
        stdscr.refresh()

    def blank():
        nonlocal my
        content_lines.append(None)
        my += 1

    def _redraw(hint):
        _rows, _cols = stdscr.getmaxyx()
        stdscr.erase()
        _iy, _ix, _ih, _iw, _sx, _sw = _draw_frame(stdscr, colors, subtitle)
        _my = _iy + 1
        for entry in content_lines:
            if entry is None:
                _my += 1
            else:
                _put(stdscr, _my, _ix + 3, entry[0], entry[1], _iw - 4)
                _my += 1
        if _rows - 3 > _my:
            _hline(stdscr, _rows - 3, 0, _sw)
        _put(stdscr, _rows - 2, _ix + (_iw - len(hint)) // 2, hint, colors["hint"])
        stdscr.refresh()

    line("Detecting system configuration...")
    blank()

    arch   = _detect_arch()
    ubuntu = _detect_ubuntu()
    line(f"  Architecture : {arch or 'unknown'}", colors["dim"])
    line(f"  Ubuntu       : {ubuntu or 'unknown'}", colors["dim"])

    try:
        cuda = _detect_cuda()
        line(f"  CUDA         : {cuda}", colors["dim"])
    except RuntimeError as e:
        my += 1
        line("Cannot detect CUDA version:", colors["err"])
        for msg in str(e).splitlines():
            line("  " + msg, colors["dim"])
        my += 1
        line("Press any key to exit.", colors["hint"])
        stdscr.getch()
        return None

    blank()
    line("Contacting download server...")
    try:
        product, valid_until = _uuid_info(uuid)
    except RuntimeError as e:
        my += 1
        line(f"Error: {e}", colors["err"])
        line("Press any key to exit.", colors["hint"])
        stdscr.getch()
        return None

    line(f"  Product : {product}    Valid until : {valid_until}", colors["dim"])
    blank()
    line("Fetching and filtering package list...")

    try:
        packages = _fetch_package_list(uuid, product)
        filtered = _filter_packages(packages, arch, ubuntu, cuda)
    except RuntimeError as e:
        my += 1
        line(f"Error: {e}", colors["err"])
        line("Press any key to exit.", colors["hint"])
        stdscr.getch()
        return None

    hh_pkgs = [p for p in filtered if p.get("filename", "").startswith("hammerhead-")]
    nv_pkgs = [p for p in filtered if p.get("filename", "").startswith("nodar_viewer-")]

    if len(hh_pkgs) != 1 or len(nv_pkgs) != 1:
        my += 1
        line(
            f"Error: expected 1 hammerhead + 1 nodar_viewer package; "
            f"got {len(hh_pkgs)} + {len(nv_pkgs)}.",
            colors["err"],
        )
        line("Contact sales@nodarsensor.com for assistance.", colors["normal"])
        line("Press any key to exit.", colors["hint"])
        stdscr.getch()
        return None

    hh_pkg = hh_pkgs[0]
    nv_pkg = nv_pkgs[0]

    blank()

    # ── Version comparison (update flow only) ──────────────────────────────────
    is_update = installed_versions is not None
    if is_update:
        hh_inst, nv_inst = installed_versions
        hh_avail = hh_pkg.get("version", "")
        nv_avail = nv_pkg.get("version", "")

        def _parse_ver(v):
            try:
                return [int(x) for x in v.split(".")]
            except (ValueError, AttributeError):
                return []

        hh_needs = bool(_parse_ver(hh_avail) and _parse_ver(hh_inst)
                        and _parse_ver(hh_avail) > _parse_ver(hh_inst))
        nv_needs = bool(_parse_ver(nv_avail) and _parse_ver(nv_inst)
                        and _parse_ver(nv_avail) > _parse_ver(nv_inst))

        HINT_CLOSE = "  Press any key to return  "

        if not hh_needs and not nv_needs:
            line("Both packages are already up to date.", colors["bold"])
            blank()
            line(f"  {'Hammerhead':<12} : {hh_inst}", colors["dim"])
            line(f"  {'Nodar Viewer':<12} : {nv_inst}", colors["dim"])
            rows, cols = stdscr.getmaxyx()
            if rows - 3 > my:
                _hline(stdscr, rows - 3, 0, sep_w)
            _put(stdscr, rows - 2, ix + (iw - len(HINT_CLOSE)) // 2,
                 HINT_CLOSE, colors["hint"])
            stdscr.refresh()
            while True:
                k = stdscr.getch()
                if k == curses.KEY_RESIZE:
                    _wait_size_ok(stdscr)
                    _redraw(HINT_CLOSE)
                else:
                    break
            return "up_to_date"

        line("A newer version is available!", colors["bold"])
        blank()
        line(f"  {'Hammerhead':<12} : {hh_inst or 'unknown'}  →  {hh_avail}", colors["dim"])
        line(f"  {'Nodar Viewer':<12} : {nv_inst or 'unknown'}  →  {nv_avail}", colors["dim"])
        blank()

    # ── Confirmation ───────────────────────────────────────────────────────────
    hint_action = "Update" if is_update else "Install"
    hint = f"  Enter  Download & {hint_action}    q  Cancel  "

    line(f"The following will be downloaded and {hint_action.lower()}ed:", colors["bold"])
    blank()
    line(f"  {hh_pkg['filename']}")
    line(f"  {nv_pkg['filename']}")
    if not is_update:
        line(f"  {DATASET_ZIP}  (sample dataset)")

    rows, cols = stdscr.getmaxyx()
    if rows - 3 > my:
        _hline(stdscr, rows - 3, 0, sep_w)
    _put(stdscr, rows - 2, ix + (iw - len(hint)) // 2, hint, colors["hint"])
    stdscr.refresh()

    while True:
        key = stdscr.getch()
        if key == curses.KEY_RESIZE:
            _wait_size_ok(stdscr)
            _redraw(hint)
        elif key in (curses.KEY_ENTER, ord("\n"), ord("\r")):
            return [hh_pkg, nv_pkg]
        elif key in (ord("q"), 27):
            return None

# ── Installer: download + install ─────────────────────────────────────────────

def _download_and_install(stdscr, colors, uuid, packages):
    """Download debs + dataset, unzip, run apt install.

    Returns True on success, False on failure/cancellation.
    """
    debs_dir     = os.path.join(DOWNLOAD_DIR, "debs")
    zips_dir     = os.path.join(DOWNLOAD_DIR, "zips")
    datasets_dir = os.path.join(DOWNLOAD_DIR, "datasets")
    for d in (debs_dir, zips_dir, datasets_dir):
        os.makedirs(d, exist_ok=True)

    hh_pkg, nv_pkg = packages[0], packages[1]
    hh_version   = hh_pkg.get("version", "unknown")
    configs_dir  = os.path.join(DOWNLOAD_DIR, f"config_{hh_version}")
    os.makedirs(configs_dir, exist_ok=True)

    items = [
        {
            "label": hh_pkg["filename"],
            "url":   f"{BASE_URL}/download/{uuid}/{hh_pkg['bucket']}/{hh_pkg['key']}",
            "dest":  os.path.join(debs_dir, hh_pkg["filename"]),
            "done": 0, "total": 0, "state": "waiting",
        },
        {
            "label": nv_pkg["filename"],
            "url":   f"{BASE_URL}/download/{uuid}/{nv_pkg['bucket']}/{nv_pkg['key']}",
            "dest":  os.path.join(debs_dir, nv_pkg["filename"]),
            "done": 0, "total": 0, "state": "waiting",
        },
        {
            "label": f"{DATASET_ZIP}  (sample dataset)",
            "url":   DATASET_URL,
            "dest":  os.path.join(zips_dir, DATASET_ZIP),
            "done": 0, "total": 0, "state": "waiting",
        },
    ] + [
        {
            "label": f"{f}  (config {hh_version})",
            "url":   f"{CONFIG_BASE_URL}/{f}",
            "dest":  os.path.join(configs_dir, f),
            "done": 0, "total": 0, "state": "waiting",
        }
        for f in CONFIG_FILES
    ]

    def _redraw(status_line="  Downloading — please wait..."):
        rows, cols = stdscr.getmaxyx()
        stdscr.erase()
        iy, ix, ih, iw, sep_x, sep_w = _draw_frame(
            stdscr, colors, "Nodar Launcher  ·  Downloading"
        )
        bar_w = iw - 31  # 3 indent + 1 "[" + 1 "]" + 2 "  " + 24 max info
        my    = iy + 1

        for it in items:
            _put(stdscr, my, ix + 3, it["label"], colors["bold"], iw - 4)
            my += 1
            if it["state"] == "waiting":
                bar = "░" * bar_w
                _put(stdscr, my, ix + 3, f"[{bar}]  waiting...", colors["dim"])
            elif it["state"] in ("done", "skipped"):
                bar  = "█" * bar_w
                note = "done" if it["state"] == "done" else "already downloaded"
                _put(stdscr, my, ix + 3, f"[{bar}]  {note}", colors["desc"])
            elif it["state"] == "downloading":
                pct  = it["done"] / it["total"] if it["total"] else 0
                fill = int(bar_w * pct)
                bar  = "█" * fill + "░" * (bar_w - fill)
                info = f"{pct * 100:3.0f}%  {it['done'] / 1_048_576:.1f} / {it['total'] / 1_048_576:.1f} MB"
                _put(stdscr, my, ix + 3, f"[{bar}]  {info}", colors["normal"])
            my += 2

        _put(stdscr, rows - 2, ix + 3, status_line, colors["hint"])
        stdscr.refresh()

    _redraw()

    for it in items:
        if os.path.isfile(it["dest"]):
            it["state"] = "skipped"
            _redraw()
            continue

        it["state"] = "downloading"

        def _cb(done, total, _it=it):
            _it["done"]  = done
            _it["total"] = total
            _redraw()

        try:
            _download_file(it["url"], it["dest"], _cb)
            it["state"] = "done"
            _redraw()
        except Exception as e:
            stdscr.erase()
            iy, ix, ih, iw, sep_x, sep_w = _draw_frame(
                stdscr, colors, "Nodar Launcher  ·  Download Error"
            )
            _put(stdscr, iy + 1, ix + 3,
                 f"Download failed: {e}"[:iw - 4], colors["err"])
            _put(stdscr, iy + 3, ix + 3, "Press any key to exit.", colors["hint"])
            stdscr.refresh()
            stdscr.getch()
            return False

    # Unzip sample dataset
    dataset_folder = os.path.join(datasets_dir, DATASET_ZIP[:-4])
    zip_path       = items[2]["dest"]

    _redraw("  Unpacking sample dataset...")
    if not os.path.isdir(dataset_folder):
        try:
            with zipfile.ZipFile(zip_path) as z:
                z.extractall(datasets_dir)
        except Exception as e:
            stdscr.erase()
            iy, ix, ih, iw, sep_x, sep_w = _draw_frame(
                stdscr, colors, "Nodar Launcher  ·  Error"
            )
            _put(stdscr, iy + 1, ix + 3,
                 f"Unzip failed: {e}"[:iw - 4], colors["err"])
            _put(stdscr, iy + 3, ix + 3, "Press any key to exit.", colors["hint"])
            stdscr.refresh()
            stdscr.getch()
            return False

    # Populate the live config folder with any missing files from the downloaded set
    live_config_dir = os.path.join(NODAR_DIR, "config")
    os.makedirs(live_config_dir, exist_ok=True)
    _redraw("  Copying missing config files...")
    for f in CONFIG_FILES:
        dest = os.path.join(live_config_dir, f)
        src  = os.path.join(configs_dir, f)
        if not os.path.isfile(dest) and os.path.isfile(src):
            shutil.copy2(src, dest)

    # Prompt before leaving curses for apt
    def _draw_install_prompt():
        stdscr.erase()
        _iy, _ix, _ih, _iw, _sx, _sw = _draw_frame(
            stdscr, colors, "Nodar Launcher  ·  Installing"
        )
        _iy += 1  # blank line
        _iy = _put(stdscr, _iy, _ix + 3,
                   "Downloads complete. Ready to install packages with apt.", colors["bold"])
        _iy += 1  # blank line
        _iy = _put(stdscr, _iy, _ix + 3,
                   "The terminal will switch to normal mode — sudo may prompt for your password.",
                   colors["normal"], _iw - 3, wrap=True)
        _iy += 1  # blank line
        _put(stdscr, _iy, _ix + 3,
             "Press Enter to proceed, or q to cancel.", colors["hint"])
        stdscr.refresh()

    _draw_install_prompt()

    while True:
        key = stdscr.getch()
        if key == curses.KEY_RESIZE:
            _wait_size_ok(stdscr)
            _draw_install_prompt()
        elif key in (curses.KEY_ENTER, ord("\n"), ord("\r")):
            break
        elif key in (ord("q"), 27):
            return False

    hh_deb = items[0]["dest"]
    nv_deb = items[1]["dest"]

    curses.endwin()
    print()
    print("  Installing Hammerhead and Nodar Viewer...")
    print()
    try:
        subprocess.run(
            ["sudo", "apt", "install", "-y", hh_deb, nv_deb],
            check=True,
        )
        print()
        print("  Installation complete!")
        print()
        print("  Switching defaults to the newly installed versions...")
        for alt in ("hammerhead", "nodar_viewer"):
            try:
                subprocess.run(
                    ["sudo", "update-alternatives", "--auto", alt],
                    check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                print(f"    update-alternatives --auto {alt}  ✓")
            except (subprocess.CalledProcessError, FileNotFoundError):
                print(f"    update-alternatives --auto {alt}  (skipped — not registered)")
    except subprocess.CalledProcessError as e:
        print(f"\n  apt install failed (exit code {e.returncode}).")
        print("  Resolve the errors above, then re-run the launcher.")
        input("\n  Press Enter to exit...")
        return False
    except KeyboardInterrupt:
        print("\n  Cancelled.")
        input("  Press Enter to exit...")
        return False

    input("\n  Press Enter to continue to the launcher...")
    stdscr.refresh()
    return True

# ── Check for update ─────────────────────────────────────────────────────────

def _check_for_update_screen(stdscr, colors, cfg):
    """Check for a newer package version and optionally install it.

    Returns ("restart",) if an update was installed (caller should reload cfg),
    or ("stay", msg) when no update was performed.
    """
    _wait_size_ok(stdscr)

    uuid = _load_uuid()
    if not uuid:
        result = _setup_screen(stdscr, colors, need_uuid=True, need_key=False)
        if result is None:
            return ("stay", "Update check cancelled.")
        uuid, _ = result
        if uuid:
            _save_uuid(uuid)
        if not uuid:
            return ("stay", "License ID required to check for updates.")

    hh_installed = cfg["version"]
    nv_installed = _detect_version(cfg["nodar_viewer"])
    result = _fetch_and_confirm(
        stdscr, colors, uuid,
        subtitle="Nodar Launcher  ·  Check for Update",
        installed_versions=(hh_installed, nv_installed),
    )
    if result == "up_to_date":
        return ("stay", f"Already up to date  (v{hh_installed})")
    if result is None:
        return ("stay", "Update cancelled.")
    ok = _download_and_install(stdscr, colors, uuid, result)
    return ("restart",) if ok else ("stay", "Update failed or was cancelled.")

# ── Launcher actions ──────────────────────────────────────────────────────────

def _open_in_terminal(cmd_list):
    inner     = " ".join(shlex.quote(a) for a in cmd_list)
    pause     = 'echo; echo "  Process exited — press Enter to close."; read'
    shell_cmd = f"{inner}; {pause}"
    for args in [
        ["gnome-terminal", "--", "bash", "-c", shell_cmd],
        ["xterm", "-e", "bash", "-c", shell_cmd],
        ["x-terminal-emulator", "-e", "bash", "-c", shell_cmd],
        ["konsole", "-e", "bash", "-c", shell_cmd],
    ]:
        try:
            subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True, args[0]
        except FileNotFoundError:
            continue
    return False, None


_SINGLE_APPS     = ("Hammerhead", "Nodar Viewer", "Hammerhead + Nodar Viewer")
_SINGLE_CMD_KEYS = ("hammerhead", "nodar_viewer", None)  # None → launch both
_single_app_idx  = [2]
TOGGLE_ITEM_IDX  = 0


def _make_actions(cfg, stdscr, colors):
    def _run_launch():
        idx  = _single_app_idx[0]
        name = _SINGLE_APPS[idx]
        if idx == 2:  # Hammerhead + Nodar Viewer
            vcmd, hcmd = cfg["nodar_viewer"], cfg["hammerhead"]
            viewer_ok = False
            try:
                subprocess.Popen(vcmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                viewer_ok = True
            except FileNotFoundError:
                pass
            ok, term = _open_in_terminal(hcmd)
            if ok and viewer_ok:
                return ("stay", f"Launched Nodar Viewer and Hammerhead  ({term})")
            if ok:
                return ("stay", f"Hammerhead launched in {term}  (Nodar Viewer not found)")
            if viewer_ok:
                return ("stay", "Nodar Viewer launched — could not open a terminal for Hammerhead")
            return ("stay", "Launch failed — check commands in config")
        cmd = cfg[_SINGLE_CMD_KEYS[idx]]
        ok, term = _open_in_terminal(cmd)
        if ok:
            return ("stay", f"{name} launched in a new {term} window")
        return ("stay", "No terminal emulator found — install gnome-terminal or xterm")

    def _open_config_folder():
        folder = os.path.dirname(cfg["master_config"])
        if not os.path.isdir(folder):
            return ("stay", f"Directory not found:  {folder}")
        try:
            subprocess.Popen(["xdg-open", folder],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return ("stay", f"Opened  {folder}")
        except FileNotFoundError:
            return ("stay", f"xdg-open not available — config folder is at:  {folder}")

    def _show_version_info():
        def _query(cmd):
            try:
                out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True, timeout=5)
                return out.rstrip().splitlines()
            except FileNotFoundError:
                return [f"Command not found: {cmd[0]}"]
            except subprocess.TimeoutExpired:
                return [f"Timed out waiting for {cmd[0]} --version"]
            except subprocess.CalledProcessError as e:
                return (e.output or "").rstrip().splitlines() or [f"{cmd[0]} command failed"]

        hh_lines = _query(cfg["hammerhead"]   + ["--version"])
        nv_lines = _query(cfg["nodar_viewer"] + ["--version"])
        lines = (
            ["Hammerhead:"] + [f"  {l}" for l in hh_lines]
            + [""]
            + ["Nodar Viewer:"] + [f"  {l}" for l in nv_lines]
        )
        return ("overlay", lines)

    def _run_check_for_update():
        return _check_for_update_screen(stdscr, colors, cfg)

    return _run_launch, _open_config_folder, _show_version_info, _run_check_for_update

# ── Menu definition ───────────────────────────────────────────────────────────

class MenuItem:
    def __init__(self, title, description, action):
        self.title       = title
        self.description = description
        self.action      = action


def _build_menu(cfg, stdscr, colors):
    launch, omc, svi, cfu = _make_actions(cfg, stdscr, colors)
    return [
        MenuItem("Launch",
                 "Selected app  ·  ◄ ► to switch", launch),
        MenuItem("Open Config Folder",
                 f"Browse config files  ({os.path.dirname(cfg['master_config'])})", omc),
        MenuItem("Show Version Info",
                 "Display the full output of `hammerhead --version`", svi),
        MenuItem("Check for Update",
                 "Compare installed version with latest available and update if newer", cfu),
    ]

# ── Launcher menu ─────────────────────────────────────────────────────────────

def _launcher_menu(stdscr, colors, cfg, act_key=None):
    os.makedirs(os.path.dirname(cfg["master_config"]), exist_ok=True)

    menu     = _build_menu(cfg, stdscr, colors)
    selected = 0
    status   = ""
    overlay  = None

    while True:
        _wait_size_ok(stdscr)
        rows, cols = stdscr.getmaxyx()
        stdscr.erase()

        iy, ix, ih, iw, sep_x, sep_w = _draw_frame(stdscr, colors, f"Nodar Launcher  ·  v{cfg['version']}")

        my = iy  # The y of menu area start
        menu_buf = 1
        menu_inner = iw - 2 * menu_buf

        for idx, item in enumerate(menu):
            is_sel = (idx == selected)
            tag    = f" [{idx + 1}]  "

            if idx == TOGGLE_ITEM_IDX:
                app_name = _SINGLE_APPS[_single_app_idx[0]]
                title_s  = (tag + f"Launch   ◄  {app_name}  ►").ljust(menu_inner)
            else:
                title_s = (tag + item.title).ljust(menu_inner)

            desc_s = " " * (len(tag) + 1) + item.description

            if is_sel:
                my = _put(stdscr, my, ix + menu_buf, title_s, colors["sel"], menu_inner)
                my = _put(stdscr, my, ix + menu_buf, desc_s,  colors["desc"], menu_inner)
            else:
                my = _put(stdscr, my, ix + menu_buf, title_s, colors["normal"], menu_inner)
                my = _put(stdscr, my, ix + menu_buf, desc_s,  colors["dim"], menu_inner)
            my += 1  # blank line

        # Activation key display (two rows above the hint separator)
        if act_key and not os.path.isfile(LICENSE_ENC_FILE) and rows - 5 >= my:
            instr = "Copy and paste this key to Hammerhead when prompted at the first run."
            _put(stdscr, rows - 5, ix + (iw - len(instr)) // 2, instr,
                 colors["hint"], iw)
            _put(stdscr, rows - 4, ix + (iw - len(act_key)) // 2, act_key,
                 colors["desc"] | curses.A_BOLD)

        # Draw the navigation hint
        hint_sep = rows - 3
        if hint_sep >= my:
            _hline(stdscr, hint_sep, 0, sep_w)
            hint_buf = 2
            hint_width = iw - 2 * hint_buf
            if status:
                _put(stdscr, hint_sep + 1, ix + hint_buf, status, colors["status"], hint_width)
            else:
                if selected == TOGGLE_ITEM_IDX:
                    hint = "  ↑↓  Navigate    Enter  Launch    ◄ ►  Switch App    q  Quit  "
                else:
                    hint = "  ↑↓  Navigate    Enter / 1–4  Select    q  Quit  "
                _put(stdscr, hint_sep + 1, ix + (iw - len(hint)) // 2, hint, colors["hint"])

        if overlay is not None:
            content_w = max((len(l) for l in overlay), default=0)
            box_w     = min(content_w + 6, cols - 4)
            box_h     = len(overlay) + 4
            oy        = max(0, (rows - box_h) // 2)
            ox        = (cols - box_w) // 2
            oiy, oix, oih, oiw = _box(stdscr, oy, ox, box_h, box_w)
            blank = " " * oiw
            for row in range(oih):
                _put(stdscr, oiy + row, oix, blank, colors["normal"])
            for i, line in enumerate(overlay):
                _put(stdscr, oiy + i, oix + 2, line, colors["normal"], oiw - 4)
            _hline(stdscr, oiy + len(overlay), ox, box_w)
            hint_ov = "  Space / Enter to close  "
            _put(stdscr, oiy + 1 + len(overlay),
                 ox + (box_w - len(hint_ov)) // 2, hint_ov, colors["hint"])

        stdscr.refresh()
        status = ""

        key = stdscr.getch()

        if overlay is not None:
            if key in (ord(" "), ord("\n"), ord("\r"), curses.KEY_ENTER):
                overlay = None
            continue

        if key == curses.KEY_UP:
            selected = (selected - 1) % len(menu)
        elif key == curses.KEY_DOWN:
            selected = (selected + 1) % len(menu)
        elif key == curses.KEY_LEFT and selected == TOGGLE_ITEM_IDX:
            _single_app_idx[0] = (_single_app_idx[0] - 1) % len(_SINGLE_APPS)
        elif key == curses.KEY_RIGHT and selected == TOGGLE_ITEM_IDX:
            _single_app_idx[0] = (_single_app_idx[0] + 1) % len(_SINGLE_APPS)
        elif key in (curses.KEY_ENTER, ord("\n"), ord("\r")):
            result = menu[selected].action()
            if isinstance(result, tuple) and result[0] == "stay":
                status = result[1]
            elif isinstance(result, tuple) and result[0] == "overlay":
                overlay = result[1]
            elif isinstance(result, tuple) and result[0] == "restart":
                cfg    = load_config()
                menu   = _build_menu(cfg, stdscr, colors)
                status = f"Updated successfully  ·  now v{cfg['version']}"
        elif key in (ord("q"), 27):
            sys.exit(0)
        else:
            for i in range(len(menu)):
                if key == ord(str(i + 1)):
                    selected = i
                    result   = menu[i].action()
                    if isinstance(result, tuple) and result[0] == "stay":
                        status = result[1]
                    elif isinstance(result, tuple) and result[0] == "overlay":
                        overlay = result[1]
                    elif isinstance(result, tuple) and result[0] == "restart":
                        cfg    = load_config()
                        menu   = _build_menu(cfg, stdscr, colors)
                        status = f"Updated successfully  ·  now v{cfg['version']}"
                    break

# ── Uninstall ─────────────────────────────────────────────────────────────────

def _uninstall():
    """Remove all files and directories created or downloaded by the launcher.

    Preserves nodar_launcher.cfg (may contain user edits) and the script
    files themselves (nodar_launcher.py, nodar_launcher_run.sh), which are
    managed by install.sh / uninstall.sh.
    """
    targets = [
        UUID_FILE,
        ACTIVATION_KEY_FILE,
        DOWNLOAD_DIR,
    ] + [os.path.join(NODAR_DIR, "config", f) for f in CONFIG_FILES]

    for path in targets:
        if os.path.isfile(path):
            os.remove(path)
            print(f"  removed  {path}")
        elif os.path.isdir(path):
            shutil.rmtree(path)
            print(f"  removed  {path}/")
        else:
            print(f"  skipped  {path}  (not found)")

# ── Top-level dispatcher ──────────────────────────────────────────────────────

def _app(stdscr):
    colors = _init_colors(stdscr)

    hh_ok = _is_installed("hammerhead")
    nv_ok = _is_installed("nodar_viewer")

    uuid    = _load_uuid()
    act_key = _load_activation_key()

    # UUID is considered provided when both packages are already installed.
    need_uuid = (uuid is None) and not (hh_ok and nv_ok)
    need_key  = (act_key is None) and not os.path.isfile(LICENSE_ENC_FILE)

    if need_uuid or need_key:
        result = _setup_screen(stdscr, colors, need_uuid, need_key, pre_uuid=uuid)
        if result is None:
            return
        new_uuid, new_key = result
        if new_uuid is not None:
            uuid = new_uuid
            _save_uuid(uuid)
        if new_key is not None:
            act_key = new_key
            _save_activation_key(act_key)

    if not (hh_ok and nv_ok):
        packages = _fetch_and_confirm(stdscr, colors, uuid)
        if packages is None:
            return

        if not _download_and_install(stdscr, colors, uuid, packages):
            return

    cfg = load_config()
    _launcher_menu(stdscr, colors, cfg, act_key)


def main():
    import argparse
    ap = argparse.ArgumentParser(
        description="Nodar Launcher — interactive menu for Hammerhead & nodar_viewer."
    )
    ap.add_argument(
        "--uninstall", action="store_true",
        help="Remove all files created or downloaded by the launcher, then exit.",
    )
    args = ap.parse_args()

    if args.uninstall:
        _uninstall()
        return

    try:
        curses.wrapper(_app)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
