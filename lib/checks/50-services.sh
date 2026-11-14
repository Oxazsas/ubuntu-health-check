# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 50-services.sh — failed units and network-facing services enabled at boot.
# A service started for a test and forgotten is one of the most common ways a
# workstation ends up exposed for years. Scheduled and startup jobs are
# audited in 55-persistence.sh.
#
# Texts: lib/lang/*/50-services.lang (keys SVC-ALL, SVC-FAILED,
# SVC-USER-FAILED, SVC-NETWORK, section.50-services).
# -----------------------------------------------------------------------------

section "$(t section.50-services)"

# svc_cmd_name LIST PLACEHOLDER — the first word of LIST, for a proposed
# command, when LIST has a single line; PLACEHOLDER when it has several (the
# list itself is in the evidence) or when the name is not a plain name.
svc_cmd_name() {
    if [[ "$1" == *$'\n'* ]]; then
        printf '%s' "$2"
    else
        safe_name "${1%% *}" "$2"
    fi
}

if [[ ! -d /run/systemd/system ]]; then
    partial SVC-ALL "$(t SVC-ALL.partial.1)"
else
    # ---- failed units -------------------------------------------------------------
    if ! failed_raw="$(run systemctl --failed --no-legend --plain)"; then
        partial SVC-FAILED "$(t SVC-FAILED.partial.1)"
    elif failed="$(awk '{print $1}' <<<"$failed_raw")"; [[ -n "$failed" ]]; then
        unit_name="$(svc_cmd_name "$failed" "<unit>")"
        finding WARNING SVC-FAILED "$(t SVC-FAILED.warn.title n="$(wc -l <<<"$failed")")"
        impact SVC-FAILED.warn.impact
        action "systemctl status ${unit_name}" SVC-FAILED.warn.act.1
        action "journalctl -u ${unit_name} -b" SVC-FAILED.warn.act.2
        action "" SVC-FAILED.warn.act.3
        caution SVC-FAILED.warn.caution
        evidence "$(t SVC-FAILED.ev.1)" "$failed"
    else
        finding OK SVC-FAILED "$(t SVC-FAILED.ok.title)"
    fi

    if [[ "$IS_ROOT" == 0 ]]; then
        user_failed="$(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
        if [[ -n "$user_failed" ]]; then
            unit_name="$(svc_cmd_name "$user_failed" "<unit>")"
            finding WARNING SVC-USER-FAILED "$(t SVC-USER-FAILED.warn.title n="$(wc -l <<<"$user_failed")")"
            impact SVC-USER-FAILED.warn.impact
            action "systemctl --user status ${unit_name}" SVC-USER-FAILED.warn.act.1
            action "journalctl --user-unit=${unit_name} -b" SVC-USER-FAILED.warn.act.2
            action "" SVC-USER-FAILED.warn.act.3
            evidence "$(t SVC-USER-FAILED.ev.1)" "$user_failed"
        fi
    fi

    # ---- network-facing services enabled at boot --------------------------------------
    # Services that accept connections by design. Being enabled is not a problem
    # in itself: the question is whether each one is still needed.
    review_pattern='^(apache2|httpd|nginx|lighttpd|caddy|php[0-9.]*-fpm|mysql|mariadb|postgresql|mongod|redis-server|memcached|cups|cups-browsed|avahi-daemon|smbd|nmbd|nfs-server|rpcbind|vsftpd|proftpd|pure-ftpd|ssh|sshd|openvpn|openvpn-server@.*|openvpn-client@.*|wg-quick@.*|xrdp|x11vnc|vncserver@.*|gnome-remote-desktop|pm2-.*|snmpd|postfix|exim4|dovecot|named|bind9|dnsmasq|squid|tor|transmission-daemon|jellyfin|plexmediaserver|cockpit|webmin|telnet.*|rsh.*)\.service$'
    svc_list=""
    while read -r unit _; do
        [[ "$unit" =~ $review_pattern ]] || continue
        state="$(systemctl is-active "$unit" 2>/dev/null)"
        svc_list+="${unit} (${state})"$'\n'
    done < <(systemctl list-unit-files --type=service --state=enabled --no-legend --plain 2>/dev/null)
    if [[ -n "$svc_list" ]]; then
        unit_name="$(svc_cmd_name "${svc_list%$'\n'}" "<unit>")"
        finding INFO SVC-NETWORK "$(t SVC-NETWORK.info.title n="$(grep -c . <<<"$svc_list")")"
        impact SVC-NETWORK.info.impact
        action "systemctl status ${unit_name}" SVC-NETWORK.info.act.1
        action "sudo systemctl disable --now ${unit_name}" SVC-NETWORK.info.act.2
        caution SVC-NETWORK.info.caution
        evidence "$(t SVC-NETWORK.ev.1)" "${svc_list%$'\n'}"
    else
        finding OK SVC-NETWORK "$(t SVC-NETWORK.ok.title)"
    fi
fi
