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
#  Version:        1.0.5
#  Author:         hamb4
#  Description:    Secure Port-Forwarding Tunnel - Iranian Server (Client) Side
#  Repository:     https://github.com/hamb4/tommy-tunnel
#
#  Tunnel Mode:    Port Forwarding (x-ui External Proxy Model)
#    - User chooses port (e.g. 443) on both servers
#    - Foreign server generates a private key unique to this server
#    - This server enters that key to authenticate
#    - All traffic flows through the chosen port via authenticated tunnel
#    - SOCKS5 proxy on 127.0.0.1:10808
#    - HTTP proxy on 127.0.0.1:10809
#
#  Security Levels:
#    1) VMess + AES-128-GCM         (Standard)
#    2) VLESS + TLS                 (Enhanced)
#    3) VLESS + Reality             (Maximum)
#
#  USAGE:
#    chmod +x tommy-client-iran.sh
#    sudo ./tommy-client-iran.sh
#===============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

TOMMY_VER="1.0.5"
TOMMY_DIR="/etc/tommy"
SOCKS_PORT="10808"
HTTP_PORT="10809"

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
generate_password() { openssl rand -base64 32 | tr -d '/+=' | head -c 32; }

# ── Firewall Helper ───────────────────────────────────────────────────────────
open_firewall() {
    local port=$1
    local proto=${2:-tcp}
    info "Opening ${proto^^} port ${port}..."
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    if command -v iptables &>/dev/null; then
        iptables -I INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || true
    fi
}

# ── Install Dependencies ─────────────────────────────────────────────────────
install_deps() {
    info "Installing dependencies..."
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
            apt-get update -y
            apt-get install -y curl wget unzip openssl uuid-runtime 2>/dev/null || true
        elif [[ "$ID" == "centos" || "$ID" == "rhel" || "$ID" == "rocky" ]]; then
            yum install -y curl wget unzip openssl uuid-runtime 2>/dev/null || true
        elif [[ "$ID" == "arch" ]]; then
            pacman -Sy --noconfirm curl wget unzip openssl 2>/dev/null || true
        fi
    fi

    # Enable BBR congestion control
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        if ! grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        fi
        sysctl -p /etc/sysctl.conf 2>/dev/null || true
        info "BBR enabled."
    fi

    # Create Tommy directories
    mkdir -p "${TOMMY_DIR}"
    chmod 700 "${TOMMY_DIR}"
    chown root:root "${TOMMY_DIR}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  SECURITY HARDENING
# ══════════════════════════════════════════════════════════════════════════════
harden_security() {
    info "Applying security hardening..."

    # 1. UFW
    if command -v ufw &>/dev/null; then
        if ! ufw status 2>/dev/null | grep -q "active"; then
            info "Enabling UFW with deny-incoming default..."
            ufw --force enable 2>/dev/null || true
            ufw default deny incoming 2>/dev/null || true
            ufw default allow outgoing 2>/dev/null || true
            ufw allow ssh 2>/dev/null || true
            ufw allow 22/tcp 2>/dev/null || true
        fi
    fi

    # 2. SSH hardening
    if [[ -f /etc/ssh/sshd_config ]]; then
        info "Hardening SSH configuration..."
        if grep -q "^#*PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config 2>/dev/null || true
        elif ! grep -q "PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null; then
            echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
        fi
        if grep -q "^#*PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config 2>/dev/null || true
        elif ! grep -q "PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null; then
            echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config
        fi
        if grep -q "^#*MaxAuthTries" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config 2>/dev/null || true
        elif ! grep -q "MaxAuthTries" /etc/ssh/sshd_config 2>/dev/null; then
            echo "MaxAuthTries 3" >> /etc/ssh/sshd_config
        fi
        if grep -q "^#*PermitEmptyPasswords" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config 2>/dev/null || true
        elif ! grep -q "PermitEmptyPasswords" /etc/ssh/sshd_config 2>/dev/null; then
            echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config
        fi
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    fi

    # 3. Kernel hardening
    info "Applying kernel security parameters..."
    local SYSCTL_SECURITY=/etc/sysctl.d/99-tommy-security.conf
    cat > "$SYSCTL_SECURITY" <<EOF
# Tommy v${TOMMY_VER} - Security Hardening
kernel.randomize_va_space=2
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
fs.suid_dumpable=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
EOF
    sysctl -p "$SYSCTL_SECURITY" 2>/dev/null || true

    # 4. Disable unnecessary services
    for svc in avahi-daemon cups rpcbind; do
        if systemctl is-enabled "${svc}" 2>/dev/null | grep -q "enabled"; then
            info "Disabling unnecessary service: ${svc}"
            systemctl stop "${svc}" 2>/dev/null || true
            systemctl disable "${svc}" 2>/dev/null || true
        fi
    done

    info "Security hardening applied."
}

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL XRAY
# ══════════════════════════════════════════════════════════════════════════════
install_xray() {
    if command -v xray &>/dev/null; then
        info "Xray already installed: $(xray version 2>/dev/null | head -1)"
        return 0
    fi
    info "Installing Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>/dev/null || true
    if ! command -v xray &>/dev/null; then
        error "Xray installation failed. Cannot set up tunnel."
    fi
    info "Xray installed: $(xray version 2>/dev/null | head -1)"
    # Stop default xray service - we use tommy-prefixed services
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
#  CREATE TUNNEL (Port Forwarding - x-ui External Proxy Client Model)
# ══════════════════════════════════════════════════════════════════════════════
create_tunnel() {
    echo ""
    info "================================================================"
    info "  Tommy v${TOMMY_VER} - Create Port Forwarding Tunnel"
    info "  (Iranian Server / Client Side)"
    info "================================================================"
    echo ""
    info "Enter the credentials you received from the FOREIGN server."
    info "(Found in /root/tommy-<name>-client-info.txt on the foreign server)"
    echo ""

    # Step 1: Tunnel name
    read -rp "Enter a name for this tunnel (e.g. tunnel1): " TUNNEL_NAME
    TUNNEL_NAME="${TUNNEL_NAME:-tunnel1}"
    TUNNEL_NAME=$(echo "$TUNNEL_NAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
    [[ -z "$TUNNEL_NAME" ]] && error "Tunnel name cannot be empty."

    # Check if tunnel already exists
    local SVC_NAME="tommy-${TUNNEL_NAME}"
    if systemctl is-active --quiet "$SVC_NAME" 2>/dev/null || [[ -f "/etc/systemd/system/${SVC_NAME}.service" ]]; then
        error "A tunnel named '${TUNNEL_NAME}' already exists. Choose a different name or delete it first."
    fi

    # Step 2: Foreign server IP
    read -rp "Enter FOREIGN server IP: " FOREIGN_IP
    [[ -z "$FOREIGN_IP" ]] && error "Foreign server IP required."

    # Step 3: Tunnel port (same as foreign server)
    read -rp "Enter tunnel port (same as foreign server) [443]: " TUNNEL_PORT
    TUNNEL_PORT="${TUNNEL_PORT:-443}"

    # Step 4: Private key (UUID) from foreign server
    echo ""
    info "Enter the AUTH KEY (UUID) generated on the foreign server."
    info "This is the unique private key for authenticating your tunnel."
    read -rp "Auth Key (UUID): " TUNNEL_UUID
    [[ -z "$TUNNEL_UUID" ]] && error "Auth key is required."

    # Step 5: Security level (must match foreign server)
    echo ""
    info "Select SECURITY level (MUST match foreign server setting):"
    echo "  1) Standard  - VMess + AES-128-GCM"
    echo "  2) Enhanced  - VLESS + TLS"
    echo "  3) Maximum   - VLESS + Reality"
    read -rp "Select security [1-3, default=3]: " SECURITY_LEVEL
    SECURITY_LEVEL="${SECURITY_LEVEL:-3}"

    # Step 6: Speed level (must match foreign server)
    echo ""
    info "Select SPEED level (MUST match foreign server setting):"
    echo "  1) Low       - 50 mbps"
    echo "  2) Medium    - 200 mbps"
    echo "  3) High      - 500 mbps"
    echo "  4) Maximum   - 1000 mbps"
    read -rp "Select speed [1-4, default=3]: " SPEED_LEVEL
    SPEED_LEVEL="${SPEED_LEVEL:-3}"

    # Step 7: Install Xray
    install_xray

    # Step 8: Configure based on security level
    local SEC_LABEL="" XRAY_CONFIG_DIR="${TOMMY_DIR}/${TUNNEL_NAME}"
    mkdir -p "$XRAY_CONFIG_DIR"
    chmod 700 "$XRAY_CONFIG_DIR"

    if [[ "$SECURITY_LEVEL" == "1" ]]; then
        SEC_LABEL="VMess+AES"
        _create_vmess_client "$XRAY_CONFIG_DIR" "$FOREIGN_IP" "$TUNNEL_PORT" "$TUNNEL_UUID" "$SPEED_LEVEL"
    elif [[ "$SECURITY_LEVEL" == "2" ]]; then
        SEC_LABEL="VLESS+TLS"
        _create_vless_tls_client "$XRAY_CONFIG_DIR" "$FOREIGN_IP" "$TUNNEL_PORT" "$TUNNEL_UUID" "$SPEED_LEVEL"
    else
        SEC_LABEL="VLESS+Reality"
        # Reality requires extra parameters from foreign server
        echo ""
        info "VLESS + Reality requires extra parameters from the foreign server."
        info "These were shown when creating the tunnel on the foreign server."
        echo ""
        read -rp "Enter Public Key (from foreign server): " PBK
        read -rp "Enter Short ID (from foreign server): " SID
        read -rp "Enter SNI [www.microsoft.com]: " SNI
        SNI="${SNI:-www.microsoft.com}"
        read -rp "Enter Fingerprint [chrome]: " FP
        FP="${FP:-chrome}"
        [[ -z "$PBK" || -z "$SID" ]] && error "Public Key and Short ID are required for VLESS+Reality."

        _create_vless_reality_client "$XRAY_CONFIG_DIR" "$FOREIGN_IP" "$TUNNEL_PORT" "$TUNNEL_UUID" "$SPEED_LEVEL" "$PBK" "$SID" "$SNI" "$FP"
    fi

    # Step 9: Create systemd service
    info "Creating tunnel service: ${SVC_NAME}..."
    cat > "/etc/systemd/system/${SVC_NAME}.service" <<SVCEOF
[Unit]
Description=Tommy Tunnel - ${TUNNEL_NAME} (${SEC_LABEL}) - Client
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c ${XRAY_CONFIG_DIR}/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable "$SVC_NAME"
    systemctl restart "$SVC_NAME"
    sleep 2

    if systemctl is-active --quiet "$SVC_NAME"; then
        info "Tunnel '${TUNNEL_NAME}' is RUNNING!"
    else
        warn "Tunnel '${TUNNEL_NAME}' may have failed. Check: journalctl -u ${SVC_NAME} -n 30"
    fi

    # Step 10: Set up system-wide proxy
    setup_system_proxy

    # Step 11: Test connection
    test_connection

    # Step 12: Save tunnel info
    local SPEED_LABEL=""
    case "$SPEED_LEVEL" in
        1) SPEED_LABEL="50 mbps" ;;
        2) SPEED_LABEL="200 mbps" ;;
        3) SPEED_LABEL="500 mbps" ;;
        4) SPEED_LABEL="1000 mbps" ;;
        *) SPEED_LABEL="Unknown" ;;
    esac

    cat > "${XRAY_CONFIG_DIR}/tunnel-info.txt" <<IEOF
TUNNEL_NAME=${TUNNEL_NAME}
FOREIGN_IP=${FOREIGN_IP}
TUNNEL_PORT=${TUNNEL_PORT}
SECURITY_LEVEL=${SECURITY_LEVEL}
SEC_LABEL=${SEC_LABEL}
SPEED_LEVEL=${SPEED_LEVEL}
SPEED_LABEL=${SPEED_LABEL}
TUNNEL_UUID=${TUNNEL_UUID}
SOCKS_PORT=${SOCKS_PORT}
HTTP_PORT=${HTTP_PORT}
SERVICE=${SVC_NAME}
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
IEOF
    chmod 600 "${XRAY_CONFIG_DIR}/tunnel-info.txt"

    # Step 13: Display summary
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Tommy v${TOMMY_VER} - Tunnel Setup Complete!                    ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Mode:     Port Forwarding (External Proxy)                ║${NC}"
    echo -e "${CYAN}║  Name:     ${TUNNEL_NAME}$(printf '%*s' $((44 - ${#TUNNEL_NAME})) '')║${NC}"
    echo -e "${CYAN}║  Foreign:  ${FOREIGN_IP}$(printf '%*s' $((44 - ${#FOREIGN_IP})) '')║${NC}"
    echo -e "${CYAN}║  Port:     ${TUNNEL_PORT}$(printf '%*s' $((44 - ${#TUNNEL_PORT})) '')║${NC}"
    echo -e "${CYAN}║  Security: ${SEC_LABEL}$(printf '%*s' $((44 - ${#SEC_LABEL})) '')║${NC}"
    echo -e "${CYAN}║  Speed:    ${SPEED_LABEL}$(printf '%*s' $((44 - ${#SPEED_LABEL})) '')║${NC}"
    echo -e "${CYAN}║  SOCKS5:   127.0.0.1:${SOCKS_PORT}$(printf '%*s' $((34 - ${#SOCKS_PORT})) '')║${NC}"
    echo -e "${CYAN}║  HTTP:     127.0.0.1:${HTTP_PORT}$(printf '%*s' $((34 - ${#HTTP_PORT})) '')║${NC}"
    echo -e "${CYAN}║  Service:  ${SVC_NAME}$(printf '%*s' $((44 - ${#SVC_NAME})) '')║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ── VMess client config (Security Level 1: Standard) ─────────────────────────
_create_vmess_client() {
    local CONFIG_DIR="$1" FIP="$2" PORT="$3" UUID="$4" SPEED="$5"
    info "Configuring VMess + AES-128-GCM tunnel client..."

    local STREAM_RECV=8388608
    case "$SPEED" in
        1) STREAM_RECV=2097152 ;;
        2) STREAM_RECV=4194304 ;;
        3) STREAM_RECV=8388608 ;;
        4) STREAM_RECV=16777216 ;;
    esac

    cat > "${CONFIG_DIR}/config.json" <<XEOF
{
  "log": {"loglevel":"warning"},
  "inbounds": [
    {"tag":"socks","listen":"127.0.0.1","port":${SOCKS_PORT},"protocol":"socks","settings":{"auth":"noauth","udp":true},"sniffing":{"enabled":true,"destOverride":["http","tls"]}},
    {"tag":"http","listen":"127.0.0.1","port":${HTTP_PORT},"protocol":"http","settings":{"allowTransparent":false},"sniffing":{"enabled":true,"destOverride":["http","tls"]}}
  ],
  "outbounds": [
    {"tag":"vmess-tunnel","protocol":"vmess","settings":{"vnext":[{"address":"${FIP}","port":${PORT},"users":[{"id":"${UUID}","alterId":0,"security":"aes-128-gcm"}]}]},"streamSettings":{"network":"tcp","sockopt":{"tcpFastOpen":true,"tcpKeepAliveInterval":30}}},
    {"tag":"direct","protocol":"freedom","settings":{}}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]}
}
XEOF
    chmod 600 "${CONFIG_DIR}/config.json"
    info "VMess tunnel client configured."
}

# ── VLESS + TLS client config (Security Level 2: Enhanced) ───────────────────
_create_vless_tls_client() {
    local CONFIG_DIR="$1" FIP="$2" PORT="$3" UUID="$4" SPEED="$5"
    info "Configuring VLESS + TLS tunnel client..."

    local STREAM_RECV=8388608
    case "$SPEED" in
        1) STREAM_RECV=2097152 ;;
        2) STREAM_RECV=4194304 ;;
        3) STREAM_RECV=8388608 ;;
        4) STREAM_RECV=16777216 ;;
    esac

    cat > "${CONFIG_DIR}/config.json" <<XEOF
{
  "log": {"loglevel":"warning"},
  "inbounds": [
    {"tag":"socks","listen":"127.0.0.1","port":${SOCKS_PORT},"protocol":"socks","settings":{"auth":"noauth","udp":true},"sniffing":{"enabled":true,"destOverride":["http","tls"]}},
    {"tag":"http","listen":"127.0.0.1","port":${HTTP_PORT},"protocol":"http","settings":{"allowTransparent":false},"sniffing":{"enabled":true,"destOverride":["http","tls"]}}
  ],
  "outbounds": [
    {"tag":"vless-tunnel","protocol":"vless","settings":{"vnext":[{"address":"${FIP}","port":${PORT},"users":[{"id":"${UUID}","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"serverName":"bing.com","allowInsecure":true},"sockopt":{"tcpFastOpen":true,"tcpKeepAliveInterval":30}}},
    {"tag":"direct","protocol":"freedom","settings":{}}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]}
}
XEOF
    chmod 600 "${CONFIG_DIR}/config.json"
    info "VLESS + TLS tunnel client configured."
}

# ── VLESS + Reality client config (Security Level 3: Maximum) ────────────────
_create_vless_reality_client() {
    local CONFIG_DIR="$1" FIP="$2" PORT="$3" UUID="$4" SPEED="$5" PBK="$6" SID="$7" SNI="$8" FP="$9"
    info "Configuring VLESS + Reality tunnel client (Maximum Security)..."

    cat > "${CONFIG_DIR}/config.json" <<XEOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[
    {"tag":"socks","listen":"127.0.0.1","port":${SOCKS_PORT},"protocol":"socks","settings":{"auth":"noauth","udp":true},"sniffing":{"enabled":true,"destOverride":["http","tls"]}},
    {"tag":"http","listen":"127.0.0.1","port":${HTTP_PORT},"protocol":"http","settings":{"allowTransparent":false},"sniffing":{"enabled":true,"destOverride":["http","tls"]}}
  ],
  "outbounds":[
    {"tag":"vless-reality","protocol":"vless","settings":{"vnext":[{"address":"${FIP}","port":${PORT},"users":[{"id":"${UUID}","encryption":"none","flow":"xtls-rprx-vision"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"${SNI}","fingerprint":"${FP}","publicKey":"${PBK}","shortId":"${SID}"}},"sockopt":{"tcpFastOpen":true,"tcpKeepAliveInterval":30}},
    {"tag":"direct","protocol":"freedom","settings":{}}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]}
}
XEOF
    chmod 600 "${CONFIG_DIR}/config.json"
    info "VLESS + Reality tunnel client configured."
}

# ══════════════════════════════════════════════════════════════════════════════
#  SYSTEM-WIDE PROXY
# ══════════════════════════════════════════════════════════════════════════════
setup_system_proxy() {
    echo ""
    read -rp "Set up system-wide proxy? [y/N]: " DO_SYS
    [[ "${DO_SYS,,}" != "y" ]] && return

    cat > /etc/profile.d/tommy-proxy.sh <<ENVEOF
export http_proxy="http://127.0.0.1:${HTTP_PORT}"
export https_proxy="http://127.0.0.1:${HTTP_PORT}"
export HTTP_PROXY="http://127.0.0.1:${HTTP_PORT}"
export HTTPS_PROXY="http://127.0.0.1:${HTTP_PORT}"
export no_proxy="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
export NO_PROXY="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
ENVEOF
    chmod +x /etc/profile.d/tommy-proxy.sh
    # shellcheck disable=SC1090
    source /etc/profile.d/tommy-proxy.sh
    info "System proxy set: http://127.0.0.1:${HTTP_PORT}"

    if [[ -d /etc/apt ]]; then
        cat > /etc/apt/apt.conf.d/99tommy-proxy <<PEOF
Acquire::http::Proxy "http://127.0.0.1:${HTTP_PORT}";
Acquire::https::Proxy "http://127.0.0.1:${HTTP_PORT}";
PEOF
    fi

    info "System-wide proxy configured for all new sessions."
}

# ══════════════════════════════════════════════════════════════════════════════
#  CONNECTION TEST
# ══════════════════════════════════════════════════════════════════════════════
test_connection() {
    echo ""
    info "================================================================"
    info "  Testing Connection..."
    info "================================================================"
    sleep 3

    local SOCKS_RESULT=""
    SOCKS_RESULT=$(curl -x socks5h://127.0.0.1:${SOCKS_PORT} -s --connect-timeout 10 https://api.ipify.org 2>/dev/null || echo "FAILED")

    if [[ "$SOCKS_RESULT" != "FAILED" && -n "$SOCKS_RESULT" ]]; then
        info "SOCKS5 OK! Tunnel IP: ${SOCKS_RESULT}"
    else
        warn "SOCKS5 test failed."
    fi

    local HTTP_RESULT=""
    HTTP_RESULT=$(curl -x http://127.0.0.1:${HTTP_PORT} -s --connect-timeout 10 https://api.ipify.org 2>/dev/null || echo "FAILED")

    if [[ "$HTTP_RESULT" != "FAILED" ]]; then
        info "HTTP proxy OK! Tunnel IP: ${HTTP_RESULT}"
    else
        warn "HTTP proxy test failed."
    fi

    local DIRECT_IP=""
    DIRECT_IP=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo "unknown")
    info "Direct IP: ${DIRECT_IP}"

    if [[ "$SOCKS_RESULT" != "FAILED" && "$SOCKS_RESULT" != "$DIRECT_IP" ]]; then
        info "SUCCESS! Your IP is hidden through Tommy!"
    else
        warn "IP may not be hidden. Check your tunnel configuration."
    fi
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  LIST TUNNELS
# ══════════════════════════════════════════════════════════════════════════════
list_tunnels() {
    echo ""
    info "================================================================"
    info "  Tommy v${TOMMY_VER} - Active Tunnels"
    info "================================================================"

    local FOUND=0
    for info_file in "${TOMMY_DIR}"/*/tunnel-info.txt; do
        [[ ! -f "$info_file" ]] && continue
        FOUND=1
        # shellcheck disable=SC1090
        source "$info_file"
        local SVC_NAME="tommy-${TUNNEL_NAME}"
        local STATUS="STOPPED"
        if systemctl is-active --quiet "$SVC_NAME" 2>/dev/null; then
            STATUS="RUNNING"
        fi
        echo ""
        echo -e "  ${GREEN}Name:${NC}      ${TUNNEL_NAME}"
        echo -e "  ${GREEN}Foreign:${NC}   ${FOREIGN_IP}"
        echo -e "  ${GREEN}Port:${NC}      ${TUNNEL_PORT}"
        echo -e "  ${GREEN}Security:${NC}  ${SEC_LABEL}"
        echo -e "  ${GREEN}Speed:${NC}     ${SPEED_LABEL}"
        echo -e "  ${GREEN}SOCKS5:${NC}    127.0.0.1:${SOCKS_PORT}"
        echo -e "  ${GREEN}HTTP:${NC}      127.0.0.1:${HTTP_PORT}"
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
        error "Tunnel '${DEL_NAME}' not found."
    fi

    # Confirm deletion
    echo ""
    warn "You are about to DELETE tunnel: ${DEL_NAME}"
    warn "This will stop the service, remove configs, and delete all related files."
    read -rp "Are you sure? Type 'yes' to confirm: " CONFIRM
    [[ "${CONFIRM}" != "yes" ]] && { info "Deletion cancelled."; return; }

    # Stop and disable service
    systemctl stop "$SVC_NAME" 2>/dev/null || true
    systemctl disable "$SVC_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SVC_NAME}.service"
    systemctl daemon-reload

    # Remove tunnel config directory
    rm -rf "$TUNNEL_DIR"

    info "Tunnel '${DEL_NAME}' has been DELETED."
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  SERVICE MANAGER
# ══════════════════════════════════════════════════════════════════════════════
service_manager() {
    while true; do
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║  Tommy v${TOMMY_VER} - Service Manager                            ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║  1) List all tunnels                                        ║${NC}"
        echo -e "${CYAN}║  2) Start a tunnel                                          ║${NC}"
        echo -e "${CYAN}║  3) Stop a tunnel                                           ║${NC}"
        echo -e "${CYAN}║  4) Restart a tunnel                                        ║${NC}"
        echo -e "${CYAN}║  5) View tunnel status                                      ║${NC}"
        echo -e "${CYAN}║  6) View tunnel logs                                        ║${NC}"
        echo -e "${CYAN}║  7) Delete a tunnel                                         ║${NC}"
        echo -e "${CYAN}║  8) Test tunnel connection                                  ║${NC}"
        echo -e "${CYAN}║  9) Back to main menu                                       ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
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
                systemctl start "tommy-${SM_NAME}" 2>/dev/null && info "Tunnel '${SM_NAME}' started." || warn "Failed to start tunnel '${SM_NAME}'."
                ;;
            3)
                list_tunnels
                read -rp "Enter tunnel name to STOP: " SM_NAME
                SM_NAME=$(echo "$SM_NAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
                systemctl stop "tommy-${SM_NAME}" 2>/dev/null && info "Tunnel '${SM_NAME}' stopped." || warn "Failed to stop tunnel '${SM_NAME}'."
                ;;
            4)
                list_tunnels
                read -rp "Enter tunnel name to RESTART: " SM_NAME
                SM_NAME=$(echo "$SM_NAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
                systemctl restart "tommy-${SM_NAME}" 2>/dev/null && info "Tunnel '${SM_NAME}' restarted." || warn "Failed to restart tunnel '${SM_NAME}'."
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
#  MAIN MENU
# ══════════════════════════════════════════════════════════════════════════════
show_menu() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              ████████╗██╗   ██╗██████╗ ███╗   ███╗              ║${NC}"
    echo -e "${CYAN}║              ╚══██╔══╝╚██╗ ██╔╝██╔══██╗████╗ ████║              ║${NC}"
    echo -e "${CYAN}║                 ██║    ╚████╔╝ ██████╔╝██╔████╔██║              ║${NC}"
    echo -e "${CYAN}║                 ██║     ╚██╔╝  ██╔══██╗██║╚██╔╝██║              ║${NC}"
    echo -e "${CYAN}║                 ██║      ██║   ██████╔╝██║ ╚═╝ ██║              ║${NC}"
    echo -e "${CYAN}║                 ╚═╝      ╚═╝   ╚═════╝ ╚═╝     ╚═╝              ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║    Port Forwarding Tunnel v${TOMMY_VER} - Iranian Server            ║${NC}"
    echo -e "${CYAN}║    Author: hamb4                                               ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║                                                                ║${NC}"
    echo -e "${CYAN}║  1)  Create Tunnel       (New port-forwarding tunnel)         ║${NC}"
    echo -e "${CYAN}║  2)  Service Manager     (Start/Stop/Restart/Delete tunnels)  ║${NC}"
    echo -e "${CYAN}║  3)  List Tunnels        (View all tunnels)                  ║${NC}"
    echo -e "${CYAN}║  4)  Test Connection     (Check if tunnel is working)         ║${NC}"
    echo -e "${CYAN}║  5)  System Prep         (Install deps + harden security)     ║${NC}"
    echo -e "${CYAN}║  0)  Exit                                                        ║${NC}"
    echo -e "${CYAN}║                                                                ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "Select [0-5]: " MAIN_CHOICE

    case "$MAIN_CHOICE" in
        1) create_tunnel ;;
        2) service_manager ;;
        3) list_tunnels ;;
        4) test_connection ;;
        5) install_deps; harden_security ;;
        0) exit 0 ;;
        *) warn "Invalid choice." ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
#  ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════════
main() {
    check_root
    banner
    install_deps

    while true; do
        show_menu
    done
}

main "$@"
