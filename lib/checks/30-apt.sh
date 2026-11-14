# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 30-apt.sh — package and repository hygiene.
#
# Catches the silent failure modes of APT:
#   - packages whose repository disappeared (no updates ever again, while
#     'apt upgrade' happily reports everything up to date);
#   - packages stuck on a third-party version higher than Ubuntu's, which
#     apt will never replace on its own;
#   - repositories disabled by a release upgrade, leftovers and duplicates;
#   - automatic security updates not running.
# Nothing here runs 'apt update': results are based on the current package
# lists, whose age is reported first.
#
# Texts: lib/lang/*/30-apt.lang (keys APT-*, section.30-apt).
# -----------------------------------------------------------------------------

section "$(t section.30-apt)"

# ---- freshness of package lists ------------------------------------------------
newest="$(find /var/lib/apt/lists -maxdepth 1 -name '*Release' -printf '%T@\n' 2>/dev/null | sort -rn | head -n1)"
if [[ -n "$newest" ]]; then
    APT_LISTS_AGE_DAYS=$(( ( $(date +%s) - ${newest%.*} ) / 86400 ))
    if (( APT_LISTS_AGE_DAYS > APT_LISTS_MAX_AGE )); then
        finding WARNING APT-LISTS-AGE "$(t APT-LISTS-AGE.warn.title days="$APT_LISTS_AGE_DAYS")"
        impact APT-LISTS-AGE.warn.impact
        action "sudo apt update" APT-LISTS-AGE.warn.act.1
        action "systemctl list-timers apt-daily.timer" APT-LISTS-AGE.warn.act.2
        caution APT-LISTS-AGE.warn.caution
    else
        finding OK APT-LISTS-AGE "$(t APT-LISTS-AGE.ok.title days="$APT_LISTS_AGE_DAYS")"
    fi
else
    partial APT-LISTS-AGE "$(t APT-LISTS-AGE.partial.1)"
fi

# ---- pending upgrades and holds ---------------------------------------------
n_upg=0; n_sec=0; phased=""
if upgradable="$(apt "${APT_RO[@]}" list --upgradable 2>/dev/null)"; then
    upgradable="$(grep -v '^Listing' <<<"$upgradable")"
    # Upgrades held back by Ubuntu's phased updates are listed by a simulated
    # upgrade (no root needed, nothing changed) under a dedicated header, as
    # indented lines of package names. They are reported apart and not counted
    # as pending. Older apt versions print no such header: nothing changes.
    if [[ -n "$upgradable" ]] && sim="$(run apt-get "${APT_RO[@]}" -s upgrade)"; then
        phased="$(awk '/^The following upgrades have been deferred due to phasing:$/ {f = 1; next}
                       f && /^[[:space:]]/ {for (i = 1; i <= NF; i++) print $i; next}
                       f {exit}' <<<"$sim")"
    fi
    if [[ -n "$phased" ]]; then
        # apt-get names foreign-architecture packages 'name:arch'; 'apt list'
        # prints the bare name, so the suffix is dropped before comparing.
        upgradable="$(awk -F/ 'NR==FNR {sub(/:.*/, ""); skip[$0] = 1; next} !($1 in skip)' <(printf '%s\n' "$phased") - <<<"$upgradable")"
    fi
    if [[ -n "$upgradable" ]]; then
        n_upg=$(wc -l <<<"$upgradable")
        n_sec=$(grep -c -- '-security' <<<"$upgradable")
    fi
    apt_list_ok=1
else
    apt_list_ok=0
fi
if (( apt_list_ok == 0 )); then
    partial APT-UPGRADES "$(t APT-UPGRADES.partial.1)"
elif (( n_sec > 0 )); then
    finding WARNING APT-SECURITY-UPGRADES "$(t APT-SECURITY-UPGRADES.warn.title n="$n_sec" total="$n_upg")"
    impact APT-SECURITY-UPGRADES.warn.impact
    action "apt list --upgradable" APT-SECURITY-UPGRADES.warn.act.1
    action "sudo apt upgrade" APT-SECURITY-UPGRADES.warn.act.2
    action "" APT-SECURITY-UPGRADES.warn.act.3
    caution APT-SECURITY-UPGRADES.warn.caution
    evidence "$(t APT-SECURITY-UPGRADES.ev.1)" "$upgradable"
elif (( n_upg > 0 )); then
    finding INFO APT-UPGRADES "$(t APT-UPGRADES.info.title n="$n_upg")"
    impact APT-UPGRADES.info.impact
    action "sudo apt upgrade" APT-UPGRADES.info.act.1
    evidence "$(t APT-UPGRADES.ev.1)" "$upgradable"
else
    finding OK APT-UPGRADES "$(t APT-UPGRADES.ok.title)"
fi
if [[ -n "$phased" ]]; then
    finding INFO APT-PHASED "$(t APT-PHASED.info.title n="$(wc -l <<<"$phased")")"
    impact APT-PHASED.info.impact
    evidence "$(t APT-PHASED.ev.1)" "$phased"
fi

held="$(apt-mark "${APT_RO[@]}" showhold 2>/dev/null)"
if [[ -n "$held" ]]; then
    finding WARNING APT-HELD "$(t APT-HELD.warn.title n="$(wc -l <<<"$held")")"
    impact APT-HELD.warn.impact
    action "apt-mark showhold" APT-HELD.warn.act.1
    action "sudo apt-mark unhold <package>" APT-HELD.warn.act.2
    caution APT-HELD.warn.caution
    evidence "$(t APT-HELD.ev.1)" "$held"
fi

# ---- packages whose installed version no repository offers ----------------------
# apt flags them "[installed,local]". This is broader than the '?obsolete'
# pattern, which misses packages stuck on a third-party version when Ubuntu
# still ships a package with the same name.
obsolete=(); obsolete_kernel=(); obsolete_other=()
if installed_list="$(apt "${APT_RO[@]}" list --installed 2>/dev/null)"; then
    installed_ok=1
    local_list="$(grep -E ',local\]$' <<<"$installed_list")"
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        # Packages the user chose to ignore (IGNORE_PACKAGES, validated names).
        [[ " ${IGNORE_PACKAGES} " == *" ${p} "* ]] && continue
        obsolete+=("$p")
        if [[ "$p" == linux-* ]]; then obsolete_kernel+=("$p"); else obsolete_other+=("$p"); fi
    done < <(cut -d/ -f1 <<<"$local_list")
else
    installed_ok=0
    partial APT-OBSOLETE "$(t APT-OBSOLETE.partial.1)"
fi

# Among non-kernel obsolete packages, separate those for which the configured
# repositories offer *another* version (stuck on a third-party build) from
# true orphans (no repository offers the package at all).
stuck=(); orphans=()
if (( ${#obsolete_other[@]} > 0 )); then
    mapfile -t in_repo < <(apt-cache "${APT_RO[@]}" madison "${obsolete_other[@]}" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$1); print $1}' | sort -u)
    for p in "${obsolete_other[@]}"; do
        if printf '%s\n' "${in_repo[@]}" | grep -qxF "$p"; then stuck+=("$p"); else orphans+=("$p"); fi
    done
fi

if (( ${#stuck[@]} > 0 )); then
    codename_cmd="$(safe_name "${OS_CODENAME:-}" "<codename>")"
    finding WARNING APT-STUCK-VERSION "$(t APT-STUCK-VERSION.warn.title n="${#stuck[@]}")"
    impact APT-STUCK-VERSION.warn.impact
    action "apt-cache policy <package>" APT-STUCK-VERSION.warn.act.1
    action "apt install --simulate --allow-downgrades <package>/${codename_cmd}" APT-STUCK-VERSION.warn.act.2
    action "sudo apt install --allow-downgrades <package>/${codename_cmd}" APT-STUCK-VERSION.warn.act.3
    caution APT-STUCK-VERSION.warn.caution
    evidence "$(t APT-STUCK-VERSION.ev.1)" "$(apt-cache "${APT_RO[@]}" policy "${stuck[@]}" 2>/dev/null)"
fi

if (( ${#orphans[@]} > 0 )); then
    finding WARNING APT-OBSOLETE "$(t APT-OBSOLETE.warn.title n="${#orphans[@]}")"
    impact APT-OBSOLETE.warn.impact
    action "apt purge --simulate <package>" APT-OBSOLETE.warn.act.1
    action "apt-cache policy <package>t64" APT-OBSOLETE.warn.act.2
    action "sudo apt purge <package>" APT-OBSOLETE.warn.act.3
    caution APT-OBSOLETE.warn.caution
    evidence "$(t APT-OBSOLETE.ev.1)" "$(awk -F/ 'NR==FNR {want[$0]=1; next} ($1 in want)' <(printf '%s\n' "${orphans[@]}") - <<<"$local_list")"
fi

if (( ${#obsolete_kernel[@]} > 0 )); then
    finding INFO APT-OBSOLETE-KERNEL "$(t APT-OBSOLETE-KERNEL.info.title n="${#obsolete_kernel[@]}")"
    impact APT-OBSOLETE-KERNEL.info.impact
    action "sudo apt remove --simulate <package>" APT-OBSOLETE-KERNEL.info.act.1
    action "sudo apt autoremove --simulate" APT-OBSOLETE-KERNEL.info.act.2
    caution APT-OBSOLETE-KERNEL.info.caution
    evidence "$(t APT-OBSOLETE-KERNEL.ev.1)" "$(printf '%s\n' "${obsolete_kernel[@]}")"
fi

(( installed_ok == 1 && ${#obsolete[@]} == 0 )) && finding OK APT-OBSOLETE "$(t APT-OBSOLETE.ok.title)"

# ---- residual configuration (removed packages whose config files remain) --------
residual="$(dpkg -l 2>/dev/null | awk '$1=="rc"{print $2}')"
if [[ -n "$residual" ]]; then
    finding INFO APT-RESIDUAL "$(t APT-RESIDUAL.info.title n="$(wc -l <<<"$residual")")"
    impact APT-RESIDUAL.info.impact
    action "apt purge --simulate '~c'" APT-RESIDUAL.info.act.1
    action "sudo apt purge '~c'" APT-RESIDUAL.info.act.2
    caution APT-RESIDUAL.info.caution
    evidence "$(t APT-RESIDUAL.ev.1)" "$residual"
fi

# ---- repositories ------------------------------------------------------------
# Official Ubuntu / Canonical archives (archive, security, ports, esm, ...).
is_official_uri() { [[ "$1" =~ ^https?://([a-z0-9-]+\.)*(ubuntu\.com|canonical\.com)(/|$) ]]; }

# Normalise every source entry, from both formats, to: status|file|uri|suite
repo_entries="$(
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        awk -v f="$f" '
            /^[[:space:]]*#?[[:space:]]*deb(-src)?[[:space:]]/ {
                status = ($0 ~ /^[[:space:]]*#/) ? "disabled" : "enabled"
                line = $0; sub(/^[[:space:]]*#?[[:space:]]*/, "", line); sub(/\[[^]]*\]/, "", line)
                n = split(line, a, " ")
                if (n >= 3) print status "|" f "|" a[2] "|" a[3]
            }' "$f"
    done
    for f in /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        awk -v f="$f" '
            BEGIN { RS = ""; FS = "\n" }
            {
                enabled = "yes"; uris = ""; suites = ""
                for (i = 1; i <= NF; i++) {
                    l = $i
                    if (l ~ /^#/) continue
                    v = l; sub(/^[^:]*:[ \t]*/, "", v)
                    if (tolower(l) ~ /^enabled:/) enabled = tolower(v)
                    if (tolower(l) ~ /^uris:/)    uris = v
                    if (tolower(l) ~ /^suites:/)  suites = v
                }
                if (uris == "") next
                n = split(uris, U, " "); m = split(suites, S, " ")
                for (a = 1; a <= n; a++) for (b = 1; b <= m; b++)
                    print (enabled == "no" ? "disabled" : "enabled") "|" f "|" U[a] "|" S[b]
            }' "$f"
    done
)"

# Only third-party entries matter here: commented-out official lines (deb-src,
# partner...) are normal in stock configurations.
disabled="$(grep '^disabled|' <<<"$repo_entries" | while IFS='|' read -r _ file uri suite; do
                is_official_uri "$uri" || printf '%s %s %s\n' "$file" "$uri" "$suite"
            done)"
if [[ -n "$disabled" ]]; then
    finding INFO APT-REPO-DISABLED "$(t APT-REPO-DISABLED.info.title n="$(wc -l <<<"$disabled")")"
    impact APT-REPO-DISABLED.info.impact
    action "" APT-REPO-DISABLED.info.act.1
    action "" APT-REPO-DISABLED.info.act.2
    evidence "$(t APT-REPO-DISABLED.ev.1)" "$disabled"
fi

leftovers="$(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.distUpgrade' -o -name '*.save' \
             -o -name '*.disabled' -o -name '*.dpkg-old' -o -name '*.dpkg-dist' -o -name '*.bak' \) 2>/dev/null | sort)"
if [[ -n "$leftovers" ]]; then
    finding INFO APT-REPO-LEFTOVER "$(t APT-REPO-LEFTOVER.info.title n="$(wc -l <<<"$leftovers")")"
    impact APT-REPO-LEFTOVER.info.impact
    action "ls -l /etc/apt/sources.list.d" APT-REPO-LEFTOVER.info.act.1
    action "sudo rm /etc/apt/sources.list.d/<file>" APT-REPO-LEFTOVER.info.act.2
    caution APT-REPO-LEFTOVER.info.caution
    evidence "$(t APT-REPO-LEFTOVER.ev.1)" "$leftovers"
fi

third_party=""
suite_mismatch=""
known_codenames="$(ubuntu-distro-info --all 2>/dev/null)"
[[ -z "$known_codenames" ]] && known_codenames="xenial bionic focal jammy kinetic lunar mantic noble oracular plucky questing resolute"
while IFS='|' read -r status file uri suite; do
    [[ "$status" == enabled ]] || continue
    base="${suite%%-*}"
    if ! is_official_uri "$uri"; then
        third_party+="${uri} ${suite} (${file})"$'\n'
    fi
    if [[ -n "$OS_CODENAME" && "$base" != "$OS_CODENAME" ]] && grep -qw -- "$base" <<<"$known_codenames"; then
        if is_official_uri "$uri"; then
            suite_mismatch+="OFFICIAL ${uri} ${suite} (${file})"$'\n'
        else
            suite_mismatch+="third-party ${uri} ${suite} (${file})"$'\n'
        fi
    fi
done <<<"$repo_entries"

if [[ -n "$third_party" ]]; then
    finding INFO APT-REPO-THIRDPARTY "$(t APT-REPO-THIRDPARTY.info.title n="$(grep -c . <<<"$third_party")")"
    impact APT-REPO-THIRDPARTY.info.impact
    action "" APT-REPO-THIRDPARTY.info.act.1
    evidence "$(t APT-REPO-THIRDPARTY.ev.1)" "${third_party%$'\n'}"
fi

if grep -q '^OFFICIAL' <<<"$suite_mismatch"; then
    finding CRITICAL APT-REPO-SUITE "$(t APT-REPO-SUITE.crit.title)"
    impact APT-REPO-SUITE.crit.impact
    action "" APT-REPO-SUITE.crit.act.1 codename="$OS_CODENAME"
    action "sudo apt update" APT-REPO-SUITE.crit.act.2
    action "apt-cache policy" APT-REPO-SUITE.crit.act.3 codename="$OS_CODENAME"
    caution APT-REPO-SUITE.crit.caution
    evidence "$(t APT-REPO-SUITE.ev.1)" "${suite_mismatch%$'\n'}"
elif [[ -n "$suite_mismatch" ]]; then
    finding INFO APT-REPO-SUITE "$(t APT-REPO-SUITE.info.title codename="$OS_CODENAME")"
    impact APT-REPO-SUITE.info.impact
    action "" APT-REPO-SUITE.info.act.1 codename="$OS_CODENAME"
    evidence "$(t APT-REPO-SUITE.ev.2)" "${suite_mismatch%$'\n'}"
fi

duplicates="$(grep '^enabled|' <<<"$repo_entries" | awk -F'|' '{k=$3" "$4; files[k]=files[k]" "$2; n[k]++} END {for (k in n) if (n[k]>1) print k " ->" files[k]}')"
if [[ -n "$duplicates" ]]; then
    finding INFO APT-REPO-DUPLICATE "$(t APT-REPO-DUPLICATE.info.title)"
    impact APT-REPO-DUPLICATE.info.impact
    action "" APT-REPO-DUPLICATE.info.act.1
    action "sudo apt update" APT-REPO-DUPLICATE.info.act.2
    caution APT-REPO-DUPLICATE.info.caution
    evidence "$(t APT-REPO-DUPLICATE.ev.1)" "$duplicates"
fi

# Keys in the legacy global keyring are trusted for every repository.
if [[ -s /etc/apt/trusted.gpg ]]; then
    finding INFO APT-LEGACY-KEYS "$(t APT-LEGACY-KEYS.info.title)"
    impact APT-LEGACY-KEYS.info.impact
    action "gpg --show-keys /etc/apt/trusted.gpg" APT-LEGACY-KEYS.info.act.1
    action "" APT-LEGACY-KEYS.info.act.2
    caution APT-LEGACY-KEYS.info.caution
fi

# ---- automatic security updates -------------------------------------------------
if pkg_installed unattended-upgrades; then
    uu="$(apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null | grep -o '"[0-9]*"' | tr -d '"')"
    if [[ "${uu:-0}" != 0 ]]; then
        finding OK APT-UNATTENDED "$(t APT-UNATTENDED.ok.title)"
    else
        finding WARNING APT-UNATTENDED "$(t APT-UNATTENDED.off.title)"
        impact APT-UNATTENDED.off.impact
        action "apt-config dump APT::Periodic::Unattended-Upgrade" APT-UNATTENDED.off.act.1
        action "sudo dpkg-reconfigure -plow unattended-upgrades" APT-UNATTENDED.off.act.2
    fi
    uu_log=/var/log/unattended-upgrades/unattended-upgrades.log
    if [[ -r "$uu_log" ]]; then
        last_run="$(grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' "$uu_log" | tail -n1)"
        if [[ -n "$last_run" ]]; then
            age=$(( ( $(date +%s) - $(date -d "$last_run" +%s) ) / 86400 ))
            if (( age > 7 )); then
                finding WARNING APT-UNATTENDED-LASTRUN "$(t APT-UNATTENDED-LASTRUN.warn.title days="$age" date="$last_run")"
                impact APT-UNATTENDED-LASTRUN.warn.impact
                action "systemctl list-timers apt-daily-upgrade.timer" APT-UNATTENDED-LASTRUN.warn.act.1
                action "sudo tail -n 50 /var/log/unattended-upgrades/unattended-upgrades.log" APT-UNATTENDED-LASTRUN.warn.act.2
                caution APT-UNATTENDED-LASTRUN.warn.caution
            fi
        fi
        uu_errors="$(tail -n 300 "$uu_log" | grep -E 'ERROR|WARNING' | tail -n 10)"
        if [[ -n "$uu_errors" ]]; then
            finding WARNING APT-UNATTENDED-ERRORS "$(t APT-UNATTENDED-ERRORS.warn.title)"
            impact APT-UNATTENDED-ERRORS.warn.impact
            action "sudo tail -n 50 /var/log/unattended-upgrades/unattended-upgrades.log" APT-UNATTENDED-ERRORS.warn.act.1
            action "sudo unattended-upgrade --dry-run --debug" APT-UNATTENDED-ERRORS.warn.act.2
            action "" APT-UNATTENDED-ERRORS.warn.act.3
            caution APT-UNATTENDED-ERRORS.warn.caution
            evidence "$(t APT-UNATTENDED-ERRORS.ev.1)" "$uu_errors"
        fi
    else
        partial APT-UNATTENDED-LASTRUN "$(t APT-UNATTENDED-LASTRUN.partial.1)"
    fi
else
    finding WARNING APT-UNATTENDED "$(t APT-UNATTENDED.missing.title)"
    impact APT-UNATTENDED.missing.impact
    action "apt-cache policy unattended-upgrades" APT-UNATTENDED.missing.act.1
    action "sudo apt install unattended-upgrades" APT-UNATTENDED.missing.act.2
fi

# ---- Ubuntu Pro security coverage ---------------------------------------------
# 'pro' writes logs and caches when run as root: run it as the audited user.
if have pro; then
    pro_out=""
    if [[ "$IS_ROOT" == 1 && "$TARGET_USER" == root ]]; then
        partial APT-PRO-STATUS "$(t APT-PRO-STATUS.partial.1)"
    else
        pro_out="$(as_target timeout "$CMD_TIMEOUT" pro security-status 2>/dev/null)"
    fi
    if [[ -n "$pro_out" ]]; then
        pro_detached=0
        grep -q 'NOT attached' <<<"$pro_out" && pro_detached=1
        finding INFO APT-PRO-STATUS "$(t APT-PRO-STATUS.info.title)"
        impact APT-PRO-STATUS.info.impact
        action "pro security-status" APT-PRO-STATUS.info.act.1
        (( pro_detached == 1 )) && action "" APT-PRO-STATUS.info.act.2
        evidence "$(t APT-PRO-STATUS.ev.1)" "$(grep -E 'packages|attached|until|esm' <<<"$pro_out")"
    fi
fi
