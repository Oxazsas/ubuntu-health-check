# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 40-snap.sh — snap health: failed refreshes, snap/deb duplicates (two
# daemons fighting for the same resource), publishers and confinement.
#
# Texts: lib/lang/*/40-snap.lang (keys SNAP-*, section.40-snap).
# -----------------------------------------------------------------------------

section "$(t section.40-snap)"

# snap_cmd_name LIST PLACEHOLDER — the first word of LIST, for a proposed
# command, when LIST has a single line; PLACEHOLDER when it has several (the
# list itself is in the evidence) or when the name is not a plain name.
snap_cmd_name() {
    if [[ "$1" == *$'\n'* ]]; then
        printf '%s' "$2"
    else
        safe_name "${1%% *}" "$2"
    fi
}

if ! have snap || ! snap list >/dev/null 2>&1; then
    partial SNAP-ALL "$(t SNAP-ALL.partial.1)"
else
    # ---- failed operations ------------------------------------------------------
    # 'snap changes' lists recent operations; repeated errors usually mean an
    # auto-refresh that keeps failing (running app, service conflict, ...).
    if ! snap_changes="$(run snap changes)"; then
        partial SNAP-ERRORS "$(t SNAP-ERRORS.partial.1)"
    elif snap_errors="$(awk 'NR>1 && $2=="Error"' <<<"$snap_changes")"; [[ -n "$snap_errors" ]]; then
        change_id="$(snap_cmd_name "$snap_errors" "<ID>")"
        # Errors that name the Snap Store or an obvious network failure point
        # to the store or the connection, not to this computer. The details of
        # an error are in the log of its operation ('snap tasks', read from the
        # local snapd, no network): the first five failed operations are read.
        net_re='api\.snapcraft\.io|snapcraftcontent\.com|dial tcp|no such host|name resolution|network is unreachable|i/o timeout|TLS handshake timeout|connection reset by peer|unexpected EOF'
        net_lines="$(grep -iE "$net_re" <<<"$snap_errors")"
        while read -r err_id _; do
            [[ "$err_id" =~ ^[0-9]+$ ]] || continue
            net_lines+=$'\n'"$(run snap tasks "$err_id" | grep -iE "$net_re")"
        done < <(head -n 5 <<<"$snap_errors")
        net_lines="$(grep -v '^$' <<<"$net_lines" | head -n 10)"
        finding WARNING SNAP-ERRORS "$(t SNAP-ERRORS.warn.title n="$(wc -l <<<"$snap_errors")")"
        if [[ -n "$net_lines" ]]; then
            impact SNAP-ERRORS.net.impact
            action "snap changes" SNAP-ERRORS.net.act.1
            action "snap tasks ${change_id}" SNAP-ERRORS.net.act.2
            action "sudo snap refresh" SNAP-ERRORS.net.act.3
            caution SNAP-ERRORS.net.caution
        else
            impact SNAP-ERRORS.warn.impact
            action "snap changes" SNAP-ERRORS.warn.act.1
            action "snap tasks ${change_id}" SNAP-ERRORS.warn.act.2
            action "sudo snap refresh" SNAP-ERRORS.warn.act.3
            caution SNAP-ERRORS.warn.caution
        fi
        evidence "$(t SNAP-ERRORS.ev.1)" "$snap_errors"
        evidence "$(t SNAP-ERRORS.ev.2)" "$net_lines"
    else
        finding OK SNAP-ERRORS "$(t SNAP-ERRORS.ok.title)"
    fi

    # ---- automatic refreshes ----------------------------------------------------------
    # 'snap refresh --time' is answered by the local snapd (no network). With
    # --abs-time, dates are RFC 3339 instead of "today at 14:55". A 'hold:'
    # line means that refreshes of all snaps are postponed; a single snap held
    # with 'snap refresh --hold NAME' shows 'held' in the Notes of 'snap list'.
    snap_table="$(snap list 2>/dev/null)"
    held_snaps="$(awk 'NR>1 && $NF ~ /(^|,)held(,|$)/ {print $1}' <<<"$snap_table")"
    if ! refresh_time="$(run snap refresh --time --abs-time)"; then
        partial SNAP-REFRESH "$(t SNAP-REFRESH.partial.1)"
    else
        refresh_last="$(awk '$1=="last:"{print $2; exit}' <<<"$refresh_time")"
        refresh_hold="$(awk '$1=="hold:"{$1=""; sub(/^ /, ""); print; exit}' <<<"$refresh_time")"
        last_epoch="$(date -d "$refresh_last" +%s 2>/dev/null)"
        if [[ -n "$refresh_hold" || -n "$held_snaps" ]]; then
            hold_until="$refresh_hold"
            hold_epoch="$(date -d "$refresh_hold" +%s 2>/dev/null)" && hold_until="$(date -d "@$hold_epoch" '+%Y-%m-%d')"
            held_cmd="$(snap_cmd_name "$held_snaps" "<name>")"
            # Every snap on hold is a WARNING; a hold on some snaps only is
            # usually deliberate and is reported as INFO.
            if [[ -n "$refresh_hold" ]]; then
                finding WARNING SNAP-REFRESH "$(t SNAP-REFRESH.held.title)"
                impact SNAP-REFRESH.held.impact
            else
                finding INFO SNAP-REFRESH "$(t SNAP-REFRESH.heldsome.title n="$(wc -l <<<"$held_snaps")")"
                impact SNAP-REFRESH.heldsome.impact
            fi
            action "snap refresh --time" SNAP-REFRESH.held.act.1
            if [[ -n "$refresh_hold" ]]; then
                action "sudo snap refresh --unhold" SNAP-REFRESH.held.act.2
            fi
            if [[ -n "$held_snaps" ]]; then
                action "sudo snap refresh --unhold ${held_cmd}" SNAP-REFRESH.held.act.3
            fi
            caution SNAP-REFRESH.held.caution
            [[ -n "$refresh_hold" ]] && evidence "$(t SNAP-REFRESH.ev.1)" "$(t SNAP-REFRESH.ev.all until="$hold_until")"
            evidence "$(t SNAP-REFRESH.ev.2)" "$held_snaps"
        fi
        # A hold of every snap already explains old refreshes: no second finding.
        if [[ -z "$refresh_hold" ]]; then
            if [[ ! "$last_epoch" =~ ^[0-9]+$ ]]; then
                partial SNAP-REFRESH "$(t SNAP-REFRESH.partial.2)"
            else
                refresh_age=$(( ($(date +%s) - last_epoch) / 86400 ))
                (( refresh_age < 0 )) && refresh_age=0
                refresh_date="$(date -d "@$last_epoch" '+%Y-%m-%d')"
                if (( refresh_age > SNAP_REFRESH_MAX_AGE )); then
                    finding WARNING SNAP-REFRESH "$(t SNAP-REFRESH.stale.title days="$refresh_age")"
                    impact SNAP-REFRESH.stale.impact date="$refresh_date"
                    action "snap refresh --time" SNAP-REFRESH.stale.act.1
                    action "snap changes" SNAP-REFRESH.stale.act.2
                    action "sudo snap refresh" SNAP-REFRESH.stale.act.3
                    caution SNAP-REFRESH.stale.caution
                    evidence "$(t SNAP-REFRESH.ev.3)" "$refresh_time"
                elif [[ -z "$held_snaps" ]]; then
                    finding OK SNAP-REFRESH "$(t SNAP-REFRESH.ok.title days="$refresh_age")"
                fi
            fi
        fi
    fi

    # ---- channel branches of another Ubuntu release ----------------------------------
    # Some snaps (snap-store, gtk-common-themes, mesa...) follow a branch made
    # for one Ubuntu release, e.g. latest/stable/ubuntu-26.04. After a release
    # upgrade, a branch left on the previous release no longer receives the
    # updates made for this one.
    # 'snap list' shortens a branch to "latest/stable/…", whatever the width of
    # the terminal. The full channel is read from the local snapd API ('snap
    # debug api /v2/snaps': installed snaps only, no network, no root needed).
    # Its JSON output is indented by snapd in a fixed way: each snap is an
    # object indented by 4 spaces, its own fields by 6. If that reading fails,
    # the column of 'snap list' is used, and shortened values are reported as
    # not checked.
    snap_channels="$(run snap debug api /v2/snaps | awk '
        /^    \{$/ { n = ""; c = "" }
        /^      "name": /             { n = $2 }
        /^      "tracking-channel": / { c = $2 }
        /^    \},?$/ { gsub(/[",]/, "", n); gsub(/[",]/, "", c); if (n != "" && c != "") print n "\t" c }')"
    [[ -n "$snap_channels" ]] || snap_channels="$(awk 'NR>1 && $4 != "-" {print $1 "\t" $4}' <<<"$snap_table")"
    if [[ -z "${OS_VERSION_ID:-}" ]]; then
        partial SNAP-BRANCH "$(t SNAP-BRANCH.partial.1)"
    else
        stale_branch=""; branch_cut=0; branch_name=""; branch_target=""
        while IFS=$'\t' read -r sname schan; do
            [[ -n "$sname" ]] || continue
            if [[ "$schan" == *"…"* ]]; then branch_cut=1; continue; fi
            IFS=/ read -r btrack brisk bbranch <<<"$schan"
            [[ "$bbranch" =~ ^ubuntu-([0-9]{2}\.[0-9]{2})$ ]] || continue
            [[ "${BASH_REMATCH[1]}" == "$OS_VERSION_ID" ]] && continue
            stale_branch+="$(printf '%-26s %-30s -> %s' "$sname" "$schan" "${btrack}/${brisk}")"$'\n'
            branch_name="$sname"; branch_target="${btrack}/${brisk}"
        done <<<"$snap_channels"
        stale_branch="${stale_branch%$'\n'}"
        if [[ -n "$stale_branch" ]]; then
            # One snap: its name and channel in the commands; several: placeholders.
            br_name="<name>"; br_chan="<track>/<risk>"
            if [[ "$stale_branch" != *$'\n'* ]]; then
                br_name="$(safe_name "$branch_name" "<name>")"
                bt="$(safe_name "${branch_target%%/*}" "")"; brk="$(safe_name "${branch_target#*/}" "")"
                [[ -n "$bt" && -n "$brk" ]] && br_chan="${bt}/${brk}"
            fi
            finding WARNING SNAP-BRANCH "$(t SNAP-BRANCH.warn.title n="$(wc -l <<<"$stale_branch")" version="$OS_VERSION_ID")"
            impact SNAP-BRANCH.warn.impact version="$OS_VERSION_ID"
            action "snap info ${br_name}" SNAP-BRANCH.warn.act.1
            action "sudo snap refresh ${br_name} --channel=${br_chan}" SNAP-BRANCH.warn.act.2
            caution SNAP-BRANCH.warn.caution
            evidence "$(t SNAP-BRANCH.ev.1)" "$stale_branch"
        elif (( branch_cut == 0 )); then
            finding OK SNAP-BRANCH "$(t SNAP-BRANCH.ok.title version="$OS_VERSION_ID")"
        fi
        # Shortened channels could not be checked: never an OK for them.
        (( branch_cut == 1 )) && partial SNAP-BRANCH "$(t SNAP-BRANCH.partial.2)"
    fi

    # ---- same software installed as snap AND deb ----------------------------------
    # Transitional debs that only install the snap (version containing 'snap',
    # e.g. firefox 1:1snap1) are expected and ignored.
    # A duplicate is a real conflict only when both sides provide a service: the
    # snap declares at least one ('snap services' fails or prints only its
    # header when there is none), and the deb ships a systemd service unit that
    # is active or enabled. Without systemd, every duplicate is informational.
    dupes=""; dupes_conflict=""
    while read -r name; do
        ver="$(dpkg-query -W -f='${db:Status-Status} ${Version}' "$name" 2>/dev/null)"
        if [[ "$ver" == installed* && "$ver" != *snap* ]]; then
            deb_unit=""
            if [[ -d /run/systemd/system ]] \
               && [[ -n "$(run snap services "$name" | awk 'NR>1 && NF')" ]]; then
                while read -r unit_path; do
                    unit="${unit_path##*/}"
                    if [[ "$(run systemctl is-active -- "$unit")" == active \
                          || "$(run systemctl is-enabled -- "$unit")" == enabled ]]; then
                        deb_unit="$unit"; break
                    fi
                done < <(run dpkg -L -- "$name" | grep '/systemd/system/[^/]*\.service$')
            fi
            if [[ -n "$deb_unit" ]]; then
                dupes_conflict+="${name} (deb ${ver#installed }, service ${deb_unit})"$'\n'
            else
                dupes+="${name} (deb ${ver#installed })"$'\n'
            fi
        fi
    done < <(snap list 2>/dev/null | awk 'NR>1{print $1}')
    if [[ -n "$dupes_conflict" ]]; then
        dup_name="$(snap_cmd_name "${dupes_conflict%$'\n'}" "<name>")"
        finding WARNING SNAP-DUPLICATE "$(t SNAP-DUPLICATE.conflict.title)"
        impact SNAP-DUPLICATE.conflict.impact
        action "snap services ${dup_name}" SNAP-DUPLICATE.conflict.act.1
        action "snap connections ${dup_name}" SNAP-DUPLICATE.conflict.act.2
        action "sudo snap remove ${dup_name}" SNAP-DUPLICATE.conflict.act.3
        caution SNAP-DUPLICATE.conflict.caution
        evidence "$(t SNAP-DUPLICATE.ev.1)" "${dupes_conflict%$'\n'}"
    fi
    if [[ -n "$dupes" ]]; then
        dup_name="$(snap_cmd_name "${dupes%$'\n'}" "<name>")"
        finding INFO SNAP-DUPLICATE "$(t SNAP-DUPLICATE.coexist.title)"
        impact SNAP-DUPLICATE.coexist.impact
        action "" SNAP-DUPLICATE.coexist.act.1
        action "snap connections ${dup_name}" SNAP-DUPLICATE.coexist.act.2
        evidence "$(t SNAP-DUPLICATE.ev.2)" "${dupes%$'\n'}"
    fi

    # ---- publishers and confinement -------------------------------------------------
    # Publisher column: a trailing ✓ (verified) or * / ** (starred) marks
    # publishers vetted by the Snap Store.
    snap_table="$(snap list 2>/dev/null)"
    unverified="$(awk 'NR>1 && $5 !~ /(✓|\*)$/ && $5 != "-" {print $1" (publisher: "$5")"}' <<<"$snap_table")"
    if [[ -n "$unverified" ]]; then
        snap_name="$(snap_cmd_name "$unverified" "<name>")"
        finding INFO SNAP-PUBLISHER "$(t SNAP-PUBLISHER.info.title)"
        impact SNAP-PUBLISHER.info.impact
        action "snap info ${snap_name}" SNAP-PUBLISHER.info.act.1
        action "" SNAP-PUBLISHER.info.act.2
        evidence "$(t SNAP-PUBLISHER.ev.1)" "$unverified"
    fi
    loose="$(awk 'NR>1 && ($6 ~ /devmode|jailmode|classic/) {print $1" ("$6")"}' <<<"$snap_table")"
    if [[ -n "$loose" ]]; then
        snap_name="$(snap_cmd_name "$loose" "<name>")"
        finding INFO SNAP-CONFINEMENT "$(t SNAP-CONFINEMENT.info.title)"
        impact SNAP-CONFINEMENT.info.impact
        action "snap info ${snap_name}" SNAP-CONFINEMENT.info.act.1
        action "" SNAP-CONFINEMENT.info.act.2
        evidence "$(t SNAP-CONFINEMENT.ev.1)" "$loose"
    fi
fi
