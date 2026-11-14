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
        finding WARNING SNAP-ERRORS "$(t SNAP-ERRORS.warn.title n="$(wc -l <<<"$snap_errors")")"
        impact SNAP-ERRORS.warn.impact
        action "snap changes" SNAP-ERRORS.warn.act.1
        action "snap tasks ${change_id}" SNAP-ERRORS.warn.act.2
        action "sudo snap refresh" SNAP-ERRORS.warn.act.3
        caution SNAP-ERRORS.warn.caution
        evidence "$(t SNAP-ERRORS.ev.1)" "$snap_errors"
    else
        finding OK SNAP-ERRORS "$(t SNAP-ERRORS.ok.title)"
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
