# Changelog

## 2.6.1

Fixes from the eighth review (no security issue found).

- The message of `uhc-root` when the root copy is missing lost its quotes
  (nested double quotes). The path is now escaped for use inside the
  double-quoted message (`\ " $ `` ` ``), so it displays as is and a path
  containing `$(...)` can never be executed by the alias.
- The `uhc` alias broke when the tool's folder contained a space, and a folder
  name containing `$(...)` was executed at each use (a bash alias is parsed
  again every time it is used). `uhc` is now a shell function, like
  `uhc-root` and `uhc-last`: parsed once, safely quoted. Existing alias blocks
  are updated the next time the installer offers them.
- Installing from the repository reported every failure as "tag not found".
  The repository is now queried first (`git ls-remote`): an unreachable
  repository (network, address, access) and a missing tag give different
  messages, and git's own errors stay visible.


## 2.6.0

Follow-up to a seventh review: 2.5 had turned `sudo ./uhc.sh` into the usual
way to start full audits, which ran the user-owned folder as root every time
and voided the purpose of the root copy.

### Root runs
- `sudo ./uhc.sh` is now **only an installer**: it installs or updates the
  root-owned copy (terminal only) and never runs an audit. With an up-to-date
  copy, it only prints the commands to use. After an installation or update,
  it offers the aliases and one first audit from the new copy.
- Nothing but `uhc.sh` itself runs before the root safety check: the
  libraries are loaded afterwards (or, on the installation path only, the two
  the installer needs). The fingerprint function lives in `uhc.sh`.
- Installation from the repository clones the **release tag** `v<version>`,
  not the default branch; if the tag is missing, the default branch is only
  used after explicit confirmation.

### Aliases
- `uhc-root` is a function that **only ever runs the root-owned copy**; when
  it is missing, it explains how to install it instead of running the user
  folder as root.
- The installation wizard offers the aliases; they are installed with the
  invoking user's privileges (not as root).
- Name conflicts are checked against the caller's real `PATH` (kept aside,
  never used to run anything), the system `PATH` and common per-user tool
  directories (Cargo, Go, Volta, npm, Deno, Bun, pnpm).

### Packaging
- `state/` added to `.gitignore`; the 2.5 archive wrongly contained a test
  reference list. Archives are now checked against an explicit file list.


## 2.5.0

Follow-up to a sixth review, focused on the change-detection layer.

### Root runs
- **Installation wizard**: `sudo ./uhc.sh` from your folder, in a terminal,
  explains the root copy, shows fingerprints and offers to install or update
  `/opt/ubuntu-health-check` — from the public repository when
  `UHC_REPO_URL` is set in the code (recommended), or from the folder — then
  to run the audit from it. Identical copy: runs it directly. Without a
  terminal: refuses, as before. Replaces the manual copy commands.
- The persistence **reference list of root runs is stored in
  `/opt/ubuntu-health-check/state/`** (root only). A program running as the
  user can no longer read, erase or edit it, and accepting changes needs
  sudo. The 2.4 root list kept in the data directory is no longer used (a new
  one is created on the first 2.5 root run).

### Change detection
- `--accept-jobs` accepts **only what was reviewed**: explicit fingerprints
  (`--accept-jobs FP…`), or, in a terminal, the exact list shown on screen
  after confirmation. Without either, nothing is accepted. Changes appearing
  after the list was shown stay pending. The log records the count and the
  fingerprints accepted.
- A reference list that disappeared although it existed is reported as a
  WARNING (marker file), instead of silently starting over.
- Lines changed by package updates are listed as `SVC-PERSISTENCE-NEW-PACKAGE`
  (INFO) instead of being ignored silently.
- A packaged symlink is trusted only if its target belongs to the **same**
  package.
- `~/.bash_aliases` is now covered.

### Convenience
- `--install-aliases [NAME]` / `--remove-aliases`: optional `uhc`,
  `uhc-root`, `uhc-last` aliases in a delimited block of `~/.bash_aliases`,
  after confirmation, with automatic path detection and a check that the
  names are not already used on the machine. No Ubuntu 24.04 package
  provides a `uhc` command.

### Documentation
- Honest security model of the root copy: what it protects (later changes to
  the user folder) and what it cannot (a copy modified before installation,
  a compromised session).


## 2.4.0

Change of approach for persistence detection, after a fifth review showed
that pattern matching alone keeps missing new command shapes.

### Detection
- **Change detection**: a reference list of every inspected scheduled or
  startup command is created on the first run. Jobs that appear or change are
  reported as `SVC-PERSISTENCE-NEW` at every run, whatever their form, until
  accepted with the new `--accept-jobs` option (acceptances are logged).
  New lines in shell startup files and removed commands are reported as INFO.
  Updates of unmodified packaged files are not reported as new.
- Chrome false positive fixed: `/etc/cron.daily/google-chrome` is a symlink,
  for which dpkg stores no checksum. A packaged symlink is now trusted when its
  target is a packaged, unmodified file; a modified target or a redirected
  link is still flagged.
- Pattern generalisations (no new families): a path before the interpreter
  (`| /bin/bash`), a pipe into any interpreter reading stdin (`| python3`),
  process substitution (`sh <(curl …)`, `. <(curl …)`), `%` in crontab
  commands treated as a line break (as cron does), and the temporary/cache
  directory check now looks at the program started, not every word (a line
  that only reads `~/.cache/...` is no longer flagged).

### Scope
- The README documents the two-layer approach, its limits, and points to
  AIDE, auditd, rkhunter/chkrootkit and Lynis for intrusion detection. The
  pattern layer will get fixes for false positives and obvious gaps, not a
  race against obfuscation.


## 2.3.0

Follow-up to a fourth external review. Persistence detection moved to its own
module (`55-persistence.sh`); check IDs are unchanged.

### Detection
- File names containing a tab or newline (autostart entries and user units
  are named by the user's account) shifted internal fields and hid the entry
  completely. Labels and paths are now sanitised and passed to awk through
  ENVIRON (`awk -v` also turned a literal `\t` into a tab).
- Multi-line `ExecStart=` (backslash continuation) was not read: continuation
  lines are joined, every `Exec*=` key is inspected, and systemd drop-in
  overrides (`*.service.d/*.conf`) and `~/.local/share/systemd/user` are
  covered.
- New patterns: `$(/usr/bin/curl …)` with an absolute path, download-then-run
  (`curl -o f …; sh f`, `&& chmod +x`), programs run from `/tmp`, `/var/tmp`,
  `/dev/shm` or `.cache` at boot, login or every few minutes. The reason is
  shown next to each match.
- Shell startup files are now covered (`~/.bashrc`, `~/.profile` and
  friends, `/etc/profile`, `/etc/bash.bashrc`, `/etc/profile.d`).
- False positive for every Chrome user (`/etc/cron.daily/google-chrome`
  installs its key with `base64 -d`): matches in files shipped unmodified by
  a package are reported as `SVC-PERSISTENCE-VENDOR` (INFO); a modified file
  is still a warning.

### Compatibility
- `SVC-CRON-SUSPECT` (renamed in 2.2.0) is accepted again in
  `IGNORE_CHECKS`, mapped to `SVC-PERSISTENCE` with a message. IDs will not be
  renamed from now on.

### Documentation
- All persistence IDs listed; exact coverage and non-coverage documented;
  note that `uhc.conf` (and thus `JOBS_ALLOW`) is writable by the user's
  account, so allowed entries must be reviewed.


## 2.2.0

Follow-up to a third external review.

### Detection
- The scheduled-job check missed common forms, including the one found on a
  real machine: `(curl …)`, `bash -c "$(curl …)"`, `*/2` to `*/5` and `0-59`
  schedules, `python -c` / `perl -e` fetching URLs. The classifier now
  catches download-and-execute in any form, pipes into a shell, inline
  interpreters with network code, and network tools run every 1-5 minutes,
  at boot or at login, without flagging names that merely contain "curl".
- Broader and documented coverage, renamed `SVC-CRON-SUSPECT` →
  `SVC-PERSISTENCE`: every user's crontab (with sudo), cron.hourly/daily/
  weekly/monthly scripts, custom systemd services (system and user),
  autostart entries, `at` jobs (count).
- `JOBS_ALLOW`: per-line allow list by fingerprint. A changed line is
  flagged again; stale entries are reported. Replaces silencing the whole
  check with `IGNORE_CHECKS`.

### Security
- Interpreter started as `bash -p` (ignores `BASH_ENV` and exported
  functions); the root environment check now runs before any command, uses
  `EUID` and absolute paths, and also detects inherited functions.
- Text cleaning repeats until stable: removing a bidi character could join
  two bytes into a C1 control character.
- README: the self-computed fingerprint cannot prove integrity; verify a
  root copy with `diff -r` against a trusted source.


## 2.1.0

Follow-up to a second external review.

### Security
- Root runs re-execute the tool with an empty environment plus a whitelist:
  variables preserved by `sudo -E` or `env_keep` (e.g. `PYTHONPATH`, which
  reached the Python-based `ufw`/`firewall-cmd`) no longer affect root
  commands. A guard stops the run if the cleanup fails.
- A root-owned data directory must have a fully root-owned, non-writable
  parent chain (a user could otherwise swap a parent during the run).
- `SUDO_USER` is only honoured in root runs.
- The interpreter is `/bin/bash` (no `env` lookup through the caller's PATH).
- Untrusted text: C1 control characters (U+0080-U+009F) and bidirectional
  override characters are now removed too.
- Code fingerprint (SHA-256) in every report and log line, and a
  `--fingerprint` option to compare a root copy with its source.

### Detection
- New `SVC-CRON-SUSPECT`: scheduled jobs matching persistence patterns
  (network call every minute or at boot, download piped to a shell, base64
  decoding, `/dev/tcp`). Root crontab, `/etc/crontab` and `/etc/cron.d` are
  now scanned; cron checks no longer depend on systemd.

### Fixes
- Numeric settings with a leading zero (`08`, `099`) were read as octal by
  Bash: they are now rejected. Values are range-checked; `KEEP_REPORTS=0`
  (which deleted the report just written) is raised to 1.

### Project
- GitHub Actions workflow running ShellCheck on every push.


## 2.0.0

Security and correctness release, following an external review.

### Security
- Refuse to run as root when the tool's code is not owned by root or is
  writable by others (sudo on user-owned code allowed privilege escalation).
  A full audit now uses a root-owned copy in `/opt`, with `--data-dir`.
- Root runs write into user-owned directories with the user's privileges
  (defeats symlink attacks on the log, lock and reports); the root lock file
  lives in `/run`.
- Configuration values are validated against strict patterns: numeric values
  reached Bash arithmetic, where crafted values could execute commands.
- Untrusted text (process, container, package, file names) is stripped of
  control characters and escape sequences and cannot break out of code
  blocks; the report warns AI assistants against instructions in evidence.
- APT queries no longer rewrite the binary cache as root; `pro` runs as the
  regular user.
- `--sanitize` also masks SSH key file names and container names.

### Fixes
- `SYS-DISK` never checked anything (`df -P` and `--output` are mutually
  exclusive) and always reported OK. Checks now report "skipped" instead of
  OK when their command fails.
- SSH keys with loose permissions were counted as passphrase-protected, and
  FIDO keys as unprotected. Protection is now read from the key format
  (OpenSSH, PEM, PKCS#8, PuTTY).
- Packages stuck on a third-party version were missed (`?obsolete` ignores
  them); detection now uses apt's `local` flag.
- `IGNORE_PACKAGES` could hide the "all packages available" result.
- `-c` / `--data-dir` without an argument now fail instead of silently using
  defaults.
- Scheduling files no longer assume `~/ubuntu-health-check`: the path is
  written at installation time.

## 1.0.0

Initial release.
