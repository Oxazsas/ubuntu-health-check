# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 70-docker.sh — Docker engine updates and exposure.
#
# Docker writes its own firewall rules: a port published as '-p 8080:80'
# listens on all interfaces and bypasses ufw. Publishing on 127.0.0.1
# ('-p 127.0.0.1:8080:80') is the safe default for development.
# -----------------------------------------------------------------------------

section "Docker"

if ! have docker && ! pkg_installed docker-ce && ! pkg_installed docker.io; then
    finding INFO DKR-ABSENT "Docker not installed"
else
    # ---- engine package and repository ---------------------------------------------
    for pkg in docker-ce docker.io; do
        pkg_installed "$pkg" || continue
        if ! pkg_in_repo "$pkg"; then
            finding WARNING DKR-REPO "${pkg} is installed but no configured repository provides it" \
                "Docker no longer receives updates (the vendor repository was probably removed or disabled by a release upgrade). Re-add the official repository for the current release, verify its signing key fingerprint, then upgrade."
        else
            installed="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
            candidate="$(apt-cache "${APT_RO[@]}" policy "$pkg" 2>/dev/null | awk '/Candidate:/{print $2; exit}')"
            if [[ -n "$candidate" && "$candidate" != "$installed" ]]; then
                finding INFO DKR-UPDATE "Docker update available (${installed} -> ${candidate})" \
                    "Upgrading restarts the daemon: containers without a restart policy will stay stopped. Check tools that talk to the Docker API before a major version jump."
            else
                finding OK DKR-UPDATE "${pkg} ${installed} is the latest available"
            fi
        fi
    done

    # ---- group membership (equivalent to root) -------------------------------------
    members="$(getent group docker | cut -d: -f4)"
    if [[ -n "$members" ]]; then
        finding INFO DKR-GROUP "Members of the 'docker' group: ${members//,/, }" \
            "Access to the Docker socket is equivalent to root without password: any program running as these users can take over the machine. Acceptable on a personal workstation; consider rootless Docker where untrusted code (scripts, agents, dependencies) runs."
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
            finding WARNING DKR-EXPOSED "Running container(s) publish ports on all interfaces" \
                "Docker bypasses ufw for published ports: these are reachable from the network even with the firewall enabled. Publish on 127.0.0.1 instead (in compose: '127.0.0.1:8080:80')."
            evidence "Container, ports" "$exposed"
        else
            finding OK DKR-EXPOSED "No running container publishes a port on all interfaces"
        fi
    else
        partial DKR-EXPOSED "cannot query the Docker daemon (not running, or no permission: run with sudo)"
    fi
fi
