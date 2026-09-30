# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 10-system.sh — operating system, support lifetime, pending reboot, clock,
# disk space.
# -----------------------------------------------------------------------------

section "System"

# ---- OS identification and support lifetime ------------------------------------
# shellcheck source=/dev/null
. /etc/os-release 2>/dev/null
OS_CODENAME="${VERSION_CODENAME:-}"

if [[ "${ID:-}" != ubuntu ]]; then
    finding WARNING SYS-OS "Not an Ubuntu system (${PRETTY_NAME:-unknown})" \
        "This tool targets Ubuntu. Many checks still work on Debian-based systems, but support dates and some package names may not apply."
else
    finding OK SYS-OS "${PRETTY_NAME}"
fi

if [[ "${ID:-}" == ubuntu ]] && have ubuntu-distro-info && [[ -n "$OS_CODENAME" ]]; then
    days_left="$(ubuntu-distro-info --series="$OS_CODENAME" --days=eol 2>/dev/null)"
    if [[ "$days_left" =~ ^-?[0-9]+$ ]]; then
        eol_date="$(date -d "+${days_left} days" '+%Y-%m-%d')"
        if (( days_left < 0 )); then
            finding CRITICAL SYS-EOL "Release ${OS_CODENAME} is no longer supported (standard support ended)" \
                "No more security updates are published for this release without Ubuntu Pro (ESM). Plan a release upgrade or attach Ubuntu Pro."
        elif (( days_left < 180 )); then
            finding WARNING SYS-EOL "Standard support for ${OS_CODENAME} ends in ${days_left} days" \
                "Plan the upgrade to a newer release before security updates stop."
        else
            finding OK SYS-EOL "Standard support for ${OS_CODENAME} until ${eol_date}"
        fi
    fi
    latest_lts="$(ubuntu-distro-info --lts 2>/dev/null)"
    if [[ -n "$latest_lts" && "$latest_lts" != "$OS_CODENAME" ]]; then
        finding INFO SYS-RELEASE "A newer LTS release is available (${latest_lts})" \
            "Not urgent while the current release is supported. Clean up obsolete packages and third-party repositories before any release upgrade: they are the usual cause of failed upgrades."
    fi
else
    partial SYS-EOL "support end date not checked (ubuntu-distro-info unavailable)"
fi

# ---- pending reboot ----------------------------------------------------------
if [[ -f /var/run/reboot-required ]]; then
    finding WARNING SYS-REBOOT "A reboot is required to finish applying updates" \
        "Security fixes (often kernel or core libraries) are installed but not active until the next reboot."
    evidence "Packages requesting the reboot (/var/run/reboot-required.pkgs)" \
        "$(sort -u /var/run/reboot-required.pkgs 2>/dev/null)"
else
    finding OK SYS-REBOOT "No reboot pending"
fi

# ---- clock -------------------------------------------------------------------
if have timedatectl && tz="$(timedatectl show -p Timezone --value 2>/dev/null)" && [[ -n "$tz" ]]; then
    ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
    if [[ "$ntp" == yes ]]; then
        finding OK SYS-TIME "Clock synchronised (time zone ${tz})"
    else
        finding WARNING SYS-TIME "Clock is not synchronised with NTP (time zone ${tz})" \
            "A drifting clock breaks TLS certificate checks and makes logs unreliable during an incident."
        evidence "timedatectl" "$(timedatectl 2>/dev/null)"
    fi
else
    partial SYS-TIME "clock synchronisation not checked (timedatectl unavailable or no systemd)"
fi

# ---- disk space --------------------------------------------------------------
# Check the filesystems that matter for updates: /, /boot, /boot/efi, /var,
# /home and Docker's data directory when they are separate mounts.
# Note: 'df -P' and '--output' are mutually exclusive; --output alone gives a
# stable, unwrapped format.
disk_issue=0
disk_lines=""
disk_raw="$(df --output=pcent,target / /boot /boot/efi /var /home /var/lib/docker 2>/dev/null | tail -n +2 | sort -u -k2,2)"
while read -r pcent target; do
    used="${pcent%\%}"
    [[ "$used" =~ ^[0-9]+$ ]] || continue
    disk_lines+="${target} ${pcent}"$'\n'
    if (( used >= DISK_CRIT )); then
        finding CRITICAL SYS-DISK "Filesystem ${target} is ${pcent} full" \
            "Updates, logs and containers fail when a filesystem is full. Free space urgently (old kernels, Docker images, logs, caches)."
        disk_issue=1
    elif (( used >= DISK_WARN )); then
        finding WARNING SYS-DISK "Filesystem ${target} is ${pcent} full" \
            "Consider freeing space before it becomes critical (old kernels, Docker images with 'docker system df', journal logs)."
        disk_issue=1
    fi
done <<<"$disk_raw"
# No data must never become an OK.
if [[ -z "$disk_lines" ]]; then
    partial SYS-DISK "disk usage could not be read (df failed)"
else
    (( disk_issue == 0 )) && finding OK SYS-DISK "Disk usage below ${DISK_WARN}% on system filesystems"
    evidence "Usage of system filesystems" "${disk_lines%$'\n'}"
fi
