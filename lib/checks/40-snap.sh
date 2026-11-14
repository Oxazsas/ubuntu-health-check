# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 40-snap.sh — snap health: failed refreshes, snap/deb duplicates (two
# daemons fighting for the same resource), publishers and confinement.
# -----------------------------------------------------------------------------

section "Snap packages"

if ! have snap || ! snap list >/dev/null 2>&1; then
    partial SNAP-ALL "snap not installed or snapd not running"
else
    # ---- failed operations ------------------------------------------------------
    # 'snap changes' lists recent operations; repeated errors usually mean an
    # auto-refresh that keeps failing (running app, service conflict, ...).
    if ! snap_changes="$(run snap changes)"; then
        partial SNAP-ERRORS "snap operation history not readable"
    elif snap_errors="$(awk 'NR>1 && $2=="Error"' <<<"$snap_changes")"; [[ -n "$snap_errors" ]]; then
        finding WARNING SNAP-ERRORS "$(wc -l <<<"$snap_errors") failed snap operation(s) recently" \
            "Snaps that fail to refresh stay on old versions. Inspect with 'snap tasks <ID>' (the ID is the first column) to find the failing step."
        evidence "snap changes (errors only)" "$snap_errors"
    else
        finding OK SNAP-ERRORS "No failed snap operation in recent history"
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
        finding WARNING SNAP-DUPLICATE "Software installed both as a snap and as a deb package" \
            "Two copies of the same service can conflict (for example two Bluetooth daemons competing for the same D-Bus name, which makes snap refreshes fail). Usually keep the deb for system services on a desktop and remove the snap, after checking nothing depends on it ('snap connections <name>')."
        evidence "Duplicates with a service on both sides" "${dupes_conflict%$'\n'}"
    fi
    if [[ -n "$dupes" ]]; then
        finding INFO SNAP-DUPLICATE "Software installed both as a snap and as a deb package (no service conflict)" \
            "Both copies coexist without competing services, which is often intended (snapd, for example). Keeping both costs disk space and can make it unclear which version is launched."
        evidence "Duplicates" "${dupes%$'\n'}"
    fi

    # ---- publishers and confinement -------------------------------------------------
    # Publisher column: a trailing ✓ (verified) or * / ** (starred) marks
    # publishers vetted by the Snap Store.
    snap_table="$(snap list 2>/dev/null)"
    unverified="$(awk 'NR>1 && $5 !~ /(✓|\*)$/ && $5 != "-" {print $1" (publisher: "$5")"}' <<<"$snap_table")"
    if [[ -n "$unverified" ]]; then
        finding INFO SNAP-PUBLISHER "Snaps from non-verified publishers" \
            "Not necessarily a problem (community-maintained snaps), but make sure you trust each publisher."
        evidence "Snaps" "$unverified"
    fi
    loose="$(awk 'NR>1 && ($6 ~ /devmode|jailmode|classic/) {print $1" ("$6")"}' <<<"$snap_table")"
    if [[ -n "$loose" ]]; then
        finding INFO SNAP-CONFINEMENT "Snaps running without strict confinement" \
            "'classic' snaps have the same access as a regular application (normal for IDEs and CLI tools); 'devmode' disables confinement and should not be used outside development."
        evidence "Snaps" "$loose"
    fi
fi
