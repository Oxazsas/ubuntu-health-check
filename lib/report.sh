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

# write_log — one line per run.
write_log() {
    log_line "$(date '+%Y-%m-%dT%H:%M:%S%z') exit=${EXIT_CODE} critical=${COUNT_CRITICAL} warning=${COUNT_WARNING} info=${COUNT_INFO} ok=${COUNT_OK} partial=${COUNT_PARTIAL} privileges=$([[ $IS_ROOT == 1 ]] && echo root || echo user) code=${CODE_FINGERPRINT} report=reports/${REPORT_FILE##*/}"
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
