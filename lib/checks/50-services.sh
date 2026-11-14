# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 50-services.sh — failed units and network-facing services enabled at boot.
# A service started for a test and forgotten is one of the most common ways a
# workstation ends up exposed for years. Scheduled and startup jobs are
# audited in 55-persistence.sh.
#
# Texts: lib/lang/*/50-services.lang (keys SVC-ALL, SVC-FAILED,
# SVC-USER-FAILED, SVC-SOCKET-ORPHAN, SVC-NETWORK, section.50-services).
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

    # ---- active sockets whose service no longer exists ------------------------------
    # socket_orphans [--user] — one line "socket -> service" per active socket
    # whose service is not found (LoadState=not-found), typically left behind
    # when a package is removed. A socket with Accept=yes starts one copy of a
    # template service, <name>@.service, per connection: that template is
    # looked up instead. Returns 1 when systemctl fails.
    socket_orphans() {
        local socks props missing="" sock trig acc s
        local -a sock_list unit_list tpl_list
        local -A load=() tpl_found=()
        socks="$(run systemctl "$@" list-units --type=socket --state=active --no-legend --plain)" || return 1
        mapfile -t sock_list < <(awk '$1 ~ /\.socket$/ {print $1}' <<<"$socks")
        (( ${#sock_list[@]} > 0 )) || return 0
        # One call for all the sockets, one for all their services.
        props="$(run systemctl "$@" show -p Id,Triggers,Accept -- "${sock_list[@]}" \
                 | awk 'BEGIN { RS = ""; FS = "\n" }
                        { id = ""; tr = ""; acc = ""
                          for (i = 1; i <= NF; i++) {
                              if ($i ~ /^Id=/) id = substr($i, 4)
                              else if ($i ~ /^Triggers=/) tr = substr($i, 10)
                              else if ($i ~ /^Accept=/) acc = substr($i, 8)
                          }
                          if (id != "") print id "|" tr "|" acc }')" || return 1
        mapfile -t unit_list < <(cut -d'|' -f2 <<<"$props" | tr ' ' '\n' | grep -E '\.service$' | sort -u)
        if (( ${#unit_list[@]} > 0 )); then
            while IFS=$'\t' read -r s state; do
                [[ -n "$s" ]] && load[$s]="$state"
            done < <(run systemctl "$@" show -p Id,LoadState -- "${unit_list[@]}" \
                     | awk 'BEGIN { RS = ""; FS = "\n" }
                            { id = ""; st = ""
                              for (i = 1; i <= NF; i++) {
                                  if ($i ~ /^Id=/) id = substr($i, 4)
                                  else if ($i ~ /^LoadState=/) st = substr($i, 11)
                              }
                              if (id != "") print id "\t" st }')
        fi
        mapfile -t tpl_list < <(awk -F'|' '$2 == "" && $3 == "yes" {sub(/\.socket$/, "@.service", $1); print $1}' <<<"$props")
        if (( ${#tpl_list[@]} > 0 )); then
            while read -r s _; do
                [[ -n "$s" ]] && tpl_found[$s]=1
            done < <(run systemctl "$@" list-unit-files --no-legend --plain -- "${tpl_list[@]}")
        fi
        while IFS='|' read -r sock trig acc; do
            [[ -n "$sock" ]] || continue
            if [[ -z "$trig" && "$acc" == yes ]]; then
                s="${sock%.socket}@.service"
                [[ -n "${tpl_found[$s]:-}" ]] || missing+="${sock} -> ${s} (not-found)"$'\n'
                continue
            fi
            for s in $trig; do
                [[ "${load[$s]:-}" == not-found ]] && missing+="${sock} -> ${s} (not-found)"$'\n'
            done
        done <<<"$props"
        printf '%s' "$missing"
    }

    if ! orphans="$(socket_orphans)"; then
        partial SVC-SOCKET-ORPHAN "$(t SVC-SOCKET-ORPHAN.partial.1)"
    elif [[ -n "$orphans" ]]; then
        sock_name="$(svc_cmd_name "${orphans%$'\n'}" "<socket>")"
        finding WARNING SVC-SOCKET-ORPHAN "$(t SVC-SOCKET-ORPHAN.warn.title n="$(grep -c . <<<"$orphans")")"
        impact SVC-SOCKET-ORPHAN.warn.impact
        action "systemctl status ${sock_name}" SVC-SOCKET-ORPHAN.warn.act.1
        action "systemctl cat ${sock_name}" SVC-SOCKET-ORPHAN.warn.act.2
        action "sudo systemctl disable --now ${sock_name}" SVC-SOCKET-ORPHAN.warn.act.3
        caution SVC-SOCKET-ORPHAN.warn.caution
        evidence "$(t SVC-SOCKET-ORPHAN.ev.1)" "${orphans%$'\n'}"
    else
        finding OK SVC-SOCKET-ORPHAN "$(t SVC-SOCKET-ORPHAN.ok.title)"
    fi
    # The audited user's own sockets, like SVC-USER-FAILED (only when the
    # audit runs as that user; a missing session manager is not an error).
    if [[ "$IS_ROOT" == 0 ]] && user_orphans="$(socket_orphans --user)" && [[ -n "$user_orphans" ]]; then
        sock_name="$(svc_cmd_name "${user_orphans%$'\n'}" "<socket>")"
        finding WARNING SVC-SOCKET-ORPHAN "$(t SVC-SOCKET-ORPHAN.user.title n="$(grep -c . <<<"$user_orphans")")"
        impact SVC-SOCKET-ORPHAN.user.impact
        action "systemctl --user status ${sock_name}" SVC-SOCKET-ORPHAN.warn.act.1
        action "systemctl --user cat ${sock_name}" SVC-SOCKET-ORPHAN.warn.act.2
        action "systemctl --user disable --now ${sock_name}" SVC-SOCKET-ORPHAN.user.act.3
        caution SVC-SOCKET-ORPHAN.warn.caution
        evidence "$(t SVC-SOCKET-ORPHAN.ev.2)" "${user_orphans%$'\n'}"
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
