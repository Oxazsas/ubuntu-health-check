# Changelog

## 2.9.0

Five new checks: expired repository keys, third-party repositories left out
of automatic updates, sockets without a service, credential files with loose
permissions and programs installed by hand in `/usr/local`. Every new command
is read-only and answered locally: no new network access.

### APT
- New `APT-KEY-EXPIRED`: a repository signing key has expired (WARNING when
  an enabled repository uses it, since apt then refuses its updates; INFO
  when no enabled repository does) or expires within 30 days (INFO). The
  keyrings named by `Signed-By` in the enabled entries are read, both
  formats, including a key written inside a `.sources` file, plus
  `/etc/apt/trusted.gpg.d` and `/etc/apt/trusted.gpg` for the entries
  without `Signed-By`. `gpg --show-keys` runs with a home in the private
  temporary directory and `--no-autostart`: nothing is written elsewhere and
  no agent is started. A key counts as expired when it can no longer sign
  (expired primary key, or all its signing subkeys expired). The evidence
  gives the keyring, key ID, owner, date and repositories. Without `gpg`, or
  for a keyring that cannot be read, the check is reported as partial.
- New `APT-UNATTENDED-THIRDPARTY` (INFO), when automatic updates are
  enabled: the enabled third-party repositories whose origin (`apt-cache
  policy`) matches no `Allowed-Origins` or `Origins-Pattern` entry, with the
  number of pending updates from each. Patterns are compared as
  unattended-upgrades does (wildcards, `${distro_id}`,
  `${distro_codename}`); an entry this check does not reproduce makes the
  coverage "not determined" rather than guessed. The consequence says this
  is Ubuntu's default; the actions give both choices (update by hand, or add
  an origin) and the precaution warns that an automatic third-party update
  can break software without warning.

### Services
- New `SVC-SOCKET-ORPHAN` (WARNING): an active socket unit whose service no
  longer exists (`LoadState=not-found`), typically after a package was
  removed. For a socket with `Accept=yes`, the template service
  (`<name>@.service`) is looked up. Also for the user's own sockets when the
  audit runs without sudo, like `SVC-USER-FAILED`. Other `not-found` units
  are not reported.

### Security
- New `SEC-SECRET-PERMS` (WARNING): files that usually hold credentials
  (`~/.netrc`, `~/.git-credentials`, `~/.aws/credentials`,
  `~/.docker/config.json`, `~/.kube/config`, `~/.config/gh/hosts.yml`,
  Claude Code and FileZilla files...) readable or writable by the group or
  others, or not owned by the audited user. Only `stat` is used, as the
  audited user: the files are never opened. INFO instead of WARNING when no
  other account can reach them (home folder closed to others, and a group
  without another member). The evidence gives the
  `~/...` paths, modes and the home folder's mode.

### System
- New `SYS-LOCAL-BIN` (INFO): inventory of the executables and links of
  `/usr/local/bin` and `/usr/local/sbin` (not their subfolders) that no
  package owns, found with a single `dpkg -S` call: name, size, date and
  link target, never their contents.

### Fixes
- The simulation behind `APT-PHASED` (`apt-get -s upgrade`) made apt try to
  write its planner log, `/var/log/apt/eipp.log.xz`, which succeeded when
  run as root. apt is now told not to write that log.

### Considered and left out
- A network test to the Snap Store: the tool adds no network access.
- A list of end-of-life Docker runtimes: such a list must be maintained and
  is soon out of date.
- Detecting services "not in use": the tool cannot know how a service is
  used; `SVC-NETWORK` gives the inventory for the user to decide.
- Freshness of each snap: a snap without a new version would be reported by
  mistake; `SNAP-REFRESH` covers refreshes that stopped.

## 2.8.0

Three new snap checks and a breakdown of what can be freed when a disk fills
up. Every new command is read-only and answered locally: no new network
access.

### Snaps
- New `SNAP-REFRESH` (WARNING): the last snap refresh is older than
  `SNAP_REFRESH_MAX_AGE` days (new configuration key, default 14), or
  refreshes of all snaps are on hold (`hold:` line of `snap refresh --time`).
  A hold on some snaps only (`held` in `snap list`) is reported as INFO. The
  precaution recalls that a hold may have been set on purpose.
- New `SNAP-BRANCH` (WARNING): a snap follows a channel branch made for
  another Ubuntu release, such as `latest/stable/ubuntu-25.10` on 26.04, and
  no longer receives the updates made for this one. `snap list` shortens
  branches (`latest/stable/…`), so the full channel is read from the local
  snapd API (`snap debug api /v2/snaps`, installed snaps only, no root
  needed). If that fails, shortened channels are reported as partial.
- `SNAP-ERRORS`: when the failed operations name the Snap Store
  (`api.snapcraft.io`) or a network failure, the consequence and actions say
  that the store or the connection was probably unavailable, rather than a
  problem on the computer. The logs of up to five failed operations are read
  with `snap tasks` (local). Same ID, same severity.

### Disk space
- New `SYS-DISK-USAGE` (INFO), only when a filesystem is above `DISK_WARN`:
  disabled snap revisions, `~/snap` of the audited user, reclaimable Docker
  data, kernels other than the running one and the two newest (those apt keeps), the journal and
  the apt cache are measured and listed largest first. A place that cannot be
  read is reported as partial.
- `SYS-DISK` then proposes, instead of its generic commands, those of each
  measured place of at least 100 MiB, with the measured size: reading or
  simulation first, then the command that frees the space. They appear in the
  action plan. The generic commands are kept when `SYS-DISK-USAGE` is
  silenced.

## 2.7.0

The tool still only diagnoses, and never runs a fix. It now explains each
finding in plain words and proposes what to do about it, in the computer's
language.

### Explanations and proposed actions
- Each finding that calls for a decision is split into three parts instead of
  one paragraph: **what it means** (what you risk if you do nothing), **what
  you can do** (commands to run yourself, each with what it does and whether
  it can be undone; read-only commands and simulations first) and **before
  you act** (what to check, simulate or back up).
- New **action plan**: the critical findings, then the warnings, with their
  consequence, actions and precautions. It is a section of the report, placed
  after the summary, and it is printed in the terminal after the result line.
  The new `--brief` option keeps the terminal to one line per finding.
- Names that come from the system (package, snap, unit, account) are inserted
  into a proposed command only when the finding concerns a single item and
  the name is a plain one; otherwise the command keeps a placeholder such as
  `<package>` and the items stay in the evidence. Names masked by
  `--sanitize` (SSH key files, containers) never appear in a command.
- The notes for an AI assistant gain a point: proposed actions are written by
  the tool, unlike the content of code blocks, and remain proposals to
  explain to the owner.

### Languages
- Report and terminal output are available in **English and French**. The
  language is chosen by `--lang CODE`, then `REPORT_LANG` in `uhc.conf`, then
  the computer's locale (the system default from cron or a timer), then
  English. A language or a message without translation falls back to English.
- Texts live in `lib/lang/<code>/*.lang`, plain `key=text` files that are
  read and never executed. They are part of the code fingerprint, so the
  fingerprint of an installed copy changes with this version.
  `contrib/check-lang.sh` checks the catalogs (also in the CI workflow).
- Finding IDs, severity words, proposed commands, `--help`, error messages,
  the installation wizard and the log line stay in English.
- Root runs: the language code is read before the environment is reset and
  passed to the re-executed script as `UHC_LANG`, accepted only as two
  lowercase letters.

### Fixes
- `SEC-SSH-KEYS` reported an unprotected **ed25519** key as fine on systems
  whose `base64` rejects the whole input on an invalid character (uutils
  coreutils, Ubuntu 25.10 and later): the END line of a short key was fed to
  the decoder. The line is now left out.
- Stopping the SSH server is proposed as `disable --now ssh.service
  ssh.socket`: on recent releases the socket starts the server again on
  demand.
- When several filesystems are full, the actions are listed once.

No finding ID or severity changed.

## 2.6.2

Two false positives fixed.

- Upgrades deferred by Ubuntu's phased updates were counted as pending in
  `APT-UPGRADES` / `APT-SECURITY-UPGRADES`. They are now read from a simulated
  upgrade (`apt-get -s upgrade`, no root needed, nothing changed), left out of
  those counts and reported apart by the new `APT-PHASED` (INFO), since they
  install by themselves. With an older apt that does not report phasing, or if
  the simulation fails, nothing changes.
- `SNAP-DUPLICATE` was a warning for every program installed both as a snap
  and as a deb, including expected pairs such as `snapd`. It stays a warning
  only when both sides provide a service (the snap declares one, and the deb
  ships a systemd service unit that is active or enabled), as with two
  Bluetooth daemons. Other duplicates are reported under the same ID as INFO,
  and so are all duplicates when systemd is not the init system.


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
