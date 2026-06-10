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
#    3. In 3x-ui on foreign server, set External Proxy = this server IP + port
#    4. Users in Iran connect to this server → tunnel → foreign 3x-ui → internet
#
#  Usage:
#    bash <(curl -LSs https://raw.githubusercontent.com/hamb4/tommy-tunnel/main/tommy-client-iran.sh)
#===============================================================================

TOMMY_VER="1.0.5"
TOMMY_AUTHOR="hamb4"
TOMMY_DIR="/etc/tommy"

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
    IP=$(curl -s4 --connect-timeout 5 https://ifconfig.me 2>/dev/null) \
        || IP=$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null) \
        || IP=$(curl -s4 --connect-timeout 5 https://ip.sb 2>/dev/null)
    if [[ -z "$IP" ]]; then
        read -rp "Enter this server's public IP: " IP
    fi
    echo "$IP"
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
            cat >> /etc/sysctl.conf <<EOF
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
EOF
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

# ══════════════════════════════════════════════════════════════════════════════
#  SSH TUNNEL CLIENT
# ══════════════════════════════════════════════════════════════════════════════
connect_ssh_tunnel() {
    local TNAME="$1"
    local FOREIGN_IP="$2"
    local SSH_PORT="$3"
    local FWD_PORT="$4"
    local PROFILE="$5"
    local SVC_NAME="tommy-${TNAME}"
    local CFG_DIR="${TOMMY_DIR}/${TNAME}"

    info "Setting up SSH Tunnel client..."

    install_pkg autossh
    install_pkg openssh-client

    mkdir -p "${CFG_DIR}"

    # Get private key from user
    echo ""
    info "Paste the SSH private key from the foreign server."
    info "(End with a blank line)"
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

    # Save private key
    echo "$KEY_LINES" > "${CFG_DIR}/id_tommy"
    chmod 600 "${CFG_DIR}/id_tommy"

    # Profile settings
    local KEEPALIVE=30
    if [[ "$PROFILE" == "speed" ]]; then
        KEEPALIVE=15
    elif [[ "$PROFILE" == "security" ]]; then
        KEEPALIVE=60
    fi

    # Create systemd service for autossh
    # -L 0.0.0.0:FWD_PORT:localhost:FWD_PORT means:
    #   Listen on 0.0.0.0:FWD_PORT on this server
    #   Forward to localhost:FWD_PORT on the foreign server
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

    # Get client config from user
    echo ""
    info "Paste the WireGuard client config from the foreign server."
    info "(The [Interface] and [Peer] sections)"
    info "(End with a blank line)"
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
        return 1
    fi

    # Save client config
    echo "$WG_CONFIG" > "${CFG_DIR}/wg0.conf"
    chmod 600 "${CFG_DIR}/wg0.conf"

    # Copy to WireGuard directory
    cp "${CFG_DIR}/wg0.conf" /etc/wireguard/wg0.conf 2>/dev/null

    # Create systemd service
    cat > "/etc/systemd/system/${SVC_NAME}.service" <<SVCEOF
[Unit]
Description=Tommy WireGuard Tunnel - ${TNAME}
After=network.target
Wants=network.target

[Service]
Type=notify
ExecStart=/usr/bin/wg-quick up ${CFG_DIR}/wg0.conf
ExecStop=/usr/bin/wg-quick down ${CFG_DIR}/wg0.conf
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

    # Also set up port forwarding through WireGuard
    # After WireGuard is connected, forward FWD_PORT through the tunnel
    local SRV_WG_IP="10.10.0.1"
    info "Setting up port forwarding through WireGuard..."

    # Enable IP forwarding for WireGuard routing
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
    sysctl -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true

    # Create a port forwarding helper service using socat
    install_pkg socat
    # Forward incoming traffic on FWD_PORT to the foreign server's WG IP on FWD_PORT
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
    # This listens on FWD_PORT locally and forwards through the TLS relay
    # to localhost:FWD_PORT on the foreign server (where 3x-ui listens)
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
    # listen on 0.0.0.0:FWD_PORT, forward to 127.0.0.1:FWD_PORT on the foreign server
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
#  CONNECT TUNNEL (Main Entry)
# ══════════════════════════════════════════════════════════════════════════════
connect_tunnel() {
    echo ""
    info "=========================================="
    info "  Tommy v${TOMMY_VER} - Connect Port Forwarding Tunnel"
    info "  (Iranian Server / Client Side)"
    info "=========================================="
    echo ""
    info "Enter the credentials from the foreign server."
    info "(Found in /root/tommy-<name>-client-info.txt on the foreign server)"
    echo ""

    # Step 1: Tunnel name
    read -rp "Enter a name for this tunnel (e.g. tunnel1): " TNAME
    TNAME="${TNAME:-tunnel1}"
    TNAME=$(echo "$TNAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
    if [[ -z "$TNAME" ]]; then
        err "Tunnel name cannot be empty."
        return
    fi

    local SVC_NAME="tommy-${TNAME}"
    if [[ -d "${TOMMY_DIR}/${TNAME}" ]] || [[ -f "/etc/systemd/system/${SVC_NAME}.service" ]]; then
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
    read -rp "Enter forward port (same as foreign server) [443]: " FWD_PORT
    FWD_PORT="${FWD_PORT:-443}"

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

    # Step 7: Method-specific setup
    case "$METHOD_CHOICE" in
        1)
            # SSH Tunnel
            read -rp "Enter SSH port on foreign server [22]: " SSH_PORT
            SSH_PORT="${SSH_PORT:-22}"
            connect_ssh_tunnel "$TNAME" "$FOREIGN_IP" "$SSH_PORT" "$FWD_PORT" "$PROFILE"
            ;;
        2)
            # WireGuard
            read -rp "Enter WireGuard UDP port on foreign server [51820]: " WG_PORT
            WG_PORT="${WG_PORT:-51820}"
            connect_wireguard_tunnel "$TNAME" "$FOREIGN_IP" "$WG_PORT" "$FWD_PORT" "$PROFILE"
            ;;
        3)
            # Gost
            read -rp "Enter Gost tunnel port on foreign server [8443]: " TUNNEL_PORT
            TUNNEL_PORT="${TUNNEL_PORT:-8443}"
            read -rp "Enter Gost password from foreign server: " GOST_PASS
            if [[ -z "$GOST_PASS" ]]; then
                err "Gost password is required."
                return
            fi
            connect_gost_tunnel "$TNAME" "$FOREIGN_IP" "$TUNNEL_PORT" "$FWD_PORT" "$GOST_PASS" "$PROFILE"
            ;;
        4)
            # Hysteria2
            read -rp "Enter Hysteria2 tunnel port on foreign server [8443]: " TUNNEL_PORT
            TUNNEL_PORT="${TUNNEL_PORT:-8443}"
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
    for info_file in "${TOMMY_DIR}"/*/tunnel-info.txt; do
        if [[ ! -f "$info_file" ]]; then
            continue
        fi
        FOUND=1
        local TNAME="" METHOD="" FOREIGN_IP="" FWD_PORT="" PROFILE="" CREATED="" LOCAL_IP=""
        # shellcheck disable=SC1090
        source "$info_file"
        local SVC_NAME="tommy-${TNAME}"
        local STATUS="STOPPED"
        if systemctl is-active --quiet "$SVC_NAME" 2>/dev/null; then
            STATUS="RUNNING"
        fi
        echo ""
        echo -e "  ${GREEN}Name:${NC}      ${TNAME}"
        echo -e "  ${GREEN}Method:${NC}    ${METHOD}"
        echo -e "  ${GREEN}Foreign:${NC}   ${FOREIGN_IP}"
        echo -e "  ${GREEN}Fwd Port:${NC}  ${FWD_PORT}"
        echo -e "  ${GREEN}Profile:${NC}   ${PROFILE}"
        echo -e "  ${GREEN}Local IP:${NC}  ${LOCAL_IP}"
        echo -e "  ${GREEN}Service:${NC}   ${SVC_NAME}"
        echo -e "  ${GREEN}Status:${NC}    ${STATUS}"
        echo -e "  ${GREEN}Created:${NC}   ${CREATED}"
        echo -e "  ${CYAN}──────────────────────────────────${NC}"
    done

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
        # shellcheck disable=SC1090
        source "${TUNNEL_DIR}/tunnel-info.txt"
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
        wg-quick down wg0 2>/dev/null || true
        rm -f /etc/wireguard/wg0.conf 2>/dev/null || true
    fi

    systemctl daemon-reload

    # Remove tunnel config directory
    rm -rf "$TUNNEL_DIR"

    # Close firewall port
    if [[ -n "$FWD_PORT" ]]; then
        close_firewall "$FWD_PORT" tcp
    fi

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
                if systemctl start "tommy-${SM_NAME}" 2>/dev/null; then
                    info "Tunnel '${SM_NAME}' started."
                else
                    warn "Failed to start tunnel '${SM_NAME}'."
                fi
                # Also start WireGuard forwarding if applicable
                if [[ -f "/etc/systemd/system/tommy-${SM_NAME}-fwd.service" ]]; then
                    systemctl start "tommy-${SM_NAME}-fwd" 2>/dev/null || true
                fi
                ;;
            3)
                list_tunnels
                read -rp "Enter tunnel name to STOP: " SM_NAME
                SM_NAME=$(echo "$SM_NAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
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
                if systemctl restart "tommy-${SM_NAME}" 2>/dev/null; then
                    info "Tunnel '${SM_NAME}' restarted."
                else
                    warn "Failed to restart tunnel '${SM_NAME}'."
                fi
                if [[ -f "/etc/systemd/system/tommy-${SM_NAME}-fwd.service" ]]; then
                    systemctl restart "tommy-${SM_NAME}-fwd" 2>/dev/null || true
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
    info "  Testing Tunnel Connection"
    info "=========================================="
    echo ""

    # Find active tunnels
    local FOUND=0
    for info_file in "${TOMMY_DIR}"/*/tunnel-info.txt; do
        if [[ ! -f "$info_file" ]]; then
            continue
        fi
        FOUND=1
        local TNAME="" METHOD="" FOREIGN_IP="" FWD_PORT=""
        # shellcheck disable=SC1090
        source "$info_file"
        local SVC_NAME="tommy-${TNAME}"
        if systemctl is-active --quiet "$SVC_NAME" 2>/dev/null; then
            info "Testing tunnel '${TNAME}' (${METHOD}) on port ${FWD_PORT}..."

            # Test if the port is listening
            if ss -tlnp 2>/dev/null | grep -q ":${FWD_PORT} "; then
                info "Port ${FWD_PORT} is LISTENING on this server."
            else
                warn "Port ${FWD_PORT} is NOT listening. Tunnel may not be working."
                continue
            fi

            # Try to connect through the tunnel
            local TEST_RESULT=""
            TEST_RESULT=$(timeout 10 bash -c "echo '' | nc -w 5 ${LOCAL_IP} ${FWD_PORT} 2>/dev/null && echo 'PORT_OPEN' || echo 'PORT_CLOSED'" 2>/dev/null)
            if echo "$TEST_RESULT" | grep -q "PORT_OPEN"; then
                info "Port ${FWD_PORT} is accepting connections."
            else
                warn "Port ${FWD_PORT} is not accepting connections."
            fi
        else
            warn "Tunnel '${TNAME}' is STOPPED."
        fi
    done

    if [[ "$FOUND" -eq 0 ]]; then
        warn "No tunnels found to test."
    fi

    echo ""
    info "To fully test: make sure 3x-ui is running on the foreign server,"
    info "then configure External Proxy in 3x-ui with this server's IP and the forward port."
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN MENU
# ══════════════════════════════════════════════════════════════════════════════
main_menu() {
    show_banner
    echo -e "${BOLD}  1)${NC} Connect to Tunnel"
    echo -e "${BOLD}  2)${NC} Service Manager (Start/Stop/Restart/Delete)"
    echo -e "${BOLD}  3)${NC} List Tunnels"
    echo -e "${BOLD}  4)${NC} Delete Tunnel"
    echo -e "${BOLD}  5)${NC} Test Connection"
    echo -e "${BOLD}  6)${NC} System Optimization (BBR + Buffers)"
    echo -e "${BOLD}  0)${NC} Exit"
    echo ""
    read -rp "Select [0-6]: " MAIN_CHOICE

    case "$MAIN_CHOICE" in
        1) connect_tunnel ;;
        2) service_manager ;;
        3) list_tunnels ;;
        4) delete_tunnel ;;
        5) test_connection ;;
        6) optimize_system ;;
        0) exit 0 ;;
        *) warn "Invalid choice." ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
#  ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════════
check_root
detect_os
LOCAL_IP=$(get_local_ip)
info "This server IP: ${LOCAL_IP}"
mkdir -p "${TOMMY_DIR}"

while true; do
    main_menu
done
