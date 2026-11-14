# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 15-hardware.sh — hardware health: battery wear, disk health (SMART) and
# hardware errors in the kernel log.
#
# Read-only by construction:
#   - battery: files of /sys/class/power_supply/BAT* (the serial number file
#     is never read);
#   - disks: as root, smartctl -H -A -n standby (health and attributes only:
#     -i, which prints the serial number, is never used; -n standby leaves a
#     sleeping disk asleep) or nvme smart-log; without root, the SMART data
#     that udisks2 already keeps, read over D-Bus with busctl --auto-start=no
#     and only when udisksd already runs, so no daemon is ever started. Raw
#     outputs never reach the report: only the parsed values do (no serial
#     number, no WWN, no udisks object path, which contains the serial);
#   - kernel log: journalctl -k of the current and previous boot.
# Disks are skipped in a virtual machine or a container (their SMART data,
# when there is any, belongs to the host); removable, USB, loop, zram, dm and
# md devices are never examined.
#
# Texts: lib/lang/*/15-hardware.lang (keys HW-*, section.15-hardware).
# -----------------------------------------------------------------------------

section "$(t section.15-hardware)"

# Root of the files read here: "/" in normal use. A test harness may set
# UHC_TEST_ROOT inside the process (a module sourced before this one); a value
# inherited from the environment (exported) is ignored, so it is not a user
# setting.
hw_root=""
if [[ -n "${UHC_TEST_ROOT:-}" && "$(declare -p UHC_TEST_ROOT 2>/dev/null)" != "declare -x"* ]]; then
    hw_root="$UHC_TEST_ROOT"
fi

# hw_val FILE — first line of FILE, trimmed; nothing if unreadable.
hw_val() {
    local v=""
    [[ -r "$1" && -f "$1" ]] || return 0
    IFS= read -r v <"$1" 2>/dev/null
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}
# hw_int VALUE — true if VALUE is a non-negative integer (no leading zero
# issue: Bash arithmetic is only applied after this test, with 10#).
hw_int() { [[ "$1" =~ ^[0-9]{1,15}$ ]]; }

hw_virt="$(run systemd-detect-virt)"
[[ "$hw_virt" == none ]] && hw_virt=""

# ---- battery -------------------------------------------------------------------
bat_lines=""; bat_low=""; bat_titles=""
for bat in "$hw_root"/sys/class/power_supply/BAT*; do
    [[ -d "$bat" ]] || continue
    bt="$(hw_val "$bat/type")"
    [[ -z "$bt" || "$bt" == Battery ]] || continue
    [[ "$(hw_val "$bat/present")" == 0 ]] && continue
    bname="$(clean_line "${bat##*/}")"
    full="$(hw_val "$bat/energy_full")"; design="$(hw_val "$bat/energy_full_design")"; unit=µWh
    if ! hw_int "$full" || ! hw_int "$design"; then
        full="$(hw_val "$bat/charge_full")"; design="$(hw_val "$bat/charge_full_design")"; unit=µAh
    fi
    health=""
    if hw_int "$full" && hw_int "$design" && (( 10#$design > 0 && 10#$full > 0 )); then
        health=$(( (10#$full * 1000 / 10#$design + 5) / 10 ))
    fi
    parts=()
    if [[ -n "$health" ]]; then
        parts+=("$(t HW-BATTERY.ev.health pct="$health" full="$((10#$full))" design="$((10#$design))" unit="$unit")")
        bat_titles+="${bat_titles:+, }$(t HW-BATTERY.title.one name="$bname" pct="$health")"
        (( health < BATTERY_HEALTH_WARN )) && bat_low+="${bat_low:+, }$(t HW-BATTERY.title.one name="$bname" pct="$health")"
    else
        parts+=("$(t HW-BATTERY.ev.health_unknown)")
        bat_titles+="${bat_titles:+, }$(t HW-BATTERY.title.unknown name="$bname")"
    fi
    v="$(hw_val "$bat/cycle_count")"
    hw_int "$v" && (( 10#$v > 0 )) && parts+=("$(t HW-BATTERY.ev.cycles n="$((10#$v))")")
    v="$(hw_val "$bat/capacity")"
    hw_int "$v" && parts+=("$(t HW-BATTERY.ev.charge pct="$((10#$v))")")
    v="$(hw_val "$bat/status")"
    [[ "$v" =~ ^[A-Za-z\ ]{1,30}$ ]] && parts+=("$(t HW-BATTERY.ev.status status="$v")")
    v="$(hw_val "$bat/charge_control_start_threshold")"; v2="$(hw_val "$bat/charge_control_end_threshold")"
    if hw_int "$v2"; then
        if hw_int "$v"; then parts+=("$(t HW-BATTERY.ev.thresholds start="$((10#$v))" end="$((10#$v2))")")
        else parts+=("$(t HW-BATTERY.ev.threshold_end end="$((10#$v2))")"); fi
    fi
    v="$(hw_val "$bat/charge_types")"
    [[ "$v" =~ \[([A-Za-z_\ ]{1,20})\] ]] && parts+=("$(t HW-BATTERY.ev.mode mode="${BASH_REMATCH[1]}")")
    v="$(hw_val "$bat/technology")"
    [[ "$v" =~ ^[A-Za-z0-9-]{1,20}$ && "$v" != Unknown ]] && parts+=("$v")
    # Manufacturer and model (not the serial number): they identify the
    # battery type, for a replacement.
    v="$(hw_val "$bat/manufacturer") $(hw_val "$bat/model_name")"
    v="${v# }"; v="${v% }"
    [[ -n "$v" ]] && parts+=("$(clean_line "$v")")
    line="${bname}:"
    for p in "${parts[@]}"; do line+=" ${p};"; done
    bat_lines+="${line%;}"$'\n'
done
if [[ -n "$bat_lines" ]]; then
    if [[ -n "$bat_low" ]]; then
        finding WARNING HW-BATTERY "$(t HW-BATTERY.warn.title list="$bat_low")"
        impact HW-BATTERY.warn.impact threshold="$BATTERY_HEALTH_WARN"
        action "upower --dump" HW-BATTERY.warn.act.1
        action "" HW-BATTERY.warn.act.2
        action "" HW-BATTERY.warn.act.3
        caution HW-BATTERY.warn.caution
    else
        finding INFO HW-BATTERY "$(t HW-BATTERY.info.title list="$bat_titles")"
        impact HW-BATTERY.info.impact threshold="$BATTERY_HEALTH_WARN"
    fi
    evidence "$(t HW-BATTERY.ev.1)" "${bat_lines%$'\n'}"
fi

# ---- disk health -----------------------------------------------------------------
# Values of the disk being read (reset by disk_reset, filled by the readers).
disk_reset() {
    d_src=""; d_health=""; d_cw=""; d_wear=""; d_hours=""; d_temp=""
    d_realloc=""; d_pending=""; d_media=""; d_standby=0; d_nodata=0
}
# nvme_flags HEX_OR_DEC — names of the bits of an NVMe critical warning, as
# udisks2 names them.
nvme_flags() {
    local v="$1" out="" i
    local names=(spare temperature degraded readonly volatile_mem pmr_readonly)
    [[ "$v" == 0x* ]] && v=$((16#${v#0x})) || v=$((10#$v))
    for i in 0 1 2 3 4 5; do (( v & (1 << i) )) && out+="${names[$i]} "; done
    (( v >> 6 )) && out+="other "
    printf '%s' "${out% }"
}

# disk_smartctl NAME — root only. True if smartctl gave usable data.
disk_smartctl() {
    local out
    out="$(run smartctl -H -A -n standby "/dev/$1")"
    if grep -qE 'Device is in (STANDBY|SLEEP)' <<<"$out"; then
        d_src=smartctl; d_standby=1; return 0
    fi
    d_health="$(sed -nE 's/^SMART overall-health self-assessment test result: *([A-Z]+).*/\1/p; s/^SMART Health Status: *([A-Za-z]+).*/\1/p' <<<"$out" | head -n1)"
    if [[ "$1" == nvme* ]]; then
        d_cw="$(sed -nE 's/^Critical Warning: *(0x[0-9a-fA-F]+).*/\1/p' <<<"$out" | head -n1)"
        d_wear="$(sed -nE 's/^Percentage Used: *([0-9]+)%.*/\1/p' <<<"$out" | head -n1)"
        d_hours="$(sed -nE 's/^Power On Hours: *([0-9,]+).*/\1/p' <<<"$out" | head -n1 | tr -d ,)"
        d_temp="$(sed -nE 's/^Temperature: *([0-9]+) Celsius.*/\1/p' <<<"$out" | head -n1)"
        d_media="$(sed -nE 's/^Media and Data Integrity Errors: *([0-9,]+).*/\1/p' <<<"$out" | head -n1 | tr -d ,)"
        if [[ -n "$d_cw" ]]; then
            d_cw="$(nvme_flags "$d_cw")"; [[ -n "$d_cw" ]] || d_cw=none
        fi
    else
        # ATA attribute table: ID NAME FLAG VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW
        d_hours="$(awk '$1 == 9 {print $10; exit}' <<<"$out" | grep -oE '^[0-9]+')"
        d_temp="$(awk '$1 == 194 {print $10; exit}' <<<"$out" | grep -oE '^[0-9]+')"
        [[ -n "$d_temp" ]] || d_temp="$(awk '$1 == 190 {print $10; exit}' <<<"$out" | grep -oE '^[0-9]+')"
        d_realloc="$(awk '$1 == 5 {print $10; exit}' <<<"$out" | grep -oE '^[0-9]+')"
        d_pending="$(awk '$1 == 197 {print $10; exit}' <<<"$out" | grep -oE '^[0-9]+')"
        # SCSI / SAS disks.
        [[ -n "$d_temp" ]] || d_temp="$(sed -nE 's/^Current Drive Temperature: *([0-9]+) C.*/\1/p' <<<"$out" | head -n1)"
        [[ -n "$d_hours" ]] || d_hours="$(sed -nE 's/^Accumulated power on time, hours:minutes *([0-9]+):.*/\1/p' <<<"$out" | head -n1)"
    fi
    [[ -n "$d_health$d_cw$d_wear$d_hours" ]] || return 1
    d_src=smartctl
}

# disk_nvmecli NAME — root only, NVMe only.
disk_nvmecli() {
    local out
    out="$(run nvme smart-log "/dev/$1")"
    d_cw="$(sed -nE 's/^critical_warning[[:space:]]*:[[:space:]]*(0x[0-9a-fA-F]+|[0-9]+).*/\1/p' <<<"$out" | head -n1)"
    [[ -n "$d_cw" ]] || return 1
    d_cw="$(nvme_flags "$d_cw")"; [[ -n "$d_cw" ]] || d_cw=none
    d_wear="$(sed -nE 's/^percentage_used[[:space:]]*:[[:space:]]*([0-9]+)%.*/\1/p' <<<"$out" | head -n1)"
    d_hours="$(sed -nE 's/^power_on_hours[[:space:]]*:[[:space:]]*([0-9,]+).*/\1/p' <<<"$out" | head -n1 | tr -d ,)"
    d_temp="$(sed -nE 's/^temperature[[:space:]]*:[[:space:]]*([0-9]+)[^0-9K]*C.*/\1/p' <<<"$out" | head -n1)"
    d_media="$(sed -nE 's/^media_errors[[:space:]]*:[[:space:]]*([0-9,]+).*/\1/p' <<<"$out" | head -n1 | tr -d ,)"
    d_src=nvme-cli
}

# ud ARGS... — busctl on the system bus, never starting a service.
ud() { CMD_TIMEOUT=10 run busctl --system --auto-start=no "$@" </dev/null; }
# disk_udisks NAME — the SMART data udisks2 keeps (no root needed).
disk_udisks() {
    local drive props cw upd temp attrs
    drive="$(ud get-property org.freedesktop.UDisks2 "/org/freedesktop/UDisks2/block_devices/$1" \
             org.freedesktop.UDisks2.Block Drive | sed -nE 's/^o "(\/[^"]*)"$/\1/p')"
    [[ -n "$drive" && "$drive" != / ]] || return 1
    if [[ "$1" == nvme* ]]; then
        mapfile -t props < <(ud get-property org.freedesktop.UDisks2 "$drive" org.freedesktop.UDisks2.NVMe.Controller \
                             SmartUpdated SmartCriticalWarning SmartPowerOnHours SmartTemperature)
        (( ${#props[@]} == 4 )) || return 1
        upd="${props[0]#t }"
        d_src=udisks2
        if [[ "$upd" == 0 ]]; then d_nodata=1; return 0; fi
        cw="${props[1]#as }"
        if [[ "$cw" == 0 ]]; then d_cw=none
        else d_cw="$(cut -d' ' -f2- <<<"$cw" | tr -d '"')"; fi
        d_hours="${props[2]#t }"; hw_int "$d_hours" || d_hours=""
        temp="${props[3]#q }"
        hw_int "$temp" && (( temp > 0 )) && d_temp=$(( temp - 273 ))
        attrs="$(ud call org.freedesktop.UDisks2 "$drive" org.freedesktop.UDisks2.NVMe.Controller \
                 SmartGetAttributes 'a{sv}' 0)"
        d_wear="$(grep -oE '"percent_used" y [0-9]+' <<<"$attrs" | grep -oE '[0-9]+$')"
        d_media="$(grep -oE '"media_errors" t [0-9]+' <<<"$attrs" | grep -oE '[0-9]+$')"
    else
        mapfile -t props < <(ud get-property org.freedesktop.UDisks2 "$drive" org.freedesktop.UDisks2.Drive.Ata \
                             SmartSupported SmartEnabled SmartUpdated SmartFailing SmartPowerOnSeconds \
                             SmartTemperature SmartNumBadSectors)
        (( ${#props[@]} == 7 )) || return 1
        d_src=udisks2
        if [[ "${props[0]}" != "b true" || "${props[1]}" != "b true" || "${props[2]}" == "t 0" ]]; then
            d_nodata=1; return 0
        fi
        [[ "${props[3]}" == "b true" ]] && d_health=FAILED || d_health=PASSED
        upd="${props[4]#t }"; hw_int "$upd" && d_hours=$(( upd / 3600 ))
        temp="${props[5]#d }"
        [[ "$temp" =~ ^[0-9]+(\.[0-9]+)?$ ]] && d_temp="$(awk -v k="$temp" 'BEGIN { if (k > 0) printf "%d", k - 273.15 + 0.5 }')"
        d_realloc="${props[6]#x }"; [[ "$d_realloc" =~ ^[0-9]+$ ]] || d_realloc=""
    fi
}

disk_lines=""; disk_crit=""; disk_warn=""; disk_unread=""; disk_read=0; first_bad=""
if [[ -z "$hw_virt" ]]; then
    udisks_up=0
    have busctl && pgrep -x udisksd >/dev/null 2>&1 && udisks_up=1
    for dev in "$hw_root"/sys/block/*; do
        name="${dev##*/}"
        [[ "$name" =~ ^(sd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+)$ ]] || continue
        [[ "$(hw_val "$dev/removable")" == 1 ]] && continue
        # USB disks (enclosures, sticks) come and go: not examined.
        [[ "$(readlink -f "$dev" 2>/dev/null)" == */usb* ]] && continue
        disk_reset
        if [[ "$IS_ROOT" == 1 ]] && have smartctl && disk_smartctl "$name"; then :
        elif [[ "$IS_ROOT" == 1 && "$name" == nvme* ]] && have nvme && { disk_reset; disk_nvmecli "$name"; }; then :
        elif (( udisks_up == 1 )) && { disk_reset; disk_udisks "$name"; }; then :
        else
            disk_unread+="${disk_unread:+, }$name"
            continue
        fi
        disk_read=$((disk_read + 1))
        model="$(clean_line "$(hw_val "$dev/device/model")")"
        size="$(hw_val "$dev/size")"
        parts=()
        [[ -n "$model" ]] && parts+=("$model")
        hw_int "$size" && (( 10#$size > 0 )) && parts+=("$(numfmt --to=si --suffix=B $(( 10#$size * 512 )) 2>/dev/null)")
        sev=OK
        if (( d_standby == 1 )); then
            parts+=("$(t HW-DISK-HEALTH.ev.standby)")
        elif (( d_nodata == 1 )); then
            parts+=("$(t HW-DISK-HEALTH.ev.nodata)")
        else
            [[ -n "$d_health" ]] && parts+=("$(t HW-DISK-HEALTH.ev.health value="$d_health")")
            if [[ -n "$d_cw" ]]; then
                if [[ "$d_cw" == none ]]; then parts+=("$(t HW-DISK-HEALTH.ev.cw_none)")
                else parts+=("$(t HW-DISK-HEALTH.ev.cw flags="$d_cw")"); fi
            fi
            hw_int "$d_wear" && parts+=("$(t HW-DISK-HEALTH.ev.wear pct="$d_wear")")
            hw_int "$d_hours" && parts+=("$(t HW-DISK-HEALTH.ev.hours n="$d_hours")")
            hw_int "$d_temp" && parts+=("$(t HW-DISK-HEALTH.ev.temp c="$d_temp")")
            hw_int "$d_realloc" && parts+=("$(t HW-DISK-HEALTH.ev.realloc n="$d_realloc")")
            hw_int "$d_pending" && parts+=("$(t HW-DISK-HEALTH.ev.pending n="$d_pending")")
            hw_int "$d_media" && (( 10#$d_media > 0 )) && parts+=("$(t HW-DISK-HEALTH.ev.media n="$d_media")")
            # A disk that declares itself failing: ATA/SCSI overall health
            # not passed, or NVMe "reliability degraded" / "read-only".
            if [[ -n "$d_health" && ! "$d_health" =~ ^(PASSED|OK)$ ]] || [[ " $d_cw " == *" degraded "* || " $d_cw " == *" readonly "* ]]; then
                sev=CRITICAL
            elif [[ -n "$d_cw" && "$d_cw" != none ]] || { hw_int "$d_wear" && (( d_wear >= 90 )); }; then
                sev=WARNING
            fi
        fi
        parts+=("$(t HW-DISK-HEALTH.ev.source src="$d_src")")
        line="${name}:"
        for p in "${parts[@]}"; do line+=" ${p};"; done
        disk_lines+="${line%;}"$'\n'
        case "$sev" in
            CRITICAL) disk_crit+="${disk_crit:+, }$name"; [[ -n "$first_bad" ]] || first_bad="$name" ;;
            WARNING)  disk_warn+="${disk_warn:+, }$name"; [[ -n "$first_bad" ]] || first_bad="$name" ;;
        esac
    done

    # Only one disk in trouble: name it in the commands.
    bad_cmd="<disk>"
    (( $(wc -w <<<"${disk_crit//,/ } ${disk_warn//,/ }") == 1 )) && bad_cmd="$(safe_name "$first_bad" "<disk>")"
    if [[ -n "$disk_crit" ]]; then
        finding CRITICAL HW-DISK-HEALTH "$(t HW-DISK-HEALTH.crit.title disks="$disk_crit")"
        impact HW-DISK-HEALTH.crit.impact
        action "" HW-DISK-HEALTH.crit.act.1
        action "sudo smartctl -H -A /dev/${bad_cmd}" HW-DISK-HEALTH.crit.act.2
        action "" HW-DISK-HEALTH.crit.act.3
        caution HW-DISK-HEALTH.crit.caution
    elif [[ -n "$disk_warn" ]]; then
        finding WARNING HW-DISK-HEALTH "$(t HW-DISK-HEALTH.warn.title disks="$disk_warn")"
        impact HW-DISK-HEALTH.warn.impact
        action "" HW-DISK-HEALTH.warn.act.1
        action "sudo smartctl -H -A /dev/${bad_cmd}" HW-DISK-HEALTH.warn.act.2
        action "" HW-DISK-HEALTH.warn.act.3
        caution HW-DISK-HEALTH.warn.caution
    elif (( disk_read > 0 )); then
        finding OK HW-DISK-HEALTH "$(t HW-DISK-HEALTH.ok.title n="$disk_read")"
    fi
    (( disk_read > 0 )) && evidence "$(t HW-DISK-HEALTH.ev.1)" "${disk_lines%$'\n'}"
    if [[ -n "$disk_unread" ]]; then
        if [[ "$IS_ROOT" == 1 ]]; then
            partial HW-DISK-HEALTH "$(t HW-DISK-HEALTH.partial.2 disks="$disk_unread")"
        else
            partial HW-DISK-HEALTH "$(t HW-DISK-HEALTH.partial.1 disks="$disk_unread")"
        fi
    fi
fi

# ---- hardware errors in the kernel log ----------------------------------------------
# Only precise patterns are kept, whatever the priority of the message (a
# corrected memory error is logged below "err"): disk I/O errors, file system
# errors, machine checks and memory controller (EDAC) errors. The many
# messages logged at "err" by ACPI, firmware or drivers at every boot on
# healthy machines are left out on purpose. Errors of loop, CD and floppy
# devices (snaps, empty drives) are ignored.
if [[ "$hw_virt" =~ ^(lxc|lxc-libvirt|docker|podman|openvz|systemd-nspawn|rkt|wsl|proot|pouch)$ ]]; then
    :   # A container shares the host kernel: its log is not this system's.
elif ! have journalctl; then
    partial HW-KERNEL-ERRORS "$(t HW-KERNEL-ERRORS.partial.1)"
elif [[ -z "$(run journalctl -k -b 0 -q --no-pager -n 1 -o cat)" ]]; then
    partial HW-KERNEL-ERRORS "$(t HW-KERNEL-ERRORS.partial.2)"
else
    declare -A ke_re=()
    ke_re[io]='I/O error, dev |Buffer I/O error on dev|blk_update_request: (I/O|critical medium) error|critical medium error|Medium Error|ata[0-9.]+: failed command|nvme[0-9]+: I/O [0-9]+ .*timeout|nvme[0-9]+: controller is down'
    ke_re[fs]='EXT4-fs error|EXT4-fs \([^)]*\): (Remounting filesystem read-only|error count since last fsck)|BTRFS (error|critical)|XFS \([^)]*\): .*([Cc]orrupt|metadata I/O error|[Ff]ilesystem has been shut down)'
    ke_re[hw]='Machine check|mce: \[Hardware Error\]|\[Hardware Error\]|EDAC.* [0-9]+ (CE|UE) |EDAC.*([Uu]ncorrect|[Cc]orrected) (memory )?error'
    ke_re[oom]='[Oo]ut of memory: Kill'
    ke_skip='dev (loop|sr|fd|zram)[0-9]'
    declare -A ke_lines=() ke_count=()
    ke_boots=""
    for b in 0 -1; do
        log="$(run journalctl -k -b "$b" -q --no-pager -o short-iso)"
        [[ -n "$log" ]] || continue
        ke_boots+="$b "
        # The second field is the host name: not useful, and masked by --sanitize.
        log="$(sed -E 's/^([^ ]+) [^ ]+ /\1 /' <<<"$log" | grep -vE "$ke_skip")"
        for cat in io fs hw oom; do
            m="$(grep -E "${ke_re[$cat]}" <<<"$log")"
            [[ -n "$m" ]] || continue
            ke_count[$cat]=$(( ${ke_count[$cat]:-0} + $(grep -c . <<<"$m") ))
            # The last lines of each boot are the most relevant (bounded).
            ke_lines[$cat]+="$(tail -n 8 <<<"$m" | sed "s/^/[boot ${b}] /")"$'\n'
        done
    done
    ke_ev() {
        local cat="$1" key
        [[ -n "${ke_lines[$cat]:-}" ]] || return 0
        # lang-keys: HW-KERNEL-ERRORS.ev.io HW-KERNEL-ERRORS.ev.fs HW-KERNEL-ERRORS.ev.hw HW-KERNEL-ERRORS.ev.oom
        key="HW-KERNEL-ERRORS.ev.${cat}"
        evidence "$(t "$key" n="${ke_count[$cat]}")" "${ke_lines[$cat]%$'\n'}"
    }
    ke_kinds=""
    [[ -n "${ke_count[io]:-}" ]] && ke_kinds+="${ke_kinds:+, }$(t HW-KERNEL-ERRORS.kind.io)"
    [[ -n "${ke_count[fs]:-}" ]] && ke_kinds+="${ke_kinds:+, }$(t HW-KERNEL-ERRORS.kind.fs)"
    [[ -n "${ke_count[hw]:-}" ]] && ke_kinds+="${ke_kinds:+, }$(t HW-KERNEL-ERRORS.kind.hw)"
    ke_prev=1; [[ " $ke_boots " == *" -1 "* ]] || ke_prev=0
    if [[ -n "$ke_kinds" ]]; then
        finding WARNING HW-KERNEL-ERRORS "$(t HW-KERNEL-ERRORS.warn.title kinds="$ke_kinds")"
        impact HW-KERNEL-ERRORS.warn.impact
        action "journalctl -k -b 0 -p warning" HW-KERNEL-ERRORS.warn.act.1
        (( ke_prev == 1 )) && action "journalctl -k -b -1 -p warning" HW-KERNEL-ERRORS.warn.act.2
        action "" HW-KERNEL-ERRORS.warn.act.3
        caution HW-KERNEL-ERRORS.warn.caution
        ke_ev io; ke_ev fs; ke_ev hw; ke_ev oom
    elif [[ -n "${ke_count[oom]:-}" ]]; then
        finding INFO HW-KERNEL-ERRORS "$(t HW-KERNEL-ERRORS.oom.title n="${ke_count[oom]}")"
        impact HW-KERNEL-ERRORS.oom.impact
        action "journalctl -k -b 0 --grep 'Out of memory'" HW-KERNEL-ERRORS.oom.act.1
        ke_ev oom
    else
        if (( ke_prev == 1 )); then
            finding OK HW-KERNEL-ERRORS "$(t HW-KERNEL-ERRORS.ok.title)"
        else
            finding OK HW-KERNEL-ERRORS "$(t HW-KERNEL-ERRORS.ok.title_current)"
        fi
    fi
fi
