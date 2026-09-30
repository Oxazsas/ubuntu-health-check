# shellcheck shell=bash
# Backticks in printf formats are literal Markdown, not command substitution.
# MASKED is set here and read by the check modules.
# shellcheck disable=SC2016,SC2034
# -----------------------------------------------------------------------------
# lib/common.sh — shared helpers for ubuntu-health-check
#
# Provides:
#   - severity levels and counters (CRITICAL / WARNING / INFO / OK)
#   - terminal output (always on stderr, so stdout stays clean for --print)
#   - finding / evidence / partial writers used by every check module
#   - privilege helpers: run a command as the data owner or the audited user
#     when the audit runs as root (so root never writes into, or reads from,
#     locations controlled by an unprivileged user)
#   - sanitisation of untrusted text before it reaches the report
#   - small utilities (command detection, timeouts, package queries)
#
# Nothing here modifies the system.
# -----------------------------------------------------------------------------

# Severity counters (read by report.sh to build the summary and exit code).
COUNT_CRITICAL=0
COUNT_WARNING=0
COUNT_INFO=0
COUNT_OK=0
COUNT_PARTIAL=0

SECTION_INDEX=0
CURRENT_SECTION=""
# Set to 1 when the last finding was silenced by IGNORE_CHECKS, so that the
# evidence attached to it is silenced too.
LAST_FINDING_IGNORED=0

# APT options that keep apt-cache / apt list from writing their binary cache
# (/var/cache/apt/*.bin) when run as root: the cache is built in memory only.
APT_RO=(-o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache=)

# ---- terminal colours --------------------------------------------------------
init_colors() {
    if [[ "${USE_COLOR:-1}" == 1 && -t 2 && -z "${NO_COLOR:-}" ]]; then
        C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_GRN=$'\e[32m'
        C_DIM=$'\e[2m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
    else
        C_RED=""; C_YEL=""; C_BLU=""; C_GRN=""; C_DIM=""; C_BLD=""; C_RST=""
    fi
}

# Print to the terminal (stderr) unless --quiet was given.
say() {
    [[ "${QUIET:-0}" == 1 ]] && return 0
    printf '%s\n' "$*" >&2
}

# ---- untrusted text -------------------------------------------------------------
# Much of what ends up in the report is controlled by other programs or users:
# process names, container names, package descriptions, file names...
# clean_text removes, byte by byte:
#   - C0 control characters except tab and newline, and DEL (ESC starts
#     terminal escape sequences when the report is displayed with cat);
#   - C1 control characters encoded in UTF-8 (U+0080-U+009F; U+009B is a
#     single-character escape sequence introducer for some terminals);
#   - bidirectional override characters (U+202A-U+202E, U+2066-U+2069), which
#     can make text display in a misleading order;
# and it breaks Markdown code fences (inserting U+200B) so that evidence
# cannot escape its code block.
# Removing one sequence can join its neighbours into a new one (for example
# "\xc2" + U+202E + "\x9b" becomes the C1 character "\xc2\x9b"), so the
# removals repeat until the text stops changing.
clean_text() {
    perl -pe '
        my $prev;
        do {
            $prev = $_;
            s/\xe2\x80[\xaa-\xae]|\xe2\x81[\xa6-\xa9]//g;
            s/\xc2[\x80-\x9f]//g;
            s/[\x00-\x08\x0b-\x1f\x7f]//g;
        } while ($_ ne $prev);
        s/```/`\xe2\x80\x8b``/g;
    '
}

# clean_line TEXT — same, for a single value used in a title (length-limited).
clean_line() {
    printf '%s' "$1" | tr '\n\t' '  ' | clean_text | cut -c1-200
}

# mask_name CATEGORY NAME — with --sanitize, replace a user-chosen name that may
# reveal clients or projects (SSH key files, container names) by a stable alias
# such as "ssh-key-2"; without --sanitize, keep NAME. The result is stored in
# the global MASKED (not printed): the alias counter must survive between
# calls, which it would not inside a $(...) subshell.
declare -A MASK_MAP=()
declare -A MASK_COUNT=()
MASKED=""
mask_name() {
    local cat="$1" name="$2"
    if [[ "${SANITIZE:-0}" != 1 ]]; then MASKED="$name"; return; fi
    if [[ -z "${MASK_MAP[$cat/$name]:-}" ]]; then
        MASK_COUNT[$cat]=$(( ${MASK_COUNT[$cat]:-0} + 1 ))
        MASK_MAP[$cat/$name]="${cat}-${MASK_COUNT[$cat]}"
    fi
    MASKED="${MASK_MAP[$cat/$name]}"
}

# ---- privileges ------------------------------------------------------------------
# as_data_owner CMD... — run CMD with the privileges of the owner of the data
# directory (reports/logs). When the audit runs as root and the data directory
# belongs to a regular user, root must not write there itself: a symlink placed
# by that user could redirect the write to a system file.
as_data_owner() {
    if [[ "$IS_ROOT" == 1 && "$DATA_OWNER" != root ]]; then
        runuser -u "$DATA_OWNER" -- "$@"
    else
        "$@"
    fi
}

# as_target CMD... — run CMD as the audited user (for reads inside their home).
as_target() {
    if [[ "$IS_ROOT" == 1 && "$TARGET_USER" != root ]]; then
        runuser -u "$TARGET_USER" -- "$@"
    else
        "$@"
    fi
}

# ---- utilities ---------------------------------------------------------------

# have CMD — true if CMD is available in PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# run CMD [ARGS...] — run a read-only command with a timeout, stderr discarded.
# Returns the command's exit status, so callers can tell "no output" from
# "command failed" (a failed command must never produce an OK finding).
run() { timeout "${CMD_TIMEOUT:-30}" "$@" 2>/dev/null; }

# pkg_installed NAME — true if the Debian package NAME is installed.
pkg_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]
}

# pkg_in_repo NAME — true if at least one configured repository offers NAME.
# (apt-cache madison only lists repository versions, never the local dpkg one.)
pkg_in_repo() {
    [[ -n "$(apt-cache "${APT_RO[@]}" madison "$1" 2>/dev/null)" ]]
}

# is_ignored ID — true if ID is listed in IGNORE_CHECKS (config file).
is_ignored() {
    local id
    for id in ${IGNORE_CHECKS:-}; do
        [[ "$id" == "$1" ]] && return 0
    done
    return 1
}

# ---- report writers ----------------------------------------------------------

# section TITLE — start a new report section (one per check module).
section() {
    SECTION_INDEX=$((SECTION_INDEX + 1))
    CURRENT_SECTION="$1"
    printf '\n## %d. %s\n' "$SECTION_INDEX" "$1" >>"$BODY_FILE"
    say ""
    say "${C_BLD}== $1 ==${C_RST}"
}

# finding SEVERITY ID TITLE [EXPLANATION]
#   SEVERITY    CRITICAL | WARNING | INFO | OK
#   ID          stable identifier (e.g. KRN-META), usable in IGNORE_CHECKS
#   TITLE       one-line statement of what was found (cleaned: it may contain
#               names coming from the system)
#   EXPLANATION why it matters / what to do (written by the tool, trusted)
finding() {
    local sev="$1" id="$2" title explanation="${4:-}"
    local icon color
    title="$(clean_line "$3")"

    if is_ignored "$id"; then
        LAST_FINDING_IGNORED=1
        IGNORED_FOUND+=("$id")
        return 0
    fi
    LAST_FINDING_IGNORED=0

    case "$sev" in
        CRITICAL) icon="🔴"; color="$C_RED"; COUNT_CRITICAL=$((COUNT_CRITICAL + 1)) ;;
        WARNING)  icon="🟠"; color="$C_YEL"; COUNT_WARNING=$((COUNT_WARNING + 1)) ;;
        INFO)     icon="🔵"; color="$C_BLU"; COUNT_INFO=$((COUNT_INFO + 1)) ;;
        OK)       icon="🟢"; color="$C_GRN"; COUNT_OK=$((COUNT_OK + 1)) ;;
        *)        icon="❔"; color="" ;;
    esac

    {
        printf '\n### %s %s — %s `%s`\n' "$icon" "$sev" "$title" "$id"
        [[ -n "$explanation" ]] && printf '\n%s\n' "$explanation"
    } >>"$BODY_FILE"

    # Critical and warning findings are also listed in the summary table.
    if [[ "$sev" == CRITICAL || "$sev" == WARNING ]]; then
        printf '| %s %s | `%s` | %s | %s |\n' \
            "$icon" "$sev" "$id" "$CURRENT_SECTION" "${title//|/\\|}" >>"$SUMMARY_FILE"
    fi

    say "  ${color}$(printf '%-8s' "$sev")${C_RST} $title ${C_DIM}[$id]${C_RST}"
}

# evidence LABEL CONTENT — attach raw command output to the last finding.
# The content is treated as untrusted data: cleaned and fenced.
# Long output is truncated to MAX_EVIDENCE_LINES to keep the report usable.
evidence() {
    local label="$1" content total max="${MAX_EVIDENCE_LINES:-40}"
    [[ "$LAST_FINDING_IGNORED" == 1 || -z "$2" ]] && return 0
    content="$(printf '%s\n' "$2" | clean_text)"
    total=$(printf '%s\n' "$content" | wc -l)
    {
        printf '\n%s (raw system data):\n\n```text\n' "$label"
        printf '%s\n' "$content" | head -n "$max"
        if (( total > max )); then
            printf '... (%d more lines truncated)\n' "$((total - max))"
        fi
        printf '```\n'
    } >>"$BODY_FILE"
}

# partial ID WHAT — record a check that could not run fully (missing tool,
# missing privileges, failed command, non-applicable environment). Shown in the
# section itself and in a dedicated list, so the reader knows the blind spots.
partial() {
    local id="$1" what="$2"
    COUNT_PARTIAL=$((COUNT_PARTIAL + 1))
    printf -- '- `%s` (%s): %s\n' "$id" "$CURRENT_SECTION" "$what" >>"$PARTIAL_FILE"
    printf '\n> ⚪ Skipped: %s `%s`\n' "$what" "$id" >>"$BODY_FILE"
    say "  ${C_DIM}SKIPPED  $what [$id]${C_RST}"
}
