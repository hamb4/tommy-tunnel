#!/usr/bin/env bash
#===============================================================================
#  ████████╗██╗   ██╗██████╗ ███╗   ███╗
#  ╚══██╔══╝╚██╗ ██╔╝██╔══██╗████╗ ████║
#     ██║    ╚████╔╝ ██████╔╝██╔████╔██║
#     ██║     ╚██╔╝  ██╔══██╗██║╚██╔╝██║
#     ██║      ██║   ██████╔╝██║ ╚═╝ ██║
#     ╚═╝      ╚═╝   ╚═════╝ ╚═╝     ╚═╝
#
#  Tommy Tunnel v1.0.5
#  Author: hamb4
#  Iranian Server (Client) Script
#  Port Forwarding Tunnel - No xray required
#
#  How it works:
#    1. This script connects to the foreign server's tunnel
#    2. It forwards a local port (e.g. 443) to the foreign server
#    3. In 3x-ui, set External Proxy = this server IP + forwarded port
#    4. Users in Iran connect to this server -> tunnel -> foreign 3x-ui -> internet
#
#  Usage:
#    bash <(curl -LSs https://raw.githubusercontent.com/hamb4/tommy-tunnel/main/tommy-client-iran.sh)
#===============================================================================

set -euo pipefail

TOMMY_VER="1.0.5"
TOMMY_AUTHOR="hamb4"
TOMMY_DIR="/etc/tommy"
TOMMY_REGISTRY="${TOMMY_DIR}/tunnels.registry"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helper Functions ──────────────────────────────────────────────────────────
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root."
        exit 1
    fi
}

get_local_ip() {
    local IP=""
    IP=$(curl -s4 --connect-timeout 5 https://ifconfig.me 2>/dev/null || true)
    if [[ -z "$IP" ]]; then
        IP=$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)
    fi
    if [[ -z "$IP" ]]; then
        IP=$(curl -s4 --connect-timeout 5 https://ip.sb 2>/dev/null || true)
    fi
    if [[ -z "$IP" ]]; then
        read -rp "Enter this server's public IP: " IP
    fi
    echo "$IP"
}

# Read port with validation - if empty or non-numeric, use default
read_port() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local input=""
    read -rp "$prompt [$default]: " input
    input=$(echo "$input" | tr -d '[:space:]')
    if [[ -z "$input" ]] || ! [[ "$input" =~ ^[0-9]+$ ]]; then
        eval "${var_name}=${default}"
    else
        eval "${var_name}=${input}"
    fi
}

# Register tunnel in central registry
register_tunnel() {
    local tname="$1"
    local method="$2"
    local fwd_port="$3"
    local profile="$4"
    mkdir -p "${TOMMY_DIR}"
    if [[ -f "$TOMMY_REGISTRY" ]]; then
        sed -i "/^${tname}|/d" "$TOMMY_REGISTRY" 2>/dev/null || true
    fi
    echo "${tname}|${method}|${fwd_port}|${profile}|$(date '+%Y-%m-%d %H:%M:%S')" >> "$TOMMY_REGISTRY"
    chmod 600 "$TOMMY_REGISTRY"
}

unregister_tunnel() {
    local tname="$1"
    if [[ -f "$TOMMY_REGISTRY" ]]; then
        sed -i "/^${tname}|/d" "$TOMMY_REGISTRY" 2>/dev/null || true
    fi
}

tunnel_exists() {
    local tname="$1"
    if [[ -f "$TOMMY_REGISTRY" ]]; then
        grep -q "^${tname}|" "$TOMMY_REGISTRY" 2>/dev/null && return 0
    fi
    [[ -d "${TOMMY_DIR}/${tname}" ]] && return 0
    [[ -f "/etc/systemd/system/tommy-${tname}.service" ]] && return 0
    return 1
}

open_firewall() {
    local port="$1"
    local proto="${2:-tcp}"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || true
    fi
}

close_firewall() {
    local port="$1"
    local proto="${2:-tcp}"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || true
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
    else
        OS_ID="unknown"
    fi
}

install_pkg() {
    local pkg="$1"
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        apt-get install -y "$pkg" 2>/dev/null || true
    elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
        yum install -y "$pkg" 2>/dev/null || true
    elif [[ "$OS_ID" == "arch" ]]; then
        pacman -Sy --noconfirm "$pkg" 2>/dev/null || true
    fi
}

# ── System Optimization ──────────────────────────────────────────────────────
optimize_system() {
    info "Enabling BBR congestion control..."
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        if ! grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
            cat >> /etc/sysctl.conf <<SYSEOF
# Tommy v${TOMMY_VER} - BBR
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# Tommy v${TOMMY_VER} - Buffers
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.core.netdev_max_backlog=65536
net.ipv4.udp_mem=1048576 2097152 4194304
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
SYSEOF
        fi
        sysctl -p /etc/sysctl.conf 2>/dev/null || true
        info "BBR and buffer optimization enabled."
    else
        info "BBR already enabled."
    fi
}

# ── Banner ───────────────────────────────────────────────────────────────────
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "  ████████╗██╗   ██╗██████╗ ███╗   ███╗"
    echo "  ╚══██╔══╝╚██╗ ██╔╝██╔══██╗████╗ ████║"
    echo "     ██║    ╚████╔╝ ██████╔╝██╔████╔██║"
    echo "     ██║     ╚██╔╝  ██╔══██╗██║╚██╔╝██║"
    echo "     ██║      ██║   ██████╔╝██║ ╚═╝ ██║"
    echo "     ╚═╝      ╚═╝   ╚═════╝ ╚═╝     ╚═╝"
    echo -e "${NC}"
    echo -e "  ${BOLD}Tommy Tunnel v${TOMMY_VER}  |  Author: ${TOMMY_AUTHOR}${NC}"
    echo -e "  ${BLUE}Iranian Server - Port Forwarding Tunnel${NC}"
    echo ""
}

# ── Parse Connection Code ────────────────────────────────────────────────────
parse_connection_code() {
    local code="$1"
    local decoded=""
    decoded=$(echo "$code" | base64 -d 2>/dev/null) || {
        err "Invalid connection code. Could not decode."
        return 1
    }

    # Verify prefix
    if [[ "$decoded" != TOMMY105* ]]; then
        err "Invalid connection code. Wrong format or version."
        return 1
    fi

    # Parse: TOMMY105|method|server_ip|fwd_port|profile|extra_data
    local IFS='|'
    read -r PREFIX CODE_METHOD CODE_SERVER_IP CODE_FWD_PORT CODE_PROFILE CODE_EXTRA <<< "$decoded"

    if [[ -z "$CODE_METHOD" ]] || [[ -z "$CODE_SERVER_IP" ]] || [[ -z "$CODE_FWD_PORT" ]]; then
        err "Connection code is missing required fields."
        return 1
    fi

    # Export for use by caller
    PARSED_METHOD="$CODE_METHOD"
    PARSED_SERVER_IP="$CODE_SERVER_IP"
    PARSED_FWD_PORT="$CODE_FWD_PORT"
    PARSED_PROFILE="$CODE_PROFILE"
    PARSED_EXTRA="$CODE_EXTRA"

    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  SSH TUNNEL CLIENT
# ══════════════════════════════════════════════════════════════════════════════
connect_ssh_tunnel() {
    local TNAME="$1"
    local FOREIGN_IP="$2"
    local SSH_PORT="$3"
    local FWD_PORT="$4"
    local PROFILE="$5"
    local PRIVATE_KEY_B64="$6"
    local SVC_NAME="tommy-${TNAME}"
    local CFG_DIR="${TOMMY_DIR}/${TNAME}"

    info "Setting up SSH Tunnel client..."

    install_pkg autossh
    install_pkg openssh-client

    mkdir -p "${CFG_DIR}"

    # Decode private key from base64
    local PRIVATE_KEY=""
    if [[ -n "$PRIVATE_KEY_B64" ]]; then
        PRIVATE_KEY=$(echo "$PRIVATE_KEY_B64" | base64 -d 2>/dev/null) || {
            err "Failed to decode private key from connection code."
            return 1
        }
    fi

    if [[ -z "$PRIVATE_KEY" ]]; then
        # Fallback: ask user to paste the key manually
        echo ""
        info "Paste the SSH private key from the foreign server."
        info "Press Enter on an empty line when done."
        echo ""
        local KEY_LINES=""
        while IFS= read -r line; do
            if [[ -z "$line" ]]; then
                break
            fi
            KEY_LINES="${KEY_LINES}${line}"$'\n'
        done
        if [[ -z "$KEY_LINES" ]]; then
            err "No private key provided."
            return 1
        fi
        PRIVATE_KEY="$KEY_LINES"
    fi

    # Save private key
    echo "$PRIVATE_KEY" > "${CFG_DIR}/id_tommy"
    chmod 600 "${CFG_DIR}/id_tommy"

    # Profile settings
    local KEEPALIVE=30
    if [[ "$PROFILE" == "speed" ]]; then
        KEEPALIVE=15
    elif [[ "$PROFILE" == "security" ]]; then
        KEEPALIVE=60
    fi

    # Create systemd service for autossh
    cat > "/etc/systemd/system/${SVC_NAME}.service" <<SVCEOF
[Unit]
Description=Tommy SSH Tunnel - ${TNAME}
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/bin/autossh -M 0 -N \\
  -o "ServerAliveInterval=${KEEPALIVE}" \\
  -o "ServerAliveCountMax=3" \\
  -o "StrictHostKeyChecking=no" \\
  -o "UserKnownHostsFile=/dev/null" \\
  -o "ExitOnForwardFailure=yes" \\
  -L 0.0.0.0:${FWD_PORT}:localhost:${FWD_PORT} \\
  -i ${CFG_DIR}/id_tommy \\
  tommy-tunnel@${FOREIGN_IP} -p ${SSH_PORT}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    open_firewall "$FWD_PORT" tcp
    systemctl enable "$SVC_NAME" >/dev/null 2>&1
    systemctl start "$SVC_NAME"

    sleep 3
    if systemctl is-active --quiet "$SVC_NAME"; then
        info "SSH Tunnel is RUNNING! Port ${FWD_PORT} is forwarded to ${FOREIGN_IP}"
    else
        warn "SSH Tunnel may have failed. Check: journalctl -u ${SVC_NAME} -n 30"
    fi

    # Save tunnel info
    cat > "${CFG_DIR}/tunnel-info.txt" <<IEOF
TUNNEL_NAME=${TNAME}
METHOD=ssh
FOREIGN_IP=${FOREIGN_IP}
SSH_PORT=${SSH_PORT}
FWD_PORT=${FWD_PORT}
PROFILE=${PROFILE}
LOCAL_IP=${LOCAL_IP}
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
IEOF
    chmod 600 "${CFG_DIR}/tunnel-info.txt"

    # Register in central registry
    register_tunnel "$TNAME" "ssh" "$FWD_PORT" "$PROFILE"

    # Display success
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  SSH Tunnel Connected!                               ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Foreign IP:   ${YELLOW}${FOREIGN_IP}${NC}"
    echo -e "${CYAN}║  SSH Port:     ${YELLOW}${SSH_PORT}${NC}"
    echo -e "${CYAN}║  Forward Port: ${YELLOW}${FWD_PORT}${NC}"
    echo -e "${CYAN}║  Local IP:     ${YELLOW}${LOCAL_IP}${NC}"
    echo -e "${CYAN}║  Profile:      ${YELLOW}${PROFILE}${NC}"
    echo -e "${CYAN}║  Service:      ${YELLOW}${SVC_NAME}${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  In 3x-ui External Proxy:                           ║${NC}"
    echo -e "${CYAN}║  Set: ${LOCAL_IP}:${FWD_PORT}${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  WIREGUARD CLIENT
# ══════════════════════════════════════════════════════════════════════════════
connect_wireguard_tunnel() {
    local TNAME="$1"
    local FOREIGN_IP="$2"
    local WG_PORT="$3"
    local FWD_PORT="$4"
    local PROFILE="$5"
    local MTU="$6"
    local KEEPALIVE="$7"
    local SRV_WG_IP="$8"
    local CLI_WG_IP="$9"
    local CLI_PRIV="${10}"
    local SRV_PUB="${11}"
    local SVC_NAME="tommy-${TNAME}"
    local CFG_DIR="${TOMMY_DIR}/${TNAME}"

    info "Setting up WireGuard client..."

    # Install WireGuard
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        apt-get update -y 2>/dev/null || true
        apt-get install -y wireguard wireguard-tools 2>/dev/null || true
    elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y wireguard-tools 2>/dev/null || true
    elif [[ "$OS_ID" == "arch" ]]; then
        pacman -Sy --noconfirm wireguard-tools 2>/dev/null || true
    fi

    if ! command -v wg >/dev/null 2>&1; then
        err "WireGuard installation failed."
        return 1
    fi

    mkdir -p "${CFG_DIR}"

    # Build client config from parsed connection code data
    cat > "${CFG_DIR}/wg0.conf" <<WGEOF
[Interface]
PrivateKey = ${CLI_PRIV}
Address = ${CLI_WG_IP}/24
MTU = ${MTU}
DNS = 1.1.1.1

[Peer]
PublicKey = ${SRV_PUB}
Endpoint = ${FOREIGN_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = ${KEEPALIVE}
WGEOF
    chmod 600 "${CFG_DIR}/wg0.conf"

    # Copy to WireGuard directory
    cp "${CFG_DIR}/wg0.conf" "/etc/wireguard/wg0-${TNAME}.conf" 2>/dev/null || true

    # Create systemd service for WireGuard
    cat > "/etc/systemd/system/${SVC_NAME}.service" <<SVCEOF
[Unit]
Description=Tommy WireGuard Tunnel - ${TNAME}
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/wg-quick up ${CFG_DIR}/wg0.conf
ExecStop=/usr/bin/wg-quick down ${CFG_DIR}/wg0.conf

[Install]
WantedBy=multi-user.target
SVCEOF

    # Create port forwarding helper service using socat
    install_pkg socat
    info "Setting up port forwarding through WireGuard..."
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
    sysctl -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true

    cat > "/etc/systemd/system/${SVC_NAME}-fwd.service" <<FWDEOF
[Unit]
Description=Tommy Port Forward - ${TNAME}
After=${SVC_NAME}.service
Wants=${SVC_NAME}.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${FWD_PORT},fork,reuseaddr TCP:${SRV_WG_IP}:${FWD_PORT}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
FWDEOF

    systemctl daemon-reload
    open_firewall "$FWD_PORT" tcp
    systemctl enable "$SVC_NAME" >/dev/null 2>&1
    systemctl enable "${SVC_NAME}-fwd" >/dev/null 2>&1
    systemctl start "$SVC_NAME" 2>/dev/null || true
    sleep 2
    systemctl start "${SVC_NAME}-fwd" 2>/dev/null || true

    sleep 2
    if systemctl is-active --quiet "$SVC_NAME" && systemctl is-active --quiet "${SVC_NAME}-fwd"; then
        info "WireGuard Tunnel is RUNNING! Port ${FWD_PORT} forwarded to ${FOREIGN_IP}"
    else
        warn "WireGuard Tunnel may have failed. Check: journalctl -u ${SVC_NAME} -n 20"
    fi

    # Save tunnel info
    cat > "${CFG_DIR}/tunnel-info.txt" <<IEOF
TUNNEL_NAME=${TNAME}
METHOD=wireguard
FOREIGN_IP=${FOREIGN_IP}
WG_PORT=${WG_PORT}
FWD_PORT=${FWD_PORT}
SRV_WG_IP=${SRV_WG_IP}
PROFILE=${PROFILE}
LOCAL_IP=${LOCAL_IP}
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
IEOF
    chmod 600 "${CFG_DIR}/tunnel-info.txt"

    # Register in central registry
    register_tunnel "$TNAME" "wireguard" "$FWD_PORT" "$PROFILE"

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  WireGuard Tunnel Connected!                         ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Foreign IP:   ${YELLOW}${FOREIGN_IP}${NC}"
    echo -e "${CYAN}║  WG Port:      ${YELLOW}${WG_PORT} (UDP)${NC}"
    echo -e "${CYAN}║  Forward Port: ${YELLOW}${FWD_PORT}${NC}"
    echo -e "${CYAN}║  Local IP:     ${YELLOW}${LOCAL_IP}${NC}"
    echo -e "${CYAN}║  Profile:      ${YELLOW}${PROFILE}${NC}"
    echo -e "${CYAN}║  Service:      ${YELLOW}${SVC_NAME}${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  In 3x-ui External Proxy:                           ║${NC}"
    echo -e "${CYAN}║  Set: ${LOCAL_IP}:${FWD_PORT}${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  GOST CLIENT (TLS Relay)
# ══════════════════════════════════════════════════════════════════════════════
connect_gost_tunnel() {
    local TNAME="$1"
    local FOREIGN_IP="$2"
    local TUNNEL_PORT="$3"
    local FWD_PORT="$4"
    local GOST_PASS="$5"
    local PROFILE="$6"
    local SVC_NAME="tommy-${TNAME}"
    local CFG_DIR="${TOMMY_DIR}/${TNAME}"

    info "Setting up Gost TLS Relay client..."

    mkdir -p "${CFG_DIR}"

    # Install Gost v3
    local GOST_BIN="/usr/local/bin/gost"
    if [[ ! -x "$GOST_BIN" ]]; then
        info "Downloading Gost v3..."
        local ARCH=""
        case "$(uname -m)" in
            x86_64)  ARCH="amd64" ;;
            aarch64) ARCH="arm64" ;;
            armv7l)  ARCH="armv7" ;;
            *)       ARCH="amd64" ;;
        esac
        local GOST_URL="https://github.com/go-gost/gost/releases/download/v3.0.0-rc10/gost_3.0.0-rc10_linux_${ARCH}.tar.gz"
        wget -qO /tmp/gost.tar.gz "$GOST_URL" 2>/dev/null || true
        if [[ -f /tmp/gost.tar.gz ]]; then
            tar -xzf /tmp/gost.tar.gz -C /tmp/ 2>/dev/null || true
            cp /tmp/gost "$GOST_BIN" 2>/dev/null || true
            chmod +x "$GOST_BIN"
            rm -f /tmp/gost.tar.gz /tmp/gost
        fi
        if [[ ! -x "$GOST_BIN" ]]; then
            if command -v go >/dev/null 2>&1; then
                go install github.com/go-gost/gost/cmd/gost@latest 2>/dev/null || true
                cp ~/go/bin/gost "$GOST_BIN" 2>/dev/null || true
            fi
        fi
    fi

    if [[ ! -x "$GOST_BIN" ]]; then
        err "Gost installation failed."
        return 1
    fi

    # Create Gost client config
    cat > "${CFG_DIR}/gost.yaml" <<GOSTEOF
services:
  - name: tommy-client-${TNAME}
    addr: "0.0.0.0:${FWD_PORT}"
    handler:
      type: tcp
      chain: chain-${TNAME}
    listener:
      type: tcp
chains:
  - name: chain-${TNAME}
    hops:
      - name: hop-${TNAME}
        nodes:
          - name: relay-${TNAME}
            addr: "${FOREIGN_IP}:${TUNNEL_PORT}"
            connector:
              type: relay
              auth:
                username: tommy
                password: ${GOST_PASS}
            dialer:
              type: tls
              tls:
                insecure: true
GOSTEOF
    chmod 600 "${CFG_DIR}/gost.yaml"

    # Create systemd service
    cat > "/etc/systemd/system/${SVC_NAME}.service" <<SVCEOF
[Unit]
Description=Tommy Gost Tunnel - ${TNAME}
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${GOST_BIN} -C ${CFG_DIR}/gost.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    open_firewall "$FWD_PORT" tcp
    systemctl enable "$SVC_NAME" >/dev/null 2>&1
    systemctl start "$SVC_NAME"

    sleep 2
    if systemctl is-active --quiet "$SVC_NAME"; then
        info "Gost TLS Relay is RUNNING! Port ${FWD_PORT} forwarded to ${FOREIGN_IP}"
    else
        warn "Gost tunnel may have failed. Check: journalctl -u ${SVC_NAME} -n 30"
    fi

    # Save tunnel info
    cat > "${CFG_DIR}/tunnel-info.txt" <<IEOF
TUNNEL_NAME=${TNAME}
METHOD=gost
FOREIGN_IP=${FOREIGN_IP}
TUNNEL_PORT=${TUNNEL_PORT}
FWD_PORT=${FWD_PORT}
PROFILE=${PROFILE}
LOCAL_IP=${LOCAL_IP}
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
IEOF
    chmod 600 "${CFG_DIR}/tunnel-info.txt"

    # Register in central registry
    register_tunnel "$TNAME" "gost" "$FWD_PORT" "$PROFILE"

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Gost TLS Relay Connected!                           ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Foreign IP:   ${YELLOW}${FOREIGN_IP}${NC}"
    echo -e "${CYAN}║  Tunnel Port:  ${YELLOW}${TUNNEL_PORT} (TLS)${NC}"
    echo -e "${CYAN}║  Forward Port: ${YELLOW}${FWD_PORT}${NC}"
    echo -e "${CYAN}║  Local IP:     ${YELLOW}${LOCAL_IP}${NC}"
    echo -e "${CYAN}║  Profile:      ${YELLOW}${PROFILE}${NC}"
    echo -e "${CYAN}║  Service:      ${YELLOW}${SVC_NAME}${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  In 3x-ui External Proxy:                           ║${NC}"
    echo -e "${CYAN}║  Set: ${LOCAL_IP}:${FWD_PORT}${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  HYSTERIA2 CLIENT
# ══════════════════════════════════════════════════════════════════════════════
connect_hysteria2_tunnel() {
    local TNAME="$1"
    local FOREIGN_IP="$2"
    local TUNNEL_PORT="$3"
    local FWD_PORT="$4"
    local HY2_PASS="$5"
    local PROFILE="$6"
    local SVC_NAME="tommy-${TNAME}"
    local CFG_DIR="${TOMMY_DIR}/${TNAME}"

    info "Setting up Hysteria2 client..."

    mkdir -p "${CFG_DIR}"

    # Install Hysteria2
    local HY2_BIN="/usr/local/bin/hysteria"
    if [[ ! -x "$HY2_BIN" ]]; then
        info "Downloading Hysteria2..."
        bash <(curl -fsSL https://get.hy2.sh/) 2>/dev/null || true
    fi

    if [[ ! -x "$HY2_BIN" ]]; then
        err "Hysteria2 installation failed."
        return 1
    fi

    # Profile settings
    local RECV_WINDOW=16777216
    if [[ "$PROFILE" == "speed" ]]; then
        RECV_WINDOW=67108864
    elif [[ "$PROFILE" == "security" ]]; then
        RECV_WINDOW=8388608
    fi

    # Create Hysteria2 client config with TCP port forwarding
    cat > "${CFG_DIR}/config.yaml" <<HYEOF
server: ${FOREIGN_IP}:${TUNNEL_PORT}
auth: ${HY2_PASS}
tls:
  insecure: true
quic:
  initStreamReceiveWindow: ${RECV_WINDOW}
  maxStreamReceiveWindow: ${RECV_WINDOW}
  initConnReceiveWindow: $((RECV_WINDOW * 2))
  maxConnReceiveWindow: $((RECV_WINDOW * 4))
  maxIdleTimeout: 60s
  keepAlivePeriod: 20s

forwards:
  - listen: 0.0.0.0:${FWD_PORT}
    remote: 127.0.0.1:${FWD_PORT}
HYEOF
    chmod 600 "${CFG_DIR}/config.yaml"

    # Create systemd service
    cat > "/etc/systemd/system/${SVC_NAME}.service" <<SVCEOF
[Unit]
Description=Tommy Hysteria2 Tunnel - ${TNAME}
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${HY2_BIN} client -c ${CFG_DIR}/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    open_firewall "$FWD_PORT" tcp
    systemctl enable "$SVC_NAME" >/dev/null 2>&1
    systemctl start "$SVC_NAME"

    sleep 3
    if systemctl is-active --quiet "$SVC_NAME"; then
        info "Hysteria2 Tunnel is RUNNING! Port ${FWD_PORT} forwarded to ${FOREIGN_IP}"
    else
        warn "Hysteria2 tunnel may have failed. Check: journalctl -u ${SVC_NAME} -n 30"
    fi

    # Save tunnel info
    cat > "${CFG_DIR}/tunnel-info.txt" <<IEOF
TUNNEL_NAME=${TNAME}
METHOD=hysteria2
FOREIGN_IP=${FOREIGN_IP}
TUNNEL_PORT=${TUNNEL_PORT}
FWD_PORT=${FWD_PORT}
PROFILE=${PROFILE}
LOCAL_IP=${LOCAL_IP}
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
IEOF
    chmod 600 "${CFG_DIR}/tunnel-info.txt"

    # Register in central registry
    register_tunnel "$TNAME" "hysteria2" "$FWD_PORT" "$PROFILE"

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Hysteria2 Tunnel Connected!                         ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Foreign IP:   ${YELLOW}${FOREIGN_IP}${NC}"
    echo -e "${CYAN}║  Tunnel Port:  ${YELLOW}${TUNNEL_PORT} (UDP)${NC}"
    echo -e "${CYAN}║  Forward Port: ${YELLOW}${FWD_PORT}${NC}"
    echo -e "${CYAN}║  Local IP:     ${YELLOW}${LOCAL_IP}${NC}"
    echo -e "${CYAN}║  Profile:      ${YELLOW}${PROFILE}${NC}"
    echo -e "${CYAN}║  Service:      ${YELLOW}${SVC_NAME}${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  In 3x-ui External Proxy:                           ║${NC}"
    echo -e "${CYAN}║  Set: ${LOCAL_IP}:${FWD_PORT}${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  CONNECT TUNNEL - using Connection Code (Primary Method)
# ══════════════════════════════════════════════════════════════════════════════
connect_with_code() {
    echo ""
    info "=========================================="
    info "  Tommy v${TOMMY_VER} - Connect via Connection Code"
    info "  (Recommended - Auto-configures from foreign server)"
    info "=========================================="
    echo ""
    info "Paste the connection code from the foreign server."
    info "(Found in /root/tommy-<name>-connection-code.txt on the foreign server)"
    echo ""
    read -rp "Connection Code: " CONN_CODE

    if [[ -z "$CONN_CODE" ]]; then
        err "No connection code entered."
        return
    fi

    # Parse the code
    PARSED_METHOD=""
    PARSED_SERVER_IP=""
    PARSED_FWD_PORT=""
    PARSED_PROFILE=""
    PARSED_EXTRA=""

    if ! parse_connection_code "$CONN_CODE"; then
        return
    fi

    # Show parsed info for confirmation
    echo ""
    info "Decoded connection code:"
    info "  Method:     ${PARSED_METHOD}"
    info "  Server IP:  ${PARSED_SERVER_IP}"
    info "  Fwd Port:   ${PARSED_FWD_PORT}"
    info "  Profile:    ${PARSED_PROFILE}"
    echo ""

    # Step: Tunnel name
    read -rp "Enter a name for this tunnel (e.g. tunnel1): " TNAME
    TNAME="${TNAME:-tunnel1}"
    TNAME=$(echo "$TNAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
    if [[ -z "$TNAME" ]]; then
        err "Tunnel name cannot be empty."
        return
    fi

    if tunnel_exists "$TNAME"; then
        err "Tunnel '${TNAME}' already exists. Delete it first or choose another name."
        return
    fi

    # Install common deps
    info "Installing dependencies..."
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        apt-get update -y 2>/dev/null || true
        apt-get install -y curl wget openssl 2>/dev/null || true
    elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
        yum install -y curl wget openssl 2>/dev/null || true
    fi

    optimize_system

    # Get local IP
    LOCAL_IP=$(get_local_ip)

    # Set up based on method
    case "$PARSED_METHOD" in
        ssh)
            # Extra: ssh_port:keepalive:private_key_base64
            local SSH_PORT KEEPALIVE PRIV_KEY_B64
            SSH_PORT=$(echo "$PARSED_EXTRA" | cut -d':' -f1)
            KEEPALIVE=$(echo "$PARSED_EXTRA" | cut -d':' -f2)
            PRIV_KEY_B64=$(echo "$PARSED_EXTRA" | cut -d':' -f3-)
            connect_ssh_tunnel "$TNAME" "$PARSED_SERVER_IP" "$SSH_PORT" "$PARSED_FWD_PORT" "$PARSED_PROFILE" "$PRIV_KEY_B64"
            ;;
        wireguard)
            # Extra: wg_port:mtu:keepalive:srv_wg_ip:cli_wg_ip:cli_priv:srv_pub
            local WG_PORT MTU KEEPALIVE SRV_WG_IP CLI_WG_IP CLI_PRIV SRV_PUB
            WG_PORT=$(echo "$PARSED_EXTRA" | cut -d':' -f1)
            MTU=$(echo "$PARSED_EXTRA" | cut -d':' -f2)
            KEEPALIVE=$(echo "$PARSED_EXTRA" | cut -d':' -f3)
            SRV_WG_IP=$(echo "$PARSED_EXTRA" | cut -d':' -f4)
            CLI_WG_IP=$(echo "$PARSED_EXTRA" | cut -d':' -f5)
            CLI_PRIV=$(echo "$PARSED_EXTRA" | cut -d':' -f6)
            SRV_PUB=$(echo "$PARSED_EXTRA" | cut -d':' -f7)
            connect_wireguard_tunnel "$TNAME" "$PARSED_SERVER_IP" "$WG_PORT" "$PARSED_FWD_PORT" "$PARSED_PROFILE" "$MTU" "$KEEPALIVE" "$SRV_WG_IP" "$CLI_WG_IP" "$CLI_PRIV" "$SRV_PUB"
            ;;
        gost)
            # Extra: tunnel_port:password
            local TUNNEL_PORT GOST_PASS
            TUNNEL_PORT=$(echo "$PARSED_EXTRA" | cut -d':' -f1)
            GOST_PASS=$(echo "$PARSED_EXTRA" | cut -d':' -f2)
            connect_gost_tunnel "$TNAME" "$PARSED_SERVER_IP" "$TUNNEL_PORT" "$PARSED_FWD_PORT" "$GOST_PASS" "$PARSED_PROFILE"
            ;;
        hysteria2)
            # Extra: tunnel_port:password
            local TUNNEL_PORT HY2_PASS
            TUNNEL_PORT=$(echo "$PARSED_EXTRA" | cut -d':' -f1)
            HY2_PASS=$(echo "$PARSED_EXTRA" | cut -d':' -f2)
            connect_hysteria2_tunnel "$TNAME" "$PARSED_SERVER_IP" "$TUNNEL_PORT" "$PARSED_FWD_PORT" "$HY2_PASS" "$PARSED_PROFILE"
            ;;
        *)
            err "Unknown method '${PARSED_METHOD}' in connection code."
            return
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
#  CONNECT TUNNEL - Manual Entry (Fallback)
# ══════════════════════════════════════════════════════════════════════════════
connect_manual() {
    echo ""
    info "=========================================="
    info "  Tommy v${TOMMY_VER} - Manual Setup"
    info "  (Enter all settings manually)"
    info "=========================================="
    echo ""
    info "Enter the credentials from the foreign server."
    echo ""

    # Step 1: Tunnel name
    read -rp "Enter a name for this tunnel (e.g. tunnel1): " TNAME
    TNAME="${TNAME:-tunnel1}"
    TNAME=$(echo "$TNAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
    if [[ -z "$TNAME" ]]; then
        err "Tunnel name cannot be empty."
        return
    fi

    if tunnel_exists "$TNAME"; then
        err "Tunnel '${TNAME}' already exists. Delete it first or choose another name."
        return
    fi

    # Step 2: Tunnel method
    echo ""
    echo -e "${BOLD}Select Tunnel Method (must match foreign server):${NC}"
    echo "  1) SSH Tunnel"
    echo "  2) WireGuard"
    echo "  3) Gost TLS Relay"
    echo "  4) Hysteria2"
    echo ""
    read -rp "Select method [1-4, default=3]: " METHOD_CHOICE
    METHOD_CHOICE="${METHOD_CHOICE:-3}"

    # Step 3: Foreign server IP
    read -rp "Enter FOREIGN server IP: " FOREIGN_IP
    if [[ -z "$FOREIGN_IP" ]]; then
        err "Foreign server IP is required."
        return
    fi

    # Step 4: Forward port
    local FWD_PORT=443
    read_port "Enter forward port (same as foreign server)" "443" FWD_PORT

    # Step 5: Profile
    echo ""
    echo -e "${BOLD}Select Profile (must match foreign server):${NC}"
    echo "  1) Balanced"
    echo "  2) Speed Priority"
    echo "  3) Security Priority"
    echo ""
    read -rp "Select profile [1-3, default=1]: " PROFILE_CHOICE
    PROFILE_CHOICE="${PROFILE_CHOICE:-1}"

    local PROFILE="balanced"
    case "$PROFILE_CHOICE" in
        1) PROFILE="balanced" ;;
        2) PROFILE="speed" ;;
        3) PROFILE="security" ;;
        *) PROFILE="balanced" ;;
    esac

    # Step 6: Install common deps
    info "Installing dependencies..."
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        apt-get update -y 2>/dev/null || true
        apt-get install -y curl wget openssl 2>/dev/null || true
    elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
        yum install -y curl wget openssl 2>/dev/null || true
    fi

    optimize_system

    # Get local IP
    LOCAL_IP=$(get_local_ip)

    # Step 7: Method-specific setup
    case "$METHOD_CHOICE" in
        1)
            local SSH_PORT=22
            read_port "Enter SSH port on foreign server" "22" SSH_PORT
            connect_ssh_tunnel "$TNAME" "$FOREIGN_IP" "$SSH_PORT" "$FWD_PORT" "$PROFILE" ""
            ;;
        2)
            local WG_PORT=51820
            read_port "Enter WireGuard UDP port on foreign server" "51820" WG_PORT
            echo ""
            info "Paste the WireGuard client config from the foreign server."
            info "(The [Interface] and [Peer] sections)"
            info "Press Enter on an empty line when done."
            echo ""
            local WG_CONFIG=""
            while IFS= read -r line; do
                if [[ -z "$line" ]]; then
                    break
                fi
                WG_CONFIG="${WG_CONFIG}${line}"$'\n'
            done
            if [[ -z "$WG_CONFIG" ]]; then
                err "No WireGuard config provided."
                return
            fi
            # Parse WG config manually
            local CLI_PRIV="" CLI_WG_IP="" MTU="1280" SRV_PUB="" KEEPALIVE="25" SRV_WG_IP="10.10.0.1"
            CLI_PRIV=$(echo "$WG_CONFIG" | grep "PrivateKey" | head -1 | awk '{print $3}')
            CLI_WG_IP=$(echo "$WG_CONFIG" | grep "Address" | head -1 | awk '{print $3}' | cut -d'/' -f1)
            MTU=$(echo "$WG_CONFIG" | grep "MTU" | head -1 | awk '{print $3}')
            MTU="${MTU:-1280}"
            SRV_PUB=$(echo "$WG_CONFIG" | grep "PublicKey" | head -1 | awk '{print $3}')
            KEEPALIVE=$(echo "$WG_CONFIG" | grep "PersistentKeepalive" | head -1 | awk '{print $3}')
            KEEPALIVE="${KEEPALIVE:-25}"
            SRV_WG_IP="10.10.0.1"
            connect_wireguard_tunnel "$TNAME" "$FOREIGN_IP" "$WG_PORT" "$FWD_PORT" "$PROFILE" "$MTU" "$KEEPALIVE" "$SRV_WG_IP" "$CLI_WG_IP" "$CLI_PRIV" "$SRV_PUB"
            ;;
        3)
            local TUNNEL_PORT=8443
            read_port "Enter Gost tunnel port on foreign server" "8443" TUNNEL_PORT
            read -rp "Enter Gost password from foreign server: " GOST_PASS
            if [[ -z "$GOST_PASS" ]]; then
                err "Gost password is required."
                return
            fi
            connect_gost_tunnel "$TNAME" "$FOREIGN_IP" "$TUNNEL_PORT" "$FWD_PORT" "$GOST_PASS" "$PROFILE"
            ;;
        4)
            local TUNNEL_PORT=8443
            read_port "Enter Hysteria2 tunnel port on foreign server" "8443" TUNNEL_PORT
            read -rp "Enter Hysteria2 password from foreign server: " HY2_PASS
            if [[ -z "$HY2_PASS" ]]; then
                err "Hysteria2 password is required."
                return
            fi
            connect_hysteria2_tunnel "$TNAME" "$FOREIGN_IP" "$TUNNEL_PORT" "$FWD_PORT" "$HY2_PASS" "$PROFILE"
            ;;
        *)
            err "Invalid method."
            return
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
#  LIST TUNNELS
# ══════════════════════════════════════════════════════════════════════════════
list_tunnels() {
    echo ""
    info "=========================================="
    info "  Tommy v${TOMMY_VER} - Active Tunnels"
    info "=========================================="

    local FOUND=0
    if [[ -f "$TOMMY_REGISTRY" ]]; then
        while IFS='|' read -r tname method fwd_port profile created; do
            FOUND=1
            local SVC_NAME="tommy-${tname}"
            local STATUS="STOPPED"
            if systemctl is-active --quiet "$SVC_NAME" 2>/dev/null; then
                STATUS="RUNNING"
            fi
            echo ""
            echo -e "  ${GREEN}Name:${NC}      ${tname}"
            echo -e "  ${GREEN}Method:${NC}    ${method}"
            echo -e "  ${GREEN}Fwd Port:${NC}  ${fwd_port}"
            echo -e "  ${GREEN}Profile:${NC}   ${profile}"
            echo -e "  ${GREEN}Service:${NC}   ${SVC_NAME}"
            echo -e "  ${GREEN}Status:${NC}    ${STATUS}"
            echo -e "  ${GREEN}Created:${NC}   ${created}"
            echo -e "  ${CYAN}──────────────────────────────────${NC}"
        done < "$TOMMY_REGISTRY"
    fi

    if [[ "$FOUND" -eq 0 ]]; then
        warn "No tunnels found. Create one with option 1."
    fi
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  DELETE TUNNEL
# ══════════════════════════════════════════════════════════════════════════════
delete_tunnel() {
    echo ""
    list_tunnels

    read -rp "Enter the name of the tunnel to DELETE: " DEL_NAME
    DEL_NAME="${DEL_NAME:-none}"
    DEL_NAME=$(echo "$DEL_NAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')

    local SVC_NAME="tommy-${DEL_NAME}"
    local TUNNEL_DIR="${TOMMY_DIR}/${DEL_NAME}"

    if [[ ! -d "$TUNNEL_DIR" ]]; then
        err "Tunnel '${DEL_NAME}' not found."
        return
    fi

    # Read info before deletion
    local METHOD="" FWD_PORT=""
    if [[ -f "${TUNNEL_DIR}/tunnel-info.txt" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                METHOD) METHOD="$value" ;;
                FWD_PORT) FWD_PORT="$value" ;;
            esac
        done < "${TUNNEL_DIR}/tunnel-info.txt"
    fi

    # Confirm
    echo ""
    warn "You are about to DELETE tunnel: ${DEL_NAME}"
    warn "This will stop the service, remove configs, and delete all related files."
    read -rp "Are you sure? Type 'yes' to confirm: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        info "Deletion cancelled."
        return
    fi

    # Stop and disable services
    systemctl stop "$SVC_NAME" 2>/dev/null || true
    systemctl disable "$SVC_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SVC_NAME}.service"

    # For WireGuard, also stop the forwarding service
    if [[ "$METHOD" == "wireguard" ]]; then
        systemctl stop "${SVC_NAME}-fwd" 2>/dev/null || true
        systemctl disable "${SVC_NAME}-fwd" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SVC_NAME}-fwd.service"
        wg-quick down "${TUNNEL_DIR}/wg0.conf" 2>/dev/null || true
        rm -f "/etc/wireguard/wg0-${DEL_NAME}.conf" 2>/dev/null || true
    fi

    systemctl daemon-reload

    # Remove tunnel config directory
    rm -rf "$TUNNEL_DIR"

    # Close firewall port
    if [[ -n "$FWD_PORT" ]]; then
        close_firewall "$FWD_PORT" tcp
    fi

    # Unregister from central registry
    unregister_tunnel "$DEL_NAME"

    info "Tunnel '${DEL_NAME}' has been DELETED."
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  SERVICE MANAGER
# ══════════════════════════════════════════════════════════════════════════════
service_manager() {
    while true; do
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║  Tommy Service Manager               ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║  1) List all tunnels                 ║${NC}"
        echo -e "${CYAN}║  2) Start a tunnel                   ║${NC}"
        echo -e "${CYAN}║  3) Stop a tunnel                    ║${NC}"
        echo -e "${CYAN}║  4) Restart a tunnel                 ║${NC}"
        echo -e "${CYAN}║  5) View tunnel status               ║${NC}"
        echo -e "${CYAN}║  6) View tunnel logs                 ║${NC}"
        echo -e "${CYAN}║  7) Delete a tunnel                  ║${NC}"
        echo -e "${CYAN}║  8) Test tunnel connection           ║${NC}"
        echo -e "${CYAN}║  9) Back to main menu                ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
        echo ""
        read -rp "Select [1-9]: " SM_CHOICE

        case "$SM_CHOICE" in
            1)
                list_tunnels
                ;;
            2)
                list_tunnels
                read -rp "Enter tunnel name to START: " SM_NAME
                SM_NAME=$(echo "$SM_NAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
                if [[ -z "$SM_NAME" ]]; then
                    err "No tunnel name entered."
                    continue
                fi
                if ! tunnel_exists "$SM_NAME"; then
                    err "Tunnel '${SM_NAME}' does not exist."
                    continue
                fi
                if systemctl start "tommy-${SM_NAME}" 2>/dev/null; then
                    # Also start WireGuard forwarding if applicable
                    if [[ -f "/etc/systemd/system/tommy-${SM_NAME}-fwd.service" ]]; then
                        systemctl start "tommy-${SM_NAME}-fwd" 2>/dev/null || true
                    fi
                    sleep 1
                    if systemctl is-active --quiet "tommy-${SM_NAME}"; then
                        info "Tunnel '${SM_NAME}' started and is RUNNING."
                    else
                        warn "Tunnel '${SM_NAME}' started but is not running. Check logs."
                    fi
                else
                    err "Failed to start tunnel '${SM_NAME}'."
                fi
                ;;
            3)
                list_tunnels
                read -rp "Enter tunnel name to STOP: " SM_NAME
                SM_NAME=$(echo "$SM_NAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
                if [[ -z "$SM_NAME" ]]; then
                    err "No tunnel name entered."
                    continue
                fi
                if ! tunnel_exists "$SM_NAME"; then
                    err "Tunnel '${SM_NAME}' does not exist."
                    continue
                fi
                # Stop forwarding service first if applicable
                if [[ -f "/etc/systemd/system/tommy-${SM_NAME}-fwd.service" ]]; then
                    systemctl stop "tommy-${SM_NAME}-fwd" 2>/dev/null || true
                fi
                if systemctl stop "tommy-${SM_NAME}" 2>/dev/null; then
                    info "Tunnel '${SM_NAME}' stopped."
                else
                    warn "Failed to stop tunnel '${SM_NAME}'."
                fi
                ;;
            4)
                list_tunnels
                read -rp "Enter tunnel name to RESTART: " SM_NAME
                SM_NAME=$(echo "$SM_NAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
                if [[ -z "$SM_NAME" ]]; then
                    err "No tunnel name entered."
                    continue
                fi
                if ! tunnel_exists "$SM_NAME"; then
                    err "Tunnel '${SM_NAME}' does not exist."
                    continue
                fi
                if systemctl restart "tommy-${SM_NAME}" 2>/dev/null; then
                    if [[ -f "/etc/systemd/system/tommy-${SM_NAME}-fwd.service" ]]; then
                        systemctl restart "tommy-${SM_NAME}-fwd" 2>/dev/null || true
                    fi
                    sleep 1
                    if systemctl is-active --quiet "tommy-${SM_NAME}"; then
                        info "Tunnel '${SM_NAME}' restarted and is RUNNING."
                    else
                        warn "Tunnel '${SM_NAME}' restarted but is not running. Check logs."
                    fi
                else
                    err "Failed to restart tunnel '${SM_NAME}'."
                fi
                ;;
            5)
                list_tunnels
                read -rp "Enter tunnel name for STATUS: " SM_NAME
                SM_NAME=$(echo "$SM_NAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
                systemctl status "tommy-${SM_NAME}" 2>/dev/null || warn "Service not found."
                ;;
            6)
                list_tunnels
                read -rp "Enter tunnel name for LOGS: " SM_NAME
                SM_NAME=$(echo "$SM_NAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
                journalctl -u "tommy-${SM_NAME}" -n 50 --no-pager 2>/dev/null || warn "Service not found."
                ;;
            7)
                delete_tunnel
                ;;
            8)
                test_connection
                ;;
            9)
                return
                ;;
            *)
                warn "Invalid choice."
                ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════════════════════
#  TEST CONNECTION
# ══════════════════════════════════════════════════════════════════════════════
test_connection() {
    echo ""
    info "=========================================="
    info "  Tommy v${TOMMY_VER} - Tunnel Connection Test"
    info "=========================================="
    echo ""
    list_tunnels

    read -rp "Enter tunnel name to test: " TEST_NAME
    TEST_NAME=$(echo "$TEST_NAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')

    if ! tunnel_exists "$TEST_NAME"; then
        err "Tunnel '${TEST_NAME}' does not exist."
        return
    fi

    local SVC_NAME="tommy-${TEST_NAME}"
    local CFG_DIR="${TOMMY_DIR}/${TEST_NAME}"

    # Check service status
    if systemctl is-active --quiet "$SVC_NAME" 2>/dev/null; then
        info "Service '${SVC_NAME}' is RUNNING."
    else
        warn "Service '${SVC_NAME}' is STOPPED."
    fi

    # Read tunnel info
    local METHOD="" FWD_PORT="" FOREIGN_IP=""
    if [[ -f "${CFG_DIR}/tunnel-info.txt" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                METHOD) METHOD="$value" ;;
                FWD_PORT) FWD_PORT="$value" ;;
                FOREIGN_IP) FOREIGN_IP="$value" ;;
            esac
        done < "${CFG_DIR}/tunnel-info.txt"
    fi

    # Test port
    if [[ -n "$FWD_PORT" ]]; then
        info "Testing port ${FWD_PORT}..."
        if command -v nc >/dev/null 2>&1; then
            if nc -z -w 5 localhost "$FWD_PORT" 2>/dev/null; then
                info "Port ${FWD_PORT} is OPEN and listening."
            else
                warn "Port ${FWD_PORT} is NOT listening."
            fi
        elif command -v ss >/dev/null 2>&1; then
            if ss -tlnp | grep -q ":${FWD_PORT} "; then
                info "Port ${FWD_PORT} is OPEN and listening."
            else
                warn "Port ${FWD_PORT} is NOT listening."
            fi
        fi
    fi

    # Test connectivity to foreign server
    if [[ -n "$FOREIGN_IP" ]]; then
        info "Testing connectivity to foreign server ${FOREIGN_IP}..."
        if ping -c 1 -W 3 "$FOREIGN_IP" >/dev/null 2>&1; then
            info "Foreign server ${FOREIGN_IP} is reachable."
        else
            warn "Foreign server ${FOREIGN_IP} is NOT reachable (may be normal if ICMP is blocked)."
        fi
    fi

    echo ""
    info "Test complete."
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN MENU
# ══════════════════════════════════════════════════════════════════════════════
main() {
    check_root
    detect_os

    # Ensure base directory exists
    mkdir -p "${TOMMY_DIR}"

    while true; do
        show_banner
        echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║  Tommy v${TOMMY_VER} - Iranian Server            ║${NC}"
        echo -e "${CYAN}╠════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║  1) Connect via Connection Code (recommended) ║${NC}"
        echo -e "${CYAN}║  2) Manual Setup                           ║${NC}"
        echo -e "${CYAN}║  3) List tunnels                           ║${NC}"
        echo -e "${CYAN}║  4) Delete a tunnel                        ║${NC}"
        echo -e "${CYAN}║  5) Service Manager                        ║${NC}"
        echo -e "${CYAN}║  6) Exit                                   ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
        echo ""
        read -rp "Select [1-6]: " MAIN_CHOICE

        case "$MAIN_CHOICE" in
            1) connect_with_code ;;
            2) connect_manual ;;
            3) list_tunnels ;;
            4) delete_tunnel ;;
            5) service_manager ;;
            6) info "Goodbye!"; exit 0 ;;
            *) warn "Invalid choice." ;;
        esac

        echo ""
        read -rp "Press Enter to continue..."
    done
}

main
