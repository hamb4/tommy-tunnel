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
#  Foreign Server Setup Script
#  Port Forwarding Tunnel - No xray required
#
#  How it works:
#    1. This script sets up a tunnel SERVER on the foreign server
#    2. Iranian server connects and forwards a port (e.g. 443)
#    3. In 3x-ui, set External Proxy = Iranian server IP + forwarded port
#    4. Users in Iran connect to Iranian server -> tunnel -> foreign 3x-ui -> internet
#
#  Usage:
#    bash <(curl -Ls https://raw.githubusercontent.com/hamb4/tommy-tunnel/main/tommy-server-setup.sh)
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

get_server_ip() {
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

gen_password() {
    openssl rand -base64 24 | tr -d '/+= ' | head -c 32
}

# Read port with validation - if empty or non-numeric, use default
read_port() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local input=""
    read -rp "$prompt [$default]: " input
    # Remove whitespace
    input=$(echo "$input" | tr -d '[:space:]')
    # If empty or not a number, use default
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
    # Remove old entry for same name
    if [[ -f "$TOMMY_REGISTRY" ]]; then
        sed -i "/^${tname}|/d" "$TOMMY_REGISTRY" 2>/dev/null || true
    fi
    echo "${tname}|${method}|${fwd_port}|${profile}|$(date '+%Y-%m-%d %H:%M:%S')" >> "$TOMMY_REGISTRY"
    chmod 600 "$TOMMY_REGISTRY"
}

# Unregister tunnel from central registry
unregister_tunnel() {
    local tname="$1"
    if [[ -f "$TOMMY_REGISTRY" ]]; then
        sed -i "/^${tname}|/d" "$TOMMY_REGISTRY" 2>/dev/null || true
    fi
}

# Check if a tunnel name exists
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
    echo -e "  ${BLUE}Foreign Server - Port Forwarding Tunnel${NC}"
    echo ""
}

# ── Generate Connection Code ─────────────────────────────────────────────────
generate_connection_code() {
    local method="$1"
    local server_ip="$2"
    local fwd_port="$3"
    local profile="$4"
    local extra="$5"  # method-specific data (port, password, key, etc.)

    # Build a structured string and base64 encode it
    # Format: TOMMY105|method|server_ip|fwd_port|profile|extra_data
    local raw="TOMMY105|${method}|${server_ip}|${fwd_port}|${profile}|${extra}"
    echo "$raw" | base64 -w 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  SSH TUNNEL METHOD
# ══════════════════════════════════════════════════════════════════════════════
setup_ssh_tunnel() {
    local TNAME="$1"
    local FWD_PORT="$2"
    local PROFILE="$3"
    local SVC_NAME="tommy-${TNAME}"
    local CFG_DIR="${TOMMY_DIR}/${TNAME}"

    info "Setting up SSH Tunnel..."
    install_pkg openssh-server
    install_pkg autossh

    # Ensure SSH is running
    systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null || true
    systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null || true

    # Create dedicated tunnel user (no shell for security)
    if id "tommy-tunnel" >/dev/null 2>&1; then
        info "User tommy-tunnel already exists."
    else
        useradd -r -s /usr/sbin/nologin tommy-tunnel 2>/dev/null || true
        info "Created restricted user: tommy-tunnel"
    fi

    # Generate ED25519 key pair
    mkdir -p "${CFG_DIR}"
    ssh-keygen -t ed25519 -f "${CFG_DIR}/id_tommy" -N "" -C "tommy-tunnel@${TNAME}" -q 2>/dev/null || true

    # Set up authorized_keys for the tunnel user
    local TUNNEL_HOME
    TUNNEL_HOME=$(eval echo "~tommy-tunnel" 2>/dev/null || echo "/home/tommy-tunnel")
    mkdir -p "${TUNNEL_HOME}/.ssh"
    cat "${CFG_DIR}/id_tommy.pub" > "${TUNNEL_HOME}/.ssh/authorized_keys"
    chmod 700 "${TUNNEL_HOME}/.ssh"
    chmod 600 "${TUNNEL_HOME}/.ssh/authorized_keys"
    chown -R tommy-tunnel:tommy-tunnel "${TUNNEL_HOME}/.ssh" 2>/dev/null || true

    # Restrict SSH for this user to port forwarding only
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    if ! grep -q "Match User tommy-tunnel" "$SSHD_CONFIG" 2>/dev/null; then
        cat >> "$SSHD_CONFIG" <<SSHEOF

# Tommy v${TOMMY_VER} - Restrict tunnel user
Match User tommy-tunnel
    AllowTcpForwarding yes
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
    GatewayPorts yes
    ForceCommand /bin/false
SSHEOF
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    fi

    # Get SSH port
    local SSH_PORT=22
    SSH_PORT=$(grep -E "^Port " "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | head -1)
    SSH_PORT="${SSH_PORT:-22}"

    # Profile settings
    local KEEPALIVE=30
    if [[ "$PROFILE" == "speed" ]]; then
        KEEPALIVE=15
    elif [[ "$PROFILE" == "security" ]]; then
        KEEPALIVE=60
    fi

    # Create systemd service
    cat > "/etc/systemd/system/${SVC_NAME}.service" <<SVCEOF
[Unit]
Description=Tommy SSH Tunnel - ${TNAME}
After=network.target sshd.service
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/bin/true

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable "$SVC_NAME" >/dev/null 2>&1
    systemctl start "$SVC_NAME" >/dev/null 2>&1

    # Read private key
    local PRIVATE_KEY
    PRIVATE_KEY=$(cat "${CFG_DIR}/id_tommy")

    # Save tunnel info
    cat > "${CFG_DIR}/tunnel-info.txt" <<IEOF
TUNNEL_NAME=${TNAME}
METHOD=ssh
FWD_PORT=${FWD_PORT}
PROFILE=${PROFILE}
SSH_PORT=${SSH_PORT}
KEEPALIVE=${KEEPALIVE}
SERVER_IP=${SERVER_IP}
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
IEOF
    chmod 600 "${CFG_DIR}/tunnel-info.txt"

    # Register in central registry
    register_tunnel "$TNAME" "ssh" "$FWD_PORT" "$PROFILE"

    # Generate connection code
    # Extra format for SSH: ssh_port:keepalive:private_key_base64
    local PRIV_KEY_B64
    PRIV_KEY_B64=$(echo "$PRIVATE_KEY" | base64 -w 0)
    local EXTRA="${SSH_PORT}:${KEEPALIVE}:${PRIV_KEY_B64}"
    local CONN_CODE
    CONN_CODE=$(generate_connection_code "ssh" "${SERVER_IP}" "${FWD_PORT}" "${PROFILE}" "${EXTRA}")

    # Display results
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  SSH Tunnel Created!                                        ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Server IP:    ${YELLOW}${SERVER_IP}${NC}"
    echo -e "${CYAN}║  SSH Port:     ${YELLOW}${SSH_PORT}${NC}"
    echo -e "${CYAN}║  Forward Port: ${YELLOW}${FWD_PORT}${NC}"
    echo -e "${CYAN}║  Username:     ${YELLOW}tommy-tunnel${NC}"
    echo -e "${CYAN}║  Profile:      ${YELLOW}${PROFILE}${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  ${BOLD}Connection Code (give to Iranian server):${NC}"
    echo -e "${YELLOW}  ${CONN_CODE}${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  In 3x-ui External Proxy:                                  ║${NC}"
    echo -e "${CYAN}║  Set Iranian server IP + port ${FWD_PORT}${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    info "Connection code has been saved to /root/tommy-${TNAME}-connection-code.txt"
    echo "$CONN_CODE" > "/root/tommy-${TNAME}-connection-code.txt"
    chmod 600 "/root/tommy-${TNAME}-connection-code.txt"
}

# ══════════════════════════════════════════════════════════════════════════════
#  WIREGUARD METHOD
# ══════════════════════════════════════════════════════════════════════════════
setup_wireguard_tunnel() {
    local TNAME="$1"
    local FWD_PORT="$2"
    local PROFILE="$3"
    local SVC_NAME="tommy-${TNAME}"
    local CFG_DIR="${TOMMY_DIR}/${TNAME}"

    info "Setting up WireGuard Tunnel..."

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

    # Generate server keys
    wg genkey | tee "${CFG_DIR}/server_privatekey" | wg pubkey > "${CFG_DIR}/server_publickey"
    local SRV_PRIV SRV_PUB
    SRV_PRIV=$(cat "${CFG_DIR}/server_privatekey")
    SRV_PUB=$(cat "${CFG_DIR}/server_publickey")

    # Generate client (Iranian server) keys
    wg genkey | tee "${CFG_DIR}/client_privatekey" | wg pubkey > "${CFG_DIR}/client_publickey"
    local CLI_PRIV CLI_PUB
    CLI_PRIV=$(cat "${CFG_DIR}/client_privatekey")
    CLI_PUB=$(cat "${CFG_DIR}/client_publickey")

    # WireGuard port
    local WG_PORT=51820
    read_port "Enter WireGuard UDP port" "51820" WG_PORT

    # WireGuard internal IPs
    local SRV_WG_IP="10.10.0.1"
    local CLI_WG_IP="10.10.0.2"

    # Profile settings
    local MTU=1280
    local KEEPALIVE=25
    if [[ "$PROFILE" == "speed" ]]; then
        MTU=1420
        KEEPALIVE=15
    elif [[ "$PROFILE" == "security" ]]; then
        MTU=1280
        KEEPALIVE=60
    fi

    # Create server config
    cat > "${CFG_DIR}/wg0.conf" <<WGEOF
[Interface]
PrivateKey = ${SRV_PRIV}
Address = ${SRV_WG_IP}/24
ListenPort = ${WG_PORT}
MTU = ${MTU}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE; iptables -t nat -A POSTROUTING -o ens+ -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE; iptables -t nat -D POSTROUTING -o ens+ -j MASQUERADE

[Peer]
PublicKey = ${CLI_PUB}
AllowedIPs = ${CLI_WG_IP}/32
WGEOF
    chmod 600 "${CFG_DIR}/wg0.conf"

    # Copy to WireGuard directory
    cp "${CFG_DIR}/wg0.conf" "/etc/wireguard/wg0-${TNAME}.conf" 2>/dev/null || true

    # Create systemd service
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

    systemctl daemon-reload
    open_firewall "$WG_PORT" udp
    open_firewall "$FWD_PORT" tcp
    systemctl enable "$SVC_NAME" >/dev/null 2>&1
    systemctl start "$SVC_NAME" 2>/dev/null || true

    # Save tunnel info
    cat > "${CFG_DIR}/tunnel-info.txt" <<IEOF
TUNNEL_NAME=${TNAME}
METHOD=wireguard
FWD_PORT=${FWD_PORT}
WG_PORT=${WG_PORT}
PROFILE=${PROFILE}
SRV_WG_IP=${SRV_WG_IP}
CLI_WG_IP=${CLI_WG_IP}
MTU=${MTU}
KEEPALIVE=${KEEPALIVE}
SERVER_IP=${SERVER_IP}
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
IEOF
    chmod 600 "${CFG_DIR}/tunnel-info.txt"

    # Register in central registry
    register_tunnel "$TNAME" "wireguard" "$FWD_PORT" "$PROFILE"

    # Generate connection code
    # Extra: wg_port:mtu:keepalive:srv_wg_ip:cli_wg_ip:cli_priv:srv_pub
    local EXTRA="${WG_PORT}:${MTU}:${KEEPALIVE}:${SRV_WG_IP}:${CLI_WG_IP}:${CLI_PRIV}:${SRV_PUB}"
    local CONN_CODE
    CONN_CODE=$(generate_connection_code "wireguard" "${SERVER_IP}" "${FWD_PORT}" "${PROFILE}" "${EXTRA}")

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  WireGuard Tunnel Created!                                  ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Server IP:    ${YELLOW}${SERVER_IP}${NC}"
    echo -e "${CYAN}║  WG Port:      ${YELLOW}${WG_PORT} (UDP)${NC}"
    echo -e "${CYAN}║  Forward Port: ${YELLOW}${FWD_PORT}${NC}"
    echo -e "${CYAN}║  MTU:          ${YELLOW}${MTU}${NC}"
    echo -e "${CYAN}║  Profile:      ${YELLOW}${PROFILE}${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  ${BOLD}Connection Code (give to Iranian server):${NC}"
    echo -e "${YELLOW}  ${CONN_CODE}${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  In 3x-ui External Proxy:                                  ║${NC}"
    echo -e "${CYAN}║  Set Iranian server IP + port ${FWD_PORT}${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    info "Connection code has been saved to /root/tommy-${TNAME}-connection-code.txt"
    echo "$CONN_CODE" > "/root/tommy-${TNAME}-connection-code.txt"
    chmod 600 "/root/tommy-${TNAME}-connection-code.txt"
}

# ══════════════════════════════════════════════════════════════════════════════
#  GOST METHOD (TLS Relay)
# ══════════════════════════════════════════════════════════════════════════════
setup_gost_tunnel() {
    local TNAME="$1"
    local FWD_PORT="$2"
    local PROFILE="$3"
    local SVC_NAME="tommy-${TNAME}"
    local CFG_DIR="${TOMMY_DIR}/${TNAME}"

    info "Setting up Gost TLS Relay Tunnel..."

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
        err "Gost installation failed. Cannot continue."
        return 1
    fi
    info "Gost installed successfully."

    # Generate password
    local GOST_PASS
    GOST_PASS=$(gen_password)

    # Choose tunnel port (different from forward port)
    local TUNNEL_PORT=8443
    read_port "Enter Gost tunnel port (for encrypted relay)" "8443" TUNNEL_PORT

    # Generate self-signed cert for Gost TLS
    openssl req -new -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${CFG_DIR}/server.key" -out "${CFG_DIR}/server.crt" \
        -days 3650 -subj "/CN=www.bing.com" 2>/dev/null

    # Create Gost config
    cat > "${CFG_DIR}/gost.yaml" <<GOSTEOF
services:
  - name: tommy-${TNAME}
    addr: ":${TUNNEL_PORT}"
    handler:
      type: relay
      auth:
        username: tommy
        password: ${GOST_PASS}
    listener:
      type: tls
      tls:
        certFile: ${CFG_DIR}/server.crt
        keyFile: ${CFG_DIR}/server.key
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
    open_firewall "$TUNNEL_PORT" tcp
    open_firewall "$FWD_PORT" tcp
    systemctl enable "$SVC_NAME" >/dev/null 2>&1
    systemctl start "$SVC_NAME"

    sleep 2
    if systemctl is-active --quiet "$SVC_NAME"; then
        info "Gost tunnel is RUNNING on port ${TUNNEL_PORT}"
    else
        warn "Gost tunnel may have failed. Check: journalctl -u ${SVC_NAME} -n 20"
    fi

    # Save tunnel info
    cat > "${CFG_DIR}/tunnel-info.txt" <<IEOF
TUNNEL_NAME=${TNAME}
METHOD=gost
FWD_PORT=${FWD_PORT}
TUNNEL_PORT=${TUNNEL_PORT}
PROFILE=${PROFILE}
GOST_PASS=${GOST_PASS}
SERVER_IP=${SERVER_IP}
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
IEOF
    chmod 600 "${CFG_DIR}/tunnel-info.txt"

    # Register in central registry
    register_tunnel "$TNAME" "gost" "$FWD_PORT" "$PROFILE"

    # Generate connection code
    local EXTRA="${TUNNEL_PORT}:${GOST_PASS}"
    local CONN_CODE
    CONN_CODE=$(generate_connection_code "gost" "${SERVER_IP}" "${FWD_PORT}" "${PROFILE}" "${EXTRA}")

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Gost TLS Relay Tunnel Created!                             ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Server IP:    ${YELLOW}${SERVER_IP}${NC}"
    echo -e "${CYAN}║  Tunnel Port:  ${YELLOW}${TUNNEL_PORT} (TLS)${NC}"
    echo -e "${CYAN}║  Forward Port: ${YELLOW}${FWD_PORT}${NC}"
    echo -e "${CYAN}║  Password:     ${YELLOW}${GOST_PASS}${NC}"
    echo -e "${CYAN}║  Profile:      ${YELLOW}${PROFILE}${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  ${BOLD}Connection Code (give to Iranian server):${NC}"
    echo -e "${YELLOW}  ${CONN_CODE}${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  In 3x-ui External Proxy:                                  ║${NC}"
    echo -e "${CYAN}║  Set Iranian server IP + port ${FWD_PORT}${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    info "Connection code has been saved to /root/tommy-${TNAME}-connection-code.txt"
    echo "$CONN_CODE" > "/root/tommy-${TNAME}-connection-code.txt"
    chmod 600 "/root/tommy-${TNAME}-connection-code.txt"
}

# ══════════════════════════════════════════════════════════════════════════════
#  HYSTERIA2 METHOD
# ══════════════════════════════════════════════════════════════════════════════
setup_hysteria2_tunnel() {
    local TNAME="$1"
    local FWD_PORT="$2"
    local PROFILE="$3"
    local SVC_NAME="tommy-${TNAME}"
    local CFG_DIR="${TOMMY_DIR}/${TNAME}"

    info "Setting up Hysteria2 Tunnel..."

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
    info "Hysteria2 installed successfully."

    # Generate password
    local HY2_PASS
    HY2_PASS=$(gen_password)

    # Choose tunnel port
    local TUNNEL_PORT=8443
    read_port "Enter Hysteria2 tunnel port (UDP)" "8443" TUNNEL_PORT

    # Generate self-signed cert
    openssl req -new -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${CFG_DIR}/server.key" -out "${CFG_DIR}/server.crt" \
        -days 3650 -subj "/CN=bing.com" 2>/dev/null

    # Profile settings
    local RECV_WINDOW=16777216
    local MASQUERADE=""
    if [[ "$PROFILE" == "speed" ]]; then
        RECV_WINDOW=67108864
    elif [[ "$PROFILE" == "security" ]]; then
        RECV_WINDOW=8388608
        MASQUERADE="masquerade:
      type: proxy
      proxy:
        url: https://www.bing.com
        rewriteHost: true"
    fi

    # Create Hysteria2 server config
    cat > "${CFG_DIR}/config.yaml" <<HYEOF
listen: :${TUNNEL_PORT}
tls:
  cert: ${CFG_DIR}/server.crt
  key: ${CFG_DIR}/server.key
auth:
  type: password
  password: ${HY2_PASS}
${MASQUERADE}
quic:
  initStreamReceiveWindow: ${RECV_WINDOW}
  maxStreamReceiveWindow: ${RECV_WINDOW}
  initConnReceiveWindow: $((RECV_WINDOW * 2))
  maxConnReceiveWindow: $((RECV_WINDOW * 4))
  maxIdleTimeout: 60s
  maxIncomingStreams: 1024
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
ExecStart=${HY2_BIN} server -c ${CFG_DIR}/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    open_firewall "$TUNNEL_PORT" udp
    open_firewall "$FWD_PORT" tcp
    systemctl enable "$SVC_NAME" >/dev/null 2>&1
    systemctl start "$SVC_NAME"

    sleep 2
    if systemctl is-active --quiet "$SVC_NAME"; then
        info "Hysteria2 tunnel is RUNNING on port ${TUNNEL_PORT} (UDP)"
    else
        warn "Hysteria2 tunnel may have failed. Check: journalctl -u ${SVC_NAME} -n 20"
    fi

    # Save tunnel info
    cat > "${CFG_DIR}/tunnel-info.txt" <<IEOF
TUNNEL_NAME=${TNAME}
METHOD=hysteria2
FWD_PORT=${FWD_PORT}
TUNNEL_PORT=${TUNNEL_PORT}
PROFILE=${PROFILE}
HY2_PASS=${HY2_PASS}
SERVER_IP=${SERVER_IP}
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
IEOF
    chmod 600 "${CFG_DIR}/tunnel-info.txt"

    # Register in central registry
    register_tunnel "$TNAME" "hysteria2" "$FWD_PORT" "$PROFILE"

    # Generate connection code
    local EXTRA="${TUNNEL_PORT}:${HY2_PASS}"
    local CONN_CODE
    CONN_CODE=$(generate_connection_code "hysteria2" "${SERVER_IP}" "${FWD_PORT}" "${PROFILE}" "${EXTRA}")

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Hysteria2 Tunnel Created!                                  ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Server IP:    ${YELLOW}${SERVER_IP}${NC}"
    echo -e "${CYAN}║  Tunnel Port:  ${YELLOW}${TUNNEL_PORT} (UDP)${NC}"
    echo -e "${CYAN}║  Forward Port: ${YELLOW}${FWD_PORT}${NC}"
    echo -e "${CYAN}║  Password:     ${YELLOW}${HY2_PASS}${NC}"
    echo -e "${CYAN}║  Profile:      ${YELLOW}${PROFILE}${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  ${BOLD}Connection Code (give to Iranian server):${NC}"
    echo -e "${YELLOW}  ${CONN_CODE}${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  In 3x-ui External Proxy:                                  ║${NC}"
    echo -e "${CYAN}║  Set Iranian server IP + port ${FWD_PORT}${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    info "Connection code has been saved to /root/tommy-${TNAME}-connection-code.txt"
    echo "$CONN_CODE" > "/root/tommy-${TNAME}-connection-code.txt"
    chmod 600 "/root/tommy-${TNAME}-connection-code.txt"
}

# ══════════════════════════════════════════════════════════════════════════════
#  CREATE TUNNEL (Main Entry)
# ══════════════════════════════════════════════════════════════════════════════
create_tunnel() {
    echo ""
    info "=========================================="
    info "  Tommy v${TOMMY_VER} - Create Port Forwarding Tunnel"
    info "=========================================="
    echo ""

    # Step 1: Tunnel name
    read -rp "Enter a name for this tunnel (e.g. tunnel1): " TNAME
    TNAME="${TNAME:-tunnel1}"
    TNAME=$(echo "$TNAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
    if [[ -z "$TNAME" ]]; then
        err "Tunnel name cannot be empty."
        return
    fi

    # Check if tunnel already exists
    if tunnel_exists "$TNAME"; then
        err "Tunnel '${TNAME}' already exists. Delete it first or choose another name."
        return
    fi

    # Step 2: Tunnel method
    echo ""
    echo -e "${BOLD}Select Tunnel Method:${NC}"
    echo "  1) SSH Tunnel      (Reliable, built-in, encrypted)"
    echo "  2) WireGuard       (Fast kernel-level VPN, UDP)"
    echo "  3) Gost TLS Relay  (Looks like HTTPS, DPI resistant)"
    echo "  4) Hysteria2       (QUIC/HTTP3, very fast, DPI resistant)"
    echo ""
    read -rp "Select method [1-4, default=3]: " METHOD_CHOICE
    METHOD_CHOICE="${METHOD_CHOICE:-3}"

    # Step 3: Forward port
    echo ""
    info "The Forward Port is the port that 3x-ui listens on."
    info "Users on the Iranian server will connect to this same port."
    local FWD_PORT=443
    read_port "Enter forward port (same as 3x-ui port)" "443" FWD_PORT

    # Step 4: Profile
    echo ""
    echo -e "${BOLD}Select Profile:${NC}"
    echo "  1) Balanced       - Good speed + good security (recommended)"
    echo "  2) Speed Priority - Maximum speed, standard security"
    echo "  3) Security Priority - Maximum security, may reduce speed"
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

    # Step 5: Install common deps
    info "Installing dependencies..."
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        apt-get update -y 2>/dev/null || true
        apt-get install -y curl wget openssl 2>/dev/null || true
    elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
        yum install -y curl wget openssl 2>/dev/null || true
    fi

    optimize_system

    # Step 6: Get server IP
    SERVER_IP=$(get_server_ip)

    # Step 7: Set up based on method
    case "$METHOD_CHOICE" in
        1) setup_ssh_tunnel "$TNAME" "$FWD_PORT" "$PROFILE" ;;
        2) setup_wireguard_tunnel "$TNAME" "$FWD_PORT" "$PROFILE" ;;
        3) setup_gost_tunnel "$TNAME" "$FWD_PORT" "$PROFILE" ;;
        4) setup_hysteria2_tunnel "$TNAME" "$FWD_PORT" "$PROFILE" ;;
        *) err "Invalid method."; return ;;
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
    local METHOD="" FWD_PORT="" WG_PORT="" TUNNEL_PORT=""
    if [[ -f "${TUNNEL_DIR}/tunnel-info.txt" ]]; then
        # Read key-value pairs safely
        while IFS='=' read -r key value; do
            case "$key" in
                METHOD) METHOD="$value" ;;
                FWD_PORT) FWD_PORT="$value" ;;
                WG_PORT) WG_PORT="$value" ;;
                TUNNEL_PORT) TUNNEL_PORT="$value" ;;
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

    # Stop and disable service
    systemctl stop "$SVC_NAME" 2>/dev/null || true
    systemctl disable "$SVC_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SVC_NAME}.service"
    systemctl daemon-reload

    # For WireGuard, also bring down the interface
    if [[ "$METHOD" == "wireguard" ]]; then
        wg-quick down "${TUNNEL_DIR}/wg0.conf" 2>/dev/null || true
        rm -f "/etc/wireguard/wg0-${DEL_NAME}.conf" 2>/dev/null || true
    fi

    # Remove tunnel config directory
    rm -rf "$TUNNEL_DIR"

    # Remove connection code file
    rm -f "/root/tommy-${DEL_NAME}-connection-code.txt"

    # Close firewall ports
    if [[ -n "$FWD_PORT" ]]; then
        close_firewall "$FWD_PORT" tcp
    fi
    if [[ -n "$TUNNEL_PORT" ]]; then
        if [[ "$METHOD" == "wireguard" ]]; then
            close_firewall "${WG_PORT}" udp
        elif [[ "$METHOD" == "hysteria2" ]]; then
            close_firewall "$TUNNEL_PORT" udp
        else
            close_firewall "$TUNNEL_PORT" tcp
        fi
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
        echo -e "${CYAN}║  8) Show connection code             ║${NC}"
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
                list_tunnels
                read -rp "Enter tunnel name to show connection code: " SM_NAME
                SM_NAME=$(echo "$SM_NAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
                local CODE_FILE="/root/tommy-${SM_NAME}-connection-code.txt"
                if [[ -f "$CODE_FILE" ]]; then
                    echo ""
                    echo -e "${YELLOW}Connection Code for '${SM_NAME}':${NC}"
                    cat "$CODE_FILE"
                    echo ""
                else
                    warn "Connection code file not found for '${SM_NAME}'."
                fi
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
#  MAIN MENU
# ══════════════════════════════════════════════════════════════════════════════
main() {
    check_root
    detect_os

    # Ensure base directory exists
    mkdir -p "${TOMMY_DIR}"

    while true; do
        show_banner
        echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║  Tommy v${TOMMY_VER} - Foreign Server       ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║  1) Create a new tunnel              ║${NC}"
        echo -e "${CYAN}║  2) List tunnels                     ║${NC}"
        echo -e "${CYAN}║  3) Delete a tunnel                  ║${NC}"
        echo -e "${CYAN}║  4) Service Manager                  ║${NC}"
        echo -e "${CYAN}║  5) Exit                             ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
        echo ""
        read -rp "Select [1-5]: " MAIN_CHOICE

        case "$MAIN_CHOICE" in
            1) create_tunnel ;;
            2) list_tunnels ;;
            3) delete_tunnel ;;
            4) service_manager ;;
            5) info "Goodbye!"; exit 0 ;;
            *) warn "Invalid choice." ;;
        esac

        echo ""
        read -rp "Press Enter to continue..."
    done
}

main
