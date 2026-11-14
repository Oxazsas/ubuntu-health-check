# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 10-system.sh — operating system, support lifetime, pending reboot, clock,
# disk space.
#
# Texts: lib/lang/*/10-system.lang (keys SYS-*, section.10-system).
# -----------------------------------------------------------------------------

section "$(t section.10-system)"

# ---- OS identification and support lifetime ------------------------------------
# shellcheck source=/dev/null
. /etc/os-release 2>/dev/null
OS_CODENAME="${VERSION_CODENAME:-}"

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
    action "sudo apt autoremove --simulate" SYS-DISK.full.act.1
    action "sudo apt clean" SYS-DISK.full.act.2
    action "journalctl --disk-usage" SYS-DISK.full.act.3
    have docker && action "docker system df" SYS-DISK.full.act.4
    caution SYS-DISK.full.caution
done <<<"$disk_raw"
# No data must never become an OK.
if [[ -z "$disk_lines" ]]; then
    partial SYS-DISK "$(t SYS-DISK.partial.1)"
else
    (( disk_issue == 0 )) && finding OK SYS-DISK "$(t SYS-DISK.ok.title warn="$DISK_WARN")"
    evidence "$(t SYS-DISK.ev.1)" "${disk_lines%$'\n'}"
fi
