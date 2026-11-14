# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 20-kernel.sh — kernel update health.
#
# Ubuntu installs each kernel as a separate, versioned package
# (linux-image-6.8.0-142-generic). New kernels only arrive because a
# *metapackage* (linux-generic, linux-image-generic-hwe-24.04, ...) depends
# on the latest one. If the only installed metapackage no longer exists in
# the repositories (typical after a release upgrade), the system silently
# stops receiving kernel updates while everything else keeps updating.
#
# Texts: lib/lang/*/20-kernel.lang (keys KRN-*, section.20-kernel).
# -----------------------------------------------------------------------------

section "$(t section.20-kernel)"

running="$(uname -r)"

# Installed versioned kernel images, oldest first.
mapfile -t kernel_images < <(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'linux-image-[0-9]*' 2>/dev/null \
                             | awk '$1=="installed"{print $2}' | sort -V)

# Installed kernel metapackages: linux-image-* names that do not start with a
# version number (linux-image-generic, linux-image-generic-hwe-22.04, ...).
mapfile -t kernel_metas < <(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'linux-image-*' 2>/dev/null \
                            | awk '$1=="installed" && $2 !~ /^linux-image-[0-9]/ && $2 !~ /[0-9]+\.[0-9]+\.[0-9]+-[0-9]+/ {print $2}')

if (( ${#kernel_images[@]} == 0 )); then
    finding INFO KRN-NONE "$(t KRN-NONE.info.title)"
    impact KRN-NONE.info.impact
else
    # ---- metapackage health ----------------------------------------------------
    meta_ok=()
    meta_dead=()
    for meta in "${kernel_metas[@]}"; do
        if pkg_in_repo "$meta"; then meta_ok+=("$meta"); else meta_dead+=("$meta"); fi
    done

    if (( ${#kernel_metas[@]} == 0 )); then
        finding CRITICAL KRN-META "$(t KRN-META.none.title)"
        impact KRN-META.none.impact
        action "apt-cache policy linux-generic" KRN-META.none.act.1
        action "sudo apt install --simulate linux-generic" KRN-META.none.act.2
        action "sudo apt install linux-generic" KRN-META.none.act.3
        caution KRN-META.none.caution
    elif (( ${#meta_ok[@]} == 0 )); then
        # A single obsolete metapackage is named in the proposed command,
        # several are left to the evidence.
        dead_cmd="<package>"
        (( ${#meta_dead[@]} == 1 )) && dead_cmd="$(safe_name "${meta_dead[0]}" "<package>")"
        finding CRITICAL KRN-META "$(t KRN-META.dead.title)"
        impact KRN-META.dead.impact packages="${meta_dead[*]}"
        action "apt-cache policy linux-generic" KRN-META.dead.act.1
        action "sudo apt install --simulate linux-generic" KRN-META.dead.act.2
        action "sudo apt install linux-generic" KRN-META.dead.act.3
        action "" KRN-META.dead.act.4
        action "sudo apt remove --simulate ${dead_cmd}" KRN-META.dead.act.5
        caution KRN-META.dead.caution
        evidence "$(t KRN-META.ev.1)" "$(printf '%s\n' "${meta_dead[@]}")"
    else
        finding OK KRN-META "$(t KRN-META.ok.title packages="${meta_ok[*]}")"
        if (( ${#meta_dead[@]} > 0 )); then
            dead_cmd="<package>"
            (( ${#meta_dead[@]} == 1 )) && dead_cmd="$(safe_name "${meta_dead[0]}" "<package>")"
            finding INFO KRN-META-LEFTOVER "$(t KRN-META-LEFTOVER.info.title packages="${meta_dead[*]}")"
            impact KRN-META-LEFTOVER.info.impact
            action "sudo apt remove --simulate ${dead_cmd}" KRN-META-LEFTOVER.info.act.1
            action "sudo apt remove ${dead_cmd}" KRN-META-LEFTOVER.info.act.2
            action "sudo apt autoremove --simulate" KRN-META-LEFTOVER.info.act.3
            caution KRN-META-LEFTOVER.info.caution
        fi
    fi

    # ---- running kernel vs installed / available -------------------------------
    latest_installed="${kernel_images[-1]#linux-image-}"
    newest="$(printf '%s\n%s\n' "$running" "$latest_installed" | sort -V | tail -n1)"
    if [[ "$running" == "$latest_installed" ]]; then
        finding OK KRN-RUNNING "$(t KRN-RUNNING.ok.title running="$running")"
    elif [[ "$newest" == "$latest_installed" ]]; then
        finding WARNING KRN-RUNNING "$(t KRN-RUNNING.old.title running="$running" latest="$latest_installed")"
        impact KRN-RUNNING.old.impact
        action "" KRN-RUNNING.old.act.1
        action "uname -r" KRN-RUNNING.old.act.2
        caution KRN-RUNNING.old.caution
    else
        finding INFO KRN-RUNNING "$(t KRN-RUNNING.foreign.title running="$running")"
        impact KRN-RUNNING.foreign.impact
        action "" KRN-RUNNING.foreign.act.1
    fi

    # Compare with what the repositories offer through the available metapackage.
    # A version like 6.8.0-142.142 maps to the kernel ABI 6.8.0-142.
    for meta in "${meta_ok[@]}"; do
        candidate="$(apt-cache "${APT_RO[@]}" policy "$meta" 2>/dev/null | awk '/Candidate:/{print $2; exit}')"
        cand_abi="$(printf '%s' "$candidate" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)\..*/\1/')"
        if [[ "$cand_abi" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ && "$latest_installed" != "$cand_abi"* ]]; then
            meta_cmd="$(safe_name "$meta" "<package>")"
            finding WARNING KRN-PENDING "$(t KRN-PENDING.warn.title version="$cand_abi")"
            impact KRN-PENDING.warn.impact package="$meta"
            action "apt list --upgradable" KRN-PENDING.warn.act.1
            action "apt-cache policy ${meta_cmd}" KRN-PENDING.warn.act.2
            action "sudo apt upgrade" KRN-PENDING.warn.act.3
            caution KRN-PENDING.warn.caution
        fi
    done

    # ---- number of kernels kept -------------------------------------------------
    if (( ${#kernel_images[@]} > OLD_KERNELS_WARN )); then
        finding INFO KRN-OLD "$(t KRN-OLD.info.title n="${#kernel_images[@]}")"
        impact KRN-OLD.info.impact
        action "df -h /boot" KRN-OLD.info.act.1
        action "sudo apt autoremove --simulate" KRN-OLD.info.act.2
        action "sudo apt autoremove" KRN-OLD.info.act.3
        caution KRN-OLD.info.caution
        evidence "$(t KRN-OLD.ev.1)" "$(printf '%s\n' "${kernel_images[@]}")"
    fi
fi
