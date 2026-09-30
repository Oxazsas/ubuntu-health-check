# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 80-security.sh — baseline security posture.
#
# Privacy note: this module never prints the content of keys or secrets.
# For SSH keys it reads only the first bytes of each file (to recognise a
# private key header) and asks ssh-keygen whether the key opens with an empty
# passphrase; nothing derived from the key is written anywhere.
# -----------------------------------------------------------------------------

section "Security posture"

is_laptop=0
compgen -G "/sys/class/power_supply/BAT*" >/dev/null && is_laptop=1

# ---- disk encryption ---------------------------------------------------------------
if have lsblk; then
    if lsblk -rno TYPE,FSTYPE 2>/dev/null | grep -qE '^crypt|crypto_LUKS'; then
        finding OK SEC-DISK-ENC "Encrypted block device found (LUKS)"
    elif (( is_laptop )); then
        finding WARNING SEC-DISK-ENC "No disk encryption detected on a laptop" \
            "If the laptop is lost or stolen, all data (projects, tokens, SSH keys, database dumps) is readable by plugging the disk into another machine. Full-disk encryption can only be added cleanly at install time; meanwhile keep sensitive data in encrypted archives or vaults. Silence with IGNORE_CHECKS=SEC-DISK-ENC if the risk is accepted."
    else
        finding INFO SEC-DISK-ENC "No disk encryption detected" \
            "Lower risk on a desktop in a secured place, but consider it for machines holding sensitive data."
    fi
fi

# ---- Secure Boot -----------------------------------------------------------------------
if [[ -d /sys/firmware/efi ]]; then
    sb=""
    if have mokutil; then
        sb="$(run mokutil --sb-state)"
    else
        # Last byte of the SecureBoot EFI variable: 1 = enabled.
        f="$(compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' | head -n1)"
        [[ -n "$f" ]] && [[ "$(od -An -t u1 "$f" 2>/dev/null | awk '{print $NF}')" == 1 ]] && sb="SecureBoot enabled"
    fi
    if [[ "$sb" == *"enabled"* && "$sb" != *"disabled"* ]]; then
        finding OK SEC-SECUREBOOT "Secure Boot enabled"
    elif [[ -n "$sb" ]]; then
        finding INFO SEC-SECUREBOOT "Secure Boot disabled" \
            "Secure Boot blocks unsigned kernels and boot-time rootkits. Ubuntu kernels are signed; out-of-tree modules (DKMS: NVIDIA, VirtualBox) need MOK enrolment. It can be enabled in the firmware setup, and disabled again if the machine does not boot."
    else
        partial SEC-SECUREBOOT "Secure Boot state not readable"
    fi
else
    finding INFO SEC-SECUREBOOT "Legacy BIOS boot (no UEFI): Secure Boot not applicable"
fi

# ---- AppArmor ---------------------------------------------------------------------------
if [[ -r /sys/module/apparmor/parameters/enabled ]]; then
    if [[ "$(cat /sys/module/apparmor/parameters/enabled)" == Y ]]; then
        finding OK SEC-APPARMOR "AppArmor enabled"
    else
        finding WARNING SEC-APPARMOR "AppArmor disabled" \
            "Ubuntu relies on AppArmor to confine services and snaps. Check the kernel command line for apparmor=0."
    fi
fi

# ---- privileged accounts ------------------------------------------------------------------
uid0="$(awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd)"
if [[ -n "$uid0" ]]; then
    finding CRITICAL SEC-UID0 "Account(s) other than root with UID 0: ${uid0//$'\n'/, }" \
        "A second UID 0 account is a classic backdoor. Investigate immediately."
fi
admins="$(getent group sudo admin wheel 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep . | sort -u | paste -sd ' ')"
finding INFO SEC-ADMINS "Accounts with sudo rights: ${admins:-none}" \
    "Check that every listed account is expected."
if [[ "$IS_ROOT" == 1 ]]; then
    empty_pw="$(awk -F: '$2 == "" {print $1}' /etc/shadow 2>/dev/null)"
    if [[ -n "$empty_pw" ]]; then
        finding CRITICAL SEC-EMPTY-PW "Account(s) with an empty password: ${empty_pw//$'\n'/, }" \
            "Anyone can log in as these accounts where password logins are allowed. Lock them ('sudo passwd -l <user>')."
    fi
else
    partial SEC-EMPTY-PW "accounts with empty passwords not checked (needs sudo)"
fi

# ---- SSH server --------------------------------------------------------------------------
if pkg_installed openssh-server; then
    sshd_active="$(systemctl is-active ssh.service ssh.socket sshd.service 2>/dev/null | grep -c '^active')"
    if [[ "$IS_ROOT" == 1 ]] && have sshd; then
        sshd_cfg="$(run sshd -T)"          # effective configuration, includes drop-ins
    else
        sshd_cfg="$(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | grep -v '^[[:space:]]*#' | tr '[:upper:]' '[:lower:]')"
        partial SEC-SSHD-EFFECTIVE "effective sshd configuration needs sudo; files read directly (defaults not shown)"
    fi
    issues=""
    grep -qE '^permitrootlogin[[:space:]]+yes' <<<"$sshd_cfg" && issues+="PermitRootLogin yes; "
    grep -qE '^passwordauthentication[[:space:]]+yes' <<<"$sshd_cfg" && issues+="PasswordAuthentication yes; "
    if (( sshd_active > 0 )) && [[ -n "$issues" ]]; then
        finding WARNING SEC-SSHD "SSH server running with weak settings: ${issues%; }" \
            "Prefer key-only authentication ('PasswordAuthentication no') and no direct root login ('PermitRootLogin no' or 'prohibit-password')."
    elif (( sshd_active > 0 )); then
        finding INFO SEC-SSHD "SSH server running" \
            "Make sure it is needed on this machine; otherwise 'sudo systemctl disable --now ssh'."
    else
        finding INFO SEC-SSHD "openssh-server installed but not running"
    fi
fi

# ---- SSH client keys of the audited user --------------------------------------------------
# key_state FILE — prints "<state> <type>" where state is one of:
#   encrypted | unencrypted | hardware | notakey | unknown
# The protection is read from the key format itself, not by trying to open the
# key: ssh-keygen refuses keys with loose permissions (which would wrongly look
# "protected") and cannot tell a FIDO key (useless without the device) from an
# unprotected one. Only headers and the leading, non-secret fields of the
# OpenSSH format (cipher name, key type) are decoded. Files are read with the
# audited user's privileges.
key_state() {
    local f="$1" head
    head="$(as_target head -n 3 -- "$f" 2>/dev/null | tr -d '\r')"
    case "$head" in
        *"BEGIN OPENSSH PRIVATE KEY"*)
            # openssh-key-v1: magic, then length-prefixed ciphername, kdfname,
            # kdfoptions, key count, public key blob (which starts with the type).
            as_target sed -n '2,12p' -- "$f" 2>/dev/null | tr -d '\n\r' | head -c 560 \
                | base64 -d 2>/dev/null | perl -e '
                    local $/; my $d = <STDIN>; my $p = 15;
                    if (substr($d, 0, 15) ne "openssh-key-v1\0") { print "unknown ?\n"; exit }
                    my $rd = sub { my $l = unpack("N", substr($d, $p, 4)); my $v = substr($d, $p + 4, $l); $p += 4 + $l; $v };
                    my $cipher = $rd->(); $rd->(); $rd->(); $p += 4;
                    my $type = unpack("N/a*", $rd->()) // "?";
                    $type =~ s/[^\w@.-]//g;
                    my $state = $cipher ne "none" ? "encrypted" : ($type =~ /^sk-/ ? "hardware" : "unencrypted");
                    print "$state $type\n";' ;;
        *"BEGIN ENCRYPTED PRIVATE KEY"*)                     echo "encrypted pkcs8" ;;
        *"PRIVATE KEY"*ENCRYPTED*)                           echo "encrypted pem" ;;
        *"BEGIN RSA PRIVATE KEY"*|*"BEGIN EC PRIVATE KEY"*|*"BEGIN DSA PRIVATE KEY"*|*"BEGIN PRIVATE KEY"*)
                                                             echo "unencrypted pem" ;;
        PuTTY-User-Key-File-*)
            if grep -q '^Encryption: none' <<<"$head"; then echo "unencrypted putty"; else echo "encrypted putty"; fi ;;
        *) echo "notakey -" ;;
    esac
}

ssh_dir="${TARGET_HOME}/.ssh"
if [[ -d "$ssh_dir" && ! -L "$ssh_dir" ]]; then
    mode="$(stat -c '%a' "$ssh_dir")"
    if [[ "$mode" != 700 ]]; then
        finding WARNING SEC-SSH-PERMS "${ssh_dir} has permissions ${mode} (expected 700)" \
            "Fix with 'chmod 700 ${ssh_dir}'."
    fi
    no_pass=""; bad_perm=""; hw_keys=""; key_list=""; n_keys=0
    shopt -s nullglob
    for key in "$ssh_dir"/*; do
        # Regular files only: symlinks could point anywhere.
        [[ -f "$key" && ! -L "$key" && "$key" != *.pub ]] || continue
        case "${key##*/}" in known_hosts*|authorized_keys*|config|*.old) continue ;; esac
        read -r kstate ktype < <(key_state "$key")
        [[ "$kstate" == notakey ]] && continue
        n_keys=$((n_keys + 1))
        mask_name ssh-key "${key##*/}"
        kname="$MASKED"
        kmode="$(stat -c '%a' "$key")"
        key_list+="${kname} (${ktype}, ${kstate}, mode ${kmode}, last modified $(date -r "$key" '+%Y-%m-%d'))"$'\n'
        [[ "$kmode" =~ ^[46]00$ ]] || bad_perm+="${kname} (${kmode})"$'\n'
        case "$kstate" in
            unencrypted) no_pass+="${kname} (${ktype})"$'\n' ;;
            hardware)    hw_keys+="${kname} (${ktype})"$'\n' ;;
        esac
    done
    shopt -u nullglob

    if [[ -n "$no_pass" ]]; then
        finding WARNING SEC-SSH-KEYS "SSH private key(s) without passphrase in ${ssh_dir}" \
            "Any program running under this account can read and use them. Add a passphrase ('ssh-keygen -p -f <key>'), move them to an agent-backed vault (e.g. a password manager SSH agent), or delete keys that are no longer used (and revoke them where they were authorised)."
        evidence "Unprotected keys" "${no_pass%$'\n'}"
    elif (( n_keys > 0 )); then
        finding OK SEC-SSH-KEYS "${n_keys} SSH private key file(s), none stored unprotected" \
            "Keys for servers or services that no longer exist should still be deleted (and revoked where they were authorised)."
    else
        finding OK SEC-SSH-KEYS "No SSH private key file in ${ssh_dir}"
    fi
    if [[ -n "$hw_keys" ]]; then
        finding INFO SEC-SSH-FIDO "Hardware-backed (FIDO) SSH key(s)" \
            "These key files are useless without the physical security key, so no passphrase is required."
        evidence "FIDO keys" "${hw_keys%$'\n'}"
    fi
    if [[ -n "$bad_perm" ]]; then
        finding WARNING SEC-SSH-PERMS "SSH private key(s) readable by others" \
            "Private keys must be 600. Fix with 'chmod 600 <key>'."
        evidence "Keys and permissions" "${bad_perm%$'\n'}"
    fi
    if [[ -n "$key_list" ]]; then
        finding INFO SEC-SSH-INVENTORY "Inventory of SSH private key files (review for obsolete ones)"
        evidence "Keys (name, type, protection, mode, date)" "${key_list%$'\n'}"
    fi
fi

# ---- home directory permissions -----------------------------------------------------------
if [[ -d "$TARGET_HOME" ]]; then
    hmode="$(stat -c '%a' "$TARGET_HOME")"
    if (( (8#$hmode & 8#007) != 0 )); then
        finding WARNING SEC-HOME-PERMS "Home directory ${TARGET_HOME} is accessible to other users (${hmode})" \
            "Other local accounts and services can browse it. Ubuntu's default is 750: 'chmod 750 ${TARGET_HOME}'."
    fi
fi
