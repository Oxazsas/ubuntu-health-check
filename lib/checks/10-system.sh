# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 10-system.sh — operating system, support lifetime, pending reboot, clock,
# disk space, programs installed by hand in /usr/local.
#
# Texts: lib/lang/*/10-system.lang (keys SYS-*, section.10-system).
# -----------------------------------------------------------------------------

section "$(t section.10-system)"

# ---- OS identification and support lifetime ------------------------------------
# shellcheck source=/dev/null
. /etc/os-release 2>/dev/null
OS_CODENAME="${VERSION_CODENAME:-}"
# Version number (26.04...), read by 40-snap.sh for the channel branches.
# shellcheck disable=SC2034
OS_VERSION_ID="${VERSION_ID:-}"

if [[ "${ID:-}" != ubuntu ]]; then
    finding WARNING SYS-OS "$(t SYS-OS.other.title name="${PRETTY_NAME:-$(t ui.unknown)}")"
    impact SYS-OS.other.impact
    action "cat /etc/os-release" SYS-OS.other.act.1
    action "" SYS-OS.other.act.2
else
    finding OK SYS-OS "$(t SYS-OS.ok.title name="$PRETTY_NAME")"
fi

if [[ "${ID:-}" == ubuntu ]] && have ubuntu-distro-info && [[ -n "$OS_CODENAME" ]]; then
    days_left="$(ubuntu-distro-info --series="$OS_CODENAME" --days=eol 2>/dev/null)"
    if [[ "$days_left" =~ ^-?[0-9]+$ ]]; then
        eol_date="$(date -d "+${days_left} days" '+%Y-%m-%d')"
        if (( days_left < 0 )); then
            finding CRITICAL SYS-EOL "$(t SYS-EOL.ended.title codename="$OS_CODENAME")"
            impact SYS-EOL.ended.impact
            action "pro status" SYS-EOL.ended.act.1
            action "do-release-upgrade --check-dist-upgrade-only" SYS-EOL.ended.act.2
            caution SYS-EOL.ended.caution
        elif (( days_left < 180 )); then
            finding WARNING SYS-EOL "$(t SYS-EOL.soon.title codename="$OS_CODENAME" days="$days_left")"
            impact SYS-EOL.soon.impact date="$eol_date"
            action "do-release-upgrade --check-dist-upgrade-only" SYS-EOL.soon.act.1
            action "" SYS-EOL.soon.act.2
            caution SYS-EOL.soon.caution
        else
            finding OK SYS-EOL "$(t SYS-EOL.ok.title codename="$OS_CODENAME" date="$eol_date")"
        fi
    fi
    latest_lts="$(ubuntu-distro-info --lts 2>/dev/null)"
    if [[ -n "$latest_lts" && "$latest_lts" != "$OS_CODENAME" ]]; then
        finding INFO SYS-RELEASE "$(t SYS-RELEASE.info.title release="$latest_lts")"
        impact SYS-RELEASE.info.impact
        action "" SYS-RELEASE.info.act.1
        action "do-release-upgrade --check-dist-upgrade-only" SYS-RELEASE.info.act.2
    fi
else
    partial SYS-EOL "$(t SYS-EOL.partial.1)"
fi

# ---- pending reboot ----------------------------------------------------------
if [[ -f /var/run/reboot-required ]]; then
    finding WARNING SYS-REBOOT "$(t SYS-REBOOT.warn.title)"
    impact SYS-REBOOT.warn.impact
    action "" SYS-REBOOT.warn.act.1
    caution SYS-REBOOT.warn.caution
    evidence "$(t SYS-REBOOT.ev.1)" \
        "$(sort -u /var/run/reboot-required.pkgs 2>/dev/null)"
else
    finding OK SYS-REBOOT "$(t SYS-REBOOT.ok.title)"
fi

# ---- clock -------------------------------------------------------------------
if have timedatectl && tz="$(timedatectl show -p Timezone --value 2>/dev/null)" && [[ -n "$tz" ]]; then
    ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
    if [[ "$ntp" == yes ]]; then
        finding OK SYS-TIME "$(t SYS-TIME.ok.title tz="$tz")"
    else
        finding WARNING SYS-TIME "$(t SYS-TIME.warn.title tz="$tz")"
        impact SYS-TIME.warn.impact
        action "timedatectl timesync-status" SYS-TIME.warn.act.1
        action "sudo timedatectl set-ntp true" SYS-TIME.warn.act.2
        caution SYS-TIME.warn.caution
        evidence "$(t SYS-TIME.ev.1)" "$(timedatectl 2>/dev/null)"
    fi
else
    partial SYS-TIME "$(t SYS-TIME.partial.1)"
fi

# ---- what can be freed -------------------------------------------------------
# Only when a filesystem is above DISK_WARN. Each usual place is measured with
# a read-only command, then listed from the largest to the smallest. A place
# of at least 100 MiB gets its commands (reading first, then the one that
# frees the space); smaller ones are listed only. A place that cannot be read
# is reported as partial, never as empty.
# The places are measured for the whole computer, whichever filesystem holds
# them: the last action lists the largest folders of the full filesystem.

# disk_size KIB — a size in MiB or GiB, in the words of the language.
disk_size() {
    local mib=$(( $1 / 1024 ))
    if (( mib < 1024 )); then
        t SYS-DISK-USAGE.size.mib n="$mib"
    else
        t SYS-DISK-USAGE.size.gib int="$(( mib / 1024 ))" dec="$(( (mib % 1024) * 10 / 1024 ))"
    fi
}

# disk_usage_measure — fill du_items (sorted), du_lines and du_partials.
disk_usage_measure() {
    du_min=102400               # 100 MiB, in KiB
    du_items=""                 # lines: KIB <tab> place <tab> gain in KiB
    du_partials=()

    # Disabled snap revisions: snap keeps older revisions to allow 'snap
    # revert'; their files are readable by size without root (stat only).
    snaprev_n=0; snaprev_name=""; snaprev_rev=""
    if have snap && snap_all="$(run snap list --all)"; then
        snaprev_bytes=0
        while read -r sname srev; do
            [[ "$sname" =~ ^[a-z0-9][a-z0-9-]*$ && "$srev" =~ ^x?[0-9]+$ ]] || continue
            size="$(stat -c %s -- "/var/lib/snapd/snaps/${sname}_${srev}.snap" 2>/dev/null)" || continue
            snaprev_bytes=$(( snaprev_bytes + size ))
            snaprev_n=$(( snaprev_n + 1 )); snaprev_name="$sname"; snaprev_rev="$srev"
        done < <(awk 'NR>1 && $NF ~ /(^|,)disabled(,|$)/ {print $1, $3}' <<<"$snap_all")
        (( snaprev_n > 0 )) && du_items+="$(( snaprev_bytes / 1024 ))"$'\tsnaprev\t'"$(( snaprev_bytes / 1024 ))"$'\n'
    elif have snap; then
        du_partials+=("$(t SYS-DISK-USAGE.partial.snaprev)")
    fi

    # Snap data in the audited user's home, read with that user's privileges.
    if as_target test -d "${TARGET_HOME}/snap"; then
        kib="$(as_target timeout "${CMD_TIMEOUT:-30}" du -sxk -- "${TARGET_HOME}/snap" 2>/dev/null | awk '{print $1; exit}')"
        if [[ "$kib" =~ ^[0-9]+$ ]]; then
            du_items+="${kib}"$'\thome\t'"${kib}"$'\n'
        else
            du_partials+=("$(t SYS-DISK-USAGE.partial.home)")
        fi
    fi

    # Docker: what 'docker system df' reports as reclaimable (images,
    # containers, volumes and build cache that nothing uses). Docker prints
    # decimal units (kB, MB, GB).
    if have docker; then
        if docker_df="$(run docker system df --format '{{.Type}}\t{{.Reclaimable}}')"; then
            kib="$(awk -F'\t' '
                { v = $2; sub(/ .*/, "", v)
                  if (match(v, /^[0-9.]+/)) {
                      num = substr(v, 1, RLENGTH); u = substr(v, RLENGTH + 1); m = 1
                      if (u == "kB" || u == "KB") m = 1e3; else if (u == "MB") m = 1e6
                      else if (u == "GB") m = 1e9; else if (u == "TB") m = 1e12
                      s += num * m } }
                END { printf "%d\n", s / 1024 }' <<<"$docker_df")"
            du_items+="${kib}"$'\tdocker\t'"${kib}"$'\n'
        else
            du_partials+=("$(t SYS-DISK-USAGE.partial.docker)")
        fi
    fi

    # Kernels that apt would not keep: all but the running one and the two
    # newest installed (the newest is used after the next reboot, the one
    # before is kept by apt as a fallback). Every installed package whose name
    # carries their version is counted (image, modules, headers...).
    # Installed-Size is in KiB.
    krn_running="$(uname -r | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+')"
    krn_newest="$(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'linux-image-[0-9]*' 2>/dev/null \
                  | awk '$1=="installed"{print $2}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | sort -uV | tail -n2 | tr '\n' ' ')"
    read -r krn_kib krn_n < <(dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Installed-Size}\n' 'linux-*' 2>/dev/null \
        | awk -F'\t' -v r="$krn_running" -v l="$krn_newest" '
            $1 == "installed" && match($2, /[0-9]+\.[0-9]+\.[0-9]+-[0-9]+/) {
                a = substr($2, RSTART, RLENGTH)
                if (a != r && index(" " l, " " a " ") == 0) { s += $3; v[a] = 1 } }
            END { n = 0; for (k in v) n++; print s + 0, n }')
    (( ${krn_n:-0} > 0 )) && du_items+="${krn_kib}"$'\tkernel\t'"${krn_kib}"$'\n'

    # System journal. Without root, journalctl counts only the files the user
    # may read: the whole journal for members of adm or systemd-journal.
    if have journalctl; then
        if [[ "$IS_ROOT" != 1 && " $(id -nG) " != *" adm "* && " $(id -nG) " != *" systemd-journal "* ]]; then
            du_partials+=("$(t SYS-DISK-USAGE.partial.journal)")
        elif jsize="$(run journalctl --disk-usage | grep -oE 'take up [0-9.]+[BKMGTPE]' | awk '{print $3}')" && [[ -n "$jsize" ]]; then
            kib="$(awk -v v="$jsize" 'BEGIN {
                u = substr(v, length(v)); n = substr(v, 1, length(v) - 1); m = 1 / 1024
                if (u == "K") m = 1; else if (u == "M") m = 1024; else if (u == "G") m = 1048576
                else if (u == "T") m = 1073741824
                printf "%d\n", n * m }')"
            # Shrinking the journal to 100 MiB frees what is above that.
            gain=$(( kib > 102400 ? kib - 102400 : 0 ))
            du_items+="${kib}"$'\tjournal\t'"${gain}"$'\n'
        else
            du_partials+=("$(t SYS-DISK-USAGE.partial.journal)")
        fi
    fi

    # Downloaded package files kept by apt (its partial/ folder is private to
    # apt: du then fails on it but still prints the total).
    kib="$(run du -sxk /var/cache/apt/archives | awk '{print $1; exit}')"
    if [[ "$kib" =~ ^[0-9]+$ ]]; then
        du_items+="${kib}"$'\tapt\t'"${kib}"$'\n'
    else
        du_partials+=("$(t SYS-DISK-USAGE.partial.apt)")
    fi

    # ---- the finding, places sorted by size ----
    du_items="$(sort -t$'\t' -k1,1nr <<<"${du_items%$'\n'}" | grep -v '^$')"
    du_lines=""; du_big=0
    while IFS=$'\t' read -r kib place gain; do
        [[ -n "$place" ]] || continue
        # lang-keys: SYS-DISK-USAGE.item.snaprev SYS-DISK-USAGE.item.home SYS-DISK-USAGE.item.docker
        # lang-keys: SYS-DISK-USAGE.item.kernel SYS-DISK-USAGE.item.journal SYS-DISK-USAGE.item.apt
        item_key="SYS-DISK-USAGE.item.${place}"
        du_lines+="$(printf '%10s  %s' "$(disk_size "$kib")" \
            "$(t "$item_key" n="$snaprev_n" kernels="${krn_n:-0}")")"$'\n'
        (( gain >= du_min )) && du_big=1
    done <<<"$du_items"
}

# disk_usage_actions — the commands of each place of at least 100 MiB, attached
# to the last finding (the first full filesystem, so that they reach the
# action plan).
disk_usage_actions() {
    while IFS=$'\t' read -r kib place gain; do
        [[ -n "$place" ]] || continue
        (( gain >= du_min )) || continue
        size="$(disk_size "$kib")"
        case "$place" in
            snaprev)
                rev_cmd="<name> --revision=<revision>"
                (( snaprev_n == 1 )) && rev_cmd="$(safe_name "$snaprev_name" "<name>") --revision=$(safe_name "$snaprev_rev" "<revision>")"
                action "snap list --all" SYS-DISK-USAGE.snaprev.act.1 size="$size" n="$snaprev_n"
                action "sudo snap remove ${rev_cmd}" SYS-DISK-USAGE.snaprev.act.2
                action "sudo snap set system refresh.retain=2" SYS-DISK-USAGE.snaprev.act.3 ;;
            home)
                action "du -sh ~/snap/* | sort -h" SYS-DISK-USAGE.home.act.1 size="$size"
                action "" SYS-DISK-USAGE.home.act.2 ;;
            docker)
                action "docker system df -v" SYS-DISK-USAGE.docker.act.1 size="$size"
                action "docker system prune" SYS-DISK-USAGE.docker.act.2 ;;
            kernel)
                action "sudo apt autoremove --simulate" SYS-DISK-USAGE.kernel.act.1 size="$size" kernels="$krn_n"
                action "sudo apt autoremove --purge" SYS-DISK-USAGE.kernel.act.2 ;;
            journal)
                action "journalctl --disk-usage" SYS-DISK-USAGE.journal.act.1 size="$size"
                action "sudo journalctl --vacuum-size=100M" SYS-DISK-USAGE.journal.act.2 gain="$(disk_size "$gain")" ;;
            apt)
                action "du -sh /var/cache/apt/archives" SYS-DISK-USAGE.apt.act.1 size="$size"
                action "sudo apt clean" SYS-DISK-USAGE.apt.act.2 ;;
        esac
    done <<<"$du_items"
    # disk_first is one of the fixed mount points checked above.
    action "sudo du -xh --max-depth=1 ${disk_first} | sort -h" SYS-DISK-USAGE.info.act.other target="$disk_first"
    caution SYS-DISK-USAGE.info.caution
}

# ---- disk space --------------------------------------------------------------
# Check the filesystems that matter for updates: /, /boot, /boot/efi, /var,
# /home and Docker's data directory when they are separate mounts.
# Note: 'df -P' and '--output' are mutually exclusive; --output alone gives a
# stable, unwrapped format.
# The proposed actions are generic and safe (simulation or read-only first);
# the Docker one is only offered where Docker is installed.
disk_issue=0
disk_lines=""
disk_first=""
disk_raw="$(df --output=pcent,target / /boot /boot/efi /var /home /var/lib/docker 2>/dev/null | tail -n +2 | sort -u -k2,2)"
while read -r pcent target; do
    used="${pcent%\%}"
    [[ "$used" =~ ^[0-9]+$ ]] || continue
    disk_lines+="${target} ${pcent}"$'\n'
    if (( used >= DISK_CRIT )); then
        finding CRITICAL SYS-DISK "$(t SYS-DISK.crit.title target="$target" pcent="$pcent")"
        impact SYS-DISK.crit.impact target="$target"
        disk_issue=1
    elif (( used >= DISK_WARN )); then
        finding WARNING SYS-DISK "$(t SYS-DISK.warn.title target="$target" pcent="$pcent")"
        impact SYS-DISK.warn.impact target="$target"
        disk_issue=1
    else
        continue
    fi
    # The same actions apply to every full filesystem: they are listed once,
    # under the first one, and the others refer to it.
    if [[ -n "$disk_first" ]]; then
        action "" SYS-DISK.full.act.same target="$disk_first"
        continue
    fi
    disk_first="$target"
    # Commands with their measured gain; the generic list is kept for when
    # the measured breakdown (SYS-DISK-USAGE, below) is silenced.
    if ! is_ignored SYS-DISK-USAGE; then
        disk_usage_measure </dev/null
        disk_usage_actions
    else
        action "sudo apt autoremove --simulate" SYS-DISK.full.act.1
        action "sudo apt clean" SYS-DISK.full.act.2
        action "journalctl --disk-usage" SYS-DISK.full.act.3
        have docker && action "docker system df" SYS-DISK.full.act.4
        caution SYS-DISK.full.caution
    fi
done <<<"$disk_raw"
# No data must never become an OK.
if [[ -z "$disk_lines" ]]; then
    partial SYS-DISK "$(t SYS-DISK.partial.1)"
else
    (( disk_issue == 0 )) && finding OK SYS-DISK "$(t SYS-DISK.ok.title warn="$DISK_WARN")"
    evidence "$(t SYS-DISK.ev.1)" "${disk_lines%$'\n'}"
fi

# ---- what takes space (measured above, for the first full filesystem) --------
if (( disk_issue == 1 )) && ! is_ignored SYS-DISK-USAGE; then
    finding INFO SYS-DISK-USAGE "$(t SYS-DISK-USAGE.info.title)"
    if (( du_big == 1 )); then
        impact SYS-DISK-USAGE.info.impact warn="$DISK_WARN"
    else
        impact SYS-DISK-USAGE.none.impact warn="$DISK_WARN"
    fi
    evidence "$(t SYS-DISK-USAGE.ev.1)" "${du_lines%$'\n'}"
    for p in "${du_partials[@]}"; do partial SYS-DISK-USAGE "$p"; done
fi

# ---- programs installed by hand in /usr/local -----------------------------------
# Executable files and links directly in /usr/local/bin and /usr/local/sbin
# that no package owns: nothing updates them. An inventory to review, without
# judgement. Only names, sizes, dates and link targets are read, never the
# contents. A single 'dpkg -S' call covers all the files.
mapfile -t lb_lines < <(find /usr/local/bin /usr/local/sbin -mindepth 1 -maxdepth 1 \
    \( -type f -perm /111 -o -type l \) -printf '%p\t%s\t%TY-%Tm-%Td\t%l\n' 2>/dev/null | sort | head -n 200)
if (( ${#lb_lines[@]} > 0 )); then
    if ! have dpkg; then
        partial SYS-LOCAL-BIN "$(t SYS-LOCAL-BIN.partial.1)"
    else
        lb_paths=(); for l in "${lb_lines[@]}"; do lb_paths+=("${l%%$'\t'*}"); done
        # dpkg -S prints "package(s): path" for the files it knows (and
        # "diversion by ..." lines, skipped); unknown files go to stderr.
        lb_owned="$(dpkg -S -- "${lb_paths[@]}" 2>/dev/null | grep -v '^diversion ' | sed -n 's/^[^:]*: //p')"
        lb_list=""; lb_n=0
        for l in "${lb_lines[@]}"; do
            IFS=$'\t' read -r lb_path lb_size lb_date lb_target <<<"$l"
            grep -qxF -- "$lb_path" <<<"$lb_owned" && continue
            lb_n=$((lb_n + 1))
            if [[ -n "$lb_target" ]]; then
                lb_list+="$(t SYS-LOCAL-BIN.ev.link path="$lb_path" date="$lb_date" target="$lb_target")"$'\n'
            else
                lb_list+="$(t SYS-LOCAL-BIN.ev.file path="$lb_path" size="$lb_size" date="$lb_date")"$'\n'
            fi
        done
        if (( lb_n > 0 )); then
            finding INFO SYS-LOCAL-BIN "$(t SYS-LOCAL-BIN.info.title n="$lb_n")"
            impact SYS-LOCAL-BIN.info.impact
            action "ls -l /usr/local/bin /usr/local/sbin" SYS-LOCAL-BIN.info.act.1
            action "" SYS-LOCAL-BIN.info.act.2
            evidence "$(t SYS-LOCAL-BIN.ev.1)" "${lb_list%$'\n'}"
        fi
    fi
fi
