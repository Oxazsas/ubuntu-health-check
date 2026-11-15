#!/usr/bin/python3
# -----------------------------------------------------------------------------
# contrib/indicator/test_indicator.py — tests of the top-bar icon's logic
# (log parsing, state, report path checks, commands, catalogs, lock), without
# gi and without a display. Standard library only:
#
#   python3 -B contrib/indicator/test_indicator.py      (or: -m unittest)
# -----------------------------------------------------------------------------

import datetime
import importlib.util
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.realpath(__file__))
TOOL = os.path.dirname(os.path.dirname(HERE))
SCRIPT = os.path.join(HERE, "uhc-indicator.py")

sys.dont_write_bytecode = True
_gi_before = "gi" in sys.modules
_spec = importlib.util.spec_from_file_location("uhc_indicator", SCRIPT)
ind = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ind)

UTC = datetime.timezone.utc
NEW = ("2026-11-15T10:57:49+0100 exit=2 critical=3 warning=1 info=30 ok=25 partial=0 "
       "privileges=root code=ee00fc69391e51d5 report=reports/uhc-20261115-105749-myhost.md "
       "new=2 worse=1 resolved=4")
OLD = ("2026-11-14T23:21:45+0100 exit=1 critical=0 warning=1 info=26 ok=23 partial=0 "
       "privileges=user code=22b80beae153b41f report=reports/uhc-20261114-232145-host.md")
DASH = OLD.replace("privileges=user", "privileges=root") + " new=- worse=- resolved=-"


def line_at(when, critical=0, warning=0, report="reports/uhc-20261115-105749-host.md", extra=""):
    return ("%s exit=0 critical=%d warning=%d info=1 ok=1 partial=0 privileges=user "
            "code=0123456789abcdef report=%s%s" % (when.strftime("%Y-%m-%dT%H:%M:%S%z"),
                                                    critical, warning, report, extra))


class TempDir(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, rel, content, mode="w"):
        path = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, mode) as f:
            f.write(content)
        return path


class ImportTest(unittest.TestCase):
    def test_no_gi_at_import(self):
        if not _gi_before:
            self.assertNotIn("gi", sys.modules)


class ParseLineTest(unittest.TestCase):
    def test_new_format(self):
        r = ind.parse_log_line(NEW)
        self.assertEqual(r["critical"], 3)
        self.assertEqual(r["warning"], 1)
        self.assertEqual(r["exit"], 2)
        self.assertEqual(r["privileges"], "root")
        self.assertEqual(r["report"], "reports/uhc-20261115-105749-myhost.md")
        self.assertEqual(r["compare"], (2, 1, 4))
        self.assertEqual(r["time"], datetime.datetime(2026, 11, 15, 9, 57, 49, tzinfo=UTC))

    def test_old_format_without_comparison(self):
        r = ind.parse_log_line(OLD)
        self.assertIsNotNone(r)
        self.assertIsNone(r["compare"])
        self.assertEqual(r["privileges"], "user")

    def test_dash_comparison(self):
        r = ind.parse_log_line(DASH)
        self.assertIsNotNone(r)
        self.assertIsNone(r["compare"])

    def test_partial_comparison_ignored(self):
        self.assertIsNone(ind.parse_log_line(OLD + " new=1 worse=-")["compare"])

    def test_future_field_tolerated(self):
        self.assertIsNotNone(ind.parse_log_line(NEW + " later=x1"))

    def test_every_truncation_is_safe(self):
        # Each prefix is either rejected or a record whose report is complete.
        for n in range(len(NEW)):
            r = ind.parse_log_line(NEW[:n])
            if r is not None:
                self.assertEqual(r["report"], "reports/uhc-20261115-105749-myhost.md")
                self.assertEqual(r["critical"], 3)

    def test_rejected_lines(self):
        bad = [
            "",
            "2026-11-15T10:57:49+0100 notification not sent: notify-send not installed",
            OLD.replace("reports/uhc-20261114-232145-host.md", "../../etc/passwd"),
            OLD.replace("reports/uhc-20261114-232145-host.md", "/etc/passwd"),
            OLD.replace("reports/uhc-20261114-232145-host.md", "reports/../../etc/x.md"),
            OLD.replace("reports/uhc-20261114-232145-host.md", "reports/uhc-20261114-232145-a..b.md"),
            OLD.replace("reports/uhc-20261114-232145-host.md", "reports/uhc-20261114-232145-my host.md"),
            OLD.replace("host.md", "host.md.sh"),
            OLD.replace("host", "h\x1b[31mx"),
            OLD + "\x1b]0;title\x07",
            OLD.replace("critical=0", "critical=-1"),
            OLD.replace("critical=0", "critical=01"),
            OLD.replace("exit=1", "exit=9"),
            OLD.replace("privileges=user", "privileges=admin"),
            OLD.replace("code=22b80beae153b41f", "code=$(id)"),
            OLD + " critical=5",                      # duplicate key
            OLD.replace(" warning=1", ""),             # missing field
            OLD.replace(" ", "  ", 1),                 # empty token
            OLD.replace("2026-11-14T23:21:45+0100", "2026-13-14T23:21:45+0100"),
            OLD.replace("2026-11-14T23:21:45+0100", "yesterday"),
            OLD + " x=" + "a" * 2000,                  # very long line
            OLD.replace("host", "hôte"),
            OLD + "\t",
            OLD.replace("reports/uhc-20261114-232145-host.md", "reports/uhc-20261114-232145-host.md;rm"),
        ]
        for line in bad:
            self.assertIsNone(ind.parse_log_line(line), repr(line))

    def test_not_a_string(self):
        self.assertIsNone(ind.parse_log_line(None))
        self.assertIsNone(ind.parse_log_line(b"x"))


class ReadLogTest(TempDir):
    def test_missing_and_empty(self):
        self.assertIsNone(ind.read_last_record(os.path.join(self.tmp, "logs", "uhc.log")))
        self.assertIsNone(ind.read_last_record(self.write("logs/uhc.log", "")))

    def test_last_valid_line_wins(self):
        p = self.write("logs/uhc.log", OLD + "\n" + NEW + "\n"
                       + "2026-11-15T11:00:00+0100 notification not delivered (no graphical session?)\n"
                       + NEW[:60] + "\n")
        self.assertEqual(ind.read_last_record(p)["critical"], 3)

    def test_without_final_newline(self):
        p = self.write("logs/uhc.log", NEW + "\n" + OLD)
        self.assertEqual(ind.read_last_record(p)["privileges"], "user")

    def test_binary_garbage(self):
        p = self.write("logs/uhc.log", b"\xff\xfe\x00" + OLD.encode() + b"\n\x00\x01\n", mode="wb")
        self.assertIsNone(ind.read_last_record(p))
        p = self.write("logs/uhc.log", b"\xff\xfe\x00\n" + OLD.encode() + b"\n\x00\x01\n", mode="wb")
        self.assertIsNotNone(ind.read_last_record(p))

    def test_large_file_only_tail_read(self):
        p = self.write("logs/uhc.log", (OLD + "\n") * 5000 + NEW + "\n")
        self.assertEqual(ind.read_last_record(p)["critical"], 3)
        self.assertGreater(os.path.getsize(p), ind.LOG_TAIL_BYTES)

    def test_symlink_and_fifo_refused(self):
        target = self.write("elsewhere.log", NEW + "\n")
        os.makedirs(os.path.join(self.tmp, "logs"))
        link = os.path.join(self.tmp, "logs", "uhc.log")
        os.symlink(target, link)
        self.assertIsNone(ind.read_last_record(link))
        fifo = os.path.join(self.tmp, "fifo.log")
        os.mkfifo(fifo)
        self.assertIsNone(ind.read_last_record(fifo))

    def test_directory(self):
        os.makedirs(os.path.join(self.tmp, "logs", "uhc.log"))
        self.assertIsNone(ind.read_last_record(os.path.join(self.tmp, "logs", "uhc.log")))


class StateTest(unittest.TestCase):
    NOW = datetime.datetime(2026, 11, 15, 12, 0, tzinfo=UTC)

    def rec(self, days, critical=0, warning=0):
        return ind.parse_log_line(line_at(self.NOW - datetime.timedelta(days=days), critical, warning))

    def test_states(self):
        self.assertEqual(ind.audit_state(None, self.NOW), "none")
        self.assertEqual(ind.audit_state(self.rec(1, critical=1, warning=5), self.NOW), "critical")
        self.assertEqual(ind.audit_state(self.rec(1, warning=2), self.NOW), "warning")
        self.assertEqual(ind.audit_state(self.rec(1), self.NOW), "ok")

    def test_stale(self):
        self.assertEqual(ind.audit_state(self.rec(36, critical=4), self.NOW), "stale")
        self.assertEqual(ind.audit_state(self.rec(34), self.NOW), "ok")
        self.assertEqual(ind.STALE_DAYS, 35)

    def test_icons_exist_for_every_state(self):
        for state in ("none", "stale", "critical", "warning", "ok"):
            name = ind.ICON_NAMES[state]
            self.assertTrue(os.path.isfile(os.path.join(HERE, "icons", name + ".svg")), name)
        # Four distinct pictures: grey for none and stale.
        self.assertEqual(len(set(ind.ICON_NAMES.values())), 4)


class ReportPathTest(TempDir):
    REL = "reports/uhc-20261115-105749-host.md"

    def test_valid(self):
        p = self.write(self.REL, "# report\n")
        self.assertEqual(ind.report_path(self.tmp, self.REL), os.path.realpath(p))

    def test_missing_or_not_regular(self):
        self.assertIsNone(ind.report_path(self.tmp, self.REL))
        os.makedirs(os.path.join(self.tmp, self.REL))
        self.assertIsNone(ind.report_path(self.tmp, self.REL))

    def test_bad_patterns(self):
        self.write("etc/passwd", "x")
        for rel in ("../../etc/passwd", "/etc/passwd", "reports/../etc/passwd",
                    "reports/uhc-20261115-105749-host.txt", "reports/x/uhc-20261115-105749-h.md",
                    "reports/uhc-20261115-105749-h..md", "reports/uhc-20261115-105749-.md", None):
            self.assertIsNone(ind.report_path(self.tmp, rel), rel)

    def test_symlink_out_of_reports(self):
        outside = self.write("secret.md", "x")
        os.makedirs(os.path.join(self.tmp, "reports"))
        os.symlink(outside, os.path.join(self.tmp, self.REL))
        self.assertIsNone(ind.report_path(self.tmp, self.REL))
        os.unlink(os.path.join(self.tmp, self.REL))
        os.symlink("/etc/passwd", os.path.join(self.tmp, self.REL))
        self.assertIsNone(ind.report_path(self.tmp, self.REL))

    def test_symlink_inside_reports_allowed(self):
        other = self.write("reports/uhc-20261114-000000-host.md", "x")
        os.symlink(other, os.path.join(self.tmp, self.REL))
        self.assertEqual(ind.report_path(self.tmp, self.REL), os.path.realpath(other))

    def test_reports_folder_is_a_link(self):
        real = os.path.join(self.tmp, "elsewhere")
        os.makedirs(real)
        with open(os.path.join(real, "uhc-20261115-105749-host.md"), "w") as f:
            f.write("x")
        os.symlink(real, os.path.join(self.tmp, "reports"))
        self.assertIsNone(ind.report_path(self.tmp, self.REL))
        self.assertIsNone(ind.reports_dir(self.tmp))

    def test_data_dir_through_link(self):
        self.write(self.REL, "x")
        link = os.path.join(tempfile.gettempdir(), "uhc-test-link-%d" % os.getpid())
        os.symlink(self.tmp, link)
        try:
            self.assertIsNotNone(ind.report_path(link, self.REL))
            self.assertEqual(ind.reports_dir(link), os.path.join(os.path.realpath(self.tmp), "reports"))
        finally:
            os.unlink(link)


class CommandTest(TempDir):
    def setUp(self):
        super().setUp()
        # Tool directory with a space, a % and a quote in its path.
        self.tool = os.path.join(self.tmp, "my tools %d 'x'")
        os.makedirs(self.tool)
        uhc = self.write(os.path.join(self.tool, "uhc.sh"), "#!/bin/bash\n")
        os.chmod(uhc, 0o755)
        self.uhc = uhc
        self.data = os.path.join(self.tmp, "data $(id)")
        os.makedirs(self.data)

    def test_audit(self):
        self.assertEqual(ind.audit_cmd(self.tool, self.tool), [self.uhc, "--quiet"])
        self.assertEqual(ind.audit_cmd(self.tool, self.data), [self.uhc, "--quiet", "--data-dir", self.data])

    def test_not_executable_uses_bash_p(self):
        os.chmod(self.uhc, 0o644)
        self.assertEqual(ind.audit_cmd(self.tool, self.tool), ["/bin/bash", "-p", self.uhc, "--quiet"])

    def test_timer_status(self):
        self.assertEqual(ind.timer_status_cmd(self.tool, self.tool), [self.uhc, "--timer-status"])
        self.assertEqual(ind.timer_status_cmd(self.tool, self.data),
                         [self.uhc, "--data-dir", self.data, "--timer-status"])

    def test_user_timer(self):
        self.assertEqual(ind.user_timer_cmd(self.tool, self.data, "weekly"),
                         [self.uhc, "--data-dir", self.data, "--install-timer", "user", "weekly", "--yes"])
        self.assertEqual(ind.user_timer_cmd(self.tool, self.tool, None),
                         [self.uhc, "--remove-timer", "user", "--yes"])
        for bad in ("hourly", "daily --x", "", "root"):
            with self.assertRaises(ValueError):
                ind.user_timer_cmd(self.tool, self.tool, bad)

    def test_root_audit(self):
        root = os.path.join(self.tmp, "opt")
        self.assertEqual(ind.root_audit_cmd(self.tool, self.data, True, root_dir=root),
                         ["sudo", os.path.join(root, "uhc.sh"), "--data-dir", self.data])
        self.assertEqual(ind.root_audit_cmd(self.tool, self.tool, False, root_dir=root),
                         ["sudo", self.uhc])
        self.assertEqual(ind.root_audit_cmd(self.tool, self.data, False, root_dir=root),
                         ["sudo", self.uhc, "--data-dir", self.data])
        self.assertFalse(ind.root_copy_installed(root))
        self.write(os.path.join(root, "uhc.sh"), "x")
        self.assertTrue(ind.root_copy_installed(root))
        self.assertEqual(ind.ROOT_INSTALL_DIR, "/opt/ubuntu-health-check")

    def test_root_timer_never_yes(self):
        for freq in ("daily", "weekly", "monthly", None):
            cmd = ind.root_timer_cmd(self.data, freq)
            self.assertNotIn("--yes", cmd)
            self.assertEqual(cmd[:4], ["sudo", "/opt/ubuntu-health-check/uhc.sh", "--data-dir", self.data])
        self.assertEqual(ind.root_timer_cmd(self.data, "monthly")[4:], ["--install-timer", "root", "monthly"])
        self.assertEqual(ind.root_timer_cmd(self.data, None)[4:], ["--remove-timer", "root"])
        with self.assertRaises(ValueError):
            ind.root_timer_cmd(self.data, "yearly")

    def test_terminal_command_runs_data_as_arguments(self):
        term = ("/usr/bin/ptyxis", ["--"])
        argv = ["printf", "[%s]", "a;b $(echo X) `id`"]
        cmd = ind.terminal_cmd(term, argv, "Press Enter", "Runs $(id):")
        self.assertEqual(cmd[:6], ["/usr/bin/ptyxis", "--", "/bin/bash", "-c", ind.HOLD_SCRIPT, "uhc-indicator"])
        self.assertEqual(cmd[6:], ["Press Enter", "Runs $(id):"] + argv)
        # The constant script, run without the terminal: the introduction and
        # the command are shown first, and data stays literal.
        out = subprocess.run(cmd[2:], input=b"\n", stdout=subprocess.PIPE, check=True).stdout
        shown = b"printf \\[%s\\] a\\;b\\ \\$\\(echo\\ X\\)\\ \\`id\\` "
        self.assertEqual(out, b"Runs $(id):\n\n  " + shown + b"\n\n[a;b $(echo X) `id`]\nPress Enter ")

    def test_find_terminal(self):
        bindir = os.path.join(self.tmp, "bin")
        os.makedirs(bindir)
        self.assertIsNone(ind.find_terminal(bindir))

        def exe(name, target=None):
            p = os.path.join(bindir, name)
            if target:
                os.symlink(target, p)
            else:
                with open(p, "w") as f:
                    f.write("#!/bin/sh\n")
                os.chmod(p, 0o755)
            return p
        xterm = exe("xterm")
        self.assertEqual(ind.find_terminal(bindir), (xterm, ["-e"]))
        os.unlink(xterm)
        other = os.path.join(self.tmp, "kgx")
        with open(other, "w") as f:
            f.write("#!/bin/sh\n")
        os.chmod(other, 0o755)
        xte = exe("x-terminal-emulator", other)
        self.assertEqual(ind.find_terminal(bindir), (xte, ["--"]))
        ptyxis = exe("ptyxis")
        self.assertEqual(ind.find_terminal(bindir), (ptyxis, ["--"]))

    def test_display_cmd(self):
        self.assertEqual(ind.display_cmd(["sudo", "/a b/uhc.sh", "--data-dir", "/x'y"]),
                         "sudo '/a b/uhc.sh' --data-dir '/x'\"'\"'y'")

    def test_tool_dir_of(self):
        self.assertEqual(ind.tool_dir_of(SCRIPT), os.path.realpath(TOOL))
        self.assertTrue(os.path.isfile(os.path.join(ind.tool_dir_of(SCRIPT), "uhc.sh")))


class TimerStatusTest(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(ind.parse_timer_status("user=weekly\nroot=none\n"), {"user": "weekly", "root": "none"})
        self.assertEqual(ind.parse_timer_status("root=custom\nuser=monthly"), {"user": "monthly", "root": "custom"})

    def test_invalid(self):
        for text in ("", "user=weekly", "user=weekly\nroot=hourly", "user=weekly\nuser=daily",
                     "user=weekly\nroot=none\nextra=1", "user=weekly;rm\nroot=none", None,
                     "user=Weekly\nroot=none"):
            self.assertIsNone(ind.parse_timer_status(text), repr(text))


class CatalogTest(TempDir):
    def catalog_keys(self, lang):
        return ind.parse_catalog(ind.read_text(os.path.join(TOOL, "lib", "lang", lang, "indicator.lang")))

    def test_en_fr_same_keys_and_variables(self):
        en, fr = self.catalog_keys("en"), self.catalog_keys("fr")
        self.assertTrue(en)
        self.assertEqual(set(en), set(fr))
        for k in en:
            self.assertEqual(set(re.findall(r"\{(\w+)\}", en[k])), set(re.findall(r"\{(\w+)\}", fr[k])), k)

    def test_every_key_used_exists(self):
        with open(SCRIPT) as f:
            used = set(re.findall(r'(?<![\w.])tr\("([^"]+)"', f.read()))
        en = self.catalog_keys("en")
        self.assertTrue(used)
        self.assertEqual(used - set(en), set())
        self.assertEqual(set(en) - used, set())

    def test_fallback_and_variables(self):
        tool = self.tmp
        self.write("lib/lang/en/indicator.lang", "# c\nui.a=Hello {name}\nui.b=Only english\nbad key=x\n\nui.c\n")
        self.write("lib/lang/fr/indicator.lang", "ui.a=Bonjour {name}\r\n")
        ind.set_catalog(ind.load_catalog(tool, "fr"))
        self.assertEqual(ind.tr("ui.a", name="{name} & $x"), "Bonjour {name} & $x")
        self.assertEqual(ind.tr("ui.b"), "Only english")
        self.assertEqual(ind.tr("ui.missing"), "ui.missing")
        self.assertEqual(ind.tr("ui.a"), "Bonjour {name}")
        self.assertNotIn("bad key", ind.load_catalog(tool, "fr"))
        for code in ("de", "../en", "EN", "", None):
            ind.set_catalog(ind.load_catalog(tool, code))
            self.assertEqual(ind.tr("ui.a", name="x"), "Hello x", code)

    def test_real_catalog_french(self):
        ind.set_catalog(ind.load_catalog(TOOL, "fr"))
        self.assertEqual(ind.tr("ui.ind.status.compare", new=1, worse=0, resolved=2),
                         "1 nouveau(x), 0 aggravé(s), 2 résolu(s)")
        ind.set_catalog(ind.load_catalog(TOOL, "en"))
        self.assertEqual(ind.tr("ui.ind.status.counts", critical=0, warning=2), "0 critical, 2 warning(s)")

    def test_status_lines(self):
        ind.set_catalog(ind.load_catalog(TOOL, "en"))
        now = datetime.datetime(2026, 11, 15, 12, 0, tzinfo=UTC)
        self.assertEqual(ind.status_lines(None, "none", now), ["No audit yet"])
        rec = ind.parse_log_line(NEW)
        lines = ind.status_lines(rec, "critical", now)
        self.assertEqual(len(lines), 3)
        self.assertIn("full audit", lines[0])
        self.assertEqual(lines[1:], ["3 critical, 1 warning(s)", "2 new, 1 worse, 4 resolved"])
        old = ind.parse_log_line(line_at(now - datetime.timedelta(days=40)))
        lines = ind.status_lines(old, "stale", now)
        self.assertEqual(lines[-1], "No audit for 40 days")
        self.assertEqual(len(lines), 3)


class LangChoiceTest(TempDir):
    def test_conf(self):
        cases = {
            "REPORT_LANG=fr\n": "fr",
            'REPORT_LANG="fr"  # comment\n': "fr",
            "  REPORT_LANG = de\n": "de",
            "REPORT_LANG=auto\n": None,
            "REPORT_LANG=FR\n": None,
            "REPORT_LANG=fr\nREPORT_LANG=bad1\n": "fr",
            "REPORT_LANG=fr\nREPORT_LANG=auto\n": None,
            "#REPORT_LANG=fr\n": None,
            "REPORT_LANG=$(id)\n": None,
            "OTHER=fr\n": None,
        }
        for text, want in cases.items():
            p = self.write("uhc.conf", text)
            self.assertEqual(ind.report_lang_from_conf(p), want, text)
        self.assertIsNone(ind.report_lang_from_conf(os.path.join(self.tmp, "none.conf")))

    def test_locale(self):
        nodef = os.path.join(self.tmp, "nolocale")
        self.assertEqual(ind.locale_lang({"LANG": "fr_FR.UTF-8"}, nodef), "fr")
        self.assertEqual(ind.locale_lang({"LANGUAGE": "de:fr", "LANG": "fr_FR.UTF-8"}, nodef), "de")
        self.assertEqual(ind.locale_lang({"LC_ALL": "C.UTF-8", "UHC_LANG": "fr"}, nodef), "fr")
        self.assertIsNone(ind.locale_lang({"LC_ALL": "C.UTF-8"}, nodef))
        self.assertIsNone(ind.locale_lang({"LANG": "../x"}, nodef))
        deflt = self.write("default-locale", 'LANG="fr_FR.UTF-8"\n')
        self.assertEqual(ind.locale_lang({"LANG": "C"}, deflt), "fr")
        self.assertEqual(ind.locale_lang({}, deflt), "fr")

    def test_choose(self):
        nodef = os.path.join(self.tmp, "nolocale")
        self.assertEqual(ind.choose_lang(self.tmp, {"LANG": "fr_FR.UTF-8"}, nodef), "fr")
        self.write("uhc.conf", "REPORT_LANG=en\n")
        self.assertEqual(ind.choose_lang(self.tmp, {"LANG": "fr_FR.UTF-8"}, nodef), "en")
        self.write("uhc.conf", "REPORT_LANG=auto\n")
        self.assertEqual(ind.choose_lang(self.tmp, {}, nodef), "en")


class MiscTest(TempDir):
    def test_clean_output(self):
        self.assertEqual(ind.clean_output(b"uhc: \x1b[31mfailed\x1b[0m\x07 here\n"), "uhc: failed here")
        self.assertEqual(len(ind.clean_output("x" * 5000)), 2001)
        self.assertEqual(ind.clean_output(b"\xff ok"), "� ok")

    def test_lock(self):
        rt = os.path.join(self.tmp, "run")
        os.makedirs(rt, mode=0o700)
        os.chmod(rt, 0o700)
        path = ind.lock_path({"XDG_RUNTIME_DIR": rt})
        self.assertEqual(path, os.path.join(rt, "uhc-indicator.lock"))
        fd = ind.acquire_lock(path)
        self.assertIsNotNone(fd)
        self.assertIsNone(ind.acquire_lock(path))
        os.close(fd)
        fd = ind.acquire_lock(path)
        self.assertIsNotNone(fd)
        os.close(fd)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_lock_path_fallback(self):
        open_dir = os.path.join(self.tmp, "open")
        os.makedirs(open_dir)
        os.chmod(open_dir, 0o755)
        p = ind.lock_path({"XDG_RUNTIME_DIR": open_dir}, uid=os.getuid())
        self.assertEqual(os.path.dirname(p), tempfile.gettempdir())
        self.assertIn(str(os.getuid()), p)
        self.assertEqual(os.path.dirname(ind.lock_path({"XDG_RUNTIME_DIR": "relative"})), tempfile.gettempdir())

    def test_lock_symlink_refused(self):
        target = self.write("target", "")
        link = os.path.join(self.tmp, "lock")
        os.symlink(target, link)
        self.assertIsNone(ind.acquire_lock(link))

    def test_main_refuses_root(self):
        with mock.patch.object(ind.os, "geteuid", return_value=0), \
                mock.patch.object(ind, "run_gui") as gui, \
                mock.patch("sys.stderr"):
            self.assertEqual(ind.main([]), 3)
            gui.assert_not_called()

    def test_main_bad_data_dir(self):
        with mock.patch.object(ind, "run_gui") as gui, mock.patch("sys.stderr"):
            self.assertEqual(ind.main(["--data-dir", os.path.join(self.tmp, "nope")]), 3)
            gui.assert_not_called()

    def test_main_single_instance(self):
        rt = os.path.join(self.tmp, "run")
        os.makedirs(rt)
        os.chmod(rt, 0o700)
        with mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": rt}), \
                mock.patch.object(ind, "run_gui", return_value=0) as gui:
            self.assertEqual(ind.main(["--data-dir", self.tmp]), 0)
            gui.assert_called_once_with(os.path.realpath(TOOL), os.path.realpath(self.tmp))
            # The lock taken by the first call is still held by this process.
            with mock.patch("sys.stderr"):
                self.assertEqual(ind.main(["--data-dir", self.tmp]), 0)
            self.assertEqual(gui.call_count, 1)


if __name__ == "__main__":
    unittest.main()
