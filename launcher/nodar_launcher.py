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
import urllib.error
import urllib.parse
import urllib.request
import zipfile

# ── Paths ─────────────────────────────────────────────────────────────────────

HERE           = os.path.dirname(os.path.abspath(__file__))
NODAR_DIR      = os.path.expanduser("~/.config/nodar")
UUID_FILE      = os.path.join(NODAR_DIR, "uuid")
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

# ── Layout ────────────────────────────────────────────────────────────────────

DESIGN_W = 100
MIN_ROWS  = 32

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
        raise RuntimeError("UUID not recognised or licence expired.")
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
        "records_dir":   "~/Desktop/nodar_recordings",
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
        "records_dir":   _path("records_dir"),
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


def _put(win, y, x, text, attr=0, max_w=None):
    if max_w is not None:
        text = text[:max_w]
    try:
        win.addstr(y, x, text, attr)
    except curses.error:
        pass

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

# ── Shared header drawing ─────────────────────────────────────────────────────

def _draw_header(stdscr, colors, subtitle):
    """Draw outer box, NODAR logo, subtitle, separator.

    Returns (bx, bw, inner_w, sep_row).
    """
    rows, cols = stdscr.getmaxyx()
    bx      = (cols - DESIGN_W) // 2
    bw      = DESIGN_W
    inner_w = bw - 2

    _box(stdscr, 0, bx, rows, bw)

    logo_max_w = max(len(l) for l in LOGO)
    logo_x     = bx + 1 + (inner_w - logo_max_w) // 2
    for i, line in enumerate(LOGO):
        _put(stdscr, 1 + i, logo_x, line, colors["art"], inner_w)

    logo_bottom  = 1 + len(LOGO)
    subtitle_row = logo_bottom + 1
    _put(stdscr, subtitle_row,
         bx + 1 + (inner_w - len(subtitle)) // 2, subtitle, colors["hint"])

    sep_row = subtitle_row + 1
    _hline(stdscr, sep_row, bx, bw)
    return bx, bw, inner_w, sep_row


def _size_ok(stdscr):
    rows, cols = stdscr.getmaxyx()
    return cols >= DESIGN_W and rows >= MIN_ROWS

# ── UUID input screen ─────────────────────────────────────────────────────────

def _uuid_screen(stdscr, colors):
    """Show UUID prompt. Returns validated UUID string or None (quit)."""
    buf   = []
    error = ""
    curses.curs_set(1)

    while True:
        rows, cols = stdscr.getmaxyx()
        stdscr.erase()

        if not _size_ok(stdscr):
            msg = f"  Terminal too small — need {DESIGN_W}×{MIN_ROWS}, currently {cols}×{rows}."
            _put(stdscr, rows // 2, max(0, (cols - len(msg)) // 2), msg[:cols], curses.A_BOLD)
            stdscr.refresh()
            stdscr.getch()
            continue

        bx, bw, inner_w, sep_row = _draw_header(
            stdscr, colors, "Nodar Launcher  ·  First-time Setup"
        )

        my = sep_row + 2
        for line in [
            "Welcome to the Nodar HDK Launcher.",
            "",
            "Hammerhead and Nodar Viewer are not yet installed on this system.",
            "Please enter your customer UUID (from the email you received) to",
            "download and install the software.",
            "",
        ]:
            _put(stdscr, my, bx + 4, line, colors["normal"], inner_w - 4)
            my += 1

        prompt  = "UUID : "
        field_x = bx + 4 + len(prompt)
        _put(stdscr, my, bx + 4, prompt, colors["bold"])
        _put(stdscr, my, field_x, ("".join(buf)).ljust(36), colors["sel"])

        if error:
            _put(stdscr, my + 2, bx + 4, error, colors["err"], inner_w - 4)

        hint = "  Enter  Confirm    q  Quit  "
        _put(stdscr, rows - 2, bx + (bw - len(hint)) // 2, hint, colors["hint"])

        try:
            stdscr.move(my, field_x + len(buf))
        except curses.error:
            pass

        stdscr.refresh()
        key = stdscr.getch()

        if key in (curses.KEY_ENTER, ord("\n"), ord("\r")):
            uuid = "".join(buf).strip()
            if UUID_RE.match(uuid):
                curses.curs_set(0)
                return uuid
            error = "Invalid UUID — expected format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        elif key in (curses.KEY_BACKSPACE, 127, 8):
            if buf:
                buf.pop()
            error = ""
        elif key in (ord("q"), 27):
            curses.curs_set(0)
            return None
        elif 32 <= key < 128 and len(buf) < 36:
            buf.append(chr(key))
            error = ""

# ── Installer: detect system + confirm ───────────────────────────────────────

def _detect_and_confirm(stdscr, colors, uuid):
    """Detect system, fetch package list, show confirmation.

    Returns list of two package dicts [hh, nv], or None if user cancelled.
    """
    rows, cols = stdscr.getmaxyx()
    stdscr.erase()
    bx, bw, inner_w, sep_row = _draw_header(
        stdscr, colors, "Nodar Launcher  ·  Installation"
    )
    my = sep_row + 2

    def line(text, color=None):
        nonlocal my
        _put(stdscr, my, bx + 4, text, color or colors["normal"], inner_w - 4)
        my += 1
        stdscr.refresh()

    line("Detecting system configuration...")
    my += 1

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

    my += 1
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
    my += 1
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

    my += 1
    line("The following will be downloaded and installed:", colors["bold"])
    my += 1
    line(f"  {hh_pkg['filename']}")
    line(f"  {nv_pkg['filename']}")
    line(f"  {DATASET_ZIP}  (sample dataset)")

    # Confirmation bar at bottom
    sep_y  = rows - 3
    hint_y = rows - 2
    if sep_y > my:
        _hline(stdscr, sep_y, bx, bw)
    hint = "  Enter  Download & Install    q  Cancel  "
    _put(stdscr, hint_y, bx + (bw - len(hint)) // 2, hint, colors["hint"])
    stdscr.refresh()

    while True:
        key = stdscr.getch()
        if key in (curses.KEY_ENTER, ord("\n"), ord("\r")):
            return [hh_pkg, nv_pkg]
        if key in (ord("q"), 27):
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
        bx, bw, inner_w, sep_row = _draw_header(
            stdscr, colors, "Nodar Launcher  ·  Downloading"
        )
        bar_w = inner_w - 28
        my    = sep_row + 2

        for it in items:
            _put(stdscr, my, bx + 4, it["label"][:inner_w - 4], colors["bold"])
            my += 1
            if it["state"] == "waiting":
                bar = "░" * bar_w
                _put(stdscr, my, bx + 4, f"[{bar}]  waiting...", colors["dim"])
            elif it["state"] in ("done", "skipped"):
                bar  = "█" * bar_w
                note = "done" if it["state"] == "done" else "already downloaded"
                _put(stdscr, my, bx + 4, f"[{bar}]  {note}", colors["desc"])
            elif it["state"] == "downloading":
                pct  = it["done"] / it["total"] if it["total"] else 0
                fill = int(bar_w * pct)
                bar  = "█" * fill + "░" * (bar_w - fill)
                info = f"{pct * 100:3.0f}%  {it['done'] / 1_048_576:.1f} / {it['total'] / 1_048_576:.1f} MB"
                _put(stdscr, my, bx + 4, f"[{bar}]  {info}", colors["normal"])
            my += 2

        _put(stdscr, rows - 2, bx + 4, status_line, colors["hint"])
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
            rows, cols = stdscr.getmaxyx()
            stdscr.erase()
            bx, bw, inner_w, sep_row = _draw_header(
                stdscr, colors, "Nodar Launcher  ·  Download Error"
            )
            _put(stdscr, sep_row + 2, bx + 4,
                 f"Download failed: {e}"[:inner_w - 4], colors["err"])
            _put(stdscr, sep_row + 4, bx + 4, "Press any key to exit.", colors["hint"])
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
            rows, cols = stdscr.getmaxyx()
            stdscr.erase()
            bx, bw, inner_w, sep_row = _draw_header(
                stdscr, colors, "Nodar Launcher  ·  Error"
            )
            _put(stdscr, sep_row + 2, bx + 4,
                 f"Unzip failed: {e}"[:inner_w - 4], colors["err"])
            _put(stdscr, sep_row + 4, bx + 4, "Press any key to exit.", colors["hint"])
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
    rows, cols = stdscr.getmaxyx()
    stdscr.erase()
    bx, bw, inner_w, sep_row = _draw_header(
        stdscr, colors, "Nodar Launcher  ·  Installing"
    )
    _put(stdscr, sep_row + 2, bx + 4,
         "Downloads complete. Ready to install packages with apt.", colors["bold"])
    _put(stdscr, sep_row + 4, bx + 4,
         "The terminal will switch to normal mode — sudo may prompt for your password.",
         colors["normal"])
    _put(stdscr, sep_row + 6, bx + 4,
         "Press Enter to proceed, or q to cancel.", colors["hint"])
    stdscr.refresh()

    while True:
        key = stdscr.getch()
        if key in (curses.KEY_ENTER, ord("\n"), ord("\r")):
            break
        if key in (ord("q"), 27):
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


_SINGLE_APPS     = ("Hammerhead", "Nodar Viewer")
_SINGLE_CMD_KEYS = ("hammerhead", "nodar_viewer")
_single_app_idx  = [0]
TOGGLE_ITEM_IDX  = 1


def _make_actions(cfg):
    def _run_single():
        name = _SINGLE_APPS[_single_app_idx[0]]
        cmd  = cfg[_SINGLE_CMD_KEYS[_single_app_idx[0]]]
        ok, term = _open_in_terminal(cmd)
        if ok:
            return ("stay", f"{name} launched in a new {term} window")
        return ("stay", "No terminal emulator found — install gnome-terminal or xterm")

    def _run_with_viewer():
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

    def _open_records():
        folder = cfg["records_dir"]
        if not os.path.isdir(folder):
            return ("stay", f"Directory not found:  {folder}")
        try:
            subprocess.Popen(["xdg-open", folder],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return ("stay", f"Opened  {folder}")
        except FileNotFoundError:
            return ("stay", f"xdg-open not available — records are in:  {folder}")

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
        cmd = cfg["hammerhead"] + ["--version"]
        try:
            out   = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True, timeout=5)
            lines = out.rstrip().splitlines()
        except FileNotFoundError:
            lines = [f"Command not found: {cmd[0]}"]
        except subprocess.TimeoutExpired:
            lines = ["Timed out waiting for hammerhead --version"]
        except subprocess.CalledProcessError as e:
            lines = (e.output or "").rstrip().splitlines() or ["Command failed"]
        return ("overlay", lines)

    return _run_with_viewer, _run_single, _open_records, _open_config_folder, _show_version_info

# ── Menu definition ───────────────────────────────────────────────────────────

class MenuItem:
    def __init__(self, title, description, action):
        self.title       = title
        self.description = description
        self.action      = action


def _build_menu(cfg):
    rw, rs, orec, omc, svi = _make_actions(cfg)
    return [
        MenuItem("Launch Hammerhead + Nodar Viewer",
                 "Start real-time stereo matching with live viewer display", rw),
        MenuItem("Launch Single App",
                 "Launch selected app without the other  ·  ◄ ► to switch", rs),
        MenuItem("Open Records Folder",
                 f"Browse saved recordings  ({cfg['records_dir']})", orec),
        MenuItem("Open Config Folder",
                 f"Browse config files (master, intrinsics, extrinsics)  ({os.path.dirname(cfg['master_config'])})", omc),
        MenuItem("Show Version Info",
                 "Display the full output of  hammerhead --version", svi),
        MenuItem("Exit", "Quit this launcher", lambda: sys.exit(0)),
    ]

# ── Launcher menu ─────────────────────────────────────────────────────────────

def _launcher_menu(stdscr, colors, cfg):
    os.makedirs(cfg["records_dir"], exist_ok=True)
    os.makedirs(os.path.dirname(cfg["master_config"]), exist_ok=True)

    menu     = _build_menu(cfg)
    selected = 0
    status   = ""
    overlay  = None
    logo_max_w = max(len(l) for l in LOGO)

    while True:
        rows, cols = stdscr.getmaxyx()
        stdscr.erase()

        if cols < DESIGN_W or rows < MIN_ROWS:
            msg = (f"  Terminal too small — need {DESIGN_W}×{MIN_ROWS},"
                   f" currently {cols}×{rows}.  Resize and press any key.")
            _put(stdscr, rows // 2, max(0, (cols - len(msg)) // 2), msg[:cols], curses.A_BOLD)
            stdscr.refresh()
            if stdscr.getch() in (ord("q"), 27):
                sys.exit(0)
            continue

        bx      = (cols - DESIGN_W) // 2
        bw      = DESIGN_W
        bh      = rows
        inner_w = bw - 2

        _box(stdscr, 0, bx, bh, bw)

        logo_x      = bx + 1 + (inner_w - logo_max_w) // 2
        logo_bottom = 1 + len(LOGO)
        for i, line in enumerate(LOGO):
            _put(stdscr, 1 + i, logo_x, line, colors["art"], inner_w)

        subtitle_row = logo_bottom + 1
        subtitle     = f"Nodar  Launcher  ·  v{cfg['version']}"
        _put(stdscr, subtitle_row,
             bx + 1 + (inner_w - len(subtitle)) // 2, subtitle, colors["hint"])

        sep_row = subtitle_row + 1
        _hline(stdscr, sep_row, bx, bw)

        menu_inner = bw - 4
        my = sep_row + 1

        for idx, item in enumerate(menu):
            is_sel = (idx == selected)
            tag    = f" [{idx + 1}]  "

            if idx == TOGGLE_ITEM_IDX:
                app_name = _SINGLE_APPS[_single_app_idx[0]]
                title_s  = (tag + f"Launch   ◄  {app_name}  ►").ljust(menu_inner)
            else:
                title_s = (tag + item.title).ljust(menu_inner)

            desc_s = "       " + item.description

            if is_sel:
                _put(stdscr, my,     bx + 2, title_s[:menu_inner], colors["sel"])
                _put(stdscr, my + 1, bx + 2, desc_s[:menu_inner],  colors["desc"])
            else:
                _put(stdscr, my,     bx + 2, title_s[:menu_inner], colors["normal"])
                _put(stdscr, my + 1, bx + 2, desc_s[:menu_inner],  colors["dim"])

            my += 3 if idx < len(menu) - 1 else 2

        hint_sep = bh - 3
        if hint_sep > my:
            _hline(stdscr, hint_sep, bx, bw)
            if status:
                _put(stdscr, hint_sep + 1, bx + 3, status[:bw - 6], colors["status"])
            else:
                if selected == TOGGLE_ITEM_IDX:
                    hint = "  ↑↓  Navigate    Enter  Launch    ◄►  Switch App    q  Quit  "
                else:
                    hint = "  ↑↓  Navigate    Enter / 1–6  Select    q  Quit  "
                _put(stdscr, hint_sep + 1,
                     bx + (bw - len(hint)) // 2, hint, colors["hint"])

        if overlay is not None:
            content_w = max((len(l) for l in overlay), default=0)
            box_w     = min(content_w + 6, bw - 4)
            box_h     = len(overlay) + 4
            oy        = max(0, (bh - box_h) // 2)
            ox        = bx + (bw - box_w) // 2
            _box(stdscr, oy, ox, box_h, box_w)
            blank = " " * (box_w - 2)
            for row in range(1, box_h - 1):
                _put(stdscr, oy + row, ox + 1, blank, colors["normal"])
            for i, line in enumerate(overlay):
                _put(stdscr, oy + 1 + i, ox + 3, line, colors["normal"], box_w - 6)
            _hline(stdscr, oy + 1 + len(overlay), ox, box_w)
            hint_ov = "  Space / Enter to close  "
            _put(stdscr, oy + 2 + len(overlay),
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
                    break

# ── Top-level dispatcher ──────────────────────────────────────────────────────

def _app(stdscr):
    colors = _init_colors(stdscr)

    hh_ok = _is_installed("hammerhead")
    nv_ok = _is_installed("nodar_viewer")

    if not (hh_ok and nv_ok):
        uuid = _load_uuid()
        if uuid is None:
            uuid = _uuid_screen(stdscr, colors)
            if uuid is None:
                return
            _save_uuid(uuid)

        packages = _detect_and_confirm(stdscr, colors, uuid)
        if packages is None:
            return

        if not _download_and_install(stdscr, colors, uuid, packages):
            return

    cfg = load_config()
    _launcher_menu(stdscr, colors, cfg)


def main():
    try:
        curses.wrapper(_app)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
