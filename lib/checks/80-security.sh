# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 80-security.sh — baseline security posture.
#
# Privacy note: this module never prints the content of keys or secrets.
# For SSH keys it reads only the first bytes of each file (to recognise a
# private key header) and asks ssh-keygen whether the key opens with an empty
# passphrase; nothing derived from the key is written anywhere.
#
# Texts: lib/lang/*/80-security.lang (keys SEC-*, section.80-security).
# SSH key file names may be masked (--sanitize): they stay in the evidence,
# never in a title, a consequence or a proposed command (<key-file> there).
# -----------------------------------------------------------------------------

section "$(t section.80-security)"

is_laptop=0
compgen -G "/sys/class/power_supply/BAT*" >/dev/null && is_laptop=1

# ---- disk encryption ---------------------------------------------------------------
if have lsblk; then
    if lsblk -rno TYPE,FSTYPE 2>/dev/null | grep -qE '^crypt|crypto_LUKS'; then
        finding OK SEC-DISK-ENC "$(t SEC-DISK-ENC.ok.title)"
    elif (( is_laptop )); then
        finding WARNING SEC-DISK-ENC "$(t SEC-DISK-ENC.warn.title)"
        impact SEC-DISK-ENC.warn.impact
        action "" SEC-DISK-ENC.warn.act.1
        action "" SEC-DISK-ENC.warn.act.2
        action "" SEC-DISK-ENC.warn.act.3
        caution SEC-DISK-ENC.none.caution
    else
        finding INFO SEC-DISK-ENC "$(t SEC-DISK-ENC.info.title)"
        impact SEC-DISK-ENC.info.impact
        action "" SEC-DISK-ENC.info.act.1
        action "" SEC-DISK-ENC.info.act.2
        caution SEC-DISK-ENC.none.caution
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
        finding OK SEC-SECUREBOOT "$(t SEC-SECUREBOOT.ok.title)"
    elif [[ -n "$sb" ]]; then
        finding INFO SEC-SECUREBOOT "$(t SEC-SECUREBOOT.off.title)"
        impact SEC-SECUREBOOT.off.impact
        action "dkms status" SEC-SECUREBOOT.off.act.1
        action "" SEC-SECUREBOOT.off.act.2
        action "" SEC-SECUREBOOT.off.act.3
        caution SEC-SECUREBOOT.off.caution
    else
        partial SEC-SECUREBOOT "$(t SEC-SECUREBOOT.partial.1)"
    fi
else
    finding INFO SEC-SECUREBOOT "$(t SEC-SECUREBOOT.bios.title)"
    impact SEC-SECUREBOOT.bios.impact
fi

# ---- AppArmor ---------------------------------------------------------------------------
if [[ -r /sys/module/apparmor/parameters/enabled ]]; then
    if [[ "$(cat /sys/module/apparmor/parameters/enabled)" == Y ]]; then
        finding OK SEC-APPARMOR "$(t SEC-APPARMOR.ok.title)"
    else
        finding WARNING SEC-APPARMOR "$(t SEC-APPARMOR.warn.title)"
        impact SEC-APPARMOR.warn.impact
        action "cat /proc/cmdline" SEC-APPARMOR.warn.act.1
        action "" SEC-APPARMOR.warn.act.2
        action "sudo update-grub" SEC-APPARMOR.warn.act.3
        caution SEC-APPARMOR.warn.caution
    fi
fi

# ---- privileged accounts ------------------------------------------------------------------
uid0="$(awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd)"
if [[ -n "$uid0" ]]; then
    finding CRITICAL SEC-UID0 "$(t SEC-UID0.crit.title accounts="${uid0//$'\n'/, }")"
    impact SEC-UID0.crit.impact
    # A single account is named in the commands; several stay generic.
    uid0_cmd="<name>"
    [[ "$uid0" != *$'\n'* ]] && uid0_cmd="$(safe_name "$uid0" "<name>")"
    action "getent passwd ${uid0_cmd}" SEC-UID0.crit.act.1
    action "sudo passwd -S ${uid0_cmd}" SEC-UID0.crit.act.2
    action "sudo passwd -l ${uid0_cmd}" SEC-UID0.crit.act.3
    caution SEC-UID0.crit.caution
fi
admins="$(getent group sudo admin wheel 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep . | sort -u | paste -sd ' ')"
finding INFO SEC-ADMINS "$(t SEC-ADMINS.info.title accounts="${admins:-$(t SEC-ADMINS.info.none)}")"
impact SEC-ADMINS.info.impact
if [[ -n "$admins" ]]; then
    action "" SEC-ADMINS.info.act.1
    action "sudo gpasswd -d <user> sudo" SEC-ADMINS.info.act.2
    caution SEC-ADMINS.info.caution
fi
if [[ "$IS_ROOT" == 1 ]]; then
    empty_pw="$(awk -F: '$2 == "" {print $1}' /etc/shadow 2>/dev/null)"
    if [[ -n "$empty_pw" ]]; then
        finding CRITICAL SEC-EMPTY-PW "$(t SEC-EMPTY-PW.crit.title accounts="${empty_pw//$'\n'/, }")"
        impact SEC-EMPTY-PW.crit.impact
        # A single account is named in the commands; several stay generic.
        empty_cmd="<name>"
        [[ "$empty_pw" != *$'\n'* ]] && empty_cmd="$(safe_name "$empty_pw" "<name>")"
        action "sudo passwd -S ${empty_cmd}" SEC-EMPTY-PW.crit.act.1
        action "sudo passwd ${empty_cmd}" SEC-EMPTY-PW.crit.act.2
        action "sudo passwd -l ${empty_cmd}" SEC-EMPTY-PW.crit.act.3
        caution SEC-EMPTY-PW.crit.caution
    fi
else
    partial SEC-EMPTY-PW "$(t SEC-EMPTY-PW.partial.1)"
fi

# ---- SSH server --------------------------------------------------------------------------
if pkg_installed openssh-server; then
    sshd_active="$(systemctl is-active ssh.service ssh.socket sshd.service 2>/dev/null | grep -c '^active')"
    if [[ "$IS_ROOT" == 1 ]] && have sshd; then
        sshd_cfg="$(run sshd -T)"          # effective configuration, includes drop-ins
    else
        sshd_cfg="$(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | grep -v '^[[:space:]]*#' | tr '[:upper:]' '[:lower:]')"
        partial SEC-SSHD-EFFECTIVE "$(t SEC-SSHD-EFFECTIVE.partial.1)"
    fi
    issues=""
    grep -qE '^permitrootlogin[[:space:]]+yes' <<<"$sshd_cfg" && issues+="PermitRootLogin yes; "
    grep -qE '^passwordauthentication[[:space:]]+yes' <<<"$sshd_cfg" && issues+="PasswordAuthentication yes; "
    if (( sshd_active > 0 )) && [[ -n "$issues" ]]; then
        sshd_grep="sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication) '"
        finding WARNING SEC-SSHD "$(t SEC-SSHD.weak.title issues="${issues%; }")"
        impact SEC-SSHD.weak.impact
        action "$sshd_grep" SEC-SSHD.weak.act.1
        action "" SEC-SSHD.weak.act.2
        action "" SEC-SSHD.weak.act.3
        action "sudo sshd -t" SEC-SSHD.weak.act.4
        action "sudo systemctl reload ssh" SEC-SSHD.weak.act.5
        caution SEC-SSHD.weak.caution
    elif (( sshd_active > 0 )); then
        finding INFO SEC-SSHD "$(t SEC-SSHD.running.title)"
        impact SEC-SSHD.running.impact
        action "systemctl status ssh" SEC-SSHD.running.act.1
        action "sudo systemctl disable --now ssh.service ssh.socket" SEC-SSHD.running.act.2
        caution SEC-SSHD.running.caution
    else
        finding INFO SEC-SSHD "$(t SEC-SSHD.stopped.title)"
        impact SEC-SSHD.stopped.impact
        action "sudo apt remove openssh-server" SEC-SSHD.stopped.act.1
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
            # The END line is left out: a short key (ed25519) ends within these
            # lines, and base64 implementations that reject the whole input on
            # an invalid character (uutils) would then decode nothing, hiding
            # an unprotected key.
            as_target sed -n '2,12{/^-----/!p}' -- "$f" 2>/dev/null | tr -d '\n\r' | head -c 560 \
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
        finding WARNING SEC-SSH-PERMS "$(t SEC-SSH-PERMS.dir.title dir="$ssh_dir" mode="$mode")"
        impact SEC-SSH-PERMS.dir.impact
        action "chmod 700 ~/.ssh" SEC-SSH-PERMS.dir.act.1 mode="$mode"
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
        finding WARNING SEC-SSH-KEYS "$(t SEC-SSH-KEYS.nopass.title dir="$ssh_dir")"
        impact SEC-SSH-KEYS.nopass.impact
        action "ssh-keygen -l -f ~/.ssh/<key-file>" SEC-SSH-KEYS.nopass.act.1
        action "ssh-keygen -p -f ~/.ssh/<key-file>" SEC-SSH-KEYS.nopass.act.2
        action "" SEC-SSH-KEYS.nopass.act.3
        action "" SEC-SSH-KEYS.nopass.act.4
        caution SEC-SSH-KEYS.nopass.caution
        evidence "$(t SEC-SSH-KEYS.ev.1)" "${no_pass%$'\n'}"
    elif (( n_keys > 0 )); then
        finding OK SEC-SSH-KEYS "$(t SEC-SSH-KEYS.ok.title n="$n_keys")"
    else
        finding OK SEC-SSH-KEYS "$(t SEC-SSH-KEYS.none.title dir="$ssh_dir")"
    fi
    if [[ -n "$hw_keys" ]]; then
        finding INFO SEC-SSH-FIDO "$(t SEC-SSH-FIDO.info.title)"
        impact SEC-SSH-FIDO.info.impact
        evidence "$(t SEC-SSH-FIDO.ev.1)" "${hw_keys%$'\n'}"
    fi
    if [[ -n "$bad_perm" ]]; then
        finding WARNING SEC-SSH-PERMS "$(t SEC-SSH-PERMS.keys.title)"
        impact SEC-SSH-PERMS.keys.impact
        action "ls -l ~/.ssh" SEC-SSH-PERMS.keys.act.1
        action "chmod 600 ~/.ssh/<key-file>" SEC-SSH-PERMS.keys.act.2
        evidence "$(t SEC-SSH-PERMS.ev.1)" "${bad_perm%$'\n'}"
    fi
    if [[ -n "$key_list" ]]; then
        finding INFO SEC-SSH-INVENTORY "$(t SEC-SSH-INVENTORY.info.title)"
        impact SEC-SSH-INVENTORY.info.impact
        action "ssh-keygen -l -f ~/.ssh/<key-file>" SEC-SSH-INVENTORY.info.act.1
        action "" SEC-SSH-INVENTORY.info.act.2
        caution SEC-SSH-INVENTORY.info.caution
        evidence "$(t SEC-SSH-INVENTORY.ev.1)" "${key_list%$'\n'}"
    fi
fi

# ---- home directory permissions -----------------------------------------------------------
if [[ -d "$TARGET_HOME" ]]; then
    hmode="$(stat -c '%a' "$TARGET_HOME")"
    if (( (8#$hmode & 8#007) != 0 )); then
        finding WARNING SEC-HOME-PERMS "$(t SEC-HOME-PERMS.warn.title home="$TARGET_HOME" mode="$hmode")"
        impact SEC-HOME-PERMS.warn.impact
        action "ls -ld ~" SEC-HOME-PERMS.warn.act.1
        action "chmod 750 ~" SEC-HOME-PERMS.warn.act.2 mode="$hmode"
        caution SEC-HOME-PERMS.warn.caution
    fi
fi

# ---- permissions of files that usually hold credentials --------------------------
# A fixed list of files, relative to the audited user's home, where common
# tools store passwords or access tokens. Only their mode and owner are read
# (stat, as the audited user): the files are never opened. The paths are
# written as ~/... in the report and in the commands.
# A loose mode is a WARNING only when another account can really reach the
# file: it belongs to someone else, or the home lets "others" in and the file
# is open to them, or the home lets the group in, the file is open to its
# group and that group has another member. Otherwise (closed home, or the
# usual private group of the user) it is an INFO.
secret_files=(
    .netrc .git-credentials .npmrc .pypirc .pgpass .my.cnf
    .aws/credentials .docker/config.json .kube/config
    .config/gh/hosts.yml .config/rclone/rclone.conf
    .config/filezilla/sitemanager.xml .config/filezilla/recentservers.xml
    .claude.json .claude/settings.json
)
if [[ -d "$TARGET_HOME" ]]; then
    home_mode="$(stat -c '%a' -- "$TARGET_HOME" 2>/dev/null)"
    sp_bad=(); sp_list=""; sp_n=0; sp_unread=""; sp_exposed=0
    [[ "$home_mode" =~ ^[0-7]+$ ]] || home_mode=""
    # sp_group_shared GROUP — true if GROUP has a member other than the user.
    sp_group_shared() {
        local line gid
        line="$(getent group "$1" 2>/dev/null)" || return 0   # unknown: assume shared
        gid="$(cut -d: -f3 <<<"$line")"
        { cut -d: -f4 <<<"$line" | tr ',' '\n'; getent passwd | awk -F: -v g="$gid" '$4 == g {print $1}'; } \
            | grep -v -x -F -e "$TARGET_USER" -e '' | grep -q .
    }
    sp_tilde='~'   # paths are written ~/... (never the home path)
    for rel in "${secret_files[@]}"; do
        f="${TARGET_HOME}/${rel}"
        [[ -e "$f" || -L "$f" ]] || continue
        # -L: for a symbolic link, the mode and owner of the file it points to.
        if ! read -r sp_mode sp_owner sp_group < <(as_target stat -L -c '%a %U %G' -- "$f" 2>/dev/null) || [[ ! "$sp_mode" =~ ^[0-7]+$ ]]; then
            sp_unread+="${sp_tilde}/${rel} "
            continue
        fi
        sp_n=$((sp_n + 1))
        if (( (8#$sp_mode & 8#066) != 0 )) || [[ "$sp_owner" != "$TARGET_USER" ]]; then
            sp_bad+=("$rel")
            if [[ "$sp_owner" != "$TARGET_USER" || -z "$home_mode" ]]; then
                sp_exposed=1
            elif (( (8#$sp_mode & 8#006) != 0 && (8#$home_mode & 8#001) != 0 )); then
                sp_exposed=1
            elif (( (8#$sp_mode & 8#060) != 0 && (8#$home_mode & 8#010) != 0 )) && sp_group_shared "$sp_group"; then
                sp_exposed=1
            fi
            if [[ "$sp_owner" != "$TARGET_USER" ]]; then
                sp_list+="$(t SEC-SECRET-PERMS.ev.owner file="${sp_tilde}/${rel}" mode="$sp_mode" owner="$sp_owner")"$'\n'
            else
                sp_list+="$(t SEC-SECRET-PERMS.ev.mode file="${sp_tilde}/${rel}" mode="$sp_mode")"$'\n'
            fi
        fi
    done
    if (( ${#sp_bad[@]} > 0 )); then
        sp_list+="$(t SEC-SECRET-PERMS.ev.home mode="${home_mode:-?}")"
        # A single file is named in the commands; several stay generic.
        sp_cmd="${sp_tilde}/<file>"
        (( ${#sp_bad[@]} == 1 )) && sp_cmd="${sp_tilde}/${sp_bad[0]}"
        if (( sp_exposed == 0 )); then
            finding INFO SEC-SECRET-PERMS "$(t SEC-SECRET-PERMS.info.title n="${#sp_bad[@]}")"
            impact SEC-SECRET-PERMS.info.impact mode="${home_mode:-?}"
        else
            finding WARNING SEC-SECRET-PERMS "$(t SEC-SECRET-PERMS.warn.title n="${#sp_bad[@]}")"
            impact SEC-SECRET-PERMS.warn.impact mode="${home_mode:-?}"
        fi
        action "ls -l ${sp_cmd}" SEC-SECRET-PERMS.warn.act.1
        action "chmod 600 ${sp_cmd}" SEC-SECRET-PERMS.warn.act.2
        caution SEC-SECRET-PERMS.warn.caution
        evidence "$(t SEC-SECRET-PERMS.ev.1)" "$sp_list"
    elif (( sp_n > 0 )); then
        finding OK SEC-SECRET-PERMS "$(t SEC-SECRET-PERMS.ok.title n="$sp_n")"
    fi
    [[ -n "$sp_unread" ]] && partial SEC-SECRET-PERMS "$(t SEC-SECRET-PERMS.partial.1 files="${sp_unread% }")"
fi
