# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 85-backup.sh — backups: which tools are present, whether they are scheduled,
# and when the last backup ran, when a reliable local fact tells it.
#
# Sources, all read-only:
#   - Timeshift: /etc/timeshift/timeshift.json (schedule and backup device
#     only) and the names of the snapshot folders, when the backup device is
#     the system disk (/timeshift/snapshots) or is mounted by Timeshift;
#   - Déjà Dup: its settings (periodic, periodic-period, last-backup), read
#     with gsettings as the audited user. A gsettings read opens the dconf
#     "shm" flag file of $XDG_RUNTIME_DIR in write mode (creating it, or
#     ~/.cache/dconf/user without XDG_RUNTIME_DIR): XDG_RUNTIME_DIR points to
#     a private folder of this run instead, and no D-Bus session is used
#     (reads come straight from ~/.config/dconf/user). The Flatpak version
#     keeps them in a key file, read directly;
#   - systemd timers (system and user) whose name points to a backup tool:
#     state of the timer, last trigger, result of the last run of its
#     service (systemctl show);
#   - cron entries running a backup or copy program (rsync, rclone, tar,
#     borg, restic...), taken from the records collected by 55-persistence.sh
#     (job_records); only the schedule and the program name are kept;
#   - other tools (borg, borgmatic, restic, rsnapshot, duplicity, Back In
#     Time, Pika Backup, snapper, kopia): installed or not, configuration
#     present or not (existence only).
# Configuration files of borgmatic, restic, rclone, rsnapshot, Back In Time
# or Pika Backup are never opened: they may hold repository addresses,
# passwords or keys. Nothing here starts a daemon, a D-Bus session or a
# backup.
#
# A backup to a NAS, an online service or a manual copy leaves no trace that
# can be read here: the texts say so.
#
# Reads job_records (set in 55-persistence.sh) and its pkg_unmodified.
# Texts: lib/lang/*/85-backup.lang (key BAK-STATUS, section.85-backup).
# -----------------------------------------------------------------------------

section "$(t section.85-backup)"

# Root of the files read here, for tests only (see 15-hardware.sh).
bak_root=""
if [[ -n "${UHC_TEST_ROOT:-}" && "$(declare -p UHC_TEST_ROOT 2>/dev/null)" != "declare -x"* ]]; then
    bak_root="$UHC_TEST_ROOT"
fi

bak_now="$(date +%s)"
bak_lines=""      # inventory, one line per tool or scheduled job
bak_tools=""      # tool names for the title (fixed names, never user input)
bak_bad=""        # tools whose scheduled backup is late or failed
bak_sched=" "     # keywords of the tools found in a schedule
bak_partial=""

bak_tool_add() { [[ " $bak_tools " == *" $1 "* ]] || bak_tools+="${bak_tools:+ }$1"; }
bak_bad_add()  { [[ " $bak_bad " == *" $1 "* ]] || bak_bad+="${bak_bad:+ }$1"; }
# bak_line NAME PART... — one inventory line "NAME: part; part".
bak_line() {
    local l="$1:" p
    shift
    for p in "$@"; do l+=" ${p};"; done
    bak_lines+="${l%;}"$'\n'
}
# bak_when EPOCH — "date (n days ago)" text.
bak_when() {
    local days=$(( (bak_now - $1) / 86400 ))
    (( days < 0 )) && days=0
    t BAK-STATUS.ev.last date="$(date -d "@$1" '+%Y-%m-%d %H:%M')" days="$days"
}
# bak_old EPOCH — true if EPOCH is older than BACKUP_MAX_AGE days.
bak_old() { (( (bak_now - $1) / 86400 > BACKUP_MAX_AGE )); }
# bak_home_has PATH — true if PATH exists in the audited user's home (tested
# with that user's privileges).
bak_home_has() { as_target test -e "$1" 2>/dev/null; }
# bak_installed CMD [PACKAGE] [FLATPAK_ID] [SNAP] — true if the tool is there.
bak_installed() {
    have "$1" && return 0
    [[ -n "${2:-}" ]] && pkg_installed "$2" && return 0
    if [[ -n "${3:-}" ]]; then
        [[ -d "$bak_root/var/lib/flatpak/app/$3" ]] && return 0
        bak_home_has "$TARGET_HOME/.local/share/flatpak/app/$3" && return 0
    fi
    [[ -n "${4:-}" && -d "$bak_root/snap/$4" ]] && return 0
    return 1
}

# ---- scheduled jobs: systemd timers ---------------------------------------------
bak_kw_re='borgmatic|borg|restic|rsnapshot|snapper|timeshift|duplicity|deja-dup|rclone|backintime|pika|kopia|duplicati|rdiff-backup|syncoid|sanoid|backup'
# bak_sc SCOPE ARGS... — systemctl for SCOPE (system or user), with a short
# timeout. The user manager of the audited user is only queried when it
# already runs (its bus socket exists): nothing is started.
bak_user_rundir="/run/user/$(id -u "$TARGET_USER" 2>/dev/null)"
bak_sc() {
    local scope="$1"
    shift
    if [[ "$scope" == system ]]; then
        CMD_TIMEOUT=10 run systemctl "$@" </dev/null
    elif [[ -S "$bak_user_rundir/bus" ]]; then
        if [[ "$IS_ROOT" == 1 && "$TARGET_USER" != root ]]; then
            CMD_TIMEOUT=10 run runuser -u "$TARGET_USER" -- env XDG_RUNTIME_DIR="$bak_user_rundir" \
                systemctl --user "$@" </dev/null
        else
            CMD_TIMEOUT=10 run systemctl --user "$@" </dev/null
        fi
    else
        return 1
    fi
}
# bak_timer SCOPE TIMER — one inventory line for a backup timer.
bak_timer() {
    local scope="$1" tm="$2" kw tool unit="" active="" last="" svc_res="" svc_state="" ep="" k v key parts=()
    kw="$(grep -oiE "$bak_kw_re" <<<"$tm" | head -n1 | tr '[:upper:]' '[:lower:]')"
    # snapper also has a clean-up timer: only the one that takes snapshots counts.
    [[ "$kw" == snapper && "$tm" != snapper-timeline* ]] && return 0
    tool="$kw"
    while IFS='=' read -r k v; do
        case "$k" in ActiveState) active="$v" ;; Unit) unit="$v" ;; LastTriggerUSec) last="$v" ;; esac
    done < <(bak_sc "$scope" show -p ActiveState -p Unit -p LastTriggerUSec -- "$tm")
    if [[ "$unit" =~ ^[A-Za-z0-9@._:-]+$ ]]; then
        while IFS='=' read -r k v; do
            case "$k" in Result) svc_res="$v" ;; ActiveState) svc_state="$v" ;; esac
        done < <(bak_sc "$scope" show -p Result -p ActiveState -- "$unit")
    fi
    if [[ "$active" == active ]]; then
        parts+=("$(t BAK-STATUS.ev.timer_on)")
        bak_sched+="$kw "
    else
        parts+=("$(t BAK-STATUS.ev.timer_off)")
    fi
    [[ -n "$last" && "$last" != n/a ]] && ep="$(date -d "$last" +%s 2>/dev/null)"
    if [[ -n "$ep" ]]; then
        parts+=("$(t BAK-STATUS.ev.last_run when="$(bak_when "$ep")")")
    else
        parts+=("$(t BAK-STATUS.ev.no_run)")
    fi
    if [[ "$svc_state" == failed || ( -n "$svc_res" && "$svc_res" != success ) ]]; then
        parts+=("$(t BAK-STATUS.ev.failed result="${svc_res:-failed}")")
        [[ "$active" == active ]] && bak_bad_add "$tool"
    elif [[ "$svc_state" =~ ^(active|activating)$ ]]; then
        parts+=("$(t BAK-STATUS.ev.running)")
    fi
    [[ "$active" == active && -n "$ep" ]] && bak_old "$ep" && bak_bad_add "$tool"
    bak_tool_add "$tool"
    # lang-keys: BAK-STATUS.ev.scope.system BAK-STATUS.ev.scope.user
    key="BAK-STATUS.ev.scope.${scope}"
    bak_line "$(t "$key" unit="$tm")" "${parts[@]}"
}
bak_list_timers() {
    awk '{for (i = 1; i <= NF; i++) if ($i ~ /\.timer$/) {print $i; break}}' | sort -u \
        | grep -iE "$bak_kw_re" | grep -vE '^dpkg-db-backup\.timer$' | grep -E '^[A-Za-z0-9@._:\\-]+$'
}
if [[ -d /run/systemd/system ]]; then
    while read -r tm; do
        [[ -n "$tm" ]] && bak_timer system "$tm"
    done < <(bak_sc system list-timers --all --no-legend --plain | bak_list_timers)
    while read -r tm; do
        [[ -n "$tm" ]] && bak_timer user "$tm"
    done < <(bak_sc user list-timers --all --no-legend --plain | bak_list_timers)
fi

# ---- scheduled jobs: cron ---------------------------------------------------------
bak_cron_re='(^|[[:space:]/;&|(])(rsync|rclone|tar|borg|borgmatic|restic|duplicity|rsnapshot|backintime|timeshift|kopia|rdiff-backup|duplicacy|deja-dup)([[:space:];&|)]|$)'
while IFS=$'\t' read -r _trig label display path cmd _raw; do
    [[ "$label" == "crontab "* || "$label" == /etc/cron* ]] || continue
    [[ "$cmd" =~ $bak_cron_re ]] || continue
    prog="${BASH_REMATCH[2]}"
    # Lines of the cron scripts shipped unchanged by a package are not backups
    # set up by the user (a package script may well call tar).
    if [[ "$display" == "line "* && "$path" != - ]] && declare -F pkg_unmodified >/dev/null \
       && pkg_unmodified "$path" >/dev/null; then
        continue
    fi
    bak_sched+="$prog "
    bak_tool_add "$prog"
    bak_line "$(t BAK-STATUS.ev.cron label="$label" when="$display")" "$(t BAK-STATUS.ev.prog prog="$prog")" "$(t BAK-STATUS.ev.cron_last)"
done <<<"${job_records:-}"

# ---- Timeshift ------------------------------------------------------------------------
if bak_installed timeshift timeshift; then
    bak_tool_add timeshift
    parts=()
    conf="$bak_root/etc/timeshift/timeshift.json"
    ts_sched=""; ts_uuid=""; ts_btrfs=0
    if [[ -r "$conf" ]]; then
        for p in boot hourly daily weekly monthly; do
            grep -qE "\"schedule_${p}\"[[:space:]]*:[[:space:]]*\"true\"" "$conf" && ts_sched+="$p "
        done
        grep -qE '"btrfs_mode"[[:space:]]*:[[:space:]]*"true"' "$conf" && ts_btrfs=1
        ts_uuid="$(sed -nE 's/.*"backup_device_uuid"[[:space:]]*:[[:space:]]*"([0-9A-Fa-f-]+)".*/\1/p' "$conf" | head -n1)"
        if [[ -n "$ts_sched" ]]; then
            parts+=("$(t BAK-STATUS.ev.ts_sched list="${ts_sched% }")")
            bak_sched+="timeshift "
        else
            parts+=("$(t BAK-STATUS.ev.ts_nosched)")
        fi
    else
        parts+=("$(t BAK-STATUS.ev.ts_noconf)")
    fi
    root_uuid="$(findmnt -no UUID / 2>/dev/null | head -n1)"
    same=0
    [[ -n "$ts_uuid" && "${ts_uuid,,}" == "${root_uuid,,}" ]] && same=1
    (( same == 1 )) && parts+=("$(t BAK-STATUS.ev.samedisk)")
    # Snapshot folders are named by their date: 2026-11-14_23-00-02. The
    # folder on the system disk is only trusted when the configured backup
    # device is the system disk (a former backup location may remain).
    dirs=("$bak_root"/run/timeshift/*/backup/timeshift/snapshots "$bak_root"/run/timeshift/backup/timeshift-btrfs/snapshots)
    (( same == 1 && ts_btrfs == 0 )) && dirs+=("$bak_root/timeshift/snapshots")
    newest=""; count=0
    for d in "${dirs[@]}"; do
        [[ -d "$d" && -r "$d" ]] || continue
        while read -r s; do
            count=$((count + 1))
            [[ "$s" > "$newest" ]] && newest="$s"
        done < <(find "$d" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
                 | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$')
    done
    if [[ -n "$newest" ]]; then
        ep="$(date -d "${newest:0:10} ${newest:11:2}:${newest:14:2}:${newest:17:2}" +%s 2>/dev/null)"
        if [[ -n "$ep" ]]; then
            parts+=("$(t BAK-STATUS.ev.ts_snaps n="$count" when="$(bak_when "$ep")")")
            [[ -n "$ts_sched" ]] && bak_old "$ep" && bak_bad_add timeshift
        fi
    else
        parts+=("$(t BAK-STATUS.ev.last_unknown)")
    fi
    bak_line Timeshift "${parts[@]}"
fi

# ---- Déjà Dup ---------------------------------------------------------------------------
dd_deb=0; dd_flat=""
bak_installed deja-dup deja-dup && dd_deb=1
for d in "$bak_root/var/lib/flatpak/app/org.gnome.DejaDup" "$TARGET_HOME/.local/share/flatpak/app/org.gnome.DejaDup"; do
    if [[ "$d" == "$TARGET_HOME"/* ]]; then bak_home_has "$d" && dd_flat=1; else [[ -d "$d" ]] && dd_flat=1; fi
done
if (( dd_deb == 1 )) || [[ -n "$dd_flat" ]]; then
    bak_tool_add deja-dup
    dd_periodic=""; dd_period=""; dd_last=""; dd_read=0
    if [[ -n "$dd_flat" ]]; then
        kf="$TARGET_HOME/.var/app/org.gnome.DejaDup/config/glib-2.0/settings/keyfile"
        if bak_home_has "$kf"; then
            dd_read=1
            while IFS='=' read -r k v; do
                case "$k" in
                    periodic) dd_periodic="$v" ;; periodic-period) dd_period="$v" ;; last-backup) dd_last="$v" ;;
                esac
            done < <(as_target cat -- "$kf" 2>/dev/null | awk '/^\[/ { s = ($0 == "[org/gnome/deja-dup]") } s && /^(periodic|periodic-period|last-backup)=/')
        fi
    fi
    if (( dd_read == 0 && dd_deb == 1 )); then
        if have gsettings; then
            if [[ "$IS_ROOT" == 1 ]]; then
                dd_tmp="$(as_target mktemp -d /tmp/uhc.dconf.XXXXXXXX 2>/dev/null)"
            else
                dd_tmp="$(mktemp -d "${WORK_DIR}/dconf.XXXXXXXX" 2>/dev/null)"
            fi
            if [[ "$dd_tmp" =~ ^(/tmp/uhc\.dconf\.|"$WORK_DIR"/dconf\.)[A-Za-z0-9]{8}$ && -d "$dd_tmp" ]]; then
                dd_gs() {
                    as_target env -u DBUS_SESSION_BUS_ADDRESS -u DISPLAY -u WAYLAND_DISPLAY HOME="$TARGET_HOME" \
                        XDG_RUNTIME_DIR="$dd_tmp" GSETTINGS_BACKEND=dconf \
                        timeout 10 gsettings get org.gnome.DejaDup "$1" 2>/dev/null </dev/null
                }
                if dd_periodic="$(dd_gs periodic)"; then
                    dd_read=1
                    dd_period="$(dd_gs periodic-period)"
                    dd_last="$(dd_gs last-backup)"
                fi
                as_target rm -rf -- "$dd_tmp"
            fi
        fi
        (( dd_read == 1 )) || bak_partial="$(t BAK-STATUS.partial.dejadup)"
    fi
    parts=()
    if (( dd_read == 1 )); then
        dd_period="${dd_period//[^0-9]/}"
        if [[ "$dd_periodic" == true ]]; then
            parts+=("$(t BAK-STATUS.ev.dd_sched days="${dd_period:-?}")")
            bak_sched+="deja-dup "
        else
            parts+=("$(t BAK-STATUS.ev.dd_nosched)")
        fi
        dd_last="${dd_last//\'/}"; dd_last="${dd_last//\"/}"
        ep=""
        [[ "$dd_last" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9:]+)?$ ]] && ep="$(date -d "$dd_last" +%s 2>/dev/null)"
        if [[ -n "$ep" ]]; then
            parts+=("$(t BAK-STATUS.ev.dd_last when="$(bak_when "$ep")")")
            [[ "$dd_periodic" == true ]] && bak_old "$ep" && bak_bad_add deja-dup
        else
            parts+=("$(t BAK-STATUS.ev.never)")
        fi
    else
        parts+=("$(t BAK-STATUS.ev.settings_unknown)")
    fi
    bak_line "Déjà Dup" "${parts[@]}"
fi

# ---- other tools ------------------------------------------------------------------------
# NAME|COMMAND|PACKAGE|FLATPAK|SNAP|SCHEDULE KEYWORD|CONFIGURATION PATHS (existence only)
bak_others=(
    "BorgBackup|borg|borgbackup|||borg|"
    "borgmatic|borgmatic|borgmatic|||borgmatic|/etc/borgmatic/config.yaml /etc/borgmatic.d ~/.config/borgmatic"
    "restic|restic|restic||restic|restic|"
    "rsnapshot|rsnapshot|rsnapshot|||rsnapshot|/etc/rsnapshot.conf"
    "duplicity|duplicity|duplicity|||duplicity|"
    "Back In Time|backintime|backintime-common|||backintime|~/.config/backintime"
    "Pika Backup|pika-backup|pika-backup|org.gnome.World.PikaBackup||pika|~/.var/app/org.gnome.World.PikaBackup/config/pika-backup ~/.config/pika-backup"
    "snapper|snapper|snapper|||snapper|/etc/snapper/configs"
    "kopia|kopia|kopia|||kopia|~/.config/kopia"
)
for entry in "${bak_others[@]}"; do
    IFS='|' read -r name cmd pkg flat snapn kw confs <<<"$entry"
    bak_installed "$cmd" "$pkg" "$flat" "$snapn" || continue
    bak_tool_add "$kw"
    parts=()
    if [[ " $bak_sched " == *" $kw "* ]]; then
        parts+=("$(t BAK-STATUS.ev.sched_found)")
    else
        parts+=("$(t BAK-STATUS.ev.sched_none)")
    fi
    found=""
    for c in $confs; do
        if [[ "$c" == \~/* ]]; then
            bak_home_has "$TARGET_HOME/${c#\~/}" && found+="${found:+, }$c"
        else
            [[ -e "$bak_root$c" ]] && found+="${found:+, }$c"
        fi
    done
    if [[ -n "$found" ]]; then
        parts+=("$(t BAK-STATUS.ev.config list="$found")")
    elif [[ -n "$confs" ]]; then
        parts+=("$(t BAK-STATUS.ev.noconfig)")
    fi
    parts+=("$(t BAK-STATUS.ev.last_unknown)")
    bak_line "$name" "${parts[@]}"
done

# ---- finding ------------------------------------------------------------------------------
# bak_names LIST — the tool keywords of LIST with their usual names, for titles.
bak_names() {
    local k out=""
    for k in $1; do
        case "$k" in
            timeshift) k=Timeshift ;; deja-dup) k="Déjà Dup" ;; borg) k=BorgBackup ;;
            backintime) k="Back In Time" ;; pika) k="Pika Backup" ;; backup) k="$(t BAK-STATUS.tool.timer)" ;;
        esac
        out+="${out:+, }$k"
    done
    printf '%s' "$out"
}
if [[ -n "$bak_bad" ]]; then
    finding WARNING BAK-STATUS "$(t BAK-STATUS.warn.title tools="$(bak_names "$bak_bad")")"
    impact BAK-STATUS.warn.impact days="$BACKUP_MAX_AGE"
    action "" BAK-STATUS.warn.act.1
    action "systemctl list-timers --all" BAK-STATUS.warn.act.2
    action "journalctl -u <unit> -n 50" BAK-STATUS.warn.act.3
    action "" BAK-STATUS.warn.act.4
    caution BAK-STATUS.warn.caution
elif [[ -n "$bak_tools" ]]; then
    finding INFO BAK-STATUS "$(t BAK-STATUS.info.title tools="$(bak_names "$bak_tools")")"
    impact BAK-STATUS.info.impact days="$BACKUP_MAX_AGE"
else
    finding INFO BAK-STATUS "$(t BAK-STATUS.none.title)"
    impact BAK-STATUS.none.impact
    action "" BAK-STATUS.none.act.1
fi
evidence "$(t BAK-STATUS.ev.1)" "${bak_lines%$'\n'}"
[[ -n "$bak_partial" ]] && partial BAK-STATUS "$bak_partial"
