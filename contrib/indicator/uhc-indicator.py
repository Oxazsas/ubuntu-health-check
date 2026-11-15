#!/usr/bin/python3
# -----------------------------------------------------------------------------
# contrib/indicator/uhc-indicator.py — optional top-bar icon for
# ubuntu-health-check (Ubuntu Desktop only; the audit itself never needs it).
#
# Shows the state of the last audit, opens the reports, starts an audit and
# sets the schedule of the normal audit. Install it with
# 'uhc.sh --install-indicator' (autostart entry), remove it with
# 'uhc.sh --remove-indicator'.
#
#   /usr/bin/python3 -I contrib/indicator/uhc-indicator.py [--data-dir DIR]
#
# Security model:
#   - never runs as root; one instance per user (lock in XDG_RUNTIME_DIR);
#   - logs/uhc.log is untrusted data: each line is parsed field by field
#     against strict patterns, nothing in it is ever executed, and the only
#     value that reaches a command is the report path, checked against a
#     strict pattern, resolved, and required to be a regular file directly in
#     the reports/ folder of the data directory;
#   - every command is a list of arguments built from the tool directory (the
#     real location of this script), the data directory and constants; no
#     command line is ever given to a shell. The one shell script used (to
#     keep a terminal window open at the end) is a constant, its data comes as
#     separate arguments;
#   - programs are looked up in system directories only; no network access,
#     no password: sudo always runs in a terminal, where the user types it;
#   - the language catalogs (lib/lang/*/indicator.lang) are read as text.
#
# Everything that does not need the display (log parsing, state, path checks,
# commands, catalogs) is importable without gi; gi is imported in run_gui().
# Tests: contrib/indicator/test_indicator.py (no display needed).
# -----------------------------------------------------------------------------

import argparse
import datetime
import fcntl
import os
import re
import shlex
import shutil
import stat
import sys
import tempfile

# ---- constants ------------------------------------------------------------------
# An audit older than this is shown in grey, like no audit at all.
STALE_DAYS = 35
# Only the end of the log is read (it is capped at 1000 lines by uhc.sh).
LOG_TAIL_BYTES = 256 * 1024
# A longer line is not one written by uhc.sh.
MAX_LINE_LEN = 1024
# Catalogs and uhc.conf above this size are ignored.
MAX_TEXT_FILE = 256 * 1024
# Programs (terminal, sudo, xdg-open) are only looked up here.
SAFE_PATH = "/usr/local/bin:/usr/bin:/bin:/snap/bin"
# Root-owned copy used for full audits (same value as in uhc.sh).
ROOT_INSTALL_DIR = "/opt/ubuntu-health-check"
TIMER_FREQS = ("daily", "weekly", "monthly")
TIMER_STATES = ("none",) + TIMER_FREQS + ("custom",)
# Exit code of uhc.sh for usage errors and "another run is already in progress".
UHC_EXIT_STOPPED = 3
UHC_BUSY_TEXT = b"another run is already in progress"
# Safety net next to the file monitor: seconds between two cheap checks of
# the log (stat only), and between two readings of the schedule.
LOG_CHECK_SECONDS = 60
TIMER_CHECK_SECONDS = 1800
# Reading or changing the schedule is stopped after this delay (seconds).
STATUS_TIMEOUT = 30
INDICATOR_ID = "ubuntu-health-check"
ICON_NAMES = {
    "ok": "uhc-indicator-ok",
    "warning": "uhc-indicator-warning",
    "critical": "uhc-indicator-critical",
    "none": "uhc-indicator-unknown",
    "stale": "uhc-indicator-unknown",
}

# Terminals, in order of preference, with the arguments that make them run
# the rest of the command line as a program and its arguments (each checked
# against the terminal's own documentation; -e of x-terminal-emulator is the
# Debian policy for that name). tilix is left out: its -e takes one string.
TERMINALS = (
    ("ptyxis", ("--",)),
    ("gnome-terminal", ("--",)),
    ("kgx", ("--",)),
    ("konsole", ("-e",)),
    ("xfce4-terminal", ("-x",)),
    ("mate-terminal", ("-x",)),
    ("xterm", ("-e",)),
    ("x-terminal-emulator", ("-e",)),
)
# Constant script run in the terminal: first says what runs and why sudo asks
# for a password, shows the exact command, runs it, then shows the close
# message so that its output stays readable. $1 is the close message, $2 the
# introduction, the rest is the command, passed as separate arguments (shown
# with %q, never parsed).
HOLD_SCRIPT = ('msg=$1 intro=$2; shift 2; printf "%s\\n\\n  " "$intro"; printf "%q " "$@"; printf "\\n\\n"; '
               '"$@"; printf "\\n%s " "$msg"; read -r _ || :')

# ---- log of the audits (logs/uhc.log) --------------------------------------------
# Line written by uhc.sh (lib/report.sh, write_log); fields are only ever
# added at the end, and new= worse= resolved= are absent before 2.11.0:
#   2026-11-15T10:57:49+0100 exit=1 critical=0 warning=1 info=30 ok=25
#   partial=0 privileges=user code=ee00fc69391e51d5
#   report=reports/uhc-20261115-105749-host.md new=- worse=- resolved=-
REPORT_REL_RE = re.compile(r"reports/uhc-[0-9]{8}-[0-9]{6}-[A-Za-z0-9][A-Za-z0-9.-]{0,63}\.md\Z")
_TS_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}\Z")
_FIELD_RE = re.compile(r"([a-z]{1,32})=([\x21-\x7e]{0,256})\Z")
_PRINTABLE_RE = re.compile(r"[\x20-\x7e]*\Z")
_COUNT = r"(?:0|[1-9][0-9]{0,5})"
_FIELD_VALUE = {
    "exit": re.compile(r"[0-2]\Z"),
    "critical": re.compile(_COUNT + r"\Z"),
    "warning": re.compile(_COUNT + r"\Z"),
    "info": re.compile(_COUNT + r"\Z"),
    "ok": re.compile(_COUNT + r"\Z"),
    "partial": re.compile(_COUNT + r"\Z"),
    "privileges": re.compile(r"(?:user|root)\Z"),
    "code": re.compile(r"[0-9a-f]{16}\Z"),
    "report": REPORT_REL_RE,
    "new": re.compile(r"(?:-|" + _COUNT + r")\Z"),
    "worse": re.compile(r"(?:-|" + _COUNT + r")\Z"),
    "resolved": re.compile(r"(?:-|" + _COUNT + r")\Z"),
}
_REQUIRED = ("exit", "critical", "warning", "info", "ok", "partial", "privileges", "report")
_COUNTERS = ("critical", "warning", "info", "ok", "partial")
_COMPARE = ("new", "worse", "resolved")


def parse_log_line(line):
    """Return the audit record of one log line, or None if the line is not a
    complete, valid audit line (other messages, truncated or forged lines)."""
    if not isinstance(line, str) or len(line) > MAX_LINE_LEN or not _PRINTABLE_RE.match(line):
        return None
    tokens = line.split(" ")
    if len(tokens) < 1 + len(_REQUIRED) or not _TS_RE.match(tokens[0]):
        return None
    try:
        when = datetime.datetime.strptime(tokens[0], "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return None
    fields = {}
    for tok in tokens[1:]:
        m = _FIELD_RE.match(tok)
        if not m or m.group(1) in fields:
            return None
        key, value = m.group(1), m.group(2)
        check = _FIELD_VALUE.get(key)
        # Unknown keys may be added by later versions (at the end): ignored.
        if check is not None and not check.match(value):
            return None
        fields[key] = value
    if any(k not in fields for k in _REQUIRED) or ".." in fields["report"]:
        return None
    rec = {
        "time": when,
        "exit": int(fields["exit"]),
        "privileges": fields["privileges"],
        "report": fields["report"],
        "compare": None,
    }
    for k in _COUNTERS:
        rec[k] = int(fields[k])
    # The comparison counts only when the three fields are there and are numbers
    # ("-": no usable previous audit at this privilege level).
    if all(k in fields and fields[k] != "-" for k in _COMPARE):
        rec["compare"] = tuple(int(fields[k]) for k in _COMPARE)
    return rec


def read_tail(path, limit=LOG_TAIL_BYTES):
    """The last LIMIT bytes of PATH as text (first partial line dropped), or
    None: missing, not a regular file, a symlink, unreadable."""
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    try:
        fd = os.open(path, flags)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None
        start = max(0, st.st_size - limit)
        os.lseek(fd, start, os.SEEK_SET)
        chunks, left = [], limit
        while left > 0:
            data = os.read(fd, min(left, 65536))
            if not data:
                break
            chunks.append(data)
            left -= len(data)
    except OSError:
        return None
    finally:
        os.close(fd)
    text = b"".join(chunks).decode("ascii", errors="replace")
    if start > 0:
        text = text.partition("\n")[2]
    return text


def read_last_record(log_path):
    """The record of the last valid audit line of the log, or None."""
    text = read_tail(log_path)
    if not text:
        return None
    for line in reversed(text.split("\n")):
        rec = parse_log_line(line)
        if rec is not None:
            return rec
    return None


def log_signature(log_path):
    """Cheap change detector for the safety-net check: (inode, size, mtime)."""
    try:
        st = os.lstat(log_path)
    except OSError:
        return None
    return (st.st_ino, st.st_size, st.st_mtime_ns)


def audit_state(rec, now):
    """none, stale, critical, warning or ok. NOW is an aware datetime."""
    if rec is None:
        return "none"
    if now - rec["time"] > datetime.timedelta(days=STALE_DAYS):
        return "stale"
    if rec["critical"] > 0:
        return "critical"
    if rec["warning"] > 0:
        return "warning"
    return "ok"


def report_path(data_dir, rel):
    """Absolute path of the report named in the log, or None unless it matches
    the strict pattern and resolves to a regular file directly inside the
    reports/ folder of DATA_DIR (that folder itself not being a link out)."""
    if not isinstance(rel, str) or not REPORT_REL_RE.match(rel) or ".." in rel:
        return None
    try:
        data_real = os.path.realpath(data_dir)
        reports = os.path.join(data_real, "reports")
        if os.path.realpath(reports) != reports:
            return None
        target = os.path.realpath(os.path.join(data_real, rel))
        if os.path.dirname(target) != reports:
            return None
        if not stat.S_ISREG(os.stat(target).st_mode):
            return None
        return target
    except (OSError, ValueError):
        return None


def reports_dir(data_dir):
    """The reports/ folder of DATA_DIR if it is a real folder there, or None."""
    try:
        data_real = os.path.realpath(data_dir)
        reports = os.path.join(data_real, "reports")
        if os.path.realpath(reports) == reports and os.path.isdir(reports):
            return reports
    except (OSError, ValueError):
        pass
    return None


# ---- language catalogs ---------------------------------------------------------------
LANG_RE = re.compile(r"[a-z]{2}\Z")
_KEY_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
_VAR_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")
_MESSAGES = {}


def read_text(path, limit=MAX_TEXT_FILE):
    """Content of a regular text file (UTF-8, invalid bytes replaced), or None."""
    try:
        with open(path, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                return None
            data = f.read(limit + 1)
    except OSError:
        return None
    if len(data) > limit:
        return None
    return data.decode("utf-8", errors="replace")


def parse_catalog(text):
    """key=text lines, as lib/common.sh (load_lang) reads them."""
    out = {}
    for line in (text or "").split("\n"):
        line = line.rstrip("\r")
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if _KEY_RE.match(key):
            out[key] = value
    return out


def load_catalog(tool_dir, code):
    """English, then CODE over it (a missing key falls back to English)."""
    msgs = parse_catalog(read_text(os.path.join(tool_dir, "lib", "lang", "en", "indicator.lang")))
    if code != "en" and LANG_RE.match(code or ""):
        msgs.update(parse_catalog(read_text(os.path.join(tool_dir, "lib", "lang", code, "indicator.lang"))))
    return msgs


def set_catalog(msgs):
    _MESSAGES.clear()
    _MESSAGES.update(msgs)


def format_message(template, values):
    """Replace each {name} by its value in one pass (a value is never expanded
    again); an unknown {name} stays as it is."""
    return _VAR_RE.sub(lambda m: str(values[m.group(1)]) if m.group(1) in values else m.group(0), template)


def tr(key, **values):
    """The message KEY of the current language; an unknown key gives the key."""
    return format_message(_MESSAGES.get(key, key), values)


def report_lang_from_conf(path):
    """REPORT_LANG of uhc.conf when it is a two-letter code; None for auto,
    absent or invalid. Only this key is read, as uhc.sh (load_config) does:
    comment and spaces stripped, optional double quotes, last valid value wins."""
    text = read_text(path)
    if text is None:
        return None
    lang = None
    for line in text.split("\n"):
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if re.sub(r"\s", "", key) != "REPORT_LANG":
            continue
        value = value.split("#", 1)[0].strip()
        if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
            value = value[1:-1]
        if value == "auto" or LANG_RE.match(value):
            lang = value
    return lang if lang and LANG_RE.match(lang) else None


def locale_lang(environ, default_locale="/etc/default/locale"):
    """Two-letter code of the session's language, as uhc.sh reads it
    (UHC_LANG, LANGUAGE, LC_ALL, LC_MESSAGES, LANG, then the system default
    when the locale is C or POSIX), or None."""
    forced = environ.get("UHC_LANG", "")
    if LANG_RE.match(forced):
        return forced
    loc = environ.get("LANGUAGE", "").split(":")[0]
    if not loc:
        loc = environ.get("LC_ALL") or environ.get("LC_MESSAGES") or environ.get("LANG") or ""
    if not loc or loc in ("C", "POSIX") or loc.startswith("C."):
        loc = ""
        text = read_text(default_locale) or ""
        for line in text.split("\n"):
            m = re.match(r'\s*LANG="?([^"]*)', line)
            if m:
                loc = m.group(1)
    code = loc[:2]
    return code if LANG_RE.match(code) else None


def choose_lang(data_dir, environ, default_locale="/etc/default/locale"):
    """REPORT_LANG of DATA_DIR/uhc.conf, else the session's locale, else en."""
    return (report_lang_from_conf(os.path.join(data_dir, "uhc.conf"))
            or locale_lang(environ, default_locale) or "en")


# ---- menu texts ----------------------------------------------------------------------
def freq_label(state):
    """Label of a schedule state (none, daily, weekly, monthly, custom, unknown)."""
    if state == "none":
        return tr("ui.ind.sched.never")
    if state == "daily":
        return tr("ui.ind.sched.daily")
    if state == "weekly":
        return tr("ui.ind.sched.weekly")
    if state == "monthly":
        return tr("ui.ind.sched.monthly")
    if state == "custom":
        return tr("ui.ind.sched.custom")
    return tr("ui.ind.sched.unknown")


def icon_description(state):
    """Text read by screen readers for the icon of STATE."""
    if state == "ok":
        return tr("ui.ind.icon.ok")
    if state == "warning":
        return tr("ui.ind.icon.warning")
    if state == "critical":
        return tr("ui.ind.icon.critical")
    return tr("ui.ind.icon.unknown")


def status_lines(rec, state, now):
    """Lines of the status block at the top of the menu."""
    if rec is None:
        return [tr("ui.ind.status.none")]
    date = rec["time"].astimezone().strftime("%Y-%m-%d %H:%M")
    if rec["privileges"] == "root":
        priv = tr("ui.ind.priv.root")
    else:
        priv = tr("ui.ind.priv.user")
    lines = [tr("ui.ind.status.last", date=date, privileges=priv),
             tr("ui.ind.status.counts", critical=rec["critical"], warning=rec["warning"])]
    if rec["compare"] is not None:
        new, worse, resolved = rec["compare"]
        lines.append(tr("ui.ind.status.compare", new=new, worse=worse, resolved=resolved))
    if state == "stale":
        lines.append(tr("ui.ind.status.stale", days=(now - rec["time"]).days))
    return lines


# ---- commands (lists of arguments, never given to a shell) ----------------------------
def tool_dir_of(script):
    """The tool directory: two levels above the real location of this script."""
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(script))))


def uhc_argv(tool_dir):
    path = os.path.join(tool_dir, "uhc.sh")
    if os.access(path, os.X_OK):
        return [path]
    return ["/bin/bash", "-p", path]


def data_args(tool_dir, data_dir):
    """--data-dir DIR, unless DIR is the tool directory (uhc.sh's default)."""
    if os.path.realpath(data_dir) == os.path.realpath(tool_dir):
        return []
    return ["--data-dir", data_dir]


def audit_cmd(tool_dir, data_dir):
    return uhc_argv(tool_dir) + ["--quiet"] + data_args(tool_dir, data_dir)


def timer_status_cmd(tool_dir, data_dir):
    return uhc_argv(tool_dir) + data_args(tool_dir, data_dir) + ["--timer-status"]


def user_timer_cmd(tool_dir, data_dir, freq):
    """Install (FREQ) or remove (FREQ None) the user timer, without question."""
    if freq is None:
        return uhc_argv(tool_dir) + ["--remove-timer", "user", "--yes"]
    if freq not in TIMER_FREQS:
        raise ValueError("invalid frequency")
    return uhc_argv(tool_dir) + data_args(tool_dir, data_dir) + ["--install-timer", "user", freq, "--yes"]


def root_copy_installed(root_dir=ROOT_INSTALL_DIR):
    return os.path.isfile(os.path.join(root_dir, "uhc.sh"))


def root_audit_cmd(tool_dir, data_dir, installed, sudo="sudo", root_dir=ROOT_INSTALL_DIR):
    """Full audit from the root-owned copy; without it, 'sudo uhc.sh' of this
    folder, which only starts the installation wizard."""
    if installed:
        return [sudo, os.path.join(root_dir, "uhc.sh"), "--data-dir", data_dir]
    return [sudo, os.path.join(tool_dir, "uhc.sh")] + data_args(tool_dir, data_dir)


def root_timer_cmd(data_dir, freq, sudo="sudo", root_dir=ROOT_INSTALL_DIR):
    """Install (FREQ) or remove (FREQ None) the root timer; always asks in the
    terminal (never --yes)."""
    cmd = [sudo, os.path.join(root_dir, "uhc.sh"), "--data-dir", data_dir]
    if freq is None:
        return cmd + ["--remove-timer", "root"]
    if freq not in TIMER_FREQS:
        raise ValueError("invalid frequency")
    return cmd + ["--install-timer", "root", freq]


def find_program(name, search_path=SAFE_PATH):
    return shutil.which(name, path=search_path)


def find_terminal(search_path=SAFE_PATH):
    """(path, arguments before the command) of the first terminal found, or None.
    x-terminal-emulator uses the syntax of the terminal it points to, when known."""
    for name, prefix in TERMINALS:
        path = shutil.which(name, path=search_path)
        if not path:
            continue
        if name == "x-terminal-emulator":
            real = os.path.basename(os.path.realpath(path))
            for other, other_prefix in TERMINALS:
                if other == real:
                    prefix = other_prefix
        return (path, list(prefix))
    return None


def terminal_cmd(terminal, argv, close_msg, intro=""):
    """Open TERMINAL on ARGV, introduced by INTRO and the command itself, then
    keep the window until Enter is pressed."""
    path, prefix = terminal
    return ([path] + list(prefix) + ["/bin/bash", "-c", HOLD_SCRIPT, "uhc-indicator", close_msg, intro]
            + list(argv))


def display_cmd(argv):
    """ARGV as a command line to show the user (never run)."""
    return " ".join(shlex.quote(a) for a in argv)


def parse_timer_status(text):
    """{'user': STATE, 'root': STATE} from 'uhc.sh --timer-status', or None."""
    out = {}
    for line in (text or "").strip().split("\n"):
        m = re.match(r"(user|root)=([a-z]+)\Z", line)
        if not m or m.group(1) in out or m.group(2) not in TIMER_STATES:
            return None
        out[m.group(1)] = m.group(2)
    return out if set(out) == {"user", "root"} else None


def clean_output(data, limit=2000):
    """Output of uhc.sh shown in a message: printable text only, shortened."""
    text = data.decode("utf-8", errors="replace") if isinstance(data, bytes) else str(data or "")
    text = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", text)
    text = "".join(c for c in text if c in "\n\t" or (c.isprintable()))
    text = text.strip()
    return text if len(text) <= limit else text[:limit] + "…"


# ---- single instance ----------------------------------------------------------------
def lock_path(environ, uid=None):
    """Lock file: XDG_RUNTIME_DIR when it is a private folder of this user,
    else a per-user file in the temporary directory."""
    uid = os.getuid() if uid is None else uid
    rt = environ.get("XDG_RUNTIME_DIR", "")
    if rt.startswith("/"):
        try:
            st = os.stat(rt)
            if stat.S_ISDIR(st.st_mode) and st.st_uid == uid and not st.st_mode & 0o077:
                return os.path.join(rt, "uhc-indicator.lock")
        except OSError:
            pass
    return os.path.join(tempfile.gettempdir(), "uhc-indicator-%d.lock" % uid)


def acquire_lock(path):
    """An open descriptor holding the lock, or None (another instance, or a
    lock file that is not a regular file owned by this user)."""
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            os.close(fd)
            return None
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


# ---- display ----------------------------------------------------------------------------
def run_gui(tool_dir, data_dir):
    import signal

    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AI
    from gi.repository import Gio, GLib, Gtk

    ok, _ = Gtk.init_check(None)
    if not ok:
        print("uhc-indicator: no graphical session (cannot open the display)", file=sys.stderr)
        return 1

    class Indicator:
        def __init__(self):
            self.tool_dir = tool_dir
            self.data_dir = data_dir
            self.log_path = os.path.join(data_dir, "logs", "uhc.log")
            self.record = None
            self.signature = None
            self.report = None
            self.timers = None          # {'user': ..., 'root': ...} or None
            self.audit_running = False
            self.timer_busy = False
            self.updating_radios = False
            self.pending_refresh = 0
            icons = os.path.join(os.path.dirname(os.path.realpath(__file__)), "icons")
            self.ind = AI.Indicator.new_with_path(
                INDICATOR_ID, ICON_NAMES["none"],
                AI.IndicatorCategory.SYSTEM_SERVICES, icons)
            self.ind.set_title(tr("ui.ind.title"))
            self.ind.set_status(AI.IndicatorStatus.ACTIVE)
            self.build_menu()
            self.monitors = []
            self.watch(self.log_path, self.schedule_refresh)
            self.watch(os.path.join(self.user_unit_dir(), "uhc.timer"), self.refresh_timers)
            self.watch("/etc/systemd/system/uhc-root.timer", self.refresh_timers)
            self.refresh(force=True)
            self.refresh_timers()
            GLib.timeout_add_seconds(LOG_CHECK_SECONDS, self.on_log_tick)
            GLib.timeout_add_seconds(TIMER_CHECK_SECONDS, self.on_timer_tick)

        # -- menu ------------------------------------------------------------
        def item(self, label, callback=None, sensitive=True):
            it = Gtk.MenuItem.new_with_label(label)
            if callback is not None:
                it.connect("activate", lambda _w: callback())
            it.set_sensitive(sensitive)
            return it

        def build_menu(self):
            menu = Gtk.Menu()
            self.status_items = []
            for _ in range(4):
                it = self.item("", sensitive=False)
                menu.append(it)
                self.status_items.append(it)
            menu.append(Gtk.SeparatorMenuItem())
            self.open_report_item = self.item(tr("ui.ind.open_report"), self.open_report)
            menu.append(self.open_report_item)
            self.open_folder_item = self.item(tr("ui.ind.open_folder"), self.open_folder)
            menu.append(self.open_folder_item)
            menu.append(Gtk.SeparatorMenuItem())
            self.run_item = self.item(tr("ui.ind.run"), self.run_audit)
            menu.append(self.run_item)
            menu.append(self.item(tr("ui.ind.run_root"), self.run_root_audit))
            menu.append(Gtk.SeparatorMenuItem())

            # Schedule of the normal audit: radio buttons.
            sched = Gtk.Menu()
            self.radios = {}
            group = None
            for state, label in (("none", tr("ui.ind.sched.never")),
                                 ("daily", tr("ui.ind.sched.daily")),
                                 ("weekly", tr("ui.ind.sched.weekly")),
                                 ("monthly", tr("ui.ind.sched.monthly")),
                                 ("custom", tr("ui.ind.sched.custom"))):
                r = Gtk.RadioMenuItem.new_with_label_from_widget(group, label)
                group = r
                r.connect("toggled", self.on_radio, state)
                sched.append(r)
                self.radios[state] = r
            self.radios["custom"].set_sensitive(False)
            self.sched_note = self.item(tr("ui.ind.sched.unknown"), sensitive=False)
            sched.append(self.sched_note)
            sched_item = self.item(tr("ui.ind.sched"))
            sched_item.set_submenu(sched)
            menu.append(sched_item)

            # Schedule of the full audit: shown, changed in a terminal only.
            rsched = Gtk.Menu()
            self.root_state_item = self.item("", sensitive=False)
            rsched.append(self.root_state_item)
            rsched.append(Gtk.SeparatorMenuItem())
            self.root_actions = [
                self.item(tr("ui.ind.sched_root.set_daily"), lambda: self.root_timer("daily")),
                self.item(tr("ui.ind.sched_root.set_weekly"), lambda: self.root_timer("weekly")),
                self.item(tr("ui.ind.sched_root.set_monthly"), lambda: self.root_timer("monthly")),
                self.item(tr("ui.ind.sched_root.set_never"), lambda: self.root_timer(None)),
            ]
            for it in self.root_actions:
                rsched.append(it)
            self.root_no_copy = self.item(tr("ui.ind.sched_root.no_copy"), sensitive=False)
            rsched.append(self.root_no_copy)
            rsched_item = self.item(tr("ui.ind.sched_root"))
            rsched_item.set_submenu(rsched)
            menu.append(rsched_item)

            menu.append(Gtk.SeparatorMenuItem())
            menu.append(self.item(tr("ui.ind.quit"), Gtk.main_quit))
            menu.show_all()
            self.ind.set_menu(menu)

        # -- state of the last audit -------------------------------------------
        def watch(self, path, callback):
            try:
                mon = Gio.File.new_for_path(path).monitor_file(Gio.FileMonitorFlags.NONE, None)
            except GLib.Error:
                return
            mon.connect("changed", lambda *_a: callback())
            self.monitors.append(mon)

        def schedule_refresh(self):
            # Several events arrive for one write: refresh once, shortly after.
            if not self.pending_refresh:
                self.pending_refresh = GLib.timeout_add(500, self.on_pending_refresh)

        def on_pending_refresh(self):
            self.pending_refresh = 0
            self.refresh(force=True)
            return False

        def on_log_tick(self):
            self.refresh(force=False)
            return True

        def refresh(self, force):
            sig = log_signature(self.log_path)
            if force or sig != self.signature:
                self.signature = sig
                self.record = read_last_record(self.log_path)
            now = datetime.datetime.now(datetime.timezone.utc)
            state = audit_state(self.record, now)
            self.report = report_path(self.data_dir, self.record["report"]) if self.record else None
            self.ind.set_icon_full(ICON_NAMES[state], icon_description(state))
            lines = status_lines(self.record, state, now)
            for i, it in enumerate(self.status_items):
                if i < len(lines):
                    it.set_label(lines[i])
                    it.show()
                else:
                    it.hide()
            self.open_report_item.set_sensitive(self.report is not None)
            self.open_folder_item.set_sensitive(reports_dir(self.data_dir) is not None)
            self.update_root_menu()

        # -- opening files ----------------------------------------------------------
        def open_path(self, path):
            if path is None:
                return
            try:
                if Gio.AppInfo.launch_default_for_uri(Gio.File.new_for_path(path).get_uri(), None):
                    return
            except GLib.Error:
                pass
            xdg = find_program("xdg-open")
            if xdg and self.spawn([xdg, path], None, quiet=True):
                return
            self.message(tr("ui.ind.msg.open_failed", path=path))

        def open_report(self):
            self.refresh(force=True)
            self.open_path(self.report)

        def open_folder(self):
            self.open_path(reports_dir(self.data_dir))

        # -- commands ---------------------------------------------------------------
        def spawn(self, argv, callback, quiet=False, timeout=0):
            """Start ARGV (a list, run directly, never through a shell);
            CALLBACK(rc, stdout, stderr) at the end; after TIMEOUT seconds
            (0: none) the program is stopped. False if it could not start."""
            flags = Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            if quiet:
                flags = Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE
            launcher = Gio.SubprocessLauncher.new(flags)
            launcher.set_cwd(self.data_dir)
            try:
                proc = launcher.spawnv(argv)
            except GLib.Error:
                if callback is not None:
                    self.message(tr("ui.ind.msg.start_failed", program=argv[0]))
                return False
            if callback is None:
                proc.wait_async(None, None, None)
                return True
            timer = [0]
            if timeout:
                def stop():
                    timer[0] = 0
                    proc.force_exit()
                    return False
                timer[0] = GLib.timeout_add_seconds(timeout, stop)
            proc.communicate_async(None, None, self.on_spawn_done, (callback, timer))
            return True

        def on_spawn_done(self, proc, res, data):
            callback, timer = data
            if timer[0]:
                GLib.source_remove(timer[0])
                timer[0] = 0
            out = err = b""
            try:
                _ok, o, e = proc.communicate_finish(res)
                out = o.get_data() if o is not None else b""
                err = e.get_data() if e is not None else b""
            except GLib.Error:
                pass
            rc = proc.get_exit_status() if proc.get_if_exited() else None
            callback(rc, out, err)

        def run_audit(self):
            if self.audit_running:
                return
            if self.spawn(audit_cmd(self.tool_dir, self.data_dir), self.on_audit_done):
                self.audit_running = True
                self.run_item.set_label(tr("ui.ind.running"))
                self.run_item.set_sensitive(False)

        def on_audit_done(self, rc, _out, err):
            self.audit_running = False
            self.run_item.set_label(tr("ui.ind.run"))
            self.run_item.set_sensitive(True)
            self.refresh(force=True)
            if rc in (0, 1, 2):
                return
            if rc == UHC_EXIT_STOPPED and UHC_BUSY_TEXT in err:
                self.message(tr("ui.ind.msg.busy"))
            else:
                self.message(tr("ui.ind.msg.audit_failed", code=rc if rc is not None else "?"),
                             clean_output(err))

        def in_terminal(self, argv, title, body):
            """Say what will run and why a password will be asked, then, once
            confirmed, open a terminal on ARGV (sudo asks there, never here)."""
            sudo = find_program("sudo")
            shown = ["sudo"] + argv[1:]
            term = find_terminal()
            if sudo is None or term is None:
                self.message(tr("ui.ind.msg.no_terminal"), display_cmd(shown))
                return

            def go():
                self.spawn(terminal_cmd(term, [sudo] + argv[1:], tr("ui.ind.term.close"), tr("ui.ind.term.intro")),
                           None, quiet=True) or self.message(tr("ui.ind.msg.start_failed", program=term[0]))
            self.confirm(title, body + "\n\n" + display_cmd(shown), go)

        def run_root_audit(self):
            self.in_terminal(root_audit_cmd(self.tool_dir, self.data_dir, root_copy_installed()),
                             tr("ui.ind.confirm.root_audit.title"), tr("ui.ind.confirm.root_audit.body"))

        def root_timer(self, freq):
            if freq is None:
                title, body = tr("ui.ind.confirm.root_timer_remove.title"), tr("ui.ind.confirm.root_timer_remove.body")
            else:
                title = tr("ui.ind.confirm.root_timer.title", freq=freq_label(freq))
                body = tr("ui.ind.confirm.root_timer.body")
            self.in_terminal(root_timer_cmd(self.data_dir, freq), title, body)

        # -- schedule -----------------------------------------------------------------
        def user_unit_dir(self):
            base = os.environ.get("XDG_CONFIG_HOME", "")
            if not base.startswith("/"):
                base = os.path.join(os.path.expanduser("~"), ".config")
            return os.path.join(base, "systemd", "user")

        def on_timer_tick(self):
            self.refresh_timers()
            return True

        def refresh_timers(self):
            if not self.timer_busy:
                self.spawn(timer_status_cmd(self.tool_dir, self.data_dir), self.on_timer_status,
                           timeout=STATUS_TIMEOUT)

        def on_timer_status(self, rc, out, _err):
            self.timers = parse_timer_status(out.decode("ascii", errors="replace")) if rc == 0 else None
            self.update_radios()
            self.update_root_menu()

        def update_radios(self):
            state = self.timers["user"] if self.timers else None
            self.updating_radios = True
            if state in self.radios:
                self.radios[state].set_active(True)
            self.updating_radios = False
            self.radios["custom"].set_visible(state == "custom")
            for name, r in self.radios.items():
                r.set_sensitive(name != "custom" and state is not None and not self.timer_busy)
            self.sched_note.set_visible(state is None or self.timer_busy)
            self.sched_note.set_label(tr("ui.ind.sched.busy") if self.timer_busy else tr("ui.ind.sched.unknown"))

        def on_radio(self, radio, state):
            if self.updating_radios or not radio.get_active() or self.timer_busy:
                return
            if self.timers is None or state == self.timers["user"] or state == "custom":
                return
            freq = None if state == "none" else state
            if self.spawn(user_timer_cmd(self.tool_dir, self.data_dir, freq), self.on_timer_changed,
                          timeout=STATUS_TIMEOUT):
                self.timer_busy = True
            self.update_radios()

        def on_timer_changed(self, rc, _out, err):
            self.timer_busy = False
            if rc != 0:
                self.message(tr("ui.ind.msg.sched_failed"), clean_output(err))
            # Back to the real state, whatever happened.
            self.refresh_timers()
            self.update_radios()

        def update_root_menu(self):
            installed = root_copy_installed()
            state = self.timers["root"] if self.timers else None
            self.root_state_item.set_label(tr("ui.ind.sched_root.now", state=freq_label(state)))
            for it in self.root_actions:
                it.set_visible(installed)
            self.root_no_copy.set_visible(not installed)

        # -- messages -----------------------------------------------------------------
        def confirm(self, primary, secondary, on_yes):
            """Ask before doing something; ON_YES runs only after Continue."""
            d = Gtk.MessageDialog(message_type=Gtk.MessageType.QUESTION,
                                  buttons=Gtk.ButtonsType.NONE, text=primary)
            d.props.secondary_text = secondary
            d.set_title(tr("ui.ind.title"))
            d.add_button(tr("ui.ind.confirm.cancel"), Gtk.ResponseType.CANCEL)
            d.add_button(tr("ui.ind.confirm.continue"), Gtk.ResponseType.OK)
            d.set_default_response(Gtk.ResponseType.CANCEL)
            for child in d.get_message_area().get_children():
                if isinstance(child, Gtk.Label):
                    child.set_selectable(True)

            def on_response(w, r):
                w.destroy()
                if r == Gtk.ResponseType.OK:
                    on_yes()
            d.connect("response", on_response)
            d.show_all()

        def message(self, primary, secondary=""):
            d = Gtk.MessageDialog(message_type=Gtk.MessageType.INFO,
                                  buttons=Gtk.ButtonsType.CLOSE, text=primary)
            d.props.secondary_text = secondary or None
            d.set_title(tr("ui.ind.title"))
            for child in d.get_message_area().get_children():
                if isinstance(child, Gtk.Label):
                    child.set_selectable(True)
            d.connect("response", lambda w, _r: w.destroy())
            d.show_all()

    # Tray icons need a StatusNotifierWatcher (under GNOME: the AppIndicator
    # extension). Without one, the icon stays invisible: say it.
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        has = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                            "NameHasOwner", GLib.Variant("(s)", ("org.kde.StatusNotifierWatcher",)),
                            GLib.VariantType.new("(b)"), Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
        if not has:
            print("uhc-indicator: no StatusNotifierWatcher on the session bus: the icon will not be"
                  " visible until one runs (GNOME: enable the 'Ubuntu AppIndicators' extension)",
                  file=sys.stderr)
    except GLib.Error:
        pass

    Indicator()
    try:
        from gi.repository import GLibUnix
        signal_add = GLibUnix.signal_add
    except ImportError:             # GLib before 2.80
        signal_add = GLib.unix_signal_add
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal_add(GLib.PRIORITY_DEFAULT, sig, lambda *_a: Gtk.main_quit() or False)
    Gtk.main()
    return 0


# ---- entry point --------------------------------------------------------------------------
def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="uhc-indicator",
        description="Top-bar icon for ubuntu-health-check: state of the last audit, reports, schedule.")
    parser.add_argument("--data-dir", metavar="DIR",
                        help="folder holding reports/ and logs/ (default: the tool directory)")
    args = parser.parse_args(argv)
    if os.geteuid() == 0:
        print("uhc-indicator: refusing to run as root (it belongs to your desktop session)", file=sys.stderr)
        return 3
    tool_dir = tool_dir_of(__file__)
    if not os.path.isfile(os.path.join(tool_dir, "uhc.sh")):
        print("uhc-indicator: uhc.sh not found in %s" % tool_dir, file=sys.stderr)
        return 3
    data_dir = os.path.realpath(args.data_dir or tool_dir)
    if not os.path.isdir(data_dir):
        print("uhc-indicator: data directory does not exist: %s" % data_dir, file=sys.stderr)
        return 3
    lock = acquire_lock(lock_path(os.environ))
    if lock is None:
        print("uhc-indicator: already running", file=sys.stderr)
        return 0
    set_catalog(load_catalog(tool_dir, choose_lang(data_dir, os.environ)))
    return run_gui(tool_dir, data_dir)


if __name__ == "__main__":
    sys.exit(main())
