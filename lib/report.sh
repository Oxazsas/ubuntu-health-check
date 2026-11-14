# shellcheck shell=bash
# Backticks in printf formats are literal Markdown, not command substitution.
# shellcheck disable=SC2016
# -----------------------------------------------------------------------------
# lib/report.sh — assemble the Markdown report and the action plan, sanitize
# the report, rotate old reports, append to the run log and send the desktop
# notification.
#
# The report is first assembled in the private temporary directory, then
# copied into the data directory with the data owner's privileges (never as
# root into a user-controlled directory). Reports and the log are mode 600:
# they are a detailed map of the machine.
# -----------------------------------------------------------------------------

# host_context — key facts about the machine, as a Markdown table.
host_context() {
    local os kernel up model battery privileges lists_age
    os="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")"
    kernel="$(uname -r)"
    up="$(uptime -p 2>/dev/null || t ui.unknown)"
    model="$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null | tr '\n' ' ')"
    battery="$(t ui.ctx.battery_no)"
    compgen -G "/sys/class/power_supply/BAT*" >/dev/null && battery="$(t ui.ctx.battery_yes)"
    if [[ "$IS_ROOT" == 1 ]]; then
        privileges="$(t ui.ctx.priv_root)"
    else
        privileges="$(t ui.ctx.priv_user)"
    fi
    if [[ "${APT_LISTS_AGE_DAYS:-unknown}" != unknown ]]; then
        lists_age="$(t ui.ctx.days n="$APT_LISTS_AGE_DAYS")"
    else
        lists_age="$(t ui.unknown)"
    fi

    cat <<EOF
| $(t ui.ctx.field) | $(t ui.ctx.value) |
|---|---|
| $(t ui.ctx.host) | $(hostname) |
| $(t ui.ctx.user) | ${TARGET_USER} |
| $(t ui.ctx.os) | $(clean_line "${os:-$(t ui.unknown)}") |
| $(t ui.ctx.kernel) | ${kernel} |
| $(t ui.ctx.uptime) | ${up} |
| $(t ui.ctx.hardware) | $(clean_line "${model:-$(t ui.unknown)}") |
| $(t ui.ctx.battery) | ${battery} |
| $(t ui.ctx.privileges) | ${privileges} |
| $(t ui.ctx.lists_age) | ${lists_age} |
| $(t ui.ctx.generated) | $(date '+%Y-%m-%d %H:%M:%S %z') |
| $(t ui.ctx.tool) | $(t ui.ctx.tool_value version="$UHC_VERSION" fp="$CODE_FINGERPRINT") |
EOF
}

# ai_notes — guidance block appended at the end of the report, so that the
# report can be pasted as-is into an AI assistant to start a maintenance
# session with the right safety habits.
ai_notes() {
    printf '\n## %s\n\n%s\n\n' "$(t ui.ai.title)" "$(t ui.ai.intro)"
    printf '1. %s\n' "$(t ui.ai.untrusted)"
    printf '2. %s\n' "$(t ui.ai.proposals)"
    printf '3. %s\n' "$(t ui.ai.order)"
    printf '4. %s\n' "$(t ui.ai.simulate)"
    printf '5. %s\n' "$(t ui.ai.explain)"
    printf '6. %s\n' "$(t ui.ai.backup)"
    printf '7. %s\n' "$(t ui.ai.partial)"
    printf '8. %s\n' "$(t ui.ai.reversible)"
}

# ---- action plan ----------------------------------------------------------------
# term_wrap INDENT HANG TEXT [LABEL STYLED] — print TEXT on the terminal (say),
# folded at spaces to fit 80 columns: the first line starts after INDENT, the
# next ones after INDENT and HANG. If TEXT starts with LABEL, the label is
# shown as STYLED on the first line (colour codes are added after folding, so
# that they do not count as columns).
term_wrap() {
    local indent="$1" hang="$2" text="$3" label="${4:-}" styled="${5:-}" line first=1
    while IFS= read -r line; do
        line="${line%"${line##*[! ]}"}"                  # fold -s keeps the space it breaks at
        if (( first )); then
            [[ -n "$label" ]] && line="${line/#"$label"/"$styled"}"
            say "${indent}${line}"
            first=0
        else
            say "${indent}${hang}${line}"
        fi
    done < <(printf '%s\n' "$text" | fold -s -w "$(( 80 - ${#indent} - ${#hang} ))")
}

# render_plan md|term — the critical findings, then the warnings, numbered,
# each with its consequence, proposed actions and precaution, from the
# records written by finding / impact / action / caution (see plan_record).
# md writes the "Action plan" section of the report on stdout; term prints it
# on the terminal, where each command stays alone on its line (never folded),
# ready to be copied. Nothing is printed when there is nothing to act on.
render_plan() {
    local mode="$1" file line type rest a b sev icon color n=0 nact=0 label
    [[ -s "$PLAN_CRIT_FILE" || -s "$PLAN_WARN_FILE" ]] || return 0
    if [[ "$mode" == md ]]; then
        printf '\n## %s\n\n%s\n' "$(t ui.plan.title)" "$(t ui.plan.intro)"
    else
        say ""
        say "${C_BLD}$(t ui.plan.title)${C_RST} ($(t ui.actions_note))"
    fi
    for file in "$PLAN_CRIT_FILE" "$PLAN_WARN_FILE"; do
        if [[ "$file" == "$PLAN_CRIT_FILE" ]]; then
            sev=CRITICAL; icon="🔴"; color="$C_RED"
        else
            sev=WARNING; icon="🟠"; color="$C_YEL"
        fi
        # Records: TYPE, then one or two tab-separated fields (the first one
        # may be empty: an action without a command). Split by hand, because
        # 'read' with IFS=tab would merge consecutive tabs.
        while IFS= read -r line; do
            type="${line%%$'\t'*}"
            rest="${line#*$'\t'}"
            a="${rest%%$'\t'*}"
            b=""
            [[ "$rest" == *$'\t'* ]] && b="${rest#*$'\t'}"
            case "$type" in
                F)
                    n=$((n + 1)); nact=0
                    if [[ "$mode" == md ]]; then
                        printf '\n### %d. %s %s — %s `%s`\n' "$n" "$icon" "$sev" "$b" "$a"
                    else
                        say ""
                        term_wrap "" "   " "${n}. ${sev} — ${b} [${a}]" \
                            "${n}. ${sev}" "${C_BLD}${n}.${C_RST} ${color}${sev}${C_RST}"
                    fi ;;
                I|C)
                    if [[ "$type" == I ]]; then label="$(t ui.impact)"; else label="$(t ui.caution)"; fi
                    if [[ "$mode" == md ]]; then
                        if [[ "$type" == I ]]; then md_impact "$a"; else md_caution "$a"; fi
                    else
                        label+="$(t ui.colon)"
                        term_wrap "   " "  " "${label} ${a}" "$label" "${C_BLD}${label}${C_RST}"
                    fi ;;
                A)
                    nact=$((nact + 1))
                    if [[ "$mode" == md ]]; then
                        (( nact == 1 )) && md_actions_heading
                        md_action "$nact" "$a" "$b"
                    else
                        (( nact == 1 )) && say "   ${C_BLD}$(t ui.actions)$(t ui.colon)${C_RST}"
                        term_wrap "   " "   " "${nact}) ${b}"
                        [[ -n "$a" ]] && say "        ${C_BLD}${a}${C_RST}"
                    fi ;;
            esac
        done <"$file"
    done
}

# ---- comparison with the previous audit -------------------------------------------
# At the end of each complete run, the results are saved by ID in a small state
# file of the data directory, logs/last-audit-<user|root>.state (one per
# privilege level: an unprivileged audit, with its partial checks, is never
# compared with a root audit). The next run at the same level compares its own
# results with it. Format (tab-separated, sorted, nothing else):
#   # ubuntu-health-check state 1
#   version<TAB>2.11.0
#   date<TAB>2026-11-14T09:30:00+0100
#   privileges<TAB>user
#   SEVERITY<TAB>ID<TAB>COUNT      highest severity of the ID, and how many
#                                  times it was reported at that severity
#   PARTIAL<TAB>ID<TAB>1           partial (skipped) check
# No title, host, user, package or other name: the file holds nothing that
# --sanitize would mask. It is read as data, never sourced: every line must
# match one of the patterns below, or the whole file is set aside (treated as
# a first audit). Results silenced by IGNORE_CHECKS are not recorded as such;
# an ID that is silenced today, or not reported because its check was partial
# today, keeps its previous result (carried over), so that the next
# comparison is made with the last time it was actually checked.
STATE_MAGIC="# ubuntu-health-check state 1"
STATE_MAX_BYTES=262144
CMP_NEW="-" CMP_WORSE="-" CMP_RESOLVED="-"
CMP_TERM=()
declare -A PREV_SEV=() PREV_N=() PREV_PARTIAL=() CARRY=()
PREV_VERSION="" PREV_DATE=""

# priv_word — "root" or "user", as in the state file name and the log line.
priv_word() { if [[ "$IS_ROOT" == 1 ]]; then echo root; else echo user; fi; }

# read_state FILE — load the previous state into PREV_* (parse_state does
# the reading; on failure, PREV_* are emptied again). Returns 0 when it is
# usable, 1 when there is none, 2 when it cannot be used (unreadable, not a
# regular file, too large, corrupted, other format or privilege level).
# Read with the data owner's privileges; NUL bytes are turned into a byte
# that no pattern accepts.
parse_state() {
    local file="$1" content rc line kind id cnt n=0 seen_v=0 seen_d=0 seen_p=0
    local id_re='^[A-Z][A-Z0-9]*(-[A-Z0-9]+)*$'
    local res_re=$'^(CRITICAL|WARNING|INFO|OK|PARTIAL)\t([A-Z][A-Z0-9-]{0,63})\t([1-9][0-9]{0,3})$'
    local ver_re=$'^version\t([0-9]{1,4}(\\.[0-9]{1,4}){1,3}([~+-][A-Za-z0-9.]{1,20})?)$'
    local date_re=$'^date\t([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4})$'
    local priv_re=$'^privileges\t(root|user)$'
    # $1 is expanded by the inner sh, which receives the path as an argument.
    # shellcheck disable=SC2016
    content="$(as_data_owner sh -c '
        [ -e "$1" ] || [ -h "$1" ] || exit 10
        { [ -h "$1" ] || [ ! -f "$1" ]; } && exit 11
        head -c "$2" -- "$1" 2>/dev/null | tr "\000" "\001"' _ "$file" "$STATE_MAX_BYTES")"
    rc=$?
    (( rc == 10 )) && return 1
    (( rc == 0 && ${#content} < STATE_MAX_BYTES )) || return 2
    while IFS= read -r line; do
        n=$((n + 1))
        if (( n == 1 )); then
            [[ "$line" == "$STATE_MAGIC" ]] || return 2
        elif [[ "$line" =~ $res_re ]]; then
            kind="${BASH_REMATCH[1]}" id="${BASH_REMATCH[2]}" cnt="${BASH_REMATCH[3]}"
            [[ "$id" =~ $id_re ]] || return 2
            if [[ "$kind" == PARTIAL ]]; then
                [[ -z "${PREV_PARTIAL[$id]+x}" ]] || return 2
                PREV_PARTIAL[$id]=1
            else
                [[ -z "${PREV_SEV[$id]+x}" ]] || return 2
                PREV_SEV[$id]="$kind"
                PREV_N[$id]="$cnt"
            fi
        elif [[ "$line" =~ $ver_re ]]; then
            (( seen_v++ == 0 )) || return 2
            PREV_VERSION="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ $date_re ]]; then
            (( seen_d++ == 0 )) || return 2
            PREV_DATE="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ $priv_re ]]; then
            (( seen_p++ == 0 )) || return 2
            [[ "${BASH_REMATCH[1]}" == "$(priv_word)" ]] || return 2
        else
            return 2
        fi
    done <<<"$content"
    (( seen_v == 1 && seen_d == 1 && seen_p == 1 )) || return 2
}
read_state() {
    local rc
    parse_state "$1"
    rc=$?
    (( rc == 0 )) || { PREV_SEV=(); PREV_N=(); PREV_PARTIAL=(); PREV_VERSION=""; PREV_DATE=""; }
    return "$rc"
}

# cmp_sev SEVERITY COUNT [FORCE] — "WARNING", or "WARNING ×2" when COUNT is
# above 1 or FORCE is given (same severity on both sides).
cmp_sev() {
    if (( $2 > 1 )) || [[ -n "${3:-}" ]]; then printf '%s ×%d' "$1" "$2"; else printf '%s' "$1"; fi
}

# cmp_list KEY ITEM... — one bullet of the comparison (KEY with {n} and the
# items joined by commas); nothing when there is no item.
cmp_list() {
    local key="$1" out
    shift
    (( $# > 0 )) || return 0
    out="$(printf '%s, ' "$@")"
    printf -- '- %s\n' "$(t "$key" n="$#" items="${out%, }")"
}

# compare_previous — compare this run with the state of the previous audit at
# the same privilege level, write the report section to WORK_DIR/compare.md
# and prepare the terminal lines (CMP_TERM) and the log counters. Rules, by ID
# (highest severity, then number of occurrences at that severity):
#   new       absent before, WARNING or CRITICAL now;
#   worse     severity up to WARNING or CRITICAL, or same WARNING/CRITICAL
#             severity reported more times;
#   improved  WARNING/CRITICAL down to INFO or a lower WARNING/CRITICAL, or
#             reported fewer times at the same severity;
#   resolved  WARNING/CRITICAL before, OK or not reported now.
# Changes that stay between OK and INFO are only counted. IDs silenced by
# IGNORE_CHECKS today are left out; a previous problem that is not reported
# because its check was partial today is "not checked", not resolved. When
# the tool changed version, an ID the previous state did not know at all is a
# check possibly added by the new version, not a new problem.
compare_previous() {
    local rc id o n on nn s_old s_new same vchanged=0 minor=0 d item
    local -a l_new=() l_worse=() l_better=() l_resolved=() l_check=() l_ign=() l_part=() term_ids=()
    CMP_FILE="${WORK_DIR}/compare.md"
    CMP_STATE_FILE="${LOG_DIR}/last-audit-$(priv_word).state"
    read_state "$CMP_STATE_FILE"
    rc=$?
    {
        printf '\n## %s\n\n' "$(t ui.cmp.title)"
        if (( rc == 1 )); then
            if [[ "$IS_ROOT" == 1 ]]; then t ui.cmp.first_root; else t ui.cmp.first_user; fi
            printf '\n'
            CMP_TERM=("${C_DIM}$(t ui.cmp.term_first)${C_RST}")
            return 0
        elif (( rc != 0 )); then
            printf '%s\n' "$(t ui.cmp.unusable)"
            CMP_TERM=("${C_DIM}$(t ui.cmp.term_unusable)${C_RST}")
            return 0
        fi
    } >"$CMP_FILE"

    [[ "$PREV_VERSION" != "$UHC_VERSION" ]] && vchanged=1
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        o="${SEV_RANK[${PREV_SEV[$id]:-none}]:-0}"
        n="${SEV_RANK[${RUN_SEV[$id]:-none}]:-0}"
        on="${PREV_N[$id]:-0}"; nn="${RUN_N[$id]:-0}"
        s_old="${PREV_SEV[$id]:-}"; s_new="${RUN_SEV[$id]:-}"
        if is_ignored "$id"; then
            (( o >= 3 )) && l_ign+=("\`${id}\`")
            (( o > 0 )) && CARRY[$id]=1
            continue
        fi
        if (( o == 0 )); then
            if (( vchanged )) && [[ -z "${PREV_PARTIAL[$id]+x}" ]]; then
                l_check+=("\`${id}\` ($(cmp_sev "$s_new" "$nn"))")
            elif (( n >= 3 )); then
                l_new+=("\`${id}\` $(cmp_sev "$s_new" "$nn")"); term_ids+=("$id")
            else
                minor=$((minor + 1))
            fi
            continue
        fi
        if (( n == 0 )); then
            if [[ -n "${RUN_PARTIAL[$id]+x}" || -n "${RUN_PARTIAL[${id%%-*}-ALL]+x}" ]]; then
                (( o >= 3 )) && l_part+=("\`${id}\`")
                CARRY[$id]=1
            elif (( o >= 3 )); then
                l_resolved+=("\`${id}\` $(cmp_sev "$s_old" "$on") → $(t ui.cmp.absent)")
            else
                minor=$((minor + 1))
            fi
            continue
        fi
        same=""; (( n == o )) && same=1
        item="\`${id}\` $(cmp_sev "$s_old" "$on" "$same") → $(cmp_sev "$s_new" "$nn" "$same")"
        if (( n > o )); then
            if (( n >= 3 )); then l_worse+=("$item"); term_ids+=("$id"); else minor=$((minor + 1)); fi
        elif (( n < o )); then
            if (( o < 3 )); then minor=$((minor + 1))
            elif (( n == 1 )); then l_resolved+=("$item")
            else l_better+=("$item"); fi
        elif (( n >= 3 && nn > on )); then
            l_worse+=("$item"); term_ids+=("$id")
        elif (( n >= 3 && nn < on )); then
            l_better+=("$item")
        fi
    done < <(printf '%s\n' "${!PREV_SEV[@]}" "${!RUN_SEV[@]}" | LC_ALL=C sort -u)

    CMP_NEW=${#l_new[@]}; CMP_WORSE=${#l_worse[@]}; CMP_RESOLVED=${#l_resolved[@]}
    d="${PREV_DATE:0:10} ${PREV_DATE:11:5}"
    {
        if [[ "$IS_ROOT" == 1 ]]; then
            t ui.cmp.intro_root date="$d" version="$PREV_VERSION"
        else
            t ui.cmp.intro_user date="$d" version="$PREV_VERSION"
        fi
        printf '\n'
        (( vchanged )) && printf '\n%s\n' "$(t ui.cmp.version from="$PREV_VERSION" to="$UHC_VERSION")"
        if (( ${#l_new[@]} + ${#l_worse[@]} + ${#l_better[@]} + ${#l_resolved[@]} == 0 )); then
            printf '\n%s\n' "$(t ui.cmp.none)"
        fi
        # lang-keys: ui.cmp.new ui.cmp.worse ui.cmp.better ui.cmp.resolved ui.cmp.checks ui.cmp.ignored ui.cmp.partial
        item="$(cmp_list ui.cmp.new "${l_new[@]}"
                cmp_list ui.cmp.worse "${l_worse[@]}"
                cmp_list ui.cmp.better "${l_better[@]}"
                cmp_list ui.cmp.resolved "${l_resolved[@]}"
                cmp_list ui.cmp.checks "${l_check[@]}"
                cmp_list ui.cmp.ignored "${l_ign[@]}"
                cmp_list ui.cmp.partial "${l_part[@]}"
                (( minor > 0 )) && printf -- '- %s\n' "$(t ui.cmp.minor n="$minor")")"
        [[ -n "$item" ]] && printf '\n%s\n' "$item"
        (( ${#l_new[@]} + ${#l_worse[@]} + ${#l_better[@]} > 0 )) && printf '\n%s\n' "$(t ui.cmp.details)"
    } >>"$CMP_FILE"

    if (( ${#l_new[@]} + ${#l_worse[@]} + ${#l_better[@]} + ${#l_resolved[@]} == 0 )); then
        item="$(t ui.cmp.term_none date="$d")"
    else
        item="$(t ui.cmp.term_counts date="$d" new="$CMP_NEW" worse="$CMP_WORSE" better="${#l_better[@]}" resolved="$CMP_RESOLVED")"
    fi
    (( vchanged )) && item+=" $(t ui.cmp.term_version from="$PREV_VERSION" to="$UHC_VERSION" n="${#l_check[@]}")"
    CMP_TERM=("$item")
    if (( ${#term_ids[@]} > 0 )); then
        item="$(printf '%s, ' "${term_ids[@]}")"
        CMP_TERM+=("$(t ui.cmp.term_ids ids="${item%, }")")
    fi
}

# print_compare — the comparison on the terminal: one or two lines, one with
# --brief, none with --quiet (say).
print_compare() {
    (( ${#CMP_TERM[@]} > 0 )) || return 0
    if [[ "$BRIEF" == 1 ]]; then say "${CMP_TERM[0]}"; return 0; fi
    local line
    for line in "${CMP_TERM[@]}"; do say "$line"; done
}

# save_state — replace the state file with the results of this run, with the
# data owner's privileges: written to a new private file of logs/ (mktemp,
# never an existing path), then renamed over the old one (mv -T replaces a
# symlink instead of following it, and refuses a directory).
save_state() {
    local id cnt
    {
        printf '%s\n' "$STATE_MAGIC"
        printf 'version\t%s\n' "$UHC_VERSION"
        printf 'date\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
        printf 'privileges\t%s\n' "$(priv_word)"
        {
            for id in "${!RUN_SEV[@]}"; do
                [[ "$id" =~ ^[A-Z][A-Z0-9]*(-[A-Z0-9]+)*$ && ${#id} -le 64 ]] || continue
                cnt="${RUN_N[$id]}"; (( cnt > 9999 )) && cnt=9999
                printf '%s\t%s\t%d\n' "${RUN_SEV[$id]}" "$id" "$cnt"
            done
            # Carried over (already validated when the previous state was read).
            for id in "${!CARRY[@]}"; do
                [[ -z "${RUN_SEV[$id]+x}" ]] && printf '%s\t%s\t%d\n' "${PREV_SEV[$id]}" "$id" "${PREV_N[$id]}"
            done
        } | LC_ALL=C sort -t$'\t' -k2,2
        for id in "${!RUN_PARTIAL[@]}"; do
            [[ "$id" =~ ^[A-Z][A-Z0-9]*(-[A-Z0-9]+)*$ && ${#id} -le 64 ]] || continue
            printf 'PARTIAL\t%s\t1\n' "$id"
        done | LC_ALL=C sort
    } | as_data_owner sh -c '
        exec 2>/dev/null; umask 077
        tmp="$(mktemp "$1.XXXXXX")" || exit 1
        if cat > "$tmp" && mv -fT -- "$tmp" "$1"; then exit 0; fi
        rm -f -- "$tmp"; exit 1' _ "$CMP_STATE_FILE" \
        || echo "uhc: cannot write the state file $CMP_STATE_FILE (check it is a regular file you own)" >&2
}

# sanitize — mask identifying data (hostname, user name, IP and MAC addresses)
# so the report can be shared. Loopback and wildcard addresses are kept
# because they carry meaning (local-only vs exposed). SSH key and container
# names are masked at the source by mask_name().
sanitize() {
    HOST_RE="$(hostname)" USER_RE="${TARGET_USER}" perl -pe '
        BEGIN { $h = quotemeta($ENV{HOST_RE}); $u = quotemeta($ENV{USER_RE}); }
        s/\b$h\b/<hostname>/g if length $h;
        s/\b$u\b/<user>/g     if length $u && $ENV{USER_RE} ne "root";
        # MAC addresses
        s/\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b/<mac>/gi;
        # IPv4, except loopback (127.x) and wildcard (0.0.0.0)
        s/\b(?!127\.)(?!0\.0\.0\.0\b)(?:\d{1,3}\.){3}\d{1,3}\b/<ipv4>/g;
        # Global unicast IPv6 (2000::/3)
        s/\b[23][0-9a-f]{3}:[0-9a-f:]{2,}[0-9a-f]\b/<ipv6>/gi;
    '
}

# log_line TEXT — append one line to the run log (as the data owner), keeping
# the log to its last 1000 lines.
log_line() {
    printf '%s\n' "$1" | as_data_owner sh -c '
        exec 2>/dev/null; umask 077
        cat >> "$1" || exit 1
        if [ "$(wc -l < "$1")" -gt 1000 ]; then
            tail -n 1000 "$1" > "$1.tmp" && mv -f "$1.tmp" "$1"
        fi' _ "${LOG_DIR}/uhc.log" \
        || echo "uhc: cannot write the log ${LOG_DIR}/uhc.log (check it is a regular file you own)" >&2
}

# write_report — assemble all parts, then copy into the data directory.
write_report() {
    local stamp host_tag assembled="${WORK_DIR}/report.md"
    stamp="$(date '+%Y%m%d-%H%M%S')"
    host_tag="$(hostname)"
    [[ "$SANITIZE" == 1 ]] && host_tag="host"
    REPORT_FILE="${REPORT_DIR}/uhc-${stamp}-${host_tag}.md"

    {
        printf '# %s\n\n' "$(t ui.title)"
        printf '> %s\n' "$(t ui.header.readonly)"
        printf '> %s\n\n' "$(t ui.header.untrusted)"
        host_context
        printf '\n## %s\n\n' "$(t ui.summary)"
        printf '| %s | %s |\n|---|---|\n' "$(t ui.sum.severity)" "$(t ui.sum.count)"
        printf '| 🔴 CRITICAL | %d |\n| 🟠 WARNING | %d |\n' "$COUNT_CRITICAL" "$COUNT_WARNING"
        printf '| 🔵 INFO | %d |\n| 🟢 OK | %d |\n' "$COUNT_INFO" "$COUNT_OK"
        printf '| ⚪ %s | %d |\n' "$(t ui.sum.partial)" "$COUNT_PARTIAL"
        if [[ -s "$SUMMARY_FILE" ]]; then
            printf '\n### %s\n\n' "$(t ui.sum.attention)"
            printf '| %s | ID | %s | %s |\n|---|---|---|---|\n' \
                "$(t ui.sum.severity)" "$(t ui.sum.section)" "$(t ui.sum.finding)"
            cat "$SUMMARY_FILE"
        else
            printf '\n%s\n' "$(t ui.sum.none)"
        fi
        if (( ${#IGNORED_FOUND[@]} > 0 )); then
            printf '\n%s\n' "$(t ui.sum.silenced ids="${IGNORED_FOUND[*]}")"
        fi
        [[ -s "${CMP_FILE:-}" ]] && cat "$CMP_FILE"
        render_plan md
        cat "$BODY_FILE"
        if [[ -s "$PARTIAL_FILE" ]]; then
            printf '\n## %s\n\n' "$(t ui.partial.title)"
            printf '%s\n\n' "$(t ui.partial.intro)"
            cat "$PARTIAL_FILE"
        fi
        ai_notes
    } | if [[ "$SANITIZE" == 1 ]]; then sanitize; else cat; fi >"$assembled"

    # Copy with the owner's privileges; set -C refuses to overwrite a file.
    as_data_owner sh -c 'umask 077; set -C; cat > "$1"' _ "$REPORT_FILE" <"$assembled"
}

# rotate_reports — keep only the KEEP_REPORTS most recent reports.
# Only files matching the tool's naming pattern in reports/ are deleted,
# with the data owner's privileges.
rotate_reports() {
    as_data_owner sh -c '
        find "$1" -maxdepth 1 -type f -name "uhc-*.md" -printf "%T@ %p\n" \
            | sort -rn | tail -n +"$(( $2 + 1 ))" | cut -d" " -f2- \
            | while IFS= read -r f; do rm -f -- "$f"; done' _ "$REPORT_DIR" "$KEEP_REPORTS"
}

# write_log — one line per run. The comparison counters come last (fields
# are only ever added at the end, for programs that read this line); they are
# "-" when there was no usable previous state at this privilege level.
write_log() {
    log_line "$(date '+%Y-%m-%dT%H:%M:%S%z') exit=${EXIT_CODE} critical=${COUNT_CRITICAL} warning=${COUNT_WARNING} info=${COUNT_INFO} ok=${COUNT_OK} partial=${COUNT_PARTIAL} privileges=$(priv_word) code=${CODE_FINGERPRINT} report=reports/${REPORT_FILE##*/} new=${CMP_NEW} worse=${CMP_WORSE} resolved=${CMP_RESOLVED}"
}

# notify — desktop notification when the result reaches NOTIFY_LEVEL.
# Works from cron or a systemd user timer by locating the user's session bus.
# Skipped when running as root (the audit is interactive in that case).
notify() {
    local level="${NOTIFY_LEVEL:-critical}" urgency title msg bus
    [[ "$NO_NOTIFY" == 1 || "$level" == none || "$IS_ROOT" == 1 ]] && return 0
    case "$level" in
        critical) (( COUNT_CRITICAL > 0 )) || return 0 ;;
        warning)  (( COUNT_CRITICAL + COUNT_WARNING > 0 )) || return 0 ;;
        *)        return 0 ;;
    esac
    if ! have notify-send; then
        log_line "$(date '+%Y-%m-%dT%H:%M:%S%z') notification not sent: notify-send not installed"
        return 0
    fi
    # cron and some timers start without the session bus address.
    bus="/run/user/$(id -u)/bus"
    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "$bus" ]]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$bus"
    fi
    urgency="normal"
    (( COUNT_CRITICAL > 0 )) && urgency="critical"
    title="$(t ui.notify.title critical="$COUNT_CRITICAL" warning="$COUNT_WARNING")"
    msg="$(t ui.report_path path="$REPORT_FILE")"
    if ! notify-send --urgency="$urgency" --app-name="ubuntu-health-check" \
            --icon=dialog-warning "$title" "$msg" 2>/dev/null; then
        log_line "$(date '+%Y-%m-%dT%H:%M:%S%z') notification not delivered (no graphical session?)"
    fi
}
