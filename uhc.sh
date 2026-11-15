#!/bin/bash -p
# Settings below are consumed by the sourced check modules.
# shellcheck disable=SC2034
# -----------------------------------------------------------------------------
# ubuntu-health-check (uhc) — read-only maintenance audit for Ubuntu systems
#
# Scans package hygiene, kernel updates, repositories, snaps, services,
# network exposure, Docker, virtual machines and basic security posture,
# then writes a Markdown report designed to be read by a human or handed to an AI
# assistant as the starting point of a maintenance session.
#
# The tool never modifies the system. Persistent output (reports, log) goes to
# its data directory; transient files go to a private temporary directory
# removed at exit.
#
# Security model for root runs (sudo):
#   - the tool refuses to run as root unless its own code is owned by root and
#     not writable by anyone else (otherwise any program running as the user
#     could inject code that sudo would then execute as root);
#   - everything written to a user-owned data directory is written with that
#     user's privileges, never as root (defeats symlink tricks);
#   - files in the audited user's home are read with that user's privileges.
#
# Usage: ./uhc.sh [options]      (see --help)
# License: MIT
# -----------------------------------------------------------------------------

set -uo pipefail

UHC_VERSION="2.12.0"

# Public repository used by the root installation wizard (preferred source:
# the code goes straight from the repository to a root-owned folder). Set it in
# the code, not in uhc.conf, which any program running as the user can edit.
# Forks should point it to their own repository. Empty: install from the local
# folder, after confirmation.
UHC_REPO_URL="https://github.com/Oxazsas/ubuntu-health-check.git"
# Root-owned copy used for sudo runs, and its private state (reference lists).
ROOT_INSTALL_DIR="/opt/ubuntu-health-check"

# ---- language of the computer (read before the environment is reset) ----------
# The locale must be read here: the root re-execution below and the C locale
# forced further down both erase it. This runs before PATH is fixed, so it
# uses builtins only (no command at all), and it defines no function (the root
# block would take one for an inherited function). The result is reduced to a
# two-letter code whose only use is to pick a folder under lib/lang/. The
# letters are listed one by one because a range such as [a-z] follows the
# caller's locale at this point. UHC_LANG, when valid, forces the language
# (it is also how the code survives the root re-execution).
UHC_LOCALE_LANG=""
if [[ "${UHC_LANG:-}" =~ ^[abcdefghijklmnopqrstuvwxyz]{2}$ ]]; then
    UHC_LOCALE_LANG="$UHC_LANG"
else
    uhc_loc="${LANGUAGE:-}"
    uhc_loc="${uhc_loc%%:*}"
    [[ -n "$uhc_loc" ]] || uhc_loc="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    # cron and systemd timers start without a locale (or with C / POSIX): use
    # the system default, read as text, never sourced.
    if [[ -z "$uhc_loc" || "$uhc_loc" == C || "$uhc_loc" == C.* || "$uhc_loc" == POSIX ]]; then
        uhc_loc=""
        uhc_re='^[[:space:]]*LANG="?([^"]*)'
        if [[ -r /etc/default/locale ]]; then
            while IFS= read -r uhc_line || [[ -n "$uhc_line" ]]; do
                [[ "$uhc_line" =~ $uhc_re ]] && uhc_loc="${BASH_REMATCH[1]}"
            done </etc/default/locale
        fi
    fi
    uhc_loc="${uhc_loc:0:2}"
    [[ "$uhc_loc" =~ ^[abcdefghijklmnopqrstuvwxyz]{2}$ ]] && UHC_LOCALE_LANG="$uhc_loc"
    unset uhc_loc uhc_line uhc_re
fi

# ---- clean environment for root runs (first thing, before any command) ---------
# The shebang uses 'bash -p': Bash then ignores BASH_ENV/ENV and does not import
# functions from the environment, so nothing from the caller runs before this
# point. As root, the tool also re-executes itself with an empty environment
# plus a short whitelist: 'sudo -E' or an env_keep rule could otherwise pass
# variables such as PYTHONPATH (ufw and firewall-cmd are Python programs) or
# HOME (Docker client configuration) to root commands.
# EUID is a read-only Bash variable (cannot be faked through the environment),
# and only absolute paths are used until PATH is fixed.
# UHC_REEXEC guards against a loop: if the environment is still unexpected
# after the re-execution, the tool stops instead of continuing.
if (( EUID == 0 )); then
    env_ok=1
    [[ -n "$(declare -F)" ]] && env_ok=0          # functions inherited (run without -p)
    for v in $(compgen -e); do
        case "$v" in
            PATH|LANG|LC_ALL|HOME|TERM|NO_COLOR|SUDO_USER|UHC_REEXEC|PWD|OLDPWD|SHLVL|_) ;;
            # Kept only in its expected form (two lowercase letters).
            UHC_LANG) [[ "$UHC_LANG" =~ ^[abcdefghijklmnopqrstuvwxyz]{2}$ ]] || { env_ok=0; break; } ;;
            *) env_ok=0; break ;;
        esac
    done
    if [[ "$env_ok" == 0 ]]; then
        [[ -n "${UHC_REEXEC:-}" ]] && { echo "uhc: unexpected environment after cleanup, stopping" >&2; exit 3; }
        clean_env=(PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
                   LANG=C.UTF-8 LC_ALL=C.UTF-8 HOME=/root TERM="${TERM:-dumb}" UHC_REEXEC=1)
        [[ -n "${NO_COLOR:-}" ]] && clean_env+=(NO_COLOR=1)
        # SUDO_USER is set by sudo itself; keep it only if it is a plain user name.
        [[ "${SUDO_USER:-}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] && clean_env+=(SUDO_USER="$SUDO_USER")
        # The language code read above (already validated): LANG is reset here.
        [[ -n "$UHC_LOCALE_LANG" ]] && clean_env+=(UHC_LANG="$UHC_LOCALE_LANG")
        exec /usr/bin/env -i "${clean_env[@]}" /bin/bash -p "$(/usr/bin/readlink -f "${BASH_SOURCE[0]}")" "$@"
    fi
fi

# Parse command output in a predictable language, whatever the user's locale.
export LC_ALL=C.UTF-8 LANG=C.UTF-8
# Validated again now that ranges follow the C locale, before any use.
[[ "$UHC_LOCALE_LANG" =~ ^[a-z]{2}$ ]] || UHC_LOCALE_LANG=""

# Use system directories only: cron provides a minimal PATH (no /usr/sbin),
# and a fixed PATH prevents a program in a user-writable directory from
# being run instead of a system tool.
# The caller's PATH is kept aside only to detect name conflicts when installing
# aliases (files are tested, nothing is ever run from it).
UHC_ORIG_PATH="${PATH:-}"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin

# Resolve the tool's own directory, even when called through a symlink.
UHC_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ---- defaults (overridable in uhc.conf) --------------------------------------
KEEP_REPORTS=12          # number of reports kept in reports/
NOTIFY_LEVEL=critical    # critical | warning | none
DISK_WARN=85             # % used on a filesystem that triggers a WARNING
DISK_CRIT=95             # % used that triggers a CRITICAL
APT_LISTS_MAX_AGE=7      # days before APT package lists are considered stale
OLD_KERNELS_WARN=3       # installed kernel images above which to report
SNAP_REFRESH_MAX_AGE=14  # days without a snap refresh before it is reported
BATTERY_HEALTH_WARN=60   # % of the design capacity below which a battery is reported
BACKUP_MAX_AGE=30        # days since the last backup of a scheduled backup tool
ALLOWED_PORTS=""         # listening ports considered expected, e.g. "22/tcp"
IGNORE_CHECKS=""         # finding IDs to silence, e.g. "SEC-DISK-ENC"
IGNORE_PACKAGES=""       # packages to leave out of the obsolete-package list
JOBS_ALLOW=""            # fingerprints of known-good scheduled/startup jobs (see report)
MAX_EVIDENCE_LINES=40    # truncation of raw command output in the report
CMD_TIMEOUT=30           # seconds before a single command is abandoned
REPORT_LANG=auto         # auto (computer's locale) | two-letter code (en, fr...)

QUIET=0
BRIEF=0
LANG_OPT=""
SANITIZE=0
PRINT_REPORT=0
NO_NOTIFY=0
USE_COLOR=1
DATA_DIR=""
CONFIG_FILE=""
FINGERPRINT_ONLY=0
ACCEPT_JOBS=0
ACCEPT_FPS=()
ALIAS_ACTION=""
ALIAS_NAME="uhc"
TIMER_ACTION=""          # install | remove | status
TIMER_SCOPE=""           # user | root
TIMER_FREQ=""            # daily | weekly | monthly
ASSUME_YES=0
INDICATOR_ACTION=""      # install | remove
# Original command line, reused when the installation wizard hands over to
# the root-owned copy.
ORIG_ARGS=("$@")
IGNORED_FOUND=()

die() { echo "uhc: $*" >&2; exit 3; }

usage() {
    cat <<EOF
ubuntu-health-check ${UHC_VERSION} — read-only maintenance audit for Ubuntu

Usage: $(basename "$0") [options]

Options:
  -q, --quiet          No terminal output (for cron / timers)
      --brief          Terminal: one line per finding, without the action plan
      --lang CODE      Language of the report and terminal output, as a
                       two-letter code (en, fr...). Default: REPORT_LANG in
                       uhc.conf, else the computer's locale, else English
  -s, --sanitize       Mask hostname, user name, IP/MAC addresses, SSH key and
                       container names in the saved report (for sharing it)
  -p, --print          Also print the report to stdout (e.g. to pipe it)
  -d, --data-dir DIR   Where reports/ and logs/ are written
                       (default: the tool directory)
  -c, --config FILE    Configuration file (default: DATA_DIR/uhc.conf)
      --no-notify      Never send a desktop notification
      --no-color       Disable colours in the terminal output
      --accept-jobs [FINGERPRINT...]
                       Accept new or changed scheduled/startup jobs into the
                       reference list: the given fingerprints only, or, in a
                       terminal without fingerprints, the list shown on screen
                       after confirmation
      --install-aliases [NAME]
                       Add NAME, NAME-root and NAME-last aliases to
                       ~/.bash_aliases (default NAME: uhc), after confirmation
      --remove-aliases Remove those aliases
      --install-timer [user|root] [daily|weekly|monthly]
                       Schedule the audit with a systemd timer, after
                       confirmation (default: user monthly). Run it again to
                       change the frequency.
                         user: your own user units, unprivileged audit of this
                               folder (run without sudo)
                         root: system units running the full audit from the
                               root-owned copy, reports in --data-dir (run as
                               sudo ${ROOT_INSTALL_DIR}/uhc.sh --data-dir DIR ...)
      --remove-timer [user|root]
                       Disable and remove that timer (default: user)
      --timer-status   Print two lines, user=STATE and root=STATE, where STATE
                       is none, daily, weekly, monthly or custom (a timer not
                       written by this tool, or edited since)
  -y, --yes            With --install-timer user or --remove-timer user only:
                       no question (for programs; never for root)
      --install-indicator
                       Desktop only (optional): an icon in the top bar showing
                       the state of the last audit, started at each login
                       (writes ~/.config/autostart/uhc-indicator.desktop),
                       after confirmation; needs python3-gi and
                       gir1.2-ayatanaappindicator3-0.1 (run without sudo)
      --remove-indicator
                       Remove that autostart entry
      --fingerprint    Print the SHA-256 fingerprint of the code and exit
                       (compare a root copy with its source)
  -h, --help           Show this help
  -V, --version        Show the version

Run without privileges for a routine check. For a full audit with sudo, the
code must be owned by root (see README, "Full audit with sudo").

Exit codes: 0 = nothing to report, 1 = warnings, 2 = critical findings,
            3 = usage, safety or internal error.
EOF
}

# ---- options -----------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        -q|--quiet)    QUIET=1 ;;
        --brief)       BRIEF=1 ;;
        --lang)
            [[ "${2:-}" =~ ^[a-z]{2}$ ]] || die "$1 needs a two-letter lowercase language code, e.g. en or fr"
            LANG_OPT="$2"; shift ;;
        -s|--sanitize) SANITIZE=1 ;;
        -p|--print)    PRINT_REPORT=1 ;;
        -d|--data-dir) [[ -n "${2:-}" ]] || die "$1 needs a directory"; DATA_DIR="$2"; shift ;;
        -c|--config)   [[ -n "${2:-}" ]] || die "$1 needs a file"; CONFIG_FILE="$2"; shift ;;
        --no-notify)   NO_NOTIFY=1 ;;
        --no-color)    USE_COLOR=0 ;;
        -h|--help)     usage; exit 0 ;;
        -V|--version)  echo "ubuntu-health-check ${UHC_VERSION}"; exit 0 ;;
        --fingerprint) FINGERPRINT_ONLY=1 ;;
        --accept-jobs)
            # Optional fingerprints to accept (12 hex digits each).
            ACCEPT_JOBS=1
            while [[ "${2:-}" =~ ^[0-9a-f]{12}$ ]]; do ACCEPT_FPS+=("$2"); shift; done ;;
        --install-aliases)
            ALIAS_ACTION=install
            if [[ -n "${2:-}" && "${2:0:1}" != - ]]; then ALIAS_NAME="$2"; shift; fi ;;
        --remove-aliases) ALIAS_ACTION=remove ;;
        --install-timer|--remove-timer)
            # Optional scope and (install only) frequency, in either order,
            # each checked against a closed list.
            [[ -z "$TIMER_ACTION" ]] || die "only one timer action at a time"
            timer_opt="$1"; TIMER_ACTION="${1#--}"; TIMER_ACTION="${TIMER_ACTION%-timer}"
            while [[ -n "${2:-}" && "${2:0:1}" != - ]]; do
                case "$2" in
                    user|root)
                        [[ -z "$TIMER_SCOPE" ]] || die "$timer_opt: give user or root once"
                        TIMER_SCOPE="$2" ;;
                    daily|weekly|monthly)
                        [[ "$timer_opt" == --install-timer ]] || die "$timer_opt takes no frequency"
                        [[ -z "$TIMER_FREQ" ]] || die "$timer_opt: give the frequency once"
                        TIMER_FREQ="$2" ;;
                    *)  if [[ "$timer_opt" == --install-timer ]]; then
                            die "$timer_opt: invalid argument (expected user or root, and daily, weekly or monthly)"
                        fi
                        die "$timer_opt: invalid argument (expected user or root)" ;;
                esac
                shift
            done ;;
        --timer-status) [[ -z "$TIMER_ACTION" ]] || die "only one timer action at a time"; TIMER_ACTION=status ;;
        -y|--yes)      ASSUME_YES=1 ;;
        --install-indicator|--remove-indicator)
            [[ -z "$INDICATOR_ACTION" ]] || die "only one indicator action at a time"
            INDICATOR_ACTION="${1#--}"; INDICATOR_ACTION="${INDICATOR_ACTION%-indicator}" ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done
if [[ -n "$INDICATOR_ACTION" ]]; then
    [[ -z "$TIMER_ACTION" && -z "$ALIAS_ACTION" ]] || die "indicator, timer and alias options cannot be combined"
fi
if [[ -n "$TIMER_ACTION" ]]; then
    [[ -z "$ALIAS_ACTION" ]] || die "timer and alias options cannot be combined"
    TIMER_SCOPE="${TIMER_SCOPE:-user}"; TIMER_FREQ="${TIMER_FREQ:-monthly}"
fi
# --yes is for a program changing the user timer (e.g. from a menu): those
# units belong to the user's own account and run the audit unprivileged.
# Root actions always need a human in a terminal, as the installation wizard.
if [[ "$ASSUME_YES" == 1 ]]; then
    [[ ( "$TIMER_ACTION" == install || "$TIMER_ACTION" == remove ) && "$TIMER_SCOPE" == user ]] \
        || die "--yes only applies to --install-timer user and --remove-timer user"
fi

# ---- code fingerprint -------------------------------------------------------------
# fingerprint_of DIR — SHA-256 over uhc.sh, every module and every language
# catalog of the copy in DIR, in a fixed order (16 hex digits). Shown in each
# report and log line, so a root copy can be compared with its source. Defined
# here (not in lib/) so that nothing else is loaded before the root safety
# check. Catalogs are included: they are not code, but they write the commands
# proposed to the reader.
fingerprint_of() {
    (cd "$1" && { printf '%s\n' uhc.sh; find lib -type f \( -name '*.sh' -o -name '*.lang' \) | LC_ALL=C sort; } \
        | while IFS= read -r f; do printf '%s\n' "$f"; sha256sum <"$f"; done | sha256sum | cut -c1-16)
}
CODE_FINGERPRINT="$(fingerprint_of "$UHC_DIR")"
if [[ "$FINGERPRINT_ONLY" == 1 ]]; then
    echo "ubuntu-health-check ${UHC_VERSION} code fingerprint: ${CODE_FINGERPRINT}"
    exit 0
fi

# ---- privileges and audited user ----------------------------------------------
# When run with sudo, home-directory checks target the invoking user.
IS_ROOT=0
[[ "$(id -u)" == 0 ]] && IS_ROOT=1
TARGET_USER="$(id -un)"
# SUDO_USER is only meaningful (and only trusted) in a root run started by sudo.
[[ "$IS_ROOT" == 1 && -n "${SUDO_USER:-}" ]] && TARGET_USER="$SUDO_USER"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_HOME="${TARGET_HOME:-$HOME}"

# ---- safety check for root runs -----------------------------------------------
# Every file of the tool, and every directory from the tool directory up to /,
# must be owned by root and not writable by group or others. Symlinks inside
# lib/ are refused. This is what makes 'sudo ./uhc.sh' safe to run.
# untrusted_paths PATH... — print every given path (and every parent directory
# of the given directories, up to /) that is a symlink, not owned by root, or
# writable by group or others. Empty output means the whole chain is trusted.
untrusted_paths() {
    local p uid mode d
    while IFS= read -r p; do
        if [[ -L "$p" ]]; then printf '%s (symlink)\n' "$p"; continue; fi
        read -r uid mode < <(stat -c '%u %a' "$p")
        if [[ "$uid" != 0 ]] || (( (8#$mode & 8#022) != 0 )); then
            printf '%s (%s)\n' "$p" "$(stat -c '%U %A' "$p")"
        fi
    done < <(
        for p in "$@"; do
            find "$p" 2>/dev/null
            d="$(dirname "$p")"
            while :; do printf '%s\n' "$d"; [[ "$d" == / ]] && break; d="$(dirname "$d")"; done
        done | sort -u
    )
}

# check_code_trust — as root, the code must be root-owned and writable by root
# only; otherwise the installation wizard offers to install (or update) the
# root-owned copy and hands over to it. Without a terminal, it refuses.
check_code_trust() {
    [[ -z "$(untrusted_paths "${UHC_DIR}/uhc.sh" "${UHC_DIR}/lib")" ]] && return 0
    # From here on, this is the one-shot installation path: the code of this
    # (user-owned) folder is running as root, by definition. It only installs
    # or updates the root copy; it never runs an audit.
    # shellcheck source=lib/common.sh
    source "${UHC_DIR}/lib/common.sh"
    # shellcheck source=lib/install.sh
    source "${UHC_DIR}/lib/install.sh"
    root_install_wizard
}
# ---- timers: who may install them (decided before the trust check) ------------
# Only exits, loads nothing: the user timer is never written as root, and the
# root timer only by the root-owned copy itself, run as root. Any other copy
# run as root would go through check_code_trust (installation wizard), which
# must stay the only thing a user-owned copy does as root.
if [[ "$TIMER_ACTION" == install || "$TIMER_ACTION" == remove ]]; then
    [[ "$TIMER_SCOPE" == user && "$IS_ROOT" == 1 ]] \
        && die "--${TIMER_ACTION}-timer user manages your own systemd user units: run it without sudo"
    if [[ "$TIMER_SCOPE" == root && ( "$IS_ROOT" != 1 || "$UHC_DIR" != "$ROOT_INSTALL_DIR" ) ]]; then
        timer_dd="${DATA_DIR:-$UHC_DIR}"
        timer_dd="$(cd -- "$timer_dd" 2>/dev/null && pwd -P || printf '%s' "$timer_dd")"
        timer_cmd="sudo ${ROOT_INSTALL_DIR}/uhc.sh --data-dir $(printf '%q' "$timer_dd") --${TIMER_ACTION}-timer root"
        [[ "$TIMER_ACTION" == install ]] && timer_cmd+=" ${TIMER_FREQ}"
        timer_msg="the root timer is managed by the root-owned copy, run as root:
  ${timer_cmd}"
        [[ -f "${ROOT_INSTALL_DIR}/uhc.sh" ]] || timer_msg+="
The root-owned copy is not installed yet; install it first with: sudo $(printf '%q' "${UHC_DIR}/uhc.sh")"
        die "$timer_msg"
    fi
fi

# ---- top-bar icon: never as root (decided before the trust check) ------------------
# It belongs to the user's desktop session; only exits, loads nothing.
[[ -n "$INDICATOR_ACTION" && "$IS_ROOT" == 1 ]] \
    && die "--${INDICATOR_ACTION}-indicator belongs to your desktop session: run it without sudo"

[[ "$IS_ROOT" == 1 ]] && check_code_trust

# ---- libraries (loaded only once the code is trusted, or when unprivileged) -------------
# shellcheck source=lib/common.sh
source "${UHC_DIR}/lib/common.sh"
# shellcheck source=lib/report.sh
source "${UHC_DIR}/lib/report.sh"
# shellcheck source=lib/install.sh
source "${UHC_DIR}/lib/install.sh"

# ---- data directory ------------------------------------------------------------
DATA_DIR="${DATA_DIR:-$UHC_DIR}"
[[ -d "$DATA_DIR" ]] || die "data directory does not exist: $DATA_DIR"
DATA_DIR="$(cd "$DATA_DIR" && pwd -P)"
DATA_OWNER="$(stat -c '%U' "$DATA_DIR")"
# A root-owned data directory is written as root: it and all its parents must
# be root-owned and not writable by others, or a user could swap a parent
# directory during the run and redirect root's writes.
if [[ "$IS_ROOT" == 1 && "$DATA_OWNER" == root ]]; then
    bad="$(untrusted_paths "$DATA_DIR" | head -n 5)"
    [[ -z "$bad" ]] || die "root-owned data directory in an untrusted location, refusing to write there as root:
$bad
Use a data directory you own (it is then written with your privileges)."
fi
REPORT_DIR="${DATA_DIR}/reports"
LOG_DIR="${DATA_DIR}/logs"
CONFIG_FILE="${CONFIG_FILE:-${DATA_DIR}/uhc.conf}"

init_colors

# ---- configuration -----------------------------------------------------------
# The config file is parsed, never sourced, and every value is validated
# against a strict pattern before use. This matters because numeric values end
# up in Bash arithmetic, where an unvalidated value such as 'x[$(cmd)]' would
# execute a command. Invalid values are reported and the default is kept.
# The file is read with the data owner's privileges.
load_config() {
    local file="$1" key value content pattern
    [[ -f "$file" ]] || return 0
    content="$(as_data_owner cat -- "$file" 2>/dev/null)" || { echo "uhc: cannot read $file" >&2; return 0; }
    while IFS='=' read -r key value; do
        key="${key//[[:space:]]/}"
        [[ -z "$key" || "$key" == \#* ]] && continue
        value="${value%%#*}"                              # strip trailing comment
        value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/')"
        case "$key" in
            # No leading zero: Bash would read "08" as an invalid octal number.
            KEEP_REPORTS|DISK_WARN|DISK_CRIT|APT_LISTS_MAX_AGE|OLD_KERNELS_WARN|SNAP_REFRESH_MAX_AGE|BATTERY_HEALTH_WARN|BACKUP_MAX_AGE|MAX_EVIDENCE_LINES|CMD_TIMEOUT)
                pattern='^(0|[1-9][0-9]{0,4})$' ;;
            NOTIFY_LEVEL)    pattern='^(critical|warning|none)$' ;;
            ALLOWED_PORTS)   pattern='^([0-9]{1,5}/(tcp|udp)( +|$))*$' ;;
            IGNORE_CHECKS)   pattern='^([A-Z0-9-]+( +|$))*$' ;;
            JOBS_ALLOW)      pattern='^([0-9a-f]{12}( +|$))*$' ;;
            IGNORE_PACKAGES) pattern='^([a-z0-9][a-z0-9.+-]*(:[a-z0-9]+)?( +|$))*$' ;;
            REPORT_LANG)     pattern='^(auto|[a-z]{2})$' ;;
            *) echo "uhc: ignoring unknown config key '$(clean_line "$key")' in $file" >&2; continue ;;
        esac
        if [[ "$value" =~ $pattern ]]; then
            printf -v "$key" '%s' "$value"
        else
            echo "uhc: invalid value for $key in $file, keeping default" >&2
        fi
    done <<<"$content"
    # Renamed check IDs keep working in IGNORE_CHECKS (IDs are otherwise stable).
    if [[ " ${IGNORE_CHECKS} " == *" SVC-CRON-SUSPECT "* ]]; then
        IGNORE_CHECKS+=" SVC-PERSISTENCE"
        echo "uhc: SVC-CRON-SUSPECT is now SVC-PERSISTENCE (since 2.2.0); please update IGNORE_CHECKS in $file" >&2
    fi
    # Range checks (values are known to be plain decimal numbers here).
    (( DISK_WARN <= 100 && DISK_CRIT <= 100 && DISK_CRIT >= DISK_WARN )) \
        || { echo "uhc: invalid disk thresholds, using defaults" >&2; DISK_WARN=85; DISK_CRIT=95; }
    (( KEEP_REPORTS >= 1 )) || { echo "uhc: KEEP_REPORTS must be at least 1, using 1" >&2; KEEP_REPORTS=1; }
    (( MAX_EVIDENCE_LINES >= 1 )) || MAX_EVIDENCE_LINES=40
    (( CMD_TIMEOUT >= 1 )) || CMD_TIMEOUT=30
    (( SNAP_REFRESH_MAX_AGE >= 1 )) || { echo "uhc: SNAP_REFRESH_MAX_AGE must be at least 1, using 14" >&2; SNAP_REFRESH_MAX_AGE=14; }
    (( BATTERY_HEALTH_WARN >= 1 && BATTERY_HEALTH_WARN <= 100 )) || { echo "uhc: BATTERY_HEALTH_WARN must be between 1 and 100, using 60" >&2; BATTERY_HEALTH_WARN=60; }
    (( BACKUP_MAX_AGE >= 1 )) || { echo "uhc: BACKUP_MAX_AGE must be at least 1, using 30" >&2; BACKUP_MAX_AGE=30; }
}
load_config "$CONFIG_FILE"

# ---- language ----------------------------------------------------------------------
# --lang, then REPORT_LANG from uhc.conf, then the computer's locale (read at
# the top of this script), then English. Every candidate is a validated
# two-letter code; load_lang falls back to English when lib/lang/ has no
# folder for it. Messages printed before this point stay in English.
if [[ -n "$LANG_OPT" ]]; then
    UHC_LANG_CODE="$LANG_OPT"
elif [[ "$REPORT_LANG" != auto ]]; then
    UHC_LANG_CODE="$REPORT_LANG"
else
    UHC_LANG_CODE="${UHC_LOCALE_LANG:-en}"
fi
load_lang "$UHC_LANG_CODE"

# ---- alias management (no audit) --------------------------------------------------
[[ "$ALIAS_ACTION" == install ]] && install_aliases "$ALIAS_NAME"
[[ "$ALIAS_ACTION" == remove ]] && remove_aliases

# ---- scheduled audits (no audit) --------------------------------------------------
case "$TIMER_ACTION" in
    install) install_timer "$TIMER_SCOPE" "$TIMER_FREQ" ;;
    remove)  remove_timer "$TIMER_SCOPE" ;;
    status)  timer_status ;;
esac

# ---- top-bar icon (no audit) --------------------------------------------------------
case "$INDICATOR_ACTION" in
    install) install_indicator ;;
    remove)  remove_indicator ;;
esac

# ---- private state -------------------------------------------------------------------
# Reference lists of the persistence check. As root, they live in the
# root-owned installation (written as root, readable by root only), so a
# program running under the user's account can neither erase nor edit them,
# and accepting changes requires sudo. Unprivileged, they live in the data
# directory (and can be edited by the user's account: documented limitation).
if [[ "$IS_ROOT" == 1 ]]; then
    STATE_DIR="${UHC_DIR}/state"
    STATE_AS_ROOT=1
    install -d -o root -g root -m 700 "$STATE_DIR" || die "cannot create $STATE_DIR"
else
    STATE_DIR="$LOG_DIR"
    STATE_AS_ROOT=0
fi

# ---- working files and lock -----------------------------------------------------
as_data_owner mkdir -p "$REPORT_DIR" "$LOG_DIR" || die "cannot create $REPORT_DIR or $LOG_DIR"
as_data_owner chmod 700 "$REPORT_DIR" "$LOG_DIR"

# Prevent two runs at the same time. Root uses a lock in /run (root-only), so
# it never opens a file inside a user-controlled directory.
if [[ "$IS_ROOT" == 1 ]]; then
    exec 9>/run/ubuntu-health-check.lock
else
    exec 9>>"${LOG_DIR}/.lock"
fi
flock -n 9 || die "another run is already in progress"

# Private temporary directory (mode 700, unique name), removed at exit.
WORK_DIR="$(mktemp -d -t uhc.XXXXXXXX)" || die "cannot create a temporary directory"
trap 'rm -rf -- "$WORK_DIR"' EXIT
BODY_FILE="${WORK_DIR}/body.md"
SUMMARY_FILE="${WORK_DIR}/summary.md"
PARTIAL_FILE="${WORK_DIR}/partial.md"
# Records of the action plan (critical, then warning findings).
PLAN_CRIT_FILE="${WORK_DIR}/plan-critical.tsv"
PLAN_WARN_FILE="${WORK_DIR}/plan-warning.tsv"
: >"$BODY_FILE"; : >"$SUMMARY_FILE"; : >"$PARTIAL_FILE"; : >"$PLAN_CRIT_FILE"; : >"$PLAN_WARN_FILE"

# ---- run the checks -----------------------------------------------------------
say "${C_BLD}ubuntu-health-check ${UHC_VERSION}${C_RST} — $(t ui.start)"
if [[ "$IS_ROOT" == 1 ]]; then
    say "$(t ui.run_root user="$TARGET_USER" owner="$DATA_OWNER")"
else
    say "${C_DIM}$(t ui.run_user)${C_RST}"
fi

for module in "${UHC_DIR}"/lib/checks/[0-9][0-9]-*.sh; do
    # shellcheck source=/dev/null
    source "$module"
done

# ---- output ------------------------------------------------------------------
EXIT_CODE=0
(( COUNT_WARNING > 0 )) && EXIT_CODE=1
(( COUNT_CRITICAL > 0 )) && EXIT_CODE=2

# Comparison with the previous audit at this privilege level (report section,
# terminal lines, log counters). The new state is saved only once the report
# is written: a run that stops earlier leaves the previous state in place.
compare_previous
write_report || die "cannot write the report to $REPORT_DIR"
rotate_reports
write_log
save_state
notify

say ""
say "${C_BLD}$(t ui.result)${C_RST} ${C_RED}${COUNT_CRITICAL} critical${C_RST}, ${C_YEL}${COUNT_WARNING} warning${C_RST}, ${COUNT_INFO} info, ${C_GRN}${COUNT_OK} ok${C_RST}, $(t ui.result_partial n="$COUNT_PARTIAL")"
print_compare
say "$(t ui.report_path path="$REPORT_FILE")"
# The action plan, unless the terminal output is off or kept to one line per
# finding (it is in the report either way).
[[ "$QUIET" == 1 || "$BRIEF" == 1 ]] || render_plan term

[[ "$PRINT_REPORT" == 1 ]] && cat "${WORK_DIR}/report.md"
exit "$EXIT_CODE"
