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
# -----------------------------------------------------------------------------

section "Kernel"

running="$(uname -r)"

# Installed versioned kernel images, oldest first.
mapfile -t kernel_images < <(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'linux-image-[0-9]*' 2>/dev/null \
                             | awk '$1=="installed"{print $2}' | sort -V)

# Installed kernel metapackages: linux-image-* names that do not start with a
# version number (linux-image-generic, linux-image-generic-hwe-22.04, ...).
mapfile -t kernel_metas < <(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'linux-image-*' 2>/dev/null \
                            | awk '$1=="installed" && $2 !~ /^linux-image-[0-9]/ && $2 !~ /[0-9]+\.[0-9]+\.[0-9]+-[0-9]+/ {print $2}')

if (( ${#kernel_images[@]} == 0 )); then
    finding INFO KRN-NONE "No distribution kernel packages installed" \
        "Normal inside containers, WSL or systems booting a kernel managed elsewhere. Kernel checks skipped."
else
    # ---- metapackage health ----------------------------------------------------
    meta_ok=()
    meta_dead=()
    for meta in "${kernel_metas[@]}"; do
        if pkg_in_repo "$meta"; then meta_ok+=("$meta"); else meta_dead+=("$meta"); fi
    done

    if (( ${#kernel_metas[@]} == 0 )); then
        finding CRITICAL KRN-META "No kernel metapackage installed: new kernels will never be installed" \
            "Security fixes for the kernel are not being received. Install the metapackage for your release (for example 'linux-generic', or the HWE variant) after checking with 'apt install --simulate'."
    elif (( ${#meta_ok[@]} == 0 )); then
        finding CRITICAL KRN-META "Kernel metapackage no longer available in any repository: kernel updates have stopped" \
            "The installed metapackage (${meta_dead[*]}) belongs to a previous release. Other packages keep updating, which hides the problem. Install the metapackage of the current release (e.g. 'linux-generic'), reboot, then remove the obsolete one."
        evidence "Obsolete kernel metapackage(s)" "$(printf '%s\n' "${meta_dead[@]}")"
    else
        finding OK KRN-META "Kernel metapackage available: ${meta_ok[*]}"
        if (( ${#meta_dead[@]} > 0 )); then
            finding INFO KRN-META-LEFTOVER "Obsolete kernel metapackage still installed: ${meta_dead[*]}" \
                "Leftover from a previous release. Once the current kernel is validated, it can be removed (simulate first); it keeps an old kernel installed."
        fi
    fi

    # ---- running kernel vs installed / available -------------------------------
    latest_installed="${kernel_images[-1]#linux-image-}"
    newest="$(printf '%s\n%s\n' "$running" "$latest_installed" | sort -V | tail -n1)"
    if [[ "$running" == "$latest_installed" ]]; then
        finding OK KRN-RUNNING "Running the newest installed kernel (${running})"
    elif [[ "$newest" == "$latest_installed" ]]; then
        finding WARNING KRN-RUNNING "Running kernel ${running} is not the newest installed (${latest_installed})" \
            "A newer kernel is installed but not in use. Reboot to activate it."
    else
        finding INFO KRN-RUNNING "Running kernel ${running} does not come from an installed package" \
            "Custom, virtualised or externally managed kernel: distribution kernel updates may not apply to it."
    fi

    # Compare with what the repositories offer through the available metapackage.
    # A version like 6.8.0-142.142 maps to the kernel ABI 6.8.0-142.
    for meta in "${meta_ok[@]}"; do
        candidate="$(apt-cache "${APT_RO[@]}" policy "$meta" 2>/dev/null | awk '/Candidate:/{print $2; exit}')"
        cand_abi="$(printf '%s' "$candidate" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)\..*/\1/')"
        if [[ "$cand_abi" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ && "$latest_installed" != "$cand_abi"* ]]; then
            finding WARNING KRN-PENDING "A newer kernel (${cand_abi}) is available but not installed" \
                "Pending kernel update via ${meta}. Check that updates are applied ('apt list --upgradable')."
        fi
    done

    # ---- number of kernels kept -------------------------------------------------
    if (( ${#kernel_images[@]} > OLD_KERNELS_WARN )); then
        finding INFO KRN-OLD "${#kernel_images[@]} kernel images installed" \
            "Old kernels take space in /boot and /lib/modules. 'apt autoremove' normally keeps the running and the previous kernel; extra ones are often leftovers of an obsolete metapackage."
        evidence "Installed kernel images" "$(printf '%s\n' "${kernel_images[@]}")"
    fi
fi
