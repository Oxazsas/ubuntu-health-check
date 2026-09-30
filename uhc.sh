#!/bin/bash -p
# Settings below are consumed by the sourced check modules.
# shellcheck disable=SC2034
# -----------------------------------------------------------------------------
# ubuntu-health-check (uhc) — read-only maintenance audit for Ubuntu systems
#
# Scans package hygiene, kernel updates, repositories, snaps, services,
# network exposure, Docker and basic security posture, then writes a
# Markdown report designed to be read by a human or handed to an AI
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

UHC_VERSION="2.6.1"

# Public repository used by the root installation wizard (preferred source:
# the code goes straight from the repository to a root-owned folder). Set it in
# the code, not in uhc.conf, which any program running as the user can edit.
# Forks should point it to their own repository. Empty: install from the local
# folder, after confirmation.
UHC_REPO_URL="https://github.com/Oxazsas/ubuntu-health-check.git"
# Root-owned copy used for sudo runs, and its private state (reference lists).
ROOT_INSTALL_DIR="/opt/ubuntu-health-check"

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
        exec /usr/bin/env -i "${clean_env[@]}" /bin/bash -p "$(/usr/bin/readlink -f "${BASH_SOURCE[0]}")" "$@"
    fi
fi

# Parse command output in a predictable language, whatever the user's locale.
export LC_ALL=C.UTF-8 LANG=C.UTF-8

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
ALLOWED_PORTS=""         # listening ports considered expected, e.g. "22/tcp"
IGNORE_CHECKS=""         # finding IDs to silence, e.g. "SEC-DISK-ENC"
IGNORE_PACKAGES=""       # packages to leave out of the obsolete-package list
JOBS_ALLOW=""            # fingerprints of known-good scheduled/startup jobs (see report)
MAX_EVIDENCE_LINES=40    # truncation of raw command output in the report
CMD_TIMEOUT=30           # seconds before a single command is abandoned

QUIET=0
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
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

# ---- code fingerprint -------------------------------------------------------------
# fingerprint_of DIR — SHA-256 over uhc.sh and every module of the copy in DIR,
# in a fixed order (16 hex digits). Shown in each report and log line, so a
# root copy can be compared with its source. Defined here (not in lib/) so
# that nothing else is loaded before the root safety check.
fingerprint_of() {
    (cd "$1" && { printf '%s\n' uhc.sh; find lib -type f -name '*.sh' | LC_ALL=C sort; } \
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
            KEEP_REPORTS|DISK_WARN|DISK_CRIT|APT_LISTS_MAX_AGE|OLD_KERNELS_WARN|MAX_EVIDENCE_LINES|CMD_TIMEOUT)
                pattern='^(0|[1-9][0-9]{0,4})$' ;;
            NOTIFY_LEVEL)    pattern='^(critical|warning|none)$' ;;
            ALLOWED_PORTS)   pattern='^([0-9]{1,5}/(tcp|udp)( +|$))*$' ;;
            IGNORE_CHECKS)   pattern='^([A-Z0-9-]+( +|$))*$' ;;
            JOBS_ALLOW)      pattern='^([0-9a-f]{12}( +|$))*$' ;;
            IGNORE_PACKAGES) pattern='^([a-z0-9][a-z0-9.+-]*(:[a-z0-9]+)?( +|$))*$' ;;
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
}
load_config "$CONFIG_FILE"

# ---- alias management (no audit) --------------------------------------------------
[[ "$ALIAS_ACTION" == install ]] && install_aliases "$ALIAS_NAME"
[[ "$ALIAS_ACTION" == remove ]] && remove_aliases

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
: >"$BODY_FILE"; : >"$SUMMARY_FILE"; : >"$PARTIAL_FILE"

# ---- run the checks -----------------------------------------------------------
say "${C_BLD}ubuntu-health-check ${UHC_VERSION}${C_RST} — read-only audit"
if [[ "$IS_ROOT" == 1 ]]; then
    say "Running as root: full audit (home checks target user '${TARGET_USER}', output written as '${DATA_OWNER}')."
else
    say "${C_DIM}Running unprivileged: some checks will be partial. See README for a full audit with sudo.${C_RST}"
fi

for module in "${UHC_DIR}"/lib/checks/[0-9][0-9]-*.sh; do
    # shellcheck source=/dev/null
    source "$module"
done

# ---- output ------------------------------------------------------------------
EXIT_CODE=0
(( COUNT_WARNING > 0 )) && EXIT_CODE=1
(( COUNT_CRITICAL > 0 )) && EXIT_CODE=2

write_report || die "cannot write the report to $REPORT_DIR"
rotate_reports
write_log
notify

say ""
say "${C_BLD}Result:${C_RST} ${C_RED}${COUNT_CRITICAL} critical${C_RST}, ${C_YEL}${COUNT_WARNING} warning${C_RST}, ${COUNT_INFO} info, ${C_GRN}${COUNT_OK} ok${C_RST}, ${COUNT_PARTIAL} partial"
say "Report: ${REPORT_FILE}"

[[ "$PRINT_REPORT" == 1 ]] && cat "${WORK_DIR}/report.md"
exit "$EXIT_CODE"
