# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 50-services.sh — failed units and network-facing services enabled at boot.
# A service started for a test and forgotten is one of the most common ways a
# workstation ends up exposed for years. Scheduled and startup jobs are
# audited in 55-persistence.sh.
# -----------------------------------------------------------------------------

section "Services"

if [[ ! -d /run/systemd/system ]]; then
    partial SVC-ALL "systemd is not the running init system (container?), service checks skipped"
else
    # ---- failed units -------------------------------------------------------------
    if ! failed_raw="$(run systemctl --failed --no-legend --plain)"; then
        partial SVC-FAILED "failed units not listed (systemctl failed)"
    elif failed="$(awk '{print $1}' <<<"$failed_raw")"; [[ -n "$failed" ]]; then
        finding WARNING SVC-FAILED "$(wc -l <<<"$failed") failed system unit(s)" \
            "Inspect each one with 'systemctl status <unit>' and 'journalctl -u <unit> -b'."
        evidence "Failed units" "$failed"
    else
        finding OK SVC-FAILED "No failed system unit"
    fi

    if [[ "$IS_ROOT" == 0 ]]; then
        user_failed="$(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
        if [[ -n "$user_failed" ]]; then
            finding WARNING SVC-USER-FAILED "$(wc -l <<<"$user_failed") failed user unit(s)" \
                "Inspect with 'systemctl --user status <unit>'."
            evidence "Failed user units" "$user_failed"
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
        finding INFO SVC-NETWORK "$(grep -c . <<<"$svc_list") network-facing service(s) enabled at boot — confirm each is still needed" \
            "Each of these can accept connections. Disable what you no longer use ('sudo systemctl disable --now <unit>'; reversible with 'enable --now'). Cross-check with the listening ports in the Network section."
        evidence "Enabled services (current state)" "${svc_list%$'\n'}"
    else
        finding OK SVC-NETWORK "No common network-facing service enabled at boot"
    fi
fi
