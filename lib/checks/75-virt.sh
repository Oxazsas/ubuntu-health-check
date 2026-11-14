# shellcheck shell=bash
# -----------------------------------------------------------------------------
# 75-virt.sh — virtual machines managed by libvirt (KVM/QEMU), and the groups
# that give access to them.
#
# Inventory of the virtual machines (VMs), disks whose file is gone, disk
# images that no VM uses, snapshots, graphical consoles reachable from the
# network, libvirt networks and storage pools.
#
# Read-only by construction:
#   - every virsh call uses --readonly (-r), against the local URIs
#     qemu:///system and qemu:///session only; nothing is started, stopped,
#     defined or changed. Connecting to qemu:///system may start the system
#     daemon through systemd socket activation, which is its normal behaviour
#     and changes nothing;
#   - a connection to qemu:///session starts a session daemon for the user
#     when none is running (it then writes under ~/.config/libvirt and
#     $XDG_RUNTIME_DIR/libvirt). The session is therefore only queried when
#     its daemon already runs and its socket exists, and always with
#     LIBVIRT_AUTOSTART=0 (which forbids the client to start one). Otherwise
#     only the names of the definition files (~/.config/libvirt/qemu/*.xml)
#     are listed;
#   - dumpxml is never given --security-info (refused anyway on a read-only
#     connection), so console passwords are not in the XML; only a few
#     attributes are extracted from it, and the XML itself never reaches the
#     report.
#
# Names chosen by the user (VMs, snapshots, networks, pools, image files) may
# reveal clients or projects: they are masked with --sanitize (mask_name) and
# stay in the evidence only, never in a title, a consequence or a command,
# like container names in 70-docker.sh. Commands use placeholders (<vm>...).
#
# Reads VM_BRIDGE_ADDRS (set in 60-network.sh).
# Texts: lib/lang/*/75-virt.lang (keys VIRT-*, section.75-virt).
# -----------------------------------------------------------------------------

section "$(t section.75-virt)"

# vq ARGS... — virsh, read-only, against the scope in VQ_SCOPE (system or
# session), with a short timeout. LIBVIRT_AUTOSTART=0: never start a daemon.
vq() {
    if [[ "$VQ_SCOPE" == session && "$IS_ROOT" == 1 && "$TARGET_USER" != root ]]; then
        CMD_TIMEOUT=10 run runuser -u "$TARGET_USER" -- env LIBVIRT_AUTOSTART=0 \
            XDG_RUNTIME_DIR="$virt_rundir" virsh -r -c qemu:///session "$@" </dev/null
    else
        LIBVIRT_AUTOSTART=0 CMD_TIMEOUT=10 run virsh -r -c "qemu:///${VQ_SCOPE}" "$@" </dev/null
    fi
}

# virt_xml — the few facts the checks need from a domain XML (stdin), one per
# line, tab-separated. Values are unescaped; tabs and newlines in them become
# spaces. Nothing else of the XML is printed (no passwd attribute, ever).
#   disk TYPE DEVICE TARGET SOURCE     (SOURCE: file, dev, or name for network disks)
#   vdisk DEVICE TARGET POOL VOLUME    (disk of type 'volume')
#   back PATH                          (backing file shown in the XML)
#   boot PATH                          (kernel, initrd, firmware, NVRAM)
#   gfx TYPE KIND VALUE [ADDRESS]      (KIND: address, network, socket, none, default)
#   net TYPE NETWORK BRIDGE
virt_xml() {
    perl -e '
        local $/; my $x = <STDIN> // "";
        sub un { my $v = shift // ""; $v =~ s/&lt;/</g; $v =~ s/&gt;/>/g; $v =~ s/&quot;/"/g;
                 $v =~ s/&apos;/\x27/g; $v =~ s/&amp;/&/g; $v =~ s/[\t\r\n]/ /g; return $v }
        sub attr { my ($tag, $n) = @_; return $tag =~ /\s\Q$n\E=(["\x27])(.*?)\1/s ? un($2) : "" }
        while ($x =~ m{<disk\b([^>]*)>(.*?)</disk>}gs) {
            my ($a, $body) = ($1, $2);
            # The backing chain (nested backingStore elements, which have
            # their own source) is taken out of the disk element first.
            my ($own, $chain) = ($body, "");
            $chain = $1 if $own =~ s{(<backingStore\b.*</backingStore>)}{}s;
            $own =~ s{<backingStore\b[^>]*/>}{}g;
            my ($type, $dev) = (attr($a, "type"), attr($a, "device"));
            my $tgt = $own =~ /<target\b([^>]*)/ ? attr($1, "dev") : "";
            my $s = $own =~ /<source\b([^>]*)/ ? $1 : "";
            if ($type eq "volume") {
                print join("\t", "vdisk", $dev, $tgt, attr($s, "pool"), attr($s, "volume")), "\n";
            } else {
                my $src = attr($s, "file"); $src = attr($s, "dev") if $src eq "";
                $src = attr($s, "name") if $src eq "";
                print join("\t", "disk", $type, $dev, $tgt, $src), "\n";
            }
            while ($chain =~ /<source\b([^>]*)/g) {
                my $p = attr($1, "file"); $p = attr($1, "dev") if $p eq "";
                print "back\t$p\n" if $p ne "";
            }
        }
        while ($x =~ m{<(kernel|initrd|loader|nvram)\b[^>]*>([^<]+)</\1>}g) { print "boot\t", un($2), "\n" }
        while ($x =~ m{<graphics\b([^>]*?)(?:/>|>(.*?)</graphics>)}gs) {
            my ($a, $body) = ($1, $2 // "");
            my $type = attr($a, "type");
            next unless $type =~ /^(vnc|spice|rdp)$/;
            my @l;
            while ($body =~ /<listen\b([^>]*)/g) {
                my $l = $1; my $k = attr($l, "type");
                if    ($k eq "address") { push @l, attr($l, "address") ne "" ? "address\t" . attr($l, "address") : "default\t" }
                elsif ($k eq "network") { push @l, "network\t" . attr($l, "network") . "\t" . attr($l, "address") }
                elsif ($k eq "socket")  { push @l, "socket\t" }
                elsif ($k eq "none")    { push @l, "none\t" }
            }
            if (!@l) {
                my $la = attr($a, "listen");
                push @l, $la ne "" ? "address\t$la" : ($a =~ /\ssocket=/ ? "socket\t" : "default\t");
            }
            print "gfx\t$type\t$_\n" for @l;
        }
        while ($x =~ m{<interface\b([^>]*)>(.*?)</interface>}gs) {
            my ($a, $b) = ($1, $2);
            my $s = $b =~ /<source\b([^>]*)/ ? $1 : "";
            print join("\t", "net", attr($a, "type"), attr($s, "network"), attr($s, "bridge")), "\n";
        }'
}

# virt_size_bytes "23.69 GiB" — the size in bytes (virsh prints binary units).
virt_size_bytes() {
    awk -v n="$1" -v u="$2" 'BEGIN {
        m["B"] = 1; m["bytes"] = 1; m["KiB"] = 1024; m["MiB"] = 1024^2; m["GiB"] = 1024^3; m["TiB"] = 1024^4; m["PiB"] = 1024^5
        printf "%.0f", n * (u in m ? m[u] : 0) }'
}
# virt_human BYTES — e.g. "23.7 GiB".
virt_human() {
    awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB PiB", u, " "); i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

# virt_path PATH — PATH as shown in the evidence, in VP: ~/... under the home
# folder; with --sanitize, the file name is replaced by an alias (image-N,
# extension kept), and its folder too unless it is a libvirt or device folder.
virt_path() {
    local p="$1" dir base ext=""
    if [[ "${SANITIZE:-0}" == 1 && "$p" == */* ]]; then
        dir="${p%/*}"; base="${p##*/}"
        [[ "$base" == *.* ]] && ext=".${base##*.}"
        [[ "$ext" =~ ^\.[A-Za-z0-9]{1,6}$ ]] || ext=""
        mask_name image "$p"
        [[ "$dir" == /var/lib/libvirt* || "$dir" == /dev* ]] || dir="…"
        VP="${dir}/${MASKED}${ext}"
    elif [[ "$p" == "$TARGET_HOME"/* ]]; then
        # A literal "~/" for the report, not a path to expand.
        # shellcheck disable=SC2088
        VP="~/${p#"$TARGET_HOME"/}"
    else
        VP="$p"
    fi
}

# virt_listen_scope KIND VALUE ADDRESS — local | vms | network: where a
# graphical console listens. No address in the XML means the default of
# /etc/libvirt/qemu.conf, 127.0.0.1 unless changed (that file is not read:
# it may hold console passwords). A running VM shows its real address.
virt_listen_scope() {
    local kind="$1" val="$2" addr="${3:-}" fwd
    case "$kind" in
        socket|none|default) echo local; return ;;
        network)
            if [[ -z "$addr" ]]; then
                # Not running: the address is the one of that libvirt network.
                fwd="${VIRT_NET_FWD[${VQ_SCOPE}/${val}]:-unknown}"
                if [[ "$fwd" == nat || "$fwd" == isolated ]]; then echo vms; else echo network; fi
                return
            fi
            val="$addr" ;;
    esac
    val="${val#[}"; val="${val%]}"
    if [[ "$val" =~ ^127\. || "$val" == ::1 || "$val" == localhost || "$val" == ip6-localhost ]]; then
        echo local
    elif [[ -n "${VM_BRIDGE_ADDRS:-}" && " ${VM_BRIDGE_ADDRS} " == *" ${val} "* ]]; then
        echo vms
    else
        echo network
    fi
}

# virt_scan — query the scope in VQ_SCOPE and add to the lists below.
# Returns 1 when the scope cannot be queried.
declare -A VIRT_NET_FWD=() VOL_CAP=() VOL_ALLOC=() VOL_BYTES=() VOL_IMG=() VOL_LABEL=() VIRT_USED=()
virt_vms=""; virt_nets=""; virt_pools=""; virt_snaps=""; virt_missing=""; virt_consoles=""
n_vms=0; n_running=0; n_autostart=0; mem_running=0; n_disks_unknown=0; n_pools_inactive=0
n_snap_total=0; n_snap_vms=0; snap_oldest=""; n_gfx=0
virt_scan() {
    local sc="$VQ_SCOPE" uuids u out name state persistent autostart cpus mem
    local pinfo ptype ppath pname pstate pauto vols line rec f1 f2 f3 f4 src p st
    local nname nactive nauto nbridge naddr nfwd xml snaps n_s first last
    uuids="$(vq list --all --uuid)" || return 1

    # ---- networks ----
    for u in $(vq net-list --all --uuid); do
        [[ "$u" =~ ^[0-9a-f-]+$ ]] || continue
        out="$(vq net-info "$u")" || continue
        nname="$(awk -F': *' '$1 == "Name" {print $2; exit}' <<<"$out")"
        nactive="$(awk -F': *' '$1 == "Active" {print $2; exit}' <<<"$out")"
        nauto="$(awk -F': *' '$1 == "Autostart" {print $2; exit}' <<<"$out")"
        nbridge="$(awk -F': *' '$1 == "Bridge" {print $2; exit}' <<<"$out")"
        xml="$(vq net-dumpxml "$u")"
        nfwd="$(grep -oE "<forward [^>]*mode=['\"][a-z]+" <<<"$xml" | head -n1 | grep -oE '[a-z]+$')"
        [[ -n "$nfwd" ]] || nfwd=isolated
        naddr="$(grep -oE "<ip [^>]*address=['\"][^'\"]+" <<<"$xml" | sed -E "s/.*address=['\"]//" | paste -sd ' ')"
        VIRT_NET_FWD[$sc/$nname]="$nfwd"
        mask_name network "$nname"
        virt_nets+="[${sc}] ${MASKED}  active=${nactive:-?}  autostart=${nauto:-?}  bridge=${nbridge:--}  forward=${nfwd}  address=${naddr:--}"$'\n'
    done

    # ---- storage pools and their volumes ----
    for u in $(vq pool-list --all --uuid); do
        [[ "$u" =~ ^[0-9a-f-]+$ ]] || continue
        pinfo="$(vq pool-dumpxml "$u")" || continue
        ptype="$(grep -oE "<pool [^>]*type=['\"][a-z]+" <<<"$pinfo" | head -n1 | grep -oE '[a-z]+$')"
        pname="$(sed -nE 's#.*<name>([^<]*)</name>.*#\1#p' <<<"$pinfo" | head -n1)"
        ppath="$(sed -nE 's#.*<path>([^<]*)</path>.*#\1#p' <<<"$pinfo" | head -n1)"
        out="$(vq pool-info "$u")"
        pstate="$(awk -F': *' '$1 == "State" {print $2; exit}' <<<"$out")"
        pauto="$(awk -F': *' '$1 == "Autostart" {print $2; exit}' <<<"$out")"
        mask_name pool "$pname"; pname="$MASKED"
        # The folder of the pool: ~/... under the home folder; with
        # --sanitize, only libvirt and device folders are kept.
        VP="$ppath"
        if [[ "${SANITIZE:-0}" == 1 && -n "$ppath" && "$ppath" != /var/lib/libvirt* && "$ppath" != /dev* ]]; then
            VP="…"
        elif [[ "$ppath" == "$TARGET_HOME" || "$ppath" == "$TARGET_HOME"/* ]]; then
            # shellcheck disable=SC2088  # literal "~" for the report
            VP="~${ppath#"$TARGET_HOME"}"
        fi
        virt_pools+="[${sc}] ${pname}  type=${ptype:-?}  state=${pstate:-?}  autostart=${pauto:-?}  path=${VP:--}"$'\n'
        if [[ "$pstate" != running ]]; then
            n_pools_inactive=$((n_pools_inactive + 1))
            continue
        fi
        vols="$(vq vol-list --details --pool "$u")" || continue
        # Columns: Name, Path, Type, Capacity (2 words), Allocation (2 words);
        # the path is the part that starts with "/".
        while IFS=$'\t' read -r p f1 f2 f3 f4; do
            [[ "$p" == /* && -z "${VOL_CAP[$p]+x}" ]] || continue     # two pools on one folder: counted once
            VOL_CAP[$p]="$f1 $f2"; VOL_ALLOC[$p]="$f3 $f4"
            VOL_BYTES[$p]="$(virt_size_bytes "$f3" "$f4")"
            VOL_LABEL[$p]="[${sc}] ${pname}"
            # Disk images only: in a folder pool, a file with the extension
            # of a disk image (a pool can point to any folder, Downloads for
            # instance); in an LVM or ZFS pool, every volume.
            case "$ptype" in
                dir|fs|netfs) [[ "${p,,}" =~ \.(qcow2?|img|raw|iso|vmdk|vdi|vhdx?|qed)$ ]] && VOL_IMG[$p]=1 ;;
                logical|zfs) VOL_IMG[$p]=1 ;;
            esac
        done < <(awk 'f && NF >= 6 { for (i = 1; i <= NF - 5; i++) if ($i ~ /^\//) break
                                      if (i > NF - 5) next
                                      path = $i; for (j = i + 1; j <= NF - 5; j++) path = path " " $j
                                      printf "%s\t%s\t%s\t%s\t%s\n", path, $(NF-3), $(NF-2), $(NF-1), $NF }
                      /^-+$/ { f = 1 }' <<<"$vols")
    done

    # ---- virtual machines ----
    for u in $uuids; do
        [[ "$u" =~ ^[0-9a-f-]+$ ]] || continue
        out="$(vq dominfo "$u")" || continue
        name="$(awk -F': +' '$1 == "Name" {print $2; exit}' <<<"$out")"
        state="$(awk -F': +' '$1 == "State" {print $2; exit}' <<<"$out")"
        persistent="$(awk -F': +' '$1 == "Persistent" {print $2; exit}' <<<"$out")"
        autostart="$(awk -F': +' '$1 == "Autostart" {print ($2 == "enable" ? "yes" : "no"); exit}' <<<"$out")"
        cpus="$(awk -F': +' '$1 == "CPU(s)" {print $2; exit}' <<<"$out")"
        mem="$(awk -F': +' '$1 == "Max memory" {print $2 + 0; exit}' <<<"$out")"
        mask_name vm "$name"; name="$MASKED"
        n_vms=$((n_vms + 1))
        [[ "$state" == running ]] && n_running=$((n_running + 1))
        [[ "$autostart" == yes ]] && n_autostart=$((n_autostart + 1))
        [[ "$state" != "shut off" ]] && mem_running=$((mem_running + ${mem:-0}))
        virt_vms+="[${sc}] ${name}  state=${state:-?}  autostart=${autostart:-?}  persistent=${persistent:-?}  memory=$(virt_human "$(( ${mem:-0} * 1024 ))")  vcpu=${cpus:-?}"$'\n'

        # Fields separated by \037 (tab is a whitespace for read, which
        # would merge empty fields).
        while IFS=$'\037' read -r rec f1 f2 f3 f4; do
            case "$rec" in
                disk|vdisk)
                    # disk: f1 type, f2 device, f3 target, f4 source;
                    # vdisk: f1 device, f2 target, f3 pool, f4 volume.
                    if [[ "$rec" == vdisk ]]; then
                        # A volume that cannot be resolved (inactive pool,
                        # or gone) is counted as not checked, not as missing.
                        src="$(vq vol-path --pool "$f3" "$f4")"
                        [[ "$src" == /* ]] || { n_disks_unknown=$((n_disks_unknown + 1)); continue; }
                        f4="$src"; f3="$f2"; f2="$f1"; f1=volume
                    fi
                    [[ -n "$f4" ]] || { virt_vms+="    ${f2} ${f3}: -"$'\n'; continue; }
                    if [[ "$f1" == network ]]; then
                        virt_vms+="    ${f2} ${f3}: $(t VIRT-VMS.ev.network_disk)"$'\n'
                        continue
                    fi
                    VIRT_USED[$f4]=1
                    virt_path "$f4"
                    line="    ${f2} ${f3}: ${VP}"
                    [[ -n "${VOL_CAP[$f4]+x}" ]] && line+="  $(t VIRT-VMS.ev.size cap="${VOL_CAP[$f4]}" alloc="${VOL_ALLOC[$f4]}")"
                    virt_vms+="${line}"$'\n'
                    # Backing file of an image in a pool (libvirt reads the
                    # image header; this tool does not open images).
                    if [[ -n "${VOL_CAP[$f4]+x}" ]]; then
                        p="$(vq vol-dumpxml "$f4" | perl -0ne 'print $1 if m{<backingStore>.*?<path>([^<]*)</path>}s')"
                        [[ -n "$p" ]] && VIRT_USED[$p]=1
                    fi
                    if [[ "$f4" == /* ]]; then
                        if st="$(stat -L -c %F -- "$f4" 2>&1)"; then
                            :
                        elif [[ "$st" == *"No such file or directory"* ]]; then
                            virt_missing+="[${sc}] ${name}  ${f2} ${f3}: ${VP}"$'\n'
                        else
                            n_disks_unknown=$((n_disks_unknown + 1))
                        fi
                    fi
                    ;;
                back|boot)
                    VIRT_USED[$f1]=1 ;;
                gfx)
                    n_gfx=$((n_gfx + 1))
                    if [[ "$(virt_listen_scope "$f2" "$f3" "$f4")" == network ]]; then
                        line="[${sc}] ${name}  ${f1}  listen"
                        if [[ "$f2" == network ]]; then
                            mask_name network "$f3"
                            line+=" network=${MASKED}${f4:+ address=${f4}}"
                        else
                            line+=" ${f3}"
                        fi
                        virt_consoles+="${line}  (state=${state:-?})"$'\n'
                    fi
                    ;;
                net)
                    if [[ -n "$f2" ]]; then
                        mask_name network "$f2"
                        virt_vms+="    network ${MASKED}${f3:+ (${f3})}"$'\n'
                    else
                        virt_vms+="    network ${f1}${f3:+ (${f3})}"$'\n'
                    fi
                    ;;
            esac
        done < <(vq dumpxml "$u" | virt_xml | tr '\t' '\037')

        # Snapshots: Name, Creation Time (3 words), State.
        snaps="$(vq snapshot-list "$u" | awk 'f && NF >= 5 { st = $NF; d = $(NF-3) " " $(NF-2) " " $(NF-1)
                    n = $1; for (i = 2; i <= NF - 4; i++) n = n " " $i; printf "%s\t%s\t%s\n", d, st, n }
                 /^-+$/ { f = 1 }' | LC_ALL=C sort)"
        if [[ -n "$snaps" ]]; then
            n_s="$(grep -c . <<<"$snaps")"
            first="$(head -n1 <<<"$snaps" | cut -f1)"; last="$(tail -n1 <<<"$snaps" | cut -f1)"
            n_snap_total=$((n_snap_total + n_s)); n_snap_vms=$((n_snap_vms + 1))
            [[ -z "$snap_oldest" || "$first" < "$snap_oldest" ]] && snap_oldest="$first"
            virt_snaps+="[${sc}] ${name}: $(t VIRT-SNAPSHOTS.ev.vm n="$n_s" oldest="$first" newest="$last")"$'\n'
            while IFS=$'\t' read -r f1 f2 f3; do
                mask_name snapshot "$f3"
                line="    ${MASKED}  ${f1}  ${f2}"
                [[ "$f2" == running || "$f2" == paused ]] && line+="  $(t VIRT-SNAPSHOTS.ev.memory mem="$(virt_human "$(( ${mem:-0} * 1024 ))")")"
                virt_snaps+="${line}"$'\n'
            done <<<"$snaps"
        fi
    done
    return 0
}

if ! have virsh; then
    if pkg_installed libvirt-daemon-system || pkg_installed libvirt-daemon; then
        partial VIRT-ACCESS "$(t VIRT-ACCESS.partial.1)"
    else
        finding INFO VIRT-ABSENT "$(t VIRT-ABSENT.info.title)"
        impact VIRT-ABSENT.info.impact
    fi
else
    # ---- system scope ----
    VQ_SCOPE=system
    system_ok=1
    virt_scan || { system_ok=0; partial VIRT-ACCESS "$(t VIRT-ACCESS.partial.2)"; }

    # ---- session scope of the audited user ----
    # Queried only when its daemon already runs (see the header).
    virt_rundir="/run/user/$(id -u "$TARGET_USER" 2>/dev/null)"
    session_defs=""
    if [[ -S "${virt_rundir}/libvirt/libvirt-sock" || -S "${virt_rundir}/libvirt/virtqemud-sock" ]] \
        && pgrep -u "$TARGET_USER" -x 'libvirtd|virtqemud' >/dev/null 2>&1; then
        VQ_SCOPE=session
        virt_scan || partial VIRT-SESSION "$(t VIRT-SESSION.partial.2)"
    else
        session_defs="$(as_target find "${TARGET_HOME}/.config/libvirt/qemu" -maxdepth 1 -type f -name '*.xml' -printf '%f\n' 2>/dev/null)"
        if [[ -n "$session_defs" ]]; then
            while IFS= read -r f; do
                mask_name vm "${f%.xml}"
                virt_vms+="[session] ${MASKED}  $(t VIRT-VMS.ev.not_queried)"$'\n'
            done <<<"$session_defs"
            partial VIRT-SESSION "$(t VIRT-SESSION.partial.1 n="$(grep -c . <<<"$session_defs")")"
        fi
    fi
    n_session_defs=0
    [[ -n "$session_defs" ]] && n_session_defs="$(grep -c . <<<"$session_defs")"

    if (( system_ok == 1 || n_vms > 0 || n_session_defs > 0 )); then
        # ---- inventory ----
        if (( n_vms + n_session_defs > 0 )); then
            finding INFO VIRT-VMS "$(t VIRT-VMS.info.title n="$((n_vms + n_session_defs))" running="$n_running" autostart="$n_autostart" mem="$(virt_human "$((mem_running * 1024))")")"
            impact VIRT-VMS.info.impact
            action "virsh -r -c qemu:///system list --all" VIRT-VMS.info.act.1
            action "virsh -r -c qemu:///system dominfo <vm>" VIRT-VMS.info.act.2
            action "" VIRT-VMS.info.act.3
            action "virsh -c qemu:///system autostart --disable <vm>" VIRT-VMS.info.act.4
            caution VIRT-VMS.info.caution
            evidence "$(t VIRT-VMS.ev.1)" "${virt_vms%$'\n'}"
        else
            finding OK VIRT-VMS "$(t VIRT-VMS.ok.title)"
        fi
        evidence "$(t VIRT-VMS.ev.2)" "${virt_nets%$'\n'}"
        evidence "$(t VIRT-VMS.ev.3)" "${virt_pools%$'\n'}"

        if (( n_vms > 0 )); then
            # ---- disks whose file is gone ----
            if [[ -n "$virt_missing" ]]; then
                finding WARNING VIRT-DISK-MISSING "$(t VIRT-DISK-MISSING.warn.title n="$(grep -c . <<<"$virt_missing")")"
                impact VIRT-DISK-MISSING.warn.impact
                action "virsh -r -c qemu:///system domblklist <vm> --details" VIRT-DISK-MISSING.warn.act.1
                action "virsh -r -c qemu:///system dumpxml <vm> > vm-backup.xml" VIRT-DISK-MISSING.warn.act.2
                action "virsh -c qemu:///system edit <vm>" VIRT-DISK-MISSING.warn.act.3
                action "virsh -c qemu:///system undefine <vm>" VIRT-DISK-MISSING.warn.act.4
                caution VIRT-DISK-MISSING.warn.caution
                evidence "$(t VIRT-DISK-MISSING.ev.1)" "${virt_missing%$'\n'}"
            elif (( n_disks_unknown == 0 )); then
                finding OK VIRT-DISK-MISSING "$(t VIRT-DISK-MISSING.ok.title)"
            fi
            (( n_disks_unknown > 0 )) && partial VIRT-DISK-MISSING "$(t VIRT-DISK-MISSING.partial.1 n="$n_disks_unknown")"

            # ---- graphical consoles reachable from the network ----
            if [[ -n "$virt_consoles" ]]; then
                finding WARNING VIRT-CONSOLE "$(t VIRT-CONSOLE.warn.title n="$(grep -c . <<<"$virt_consoles")")"
                impact VIRT-CONSOLE.warn.impact
                action "virsh -r -c qemu:///system domdisplay <vm>" VIRT-CONSOLE.warn.act.1
                action "virsh -c qemu:///system edit <vm>" VIRT-CONSOLE.warn.act.2
                action "ssh -L 5900:127.0.0.1:5900 <user>@<host>" VIRT-CONSOLE.warn.act.3
                caution VIRT-CONSOLE.warn.caution
                evidence "$(t VIRT-CONSOLE.ev.1)" "${virt_consoles%$'\n'}"
            elif (( n_gfx > 0 )); then
                finding OK VIRT-CONSOLE "$(t VIRT-CONSOLE.ok.title)"
            fi

            # ---- snapshots ----
            if (( n_snap_total > 0 )); then
                finding INFO VIRT-SNAPSHOTS "$(t VIRT-SNAPSHOTS.info.title n="$n_snap_total" vms="$n_snap_vms" oldest="${snap_oldest%% *}")"
                impact VIRT-SNAPSHOTS.info.impact
                action "virsh -r -c qemu:///system snapshot-list <vm> --tree" VIRT-SNAPSHOTS.info.act.1
                action "virsh -r -c qemu:///system snapshot-info <vm> --snapshotname <snapshot>" VIRT-SNAPSHOTS.info.act.2
                action "virsh -c qemu:///system snapshot-delete <vm> --snapshotname <snapshot>" VIRT-SNAPSHOTS.info.act.3
                caution VIRT-SNAPSHOTS.info.caution
                evidence "$(t VIRT-SNAPSHOTS.ev.1)" "${virt_snaps%$'\n'}"
            fi
        fi

        # ---- disk images that no VM uses ----
        orphans=""; orphan_bytes=0; n_orphans=0
        for p in "${!VOL_IMG[@]}"; do
            [[ -n "${VIRT_USED[$p]+x}" ]] && continue
            virt_path "$p"
            orphans+="${VOL_LABEL[$p]}  ${VP}  $(t VIRT-VMS.ev.size cap="${VOL_CAP[$p]}" alloc="${VOL_ALLOC[$p]}")"$'\n'
            orphan_bytes=$((orphan_bytes + ${VOL_BYTES[$p]:-0}))
            n_orphans=$((n_orphans + 1))
        done
        if (( n_orphans > 0 )); then
            finding INFO VIRT-IMAGE-ORPHAN "$(t VIRT-IMAGE-ORPHAN.info.title n="$n_orphans" size="$(virt_human "$orphan_bytes")")"
            impact VIRT-IMAGE-ORPHAN.info.impact
            action "virsh -r -c qemu:///system vol-list --details <pool>" VIRT-IMAGE-ORPHAN.info.act.1
            action "sudo qemu-img info -U --backing-chain <image>" VIRT-IMAGE-ORPHAN.info.act.2
            action "virsh -c qemu:///system vol-delete --pool <pool> <volume>" VIRT-IMAGE-ORPHAN.info.act.3
            caution VIRT-IMAGE-ORPHAN.info.caution
            evidence "$(t VIRT-IMAGE-ORPHAN.ev.1)" "$(LC_ALL=C sort <<<"${orphans%$'\n'}")"
        fi
        (( n_pools_inactive > 0 )) && partial VIRT-IMAGE-ORPHAN "$(t VIRT-IMAGE-ORPHAN.partial.1 n="$n_pools_inactive")"
    fi

    # ---- group membership (equivalent to root) ----
    members="$(getent group libvirt | cut -d: -f4)"
    if [[ -n "$members" ]]; then
        finding INFO VIRT-GROUP "$(t VIRT-GROUP.info.title members="${members//,/, }")"
        impact VIRT-GROUP.info.impact
        # A single member is named in the command; several stay generic.
        member_cmd="<user>"
        [[ "$members" != *,* ]] && member_cmd="$(safe_name "$members" "<user>")"
        action "getent group libvirt" VIRT-GROUP.info.act.1
        action "" VIRT-GROUP.info.act.2
        action "sudo gpasswd -d ${member_cmd} libvirt" VIRT-GROUP.info.act.3
        caution VIRT-GROUP.info.caution
    fi
fi

# ---- lxd group, when LXD is installed ----------------------------------------------
# Ubuntu adds the first account to the lxd group whether LXD is installed or
# not; the membership only matters once LXD is there (its socket belongs to
# that group), so it is reported only then, libvirt or not.
if [[ -e /snap/lxd/current ]] || pkg_installed lxd; then
    members="$(getent group lxd | cut -d: -f4)"
    if [[ -n "$members" ]]; then
        finding INFO VIRT-LXD-GROUP "$(t VIRT-LXD-GROUP.info.title members="${members//,/, }")"
        impact VIRT-LXD-GROUP.info.impact
        member_cmd="<user>"
        [[ "$members" != *,* ]] && member_cmd="$(safe_name "$members" "<user>")"
        action "getent group lxd" VIRT-LXD-GROUP.info.act.1
        action "sudo gpasswd -d ${member_cmd} lxd" VIRT-LXD-GROUP.info.act.2
        caution VIRT-LXD-GROUP.info.caution
    fi
fi
