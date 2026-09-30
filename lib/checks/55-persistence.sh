# shellcheck shell=bash
# Source files are passed both as a label/path argument and as stdin: they are
# only read, never written (SC2094 does not apply).
# shellcheck disable=SC2094
# -----------------------------------------------------------------------------
# 55-persistence.sh — scheduled and startup jobs (persistence).
#
# Everything that makes a command run again later, without user action:
#   - crontabs (every user's when root, your own otherwise), /etc/crontab,
#     /etc/cron.d, scripts in /etc/cron.{hourly,daily,weekly,monthly};
#   - systemd services and drop-in overrides (system: /etc/systemd/system,
#     /etc/systemd/user; user: ~/.config/systemd/user, ~/.local/share/systemd/user);
#   - desktop autostart entries (~/.config/autostart, /etc/xdg/autostart);
#   - shell startup files (~/.bashrc, ~/.bash_aliases, ~/.profile, ... and /etc/profile,
#     /etc/bash.bashrc, /etc/profile.d);
#   - at jobs (counted only: their content includes the whole environment).
#
# Each command becomes one record, fields separated by tabs:
#   trigger  label  display  path  command  raw
#   trigger  frequent (every 1-5 min) | boot (@reboot, services, autostart) |
#            login (shell startup files) | periodic (anything else)
#   label    where it comes from; display: schedule / key / line number
#   path     source file when there is one (for the package check), else "-"
# Labels and paths built from file or user names go through safe_field, and
# are passed to awk through ENVIRON (awk -v would turn a literal "\t" into a
# tab): a control character in a file name can therefore not shift the fields
# and hide an entry. A path altered by safe_field no longer exists, so it can
# never be mistaken for an unmodified package file (fail-safe).
#
# Nothing but the schedule/key and the program name reaches the report:
# arguments often contain tokens. Each record gets a fingerprint (SHA-256 of
# label + raw line, 12 hex digits) for JOBS_ALLOW.
# -----------------------------------------------------------------------------

section "Persistence (scheduled and startup jobs)"

# safe_field TEXT — replace control characters (tab, newline...) by '?'.
safe_field() { printf '%s' "$1" | tr '\000-\037\177' '?'; }

# logical_lines — join lines ending with a backslash (systemd units and shell
# scripts allow continuation lines), drop CR, turn tabs into spaces.
# Output: "<first line number><TAB><logical line>".
logical_lines() {
    awk '
        { line = $0; sub(/\r$/, "", line)
          if (buf == "") start = NR
          if (line ~ /\\$/) { sub(/\\$/, "", line); buf = buf line " "; next }
          buf = buf line; gsub(/\t/, " ", buf); print start "\t" buf; buf = "" }
        END { if (buf != "") { gsub(/\t/, " ", buf); print start "\t" buf } }'
}

# crontab_records LABEL SYSTEM_FORMAT PATH — crontab content on stdin.
# (cron itself has no continuation lines.)
crontab_records() {
    LBL="$1" SYS="$2" SRC_PATH="$3" awk '
        /^[[:space:]]*#/ || NF == 0 || /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { next }
        {
            raw = $0; gsub(/[\t\r]/, " ", raw)
            if ($1 ~ /^@/) { sched = $1; i = 2 } else { sched = $1" "$2" "$3" "$4" "$5; i = 6 }
            if (ENVIRON["SYS"] == 1) i++
            cmd = ""; for (j = i; j <= NF; j++) cmd = cmd " " $j
            # In a crontab, an unescaped % ends the command and the rest is
            # sent to it on stdin, one line per %: "bash%curl ...%sh x" runs
            # those lines. Classify it as if % were a command separator.
            gsub(/\\%/, "\001", cmd); gsub(/%/, " ; ", cmd); gsub(/\001/, "%", cmd)
            if (sched == "@reboot") trig = "boot"
            else if ($1 ~ /^(\*|\*\/[1-5]|0-59|0-59\/[1-5])$/) trig = "frequent"
            else trig = "periodic"
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", trig, ENVIRON["LBL"], sched, ENVIRON["SRC_PATH"], cmd, raw
        }'
}

# script_records TRIGGER LABEL PATH — shell script content on stdin: every
# logical, non-comment line is treated as a command.
script_records() {
    logical_lines | TRIG="$1" LBL="$2" SRC_PATH="$3" awk -F'\t' '
        $2 ~ /^[[:space:]]*(#|$)/ { next }
        { printf "%s\t%s\tline %s\t%s\t%s\t%s\n", ENVIRON["TRIG"], ENVIRON["LBL"], $1, ENVIRON["SRC_PATH"], $2, $2 }'
}

# key_records TRIGGER LABEL PATH KEY_REGEX — unit or .desktop content on stdin:
# lines whose key matches KEY_REGEX (e.g. ^Exec[A-Za-z]*$ for systemd).
key_records() {
    logical_lines | TRIG="$1" LBL="$2" SRC_PATH="$3" KEYRE="$4" awk -F'\t' '
        {
            line = $2; sub(/^[[:space:]]+/, "", line)
            eq = index(line, "="); if (eq == 0) next
            key = substr(line, 1, eq - 1); sub(/[[:space:]]+$/, "", key)
            if (key !~ ENVIRON["KEYRE"]) next
            cmd = substr(line, eq + 1); sub(/^[[:space:]]*[-@:+!|]*/, "", cmd)
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", ENVIRON["TRIG"], ENVIRON["LBL"], key, ENVIRON["SRC_PATH"], cmd, line
        }'
}

# read_user_file PATH — file inside the audited user's home, read with that
# user's privileges (symlinks are then harmless: they can only reach what the
# user can read anyway).
read_user_file() { as_target cat -- "$1" 2>/dev/null; }

# prog_name COMMAND — basename of the program, or a placeholder.
prog_name() {
    local first="${1#"${1%%[![:space:]]*}"}"
    first="${first%%[[:space:]]*}"; first="${first//[\"\'()\`]/}"
    [[ "$first" == *=* ]] && { printf '<command with inline variables>'; return; }
    printf '%s' "${first##*/}"
}

# job_class TRIGGER COMMAND — prints "SUSPECT <reason>" or "ok".
# Program names may be preceded by a path (/usr/bin/curl, /bin/bash) and by
# sudo; "interpreter" means a shell or python/perl/ruby/php/node.
job_class() {
    local trig="$1" cmd="$2"
    local path='([^[:space:]"'"'"'`|;&()<>]*/)?'
    local sudo='(sudo[[:space:]]+)?'
    local interp_names='((ba|da|z|k)?sh|python[0-9.]*|perl|ruby|php|node)'
    local dl="${path}(curl|wget)"
    local net='(^|[^[:alnum:]_.-])(curl|wget|nc|ncat|netcat|socat|telnet|aria2c)([^[:alnum:]_-]|$)'
    # download executed directly: $(curl ...), `curl ...`, <(curl ...)
    local dl_subst='(\$\(|`|<\()[[:space:]]*'"${sudo}${dl}"'([^[:alnum:]_-]|$)'
    # anything piped into an interpreter that reads code from stdin
    # (no script argument after it: "| bash", "| /bin/sh -s", "| python3 -")
    local pipe_interp='\|[[:space:]]*'"${sudo}${path}${interp_names}"'([[:space:]]+-[^[:space:];&|)]*)*[[:space:]]*([;&|)]|$)'
    # download to a file, then run it: curl -o x ...; sh x / && chmod +x x
    local dl_then_run='(curl|wget)[^;&|]*(;|&&|\|\|)[[:space:]]*'"${sudo}"'(('"${path}${interp_names}"')[[:space:]]|chmod[[:space:]][^;&|]*x)'
    local decode='base64[[:space:]]+(-d|--decode)|/dev/(tcp|udp)/'
    local interp_net='(python[0-9.]*|perl|ruby|php|node)[[:space:]]+-[[:alnum:]]*[cer][[:space:]].*(https?://|urlopen|urllib|requests\.|socket|LWP|fsockopen|http\.get|fetch\()'
    # program (or interpreter script) started from a temporary or cache
    # location; only the first word of each command is considered, so a line
    # that merely reads a file under ~/.cache is not flagged
    local drop='(/tmp/|/var/tmp/|/dev/shm/|[^[:space:]"'"'"']*/\.cache/)'
    local tmp_exec='(^|[;&|(])[[:space:]]*'"${sudo}"'(exec[[:space:]]+)?(nohup[[:space:]]+)?(("?'"${drop}"')|('"${path}${interp_names}"'[[:space:]]+"?'"${drop}"'))'

    if   [[ "$cmd" =~ $dl_subst ]];    then echo "SUSPECT download-and-execute"
    elif [[ "$cmd" =~ $pipe_interp ]]; then
        if [[ "$cmd" =~ $net ]]; then echo "SUSPECT download-and-execute"; else echo "SUSPECT pipe-to-interpreter"; fi
    elif [[ "$cmd" =~ $dl_then_run ]]; then echo "SUSPECT download-then-run"
    elif [[ "$cmd" =~ $decode ]];      then echo "SUSPECT decode-or-raw-socket"
    elif [[ "$cmd" =~ $interp_net ]];  then echo "SUSPECT inline-interpreter-network"
    elif [[ "$trig" != periodic && "$cmd" =~ $net ]];      then echo "SUSPECT network-${trig}"
    elif [[ "$trig" != periodic && "$cmd" =~ $tmp_exec ]]; then echo "SUSPECT runs-from-temp-${trig}"
    else echo ok
    fi
}

# pkg_owner PATH — package that installed PATH (first one if shared), or nothing.
pkg_owner() {
    dpkg -S -- "$1" 2>/dev/null | grep -v '^diversion' | head -n1 | cut -d: -f1 | cut -d, -f1
}

# pkg_file_intact PATH OWNER — true if the regular file PATH still has the
# checksum recorded by package OWNER (conffiles in the status database, other
# files in the package's md5sums list, whose paths have no leading /).
pkg_file_intact() {
    local f="$1" owner="$2" md5 expected
    md5="$(md5sum <"$f" 2>/dev/null | cut -d' ' -f1)"
    expected="$(dpkg-query -W -f='${Conffiles}\n' "$owner" 2>/dev/null | P="$f" awk '$1 == ENVIRON["P"] {print $2; exit}')"
    if [[ -z "$expected" ]]; then
        expected="$(cat /var/lib/dpkg/info/"$owner".md5sums /var/lib/dpkg/info/"$owner":*.md5sums 2>/dev/null \
                    | P="${f#/}" awk '$2 == ENVIRON["P"] {print $1; exit}')"
    fi
    [[ -n "$md5" && "$md5" == "$expected" ]]
}

# pkg_unmodified PATH — if PATH is shipped by a Debian package and its content
# is unchanged (checksum from the package database), print the package name.
# Used to avoid flagging vendor files (e.g. Chrome's cron job that installs its
# repository key with base64 -d). A modified file is still flagged.
# Symlinks: dpkg records no checksum for a link, so the link must belong to a
# package, and its final target must be an unmodified file of the same package.
# This is how Chrome installs its job (/etc/cron.daily/google-chrome is a link
# to /opt/google/chrome/cron/google-chrome).
pkg_unmodified() {
    local f="$1" owner target towner
    [[ "$f" == /* && "$f" != "$TARGET_HOME"/* && -f "$f" ]] || return 1
    owner="$(pkg_owner "$f")"
    [[ -n "$owner" ]] || return 1
    if [[ -L "$f" ]]; then
        target="$(readlink -f -- "$f")"
        [[ "$target" == /* && "$target" != "$TARGET_HOME"/* && -f "$target" && ! -L "$target" ]] || return 1
        towner="$(pkg_owner "$target")"
        # The target must belong to the same package as the link: a link
        # redirected to an intact file of another package is not trusted.
        [[ "$towner" == "$owner" ]] && pkg_file_intact "$target" "$towner" || return 1
        printf '%s' "$owner"
        return 0
    fi
    pkg_file_intact "$f" "$owner" || return 1
    printf '%s' "$owner"
}

# ---- collect records ---------------------------------------------------------------
job_records=""
add() { [[ -n "$1" ]] && job_records+="$1"$'\n'; }

# Crontabs.
if [[ "$IS_ROOT" == 1 ]]; then
    for f in /var/spool/cron/crontabs/*; do
        [[ -f "$f" ]] || continue
        u="${f##*/}"
        add "$(crontab -l -u "$u" 2>/dev/null | crontab_records "crontab $(safe_field "$u")" 0 -)"
    done
else
    add "$(crontab -l 2>/dev/null | crontab_records "crontab ${TARGET_USER}" 0 -)"
    partial SVC-PERSISTENCE-SCOPE "crontabs of root and other users not inspected (needs sudo)"
fi
for f in /etc/crontab /etc/cron.d/*; do
    [[ -f "$f" && -r "$f" && "${f##*/}" != .placeholder ]] || continue
    add "$(crontab_records "$(safe_field "$f")" 1 "$(safe_field "$f")" <"$f")"
done
for f in /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/*; do
    [[ -f "$f" && -r "$f" && "${f##*/}" != .placeholder ]] || continue
    add "$(script_records periodic "$(safe_field "$f")" "$(safe_field "$f")" <"$f")"
done

# systemd services and drop-in overrides. In /etc, symlinks are enablement
# links to vendor units in /usr/lib and are skipped; drop-ins apply to any
# unit, vendor ones included.
for f in /etc/systemd/system/*.service /etc/systemd/user/*.service \
         /etc/systemd/system/*.service.d/*.conf /etc/systemd/user/*.service.d/*.conf; do
    [[ -f "$f" && ! -L "$f" && -r "$f" ]] || continue
    add "$(key_records boot "systemd $(safe_field "${f#/etc/systemd/}")" "$(safe_field "$f")" '^Exec[A-Za-z]*$' <"$f")"
done
for f in "${TARGET_HOME}"/.config/systemd/user/*.service "${TARGET_HOME}"/.config/systemd/user/*.service.d/*.conf \
         "${TARGET_HOME}"/.local/share/systemd/user/*.service "${TARGET_HOME}"/.local/share/systemd/user/*.service.d/*.conf; do
    [[ -e "$f" ]] || continue
    add "$(read_user_file "$f" | key_records boot "user systemd $(safe_field "${f##*/systemd/user/}")" "$(safe_field "$f")" '^Exec[A-Za-z]*$')"
done

# Desktop autostart entries.
for f in "${TARGET_HOME}"/.config/autostart/*.desktop; do
    [[ -e "$f" ]] || continue
    add "$(read_user_file "$f" | key_records boot "autostart $(safe_field "${f##*/}")" "$(safe_field "$f")" '^Exec$')"
done
for f in /etc/xdg/autostart/*.desktop; do
    [[ -f "$f" && -r "$f" ]] || continue
    add "$(key_records boot "system autostart $(safe_field "${f##*/}")" "$(safe_field "$f")" '^Exec$' <"$f")"
done

# Shell startup files (run at every login or new terminal).
for f in "${TARGET_HOME}"/.bashrc "${TARGET_HOME}"/.bash_aliases "${TARGET_HOME}"/.profile "${TARGET_HOME}"/.bash_profile \
         "${TARGET_HOME}"/.bash_login "${TARGET_HOME}"/.bash_logout "${TARGET_HOME}"/.zshrc \
         "${TARGET_HOME}"/.zprofile "${TARGET_HOME}"/.zlogin "${TARGET_HOME}"/.xprofile "${TARGET_HOME}"/.xsessionrc; do
    [[ -e "$f" ]] || continue
    # "~/" is a literal label for the report, not a path to expand.
    # shellcheck disable=SC2088
    add "$(read_user_file "$f" | script_records login "~/$(safe_field "${f##*/}")" "$(safe_field "$f")")"
done
for f in /etc/profile /etc/bash.bashrc /etc/profile.d/*.sh; do
    [[ -f "$f" && -r "$f" ]] || continue
    add "$(script_records login "$(safe_field "$f")" "$(safe_field "$f")" <"$f")"
done

# ---- classify ------------------------------------------------------------------------
suspects=""; allowed=""; vendor=""; all_jobs=""; seen_fp=" "; n_records=0; base_lines=""
while IFS=$'\t' read -r trig label display path cmd raw; do
    [[ -z "$label" ]] && continue
    n_records=$((n_records + 1))
    fp="$(printf '%s\n%s' "$label" "$raw" | sha256sum | cut -c1-12)"
    seen_fp+="${fp} "
    line="${fp}  ${label}: ${display}  $(prog_name "$cmd") ..."
    kind=job; [[ "$trig" == login ]] && kind=shell
    base_lines+="${fp}"$'\t'"${kind}"$'\t'"${path}"$'\t'"${line}"$'\n'
    # The inventory lists jobs, not every line of shell startup files or
    # vendor autostart entries (those appear only when they match a pattern).
    [[ "$trig" == login || "$label" == "system autostart "* || "$display" == "line "* ]] || all_jobs+="${line}"$'\n'
    read -r verdict reason <<<"$(job_class "$trig" "$cmd")"
    [[ "$verdict" == SUSPECT ]] || continue
    line+="  [${reason}]"
    if [[ " ${JOBS_ALLOW:-} " == *" ${fp} "* ]]; then
        allowed+="${line}"$'\n'
    elif [[ "$path" != - ]] && owner="$(pkg_unmodified "$path")"; then
        vendor+="${line}  (unmodified file of package ${owner})"$'\n'
    else
        suspects+="${line}"$'\n'
    fi
done <<<"$job_records"

# ---- findings ------------------------------------------------------------------------
if [[ -n "$suspects" ]]; then
    finding WARNING SVC-PERSISTENCE "$(grep -c . <<<"$suspects") scheduled or startup job(s) matching persistence patterns" \
        "Download-and-execute, piping into a shell, base64 decoding, /dev/tcp, inline interpreters fetching URLs, programs run from temporary or cache directories, and network calls every few minutes, at boot or at login are common ways malware keeps itself running. Legitimate monitoring and keep-alive jobs match too: this is a prompt to verify, not a verdict. The reason is shown in brackets. Check each job at its source ('crontab -l', the listed file or unit). If you do not recognise one, save a copy before removing anything and find out where it points and how it got there. If you do recognise it, add its fingerprint (first column) to JOBS_ALLOW in uhc.conf: any later change to that line produces a new fingerprint and triggers this warning again."
    evidence "Jobs to verify (fingerprint, source, schedule/key/line, program, reason — arguments hidden)" "${suspects%$'\n'}"
else
    finding OK SVC-PERSISTENCE "No scheduled or startup job matches known persistence patterns (${n_records} commands inspected)" \
        "Sources: crontabs, /etc/crontab, /etc/cron.d, /etc/cron.{hourly,daily,weekly,monthly}, systemd services and drop-ins (system and user), autostart entries, shell startup files. Only the command lines are inspected, not the content of the scripts they run, and obfuscated commands can escape pattern matching."
fi
if [[ -n "$allowed" ]]; then
    finding INFO SVC-PERSISTENCE-ALLOWED "$(grep -c . <<<"$allowed") job(s) matching persistence patterns, allowed by JOBS_ALLOW" \
        "uhc.conf can be edited by any program running under your account. If this list contains an entry you did not add yourself, treat it as a red flag."
    evidence "Allowed jobs" "${allowed%$'\n'}"
fi
if [[ -n "$vendor" ]]; then
    finding INFO SVC-PERSISTENCE-VENDOR "$(grep -c . <<<"$vendor") match(es) in unmodified files shipped by installed packages" \
        "These files match a pattern but are byte-for-byte identical to what their package installed (checked against the package database), so they are as trustworthy as the package itself. If such a file is modified later, it is reported as a warning."
    evidence "Packaged files" "${vendor%$'\n'}"
fi
stale_allow=""
for fp in ${JOBS_ALLOW:-}; do
    [[ "$seen_fp" == *" ${fp} "* ]] || stale_allow+="${fp} "
done
if [[ -n "$stale_allow" ]]; then
    finding INFO SVC-PERSISTENCE-STALE-ALLOW "JOBS_ALLOW entries that no longer match any job: ${stale_allow% }" \
        "The job was removed or changed. Remove these fingerprints from uhc.conf (a changed job appears again above with its new fingerprint)."
fi

# ---- change detection against the accepted reference list --------------------------------
# Patterns cannot recognise every form of a malicious command, but any
# persistence mechanism has to add or change an entry. The reference list
# stores one record per inspected command (fingerprint, kind, path, display
# line); entries that appear or change are reported at every run until the
# owner accepts them with --accept-jobs, so a change is never "absorbed"
# because a report was skipped.
#
# Storage (see STATE_DIR in uhc.sh): as root, in the root-owned installation,
# out of reach of programs running as the user; unprivileged, in the data
# directory. One list per privilege level and audited user (a root run sees
# more sources). A marker file records that a list was created, so that its
# disappearance is reported instead of silently starting over.
#
# Acceptance only covers what was reviewed: either the fingerprints given on
# the command line, or the exact list displayed in the terminal and confirmed.
# Anything else that appeared in the meantime stays pending.
base_user="${TARGET_USER//[^a-zA-Z0-9_.-]/_}"
base_mode="$([[ "$IS_ROOT" == 1 ]] && echo root || echo user)"
baseline="${STATE_DIR}/persistence-${base_mode}-${base_user}.baseline"
marker="${STATE_DIR}/.persistence-${base_mode}-${base_user}.created"
current_base="$(grep . <<<"$base_lines" | sort -u)"

# state_do CMD... — run CMD with the privileges that own the state directory.
state_do() { if [[ "$STATE_AS_ROOT" == 1 ]]; then "$@"; else as_data_owner "$@"; fi; }
# write_state FILE — replace FILE with stdin (private, atomic).
write_state() {
    # $1 is expanded by the inner sh, which receives the path as an argument.
    # shellcheck disable=SC2016
    state_do sh -c 'umask 077; cat > "$1.tmp" && mv -f "$1.tmp" "$1"' _ "$1" \
        || echo "uhc: cannot write $1" >&2
}
# indent TEXT — prefix every line with four spaces (for the terminal listing).
indent() { local l; while IFS= read -r l; do [[ -n "$l" ]] && printf '    %s\n' "$l"; done <<<"$1"; }
# drop_fps LIST FPS — remove from LIST the lines whose first word is in FPS.
drop_fps() {
    FPS=" $2 " awk '{ if (index(ENVIRON["FPS"], " " $1 " ") == 0) print }' <<<"$1" | grep .
}

if ! state_do test -f "$baseline"; then
    if state_do test -f "$marker"; then
        finding WARNING SVC-PERSISTENCE-BASELINE "Reference list of jobs missing although it existed: recreated from the current state" \
            "The list was deleted since the previous run. Anything added in the meantime is now part of the new reference without having been reviewed. Review the inventory below carefully. A program trying to hide a job would do exactly this$([[ "$STATE_AS_ROOT" == 0 ]] && echo '; a root audit (reference kept in the root-owned installation) is not exposed to it')."
    else
        finding INFO SVC-PERSISTENCE-BASELINE "Reference list of scheduled and startup jobs created ($(grep -c . <<<"$current_base") commands)" \
            "From now on, any job that appears or changes is reported at every run, whatever its form, until you accept it with --accept-jobs. Review the inventory below once: it is now considered known."
    fi
    printf '%s\n' "$current_base" | write_state "$baseline"
    date '+%Y-%m-%d' | write_state "$marker"
else
    state_do test -f "$marker" || date '+%Y-%m-%d' | write_state "$marker"
    old_base="$(state_do cat -- "$baseline" 2>/dev/null)"
    added="$(awk -F'\t' 'NR == FNR {old[$1] = 1; next} !($1 in old)' <(printf '%s\n' "$old_base") <(printf '%s\n' "$current_base") | grep .)"
    removed_rec="$(awk -F'\t' 'NR == FNR {cur[$1] = 1; next} !($1 in cur)' <(printf '%s\n' "$current_base") <(printf '%s\n' "$old_base") | grep .)"
    new_jobs=""; new_shell=""; pkg_changes=""
    while IFS=$'\t' read -r _ kind path line; do
        [[ -z "$line" ]] && continue
        if [[ "$path" != - ]] && owner="$(pkg_unmodified "$path")"; then
            pkg_changes+="${line}  (package ${owner})"$'\n'
        elif [[ "$kind" == shell ]]; then
            new_shell+="${line}"$'\n'
        else
            new_jobs+="${line}"$'\n'
        fi
    done <<<"$added"
    removed="$(cut -f4 <<<"$removed_rec" | grep .)"
    pending_fps="$(cut -f1 <<<"${added}"$'\n'"${removed_rec}" | grep . | sort -u | paste -sd ' ')"

    # ---- acceptance ----
    if [[ "${ACCEPT_JOBS:-0}" == 1 && -n "$pending_fps" ]]; then
        selected=""
        if (( ${#ACCEPT_FPS[@]} > 0 )); then
            for fp in "${ACCEPT_FPS[@]}"; do
                if [[ " $pending_fps " == *" $fp "* ]]; then selected+="$fp "
                else echo "uhc: --accept-jobs: $fp is not a pending change, ignored" >&2; fi
            done
        elif is_interactive && [[ "$QUIET" == 0 ]]; then
            {
                printf '\nPending changes in scheduled and startup jobs:\n'
                [[ -n "$new_jobs" ]]    && printf '\n  New or changed jobs:\n%s' "$(indent "$new_jobs")"
                [[ -n "$new_shell" ]]   && printf '\n  New or changed shell startup lines:\n%s' "$(indent "$new_shell")"
                [[ -n "$pkg_changes" ]] && printf '\n  Changed by package updates:\n%s' "$(indent "$pkg_changes")"
                [[ -n "$removed" ]]     && printf '\n  Removed or changed (previous version):\n%s\n' "$(indent "$removed")"
                printf '\n'
            } >&2
            if ask "Accept exactly these $(wc -w <<<"$pending_fps") change(s)?" n; then selected="$pending_fps"; fi
        else
            echo "uhc: --accept-jobs without fingerprints needs a terminal (to show what is accepted); nothing accepted" >&2
        fi
        if [[ -n "${selected// /}" ]]; then
            accepted_lines="$(grep . <<<"${new_jobs}${new_shell}${pkg_changes}${removed}" | FPS=" $selected " awk 'index(ENVIRON["FPS"], " " $1 " ")')"
            {
                FPS=" $selected " awk -F'\t' 'index(ENVIRON["FPS"], " " $1 " ") == 0' <<<"$old_base"
                FPS=" $selected " awk -F'\t' 'index(ENVIRON["FPS"], " " $1 " ")' <<<"$added"
            } | grep . | sort -u | write_state "$baseline"
            n_sel="$(wc -w <<<"$selected")"
            finding INFO SVC-PERSISTENCE-BASELINE "Reference list updated: ${n_sel} change(s) accepted" \
                "Accepted with --accept-jobs. Changes not listed here remain pending."
            evidence "Accepted" "$accepted_lines"
            log_line "$(date '+%Y-%m-%dT%H:%M:%S%z') --accept-jobs: ${n_sel} change(s) accepted in ${base_mode} reference list (${base_user}): ${selected% }"
            new_jobs="$(drop_fps "$new_jobs" "$selected")"; new_shell="$(drop_fps "$new_shell" "$selected")"
            pkg_changes="$(drop_fps "$pkg_changes" "$selected")"; removed="$(drop_fps "$removed" "$selected")"
        fi
    fi

    # ---- remaining changes ----
    accept_hint="accept them with --accept-jobs$([[ "$IS_ROOT" == 1 ]] && echo ' (with sudo, as for this run)')"
    if [[ -n "${new_jobs//[$'\n']/}" ]]; then
        finding WARNING SVC-PERSISTENCE-NEW "$(grep -c . <<<"$new_jobs") scheduled or startup job(s) new or changed since they were last accepted" \
            "These jobs did not exist, or were different, when the reference list was last accepted. This is reported whatever the form of the command, obfuscated or not. Check each one at its source. If they are yours, ${accept_hint}, either in a terminal (the exact list is shown before confirming) or by fingerprint."
        evidence "New or changed jobs (fingerprint, source, schedule/key, program)" "$new_jobs"
    fi
    if [[ -n "${new_shell//[$'\n']/}" ]]; then
        finding INFO SVC-PERSISTENCE-NEW-SHELL "$(grep -c . <<<"$new_shell") new or changed line(s) in shell startup files" \
            "Lines added to files such as ~/.bashrc, ~/.bash_aliases or ~/.profile since the last acceptance. Usually your own edits; ${accept_hint} once checked."
        evidence "New or changed lines" "$new_shell"
    fi
    if [[ -n "${pkg_changes//[$'\n']/}" ]]; then
        finding INFO SVC-PERSISTENCE-NEW-PACKAGE "$(grep -c . <<<"$pkg_changes") job line(s) changed by package updates" \
            "These lines come from files that installed packages shipped and that are unmodified: they changed with a package update. Listed for traceability (a compromised third-party repository would show up here); ${accept_hint}."
        evidence "Changed by package updates" "$pkg_changes"
    fi
    if [[ -n "${removed//[$'\n']/}" ]]; then
        finding INFO SVC-PERSISTENCE-REMOVED "$(grep -c . <<<"$removed") command(s) removed or changed since the last acceptance" \
            "Listed for completeness (a changed command also appears as new); ${accept_hint}."
        evidence "Removed" "$removed"
    fi
    [[ -z "${new_jobs}${new_shell}${pkg_changes}${removed}" ]] && \
        finding OK SVC-PERSISTENCE-NEW "No scheduled or startup job added or changed since the last acceptance"
fi

if have atq; then
    n_at="$(run atq | grep -c .)"
    if (( n_at > 0 )); then
        finding INFO SVC-AT-JOBS "${n_at} pending 'at' job(s)" \
            "One-off scheduled commands. Their content is not inspected (it includes the full environment). Review with 'atq' and 'at -c <id>'."
    fi
fi

timers=""
[[ -d /run/systemd/system ]] && timers="$(systemctl list-timers --all --no-legend --plain 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /\.timer$/) {print $i; break}}' | sort -u | paste -sd ' ')"
[[ -n "$timers" ]] && all_jobs+="systemd timers: ${timers}"$'\n'
if [[ -n "$all_jobs" ]]; then
    finding INFO SVC-SCHEDULED "Scheduled and startup jobs (review for unknown or obsolete entries)"
    evidence "Jobs (fingerprint, source, schedule/key, program — arguments hidden)" "${all_jobs%$'\n'}"
fi
