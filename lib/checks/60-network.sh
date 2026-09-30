# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 60-network.sh — network exposure.
#
# What listens outside localhost, whether a firewall filters it, stale
# firewall rules, and whether the machine has a public IPv6 address (no NAT:
# anything listening on [::] may be reachable from the Internet unless the
# router or the host firewall blocks it).
# -----------------------------------------------------------------------------

section "Network exposure"

# ---- firewall state ------------------------------------------------------------
# fw_state: active | inactive | unknown ; fw_detail explains how it was found.
fw_state="unknown"; fw_detail=""; ufw_out=""
if have ufw; then
    if [[ "$IS_ROOT" == 1 ]]; then
        ufw_out="$(run ufw status verbose)"
        if grep -q '^Status: active' <<<"$ufw_out"; then fw_state="active"; fw_detail="ufw active"
        elif grep -q '^Status: inactive' <<<"$ufw_out"; then fw_state="inactive"; fw_detail="ufw inactive"
        fi
    elif [[ -r /etc/ufw/ufw.conf ]]; then
        # Without root, only the boot configuration can be read.
        if grep -qi '^ENABLED=yes' /etc/ufw/ufw.conf; then fw_state="active"; fw_detail="ufw enabled in /etc/ufw/ufw.conf (rules not readable without sudo)"
        else fw_state="inactive"; fw_detail="ufw disabled in /etc/ufw/ufw.conf"
        fi
    fi
fi
if [[ "$fw_state" != active ]] && have firewall-cmd && [[ "$(run firewall-cmd --state)" == running ]]; then
    fw_state="active"; fw_detail="firewalld running"
fi

# ---- listening sockets ---------------------------------------------------------
if ! have ss; then
    partial NET-LISTEN "listening ports not checked (ss not available)"
else
    ss_opts="-H -tuln"
    [[ "$IS_ROOT" == 1 ]] && ss_opts="-H -tulnp"
    # shellcheck disable=SC2086  # options are intentionally word-split
    if ! sockets="$(run ss $ss_opts)"; then
        ss_failed=1
        partial NET-LISTEN "listening ports not checked (ss failed)"
    else
        ss_failed=0
    fi

    exposed_tcp=""; udp_other=""; udp_known=""; expected=""; listen_ports=""
    while read -r netid _ _ _ local _ proc; do
        [[ -z "$local" ]] && continue
        port="${local##*:}"
        addr="${local%:*}"
        listen_ports+=" ${port} "
        # Loopback only: not reachable from the network.
        [[ "$addr" =~ ^127\. || "$addr" == "[::1]" || "$addr" == "::1" || "$addr" == *%lo ]] && continue
        pname="$(grep -oE 'users:\(\("[^"]+' <<<"$proc" | cut -d'"' -f2)"
        entry="${netid} ${local}${pname:+ (${pname})}"
        if [[ " ${ALLOWED_PORTS} " == *" ${port}/${netid} "* ]]; then
            expected+="${entry}"$'\n'
        elif [[ "$netid" == tcp ]]; then
            exposed_tcp+="${entry}"$'\n'
        elif [[ "$port" =~ ^(5353|68|546|1900)$ ]]; then
            udp_known+="${entry}"$'\n'           # mDNS, DHCP clients, SSDP
        elif (( port >= 32768 )); then
            :                                     # ephemeral client sockets (browsers: QUIC, WebRTC)
        else
            udp_other+="${entry}"$'\n'
        fi
    done <<<"$sockets"

    if (( ss_failed == 1 )); then
        :
    elif [[ -n "$exposed_tcp" ]]; then
        if [[ "$fw_state" == inactive ]]; then
            finding CRITICAL NET-LISTEN "TCP services reachable from the network and NO firewall active" \
                "Every service below accepts connections from the local network (and from the Internet over IPv6 if the router does not filter). Stop what is not needed, bind development services to 127.0.0.1, and enable a firewall ('sudo ufw default deny incoming && sudo ufw enable')."
        else
            finding WARNING NET-LISTEN "TCP services listening outside localhost" \
                "Confirm each one is intended. If a service is only used locally, bind it to 127.0.0.1. Firewall: ${fw_state}${fw_detail:+ (${fw_detail})}. Add intended ports to ALLOWED_PORTS in uhc.conf to silence them."
        fi
        evidence "Listening TCP sockets (protocol, address:port, process)" "${exposed_tcp%$'\n'}"
        [[ "$IS_ROOT" == 0 ]] && partial NET-LISTEN-PROC "process names of listening sockets need sudo"
    else
        finding OK NET-LISTEN "No TCP service listening outside localhost"
    fi
    if [[ -n "$expected" ]]; then
        finding OK NET-LISTEN-EXPECTED "Listening ports declared as expected (ALLOWED_PORTS)"
        evidence "Expected" "${expected%$'\n'}"
    fi
    if [[ -n "$udp_other" ]]; then
        finding INFO NET-UDP "UDP ports open outside localhost" \
            "UDP services (DNS, VPN, games, media servers...). Confirm each is intended."
        evidence "UDP sockets" "${udp_other%$'\n'}"
    fi
    if [[ -n "$udp_known" ]]; then
        finding INFO NET-UDP-DISCOVERY "Local discovery / DHCP sockets open (mDNS, DHCP, SSDP)" \
            "Normal on a desktop (Avahi, NetworkManager). If you never use '.local' names or network discovery, Avahi can be disabled: 'sudo systemctl disable --now avahi-daemon.service avahi-daemon.socket'. Note that ufw allows inbound mDNS by default."
        evidence "Sockets" "${udp_known%$'\n'}"
    fi
fi

# ---- firewall findings -----------------------------------------------------------
case "$fw_state" in
    active)
        finding OK NET-FIREWALL "Firewall enabled (${fw_detail})"
        if [[ -n "$ufw_out" ]]; then
            if grep -q '^Default: allow (incoming)' <<<"$ufw_out"; then
                finding WARNING NET-FW-POLICY "Firewall default policy allows incoming connections" \
                    "Set 'sudo ufw default deny incoming' and open only what is needed."
            fi
            rules="$(awk 'f && NF {print} /^--/ {f=1}' <<<"$ufw_out")"
            if [[ -n "$rules" ]]; then
                finding INFO NET-FW-RULES "$(wc -l <<<"$rules") firewall rule(s) defined"
                evidence "ufw rules" "$rules"
                # Rules opening a port nothing listens on are leftovers: they would
                # silently expose any service started later on that port.
                stale=""
                # Only meaningful when the listening ports are known.
                [[ "${ss_failed:-1}" == 0 ]] && while read -r to _; do
                    rport="${to%%/*}"
                    [[ "$rport" =~ ^[0-9]+$ ]] || continue
                    [[ "$listen_ports" == *" ${rport} "* ]] || stale+="${to}"$'\n'
                done <<<"$rules"
                stale="$(sort -u <<<"$stale" | grep .)"
                if [[ -n "$stale" ]]; then
                    finding INFO NET-FW-STALE "Firewall allows port(s) on which nothing is listening" \
                        "Probably leftovers of a removed service. Remove them ('sudo ufw delete allow <rule>') so a future service is not exposed by surprise."
                    evidence "Ports allowed but unused" "$stale"
                fi
            fi
        elif [[ "$IS_ROOT" == 0 ]]; then
            partial NET-FW-RULES "firewall rules not readable without sudo"
        fi
        ;;
    inactive)
        if [[ -z "${exposed_tcp:-}" ]]; then
            finding WARNING NET-FIREWALL "No active firewall" \
                "Nothing is exposed right now, but any service started later will be reachable from the network. Enable one: 'sudo ufw default deny incoming && sudo ufw default allow outgoing && sudo ufw enable'."
        else
            finding CRITICAL NET-FIREWALL "No active firewall while services are exposed (see above)"
        fi
        ;;
    *)
        partial NET-FIREWALL "firewall state unknown (ufw/firewalld not found, or custom nftables rules; run with sudo)"
        ;;
esac

# ---- public IPv6 -------------------------------------------------------------------
if have ip; then
    # Global unicast addresses, excluding unique-local (fc00::/7) ones.
    v6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | grep -viE '^f[cd]')"
    if [[ -n "$v6" ]]; then
        finding INFO NET-IPV6 "Public IPv6 address(es) assigned" \
            "With IPv6 there is no NAT: services listening on [::] or * can be reachable from the Internet unless the router's IPv6 firewall or the host firewall blocks them. Keep the host firewall enabled."
        evidence "Global IPv6 addresses" "$v6"
    fi
fi
