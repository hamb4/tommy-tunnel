#!/usr/bin/env bash
#===============================================================================
#  ████████╗██╗   ██╗██████╗ ███╗   ███╗
#  ╚══██╔══╝╚██╗ ██╔╝██╔══██╗████╗ ████║
#     ██║    ╚████╔╝ ██████╔╝██╔████╔██║
#     ██║     ╚██╔╝  ██╔══██╗██║╚██╔╝██║
#     ██║      ██║   ██████╔╝██║ ╚═╝ ██║
#     ╚═╝      ╚═╝   ╚═════╝ ╚═╝     ╚═╝
#
#  Script Name:    Tommy
#  Version:        3.0
#  Author:         hamb4
#  Description:    Secure Tunnel Setup - Iranian Server (Client) Side
#  Repository:     https://github.com/hamb4/tommy-tunnel
#
#  Protocols:
#    1) Xray VLESS + Reality   (Best stealth, TCP-based)
#    2) Hysteria2              (Best speed, UDP/QUIC-based)
#    3) Shadowsocks-2022       (Battle-tested, simple)
#    4) TUIC                   (QUIC-based, low latency)
#    5) WireGuard              (Kernel-level VPN, fastest raw throughput)
#    6) Brook                  (Ultra-lightweight, simple)
#    7) SSH Tunnel             (No extra software, always available)
#    8) Port Forwarding        (Forward specific ports through tunnel)
#
#  USAGE:
#    chmod +x tommy-client-iran.sh
#    sudo ./tommy-client-iran.sh
#===============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── Config ────────────────────────────────────────────────────────────────────
SOCKS_PORT="10808"
HTTP_PORT="10809"
FOREIGN_IP=""
PROTOCOL=""
TOMMY_VER="3.0"

# ── Helper Functions ──────────────────────────────────────────────────────────
info()  { echo -e "${GREEN}[Tommy]${NC} $*"; }
warn()  { echo -e "${YELLOW}[Tommy WARN]${NC} $*"; }
error() { echo -e "${RED}[Tommy ERROR]${NC} $*"; exit 1; }
banner() {
    echo -e "${CYAN}"
    echo "  ████████╗██╗   ██╗██████╗ ███╗   ███╗"
    echo "  ╚══██╔══╝╚██╗ ██╔╝██╔══██╗████╗ ████║"
    echo "     ██║    ╚████╔╝ ██████╔╝██╔████╔██║"
    echo "     ██║     ╚██╔╝  ██╔══██╗██║╚██╔╝██║"
    echo "     ██║      ██║   ██████╔╝██║ ╚═╝ ██║  v${TOMMY_VER}"
    echo "     ╚═╝      ╚═╝   ╚═════╝ ╚═╝     ╚═╝  by hamb4"
    echo -e "${NC}"
}

check_root() { [[ $EUID -eq 0 ]] || error "Run as root."; }

generate_uuid() { uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid; }
generate_password() { openssl rand -base64 32; }

open_firewall() {
    local port=$1
    local proto=${2:-tcp}
    info "Opening ${proto^^} port ${port}..."
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active" && ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
    command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1 && { firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; } || true
    command -v iptables &>/dev/null && iptables -I INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || true
}

install_deps() {
    info "Installing dependencies..."
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
            apt-get update -y
            apt-get install -y curl wget unzip openssl wireguard-tools autossh sshpass socat qrencode 2>/dev/null || true
        elif [[ "$ID" == "centos" || "$ID" == "rhel" || "$ID" == "rocky" ]]; then
            yum install -y curl wget unzip openssl wireguard-tools autossh sshpass socat 2>/dev/null || true
        fi
    fi
}

# ── Port Forwarding Setup (called after tunnel is established) ────────────────
setup_port_forwarding() {
    echo ""
    info "━━━ Port Forwarding Setup ━━━"
    info "Forward specific ports through the Tommy tunnel."
    read -rp "Set up port forwarding? [y/N]: " DO_PF
    [[ "${DO_PF,,}" != "y" ]] && return

    echo ""
    info "Choose direction:"
    echo "  L) Local  - Forward LOCAL port to REMOTE host (via tunnel)"
    echo "  R) Remote - Forward REMOTE port to LOCAL service"
    echo "  M) Multiple local rules"
    read -rp "Direction [L/R/M]: " PF_DIR
    PF_DIR="${PF_DIR^^}"

    if [[ "$PF_DIR" == "M" ]]; then
        # Multiple local forwarding rules
        info "Enter rules one per line. Format: local_port:dest_host:dest_port"
        info "Example: 3306:db.example.com:3306"
        info "         8080:api.service.com:443"
        echo ""

        PF_RULES=()
        while true; do
            read -rp "Rule (blank to finish): " PF_RULE
            [[ -z "$PF_RULE" ]] && break
            PF_RULES+=("$PF_RULE")
        done

        if [[ ${#PF_RULES[@]} -eq 0 ]]; then
            warn "No rules entered, skipping port forwarding."
            return
        fi

        # Route based on active protocol
        if [[ "$PROTOCOL" == "xray" ]]; then
            _pf_xray_multi "${PF_RULES[@]}"
        elif [[ "$PROTOCOL" == "ssh" ]]; then
            _pf_ssh_multi "${PF_RULES[@]}"
        elif [[ "$PROTOCOL" == "wireguard" ]]; then
            _pf_iptables_multi "${PF_RULES[@]}"
        else
            # For Hysteria2, SS, TUIC, Brook - use socat through SOCKS5
            _pf_socat_multi "${PF_RULES[@]}"
        fi

    elif [[ "$PF_DIR" == "L" ]]; then
        read -rp "Listen on LOCAL port: " LOCAL_PF_PORT
        read -rp "Forward to REMOTE host:port: " REMOTE_PF_DEST
        REMOTE_PF_HOST=$(echo "$REMOTE_PF_DEST" | cut -d: -f1)
        REMOTE_PF_PORT=$(echo "$REMOTE_PF_DEST" | cut -d: -f2)
        [[ -z "$LOCAL_PF_PORT" || -z "$REMOTE_PF_HOST" || -z "$REMOTE_PF_PORT" ]] && { warn "All fields required."; return; }

        _pf_single_local "$LOCAL_PF_PORT" "$REMOTE_PF_HOST" "$REMOTE_PF_PORT"

    elif [[ "$PF_DIR" == "R" ]]; then
        read -rp "Listen on REMOTE port (foreign server): " REMOTE_PF_PORT
        read -rp "Forward to LOCAL host:port (this server): " LOCAL_PF_DEST
        LOCAL_PF_HOST=$(echo "$LOCAL_PF_DEST" | cut -d: -f1)
        LOCAL_PF_PORT=$(echo "$LOCAL_PF_DEST" | cut -d: -f2)
        [[ -z "$REMOTE_PF_PORT" || -z "$LOCAL_PF_HOST" || -z "$LOCAL_PF_PORT" ]] && { warn "All fields required."; return; }

        _pf_single_remote "$REMOTE_PF_PORT" "$LOCAL_PF_HOST" "$LOCAL_PF_PORT"
    fi
}

# ── Single local port forward ─────────────────────────────────────────────────
_pf_single_local() {
    local lport=$1 rhost=$2 rport=$3

    if [[ "$PROTOCOL" == "xray" ]]; then
        _pf_xray_add "$lport" "$rhost" "$rport"
    elif [[ "$PROTOCOL" == "ssh" ]]; then
        _pf_ssh_add_local "$lport" "$rhost" "$rport"
    elif [[ "$PROTOCOL" == "wireguard" ]]; then
        _pf_iptables_add "$lport" "$rhost" "$rport"
    else
        _pf_socat_add "$lport" "$rhost" "$rport"
    fi
}

# ── Single remote port forward ────────────────────────────────────────────────
_pf_single_remote() {
    local rport=$1 lhost=$2 lport=$3

    if [[ "$PROTOCOL" == "ssh" ]]; then
        _pf_ssh_add_remote "$rport" "$lhost" "$lport"
    else
        warn "Remote forwarding only works with SSH. Use SSH tunnel for remote PF."
    fi
}

# ── Xray dokodemo-door PF ────────────────────────────────────────────────────
_pf_xray_add() {
    local lport=$1 rhost=$2 rport=$3
    info "Xray PF: 0.0.0.0:${lport} -> ${rhost}:${rport}"
    # This modifies the running xray config - add dokodemo-door inbound
    python3 -c "
import json, sys
with open('/usr/local/etc/xray/config.json') as f: cfg=json.load(f)
cfg['inbounds'].append({
    'tag':'pf-${lport}',
    'listen':'0.0.0.0','port':${lport},
    'protocol':'dokodemo-door',
    'settings':{'address':'${rhost}','port':${rport},'network':'tcp'},
    'sniffing':{'enabled':True,'destOverride':['http','tls']}
})
cfg['routing']['rules'].insert(0,{'type':'field','inboundTag':['pf-${lport}'],'outboundTag':'vless-reality'})
with open('/usr/local/etc/xray/config.json','w') as f: json.dump(cfg,f,indent=2)
" 2>/dev/null && systemctl restart xray || warn "Xray PF config failed"
    open_firewall "$lport" tcp
    info "Forwarding active: 0.0.0.0:${lport} -> ${rhost}:${rport}"
}

_pf_xray_multi() {
    local rules=("$@")
    for rule in "${rules[@]}"; do
        local lport=$(echo "$rule" | cut -d: -f1)
        local rhost=$(echo "$rule" | cut -d: -f2)
        local rport=$(echo "$rule" | cut -d: -f3)
        _pf_xray_add "$lport" "$rhost" "$rport"
    done
}

# ── SSH PF ────────────────────────────────────────────────────────────────────
_pf_ssh_add_local() {
    local lport=$1 rhost=$2 rport=$3
    info "SSH PF: 0.0.0.0:${lport} -> ${rhost}:${rport}"
    cat > /etc/systemd/system/tommy-pf-ssh-${lport}.service <<SVEOF
[Unit]
Description=Tommy SSH Local PF :${lport} -> ${rhost}:${rport}
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/autossh -L 0.0.0.0:${lport}:${rhost}:${rport} -N -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p ${SSH_PORT:-22} ${SSH_USER:-tommy-tunnel}@${FOREIGN_IP}
Restart=on-failure
RestartSec=10
Environment="AUTOSSH_GATETIME=0"
[Install]
WantedBy=multi-user.target
SVEOF
    systemctl daemon-reload
    systemctl enable "tommy-pf-ssh-${lport}"
    systemctl restart "tommy-pf-ssh-${lport}"
    open_firewall "$lport" tcp
    info "SSH local forwarding active: :${lport} -> ${rhost}:${rport}"
}

_pf_ssh_add_remote() {
    local rport=$1 lhost=$2 lport=$3
    info "SSH PF: ${FOREIGN_IP}:${rport} -> ${lhost}:${lport}"
    cat > /etc/systemd/system/tommy-pf-ssh-r${rport}.service <<SVEOF
[Unit]
Description=Tommy SSH Remote PF ${FOREIGN_IP}:${rport} -> ${lhost}:${lport}
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/autossh -R 0.0.0.0:${rport}:${lhost}:${lport} -N -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p ${SSH_PORT:-22} ${SSH_USER:-tommy-tunnel}@${FOREIGN_IP}
Restart=on-failure
RestartSec=10
Environment="AUTOSSH_GATETIME=0"
[Install]
WantedBy=multi-user.target
SVEOF
    systemctl daemon-reload
    systemctl enable "tommy-pf-ssh-r${rport}"
    systemctl restart "tommy-pf-ssh-r${rport}"
    info "SSH remote forwarding active: ${FOREIGN_IP}:${rport} -> ${lhost}:${lport}"
}

_pf_ssh_multi() {
    local rules=("$@")
    for rule in "${rules[@]}"; do
        local lport=$(echo "$rule" | cut -d: -f1)
        local rhost=$(echo "$rule" | cut -d: -f2)
        local rport=$(echo "$rule" | cut -d: -f3)
        _pf_ssh_add_local "$lport" "$rhost" "$rport"
    done
}

# ── iptables PF (WireGuard) ──────────────────────────────────────────────────
_pf_iptables_add() {
    local lport=$1 rhost=$2 rport=$3
    info "iptables PF: 0.0.0.0:${lport} -> ${rhost}:${rport}"
    iptables -t nat -A PREROUTING -p tcp --dport "${lport}" -j DNAT --to-destination "${rhost}:${rport}" 2>/dev/null || true
    iptables -t nat -A PREROUTING -p udp --dport "${lport}" -j DNAT --to-destination "${rhost}:${rport}" 2>/dev/null || true
    iptables -t nat -A POSTROUTING -d "${rhost}" -j MASQUERADE 2>/dev/null || true
    open_firewall "$lport" tcp
    open_firewall "$lport" udp
    info "iptables forwarding active: :${lport} -> ${rhost}:${rport}"
}

_pf_iptables_multi() {
    local rules=("$@")
    for rule in "${rules[@]}"; do
        local lport=$(echo "$rule" | cut -d: -f1)
        local rhost=$(echo "$rule" | cut -d: -f2)
        local rport=$(echo "$rule" | cut -d: -f3)
        _pf_iptables_add "$lport" "$rhost" "$rport"
    done
    # Save rules persistently
    iptables-save > /etc/tommy-iptables-pf.rules 2>/dev/null || true
    cat > /etc/systemd/system/tommy-pf-iptables.service <<SVEOF
[Unit]
Description=Tommy iptables Port Forwarding
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/iptables-restore < /etc/tommy-iptables-pf.rules
[Install]
WantedBy=multi-user.target
SVEOF
    systemctl daemon-reload
    systemctl enable tommy-pf-iptables 2>/dev/null || true
}

# ── socat PF (through SOCKS5 proxy) ─────────────────────────────────────────
_pf_socat_add() {
    local lport=$1 rhost=$2 rport=$3
    info "socat PF: 0.0.0.0:${lport} -> ${rhost}:${rport} (via SOCKS5)"
    if ! command -v socat &>/dev/null; then
        apt-get install -y socat 2>/dev/null || yum install -y socat 2>/dev/null || true
    fi
    cat > /etc/systemd/system/tommy-pf-socat-${lport}.service <<SVEOF
[Unit]
Description=Tommy socat PF :${lport} -> ${rhost}:${rport}
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${lport},fork,reuseaddr SOCKS5A:127.0.0.1:${rhost}:${rport},socksport=${SOCKS_PORT}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SVEOF
    systemctl daemon-reload
    systemctl enable "tommy-pf-socat-${lport}"
    systemctl restart "tommy-pf-socat-${lport}"
    open_firewall "$lport" tcp
    info "socat forwarding active: :${lport} -> ${rhost}:${rport}"
}

_pf_socat_multi() {
    local rules=("$@")
    for rule in "${rules[@]}"; do
        local lport=$(echo "$rule" | cut -d: -f1)
        local rhost=$(echo "$rule" | cut -d: -f2)
        local rport=$(echo "$rule" | cut -d: -f3)
        _pf_socat_add "$lport" "$rhost" "$rport"
    done
}

# ── System-Wide Proxy ─────────────────────────────────────────────────────────
setup_system_proxy() {
    echo ""
    read -rp "Set up system-wide proxy? [y/N]: " DO_SYS
    [[ "${DO_SYS,,}" != "y" ]] && return

    if [[ "$PROTOCOL" == "wireguard" ]]; then
        info "WireGuard tunnels all traffic at kernel level. No proxy env needed."
        return
    fi

    cat > /etc/profile.d/tommy-proxy.sh <<ENVEOF
export http_proxy="http://127.0.0.1:${HTTP_PORT}"
export https_proxy="http://127.0.0.1:${HTTP_PORT}"
export HTTP_PROXY="http://127.0.0.1:${HTTP_PORT}"
export HTTPS_PROXY="http://127.0.0.1:${HTTP_PORT}"
export no_proxy="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
export NO_PROXY="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
ENVEOF
    chmod +x /etc/profile.d/tommy-proxy.sh
    source /etc/profile.d/tommy-proxy.sh
    info "System proxy set: http://127.0.0.1:${HTTP_PORT}"

    if [[ -d /etc/apt ]]; then
        cat > /etc/apt/apt.conf.d/99tommy-proxy <<PEOF
Acquire::http::Proxy "http://127.0.0.1:${HTTP_PORT}";
Acquire::https::Proxy "http://127.0.0.1:${HTTP_PORT}";
PEOF
    fi
}

# ── Connection Test ────────────────────────────────────────────────────────────
test_connection() {
    echo ""
    info "━━━ Testing Connection ━━━"
    sleep 3

    if [[ "$PROTOCOL" == "wireguard" ]]; then
        RESULT=$(curl -s --connect-timeout 10 https://api.ipify.org 2>/dev/null || echo "FAILED")
        info "Tunnel IP: ${RESULT}"
        if [[ "$RESULT" != "FAILED" ]]; then info "SUCCESS! Traffic routes through foreign server."; fi
        return
    fi

    SOCKS_RESULT=$(curl -x socks5h://127.0.0.1:${SOCKS_PORT} -s --connect-timeout 10 https://api.ipify.org 2>/dev/null || echo "FAILED")
    if [[ "$SOCKS_RESULT" != "FAILED" && -n "$SOCKS_RESULT" ]]; then
        info "SOCKS5 OK! Tunnel IP: ${SOCKS_RESULT}"
    else
        warn "SOCKS5 test failed."
    fi

    if [[ "$PROTOCOL" != "ssh" ]]; then
        HTTP_RESULT=$(curl -x http://127.0.0.1:${HTTP_PORT} -s --connect-timeout 10 https://api.ipify.org 2>/dev/null || echo "FAILED")
        [[ "$HTTP_RESULT" != "FAILED" ]] && info "HTTP proxy OK! Tunnel IP: ${HTTP_RESULT}" || warn "HTTP proxy test failed."
    fi

    DIRECT_IP=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo "unknown")
    info "Direct IP: ${DIRECT_IP}"
    if [[ "$SOCKS_RESULT" != "FAILED" && "$SOCKS_RESULT" != "$DIRECT_IP" ]]; then
        info "SUCCESS! Your IP is hidden through Tommy!"
    fi
}

# ── Show Summary ──────────────────────────────────────────────────────────────
show_summary() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Tommy v${TOMMY_VER} - Setup Complete!              ║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Protocol: ${PROTOCOL}$(printf '%*s' $((25 - ${#PROTOCOL})) '')║${NC}"
    echo -e "${CYAN}║  Foreign:  ${FOREIGN_IP}$(printf '%*s' $((25 - ${#FOREIGN_IP})) '')║${NC}"
    if [[ "$PROTOCOL" != "wireguard" ]]; then
        echo -e "${CYAN}║  SOCKS5:   127.0.0.1:${SOCKS_PORT}                  ║${NC}"
        echo -e "${CYAN}║  HTTP:     127.0.0.1:${HTTP_PORT}                  ║${NC}"
    else
        echo -e "${CYAN}║  All traffic tunneled at kernel level         ║${NC}"
    fi
    echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
show_menu() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         Tommy v${TOMMY_VER} - Iranian Server Side               ║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  1) Xray VLESS + Reality   (Best stealth)                ║${NC}"
    echo -e "${CYAN}║  2) Hysteria2              (Best speed, QUIC)            ║${NC}"
    echo -e "${CYAN}║  3) Shadowsocks-2022       (Battle-tested)               ║${NC}"
    echo -e "${CYAN}║  4) TUIC                   (QUIC, low latency)           ║${NC}"
    echo -e "${CYAN}║  5) WireGuard              (Kernel VPN)                  ║${NC}"
    echo -e "${CYAN}║  6) Brook                  (Ultra-lightweight)            ║${NC}"
    echo -e "${CYAN}║  7) SSH Tunnel             (No extra software)            ║${NC}"
    echo -e "${CYAN}║  8) Port Forwarding Only   (Standalone PF)               ║${NC}"
    echo -e "${CYAN}║  9) Exit                                                  ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "Select [1-9]: " CHOICE
    case "$CHOICE" in
        1) PROTOCOL="xray" ;; 2) PROTOCOL="hysteria2" ;;
        3) PROTOCOL="shadowsocks" ;; 4) PROTOCOL="tuic" ;;
        5) PROTOCOL="wireguard" ;; 6) PROTOCOL="brook" ;;
        7) PROTOCOL="ssh" ;; 8) PROTOCOL="portforward" ;;
        9) exit 0 ;; *) error "Invalid choice." ;;
    esac
}

get_foreign_ip() {
    echo ""
    read -rp "Enter FOREIGN server IP: " FOREIGN_IP
    [[ -z "$FOREIGN_IP" ]] && error "IP required."
}

# ══════════════════════════════════════════════════════════════════════════════
#  1. XRAY CLIENT (VLESS+Reality)
# ══════════════════════════════════════════════════════════════════════════════
setup_xray_client() {
    info "━━━ Xray VLESS+Reality Client ━━━"
    ! command -v xray &>/dev/null && { info "Installing Xray..."; bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; }

    echo ""; info "Enter credentials from foreign server (/root/xray-client-info.txt):"
    read -rp "UUID: " VLESS_UUID
    read -rp "Port [443]: " VLESS_PORT; VLESS_PORT="${VLESS_PORT:-443}"
    read -rp "SNI [www.microsoft.com]: " SNI; SNI="${SNI:-www.microsoft.com}"
    read -rp "Public Key: " PBK
    read -rp "Short ID: " SID
    read -rp "Fingerprint [chrome]: " FP; FP="${FP:-chrome}"
    [[ -z "$VLESS_UUID" || -z "$PBK" || -z "$SID" ]] && error "UUID, Public Key, Short ID are required."

    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<XEOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[
    {"tag":"socks","listen":"127.0.0.1","port":${SOCKS_PORT},"protocol":"socks","settings":{"auth":"noauth","udp":true},"sniffing":{"enabled":true,"destOverride":["http","tls"]}},
    {"tag":"http","listen":"127.0.0.1","port":${HTTP_PORT},"protocol":"http","settings":{"allowTransparent":false},"sniffing":{"enabled":true,"destOverride":["http","tls"]}}
  ],
  "outbounds":[
    {"tag":"vless-reality","protocol":"vless","settings":{"vnext":[{"address":"${FOREIGN_IP}","port":${VLESS_PORT},"users":[{"id":"${VLESS_UUID}","encryption":"none","flow":"xtls-rprx-vision"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"${SNI}","fingerprint":"${FP}","publicKey":"${PBK}","shortId":"${SID}"}}},
    {"tag":"direct","protocol":"freedom","settings":{}}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]}
}
XEOF
    systemctl enable xray; systemctl restart xray; sleep 2
    systemctl is-active --quiet xray && info "Xray running! SOCKS5:${SOCKS_PORT} HTTP:${HTTP_PORT}" || warn "Xray may have failed."
}

# ══════════════════════════════════════════════════════════════════════════════
#  2. HYSTERIA2 CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_hysteria2_client() {
    info "━━━ Hysteria2 Client ━━━"
    ! command -v hysteria &>/dev/null && { info "Installing Hysteria2..."; bash <(curl -fsSL https://get.hy2.sh/); }

    echo ""; info "Enter credentials from foreign server:"
    read -rp "Password: " HY_PASS
    read -rp "Port [8443]: " HY_PORT; HY_PORT="${HY_PORT:-8443}"
    read -rp "SNI [bing.com]: " HY_SNI; HY_SNI="${HY_SNI:-bing.com}"
    [[ -z "$HY_PASS" ]] && error "Password required."

    mkdir -p /etc/hysteria
    cat > /etc/hysteria/client.yaml <<HEOF
server: ${FOREIGN_IP}:${HY_PORT}
auth: ${HY_PASS}
tls:
  sni: ${HY_SNI}
  insecure: true
socks5:
  listen: 127.0.0.1:${SOCKS_PORT}
http:
  listen: 127.0.0.1:${HTTP_PORT}
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
bandwidth:
  up: 100 mbps
  down: 200 mbps
HEOF
    cat > /etc/systemd/system/tommy-hysteria.service <<SEOF
[Unit]
Description=Tommy Hysteria2 Client
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria client -c /etc/hysteria/client.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SEOF
    systemctl daemon-reload; systemctl enable tommy-hysteria; systemctl restart tommy-hysteria; sleep 2
    systemctl is-active --quiet tommy-hysteria && info "Hysteria2 running! SOCKS5:${SOCKS_PORT} HTTP:${HTTP_PORT}" || warn "Hysteria2 may have failed."
}

# ══════════════════════════════════════════════════════════════════════════════
#  3. SHADOWSOCKS CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_shadowsocks_client() {
    info "━━━ Shadowsocks-2022 Client ━━━"
    if ! command -v sing-box &>/dev/null; then
        info "Installing sing-box..."
        bash -c "$(curl -fsSL https://sing-box.app/deb-install.sh)" 2>/dev/null || {
            ARCH=$(uname -m); SARCH=$([[ "$ARCH" == "aarch64" ]] && echo "arm64" || echo "amd64")
            curl -Lo /tmp/sing-box.deb "https://github.com/SagerNet/sing-box/releases/latest/download/sing-box_${SARCH}.deb" 2>/dev/null || true
            [[ -f /tmp/sing-box.deb ]] && dpkg -i /tmp/sing-box.deb 2>/dev/null || true
        }
    fi

    if command -v sing-box &>/dev/null; then
        echo ""; info "Enter credentials:"
        read -rp "Port [8388]: " SS_PORT; SS_PORT="${SS_PORT:-8388}"
        read -rp "Method [2022-blake3-aes-256-gcm]: " SS_METHOD; SS_METHOD="${SS_METHOD:-2022-blake3-aes-256-gcm}"
        read -rp "Password: " SS_PASS
        [[ -z "$SS_PASS" ]] && error "Password required."

        mkdir -p /etc/sing-box
        cat > /etc/sing-box/client.json <<SEOF
{
  "log":{"level":"warn"},
  "inbounds":[
    {"type":"socks","listen":"127.0.0.1","listen_port":${SOCKS_PORT}},
    {"type":"http","listen":"127.0.0.1","listen_port":${HTTP_PORT}}
  ],
  "outbounds":[
    {"type":"shadowsocks","server":"${FOREIGN_IP}","server_port":${SS_PORT},"method":"${SS_METHOD}","password":"${SS_PASS}"}
  ]
}
SEOF
        cat > /etc/systemd/system/tommy-shadowsocks.service <<SVEOF
[Unit]
Description=Tommy Shadowsocks Client
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/client.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SVEOF
        systemctl daemon-reload; systemctl enable tommy-shadowsocks; systemctl restart tommy-shadowsocks; sleep 2
        systemctl is-active --quiet tommy-shadowsocks && info "Shadowsocks running! SOCKS5:${SOCKS_PORT} HTTP:${HTTP_PORT}" || warn "Shadowsocks may have failed."
    else
        warn "sing-box unavailable. Install manually."
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  4. TUIC CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_tuic_client() {
    info "━━━ TUIC v5 Client ━━━"
    if ! command -v tuic-client &>/dev/null; then
        info "Installing TUIC client..."
        TARCH=$([[ "$(uname -m)" == "aarch64" ]] && echo "aarch64-unknown-linux-gnu" || echo "x86_64-unknown-linux-gnu")
        curl -Lo /usr/local/bin/tuic-client "https://github.com/EAimTY/tuic/releases/latest/download/tuic-client-${TARCH}" 2>/dev/null && chmod +x /usr/local/bin/tuic-client || { warn "TUIC download failed."; return; }
    fi

    echo ""; info "Enter credentials:"
    read -rp "UUID: " TUIC_UUID
    read -rp "Password: " TUIC_PASS
    read -rp "Port [8444]: " TUIC_PORT; TUIC_PORT="${TUIC_PORT:-8444}"
    [[ -z "$TUIC_UUID" || -z "$TUIC_PASS" ]] && error "UUID and Password required."

    mkdir -p /etc/tuic
    cat > /etc/tuic/client.json <<TEOF
{
  "relay":{"server":"${FOREIGN_IP}:${TUIC_PORT}","uuid":"${TUIC_UUID}","password":"${TUIC_PASS}"},
  "local":{"server":"127.0.0.1:${SOCKS_PORT}"},
  "tls":{"insecure":true,"alpn":["h3"]}
}
TEOF
    cat > /etc/systemd/system/tommy-tuic.service <<SVEOF
[Unit]
Description=Tommy TUIC Client
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/tuic-client -c /etc/tuic/client.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SVEOF
    systemctl daemon-reload; systemctl enable tommy-tuic; systemctl restart tommy-tuic; sleep 2
    systemctl is-active --quiet tommy-tuic && info "TUIC running! SOCKS5:${SOCKS_PORT}" || warn "TUIC may have failed."
}

# ══════════════════════════════════════════════════════════════════════════════
#  5. WIREGUARD CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_wireguard_client() {
    info "━━━ WireGuard Client ━━━"
    ! command -v wg &>/dev/null && { info "Installing WireGuard..."; apt-get install -y wireguard-tools 2>/dev/null || yum install -y wireguard-tools 2>/dev/null || true; }

    echo ""; info "Enter/paste WireGuard client config (from foreign server):"
    info "Paste the [Interface]...[Peer] block (end with blank line):"
    WG_CONFIG=""
    while IFS= read -r line; do [[ -z "$line" ]] && break; WG_CONFIG="${WG_CONFIG}${line}"$'\n'; done

    if [[ -z "$WG_CONFIG" ]]; then
        read -rp "Client Private Key: " WG_PRIVKEY
        read -rp "Client IP [10.66.66.2/24]: " WG_IP; WG_IP="${WG_IP:-10.66.66.2/24}"
        read -rp "Server Public Key: " WG_PUBKEY
        read -rp "Server Port [51820]: " WG_PORT; WG_PORT="${WG_PORT:-51820}"
        WG_CONFIG="[Interface]
PrivateKey = ${WG_PRIVKEY}
Address = ${WG_IP}
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = ${WG_PUBKEY}
Endpoint = ${FOREIGN_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25"
    fi

    echo "$WG_CONFIG" > /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf 2>/dev/null || true
    sysctl -p /etc/sysctl.conf 2>/dev/null || true

    wg-quick up wg0 2>/dev/null || true; sleep 2
    wg show wg0 &>/dev/null && info "WireGuard connected! All traffic tunneled." || warn "WireGuard may have failed."
}

# ══════════════════════════════════════════════════════════════════════════════
#  6. BROOK CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_brook_client() {
    info "━━━ Brook Client ━━━"
    if ! command -v brook &>/dev/null; then
        info "Installing Brook..."
        BARCH=$([[ "$(uname -m)" == "aarch64" ]] && echo "arm64" || echo "amd64")
        curl -Lo /tmp/brook "https://github.com/txthinking/brook/releases/latest/download/brook_linux_${BARCH}" && chmod +x /tmp/brook && mv /tmp/brook /usr/local/bin/brook || { warn "Brook download failed."; return; }
    fi

    echo ""; info "Enter credentials:"
    read -rp "Port [9999]: " BK_PORT; BK_PORT="${BK_PORT:-9999}"
    read -rp "Password: " BK_PASS
    [[ -z "$BK_PASS" ]] && error "Password required."

    cat > /etc/systemd/system/tommy-brook.service <<SVEOF
[Unit]
Description=Tommy Brook Client
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/brook client -s ${FOREIGN_IP}:${BK_PORT} -p ${BK_PASS} --socks5 127.0.0.1:${SOCKS_PORT} --http 127.0.0.1:${HTTP_PORT}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SVEOF
    systemctl daemon-reload; systemctl enable tommy-brook; systemctl restart tommy-brook; sleep 2
    systemctl is-active --quiet tommy-brook && info "Brook running! SOCKS5:${SOCKS_PORT} HTTP:${HTTP_PORT}" || warn "Brook may have failed."
}

# ══════════════════════════════════════════════════════════════════════════════
#  7. SSH TUNNEL CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_ssh_client() {
    info "━━━ SSH Tunnel Client ━━━"
    command -v autossh &>/dev/null || apt-get install -y autossh 2>/dev/null || true

    echo ""; info "Enter SSH credentials:"
    read -rp "SSH Port [22]: " SSH_PORT; SSH_PORT="${SSH_PORT:-22}"
    read -rp "Username [tommy-tunnel]: " SSH_USER; SSH_USER="${SSH_USER:-tommy-tunnel}"
    read -rp "Password (blank=key auth): " SSH_PASSWORD

    if [[ -n "$SSH_PASSWORD" ]]; then
        command -v sshpass &>/dev/null || apt-get install -y sshpass 2>/dev/null || true
        cat > /etc/systemd/system/tommy-ssh.service <<SVEOF
[Unit]
Description=Tommy SSH Tunnel
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/sshpass -p '${SSH_PASSWORD}' autossh -D 127.0.0.1:${SOCKS_PORT} -N -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p ${SSH_PORT} ${SSH_USER}@${FOREIGN_IP}
Restart=on-failure
RestartSec=10
Environment="AUTOSSH_GATETIME=0"
[Install]
WantedBy=multi-user.target
SVEOF
    else
        [[ ! -f ~/.ssh/tommy_key ]] && { ssh-keygen -t ed25519 -f ~/.ssh/tommy_key -N "" -q; info "Key generated. Add to foreign server:"; cat ~/.ssh/tommy_key.pub; read -rp "Press Enter after adding key..."; }
        cat > /etc/systemd/system/tommy-ssh.service <<SVEOF
[Unit]
Description=Tommy SSH Tunnel
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/autossh -D 127.0.0.1:${SOCKS_PORT} -N -i /root/.ssh/tommy_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p ${SSH_PORT} ${SSH_USER}@${FOREIGN_IP}
Restart=on-failure
RestartSec=10
Environment="AUTOSSH_GATETIME=0"
[Install]
WantedBy=multi-user.target
SVEOF
    fi

    systemctl daemon-reload; systemctl enable tommy-ssh; systemctl restart tommy-ssh; sleep 3
    systemctl is-active --quiet tommy-ssh && info "SSH tunnel running! SOCKS5:${SOCKS_PORT}" || warn "SSH tunnel may have failed."
}

# ══════════════════════════════════════════════════════════════════════════════
#  8. STANDALONE PORT FORWARDING
# ══════════════════════════════════════════════════════════════════════════════
setup_standalone_pf() {
    info "━━━ Standalone Port Forwarding ━━━"
    echo ""
    info "Choose method:"
    echo "  1) SSH Port Forwarding"
    echo "  2) socat TCP/UDP Relay"
    echo "  3) Xray dokodemo-door (needs VLESS credentials)"
    echo "  4) iptables DNAT (needs WireGuard)"
    read -rp "Method [1-4]: " PF_METHOD

    case "$PF_METHOD" in
        1)
            PROTOCOL="ssh"
            read -rp "Foreign server IP: " FOREIGN_IP; [[ -z "$FOREIGN_IP" ]] && error "IP required."
            read -rp "SSH Port [22]: " SSH_PORT; SSH_PORT="${SSH_PORT:-22}"
            read -rp "Username [tommy-tunnel]: " SSH_USER; SSH_USER="${SSH_USER:-tommy-tunnel}"
            setup_port_forwarding
            ;;
        2)
            PROTOCOL="socat"
            ! command -v socat &>/dev/null && apt-get install -y socat 2>/dev/null || true
            setup_port_forwarding
            ;;
        3)
            PROTOCOL="xray"
            read -rp "Foreign server IP: " FOREIGN_IP; [[ -z "$FOREIGN_IP" ]] && error "IP required."
            setup_xray_client
            setup_port_forwarding
            ;;
        4)
            PROTOCOL="wireguard"
            read -rp "Foreign server IP: " FOREIGN_IP; [[ -z "$FOREIGN_IP" ]] && error "IP required."
            setup_wireguard_client
            setup_port_forwarding
            ;;
        *) error "Invalid choice." ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
    banner
    check_root
    show_menu
    install_deps

    if [[ "$PROTOCOL" == "portforward" ]]; then
        setup_standalone_pf
        show_summary
        return
    fi

    get_foreign_ip

    case "$PROTOCOL" in
        xray)        setup_xray_client ;;
        hysteria2)   setup_hysteria2_client ;;
        shadowsocks) setup_shadowsocks_client ;;
        tuic)        setup_tuic_client ;;
        wireguard)   setup_wireguard_client ;;
        brook)       setup_brook_client ;;
        ssh)         setup_ssh_client ;;
    esac

    # Port forwarding INSIDE each protocol
    setup_port_forwarding

    # System-wide proxy
    setup_system_proxy

    # Test connection
    test_connection

    # Summary
    show_summary
}

main "$@"
