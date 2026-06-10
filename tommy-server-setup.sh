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
#  Description:    Secure Port-Forwarding Tunnel - Foreign Server Side
#  Repository:     https://github.com/hamb4/tommy-tunnel
#
#  Tunnel Mode:    Port Forwarding (x-ui External Proxy Model)
#    - User chooses port (e.g. 443) on both servers
#    - Foreign server generates a private key unique to the Iranian server
#    - Iranian server enters that key to authenticate
#    - All traffic flows through the chosen port via authenticated tunnel
#
#  Security Levels:
#    1) VMess + AES-128-GCM         (Standard)
#    2) VLESS + TLS                 (Enhanced)
#    3) VLESS + Reality             (Maximum)
#
#  USAGE:
#    chmod +x tommy-server-setup.sh
#    sudo ./tommy-server-setup.sh
#===============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

TOMMY_VER="1.0.5"
TOMMY_DIR="/etc/tommy"
TOMMY_LOG="/var/log/tommy"

# ── Helper Functions ──────────────────────────────────────────────────────────
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

check_root() { [[ $EUID -eq 0 ]] || error "This script must be run as root."; }

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
    fi
    info "Detected OS: ${OS_ID} ${OS_VERSION}"
}

generate_uuid() { uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid; }
generate_password() { openssl rand -base64 32 | tr -d '/+=' | head -c 32; }

# ── Firewall Helper ──────────────────────────────────────────────────────────
open_firewall() {
    local port=$1
    local proto=${2:-tcp}
    info "Opening ${proto^^} port ${port} in firewall..."
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

close_firewall() {
    local port=$1
    local proto=${2:-tcp}
    info "Closing ${proto^^} port ${port} in firewall..."
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    if command -v iptables &>/dev/null; then
        iptables -D INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || true
    fi
}

# ── Global State ─────────────────────────────────────────────────────────────
SERVER_IP=""

get_server_ip() {
    info "Detecting server public IP..."
    SERVER_IP=$(curl -s4 https://ifconfig.me 2>/dev/null \
             || curl -s4 https://api.ipify.org 2>/dev/null \
             || curl -s4 https://ip.sb 2>/dev/null)
    if [[ -z "$SERVER_IP" ]]; then
        read -rp "Could not auto-detect IP. Enter your server's public IP: " SERVER_IP
    fi
    info "Server IP: ${SERVER_IP}"
}

# ── System Preparation ───────────────────────────────────────────────────────
prepare_system() {
    info "Updating system packages and installing dependencies..."
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        apt-get update -y
        apt-get install -y curl wget unzip openssl uuid-runtime 2>/dev/null || true
    elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y curl wget unzip openssl uuid-runtime 2>/dev/null || true
    elif [[ "$OS_ID" == "arch" ]]; then
        pacman -Sy --noconfirm curl wget unzip openssl 2>/dev/null || true
    else
        apt-get update -y 2>/dev/null || true
        apt-get install -y curl wget unzip openssl 2>/dev/null || true
    fi

    # Enable BBR congestion control
    info "Enabling BBR congestion control..."
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        if ! grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        fi
        sysctl -p /etc/sysctl.conf 2>/dev/null || true
        info "BBR enabled."
    else
        info "BBR already enabled."
    fi

    # UDP buffer optimization
    if ! grep -q "rmem_max=16777216" /etc/sysctl.conf 2>/dev/null; then
        info "Optimizing UDP buffer sizes..."
        cat >> /etc/sysctl.conf <<EOF
# Tommy v${TOMMY_VER} - UDP buffer optimization
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.core.netdev_max_backlog=65536
net.ipv4.udp_mem=1048576 2097152 4194304
# Tommy v${TOMMY_VER} - IP forwarding
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
        sysctl -p /etc/sysctl.conf 2>/dev/null || true
        info "UDP buffers and IP forwarding configured."
    else
        info "UDP buffers already optimized."
    fi

    # Create Tommy directories
    mkdir -p "${TOMMY_DIR}"
    chmod 700 "${TOMMY_DIR}"
    chown root:root "${TOMMY_DIR}"
    mkdir -p "${TOMMY_LOG}"

    # Run security hardening
    harden_security
}

# ── Security Hardening ───────────────────────────────────────────────────────
harden_security() {
    info "Applying security hardening..."

    # 1. UFW: deny incoming by default, allow SSH
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

    # 3. Kernel hardening via sysctl
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

    # 5. Enable automatic security updates (Debian/Ubuntu)
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        if ! command -v unattended-upgrade &>/dev/null; then
            apt-get install -y unattended-upgrades 2>/dev/null || true
        fi
        if command -v unattended-upgrade &>/dev/null; then
            dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true
        fi
    fi

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
    info "Installing Xray-core..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>/dev/null || true
    if ! command -v xray &>/dev/null; then
        error "Xray installation failed. Cannot continue."
    fi
    info "Xray installed: $(xray version 2>/dev/null | head -1)"
    # Stop default xray service - we use tommy-prefixed services
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
#  CREATE TUNNEL (Port Forwarding - x-ui External Proxy Model)
# ══════════════════════════════════════════════════════════════════════════════
create_tunnel() {
    echo ""
    info "================================================================"
    info "  Tommy v${TOMMY_VER} - Create Port Forwarding Tunnel"
    info "  (x-ui External Proxy Model)"
    info "================================================================"
    echo ""

    # Step 1: Tunnel name
    read -rp "Enter a name for this tunnel (e.g. tunnel1): " TUNNEL_NAME
    TUNNEL_NAME="${TUNNEL_NAME:-tunnel1}"
    # Sanitize name: only alphanumeric and dashes
    TUNNEL_NAME=$(echo "$TUNNEL_NAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
    [[ -z "$TUNNEL_NAME" ]] && error "Tunnel name cannot be empty."

    # Check if tunnel already exists
    local SVC_NAME="tommy-${TUNNEL_NAME}"
    if systemctl is-active --quiet "$SVC_NAME" 2>/dev/null || [[ -f "/etc/systemd/system/${SVC_NAME}.service" ]]; then
        error "A tunnel named '${TUNNEL_NAME}' already exists. Choose a different name or delete it first."
    fi

    # Step 2: Tunnel port
    read -rp "Enter the tunnel port (same port will be used on Iranian server) [443]: " TUNNEL_PORT
    TUNNEL_PORT="${TUNNEL_PORT:-443}"

    # Step 3: Speed level
    echo ""
    info "Select SPEED level:"
    echo "  1) Low       - 50 mbps"
    echo "  2) Medium    - 200 mbps"
    echo "  3) High      - 500 mbps"
    echo "  4) Maximum   - 1000 mbps"
    read -rp "Select speed [1-4, default=3]: " SPEED_LEVEL
    SPEED_LEVEL="${SPEED_LEVEL:-3}"

    # Step 4: Security level
    echo ""
    info "Select SECURITY level:"
    echo "  1) Standard  - VMess + AES-128-GCM"
    echo "  2) Enhanced  - VLESS + TLS"
    echo "  3) Maximum   - VLESS + Reality"
    read -rp "Select security [1-3, default=3]: " SECURITY_LEVEL
    SECURITY_LEVEL="${SECURITY_LEVEL:-3}"

    # Step 5: Install Xray
    install_xray

    # Step 6: Generate credentials
    local TUNNEL_UUID=$(generate_uuid)

    # Step 7: Configure based on security level
    local PRIVATE_KEY="" PUBLIC_KEY="" SHORT_ID="" SNI="" FP="" REALITY_DEST=""
    local SEC_LABEL="" XRAY_CONFIG_DIR="${TOMMY_DIR}/${TUNNEL_NAME}"

    mkdir -p "$XRAY_CONFIG_DIR"
    chmod 700 "$XRAY_CONFIG_DIR"

    if [[ "$SECURITY_LEVEL" == "1" ]]; then
        SEC_LABEL="VMess+AES"
        _create_vmess_server "$XRAY_CONFIG_DIR" "$TUNNEL_UUID" "$TUNNEL_PORT" "$SPEED_LEVEL"
    elif [[ "$SECURITY_LEVEL" == "2" ]]; then
        SEC_LABEL="VLESS+TLS"
        _create_vless_tls_server "$XRAY_CONFIG_DIR" "$TUNNEL_UUID" "$TUNNEL_PORT" "$SPEED_LEVEL"
    else
        SEC_LABEL="VLESS+Reality"
        # Generate Reality keys
        X25519_OUTPUT=$(xray x25519)
        PRIVATE_KEY=$(echo "$X25519_OUTPUT" | grep "Private key" | awk '{print $3}')
        PUBLIC_KEY=$(echo "$X25519_OUTPUT" | grep "Public key" | awk '{print $3}')
        SHORT_ID=$(openssl rand -hex 8)

        echo ""
        info "Choose SNI/dest (major website with TLS 1.3 & H2)."
        info "  Recommended: www.microsoft.com, www.amazon.com, www.apple.com, dl.google.com"
        read -rp "Enter SNI [www.microsoft.com]: " REALITY_DEST
        REALITY_DEST="${REALITY_DEST:-www.microsoft.com}"
        SNI="$REALITY_DEST"
        FP="chrome"

        _create_vless_reality_server "$XRAY_CONFIG_DIR" "$TUNNEL_UUID" "$TUNNEL_PORT" "$SPEED_LEVEL" "$PRIVATE_KEY" "$SHORT_ID" "$REALITY_DEST"
    fi

    # Step 8: Create systemd service
    info "Creating tunnel service: ${SVC_NAME}..."
    cat > "/etc/systemd/system/${SVC_NAME}.service" <<SVCEOF
[Unit]
Description=Tommy Tunnel - ${TUNNEL_NAME} (${SEC_LABEL})
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
    open_firewall "$TUNNEL_PORT" tcp
    systemctl enable "$SVC_NAME"
    systemctl restart "$SVC_NAME"
    sleep 2

    if systemctl is-active --quiet "$SVC_NAME"; then
        info "Tunnel '${TUNNEL_NAME}' is RUNNING on port ${TUNNEL_PORT}!"
    else
        warn "Tunnel '${TUNNEL_NAME}' may have failed. Check: journalctl -u ${SVC_NAME} -n 30"
    fi

    # Step 9: Save tunnel info
    local SPEED_LABEL=""
    case "$SPEED_LEVEL" in
        1) SPEED_LABEL="50 mbps" ;;
        2) SPEED_LABEL="200 mbps" ;;
        3) SPEED_LABEL="500 mbps" ;;
        4) SPEED_LABEL="1000 mbps" ;;
        *) SPEED_LABEL="Unknown" ;;
    esac

    # Save internal tunnel record
    cat > "${XRAY_CONFIG_DIR}/tunnel-info.txt" <<IEOF
TUNNEL_NAME=${TUNNEL_NAME}
TUNNEL_PORT=${TUNNEL_PORT}
SECURITY_LEVEL=${SECURITY_LEVEL}
SEC_LABEL=${SEC_LABEL}
SPEED_LEVEL=${SPEED_LEVEL}
SPEED_LABEL=${SPEED_LABEL}
TUNNEL_UUID=${TUNNEL_UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SNI=${SNI}
FINGERPRINT=${FP}
REALITY_DEST=${REALITY_DEST}
SERVER_IP=${SERVER_IP}
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
IEOF
    chmod 600 "${XRAY_CONFIG_DIR}/tunnel-info.txt"

    # Save client info file for sharing with Iranian server
    cat > "/root/tommy-${TUNNEL_NAME}-client-info.txt" <<CEOF
================================================================
  Tommy v${TOMMY_VER} - Port Forwarding Tunnel - Client Info
  Give this information to the Iranian server admin.
================================================================
  Server IP:       ${SERVER_IP}
  Tunnel Port:     ${TUNNEL_PORT}
  Security Level:  ${SEC_LABEL}
  Speed Level:     ${SPEED_LABEL}

  --- Authentication Key (PRIVATE KEY) ---
  UUID / Key:      ${TUNNEL_UUID}
IEOF

    if [[ "$SECURITY_LEVEL" == "3" ]]; then
        cat >> "/root/tommy-${TUNNEL_NAME}-client-info.txt" <<CEOF

  --- VLESS + Reality Extra Parameters ---
  Public Key:      ${PUBLIC_KEY}
  Short ID:        ${SHORT_ID}
  SNI:             ${SNI}
  Fingerprint:     ${FP}
CEOF
    fi

    cat >> "/root/tommy-${TUNNEL_NAME}-client-info.txt" <<CEOF
================================================================
  On the Iranian server, run: tommy-client-iran.sh
  Choose option 1 (Create Tunnel)
  Enter the above information exactly as shown.
================================================================
CEOF
    chmod 600 "/root/tommy-${TUNNEL_NAME}-client-info.txt"

    # Step 10: Display summary
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Tommy v${TOMMY_VER} - Tunnel Created Successfully!                ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Name:     ${TUNNEL_NAME}$(printf '%*s' $((44 - ${#TUNNEL_NAME})) '')║${NC}"
    echo -e "${CYAN}║  Port:     ${TUNNEL_PORT}$(printf '%*s' $((44 - ${#TUNNEL_PORT})) '')║${NC}"
    echo -e "${CYAN}║  Security: ${SEC_LABEL}$(printf '%*s' $((44 - ${#SEC_LABEL})) '')║${NC}"
    echo -e "${CYAN}║  Speed:    ${SPEED_LABEL}$(printf '%*s' $((44 - ${#SPEED_LABEL})) '')║${NC}"
    echo -e "${CYAN}║  Service:  ${SVC_NAME}$(printf '%*s' $((44 - ${#SVC_NAME})) '')║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  AUTH KEY (give to Iranian server):                         ║${NC}"
    echo -e "${YELLOW}║  ${TUNNEL_UUID}$(printf '%*s' $((44 - ${#TUNNEL_UUID})) '')║${NC}"
    if [[ "$SECURITY_LEVEL" == "3" ]]; then
    echo -e "${CYAN}║  Public Key:  ${PUBLIC_KEY}$(printf '%*s' $((30 - ${#PUBLIC_KEY})) '')║${NC}"
    echo -e "${CYAN}║  Short ID:    ${SHORT_ID}$(printf '%*s' $((30 - ${#SHORT_ID})) '')║${NC}"
    echo -e "${CYAN}║  SNI:         ${SNI}$(printf '%*s' $((30 - ${#SNI})) '')║${NC}"
    fi
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Client info saved to:                                     ║${NC}"
    echo -e "${CYAN}║  /root/tommy-${TUNNEL_NAME}-client-info.txt$(printf '%*s' $((19 - ${#TUNNEL_NAME})) '')║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    info "IMPORTANT: Copy the AUTH KEY and parameters above to the Iranian server."
}

# ── VMess Server (Security Level 1: Standard) ───────────────────────────────
_create_vmess_server() {
    local CONFIG_DIR="$1" UUID="$2" PORT="$3" SPEED="$4"
    info "Configuring VMess + AES-128-GCM tunnel server..."

    local STREAM_RECV=8388608
    local CONN_RECV=20971520
    case "$SPEED" in
        1) STREAM_RECV=2097152;  CONN_RECV=4194304 ;;
        2) STREAM_RECV=4194304;  CONN_RECV=8388608 ;;
        3) STREAM_RECV=8388608;  CONN_RECV=20971520 ;;
        4) STREAM_RECV=16777216; CONN_RECV=33554432 ;;
    esac

    cat > "${CONFIG_DIR}/config.json" <<XEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${PORT},
    "protocol": "vmess",
    "settings": {
      "clients": [{ "id": "${UUID}", "alterId": 0 }],
      "disableInsecureEncryption": true
    },
    "streamSettings": {
      "network": "tcp",
      "security": "none",
      "sockopt": {
        "tcpFastOpen": true,
        "tcpKeepAliveInterval": 30
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "protocol": "blackhole", "settings": {} }
  ]
}
XEOF
    chmod 600 "${CONFIG_DIR}/config.json"
    info "VMess server configured on port ${PORT}."
}

# ── VLESS + TLS Server (Security Level 2: Enhanced) ─────────────────────────
_create_vless_tls_server() {
    local CONFIG_DIR="$1" UUID="$2" PORT="$3" SPEED="$4"
    info "Configuring VLESS + TLS tunnel server..."

    # Generate self-signed cert
    local CERT_DIR="${CONFIG_DIR}/certs"
    mkdir -p "$CERT_DIR"
    openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/server.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${CERT_DIR}/server.key" \
        -out "${CERT_DIR}/server.crt" -subj "/CN=bing.com" 2>/dev/null

    local STREAM_RECV=8388608
    local CONN_RECV=20971520
    case "$SPEED" in
        1) STREAM_RECV=2097152;  CONN_RECV=4194304 ;;
        2) STREAM_RECV=4194304;  CONN_RECV=8388608 ;;
        3) STREAM_RECV=8388608;  CONN_RECV=20971520 ;;
        4) STREAM_RECV=16777216; CONN_RECV=33554432 ;;
    esac

    cat > "${CONFIG_DIR}/config.json" <<XEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${UUID}", "flow": "" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "${CERT_DIR}/server.crt",
          "keyFile": "${CERT_DIR}/server.key"
        }]
      },
      "sockopt": {
        "tcpFastOpen": true,
        "tcpKeepAliveInterval": 30
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "protocol": "blackhole", "settings": {} }
  ]
}
XEOF
    chmod 600 "${CONFIG_DIR}/config.json"
    info "VLESS + TLS server configured on port ${PORT}."
}

# ── VLESS + Reality Server (Security Level 3: Maximum) ──────────────────────
_create_vless_reality_server() {
    local CONFIG_DIR="$1" UUID="$2" PORT="$3" SPEED="$4" PRIV_KEY="$5" SHORT_ID="$6" DEST="$7"
    info "Configuring VLESS + Reality tunnel server (Maximum Security)..."

    cat > "${CONFIG_DIR}/config.json" <<XEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${DEST}:443",
        "xver": 0,
        "serverNames": ["${DEST}"],
        "privateKey": "${PRIV_KEY}",
        "shortIds": ["${SHORT_ID}", ""]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "protocol": "blackhole", "settings": {} }
  ]
}
XEOF
    chmod 600 "${CONFIG_DIR}/config.json"
    info "VLESS + Reality server configured on port ${PORT}."
    info "  Private Key: ${PRIV_KEY}"
    info "  Public Key:  $(echo "$PRIV_KEY" | wg pubkey 2>/dev/null || echo 'see client-info')"
    info "  Short ID:    ${SHORT_ID}"
    info "  SNI:         ${DEST}"
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
        echo -e "  ${GREEN}Port:${NC}      ${TUNNEL_PORT}"
        echo -e "  ${GREEN}Security:${NC}  ${SEC_LABEL}"
        echo -e "  ${GREEN}Speed:${NC}     ${SPEED_LABEL}"
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

    # Remove client info file
    rm -f "/root/tommy-${DEL_NAME}-client-info.txt"

    # Try to close firewall port (read from tunnel-info if still available)
    # Since we deleted the dir, we'll just inform the user
    info "Tunnel '${DEL_NAME}' has been DELETED."
    warn "If you want to close the firewall port, do it manually or re-run and choose a different port."
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
        echo -e "${CYAN}║  8) Back to main menu                                       ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -rp "Select [1-8]: " SM_CHOICE

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
                return
                ;;
            *)
                warn "Invalid choice."
                ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════════════════════
#  SHOW CREDENTIALS
# ══════════════════════════════════════════════════════════════════════════════
show_credentials() {
    echo ""
    list_tunnels

    read -rp "Enter tunnel name to show credentials: " SHOW_NAME
    SHOW_NAME=$(echo "$SHOW_NAME" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')
    local CLIENT_FILE="/root/tommy-${SHOW_NAME}-client-info.txt"

    if [[ -f "$CLIENT_FILE" ]]; then
        echo ""
        cat "$CLIENT_FILE"
    else
        warn "Client info file not found for '${SHOW_NAME}'."
    fi
    echo ""
}

# ── Main Menu ────────────────────────────────────────────────────────────────
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
    echo -e "${CYAN}║    Port Forwarding Tunnel v${TOMMY_VER} - Foreign Server           ║${NC}"
    echo -e "${CYAN}║    Author: hamb4                                               ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║                                                                ║${NC}"
    echo -e "${CYAN}║  1)  Create Tunnel       (New port-forwarding tunnel)         ║${NC}"
    echo -e "${CYAN}║  2)  Service Manager     (Start/Stop/Restart/Delete tunnels)  ║${NC}"
    echo -e "${CYAN}║  3)  List Tunnels        (View all active tunnels)            ║${NC}"
    echo -e "${CYAN}║  4)  Show Credentials    (Display key for Iranian server)      ║${NC}"
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
        4) show_credentials ;;
        5) prepare_system ;;
        0) exit 0 ;;
        *) warn "Invalid choice." ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
#  ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════════
main() {
    check_root
    detect_os
    get_server_ip

    while true; do
        show_menu
    done
}

main "$@"
