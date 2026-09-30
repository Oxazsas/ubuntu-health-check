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
# -----------------------------------------------------------------------------

section "APT packages and repositories"

# ---- freshness of package lists ------------------------------------------------
newest="$(find /var/lib/apt/lists -maxdepth 1 -name '*Release' -printf '%T@\n' 2>/dev/null | sort -rn | head -n1)"
if [[ -n "$newest" ]]; then
    APT_LISTS_AGE_DAYS=$(( ( $(date +%s) - ${newest%.*} ) / 86400 ))
    if (( APT_LISTS_AGE_DAYS > APT_LISTS_MAX_AGE )); then
        finding WARNING APT-LISTS-AGE "Package lists are ${APT_LISTS_AGE_DAYS} days old" \
            "Results below may be outdated, and it suggests automatic updates are not running. Refresh with 'sudo apt update' (safe, changes no package) and re-run the audit."
    else
        finding OK APT-LISTS-AGE "Package lists refreshed ${APT_LISTS_AGE_DAYS} day(s) ago"
    fi
else
    partial APT-LISTS-AGE "package list age unknown (no Release files in /var/lib/apt/lists)"
fi

# ---- pending upgrades and holds ---------------------------------------------
n_upg=0; n_sec=0
if upgradable="$(apt "${APT_RO[@]}" list --upgradable 2>/dev/null)"; then
    upgradable="$(grep -v '^Listing' <<<"$upgradable")"
    if [[ -n "$upgradable" ]]; then
        n_upg=$(wc -l <<<"$upgradable")
        n_sec=$(grep -c -- '-security' <<<"$upgradable")
    fi
    apt_list_ok=1
else
    apt_list_ok=0
fi
if (( apt_list_ok == 0 )); then
    partial APT-UPGRADES "pending upgrades not checked ('apt list' failed)"
elif (( n_sec > 0 )); then
    finding WARNING APT-SECURITY-UPGRADES "${n_sec} security update(s) pending (${n_upg} upgrades in total)" \
        "Security updates are normally applied automatically within a day. If they accumulate, check unattended-upgrades (see below)."
    evidence "apt list --upgradable" "$upgradable"
elif (( n_upg > 0 )); then
    finding INFO APT-UPGRADES "${n_upg} non-security upgrade(s) pending"
    evidence "apt list --upgradable" "$upgradable"
else
    finding OK APT-UPGRADES "No pending upgrades"
fi

held="$(apt-mark "${APT_RO[@]}" showhold 2>/dev/null)"
if [[ -n "$held" ]]; then
    finding WARNING APT-HELD "$(wc -l <<<"$held") package(s) on hold (never upgraded)" \
        "A hold is sometimes intentional, but a forgotten one blocks security fixes. Review with 'apt-mark showhold'."
    evidence "Held packages" "$held"
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
    partial APT-OBSOLETE "installed package origins not checked ('apt list --installed' failed)"
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
    finding WARNING APT-STUCK-VERSION "${#stuck[@]} package(s) stuck on a version from a removed or disabled repository" \
        "The installed version comes from a source that is no longer configured (typically a PPA or vendor repository disabled by a release upgrade), and the official repositories offer a different version. Because the installed version number is often higher, apt never replaces it and it receives no updates. Fix: 'apt install --simulate --allow-downgrades <pkg>/${OS_CODENAME:-<codename>}', check that nothing is removed, then run it for real."
    evidence "Installed vs available versions (apt-cache policy)" "$(apt-cache "${APT_RO[@]}" policy "${stuck[@]}" 2>/dev/null)"
fi

if (( ${#orphans[@]} > 0 )); then
    finding WARNING APT-OBSOLETE "${#orphans[@]} package(s) no longer available from any repository" \
        "These packages will never receive updates: leftovers of a previous release, a .deb installed by hand, or a removed repository. Do not remove them blindly: other packages may depend on them. Always simulate first ('apt purge --simulate <pkg>') and stop if core desktop packages appear. For libraries renamed in newer releases (suffix t64 on 24.04+), install the successor instead, which replaces the old one cleanly."
    evidence "Obsolete packages" "$(awk -F/ 'NR==FNR {want[$0]=1; next} ($1 in want)' <(printf '%s\n' "${orphans[@]}") - <<<"$local_list")"
fi

if (( ${#obsolete_kernel[@]} > 0 )); then
    finding INFO APT-OBSOLETE-KERNEL "${#obsolete_kernel[@]} obsolete kernel-related package(s)" \
        "Old kernels, headers and metapackages from earlier releases. If the kernel metapackage check is OK, they can be removed once the current kernel is validated (remove the obsolete metapackage, then 'apt autoremove', simulating first)."
    evidence "Obsolete kernel packages" "$(printf '%s\n' "${obsolete_kernel[@]}")"
fi

(( installed_ok == 1 && ${#obsolete[@]} == 0 )) && finding OK APT-OBSOLETE "Every installed package version is available from a configured repository"

# ---- residual configuration (removed packages whose config files remain) --------
residual="$(dpkg -l 2>/dev/null | awk '$1=="rc"{print $2}')"
if [[ -n "$residual" ]]; then
    finding INFO APT-RESIDUAL "$(wc -l <<<"$residual") removed package(s) with leftover configuration files" \
        "Harmless but clutters the system. Review then clean with 'apt purge --simulate ~c' and 'sudo apt purge ~c' (quote the ~c)."
    evidence "Packages in 'rc' state" "$residual"
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
    finding INFO APT-REPO-DISABLED "Disabled third-party repository entries: $(wc -l <<<"$disabled")" \
        "Release upgrades disable third-party repositories. Packages installed from them stop updating (see obsolete / stuck packages). Either re-enable the repository for the current release, or remove the packages and the entry."
    evidence "Disabled entries (file, URI, suite)" "$disabled"
fi

leftovers="$(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.distUpgrade' -o -name '*.save' \
             -o -name '*.disabled' -o -name '*.dpkg-old' -o -name '*.dpkg-dist' -o -name '*.bak' \) 2>/dev/null | sort)"
if [[ -n "$leftovers" ]]; then
    finding INFO APT-REPO-LEFTOVER "$(wc -l <<<"$leftovers") leftover file(s) in sources.list.d" \
        "Backups created by release upgrades or manual edits. Ignored by apt, safe to delete once reviewed."
    evidence "Leftover files" "$leftovers"
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
    finding INFO APT-REPO-THIRDPARTY "Enabled third-party repository entries: $(grep -c . <<<"$third_party")" \
        "Each one can install or replace packages with root privileges: keep only vendors you trust and still use."
    evidence "Enabled third-party repositories" "${third_party%$'\n'}"
fi

if grep -q '^OFFICIAL' <<<"$suite_mismatch"; then
    finding CRITICAL APT-REPO-SUITE "Official Ubuntu repositories from another release are enabled" \
        "Mixing releases breaks dependencies and can partially upgrade or downgrade the system. Fix the suite names to '${OS_CODENAME}'."
    evidence "Mismatching entries" "${suite_mismatch%$'\n'}"
elif [[ -n "$suite_mismatch" ]]; then
    finding INFO APT-REPO-SUITE "Third-party repositories using another release name than '${OS_CODENAME}'" \
        "Some vendors publish a single suite for all releases (this is expected for Signal, for example). Otherwise, check whether the vendor offers packages for '${OS_CODENAME}'."
    evidence "Entries" "${suite_mismatch%$'\n'}"
fi

duplicates="$(grep '^enabled|' <<<"$repo_entries" | awk -F'|' '{k=$3" "$4; files[k]=files[k]" "$2; n[k]++} END {for (k in n) if (n[k]>1) print k " ->" files[k]}')"
if [[ -n "$duplicates" ]]; then
    finding INFO APT-REPO-DUPLICATE "Repository declared more than once" \
        "apt warns about targets configured multiple times, and conflicting Signed-By options can break 'apt update'. Keep a single file per repository (prefer the .sources format)."
    evidence "Duplicates (URI suite -> files)" "$duplicates"
fi

# Keys in the legacy global keyring are trusted for every repository.
if [[ -s /etc/apt/trusted.gpg ]]; then
    finding INFO APT-LEGACY-KEYS "Legacy global APT keyring in use (/etc/apt/trusted.gpg)" \
        "Keys stored there can sign packages for any repository. Modern practice is one key per repository, referenced with Signed-By."
fi

# ---- automatic security updates -------------------------------------------------
if pkg_installed unattended-upgrades; then
    uu="$(apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null | grep -o '"[0-9]*"' | tr -d '"')"
    if [[ "${uu:-0}" != 0 ]]; then
        finding OK APT-UNATTENDED "Automatic security updates enabled"
    else
        finding WARNING APT-UNATTENDED "unattended-upgrades is installed but disabled" \
            "Security updates are not applied automatically. Enable with 'sudo dpkg-reconfigure -plow unattended-upgrades'."
    fi
    uu_log=/var/log/unattended-upgrades/unattended-upgrades.log
    if [[ -r "$uu_log" ]]; then
        last_run="$(grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' "$uu_log" | tail -n1)"
        if [[ -n "$last_run" ]]; then
            age=$(( ( $(date +%s) - $(date -d "$last_run" +%s) ) / 86400 ))
            if (( age > 7 )); then
                finding WARNING APT-UNATTENDED-LASTRUN "Last unattended-upgrades run was ${age} days ago (${last_run})" \
                    "It should run daily. Check 'systemctl list-timers apt-daily-upgrade.timer' and the log."
            fi
        fi
        uu_errors="$(tail -n 300 "$uu_log" | grep -E 'ERROR|WARNING' | tail -n 10)"
        if [[ -n "$uu_errors" ]]; then
            finding WARNING APT-UNATTENDED-ERRORS "Recent errors in the unattended-upgrades log" \
                "Some automatic updates may have failed."
            evidence "Last errors/warnings" "$uu_errors"
        fi
    else
        partial APT-UNATTENDED-LASTRUN "unattended-upgrades log not readable (run with sudo)"
    fi
else
    finding WARNING APT-UNATTENDED "unattended-upgrades is not installed" \
        "Security updates depend on manual action. Install it with 'sudo apt install unattended-upgrades'."
fi

# ---- Ubuntu Pro security coverage ---------------------------------------------
# 'pro' writes logs and caches when run as root: run it as the audited user.
if have pro; then
    pro_out=""
    if [[ "$IS_ROOT" == 1 && "$TARGET_USER" == root ]]; then
        partial APT-PRO-STATUS "pro security-status skipped (would write logs as root; run via sudo from a regular account)"
    else
        pro_out="$(as_target timeout "$CMD_TIMEOUT" pro security-status 2>/dev/null)"
    fi
    if [[ -n "$pro_out" ]]; then
        extra=""
        grep -q 'NOT attached' <<<"$pro_out" && \
            extra=" Ubuntu Pro (free for personal use on up to 5 machines) adds security fixes for Universe packages and kernel livepatching."
        finding INFO APT-PRO-STATUS "Security coverage summary (pro security-status)" \
            "Packages from Universe/Multiverse only get community fixes; third-party and unavailable packages get none from Ubuntu.${extra}"
        evidence "pro security-status" "$(grep -E 'packages|attached|until|esm' <<<"$pro_out")"
    fi
fi
