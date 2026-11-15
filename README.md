# ubuntu-health-check

A **read-only maintenance audit** for Ubuntu machines. It finds the problems
that Ubuntu does not warn you about — packages that silently stopped receiving
updates, a kernel frozen for years after a release upgrade, forgotten services
listening on the network — and writes a clear Markdown report you can read
yourself or hand to an AI assistant to drive a maintenance session.

```text
== Kernel ==
  CRITICAL Kernel metapackage no longer available in any repository: kernel updates have stopped [KRN-META]
== APT packages and repositories ==
  WARNING  4 package(s) stuck on a version from a removed or disabled repository [APT-STUCK-VERSION]
== Network exposure ==
  CRITICAL TCP services reachable from the network and NO firewall active [NET-LISTEN]

Result: 2 critical, 5 warning, 11 info, 14 ok, 3 partial
Report: ~/ubuntu-health-check/reports/uhc-20260929-221500-laptop.md
```

## Why

`apt upgrade` saying _"all packages are up to date"_ only means _up to date
relative to the repositories that are still enabled_. On a machine that has
been upgraded across releases a few times, it is common to find:

- a kernel **metapackage from an old release** that no longer exists, so no
  new kernel has been installed for years while everything else updates daily;
- packages **stuck on a third-party version** (PPA, vendor repository) that a
  release upgrade disabled: the version number is higher than Ubuntu's, so apt
  never replaces it, and it never gets a security fix again;
- repositories disabled, duplicated or pointing to another release;
- the same software installed **twice** (snap and deb) and failing to update;
- web servers, databases or test services started years ago and still
  listening on all interfaces, sometimes on a public IPv6 address, with no
  firewall.

None of these produce an alert. This tool looks for them.

It focuses on **maintenance hygiene**. For an in-depth security hardening audit,
use [Lynis](https://cisofy.com/lynis/) as well — the two are complementary.

## Safety guarantees

- **Nothing on the system is modified.** No `apt update`, no install or
  removal, no service or configuration change. APT queries run with an
  in-memory cache (they do not even rewrite `/var/cache/apt/*.bin`), and
  `pro` is run as the regular user so it does not write root logs, with its
  own log and cache redirected to a private temporary folder.
- **Persistent output stays in the data directory** (`reports/`, `logs/`;
  by default the tool directory). Transient files live in a private temporary
  directory (mode 700) removed at exit.
- **Only the explicit installation commands write elsewhere**, each after
  showing what it will write and asking: `--install-aliases`
  (`~/.bash_aliases`), `--install-timer` (systemd units) and
  `--install-indicator` (one autostart entry). Each has its `--remove-…`
  counterpart, and none replaces or removes a file it did not write without
  saying so.
- **Root runs use a root-owned copy of the code** (see
  [Full audit with sudo](#full-audit-with-sudo)):
  - as root, the tool only runs audits from code owned by root and writable
    by nobody else, in `/opt/ubuntu-health-check`; `sudo ./uhc.sh` from your
    own folder is only an installer for that copy (terminal only, never an
    audit);
  - everything written into a user-owned data directory is written **with that
    user's privileges**, never as root, so a planted symlink cannot redirect a
    write to a system file; the root lock file lives in `/run`;
  - files in the audited user's home are read with that user's privileges;
  - as root, the tool **re-executes itself with an empty environment** (plus a
    short whitelist) before running any command, so variables kept by
    `sudo -E` or an `env_keep` rule — such as `PYTHONPATH`, which would reach
    Python tools like `ufw` — cannot alter what runs as root. The interpreter
    is started as `bash -p`, which ignores `BASH_ENV` and exported shell
    functions; launch the tool by its path (`./uhc.sh`, `/opt/.../uhc.sh`),
    not as `bash uhc.sh`, to keep that protection from the first line;
  - a root-owned data directory is accepted only if it and all its parent
    directories are root-owned and not writable by others.
- **The configuration file is parsed and validated, never executed.** Every
  value must match a strict pattern (decimal numbers without leading zero, in
  range; fixed keywords; port, check-ID and package-name syntax) before it is
  used; anything else is rejected with a message and the default is kept.
- **Secrets are never printed.** SSH keys are classified from their format
  headers (cipher name and key type only); cron entries are reduced to their
  schedule and program name (arguments often contain tokens).
- **Untrusted text is neutralised.** Names coming from the system (processes,
  containers, packages, files) are stripped of C0 and C1 control characters
  (terminal escape sequences) and of bidirectional override characters, and
  cannot break out of their code block. The
  report tells AI assistants to treat code blocks as data, not instructions.
- **Reports are private** (mode `600`, directories `700`).
- **No false "OK" on missing data**: when a command fails, the check is
  reported as skipped instead.
- It sets a fixed system `PATH`, so a program in a user-writable directory
  cannot be run in place of a system tool.
- **The code fingerprint** (SHA-256 over all code files) is printed in every
  report and log line, and by `--fingerprint`.
- The code passes [ShellCheck](https://www.shellcheck.net/) (`-S style`) with
  no finding; a GitHub Actions workflow re-checks it on every push.

## Requirements

- Ubuntu 20.04 or newer (other Debian-based systems work partially).
- Bash 4.4+ and standard tools present on any Ubuntu install.
- Optional, used when present: `ubuntu-distro-info`, `pro`, `snap`, `ufw`,
  `docker`, `virsh`, `mokutil`, `ss`, `ip`, `notify-send`. Missing tools are reported
  as _skipped_, never as errors.

## Installation

```bash
git clone https://github.com/Oxazsas/ubuntu-health-check.git ~/ubuntu-health-check
cd ~/ubuntu-health-check
chmod +x uhc.sh
```

No installation step, no dependency. The whole tool lives in this directory.

## Usage

```bash
./uhc.sh              # routine check, unprivileged (some checks partial)
./uhc.sh --sanitize   # mask identifying data (see "Using the report with an AI")
./uhc.sh --quiet      # no terminal output (for cron / timers)
./uhc.sh --print      # also print the report on stdout
./uhc.sh --brief      # one line per finding, without the action plan
./uhc.sh --lang fr    # report and terminal output in French
```

| Option                                          | Effect                                                                                                                                                                                       |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-q`, `--quiet`                                 | No terminal output                                                                                                                                                                           |
| `--brief`                                       | Terminal: one line per finding, without the action plan (the plan stays in the report)                                                                                                       |
| `--lang CODE`                                   | Language of the report and terminal output (`en`, `fr`): see [Languages](#languages)                                                                                                         |
| `-s`, `--sanitize`                              | Mask identifying data in the saved report                                                                                                                                                    |
| `-p`, `--print`                                 | Print the report to stdout after the run                                                                                                                                                     |
| `-d`, `--data-dir DIR`                          | Where `reports/` and `logs/` are written (default: tool directory)                                                                                                                           |
| `-c`, `--config FILE`                           | Configuration file (default: `DATA_DIR/uhc.conf`)                                                                                                                                            |
| `--no-notify`                                   | Never send a desktop notification                                                                                                                                                            |
| `--no-color`                                    | Plain terminal output                                                                                                                                                                        |
| `--accept-jobs [FP…]`                           | Accept pending job changes: the given fingerprints, or (in a terminal) the list shown on screen after confirmation (see [Persistence detection](#persistence-detection-approach-and-limits)) |
| `--install-aliases [NAME]` / `--remove-aliases` | Add or remove the optional `uhc`, `uhc-root`, `uhc-last` aliases                                                                                                                             |
| `--install-timer [user\|root] [FREQ]`           | Schedule the audit with a systemd timer (`daily`, `weekly`, `monthly`); see [Scheduling](#scheduling)                                                                                        |
| `--remove-timer [user\|root]`                   | Remove that timer                                                                                                                                                                            |
| `--timer-status`                                | Print `user=…` and `root=…`: `none`, `daily`, `weekly`, `monthly` or `custom`                                                                                                                |
| `-y`, `--yes`                                   | With `--install-timer user` or `--remove-timer user` only: no question                                                                                                                       |
| `--install-indicator` / `--remove-indicator`    | Add or remove the optional top-bar icon (desktop only)                                                                                                                                       |
| `--fingerprint`                                 | Print the SHA-256 fingerprint of the code and exit                                                                                                                                           |
| `-h`, `--help` / `-V`, `--version`              | Help / version                                                                                                                                                                               |

The terminal summary is written to **stderr**, so `--print` output on stdout
stays clean for piping.

### Privileges

Running **without sudo** is the default and is enough for a routine check.
The checks that need root are listed in the report under _Partial or skipped
checks_: firewall rules and default policy, names of the processes behind
listening ports, effective sshd configuration, accounts with empty passwords,
the unattended-upgrades log.

### Full audit with sudo

Root must only run code that no other account can modify, so full audits run
from a root-owned copy in `/opt/ubuntu-health-check`. Three commands, three
roles:

| Command                                                                            | Role                                                                                            |
| ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `./uhc.sh` (alias `uhc`)                                                           | **routine audit**, without sudo, from your folder                                               |
| `sudo /opt/ubuntu-health-check/uhc.sh --data-dir <your folder>` (alias `uhc-root`) | **full audit**, from the root-owned copy                                                        |
| `sudo ./uhc.sh`                                                                    | **installer only**: installs or updates the root-owned copy, in a terminal; never runs an audit |

**First installation, and after each update of your folder:**

```bash
sudo ./uhc.sh
```

The **installation wizard** explains what it does, shows the fingerprint of
the code, and asks before doing anything (default answer: no):

- if the tool's public repository is known (`UHC_REPO_URL`, set in the code),
  it offers to install **from the repository, at the release tag of this
  version** (`v<version>`, not the default branch, which may contain
  unreleased changes) — recommended: the code goes straight from the
  repository to the root-owned folder; or from this folder;
- otherwise it offers to install from this folder;
- then it offers the shell aliases (installed **with your own privileges**,
  not as root, since they go into your home) and a first full audit from the
  new copy.

When the copy is already up to date, `sudo ./uhc.sh` only tells you which
command to use. Without a terminal (cron, timers, scripts) it refuses, so
nothing is ever installed as root unattended.

Reports are written in your folder **as you**, not as root. The persistence
reference list of root runs is kept in `/opt/ubuntu-health-check/state/`
(root only).

**Why `sudo ./uhc.sh` is only an installer.** Whatever `sudo ./uhc.sh` does,
it first executes the code of your folder as root — including the part that
decides what to do next. If it were the usual way to start full audits, a
modification of your folder (by a program running under your account) would
reach root at the next audit, and no check would see it. Keeping full audits on
the root copy limits that exposure to the moment you install or update.

**What the root copy protects, and what it does not.** As long as full audits
are started from `/opt` (which `uhc-root` does), a later modification of your
folder cannot reach root. It cannot protect the copy itself: if your folder
was already modified when you install, the modified code is installed — and
the wizard you are answering is that code. The trust decision happens at
installation time, which is why installing from the public repository is
preferred. If in doubt, verify the root copy **with a tool that does not
depend on this code** (the fingerprint is computed by the tool itself):

```bash
# from a trusted source directory (e.g. a fresh clone):
diff -r lib /opt/ubuntu-health-check/lib && cmp uhc.sh /opt/ubuntu-health-check/uhc.sh && echo identical
```

And the limit of the whole approach: a program running under your account can
also try to steal your sudo password by other means (a fake `sudo` earlier in
your `PATH`, for instance). The root copy is defence in depth for a personal
workstation, not a protection of a compromised session.

Use plain `sudo`. `sudo -E` is handled (the environment is discarded), but
there is no reason to use it.

### Shell aliases (optional)

The installation wizard offers them. You can also add them yourself:

```bash
./uhc.sh --install-aliases          # or --install-aliases <prefix>
```

After showing them and asking for confirmation, it adds three commands to
`~/.bash_aliases` (loaded by Ubuntu's default `~/.bashrc`). They are shell
functions rather than aliases: an alias is parsed again at each use, which
breaks on paths with spaces and could run code hidden in a folder name; a
function is parsed once.

| Command    | Does                                                                                                                                                                  |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `uhc`      | routine audit from your folder, without sudo                                                                                                                          |
| `uhc-root` | full audit from the root-owned copy, reports in your folder. It **never** runs your folder as root: if the copy is not installed, it says how to install it and stops |
| `uhc-last` | opens the latest report in `less`                                                                                                                                     |

The paths are detected automatically. Before writing anything, the tool
checks that none of the three names is already used on your machine: files
of that name in the directories of your `PATH`, in the system `PATH` and in
common per-user tool directories (`~/.local/bin`, `~/.cargo/bin`, `~/go/bin`,
`~/.volta/bin`, npm, Deno, Bun, pnpm), and aliases or functions in your shell
files. It stops if one is taken; choose another prefix then. The lines are
kept in a delimited block: running the option again updates the block instead
of duplicating it, and `--remove-aliases` removes it without touching your
other aliases. The next audit reports the new lines as
`SVC-PERSISTENCE-NEW-SHELL`: expected, accept them.

### Exit codes

| Code | Meaning                                                                                                                                                                                                      |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 0    | Nothing to report (only INFO / OK)                                                                                                                                                                           |
| 1    | At least one WARNING                                                                                                                                                                                         |
| 2    | At least one CRITICAL                                                                                                                                                                                        |
| 3    | Usage error, safety refusal (sudo on user-owned code without a terminal, or installation declined), or another run in progress. `sudo ./uhc.sh` exits with 0 after installing or when the copy is up to date |

## Output

Each run produces:

1. **A terminal summary**: one line per finding, then an **action plan** for
   the critical and warning findings (`--brief` leaves the plan out).
2. **A Markdown report** in `reports/uhc-YYYYMMDD-HHMMSS-<host>.md`:
   machine context, summary table, the action plan, one section per domain
   with every finding and the raw evidence (command output), the list of
   partial checks, and closing notes for an AI assistant.
3. **A log line** in `logs/uhc.log` (date, counts per severity, report path,
   then `new=N worse=N resolved=N` compared with the previous audit; `-` when
   there is nothing to compare with). Fields are only ever added at the end.
4. **A desktop notification** when there is at least one CRITICAL finding
   (configurable).

Only the last 12 reports are kept (configurable). The log keeps 1000 lines.

### Since the last audit

Each complete run saves its results by ID in `logs/last-audit-user.state`
(unprivileged) or `logs/last-audit-root.state` (sudo), in the data directory,
mode 600. The next run at the same privilege level compares with it: the
report gets a "Since the last audit" section after the summary, and the
terminal one or two lines. Findings are listed as new, worse, improved or
resolved, with their ID and severity before → after; changes between OK and
INFO are only counted.

- An ID silenced by `IGNORE_CHECKS`, or not checked because its check was
  partial, is never shown as resolved; it keeps its previous result for the
  next comparison.
- After an update of the tool, IDs the previous state did not know are listed
  as "checks possibly new in this version", not as new problems.
- The state file holds the tool version, the date, the privilege level and
  lines `SEVERITY<TAB>ID<TAB>count` (plus `PARTIAL<TAB>ID<TAB>1`): no title,
  no host, user or package name. It is read as data, never executed, and set
  aside as a whole if anything in it looks wrong. Deleting it restarts the
  comparison.
- Like the reports and the log, the state of a sudo run lives in your data
  directory and is written with your privileges: a program running under
  your account could alter it and hide a "new" finding from the comparison.
  The findings themselves are not affected.

### Explanations and proposed actions

The tool diagnoses, explains and proposes; **it never runs a fix**. Each
finding that calls for a decision comes with:

- **What it means**: what you risk if you do nothing, in plain words.
- **What you can do**: commands for you to run yourself, each with what it
  does and whether it can be undone. Read-only commands and simulations come
  first.
- **Before you act**: what to check, simulate or back up first.

The action plan gathers these for the critical findings, then the warnings.
Commands that apply to several items use a placeholder such as `<package>`:
the items themselves are listed in the evidence of the finding.

### Severity levels

| Level       | Meaning                                                         |
| ----------- | --------------------------------------------------------------- |
| 🔴 CRITICAL | Actively unsafe or silently broken: act soon                    |
| 🟠 WARNING  | Needs a decision or a fix                                       |
| 🔵 INFO     | Worth knowing; review, often no action needed                   |
| 🟢 OK       | Checked and fine                                                |
| ⚪ Skipped  | Could not be checked (missing tool, privileges, not applicable) |

## What is checked

Every finding has a stable ID, shown in brackets in the terminal and in
backticks in the report. Use it to silence accepted risks (`IGNORE_CHECKS`).
IDs are not renamed; the one rename so far (`SVC-CRON-SUSPECT` →
`SVC-PERSISTENCE` in 2.2.0) is still accepted in `IGNORE_CHECKS`, with a
message.

### System

| ID               | Check                                                                                                                                                  |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `SYS-OS`         | Distribution is Ubuntu                                                                                                                                 |
| `SYS-EOL`        | Days left before end of standard support                                                                                                               |
| `SYS-RELEASE`    | A newer LTS release exists                                                                                                                             |
| `SYS-REBOOT`     | Reboot required to activate installed updates                                                                                                          |
| `SYS-TIME`       | Clock synchronised with NTP                                                                                                                            |
| `SYS-DISK`       | Usage of `/`, `/boot`, `/boot/efi`, `/var`, `/home`, Docker data                                                                                       |
| `SYS-DISK-USAGE` | Only when a filesystem is above `DISK_WARN`: measured size of what can be freed (disabled snap revisions, `~/snap`, Docker, older kernels, journal, apt cache), largest first; the matching commands are proposed under `SYS-DISK` |
| `SYS-LOCAL-BIN`  | Inventory of executables in `/usr/local/bin` and `/usr/local/sbin` that no package owns (name, size, date, link target; contents never read) |

### Hardware health

| ID                 | Check |
| ------------------ | ----- |
| `HW-BATTERY`       | Battery wear (full capacity against design capacity), charge cycles, charge thresholds; WARNING below `BATTERY_HEALTH_WARN` %. Nothing on a machine without a battery |
| `HW-DISK-HEALTH`   | SMART health of the internal disks: `smartctl` or `nvme` as root, the data udisks2 already holds without root (no daemon is started, a sleeping disk is not woken, serial numbers are never shown). CRITICAL when a disk reports itself failing, WARNING when NVMe wear reaches 90 % or a critical warning is raised. Skipped in virtual machines and containers |
| `HW-KERNEL-ERRORS` | Disk I/O errors, file system errors, machine checks and memory (EDAC) errors in the kernel log of the current and previous boot (WARNING); out-of-memory kills alone (INFO) |

### Kernel

| ID                  | Check                                                                                             |
| ------------------- | ------------------------------------------------------------------------------------------------- |
| `KRN-META`          | A kernel metapackage is installed **and still available** — otherwise kernel updates have stopped |
| `KRN-META-LEFTOVER` | Obsolete metapackage from a previous release still installed                                      |
| `KRN-RUNNING`       | Running kernel is the newest installed                                                            |
| `KRN-PENDING`       | Newer kernel offered by the repositories but not installed                                        |
| `KRN-OLD`           | Number of kernel images installed                                                                 |
| `KRN-NONE`          | No distribution kernel (container, WSL)                                                           |
| `KRN-MODULES`       | Out-of-tree drivers (`linux-modules-<driver>-<kernel>` packages, DKMS) missing for an installed kernel that another installed kernel has: WARNING for the running or newest kernel, INFO for an older fallback kernel |

### APT packages and repositories

| ID                                       | Check                                                                                                |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `APT-LISTS-AGE`                          | Age of the package lists (results depend on them)                                                    |
| `APT-SECURITY-UPGRADES` / `APT-UPGRADES` | Pending updates (excluding those deferred by phased updates)                                         |
| `APT-PHASED`                             | Updates deferred by Ubuntu's phased updates (normal, installed later on their own)                   |
| `APT-HELD`                               | Packages on hold                                                                                     |
| `APT-STUCK-VERSION`                      | Installed version from a removed/disabled source while Ubuntu offers another version (never updated) |
| `APT-OBSOLETE`                           | Packages no repository provides at all                                                               |
| `APT-OBSOLETE-KERNEL`                    | Obsolete kernel-related packages                                                                     |
| `APT-RESIDUAL`                           | Removed packages with leftover configuration (`rc`)                                                  |
| `APT-REPO-DISABLED`                      | Disabled third-party repositories                                                                    |
| `APT-REPO-LEFTOVER`                      | `.distUpgrade`, `.save`, `.disabled`… files in `sources.list.d`                                      |
| `APT-REPO-THIRDPARTY`                    | Enabled third-party repositories                                                                     |
| `APT-REPO-SUITE`                         | Repositories targeting another Ubuntu release (critical for official archives)                       |
| `APT-REPO-DUPLICATE`                     | Same repository declared in several files                                                            |
| `APT-LEGACY-KEYS`                        | Legacy global keyring `/etc/apt/trusted.gpg`                                                         |
| `APT-KEY-EXPIRED`                        | Repository signing keys that expired (WARNING when an enabled repository uses them) or expire within 30 days (INFO), read with `gpg --show-keys` in a private temporary home |
| `APT-UNATTENDED`                         | Automatic security updates installed and enabled                                                     |
| `APT-UNATTENDED-THIRDPARTY`              | Enabled third-party repositories that automatic updates do not cover (`Allowed-Origins`, `Origins-Pattern`), with their pending updates; coverage "not determined" when a pattern is not reproduced (INFO) |
| `APT-UNATTENDED-LASTRUN` / `-ERRORS`     | Last run date and recent errors (sudo)                                                               |
| `APT-PRO-STATUS`                         | Security coverage summary from `pro security-status`                                                 |

### Snap packages

| ID                 | Check                                                                                                  |
| ------------------ | ------------------------------------------------------------------------------------------------------ |
| `SNAP-ERRORS`      | Failed snap operations (usually repeated refresh failures; told apart when the errors point to the Snap Store or the network) |
| `SNAP-REFRESH`     | Snaps not refreshed for more than `SNAP_REFRESH_MAX_AGE` days, or refreshes on hold (WARNING for all snaps, INFO for some)  |
| `SNAP-BRANCH`      | Snaps following a channel branch made for another Ubuntu release (e.g. `latest/stable/ubuntu-25.10` on 26.04) |
| `SNAP-DUPLICATE`   | Same software installed as snap **and** deb (warning when both provide a service, otherwise info)      |
| `SNAP-PUBLISHER`   | Snaps from non-verified publishers                                                                     |
| `SNAP-CONFINEMENT` | Snaps in classic or devmode confinement                                                                |

### Services

| ID                               | Check                                                                                                                   |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `SVC-FAILED` / `SVC-USER-FAILED` | Failed system and user units                                                                                            |
| `SVC-SOCKET-ORPHAN`              | Active socket units whose service no longer exists (system, and the user's own when run without sudo)                  |
| `SVC-NETWORK`                    | Network-facing services enabled at boot (web servers, databases, printing, VPN, remote desktop, Node process managers…) |

### Persistence (scheduled and startup jobs)

| ID                            | Check                                                                                       |
| ----------------------------- | ------------------------------------------------------------------------------------------- |
| `SVC-PERSISTENCE`             | Scheduled or startup jobs matching persistence patterns (see below)                         |
| `SVC-PERSISTENCE-NEW`         | Jobs new or changed since the reference list was last accepted, **whatever their form**     |
| `SVC-PERSISTENCE-NEW-SHELL`   | New or changed lines in shell startup files (INFO)                                          |
| `SVC-PERSISTENCE-NEW-PACKAGE` | Job lines changed by package updates (INFO, for traceability)                               |
| `SVC-PERSISTENCE-REMOVED`     | Commands removed or changed since the last acceptance (INFO)                                |
| `SVC-PERSISTENCE-BASELINE`    | Reference list created or updated (INFO); **missing although it existed** (WARNING)         |
| `SVC-PERSISTENCE-ALLOWED`     | Matching jobs accepted by `JOBS_ALLOW` (always listed)                                      |
| `SVC-PERSISTENCE-STALE-ALLOW` | `JOBS_ALLOW` fingerprints that no longer match any job                                      |
| `SVC-PERSISTENCE-VENDOR`      | Matches in files shipped **unmodified** by an installed package                             |
| `SVC-PERSISTENCE-VENDOR-COPY` | Matches in a local copy (`/etc/systemd/system`) of an unmodified packaged unit that differs only in start order (INFO) |
| `SVC-PERSISTENCE-SCOPE`       | Skipped: other users' and root's crontabs need sudo                                         |
| `SVC-AT-JOBS`                 | Pending `at` jobs (counted, not inspected)                                                  |
| `SVC-SCHEDULED`               | Inventory of scheduled and startup jobs, with fingerprints (schedule and program name only) |

**Persistence check — sources:**

- crontabs (every user's with sudo, your own otherwise), `/etc/crontab`,
  `/etc/cron.d`, scripts in `/etc/cron.{hourly,daily,weekly,monthly}`;
- systemd services **and drop-in overrides** (`*.service.d/*.conf`, which can
  alter vendor units too): `/etc/systemd/system`, `/etc/systemd/user`,
  `~/.config/systemd/user`, `~/.local/share/systemd/user`; every `Exec*=` key,
  continuation lines joined;
- autostart entries: `~/.config/autostart`, `/etc/xdg/autostart`;
- shell startup files: `~/.bashrc`, `~/.bash_aliases`, `~/.profile`, `~/.bash_profile`,
  `~/.bash_login`, `~/.bash_logout`, `~/.zshrc`, `~/.zprofile`, `~/.zlogin`,
  `~/.xprofile`, `~/.xsessionrc`, `/etc/profile`, `/etc/bash.bashrc`,
  `/etc/profile.d/*.sh`;
- `at` jobs (count only).

**Patterns** (the reason is shown next to each match): download-and-execute
(`$(curl …)`, `$(/usr/bin/curl …)`, backticks, `curl … | sh`),
download-then-run (`curl -o f …; sh f`, `… && chmod +x`), anything piped into
a shell, base64 decoding, `/dev/tcp`, inline interpreters (`python -c`,
`perl -e`…) with a URL or network module; and, for jobs run every 1–5
minutes, at boot or at login: any network tool (`curl`, `wget`, `nc`,
`socat`…) and programs run from `/tmp`, `/var/tmp`, `/dev/shm` or a `.cache`
directory.

**Not covered:** the _content_ of the scripts a job runs (`python3 ~/x.py`
is only seen as a command line), systemd units in vendor directories
(`/usr/lib`), udev rules, kernel modules, desktop-environment-specific
startup mechanisms, and anything obfuscated beyond these patterns.

**Packaged files.** A match inside a file that an installed package shipped,
and that is byte-for-byte unchanged (checked against the package database),
is reported as `SVC-PERSISTENCE-VENDOR` (INFO) instead of a warning — for
example Google Chrome's daily job, which installs its repository key with
`base64 -d`. For a symlink (Chrome's `/etc/cron.daily/google-chrome` points
into `/opt/google`), the link must belong to a package and its target must be
a packaged, unmodified file. Such a file is as trustworthy as its package; if
it is modified or the link is redirected, it is flagged again.

**Local copies of packaged units.** Some installers write a copy of a
packaged service into `/etc/systemd/system` (Ubuntu's desktop image does so
for `cloud-init-network.service`, whose `ExecStart` pipes a socket into `sh`).
Such a match is reported as `SVC-PERSISTENCE-VENDOR-COPY` (INFO) only when all
of these hold: the copy is a regular file owned by root and writable by root
only, owned by no package; a unit of the same name in `/usr/lib/systemd/system`
(or `/lib/systemd/system`) is an unmodified file of an installed package; no
drop-in (`<name>.d/*.conf` or `service.d/*.conf` in `/etc`, `/run`,
`/usr/local/lib`) changes it; and the two files differ only in the
`After=`, `Before=`, `Description=` and `Documentation=` lines of `[Unit]`
(comments ignored). Any other difference keeps the warning. This only proves
"same commands as an installed package": a malicious package would pass too.

### Persistence detection: approach and limits

Recognising malicious commands by their shape is an arms race that cannot be
won: every pattern added invites a new variant (`eval`, variables holding the
command name, base32, hexadecimal, URLs split across variables...), and every
new pattern adds complexity and false positives. The tool therefore uses two
complementary layers:

1. **Change detection (the main safeguard).** The first run records the
   fingerprint of every inspected command in a reference list. From then on,
   any job that **appears or changes** is reported as `SVC-PERSISTENCE-NEW` —
   obfuscated or not, since persistence always has to add or change an entry.
   It stays reported at every run until you review it and accept it; a change
   is never absorbed silently because a monthly report was skipped.

   Acceptance only covers **what you reviewed**, never "whatever is there now":

   ```bash
   ./uhc.sh --accept-jobs                       # in a terminal: shows the exact
                                                # list, accepts it after confirmation
   ./uhc.sh --accept-jobs 422a8054eb72 …        # or: only these fingerprints
   uhc-root --accept-jobs                       # root reference list (needs sudo)
   ```

   Anything that appeared after the list you confirmed stays pending. Each
   acceptance is recorded in `logs/uhc.log` with its fingerprints. Lines of
   files shipped unmodified by packages that change with an update are shown
   separately (`SVC-PERSISTENCE-NEW-PACKAGE`, INFO), for traceability.

   **Where the reference list lives matters.** For unprivileged runs it is in
   your data directory (`logs/`), so a program running under your account can
   edit or delete it. Deletion is detected (a marker records that a list
   existed, and the tool warns that it was recreated), but a program that
   knows the tool can defeat this. For **root runs**, the list lives in the
   root-owned installation (`/opt/ubuntu-health-check/state/`, root only): a
   program running as you can neither read, erase nor edit it, and accepting
   changes requires sudo. **A regular root audit is therefore the robust way
   to watch your own account's persistence** (crontab, `~/.bashrc`, autostart,
   user units): the root run inspects them with your privileges but keeps its
   reference out of your reach.

2. **Patterns (for the first audit, and a second opinion).** They catch
   known-bad shapes in jobs that already existed before the reference list,
   and give a reason for each match. `JOBS_ALLOW` accepts individual matches.

Acceptances in the log that you did not make, and allowed entries you did not
add, are red flags. A clean result means "nothing new and nothing matched",
not "nothing is there".

**Scope.** This is a maintenance tool, not an intrusion detection system. For
stronger guarantees, use dedicated tools: **AIDE** (file integrity against a
protected reference), **auditd** (real-time audit of changes to cron,
systemd and startup files), **rkhunter** / **chkrootkit** (known rootkits),
and **Lynis** (hardening). The pattern layer will receive fixes for false
positives and obvious gaps, but no race against obfuscation.

**Allowing a known job.** Each job has a fingerprint (first column in the
report). Add it to `JOBS_ALLOW` in `uhc.conf` to accept that exact line. Any
change to the line (schedule, URL, arguments) produces a new fingerprint and
the warning comes back; a fingerprint that no longer matches anything is
reported so you can remove it. Prefer this to `IGNORE_CHECKS`, which would
also hide future malicious jobs.

`uhc.conf` can be edited by any program running under your account, which
could add its own fingerprint. Allowed jobs therefore always remain listed in
the report (`SVC-PERSISTENCE-ALLOWED`): **an entry there that you did not add
yourself is a red flag.**

### Network exposure

| ID                              | Check                                                                |
| ------------------------------- | -------------------------------------------------------------------- |
| `NET-LISTEN`                    | TCP services listening outside localhost (critical without firewall); INFO when they all listen on a VM bridge (`virbr*`), whose lines are marked in the evidence otherwise |
| `NET-LISTEN-EXPECTED`           | Ports declared in `ALLOWED_PORTS`                                    |
| `NET-UDP` / `NET-UDP-DISCOVERY` | UDP services (VM bridge sockets marked); mDNS / DHCP / SSDP sockets  |
| `NET-FIREWALL`                  | Firewall active (ufw or firewalld)                                   |
| `NET-FW-POLICY`                 | Default incoming policy (sudo)                                       |
| `NET-FW-RULES` / `NET-FW-STALE` | Rules, and rules opening ports nothing listens on (sudo)             |
| `NET-IPV6`                      | Public IPv6 address (no NAT: exposure matters more)                  |

### Docker

| ID            | Check                                                               |
| ------------- | ------------------------------------------------------------------- |
| `DKR-REPO`    | Docker package still provided by a configured repository            |
| `DKR-UPDATE`  | Docker update available                                             |
| `DKR-GROUP`   | Members of the `docker` group (root-equivalent)                     |
| `DKR-EXPOSED` | Containers publishing ports on all interfaces (Docker bypasses ufw) |

### Virtualisation

Virtual machines managed by libvirt (`virsh`, always `--readonly`, local
URIs only). `qemu:///system` is always queried (systemd socket activation
may start the system daemon, which changes nothing). The user's own
`qemu:///session` is queried only when its daemon is already running, with
`LIBVIRT_AUTOSTART=0`: connecting would otherwise start a session daemon.
When it is not running, only the names of `~/.config/libvirt/qemu/*.xml` are
listed. Domain XML is read without `--security-info` (no console passwords),
and only a few attributes are extracted from it.

| ID                  | Check                                                                    |
| ------------------- | ------------------------------------------------------------------------ |
| `VIRT-ABSENT`       | libvirt not installed (INFO, nothing else in the section)               |
| `VIRT-ACCESS`       | Skipped: `virsh` missing, or `qemu:///system` cannot be queried          |
| `VIRT-SESSION`      | Skipped: session VMs not queried (daemon not running), or query failed   |
| `VIRT-VMS`          | Inventory: each VM with state, start at boot, persistence, memory, vCPU, disks (size from the pools) and networks; libvirt networks and storage pools (INFO; OK when no VM) |
| `VIRT-DISK-MISSING` | A disk or ISO file of a VM no longer exists (WARNING); a path that cannot be tested is reported as skipped, never as missing |
| `VIRT-CONSOLE`      | VNC / SPICE / RDP console listening on a non-local address (WARNING); local, socket, VM-bridge and NAT-network listens are not reported. Password protection cannot be checked |
| `VIRT-SNAPSHOTS`    | Snapshots per VM: count, oldest and newest, state when taken (running = memory included) |
| `VIRT-IMAGE-ORPHAN` | Pool volumes that look like disk images (extension `qcow2`, `img`, `raw`, `iso`, `vmdk`, `vdi`, `vhd(x)`, `qed` in folder pools; every volume of LVM/ZFS pools) used by no VM as disk, ISO, kernel/firmware or direct backing file; two pools on one folder are counted once (INFO) |
| `VIRT-GROUP`        | Members of the `libvirt` group (root-equivalent)                         |
| `VIRT-LXD-GROUP`    | Members of the `lxd` group, only when LXD is installed (root-equivalent) |

### Security posture

| ID                  | Check                                                                    |
| ------------------- | ------------------------------------------------------------------------ |
| `SEC-DISK-ENC`      | Disk encryption (warning on laptops)                                     |
| `SEC-SECUREBOOT`    | Secure Boot state                                                        |
| `SEC-APPARMOR`      | AppArmor enabled                                                         |
| `SEC-UID0`          | Accounts other than root with UID 0                                      |
| `SEC-ADMINS`        | Accounts with sudo rights                                                |
| `SEC-EMPTY-PW`      | Accounts with an empty password (sudo)                                   |
| `SEC-SSHD`          | SSH server running, weak settings                                        |
| `SEC-SSH-KEYS`      | SSH private keys stored unprotected (OpenSSH, PEM, PKCS#8, PuTTY `.ppk`) |
| `SEC-SSH-FIDO`      | Hardware-backed (FIDO) keys, which need no passphrase                    |
| `SEC-SSH-INVENTORY` | Key list with type, protection, mode and date, to spot obsolete keys     |
| `SEC-SSH-PERMS`     | Permissions of `~/.ssh` and private keys                                 |
| `SEC-HOME-PERMS`    | Home directory readable by other users                                   |
| `SEC-SECRET-PERMS`  | Files that usually hold credentials (`~/.netrc`, `~/.git-credentials`, `~/.aws/credentials`, `~/.docker/config.json`, `~/.config/gh/hosts.yml`, Claude Code, FileZilla…) readable or writable by group or others, or not owned by the user; mode only, files never opened (INFO when no other account can reach them) |

### Backups

| ID           | Check |
| ------------ | ----- |
| `BAK-STATUS` | Inventory of backup tools (Timeshift, Déjà Dup, borg/borgmatic, restic, rsnapshot, duplicity, Back In Time, Pika Backup, snapper, kopia), backup timers and cron jobs running a copy program (rsync, rclone, tar…): scheduled or not, last known backup. WARNING only when a scheduled backup is older than `BACKUP_MAX_AGE` days or its last run failed; INFO otherwise, also when no tool is found. A backup to a NAS, an online service or a manual copy cannot be seen from here. Configuration files of backup tools are never opened |

## Configuration

```bash
cp uhc.conf.example uhc.conf
```

`uhc.conf` is ignored by git and read from the data directory (also for sudo
runs, so it is writable by your account: see the note on `JOBS_ALLOW`). The available
keys (thresholds, notification level, expected ports, silenced checks, ignored
packages, report retention, language) are documented in
[`uhc.conf.example`](uhc.conf.example). Invalid values are rejected and the
default is kept.

`SNAP_REFRESH_MAX_AGE` (days, default 14) sets how old the last snap refresh
may be before `SNAP-REFRESH` reports it. `BATTERY_HEALTH_WARN` (percent,
default 60) is the share of its design capacity below which a battery is
reported by `HW-BATTERY`. `BACKUP_MAX_AGE` (days, default 30) is the age of
the last backup of a scheduled tool above which `BAK-STATUS` warns; raise it
if your backups are scheduled less often.

Typical use: silence an accepted risk you cannot fix right now.

```ini
IGNORE_CHECKS="SEC-DISK-ENC"
ALLOWED_PORTS="22/tcp"
```

Silenced checks are still listed in the report summary, so they are never
completely forgotten.

## Scheduling

The tool installs its own systemd timer: daily, weekly or monthly, at a fixed
daytime hour (within 15 minutes). A run missed while the machine was off
happens at the next start. This works on a server as well as on a desktop.

### Routine audit (your account, no sudo)

```bash
./uhc.sh --install-timer                 # user, monthly (default)
./uhc.sh --install-timer user weekly     # run again to change the frequency
./uhc.sh --timer-status                  # prints user=weekly and root=none
./uhc.sh --remove-timer
```

The command shows the two units it will write
(`~/.config/systemd/user/uhc.service` and `uhc.timer`, 10:00) and the commands
it will run, asks for confirmation, then runs `systemctl --user daemon-reload`
and `systemctl --user enable --now uhc.timer`. `--yes` skips the question
(user timer only, for programs such as the top-bar icon). Units written by
hand, as earlier versions of this README described, are never replaced or
removed silently.

A user timer runs while your user session manager is alive (normally: while
you are logged in). To run it even when you are not logged in, enable
lingering: `sudo loginctl enable-linger "$USER"`. Check the next run with
`systemctl --user list-timers uhc.timer`; test with
`systemctl --user start uhc.service`. If you move the tool, run
`--install-timer` again.

### Full audit (root)

Once the root-owned copy is installed (see
[Full audit with sudo](#full-audit-with-sudo)):

```bash
uhc-root --install-timer root weekly     # = sudo /opt/ubuntu-health-check/uhc.sh --data-dir <this folder> ...
uhc-root --remove-timer root
```

This writes `/etc/systemd/system/uhc-root.service` and `uhc-root.timer`
(11:00), which run `/opt/ubuntu-health-check/uhc.sh --data-dir <folder>
--quiet --no-notify`. The reports are written in your folder with your
privileges, as with `uhc-root`. The root timer is only installed by the
root-owned copy, in a terminal, never with `--yes`. Its service runs in a
sandbox: read-only file system except the data folder, private `/tmp`, no
network, no privilege gain.

The first audit after installing a timer reports the new units as new startup
jobs (`SVC-PERSISTENCE-NEW-*`): expected, accept them with `--accept-jobs`.
`contrib/uhc*.service` and `contrib/uhc*.timer` are reference copies of the
units the tool writes.

### Without systemd: cron

From the tool directory:

```bash
(crontab -l 2>/dev/null; grep -v '^#' contrib/crontab.example | sed "s|@UHC_DIR@|$PWD|") | crontab -
crontab -l    # check the new line
```

This appends one line (1st of each month, 10:00) to your existing crontab.
The tool sets its own `PATH` and locates your desktop session bus, so
notifications also work from cron when you are logged in.

## Top-bar icon (optional, desktop only)

On Ubuntu Desktop, an icon in the top bar shows the state of the last audit,
by colour and by shape:

| Icon | Meaning |
|---|---|
| Green circle with a check mark | Nothing to report |
| Orange triangle | Warnings |
| Red octagon | Critical findings |
| Hollow grey ring with a question mark | No audit yet, or the last one is older than 35 days |

Its menu shows the date and counts of the last audit and what changed since
the previous one, opens the last report or the reports folder, runs an audit,
opens a terminal for a full audit with sudo, and sets the schedule: the
routine audit directly, the full audit in a terminal with sudo.

```bash
./uhc.sh --install-indicator      # after confirmation; no sudo
./uhc.sh --remove-indicator
```

It writes one file, `~/.config/autostart/uhc-indicator.desktop`, so the icon
starts at each login. Requirements, all present on Ubuntu Desktop: `python3`,
`python3-gi`, `gir1.2-gtk-3.0`, `gir1.2-ayatanaappindicator3-0.1` and, under
GNOME, the "Ubuntu AppIndicators" extension, enabled. If one is missing, the
command says which and writes nothing. The installation wizard offers the
icon only to a user with a graphical session: nothing changes on a server,
and the audit never needs the icon.

The icon is the only part of the tool written in Python. It never runs as
root and never asks for a password itself: before anything that needs sudo,
it asks for confirmation and shows the command, then sudo asks in a terminal. It makes no
network connection and runs only fixed commands, as lists of arguments. It
reads `logs/uhc.log` as untrusted data: the only value taken from it is the
report path, accepted only as a regular file inside `reports/`.

## Using the report with an AI assistant

The report is written to be pasted into an AI assistant as the starting point
of a maintenance session: every finding has an explanation, proposed actions,
raw evidence and a stable ID, and the report ends with guidance for the
assistant (treat the proposed actions as proposals to explain, simulate
before removing, stop if core desktop metapackages would be removed, explain
irreversible commands, back up data first).

```bash
./uhc.sh --sanitize            # then open the report and paste it
./uhc.sh --sanitize --print --quiet | wl-copy     # straight to the clipboard (Wayland)
./uhc.sh --sanitize --print --quiet | xclip -sel c  # (X11)
```

`--sanitize` masks the hostname, your user name, IPv4 and global IPv6
addresses, MAC addresses, SSH key file names (`ssh-key-1`, ...), container
names (`container-1`, ...) and the names chosen for libvirt virtual machines,
snapshots, networks, storage pools and image files (`vm-1`, `snapshot-1`,
`network-1`, `pool-1`, `image-1.qcow2`; folders other than
`/var/lib/libvirt/...` are shown as `…`). Loopback (`127.0.0.1`, `[::1]`) and wildcard
(`0.0.0.0`) addresses are kept, because they tell whether a service is local
or exposed.

It deliberately **keeps** repository URLs, package, snap, service and process
names, and the program names and sources of scheduled jobs: they are what an assistant needs to diagnose the system. They can still
reveal things (a private repository on a client's domain, a project name in a
process). **Review the report before sharing it.**

**Prompt injection.** Process, container and file names are chosen by
whoever runs or creates them, so a hostile program could name itself with text
aimed at an AI ("ignore your instructions..."). The tool strips control
characters and keeps such text inside code blocks, and the report instructs
the assistant to treat code blocks as untrusted data. That lowers the risk; it
cannot remove it, because it depends on the assistant following the
instruction. Read what the assistant proposes before running it.

## Limitations

- **Point-in-time, local view.** Results depend on the local package lists
  (their age is shown; run `sudo apt update` first if they are old) and on what
  is running at the moment of the audit.
- **Not a vulnerability scanner** (no CVE matching) and not a full hardening
  audit. Use Lynis for that.
- **The unprivileged run has blind spots**, listed in each report. A full
  audit needs the root-owned installation described above.
- **The root-owned copy is a snapshot**: after updating the tool, run
  `sudo ./uhc.sh` once to let the installer update it.
- **The tool cannot vouch for its own integrity** if it was modified before
  being installed in `/opt`: the trust decision happens at installation time.
  This is inherent to any locally installed root tool. Prefer installing from
  the public repository (see [Full audit with sudo](#full-audit-with-sudo)).
- **Unprivileged reference lists can be edited by your account**: use a root
  audit for a tamper-resistant persistence check.
- **The persistence check matches patterns, it is not a verdict**: legitimate
  monitoring pings match too, and obfuscated or unusual persistence (shell
  profiles, udev rules, vendor unit directories, encoded commands) may not.
  A clean result means "nothing matched", not "nothing is there".
- **Heuristics:** snap/deb duplicates are matched by name; a different name
  providing the same service is not detected. Network-facing services are
  matched against a list of common names. Ephemeral UDP ports (≥ 32768) are
  treated as client sockets.
- **Firewall:** ufw and firewalld are understood; custom nftables/iptables
  setups are reported as unknown. Docker's own rules are not analysed beyond
  published ports.
- **SSH keys:** only files in `~/.ssh` are inspected; keys stored elsewhere or
  in agents are not. Encrypted-vs-not is read from the format, which covers
  OpenSSH, PEM, PKCS#8 and PuTTY keys.
- **Sanitising is pattern-based** and keeps diagnostic names on purpose.
- **Some findings need judgment:** _INFO_ means "review", not "fix".

## Languages

The report and the terminal output are written in the computer's language
when a translation exists (English and French today), in English otherwise.
The language is chosen, in this order, by:

1. the `--lang CODE` option (`./uhc.sh --lang fr`);
2. `REPORT_LANG` in `uhc.conf` (`auto` by default);
3. the computer's locale (`LANGUAGE`, `LC_ALL`, `LC_MESSAGES`, `LANG`; from
   cron or a timer, which start without a locale, the system default in
   `/etc/default/locale`). `UHC_LANG=fr ./uhc.sh` also forces it;
4. English.

A language without a folder in `lib/lang/` falls back to English, and so does
any message not translated yet. Finding IDs, severity words (`CRITICAL`,
`WARNING`...), proposed commands, `--help`, error messages and the log line
stay in English.

To add a language, copy `lib/lang/en/` to `lib/lang/<code>/` (two lowercase
letters) and translate the text after each `=`, keeping the keys and the
`{variables}` unchanged. Catalogs are plain text, read and never executed.
Check them with `contrib/check-lang.sh`.

## Adding a check

Checks live in `lib/checks/NN-name.sh` and are loaded in numeric order. Their
texts live in `lib/lang/<code>/NN-name.lang`, one `key=text` per line, and are
looked up with `t KEY [name=value ...]`. A module calls:

```bash
section "$(t section.NN-name)"
finding WARNING MY-ID "$(t MY-ID.warn.title count="$n")"
impact  MY-ID.warn.impact                     # what the user risks, in plain words
action  "sudo apt autoremove --simulate" MY-ID.warn.act.1   # command + what it does
action  "" MY-ID.warn.act.2                   # advice without a command
caution MY-ID.warn.caution                    # reversible? simulate first? reboot?
evidence "$(t MY-ID.ev.1)" "$(some read-only command)"
partial MY-ID "$(t MY-ID.partial.1)"
```

Keys follow `<ID>.<variant>.title`, `.impact`, `.caution`, `.act.<n>`,
`<ID>.partial.<n>` and `<ID>.ev.<n>`. Every CRITICAL and WARNING finding gets
an `impact` and at least one `action`; they also feed the action plan shown
after the summary and at the end of the terminal output. An INFO finding gets
them when a decision is expected; an OK finding only has its title. Proposed
commands are never run by the tool: prefer a simulation or a read-only
command first, and say in the description whether the action can be undone.
Insert a name that comes from the system into a command only through
`safe_name VALUE '<package>'`. The old form, `finding SEV ID TITLE
"EXPLANATION"`, still works for modules not migrated yet.

Helpers from `lib/common.sh`: `have CMD`, `run CMD ARGS` (with timeout),
`pkg_installed NAME`, `pkg_in_repo NAME`. Keep every command read-only, never
print secrets, pass untrusted names through `evidence` (or `clean_line` for
titles), run `apt`/`apt-cache`/`apt-mark` with `"${APT_RO[@]}"`, read files in
the user's home through `as_target`, never report OK when the underlying
command failed (use `partial`), and run
`shellcheck -x -S style uhc.sh lib/*.sh lib/checks/*.sh contrib/check-lang.sh contrib/check-units.sh`,
`contrib/check-lang.sh` and `contrib/check-units.sh` before submitting.

## License

MIT — see [LICENSE](LICENSE).
