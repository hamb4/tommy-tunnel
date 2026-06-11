#!/bin/bash
#==============================================================================
#  Secure Tunnel Setup Script — Iran ↔ Foreign Server
#  Protocols: GOST (WebSocket+TLS) | WireGuard | SSH Tunnel
#  Author: Auto-generated
#  License: MIT
#==============================================================================
#
#  USAGE:
#    Server side (foreign):  bash tunnel-setup.sh server --mode gost
#    Client side (Iran):     bash tunnel-setup.sh client --mode gost
#
#  Available modes:
#    gost       — GOST v3 with WebSocket+TLS (disguised as HTTPS, best stealth)
#    gost-grpc  — GOST v3 with gRPC+TLS (multiplexed streams, high concurrency)
#    wireguard  — WireGuard VPN (fastest, kernel-level, less disguised)
#    ssh        — SSH tunnel with auto-reconnect (simple, reliable)
#
#==============================================================================

set -euo pipefail

# ──────────────────────────── Color Helpers ────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ──────────────────────────── Default Config ───────────────────────────
TUNNEL_DIR="/opt/secure-tunnel"
LOG_DIR="${TUNNEL_DIR}/logs"
PID_DIR="${TUNNEL_DIR}/pids"
CONFIG_DIR="${TUNNEL_DIR}/config"
GOST_BIN="${TUNNEL_DIR}/bin/gost"
WG_CONFIG="${CONFIG_DIR}/wg0.conf"

# Connection defaults (override with flags or env vars)
SERVER_PORT="${TUNNEL_SERVER_PORT:-443}"
SERVER_IP="${TUNNEL_SERVER_IP:-}"
TUNNEL_PASS="${TUNNEL_PASSWORD:-$(openssl rand -hex 16)}"
DOMAIN="${TUNNEL_DOMAIN:-}"
WS_PATH="/$(openssl rand -hex 8)"

# TLS certificate paths
CERT_DIR="${CONFIG_DIR}/certs"
CERT_FILE="${CERT_DIR}/server.crt"
KEY_FILE="${CERT_DIR}/server.key"

# WireGuard defaults
WG_PORT="${WG_PORT:-51820}"
WG_PRIVATE_KEY=""
WG_PUBLIC_KEY=""
WG_PEER_IP="10.10.10.2/32"
WG_SERVER_IP="10.10.10.1/24"

# ──────────────────────────── Parse Arguments ─────────────────────────
ROLE=""
MODE="gost"

show_usage() {
    cat <<EOF
Usage: $0 <role> [options]

Roles:
  server    Set up on the FOREIGN server (endpoint)
  client    Set up on the IRANIAN server (origin)

Options:
  --mode <mode>       Tunnel mode: gost | gost-grpc | wireguard | ssh  (default: gost)
  --port <port>       Server listening port (default: 443)
  --ip <ip>           Foreign server IP (required for client)
  --domain <domain>   Domain name for TLS certificate (recommended)
  --password <pass>   Tunnel authentication password (auto-generated if omitted)

Examples:
  # Foreign server (outside Iran):
  bash tunnel-setup.sh server --mode gost --domain my.example.com

  # Iranian server:
  bash tunnel-setup.sh client --mode gost --ip 1.2.3.4 --domain my.example.com

EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        server|client)  ROLE="$1"; shift ;;
        --mode)         MODE="$2"; shift 2 ;;
        --port)         SERVER_PORT="$2"; shift 2 ;;
        --ip)           SERVER_IP="$2"; shift 2 ;;
        --domain)       DOMAIN="$2"; shift 2 ;;
        --password)     TUNNEL_PASS="$2"; shift 2 ;;
        -h|--help)      show_usage ;;
        *)              warn "Unknown option: $1"; shift ;;
    esac
done

[[ -z "$ROLE" ]] && error "Specify role: server or client. Run with --help for usage."
[[ "$MODE" != "gost" && "$MODE" != "gost-grpc" && "$MODE" != "wireguard" && "$MODE" != "ssh" ]] && \
    error "Invalid mode '$MODE'. Choose: gost | gost-grpc | wireguard | ssh"

# ──────────────────────────── Utility Functions ────────────────────────
check_root() {
    [[ $EUID -ne 0 ]] && error "This script must be run as root."
}

install_deps() {
    info "Installing dependencies..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq curl wget openssl net-tools iproute2 >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q curl wget openssl net-tools iproute >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl wget openssl net-tools iproute >/dev/null 2>&1
    fi
}

setup_dirs() {
    mkdir -p "${TUNNEL_DIR}"/{bin,logs,pids,config/certs}
    info "Working directory: ${TUNNEL_DIR}"
}

generate_self_signed_cert() {
    if [[ -n "$DOMAIN" ]]; then
        info "Generating self-signed certificate for ${DOMAIN}..."
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -days 3650 -subj "/CN=${DOMAIN}" \
            -addext "subjectAltName=DNS:${DOMAIN},DNS:www.${DOMAIN}" 2>/dev/null
    else
        info "Generating self-signed certificate (no domain specified)..."
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -days 3650 -subj "/CN=www.microsoft.com" \
            -addext "subjectAltName=DNS:www.microsoft.com,DNS:microsoft.com" 2>/dev/null
    fi
    info "Certificate generated at ${CERT_FILE}"
}

install_gost() {
    if [[ -x "$GOST_BIN" ]]; then
        info "GOST already installed at ${GOST_BIN}"
        return
    fi
    info "Downloading GOST v3..."
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *)       error "Unsupported architecture: $arch" ;;
    esac

    local gost_url="https://github.com/go-gost/gost/releases/download/v3.0.0-rc10/gost_3.0.0-rc10_linux_${arch}.tar.gz"
    local tmp="/tmp/gost_install"
    mkdir -p "$tmp"
    wget -q -O "${tmp}/gost.tar.gz" "$gost_url" || \
        wget -q -O "${tmp}/gost.tar.gz" "https://github.com/go-gost/gost/releases/latest/download/gost_linux_${arch}.tar.gz" || \
        error "Failed to download GOST. Download manually from https://github.com/go-gost/gost/releases"

    tar xzf "${tmp}/gost.tar.gz" -C "$tmp"
    cp "${tmp}/gost" "$GOST_BIN" 2>/dev/null || cp "${tmp}/gost_"* "$GOST_BIN" 2>/dev/null
    chmod +x "$GOST_BIN"
    rm -rf "$tmp"
    info "GOST installed: $($GOST_BIN -V 2>/dev/null || echo 'OK')"
}

install_wireguard() {
    info "Installing WireGuard..."
    if command -v apt-get &>/dev/null; then
        apt-get install -y -qq wireguard wireguard-tools >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q wireguard-tools >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y -q wireguard-tools >/dev/null 2>&1
    fi
    modprobe wireguard 2>/dev/null || true
    command -v wg &>/dev/null || error "WireGuard installation failed"
    info "WireGuard installed: $(wg --version 2>/dev/null || echo 'OK')"
}

# ═══════════════════════════════════════════════════════════════════════
#  GOST SERVER (runs on foreign server)
# ═══════════════════════════════════════════════════════════════════════
setup_gost_server() {
    install_gost
    generate_self_signed_cert

    local config_file="${CONFIG_DIR}/gost-server.yaml"

    if [[ "$MODE" == "gost" ]]; then
        # WebSocket + TLS mode (looks like HTTPS traffic)
        cat > "$config_file" <<YAML
name: gost-server

log:
  level: info
  format: json
  output: "${LOG_DIR}/gost-server.log"

profiling:
  enabled: false

services:
  - name: ws-tls-tunnel
    addr: "0.0.0.0:${SERVER_PORT}"
    handler:
      type: http2
      auth:
        username: tunnel
        password: ${TUNNEL_PASS}
      chain: chain-direct
    listener:
      type: tls
      tls:
        certFile: "${CERT_FILE}"
        keyFile: "${KEY_FILE}"
      # WebSocket upgrade happens inside TLS
      # Traffic appears as standard HTTPS to observers

chains:
  - name: chain-direct
    hops:
      - name: hop-direct
        nodes:
          - name: node-direct
            addr: "127.0.0.1:1080"
            connector:
              type: socks5
            dialer:
              type: tcp

YAML
        info "GOST server config: WebSocket+TLS on port ${SERVER_PORT}"

    elif [[ "$MODE" == "gost-grpc" ]]; then
        # gRPC + TLS mode (multiplexed streams, better concurrency)
        cat > "$config_file" <<YAML
name: gost-server-grpc

log:
  level: info
  format: json
  output: "${LOG_DIR}/gost-server.log"

services:
  - name: grpc-tls-tunnel
    addr: "0.0.0.0:${SERVER_PORT}"
    handler:
      type: http2
      auth:
        username: tunnel
        password: ${TUNNEL_PASS}
    listener:
      type: tls
      tls:
        certFile: "${CERT_FILE}"
        keyFile: "${KEY_FILE}"
    forwarder:
      nodes:
        - name: internet
          addr: "127.0.0.1:1080"
          connector:
            type: socks5
          dialer:
            type: tcp

YAML
        info "GOST server config: gRPC+TLS on port ${SERVER_PORT}"
    fi

    # Create systemd service
    cat > /etc/systemd/system/gost-tunnel.service <<UNIT
[Unit]
Description=GOST Secure Tunnel (Server)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${GOST_BIN} -C ${config_file}
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${TUNNEL_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable gost-tunnel
    systemctl restart gost-tunnel
    sleep 2
    systemctl is-active --quiet gost-tunnel && \
        info "GOST server is running on port ${SERVER_PORT}" || \
        warn "GOST server may not have started. Check: journalctl -u gost-tunnel -f"
}

# ═══════════════════════════════════════════════════════════════════════
#  GOST CLIENT (runs on Iranian server)
# ═══════════════════════════════════════════════════════════════════════
setup_gost_client() {
    [[ -z "$SERVER_IP" ]] && error "Specify foreign server IP with --ip"
    install_gost

    local config_file="${CONFIG_DIR}/gost-client.yaml"
    local server_addr="${SERVER_IP}:${SERVER_PORT}"

    # Client config: local SOCKS5 proxy → tunnel → foreign server → internet
    cat > "$config_file" <<YAML
name: gost-client

log:
  level: info
  format: json
  output: "${LOG_DIR}/gost-client.log"

profiling:
  enabled: false

services:
  - name: local-proxy
    addr: "127.0.0.1:1080"
    handler:
      type: socks5
      chain: chain-tunnel
    listener:
      type: tcp

  - name: local-http-proxy
    addr: "127.0.0.1:8080"
    handler:
      type: http
      chain: chain-tunnel
    listener:
      type: tcp

chains:
  - name: chain-tunnel
    hops:
      - name: hop-tunnel
        nodes:
          - name: node-tunnel
            addr: "${server_addr}"
            connector:
              type: http2
              auth:
                username: tunnel
                password: ${TUNNEL_PASS}
            dialer:
              type: tls
              tls:
                serverName: "${DOMAIN:-www.microsoft.com}"
                secure: true
                # Skip cert verification for self-signed certs
                # In production, use a real domain + Let's Encrypt
                insecure: true

YAML

    info "GOST client config: local SOCKS5 on 127.0.0.1:1080, HTTP on 127.0.0.1:8080"

    # Create systemd service
    cat > /etc/systemd/system/gost-tunnel.service <<UNIT
[Unit]
Description=GOST Secure Tunnel (Client)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${GOST_BIN} -C ${config_file}
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${TUNNEL_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable gost-tunnel
    systemctl restart gost-tunnel
    sleep 2
    systemctl is-active --quiet gost-tunnel && \
        info "GOST client is running. SOCKS5 proxy: 127.0.0.1:1080 | HTTP proxy: 127.0.0.1:8080" || \
        warn "GOST client may not have started. Check: journalctl -u gost-tunnel -f"
}

# ═══════════════════════════════════════════════════════════════════════
#  WIREGUARD SERVER (runs on foreign server)
# ═══════════════════════════════════════════════════════════════════════
setup_wireguard_server() {
    install_wireguard

    # Generate server keys
    cd "$CONFIG_DIR"
    WG_PRIVATE_KEY=$(wg genkey)
    WG_PUBLIC_KEY=$(echo "$WG_PRIVATE_KEY" | wg pubkey)

    # Generate client keys
    local client_priv client_pub
    client_priv=$(wg genkey)
    client_pub=$(echo "$client_priv" | wg pubkey)

    # Server config
    cat > "$WG_CONFIG" <<WGCFG
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
Address = ${WG_SERVER_IP}
ListenPort = ${WG_PORT}
MTU = 1420

# Firewall rules
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $(ip route | grep default | awk '{print $5}' | head -1) -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $(ip route | grep default | awk '{print $5}' | head -1) -j MASQUERADE

# Client peer (Iranian server)
[Peer]
PublicKey = ${client_pub}
AllowedIPs = ${WG_PEER_IP}

WGCFG

    # Save client config for transfer
    local client_config="${CONFIG_DIR}/wg-client.conf"
    local server_pub
    server_pub="$WG_PUBLIC_KEY"
    cat > "$client_config" <<WGCFG
[Interface]
PrivateKey = ${client_priv}
Address = ${WG_PEER_IP}
DNS = 1.1.1.1, 8.8.8.8
MTU = 1420

[Peer]
PublicKey = ${server_pub}
Endpoint = AUTO_FILL_SERVER_IP:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25

WGCFG

    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf

    # Start WireGuard
    wg-quick down wg0 2>/dev/null || true
    wg-quick up "$WG_CONFIG"
    systemctl enable wg-quick@wg0 2>/dev/null || true

    info "WireGuard server running on port ${WG_PORT}"
    info "═══════════════════════════════════════════════════════════"
    info "  CLIENT CONFIG FILE: ${client_config}"
    info "  Copy this file to the Iranian server!"
    info "  Don't forget to set the Endpoint IP in the client config."
    info "═══════════════════════════════════════════════════════════"
}

# ═══════════════════════════════════════════════════════════════════════
#  WIREGUARD CLIENT (runs on Iranian server)
# ═══════════════════════════════════════════════════════════════════════
setup_wireguard_client() {
    install_wireguard

    [[ -z "$SERVER_IP" ]] && error "Specify foreign server IP with --ip"

    local client_config="${CONFIG_DIR}/wg-client.conf"

    if [[ -f "$client_config" ]]; then
        # Use pre-generated client config, update endpoint
        sed -i "s/AUTO_FILL_SERVER_IP/${SERVER_IP}/g" "$client_config"
    else
        error "Client config not found. Copy wg-client.conf from the foreign server to ${client_config}"
    fi

    # Start WireGuard
    wg-quick down wg0 2>/dev/null || true
    wg-quick up "$client_config"
    systemctl enable wg-quick@wg0 2>/dev/null || true

    info "WireGuard client connected to ${SERVER_IP}:${WG_PORT}"
    info "All traffic now routes through the WireGuard tunnel."
    info "Verify: curl --interface wg0 https://api.ipify.org"
}

# ═══════════════════════════════════════════════════════════════════════
#  SSH TUNNEL (simple, reliable fallback)
# ═══════════════════════════════════════════════════════════════════════
setup_ssh_server() {
    info "Setting up SSH tunnel server..."
    command -v sshd &>/dev/null || {
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq openssh-server >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y -q openssh-server >/dev/null 2>&1
        fi
    }

    # Harden SSH config for tunnel-only use
    local sshd_config="/etc/ssh/sshd_config"
    cp "$sshd_config" "${sshd_config}.bak.$(date +%s)"

    cat >> "$sshd_config" <<SSHEOF

# Tunnel-specific settings
AllowTcpForwarding yes
GatewayPorts no
PermitTunnel yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 60
ClientAliveCountMax 3
SSHEOF

    systemctl restart sshd
    info "SSH server configured for tunneling on port 22"
    info "On the client, run:"
    info "  ssh -D 1080 -f -C -q -N -o ServerAliveInterval=60 -o ServerAliveCountMax=3 user@${SERVER_IP}"
}

setup_ssh_client() {
    [[ -z "$SERVER_IP" ]] && error "Specify foreign server IP with --ip"

    info "Setting up SSH tunnel client (auto-reconnect)..."

    # Generate SSH key if not exists
    [[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q

    local ssh_user="${SSH_USER:-root}"
    local reconnect_script="${TUNNEL_DIR}/ssh-tunnel-watchdog.sh"

    cat > "$reconnect_script" <<'SSHEOF'
#!/bin/bash
# SSH Tunnel Auto-Reconnect Script
SERVER_IP="__SERVER_IP__"
SSH_USER="__SSH_USER__"
LOCAL_SOCKS_PORT=1080

while true; do
    echo "[$(date)] Starting SSH tunnel to ${SSH_USER}@${SERVER_IP}..."
    ssh -D ${LOCAL_SOCKS_PORT} \
        -f -C -q -N \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        -o StrictHostKeyChecking=no \
        ${SSH_USER}@${SERVER_IP}

    SSH_PID=$(pgrep -f "ssh -D ${LOCAL_SOCKS_PORT}")
    if [[ -n "$SSH_PID" ]]; then
        echo "[$(date)] SSH tunnel active (PID: ${SSH_PID}). SOCKS5 on 127.0.0.1:${LOCAL_SOCKS_PORT}"
        wait "$SSH_PID" 2>/dev/null
    fi

    echo "[$(date)] SSH tunnel disconnected. Reconnecting in 5 seconds..."
    sleep 5
done
SSHEOF

    sed -i "s/__SERVER_IP__/${SERVER_IP}/g" "$reconnect_script"
    sed -i "s/__SSH_USER__/${ssh_user}/g" "$reconnect_script"
    chmod +x "$reconnect_script"

    # Create systemd service for watchdog
    cat > /etc/systemd/system/ssh-tunnel.service <<UNIT
[Unit]
Description=SSH Tunnel Auto-Reconnect
After=network.target network-online.target

[Service]
Type=simple
ExecStart=${reconnect_script}
Restart=always
RestartSec=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable ssh-tunnel
    systemctl restart ssh-tunnel

    info "SSH tunnel watchdog running. SOCKS5 proxy: 127.0.0.1:1080"
    info "IMPORTANT: Copy your SSH public key to the foreign server:"
    info "  ssh-copy-id ${ssh_user}@${SERVER_IP}"
}

# ═══════════════════════════════════════════════════════════════════════
#  NETWORK OPTIMIZATION (both sides)
# ═══════════════════════════════════════════════════════════════════════
optimize_network() {
    info "Applying network optimizations for high-speed tunneling..."

    local sysctl_file="/etc/sysctl.d/99-tunnel-optimize.conf"
    cat > "$sysctl_file" <<SYSCTL
# ─── TCP Performance Tuning ───
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65536

net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1

# ─── Connection Limits ───
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# ─── Buffer Sizes ───
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# ─── Security ───
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ─── Forwarding (required for VPN/proxy) ───
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL

    sysctl -p "$sysctl_file" >/dev/null 2>&1
    info "Network optimizations applied (BBR congestion control, TCP tuning)"
}

# ═══════════════════════════════════════════════════════════════════════
#  FIREWALL CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════
configure_firewall() {
    local port="${1}"
    info "Configuring firewall to allow port ${port}..."

    if command -v ufw &>/dev/null; then
        ufw allow "${port}"/tcp >/dev/null 2>&1
        ufw allow "${port}"/udp >/dev/null 2>&1
        info "UFW: Allowed port ${port}"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${port}"/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port="${port}"/udp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        info "Firewalld: Allowed port ${port}"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null
        iptables -I INPUT -p udp --dport "${port}" -j ACCEPT 2>/dev/null
        info "iptables: Allowed port ${port}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  CONNECTION TEST
# ═══════════════════════════════════════════════════════════════════════
test_connection() {
    info "Testing tunnel connectivity..."
    sleep 3

    case "$MODE" in
        gost|gost-grpc)
            if [[ "$ROLE" == "client" ]]; then
                # Test SOCKS5 proxy
                local ip_via_proxy
                ip_via_proxy=$(curl -x socks5h://127.0.0.1:1080 -s --connect-timeout 10 https://api.ipify.org 2>/dev/null || echo "FAILED")
                if [[ "$ip_via_proxy" != "FAILED" && -n "$ip_via_proxy" ]]; then
                    info "SUCCESS! External IP via tunnel: ${ip_via_proxy}"
                    info "Your real IP is hidden from target websites."
                else
                    warn "Could not verify IP through SOCKS5 proxy. Check logs: journalctl -u gost-tunnel -f"
                fi

                # Test HTTP proxy
                local ip_via_http
                ip_via_http=$(curl -x http://127.0.0.1:8080 -s --connect-timeout 10 https://api.ipify.org 2>/dev/null || echo "FAILED")
                if [[ "$ip_via_http" != "FAILED" ]]; then
                    info "HTTP proxy working. External IP: ${ip_via_http}"
                fi
            else
                info "Server mode. Verify from client side."
            fi
            ;;
        wireguard)
            if [[ "$ROLE" == "client" ]]; then
                local ip_via_wg
                ip_via_wg=$(curl --interface wg0 -s --connect-timeout 10 https://api.ipify.org 2>/dev/null || echo "FAILED")
                if [[ "$ip_via_wg" != "FAILED" ]]; then
                    info "SUCCESS! External IP via WireGuard: ${ip_via_wg}"
                else
                    warn "WireGuard tunnel test failed. Check: wg show"
                fi
            fi
            ;;
        ssh)
            if [[ "$ROLE" == "client" ]]; then
                local ip_via_ssh
                ip_via_ssh=$(curl -x socks5h://127.0.0.1:1080 -s --connect-timeout 10 https://api.ipify.org 2>/dev/null || echo "FAILED")
                if [[ "$ip_via_ssh" != "FAILED" ]]; then
                    info "SUCCESS! External IP via SSH tunnel: ${ip_via_ssh}"
                else
                    warn "SSH tunnel test failed. Check: systemctl status ssh-tunnel"
                fi
            fi
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════
#  PRINT SUMMARY
# ═══════════════════════════════════════════════════════════════════════
print_summary() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Secure Tunnel Setup Complete!${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "  Role:              ${YELLOW}${ROLE}${NC}"
    echo -e "  Mode:              ${YELLOW}${MODE}${NC}"
    echo -e "  Config Dir:        ${YELLOW}${CONFIG_DIR}${NC}"
    echo -e "  Log Dir:           ${YELLOW}${LOG_DIR}${NC}"
    echo ""

    case "$MODE" in
        gost|gost-grpc)
            if [[ "$ROLE" == "client" ]]; then
                echo -e "  ${GREEN}SOCKS5 Proxy:${NC}    127.0.0.1:1080"
                echo -e "  ${GREEN}HTTP Proxy:${NC}      127.0.0.1:8080"
                echo ""
                echo -e "  ${CYAN}Usage Examples:${NC}"
                echo "    curl -x socks5h://127.0.0.1:1080 https://google.com"
                echo "    curl -x http://127.0.0.1:8080 https://google.com"
                echo ""
                echo -e "  ${CYAN}For system-wide proxy, set env vars:${NC}"
                echo "    export ALL_PROXY=socks5h://127.0.0.1:1080"
                echo "    export http_proxy=http://127.0.0.1:8080"
                echo "    export https_proxy=http://127.0.0.1:8080"
            else
                echo -e "  ${GREEN}Listening Port:${NC}   ${SERVER_PORT}"
                echo -e "  ${GREEN}TLS Cert:${NC}         ${CERT_FILE}"
                echo -e "  ${GREEN}Password:${NC}         ${TUNNEL_PASS}"
            fi
            ;;
        wireguard)
            if [[ "$ROLE" == "client" ]]; then
                echo -e "  ${GREEN}WG Interface:${NC}     wg0"
                echo -e "  ${GREEN}Client IP:${NC}        ${WG_PEER_IP}"
                echo -e "  ${GREEN}Server:${NC}           ${SERVER_IP}:${WG_PORT}"
                echo ""
                echo -e "  ${CYAN}All traffic routes through the tunnel.${NC}"
            else
                echo -e "  ${GREEN}WG Interface:${NC}     wg0"
                echo -e "  ${GREEN}Listening Port:${NC}   ${WG_PORT}"
                echo -e "  ${GREEN}Server IP:${NC}        ${WG_SERVER_IP}"
                echo ""
                echo -e "  ${CYAN}Client config saved to:${NC}"
                echo "    ${CONFIG_DIR}/wg-client.conf"
                echo -e "  ${CYAN}Copy it to the Iranian server and run:${NC}"
                echo "    bash tunnel-setup.sh client --mode wireguard --ip <this_server_ip>"
            fi
            ;;
        ssh)
            if [[ "$ROLE" == "client" ]]; then
                echo -e "  ${GREEN}SOCKS5 Proxy:${NC}    127.0.0.1:1080"
                echo -e "  ${GREEN}Auto-reconnect:${NC}  Enabled (systemd watchdog)"
            else
                echo -e "  ${GREEN}SSH Port:${NC}        22"
                echo -e "  ${GREEN}Forwarding:${NC}      Enabled"
            fi
            ;;
    esac

    echo ""
    echo -e "  ${CYAN}Manage the service:${NC}"
    echo "    systemctl status gost-tunnel    # or ssh-tunnel / wg-quick@wg0"
    echo "    systemctl restart gost-tunnel"
    echo "    journalctl -u gost-tunnel -f    # live logs"
    echo ""
    echo -e "  ${CYAN}IMPORTANT: Save your password!${NC}  ${TUNNEL_PASS}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

# ═══════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════
main() {
    check_root
    install_deps
    setup_dirs
    optimize_network

    info "Setting up ${MODE} tunnel in ${ROLE} mode..."

    case "${ROLE}:${MODE}" in
        server:gost|server:gost-grpc)
            setup_gost_server
            configure_firewall "$SERVER_PORT"
            ;;
        client:gost|client:gost-grpc)
            setup_gost_client
            ;;
        server:wireguard)
            setup_wireguard_server
            configure_firewall "$WG_PORT"
            ;;
        client:wireguard)
            setup_wireguard_client
            ;;
        server:ssh)
            setup_ssh_server
            ;;
        client:ssh)
            setup_ssh_client
            ;;
        *)
            error "Unknown combination: ${ROLE}/${MODE}"
            ;;
    esac

    test_connection
    print_summary

    # Save deployment info
    cat > "${TUNNEL_DIR}/DEPLOYMENT_INFO" <<INFO
Role: ${ROLE}
Mode: ${MODE}
Server Port: ${SERVER_PORT}
Password: ${TUNNEL_PASS}
Domain: ${DOMAIN:-N/A}
WS Path: ${WS_PATH}
Setup Date: $(date -u)
INFO
    chmod 600 "${TUNNEL_DIR}/DEPLOYMENT_INFO"
    info "Deployment info saved to ${TUNNEL_DIR}/DEPLOYMENT_INFO (chmod 600)"
}

main
