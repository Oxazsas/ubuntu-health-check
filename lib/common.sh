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
#   - finding / impact / action / caution / evidence / partial writers used by
#     every check module, and the records of the action plan
#   - language catalogs (load_lang) and message lookup (t)
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
# The last finding, to which impact / action / caution attach: its severity,
# ID, cleaned title, the plan file it is recorded in (empty for INFO and OK)
# and how many actions it has so far (numbering restarts for each finding).
LAST_FINDING_SEV=""
LAST_FINDING_ID=""
LAST_FINDING_TITLE=""
LAST_PLAN_FILE=""
LAST_ACTION_COUNT=0

# Results of this run by ID, for the comparison with the previous audit (see
# compare_previous in report.sh): the highest severity an ID reached, how
# many times it was reported at that severity, and the IDs of partial checks.
declare -A RUN_SEV=() RUN_N=() RUN_PARTIAL=()

# Messages of the current language, by key (filled by load_lang).
declare -A T=()

# APT options that keep apt-cache / apt list from writing their binary cache
# (/var/cache/apt/*.bin) when run as root: the cache is built in memory only.
APT_RO=(-o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache=
        -o Dir::Log::Planner=/dev/null -o Dir::Log::Solver=/dev/null)

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

# clean_para TEXT — same as clean_line, without the length limit: for the
# explanations and proposed commands of a finding (a command cut short could
# do something else than intended).
clean_para() {
    printf '%s' "$1" | tr '\n\t' '  ' | clean_text
}

# safe_name VALUE FALLBACK — VALUE if it is a plain name (package, snap, unit,
# user...), FALLBACK otherwise (e.g. "<package>"). Use it before inserting a
# name that comes from the system into a proposed command: the reader may
# copy the command into a shell, where quotes, spaces or $(...) in a name
# chosen by someone else would change what it does.
safe_name() {
    if [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9+._@:-]*$ ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

# md_code TEXT — TEXT as Markdown inline code. The fence is made longer than
# any run of backticks inside TEXT, so the text cannot close it early.
md_code() {
    local fence='`'
    while [[ "$1" == *"$fence"* ]]; do fence+='`'; done
    if (( ${#fence} > 1 )); then
        printf '%s %s %s' "$fence" "$1" "$fence"
    else
        printf '`%s`' "$1"
    fi
}

# ---- languages -------------------------------------------------------------------
# Messages live in lib/lang/<code>/*.lang, one 'key=text' per line (the key
# stops at the first '='; empty lines and lines starting with # are ignored).
# Like uhc.conf, these files are read as text, never sourced or evaluated.
# Texts use named variables, {name}, because word order differs between
# languages.

# load_lang CODE — load the English catalog, then lay CODE over it, so that a
# key missing from CODE falls back to English. A language without a folder
# falls back to English silently. CODE is a validated two-letter code, so it
# can only name a folder directly under lib/lang/.
load_lang() {
    local code="$1" dir file line key
    T=()
    for dir in "${UHC_DIR}/lib/lang/en" "${UHC_DIR}/lib/lang/${code}"; do
        [[ -d "$dir" ]] || continue
        for file in "$dir"/*.lang; do
            [[ -f "$file" ]] || continue
            # Builtins only: one 'read' per line, no process per line.
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%$'\r'}"
                [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
                key="${line%%=*}"
                # Keys are plain identifiers (they become array subscripts).
                [[ "$key" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
                T[$key]="${line#*=}"
            done <"$file"
        done
        [[ "$code" == en ]] && break
    done
}

# t KEY [name=value ...] — print the message KEY with each {name} replaced by
# its value; an unknown key prints the key itself, so a missing message is
# visible instead of silently empty.
# The template is scanned once, left to right, and values are inserted as
# they are: a value that itself contains "{other}" is never expanded again.
# Every expansion is quoted, so '&' (special in Bash 5.2+ replacements), '/',
# '\' and glob characters in a value stay literal.
t() {
    local key="$1" msg out="" name kv
    local -A vars=()
    shift
    msg="$key"
    [[ -n "$key" && -n "${T[$key]+x}" ]] && msg="${T[$key]}"
    for kv in "$@"; do
        [[ "$kv" == ?*=* ]] && vars["${kv%%=*}"]="${kv#*=}"
    done
    while [[ "$msg" == *"{"* ]]; do
        out+="${msg%%"{"*}"
        msg="${msg#*"{"}"
        name="${msg%%"}"*}"
        if [[ "$msg" == *"}"* && -n "$name" && -n "${vars[$name]+x}" ]]; then
            out+="${vars[$name]}"
            msg="${msg#*"}"}"
        else
            out+="{"
        fi
    done
    printf '%s' "${out}${msg}"
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
#   EXPLANATION why it matters / what to do (written by the tool, trusted).
#               Modules written for 2.7.0 and later leave it out and call
#               impact / action / caution after the finding instead.
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
    LAST_FINDING_SEV="$sev"
    LAST_FINDING_ID="$id"
    LAST_FINDING_TITLE="$title"
    LAST_ACTION_COUNT=0

    case "$sev" in
        CRITICAL) icon="🔴"; color="$C_RED"; COUNT_CRITICAL=$((COUNT_CRITICAL + 1)) ;;
        WARNING)  icon="🟠"; color="$C_YEL"; COUNT_WARNING=$((COUNT_WARNING + 1)) ;;
        INFO)     icon="🔵"; color="$C_BLU"; COUNT_INFO=$((COUNT_INFO + 1)) ;;
        OK)       icon="🟢"; color="$C_GRN"; COUNT_OK=$((COUNT_OK + 1)) ;;
        *)        icon="❔"; color="" ;;
    esac
    run_record "$sev" "$id"

    {
        printf '\n### %s %s — %s `%s`\n' "$icon" "$sev" "$title" "$id"
        [[ -n "$explanation" ]] && printf '\n%s\n' "$explanation"
    } >>"$BODY_FILE"

    # Critical and warning findings are also listed in the summary table.
    if [[ "$sev" == CRITICAL || "$sev" == WARNING ]]; then
        printf '| %s %s | `%s` | %s | %s |\n' \
            "$icon" "$sev" "$id" "$CURRENT_SECTION" "${title//|/\\|}" >>"$SUMMARY_FILE"
    fi

    # ... and recorded for the action plan. A finding written in the old style
    # (single EXPLANATION) gets it as its consequence, so that the plan stays
    # complete while modules are being migrated.
    LAST_PLAN_FILE=""
    case "$sev" in
        CRITICAL) LAST_PLAN_FILE="${PLAN_CRIT_FILE:-}" ;;
        WARNING)  LAST_PLAN_FILE="${PLAN_WARN_FILE:-}" ;;
    esac
    plan_record F "$id" "$title"
    [[ -n "$explanation" ]] && plan_record I "$explanation"

    say "  ${color}$(printf '%-8s' "$sev")${C_RST} $title ${C_DIM}[$id]${C_RST}"
}

# Order of the severities (used to compare two results of the same ID).
declare -A SEV_RANK=([OK]=1 [INFO]=2 [WARNING]=3 [CRITICAL]=4)

# run_record SEVERITY ID — keep, for each ID, its highest severity in this run
# and the number of times it was reported at that severity (an ID such as
# SYS-DISK is reported once per filesystem). Builtins only: no process.
run_record() {
    local sev="$1" id="$2" r o
    r="${SEV_RANK[${sev:-none}]:-0}"
    (( r > 0 )) || return 0
    o="${SEV_RANK[${RUN_SEV[$id]:-none}]:-0}"
    if (( r > o )); then
        RUN_SEV[$id]="$sev"; RUN_N[$id]=1
    elif (( r == o )); then
        RUN_N[$id]=$(( RUN_N[$id] + 1 ))
    fi
}

# plan_record TYPE FIELD... — append one record to the plan file of the last
# finding (none for INFO and OK): TYPE then the fields, tab-separated, on one
# line. TYPE is F (ID, title), I (consequence), A (command, description) or
# C (precaution). Callers pass text that is already cleaned; tabs and newlines
# are flattened here so that they cannot break the record format.
plan_record() {
    local f line="$1"
    [[ -n "$LAST_PLAN_FILE" ]] || return 0
    shift
    for f in "$@"; do
        f="${f//$'\t'/ }"
        line+=$'\t'"${f//$'\n'/ }"
    done
    printf '%s\n' "$line" >>"$LAST_PLAN_FILE"
}

# Markdown blocks of a finding, shared by the report body and the action plan.
# Texts name placeholders such as <package>: outside code, '<' is escaped so
# that a Markdown renderer does not swallow them as HTML tags.
md_impact()  { printf '\n**%s.** %s\n' "$(t ui.impact)" "${1//</\\<}"; }
md_caution() { printf '\n**%s.** %s\n' "$(t ui.caution)" "${1//</\\<}"; }
md_actions_heading() {
    printf '\n**%s** (%s)%s\n\n' "$(t ui.actions)" "$(t ui.actions_note)" "$(t ui.colon)"
}
# md_action N CMD DESCRIPTION — one numbered action; an empty CMD is advice.
md_action() {
    if [[ -n "$2" ]]; then
        printf '%d. %s — %s\n' "$1" "$(md_code "$2")" "${3//</\\<}"
    else
        printf '%d. %s\n' "$1" "${3//</\\<}"
    fi
}

# impact KEY [name=value ...] — what the last finding means for the user, in
# plain words: what they risk if they do nothing.
# impact, action and caution write nothing when the last finding was silenced
# by IGNORE_CHECKS (like evidence). Their final text is cleaned: the values
# inserted in a message may come from the system.
impact() {
    local text
    [[ "$LAST_FINDING_IGNORED" == 1 ]] && return 0
    text="$(clean_para "$(t "$@")")"
    md_impact "$text" >>"$BODY_FILE"
    plan_record I "$text"
}

# action CMD KEY [name=value ...] — something the user can do about the last
# finding: CMD is a command for them to run themselves (never run by the
# tool), KEY describes what it does and whether it can be undone. An empty
# CMD makes the action a piece of advice without a command. Insert names that
# come from the system into CMD only through safe_name.
action() {
    local cmd desc
    [[ "$LAST_FINDING_IGNORED" == 1 ]] && return 0
    cmd="$(clean_para "$1")"
    shift
    desc="$(clean_para "$(t "$@")")"
    LAST_ACTION_COUNT=$((LAST_ACTION_COUNT + 1))
    {
        (( LAST_ACTION_COUNT == 1 )) && md_actions_heading
        md_action "$LAST_ACTION_COUNT" "$cmd" "$desc"
    } >>"$BODY_FILE"
    plan_record A "$cmd" "$desc"
}

# caution KEY [name=value ...] — what to know before acting: whether it can be
# undone, what to simulate or back up first, whether a reboot follows.
caution() {
    local text
    [[ "$LAST_FINDING_IGNORED" == 1 ]] && return 0
    text="$(clean_para "$(t "$@")")"
    md_caution "$text" >>"$BODY_FILE"
    plan_record C "$text"
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
        printf '\n%s\n\n```text\n' "$(t ui.evidence_raw label="$label")"
        printf '%s\n' "$content" | head -n "$max"
        if (( total > max )); then
            printf '%s\n' "$(t ui.evidence_more n="$((total - max))")"
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
    [[ -n "$id" ]] && RUN_PARTIAL[$id]=1
    printf -- '- `%s` (%s)%s %s\n' "$id" "$CURRENT_SECTION" "$(t ui.colon)" "$what" >>"$PARTIAL_FILE"
    printf '\n> ⚪ %s%s %s `%s`\n' "$(t ui.skipped)" "$(t ui.colon)" "$what" "$id" >>"$BODY_FILE"
    say "  ${C_DIM}SKIPPED  $what [$id]${C_RST}"
}
