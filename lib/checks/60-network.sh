# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 60-network.sh — network exposure.
#
# What listens outside localhost, whether a firewall filters it, stale
# firewall rules, and whether the machine has a public IPv6 address (no NAT:
# anything listening on [::] may be reachable from the Internet unless the
# router or the host firewall blocks it).
#
# Texts: lib/lang/*/60-network.lang (keys NET-*, section.60-network).
# -----------------------------------------------------------------------------

section "$(t section.60-network)"

# ---- firewall state ------------------------------------------------------------
# fw_state: active | inactive | unknown ; fw_detail explains how it was found.
fw_state="unknown"; fw_detail=""; ufw_out=""
if have ufw; then
    if [[ "$IS_ROOT" == 1 ]]; then
        ufw_out="$(run ufw status verbose)"
        if grep -q '^Status: active' <<<"$ufw_out"; then fw_state="active"; fw_detail="$(t NET-FIREWALL.detail.1)"
        elif grep -q '^Status: inactive' <<<"$ufw_out"; then fw_state="inactive"; fw_detail="$(t NET-FIREWALL.detail.2)"
        fi
    elif [[ -r /etc/ufw/ufw.conf ]]; then
        # Without root, only the boot configuration can be read.
        if grep -qi '^ENABLED=yes' /etc/ufw/ufw.conf; then fw_state="active"; fw_detail="$(t NET-FIREWALL.detail.3)"
        else fw_state="inactive"; fw_detail="$(t NET-FIREWALL.detail.4)"
        fi
    fi
fi
if [[ "$fw_state" != active ]] && have firewall-cmd && [[ "$(run firewall-cmd --state)" == running ]]; then
    fw_state="active"; fw_detail="$(t NET-FIREWALL.detail.5)"
fi

# ---- listening sockets ---------------------------------------------------------
if ! have ss; then
    partial NET-LISTEN "$(t NET-LISTEN.partial.1)"
else
    ss_opts="-H -tuln"
    [[ "$IS_ROOT" == 1 ]] && ss_opts="-H -tulnp"
    # shellcheck disable=SC2086  # options are intentionally word-split
    if ! sockets="$(run ss $ss_opts)"; then
        ss_failed=1
        partial NET-LISTEN "$(t NET-LISTEN.partial.2)"
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
            finding CRITICAL NET-LISTEN "$(t NET-LISTEN.crit.title)"
            impact NET-LISTEN.crit.impact
            action "sudo ss -tulnp" NET-LISTEN.exposed.act.1
            action "sudo systemctl disable --now <service>" NET-LISTEN.exposed.act.2
            action "" NET-LISTEN.exposed.act.3
            action "" NET-LISTEN.crit.act.4
            caution NET-LISTEN.exposed.caution
        else
            finding WARNING NET-LISTEN "$(t NET-LISTEN.warn.title)"
            # fw_state is "active" or "unknown" here.
            if [[ "$fw_state" == active ]]; then
                impact NET-LISTEN.warn.impact_fw detail="$fw_detail"
            else
                impact NET-LISTEN.warn.impact_nofw
            fi
            action "sudo ss -tulnp" NET-LISTEN.exposed.act.1
            action "sudo systemctl disable --now <service>" NET-LISTEN.exposed.act.2
            action "" NET-LISTEN.exposed.act.3
            action "" NET-LISTEN.warn.act.4
            caution NET-LISTEN.exposed.caution
        fi
        evidence "$(t NET-LISTEN.ev.1)" "${exposed_tcp%$'\n'}"
        [[ "$IS_ROOT" == 0 ]] && partial NET-LISTEN-PROC "$(t NET-LISTEN-PROC.partial.1)"
    else
        finding OK NET-LISTEN "$(t NET-LISTEN.ok.title)"
    fi
    if [[ -n "$expected" ]]; then
        finding OK NET-LISTEN-EXPECTED "$(t NET-LISTEN-EXPECTED.ok.title)"
        evidence "$(t NET-LISTEN-EXPECTED.ev.1)" "${expected%$'\n'}"
    fi
    if [[ -n "$udp_other" ]]; then
        finding INFO NET-UDP "$(t NET-UDP.info.title)"
        impact NET-UDP.info.impact
        action "sudo ss -ulnp" NET-UDP.info.act.1
        action "" NET-UDP.info.act.2
        evidence "$(t NET-UDP.ev.1)" "${udp_other%$'\n'}"
    fi
    if [[ -n "$udp_known" ]]; then
        finding INFO NET-UDP-DISCOVERY "$(t NET-UDP-DISCOVERY.info.title)"
        impact NET-UDP-DISCOVERY.info.impact
        action "sudo systemctl disable --now avahi-daemon.service avahi-daemon.socket" NET-UDP-DISCOVERY.info.act.1
        caution NET-UDP-DISCOVERY.info.caution
        evidence "$(t NET-UDP-DISCOVERY.ev.1)" "${udp_known%$'\n'}"
    fi
fi

# ---- firewall findings -----------------------------------------------------------
case "$fw_state" in
    active)
        finding OK NET-FIREWALL "$(t NET-FIREWALL.ok.title detail="$fw_detail")"
        if [[ -n "$ufw_out" ]]; then
            if grep -q '^Default: allow (incoming)' <<<"$ufw_out"; then
                finding WARNING NET-FW-POLICY "$(t NET-FW-POLICY.warn.title)"
                impact NET-FW-POLICY.warn.impact
                action "sudo ufw status verbose" NET-FW-POLICY.warn.act.1
                action "sudo ufw allow OpenSSH" NET-FW-POLICY.warn.act.2
                action "sudo ufw default deny incoming" NET-FW-POLICY.warn.act.3
                caution NET-FW-POLICY.warn.caution
            fi
            rules="$(awk 'f && NF {print} /^--/ {f=1}' <<<"$ufw_out")"
            if [[ -n "$rules" ]]; then
                finding INFO NET-FW-RULES "$(t NET-FW-RULES.info.title n="$(wc -l <<<"$rules")")"
                impact NET-FW-RULES.info.impact
                evidence "$(t NET-FW-RULES.ev.1)" "$rules"
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
                    finding INFO NET-FW-STALE "$(t NET-FW-STALE.info.title)"
                    impact NET-FW-STALE.info.impact
                    action "sudo ufw status numbered" NET-FW-STALE.info.act.1
                    action "sudo ufw delete allow <rule>" NET-FW-STALE.info.act.2
                    caution NET-FW-STALE.info.caution
                    evidence "$(t NET-FW-STALE.ev.1)" "$stale"
                fi
            fi
        elif [[ "$IS_ROOT" == 0 ]]; then
            partial NET-FW-RULES "$(t NET-FW-RULES.partial.1)"
        fi
        ;;
    inactive)
        if [[ -z "${exposed_tcp:-}" ]]; then
            finding WARNING NET-FIREWALL "$(t NET-FIREWALL.warn.title)"
            impact NET-FIREWALL.warn.impact
        else
            finding CRITICAL NET-FIREWALL "$(t NET-FIREWALL.crit.title)"
            impact NET-FIREWALL.crit.impact
        fi
        # The same steps turn the firewall on in both cases.
        action "sudo ufw status verbose" NET-FIREWALL.off.act.1
        action "sudo ufw default deny incoming" NET-FIREWALL.off.act.2
        action "sudo ufw default allow outgoing" NET-FIREWALL.off.act.3
        action "sudo ufw allow OpenSSH" NET-FIREWALL.off.act.4
        action "sudo ufw enable" NET-FIREWALL.off.act.5
        caution NET-FIREWALL.off.caution
        ;;
    *)
        partial NET-FIREWALL "$(t NET-FIREWALL.partial.1)"
        ;;
esac

# ---- public IPv6 -------------------------------------------------------------------
if have ip; then
    # Global unicast addresses, excluding unique-local (fc00::/7) ones.
    v6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | grep -viE '^f[cd]')"
    if [[ -n "$v6" ]]; then
        finding INFO NET-IPV6 "$(t NET-IPV6.info.title)"
        impact NET-IPV6.info.impact
        action "" NET-IPV6.info.act.1
        action "" NET-IPV6.info.act.2
        evidence "$(t NET-IPV6.ev.1)" "$v6"
    fi
fi
