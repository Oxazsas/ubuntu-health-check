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
#   - repository signing keys that expired (apt then refuses the updates);
#   - automatic security updates not running, and third-party repositories
#     they leave out.
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

# Normalise every source entry, from both formats, to:
#   status|file|uri|suite|signed-by
# signed-by is the Signed-By value (keyring paths or fingerprints, separated
# by spaces; empty when not set). A key written in the .sources file itself
# is copied to a file of the private temporary directory (it is a public key)
# and named "inline:<that file>", so that its expiry date can be read.
apt_inline_dir="${WORK_DIR}/apt-inline-keys"
mkdir -m 700 -- "$apt_inline_dir" 2>/dev/null || apt_inline_dir=""
repo_entries="$(
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        awk -v f="$f" '
            /^[[:space:]]*#?[[:space:]]*deb(-src)?[[:space:]]/ {
                status = ($0 ~ /^[[:space:]]*#/) ? "disabled" : "enabled"
                line = $0; sub(/^[[:space:]]*#?[[:space:]]*/, "", line)
                sb = ""
                if (match(line, /\[[^]]*\]/)) {
                    k = split(substr(line, RSTART + 1, RLENGTH - 2), o, /[ \t]+/)
                    for (j = 1; j <= k; j++)
                        if (tolower(o[j]) ~ /^signed-by=/) { sb = substr(o[j], 11); gsub(/,/, " ", sb) }
                }
                sub(/\[[^]]*\]/, "", line)
                n = split(line, a, " ")
                if (n >= 3) print status "|" f "|" a[2] "|" a[3] "|" sb
            }' "$f"
    done
    for f in /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        awk -v f="$f" -v kd="$apt_inline_dir" '
            BEGIN { RS = ""; FS = "\n" }
            {
                enabled = "yes"; uris = ""; suites = ""; sb = ""; insb = 0; blk = ""
                for (i = 1; i <= NF; i++) {
                    l = $i
                    if (l ~ /^#/) continue
                    # Continuation lines: only those of Signed-By are kept
                    # (a list of keyrings, or a key block where "." stands
                    # for an empty line).
                    if (l ~ /^[ \t]/) {
                        if (insb) { c = l; sub(/^[ \t]/, "", c); if (c == ".") c = ""; blk = blk c "\n" }
                        continue
                    }
                    insb = 0
                    v = l; sub(/^[^:]*:[ \t]*/, "", v)
                    if (tolower(l) ~ /^enabled:/) enabled = tolower(v)
                    if (tolower(l) ~ /^uris:/)    uris = v
                    if (tolower(l) ~ /^suites:/)  suites = v
                    if (tolower(l) ~ /^signed-by:/) { sb = v; insb = 1 }
                }
                if (uris == "") next
                if (blk ~ /-----BEGIN PGP PUBLIC KEY BLOCK-----/) {
                    sb = "inline:"
                    if (kd != "") {
                        b = f; sub(/.*\//, "", b); gsub(/[^A-Za-z0-9._-]/, "_", b)
                        out = kd "/" b "-" NR ".asc"
                        printf "%s", blk > out; close(out)
                        sb = "inline:" out
                    }
                } else if (blk != "") {
                    gsub(/[ \t\n]+/, " ", blk); sb = sb " " blk
                }
                gsub(/[ \t]+/, " ", sb); sub(/^ /, "", sb); sub(/ $/, "", sb)
                n = split(uris, U, " "); m = split(suites, S, " ")
                for (a = 1; a <= n; a++) for (b = 1; b <= m; b++)
                    print (enabled == "no" ? "disabled" : "enabled") "|" f "|" U[a] "|" S[b] "|" sb
            }' "$f"
    done
)"

# Only third-party entries matter here: commented-out official lines (deb-src,
# partner...) are normal in stock configurations.
disabled="$(grep '^disabled|' <<<"$repo_entries" | while IFS='|' read -r _ file uri suite _; do
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
while IFS='|' read -r status file uri suite _; do
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

# ---- expired repository signing keys ------------------------------------------
# apt refuses the updates of a repository whose signing key has expired. The
# keyrings named by Signed-By in the enabled entries are read, and the global
# ones (trusted.gpg.d, trusted.gpg), used by the entries without Signed-By.
# gpg only lists the keys (--show-keys imports nothing): its home is a folder
# of the private temporary directory, so nothing is written elsewhere, and
# --no-autostart keeps it from starting gpg-agent, dirmngr or keyboxd.
# A key is counted as expired when it can no longer sign: the primary key has
# expired, or it cannot sign itself and all its signing subkeys have expired
# (an expired subkey next to a valid one is normal key rotation). Revoked keys
# are not examined.
if ! have gpg; then
    partial APT-KEY-EXPIRED "$(t APT-KEY-EXPIRED.partial.1)"
else
    declare -A key_users=()
    global_users=""
    while IFS='|' read -r status file uri suite signed; do
        [[ "$status" == enabled ]] || continue
        used=0
        read -ra signed_list <<<"$signed"
        for kr in "${signed_list[@]}"; do
            # A fingerprint selects a key of the global keyrings.
            if [[ "$kr" == /* || "$kr" == inline:* ]]; then
                key_users[$kr]+="${uri} ${suite}"$'\n'
                used=1
            fi
        done
        (( used == 1 )) || global_users+="${uri} ${suite}"$'\n'
    done <<<"$repo_entries"
    keyrings=("${!key_users[@]}")
    for kr in /etc/apt/trusted.gpg.d/*.gpg /etc/apt/trusted.gpg.d/*.asc /etc/apt/trusted.gpg; do
        [[ -f "$kr" && -z "${key_users[$kr]+x}" ]] || continue
        keyrings+=("$kr")
        key_users[$kr]="$global_users"
    done
    mapfile -t keyrings < <(printf '%s\n' "${keyrings[@]}" | grep . | sort -u)

    gpg_home="${WORK_DIR}/gnupg"
    mkdir -m 700 -- "$gpg_home" 2>/dev/null
    now_s="$(date +%s)"
    key_warn=""; key_info=""; key_unread=""; key_warn_rings=(); n_rings=0
    for kr in "${keyrings[@]}"; do
        if [[ "$kr" == inline:* ]]; then
            kfile="${kr#inline:}"
            kr_label="$(t APT-KEY-EXPIRED.ev.inline file="$(grep -F "|${kr}" <<<"$repo_entries" | head -n1 | cut -d'|' -f2)")"
        else
            kfile="$kr"; kr_label="$kr"
        fi
        if [[ -z "$kfile" ]] || ! keys="$(run env GNUPGHOME="$gpg_home" gpg --no-options --batch --no-autostart \
                --show-keys --with-colons -- "$kfile")"; then
            # An empty global keyring is harmless; a missing Signed-By keyring
            # makes 'apt update' fail for its repository and is reported.
            [[ "$kr" != /etc/apt/trusted.gpg* || -s "$kr" ]] && key_unread+="${kr_label}"$'\n'
            continue
        fi
        n_rings=$((n_rings + 1))
        users="$(grep . <<<"${key_users[$kr]}" | sort -u | paste -sd ';' | sed 's/;/; /g')"
        # One line per primary key that can sign: state|key ID|end date|user ID.
        while IFS='|' read -r kstate kid kend kuid; do
            kdate="$(date -d "@${kend}" '+%Y-%m-%d' 2>/dev/null)"
            if [[ "$kstate" == expired && -n "$users" ]]; then
                key_warn+="$(t APT-KEY-EXPIRED.ev.expired ring="$kr_label" id="$kid" uid="$kuid" date="$kdate" repos="$users")"$'\n'
                key_warn_rings+=("$kr")
            elif [[ "$kstate" == expired ]]; then
                key_info+="$(t APT-KEY-EXPIRED.ev.unused ring="$kr_label" id="$kid" uid="$kuid" date="$kdate")"$'\n'
            elif [[ "$kstate" == soon ]]; then
                key_info+="$(t APT-KEY-EXPIRED.ev.soon ring="$kr_label" id="$kid" uid="$kuid" date="$kdate" \
                    repos="${users:-$(t APT-KEY-EXPIRED.ev.none)}")"$'\n'
            fi
        done < <(awk -F: -v now="$now_s" -v soon="$((now_s + 30 * 86400))" '
            function flush(   end) {
                if (kid == "") return
                if (pcap ~ /s/) end = pexp
                else if (nsign > 0) end = (sinf ? pexp : ((pexp != "" && pexp < smax) ? pexp : smax))
                else { kid = ""; return }
                if (end != "" && end + 0 <= now)       print "expired|" kid "|" end "|" uid
                else if (end != "" && end + 0 <= soon) print "soon|" kid "|" end "|" uid
                kid = ""
            }
            $1 == "pub" { flush(); kid = $5; pexp = $7; pcap = $12; nsign = 0; sinf = 0; smax = 0; uid = ""; next }
            $1 == "uid" && uid == "" { uid = $10; gsub(/\|/, "/", uid); next }
            $1 == "sub" && $2 != "r" && $12 ~ /s/ {
                nsign++
                if ($7 == "") sinf = 1; else if ($7 + 0 > smax) smax = $7 + 0
            }
            END { flush() }' <<<"$keys")
    done

    if [[ -n "$key_warn" ]]; then
        # A single keyring is named in the first command; several stay generic.
        ring_cmd="<keyring>"
        mapfile -t key_warn_rings < <(printf '%s\n' "${key_warn_rings[@]}" | sort -u)
        # Every component of the path must be a plain name (see safe_name).
        if (( ${#key_warn_rings[@]} == 1 )) && [[ "${key_warn_rings[0]}" =~ ^(/[A-Za-z0-9][A-Za-z0-9+._@:-]*)+$ ]]; then
            ring_cmd="${key_warn_rings[0]}"
        fi
        finding WARNING APT-KEY-EXPIRED "$(t APT-KEY-EXPIRED.warn.title n="$(grep -c . <<<"$key_warn")")"
        impact APT-KEY-EXPIRED.warn.impact
        action "gpg --show-keys ${ring_cmd}" APT-KEY-EXPIRED.warn.act.1
        action "apt-cache policy" APT-KEY-EXPIRED.warn.act.2
        action "" APT-KEY-EXPIRED.warn.act.3
        action "" APT-KEY-EXPIRED.warn.act.4
        caution APT-KEY-EXPIRED.warn.caution
        evidence "$(t APT-KEY-EXPIRED.ev.1)" "${key_warn%$'\n'}"
    fi
    if [[ -n "$key_info" ]]; then
        finding INFO APT-KEY-EXPIRED "$(t APT-KEY-EXPIRED.info.title n="$(grep -c . <<<"$key_info")")"
        impact APT-KEY-EXPIRED.info.impact
        action "" APT-KEY-EXPIRED.info.act.1
        action "" APT-KEY-EXPIRED.info.act.2
        evidence "$(t APT-KEY-EXPIRED.ev.2)" "${key_info%$'\n'}"
    fi
    if [[ -n "$key_unread" ]]; then
        partial APT-KEY-EXPIRED "$(t APT-KEY-EXPIRED.partial.2 rings="$(grep . <<<"$key_unread" | paste -sd ',' | sed 's/,/, /g')")"
    elif [[ -z "$key_warn$key_info" ]] && (( n_rings > 0 )); then
        finding OK APT-KEY-EXPIRED "$(t APT-KEY-EXPIRED.ok.title n="$n_rings")"
    fi
fi

# ---- third-party repositories and automatic updates ----------------------------
# unattended-upgrades only installs updates from the origins allowed by its
# settings (Allowed-Origins, Origins-Pattern): by default, Ubuntu's own. The
# origin of each third-party source is read from 'apt-cache policy' (its
# "release o=...,a=...,n=...,l=...,c=..." line and its site) and compared
# with these settings, as unattended-upgrades does.
uu_distro_id="$(sed -n 's/^DISTRIB_ID=//p' /etc/lsb-release 2>/dev/null | tr -d '"' | head -n1)"

# uu_match PATTERN — compare an Origins-Pattern entry ("key=value,..." with
# shell-style wildcards) with the origin in uu_o, uu_a, uu_n, uu_l, uu_c and
# uu_site. Returns 0 if it matches, 1 if it does not, 2 if the entry uses
# something this check does not reproduce (escapes, unknown variable or key):
# coverage is then "not determined" rather than guessed.
uu_match() {
    local pat="$1" tok what value v res=0
    local -a toks
    [[ "$pat" == *\\* || "$pat" == *"("* ]] && return 2
    # shellcheck disable=SC2016  # the variables of unattended-upgrades, literally
    {
        [[ -n "$uu_distro_id" ]] && pat="${pat//'${distro_id}'/$uu_distro_id}"
        [[ -n "${OS_CODENAME:-}" ]] && pat="${pat//'${distro_codename}'/$OS_CODENAME}"
    }
    [[ "$pat" == *'$'* ]] && return 2
    [[ -n "${pat//[[:space:]]/}" ]] || return 1
    IFS=, read -ra toks <<<"$pat"
    for tok in "${toks[@]}"; do
        [[ "$tok" == *=* && "${tok#*=}" != *=* ]] || return 2
        what="${tok%%=*}"; what="${what//[[:space:]]/}"
        value="${tok#*=}"
        value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
        case "$what" in
            o|origin)          v="$uu_o" ;;
            l|label)           v="$uu_l" ;;
            a|suite|archive)   v="$uu_a" ;;
            c|component)       v="$uu_c" ;;
            n|codename)        v="$uu_n" ;;
            site)              v="$uu_site" ;;
            *)                 return 2 ;;
        esac
        # The value is a wildcard pattern, as in unattended-upgrades (fnmatch).
        # shellcheck disable=SC2053
        [[ "$v" == $value ]] || res=1
    done
    return "$res"
}

# uu_thirdparty_check — APT-UNATTENDED-THIRDPARTY, run when automatic updates
# are enabled.
uu_thirdparty_check() {
    local policy sources key rel site st kv cnt k p v rc n_none=0 n_undet=0 n_cov=0 lines="" pend
    local -a patterns order kvs upg_names
    local -A state=() first_rel=() pending=()
    if ! policy="$(run apt-cache "${APT_RO[@]}" policy)"; then
        partial APT-UNATTENDED-THIRDPARTY "$(t APT-UNATTENDED-THIRDPARTY.partial.1)"
        return
    fi
    # Allowed-Origins entries are "origin:archive" (or "origin archive").
    while IFS= read -r v; do
        if [[ "$v" == *[\\,]* ]]; then patterns+=("\\")
        elif [[ "$v" == *:* && "${v#*:}" != *:* ]]; then patterns+=("o=${v%%:*},a=${v#*:}")
        elif [[ "$v" != *:* && "$v" == *[[:space:]]* ]]; then read -r k p <<<"$v"; patterns+=("o=${k},a=${p}")
        else patterns+=("\\")
        fi
    done < <(apt-config dump 2>/dev/null | sed -n -E 's/^Unattended-Upgrade::Allowed-Origins:: "(.*)";$/\1/p')
    while IFS= read -r v; do patterns+=("$v"); done \
        < <(apt-config dump 2>/dev/null | sed -n -E 's/^Unattended-Upgrade::Origins-Pattern:: "(.*)";$/\1/p')

    # One line per package list of a source: "<uri> <suite>", release and site,
    # separated by the unit separator (a field can be empty).
    sources="$(awk '
        function flush() { if (key != "") print key "\037" rel "\037" site; key = "" }
        $1 ~ /^-?[0-9]+$/ && $2 ~ /^[a-z][a-z0-9+.-]*:/ {
            flush(); d = (NF >= 5) ? $3 : ""; sub(/\/[^\/]*$/, "", d)
            key = $2 (d != "" ? " " d : ""); rel = ""; site = ""; next
        }
        key != "" && $1 == "release" { rel = $0; sub(/^[ \t]*release /, "", rel); next }
        key != "" && $1 == "origin"  { site = $2; next }
        END { flush() }' <<<"$policy")"
    while IFS=$'\x1f' read -r key rel site; do
        [[ -n "$key" ]] || continue
        is_official_uri "${key%% *}" && continue
        [[ -n "${state[$key]+x}" ]] || { order+=("$key"); state[$key]=none; first_rel[$key]="$rel"; }
        [[ "${state[$key]}" == covered ]] && continue
        uu_o=""; uu_a=""; uu_n=""; uu_l=""; uu_c=""; uu_site="$site"
        IFS=, read -ra kvs <<<"$rel"
        for kv in "${kvs[@]}"; do
            case "${kv%%=*}" in
                o) uu_o="${kv#*=}" ;; a) uu_a="${kv#*=}" ;; n) uu_n="${kv#*=}" ;;
                l) uu_l="${kv#*=}" ;; c) uu_c="${kv#*=}" ;;
            esac
        done
        st=none
        for p in "${patterns[@]}"; do
            uu_match "$p"; rc=$?
            if (( rc == 0 )); then st=covered; break; fi
            (( rc == 2 )) && st=undetermined
        done
        [[ "$st" != none ]] && state[$key]="$st"
    done <<<"$sources"
    (( ${#order[@]} > 0 )) || return 0

    # Pending updates of each source: the sources of the candidate version of
    # each package listed by APT-UPGRADES (phased updates already left out).
    if [[ -n "${upgradable:-}" ]]; then
        mapfile -t upg_names < <(cut -d/ -f1 <<<"$upgradable" | grep . | head -n 500)
        while read -r cnt k; do
            [[ -n "$k" ]] && pending[$k]="$cnt"
        done < <(run apt-cache "${APT_RO[@]}" policy "${upg_names[@]}" | awk '
            /^[^ ]/ { pkg = $1; cand = ""; inc = 0; next }
            $1 == "Candidate:" { cand = $2; next }
            $1 == "Installed:" || $1 == "Version" { next }
            $1 == "***" { inc = ($2 == cand); next }
            $1 ~ /^-?[0-9]+$/ && $2 ~ /^[a-z][a-z0-9+.-]*:/ {
                if (inc) {
                    d = (NF >= 5) ? $3 : ""; sub(/\/[^\/]*$/, "", d); k = $2 (d != "" ? " " d : "")
                    if (!seen[pkg SUBSEP k]++) print k
                }
                next
            }
            $1 ~ /^-?[0-9]+$/ && $2 ~ /^\// { next }
            NF == 2 { inc = ($1 == cand) }' | sort | uniq -c)
    fi

    for key in "${order[@]}"; do
        pend="${pending[$key]:-0}"
        case "${state[$key]}" in
            covered) n_cov=$((n_cov + 1)) ;;
            none)
                n_none=$((n_none + 1))
                lines+="$(t APT-UNATTENDED-THIRDPARTY.ev.none repo="$key" release="${first_rel[$key]}" n="$pend")"$'\n' ;;
            *)
                n_undet=$((n_undet + 1))
                lines+="$(t APT-UNATTENDED-THIRDPARTY.ev.undet repo="$key" release="${first_rel[$key]}" n="$pend")"$'\n' ;;
        esac
    done
    if [[ -z "$lines" ]]; then
        finding OK APT-UNATTENDED-THIRDPARTY "$(t APT-UNATTENDED-THIRDPARTY.ok.title n="$n_cov")"
        return
    fi
    if (( n_none > 0 && n_undet > 0 )); then
        finding INFO APT-UNATTENDED-THIRDPARTY "$(t APT-UNATTENDED-THIRDPARTY.mixed.title n="$n_none" u="$n_undet")"
    elif (( n_none > 0 )); then
        finding INFO APT-UNATTENDED-THIRDPARTY "$(t APT-UNATTENDED-THIRDPARTY.info.title n="$n_none")"
    else
        finding INFO APT-UNATTENDED-THIRDPARTY "$(t APT-UNATTENDED-THIRDPARTY.undet.title u="$n_undet")"
    fi
    impact APT-UNATTENDED-THIRDPARTY.info.impact
    action "apt-config dump Unattended-Upgrade" APT-UNATTENDED-THIRDPARTY.info.act.1
    action "apt list --upgradable" APT-UNATTENDED-THIRDPARTY.info.act.2
    action "sudo apt upgrade" APT-UNATTENDED-THIRDPARTY.info.act.3
    action "" APT-UNATTENDED-THIRDPARTY.info.act.4
    action "sudo unattended-upgrade --dry-run --debug" APT-UNATTENDED-THIRDPARTY.info.act.5
    caution APT-UNATTENDED-THIRDPARTY.info.caution
    evidence "$(t APT-UNATTENDED-THIRDPARTY.ev.1)" "${lines%$'\n'}"
}

# ---- automatic security updates -------------------------------------------------
if pkg_installed unattended-upgrades; then
    uu="$(apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null | grep -o '"[0-9]*"' | tr -d '"')"
    if [[ "${uu:-0}" != 0 ]]; then
        finding OK APT-UNATTENDED "$(t APT-UNATTENDED.ok.title)"
        uu_thirdparty_check
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
# 'pro' writes logs and caches when run as root (/var/log/ubuntu-advantage.log,
# /run/ubuntu-advantage): run it as the audited user. Run as a user, it still
# writes its log, ubuntu-pro.log, and may write a cache file, in
# $XDG_CACHE_HOME/ubuntu-pro (~/.cache/ubuntu-pro by default: see
# get_user_cache_dir in uaclient/system.py and setup_cli_logging in
# uaclient/log.py), and Python creates unnamed temporary files in $TMPDIR.
# Both point to a private folder of this run, removed right after. As root,
# the folder is created by the audited user (the work folder of this run is
# root-only), under /tmp/uhc.pro.*; this also keeps pro away from root's
# HOME, which runuser does not change.
if have pro; then
    pro_out=""
    if [[ "$IS_ROOT" == 1 && "$TARGET_USER" == root ]]; then
        partial APT-PRO-STATUS "$(t APT-PRO-STATUS.partial.1)"
    else
        if [[ "$IS_ROOT" == 1 ]]; then
            pro_tmp="$(as_target mktemp -d /tmp/uhc.pro.XXXXXXXX 2>/dev/null)"
        else
            pro_tmp="$(mktemp -d "${WORK_DIR}/pro.XXXXXXXX" 2>/dev/null)"
        fi
        if [[ "$pro_tmp" =~ ^(/tmp/uhc\.pro\.|"$WORK_DIR"/pro\.)[A-Za-z0-9]{8}$ && -d "$pro_tmp" ]]; then
            pro_out="$(as_target env XDG_CACHE_HOME="$pro_tmp" TMPDIR="$pro_tmp" \
                       timeout "$CMD_TIMEOUT" pro security-status 2>/dev/null)"
            as_target rm -rf -- "$pro_tmp"
        fi
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
