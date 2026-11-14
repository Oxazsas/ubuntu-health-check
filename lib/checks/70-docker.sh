# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 70-docker.sh — Docker engine updates and exposure.
#
# Docker writes its own firewall rules: a port published as '-p 8080:80'
# listens on all interfaces and bypasses ufw. Publishing on 127.0.0.1
# ('-p 127.0.0.1:8080:80') is the safe default for development.
#
# Texts: lib/lang/*/70-docker.lang (keys DKR-*, section.70-docker).
# Container names may reveal clients or projects: they are masked with
# --sanitize and must stay in the evidence, never in a title, a consequence
# or a proposed command (those are not masked).
# -----------------------------------------------------------------------------

section "$(t section.70-docker)"

if ! have docker && ! pkg_installed docker-ce && ! pkg_installed docker.io; then
    finding INFO DKR-ABSENT "$(t DKR-ABSENT.info.title)"
    impact DKR-ABSENT.info.impact
else
    # ---- engine package and repository ---------------------------------------------
    for pkg in docker-ce docker.io; do
        pkg_installed "$pkg" || continue
        if ! pkg_in_repo "$pkg"; then
            # pkg is one of the two fixed names of the loop: safe in a command.
            finding WARNING DKR-REPO "$(t DKR-REPO.warn.title pkg="$pkg")"
            impact DKR-REPO.warn.impact
            action "apt-cache policy ${pkg}" DKR-REPO.warn.act.1
            action "ls /etc/apt/sources.list.d/" DKR-REPO.warn.act.2
            action "" DKR-REPO.warn.act.3
            action "sudo apt update" DKR-REPO.warn.act.4
            action "sudo apt install --only-upgrade ${pkg}" DKR-REPO.warn.act.5
            caution DKR-REPO.warn.caution
        else
            installed="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
            candidate="$(apt-cache "${APT_RO[@]}" policy "$pkg" 2>/dev/null | awk '/Candidate:/{print $2; exit}')"
            if [[ -n "$candidate" && "$candidate" != "$installed" ]]; then
                finding INFO DKR-UPDATE "$(t DKR-UPDATE.info.title installed="$installed" candidate="$candidate")"
                impact DKR-UPDATE.info.impact
                action "docker ps" DKR-UPDATE.info.act.1
                action "sudo apt install --only-upgrade ${pkg}" DKR-UPDATE.info.act.2
                caution DKR-UPDATE.info.caution
            else
                finding OK DKR-UPDATE "$(t DKR-UPDATE.ok.title pkg="$pkg" installed="$installed")"
            fi
        fi
    done

    # ---- group membership (equivalent to root) -------------------------------------
    members="$(getent group docker | cut -d: -f4)"
    if [[ -n "$members" ]]; then
        finding INFO DKR-GROUP "$(t DKR-GROUP.info.title members="${members//,/, }")"
        impact DKR-GROUP.info.impact
        # A single member is named in the command; several stay generic.
        member_cmd="<user>"
        [[ "$members" != *,* ]] && member_cmd="$(safe_name "$members" "<user>")"
        action "getent group docker" DKR-GROUP.info.act.1
        action "" DKR-GROUP.info.act.2
        action "sudo gpasswd -d ${member_cmd} docker" DKR-GROUP.info.act.3
        caution DKR-GROUP.info.caution
    fi

    # ---- containers publishing ports on all interfaces --------------------------------
    if ps_out="$(run docker ps --format '{{.Names}}\t{{.Ports}}')"; then
        # Container names may reveal client or project names: masked with --sanitize.
        exposed=""
        while IFS=$'\t' read -r cname cports; do
            [[ "$cports" =~ (0\.0\.0\.0|\[?::\]?):[0-9]+- ]] || continue
            mask_name container "$cname"
            exposed+="${MASKED}  ${cports}"$'\n'
        done <<<"$ps_out"
        exposed="${exposed%$'\n'}"
        if [[ -n "$exposed" ]]; then
            finding WARNING DKR-EXPOSED "$(t DKR-EXPOSED.warn.title)"
            impact DKR-EXPOSED.warn.impact
            action "docker ps" DKR-EXPOSED.warn.act.1
            action "" DKR-EXPOSED.warn.act.2
            action "docker compose up -d" DKR-EXPOSED.warn.act.3
            action "" DKR-EXPOSED.warn.act.4
            caution DKR-EXPOSED.warn.caution
            evidence "$(t DKR-EXPOSED.ev.1)" "$exposed"
        else
            finding OK DKR-EXPOSED "$(t DKR-EXPOSED.ok.title)"
        fi
    else
        partial DKR-EXPOSED "$(t DKR-EXPOSED.partial.1)"
    fi
fi
