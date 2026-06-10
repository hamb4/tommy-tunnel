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
#  Description:    Secure Tunnel Setup - Foreign Server Side
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
#    8) Recommended Combo      (VLESS + Hysteria2 + SS)
#    9) Port Forwarding        (External Proxy - Authenticated Tunnel)
#
#  USAGE:
#    chmod +x tommy-server-setup.sh
#    sudo ./tommy-server-setup.sh
#===============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

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
generate_port() { shuf -i 10000-60000 -n 1; }

# ── Firewall Helper (defined ONCE, used by all protocol setups) ───────────────
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

# ── Global State ──────────────────────────────────────────────────────────────
SERVER_IP=""
ACTIVE_PROTOCOLS=()

# ── Get Server IP ─────────────────────────────────────────────────────────────
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

# ── Menu ──────────────────────────────────────────────────────────────────────
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
    echo -e "${CYAN}║          Secure Tunnel Setup v3.0 - Foreign Server              ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║                                                                  ║${NC}"
    echo -e "${CYAN}║  1)  Xray VLESS + Reality   (Best stealth, TCP-based)           ║${NC}"
    echo -e "${CYAN}║  2)  Hysteria2              (Best speed, UDP/QUIC-based)        ║${NC}"
    echo -e "${CYAN}║  3)  Shadowsocks-2022       (Battle-tested, simple & fast)      ║${NC}"
    echo -e "${CYAN}║  4)  TUIC                   (QUIC-based, low latency)           ║${NC}"
    echo -e "${CYAN}║  5)  WireGuard              (Kernel VPN, fastest throughput)    ║${NC}"
    echo -e "${CYAN}║  6)  Brook                  (Ultra-lightweight, zero-config)    ║${NC}"
    echo -e "${CYAN}║  7)  SSH Tunnel             (No extra software needed)          ║${NC}"
    echo -e "${CYAN}║  8)  Recommended Combo      (VLESS + Hysteria2 + SS)           ║${NC}"
    echo -e "${CYAN}║  9)  Port Forwarding        (External Proxy Auth. Tunnel)      ║${NC}"
    echo -e "${CYAN}║  0)  Exit                                                        ║${NC}"
    echo -e "${CYAN}║                                                                  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Enter protocol numbers separated by spaces (e.g. ${YELLOW}1 2 3${NC}):"
    read -rp "Select protocol(s): " PROTOCOL_INPUT

    if [[ "$PROTOCOL_INPUT" == "0" ]]; then exit 0; fi
    if [[ "$PROTOCOL_INPUT" == "8" ]]; then
        PROTOCOL_INPUT="1 2 3"
    fi

    SETUP_XRAY=false; SETUP_HYSTERIA=false; SETUP_SS=false
    SETUP_TUIC=false; SETUP_WG=false; SETUP_BROOK=false; SETUP_SSH=false
    SETUP_PF=false

    for choice in $PROTOCOL_INPUT; do
        case "$choice" in
            1) SETUP_XRAY=true ;;
            2) SETUP_HYSTERIA=true ;;
            3) SETUP_SS=true ;;
            4) SETUP_TUIC=true ;;
            5) SETUP_WG=true ;;
            6) SETUP_BROOK=true ;;
            7) SETUP_SSH=true ;;
            9) SETUP_PF=true ;;
            *) warn "Unknown choice: $choice, skipping" ;;
        esac
    done
}

# ── System Preparation ────────────────────────────────────────────────────────
prepare_system() {
    info "Updating system packages and installing dependencies..."
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        apt-get update -y
        apt-get install -y curl wget unzip openssl qrencode wireguard-tools \
            socat autossh sshpass netcat-openbsd uuid-runtime 2>/dev/null || true
    elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y curl wget unzip openssl qrencode wireguard-tools \
            socat autossh sshpass nmap-ncat uuid-runtime 2>/dev/null || true
    elif [[ "$OS_ID" == "arch" ]]; then
        pacman -Sy --noconfirm curl wget unzip openssl qrencode \
            wireguard-tools socat autossh sshpass gnu-netcat 2>/dev/null || true
    else
        apt-get update -y 2>/dev/null || true
        apt-get install -y curl wget unzip openssl qrencode socat autossh sshpass 2>/dev/null || true
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
        cat >> /etc/sysctl.conf <<'EOF'
# Tommy v3.0 - UDP buffer optimization
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.core.netdev_max_backlog=65536
net.ipv4.udp_mem=1048576 2097152 4194304
# Tommy v3.0 - IP forwarding (WireGuard / iptables)
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
        sysctl -p /etc/sysctl.conf 2>/dev/null || true
        info "UDP buffers and IP forwarding configured."
    else
        info "UDP buffers already optimized."
    fi

    # Run security hardening
    harden_security
}

# ── Security Hardening ────────────────────────────────────────────────────────
harden_security() {
    info "Applying security hardening..."

    # 1. UFW: deny incoming by default, allow SSH
    if command -v ufw &>/dev/null; then
        if ! ufw status 2>/dev/null | grep -q "active"; then
            info "Enabling UFW with deny-incoming default..."
            ufw --force enable 2>/dev/null || true
            ufw default deny incoming 2>/dev/null || true
            ufw default allow outgoing 2>/dev/null || true
            # Allow SSH before enabling to prevent lockout
            ufw allow ssh 2>/dev/null || true
            ufw allow 22/tcp 2>/dev/null || true
        fi
    fi

    # 2. SSH hardening
    if [[ -f /etc/ssh/sshd_config ]]; then
        info "Hardening SSH configuration..."

        # Disable password authentication for root
        if grep -q "^#*PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config 2>/dev/null || true
        elif ! grep -q "PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null; then
            echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
        fi

        # Disable root login with password (key-only)
        if grep -q "^#*PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config 2>/dev/null || true
        elif ! grep -q "PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null; then
            echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config
        fi

        # Set MaxAuthTries to 3
        if grep -q "^#*MaxAuthTries" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config 2>/dev/null || true
        elif ! grep -q "MaxAuthTries" /etc/ssh/sshd_config 2>/dev/null; then
            echo "MaxAuthTries 3" >> /etc/ssh/sshd_config
        fi

        # Disable empty passwords
        if grep -q "^#*PermitEmptyPasswords" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config 2>/dev/null || true
        elif ! grep -q "PermitEmptyPasswords" /etc/ssh/sshd_config 2>/dev/null; then
            echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config
        fi

        # Restart SSH to apply changes
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    fi

    # 3. Kernel hardening via sysctl
    info "Applying kernel security parameters..."
    local SYSCTL_SECURITY=/etc/sysctl.d/99-tommy-security.conf
    cat > "$SYSCTL_SECURITY" <<'EOF'
# Tommy v3.0 - Security Hardening
kernel.randomize_va_space=2
kernel.exec-shield=1
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

    # 5. Set strict permissions on /etc/tommy/
    if [[ -d /etc/tommy ]]; then
        chmod 700 /etc/tommy
        chown root:root /etc/tommy
    fi
    mkdir -p /etc/tommy
    chmod 700 /etc/tommy
    chown root:root /etc/tommy

    # 6. Enable process accounting if available
    if command -v accton &>/dev/null; then
        accton /var/log/accounting 2>/dev/null || true
        systemctl enable psacct 2>/dev/null || systemctl enable acct 2>/dev/null || true
    fi

    # 7. Enable automatic security updates (Debian/Ubuntu)
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        if ! command -v unattended-upgrade &>/dev/null; then
            apt-get install -y unattended-upgrades 2>/dev/null || true
        fi
        if command -v unattended-upgrade &>/dev/null; then
            dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true
        fi
    fi

    # 8. Warning if SSH still using password auth
    if [[ -f /etc/ssh/sshd_config ]]; then
        if grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config 2>/dev/null; then
            warn "SSH still allows password authentication!"
            warn "Consider setting up SSH keys and disabling password auth for better security."
        fi
    fi

    info "Security hardening applied."
}

# ══════════════════════════════════════════════════════════════════════════════
#  1. XRAY VLESS + REALITY
# ══════════════════════════════════════════════════════════════════════════════
setup_xray() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up Xray VLESS + Reality"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Install Xray
    if command -v xray &>/dev/null; then
        info "Xray already installed: $(xray version | head -1)"
    else
        info "Installing Xray-core..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>/dev/null || true
    fi

    if ! command -v xray &>/dev/null; then
        warn "Xray installation failed. Skipping VLESS+Reality."
        return
    fi

    # Generate credentials
    VLESS_UUID=$(generate_uuid)
    X25519_OUTPUT=$(xray x25519)
    PRIVATE_KEY=$(echo "$X25519_OUTPUT" | grep "Private key" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$X25519_OUTPUT" | grep "Public key" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8)

    info "UUID:        ${VLESS_UUID}"
    info "Private Key: ${PRIVATE_KEY}"
    info "Public Key:  ${PUBLIC_KEY}"
    info "Short ID:    ${SHORT_ID}"

    # Interactive setup
    echo ""
    info "Choose SNI/dest (major website with TLS 1.3 & H2)."
    info "  Recommended: www.microsoft.com, www.amazon.com, www.apple.com, dl.google.com"
    read -rp "Enter SNI [www.microsoft.com]: " REALITY_DEST
    REALITY_DEST="${REALITY_DEST:-www.microsoft.com}"

    read -rp "Enter port [443]: " XRAY_PORT
    XRAY_PORT="${XRAY_PORT:-443}"

    # Write Xray config
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<XRAYEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${XRAY_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${VLESS_UUID}", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${REALITY_DEST}:443",
        "xver": 0,
        "serverNames": ["${REALITY_DEST}"],
        "privateKey": "${PRIVATE_KEY}",
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
XRAYEOF

    # Create tommy-prefixed systemd service
    cat > /etc/systemd/system/tommy-xray.service <<SVCEOF
[Unit]
Description=Tommy - Xray VLESS+Reality Server
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
Environment=XRAY_V2RAY_VMESS=A

[Install]
WantedBy=multi-user.target
SVCEOF

    # Stop old xray service if running, switch to tommy-xray
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true

    systemctl daemon-reload
    open_firewall "$XRAY_PORT" tcp
    systemctl enable tommy-xray
    systemctl restart tommy-xray
    sleep 2

    if systemctl is-active --quiet tommy-xray; then
        info "Tommy-Xray running on port ${XRAY_PORT}!"
    else
        warn "Tommy-Xray may have failed. Check: journalctl -u tommy-xray -n 30"
    fi

    # Generate VLESS link
    VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DEST}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Tommy-VLESS-Reality"

    # Save client info
    cat > /root/xray-client-info.txt <<CEOF
================================================================
  Tommy v3.0 - Xray VLESS + Reality - Client Connection Info
================================================================
  Server IP:    ${SERVER_IP}
  Port:         ${XRAY_PORT}
  UUID:         ${VLESS_UUID}
  Flow:         xtls-rprx-vision
  SNI:          ${REALITY_DEST}
  Fingerprint:  chrome
  Public Key:   ${PUBLIC_KEY}
  Short ID:     ${SHORT_ID}
  Service:      tommy-xray
----------------------------------------------------------------
  VLESS Link:
  ${VLESS_LINK}
================================================================
CEOF

    echo ""
    echo -e "${GREEN}VLESS Link:${NC}"
    echo -e "${CYAN}${VLESS_LINK}${NC}"
    ACTIVE_PROTOCOLS+=("VLESS+Reality:${XRAY_PORT}/TCP")
}

# ══════════════════════════════════════════════════════════════════════════════
#  2. HYSTERIA2
# ══════════════════════════════════════════════════════════════════════════════
setup_hysteria() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up Hysteria2"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Install Hysteria2
    if ! command -v hysteria &>/dev/null; then
        info "Installing Hysteria2..."
        bash <(curl -fsSL https://get.hy2.sh/) 2>/dev/null || true
    fi

    if ! command -v hysteria &>/dev/null; then
        warn "Hysteria2 installation failed. Skipping."
        return
    fi

    info "Hysteria2 installed: $(hysteria version 2>/dev/null | head -1)"

    HY_PASSWORD=$(generate_password)
    read -rp "Enter Hysteria2 port [8443]: " HY_PORT
    HY_PORT="${HY_PORT:-8443}"

    # Generate self-signed cert
    CERT_DIR="/etc/tommy/hysteria"; mkdir -p "$CERT_DIR"
    openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/server.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${CERT_DIR}/server.key" \
        -out "${CERT_DIR}/server.crt" -subj "/CN=bing.com" 2>/dev/null

    read -rp "Enter masquerade URL [https://www.bing.com]: " HY_MASQ
    HY_MASQ="${HY_MASQ:-https://www.bing.com}"

    # Write Hysteria2 config
    mkdir -p /etc/hysteria
    cat > /etc/hysteria/config.yaml <<HYEOF
listen: 0.0.0.0:${HY_PORT}

tls:
  cert: ${CERT_DIR}/server.crt
  key: ${CERT_DIR}/server.key

auth:
  type: password
  password: ${HY_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${HY_MASQ}
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 60s
  maxIncomingStreams: 1024

bandwidth:
  up: 500 mbps
  down: 500 mbps

disableUDP: false
udpIdleTimeout: 120s

resolver:
  type: udp
  udp:
    addr: 8.8.4.4:53
    timeout: 4s

acl:
  inline:
    - reject(geoip:private, udp/443)

log:
  level: warn
  output: /var/log/tommy-hysteria.log
HYEOF

    # Create tommy-prefixed systemd service
    HY_BIN=$(command -v hysteria)
    cat > /etc/systemd/system/tommy-hysteria.service <<SVCEOF
[Unit]
Description=Tommy - Hysteria2 Server
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${HY_BIN} server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    # Stop old service if present
    systemctl stop hysteria-server 2>/dev/null || true
    systemctl disable hysteria-server 2>/dev/null || true
    systemctl stop hysteria 2>/dev/null || true
    systemctl disable hysteria 2>/dev/null || true

    systemctl daemon-reload
    open_firewall "$HY_PORT" udp
    systemctl enable tommy-hysteria
    systemctl restart tommy-hysteria
    sleep 2

    if systemctl is-active --quiet tommy-hysteria; then
        info "Tommy-Hysteria2 running on UDP port ${HY_PORT}!"
    else
        warn "Tommy-Hysteria2 may have failed. Check: journalctl -u tommy-hysteria -n 20"
    fi

    # Generate link
    HY_LINK="hysteria2://${HY_PASSWORD}@${SERVER_IP}:${HY_PORT}?insecure=1&sni=bing.com#Tommy-Hysteria2"

    # Save client info
    cat > /root/hysteria2-client-info.txt <<CEOF
================================================================
  Tommy v3.0 - Hysteria2 - Client Connection Info
================================================================
  Server IP:    ${SERVER_IP}
  Port:         ${HY_PORT} (UDP)
  Password:     ${HY_PASSWORD}
  SNI:          bing.com
  Insecure:     true
  Service:      tommy-hysteria
----------------------------------------------------------------
  Hysteria2 Link:
  ${HY_LINK}
================================================================
CEOF

    echo ""
    echo -e "${GREEN}Hysteria2 Link:${NC}"
    echo -e "${CYAN}${HY_LINK}${NC}"
    ACTIVE_PROTOCOLS+=("Hysteria2:${HY_PORT}/UDP")
}

# ══════════════════════════════════════════════════════════════════════════════
#  3. SHADOWSOCKS-2022 (sing-box with shadowsocks-rust fallback)
# ══════════════════════════════════════════════════════════════════════════════
setup_shadowsocks() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up Shadowsocks-2022 (via sing-box)"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Install sing-box
    if ! command -v sing-box &>/dev/null; then
        info "Installing sing-box..."
        bash -c "$(curl -fsSL https://sing-box.app/deb-install.sh)" 2>/dev/null || {
            # Manual fallback install
            local ARCH SARCH
            ARCH=$(uname -m)
            case "$ARCH" in
                x86_64)  SARCH="amd64" ;;
                aarch64) SARCH="arm64" ;;
                *)       SARCH="amd64" ;;
            esac
            curl -Lo /tmp/sing-box.deb \
                "https://github.com/SagerNet/sing-box/releases/latest/download/sing-box_${SARCH}.deb" 2>/dev/null || true
            if [[ -f /tmp/sing-box.deb ]]; then
                dpkg -i /tmp/sing-box.deb 2>/dev/null || apt-get install -f -y 2>/dev/null || true
            else
                curl -Lo /tmp/sing-box.rpm \
                    "https://github.com/SagerNet/sing-box/releases/latest/download/sing-box_${SARCH}.rpm" 2>/dev/null || true
                if [[ -f /tmp/sing-box.rpm ]]; then
                    rpm -i /tmp/sing-box.rpm 2>/dev/null || true
                fi
            fi
        }
    fi

    if ! command -v sing-box &>/dev/null; then
        warn "sing-box not available, falling back to shadowsocks-rust..."
        setup_shadowsocks_rust
        return
    fi

    info "sing-box installed: $(sing-box version | head -1)"

    SS_PASSWORD=$(generate_password)
    read -rp "Enter Shadowsocks port [8388]: " SS_PORT
    SS_PORT="${SS_PORT:-8388}"

    # Generate sing-box server config
    mkdir -p /etc/tommy/sing-box
    cat > /etc/tommy/sing-box/config.json <<SSEOF
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "shadowsocks",
    "listen": "0.0.0.0",
    "listen_port": ${SS_PORT},
    "method": "2022-blake3-aes-256-gcm",
    "password": "${SS_PASSWORD}"
  }],
  "outbounds": [
    { "type": "direct" }
  ]
}
SSEOF

    # Create tommy-prefixed systemd service
    cat > /etc/systemd/system/tommy-shadowsocks.service <<SVCEOF
[Unit]
Description=Tommy - Shadowsocks-2022 (sing-box)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/bin/sing-box run -c /etc/tommy/sing-box/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    # Stop old service if present
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true

    systemctl daemon-reload
    open_firewall "$SS_PORT" tcp
    open_firewall "$SS_PORT" udp
    systemctl enable tommy-shadowsocks
    systemctl restart tommy-shadowsocks
    sleep 2

    if systemctl is-active --quiet tommy-shadowsocks; then
        info "Tommy-Shadowsocks-2022 running on port ${SS_PORT}!"
    else
        warn "Tommy-Shadowsocks may have failed. Check: journalctl -u tommy-shadowsocks -n 20"
    fi

    # Generate SS link
    SS_LINK="ss://$(echo -n "2022-blake3-aes-256-gcm:${SS_PASSWORD}" | base64 -w0)@${SERVER_IP}:${SS_PORT}#Tommy-Shadowsocks2022"

    # Save client info
    cat > /root/shadowsocks-client-info.txt <<CEOF
================================================================
  Tommy v3.0 - Shadowsocks-2022 - Client Connection Info
================================================================
  Server IP:    ${SERVER_IP}
  Port:         ${SS_PORT}
  Method:       2022-blake3-aes-256-gcm
  Password:     ${SS_PASSWORD}
  Service:      tommy-shadowsocks
----------------------------------------------------------------
  SS Link:
  ${SS_LINK}

  sing-box client config:
  {
    "inbounds": [{
      "type": "socks",
      "listen": "127.0.0.1",
      "listen_port": 10808
    }, {
      "type": "http",
      "listen": "127.0.0.1",
      "listen_port": 10809
    }],
    "outbounds": [{
      "type": "shadowsocks",
      "server": "${SERVER_IP}",
      "server_port": ${SS_PORT},
      "method": "2022-blake3-aes-256-gcm",
      "password": "${SS_PASSWORD}"
    }]
  }
================================================================
CEOF

    echo ""
    echo -e "${GREEN}Shadowsocks Link:${NC}"
    echo -e "${CYAN}${SS_LINK}${NC}"
    ACTIVE_PROTOCOLS+=("Shadowsocks-2022:${SS_PORT}/TCP+UDP")
}

# Fallback: shadowsocks-rust
setup_shadowsocks_rust() {
    info "Installing shadowsocks-rust (fallback)..."
    local ARCH RARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  RARCH="x86_64-unknown-linux-gnu" ;;
        aarch64) RARCH="aarch64-unknown-linux-gnu" ;;
        *)       RARCH="x86_64-unknown-linux-gnu" ;;
    esac

    local SS_RUST_VERSION="1.21.0"
    curl -Lo /tmp/ss-rust.tar.xz \
        "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${SS_RUST_VERSION}/shadowsocks-v${SS_RUST_VERSION}.${RARCH}.tar.xz" \
        2>/dev/null || true
    if [[ -f /tmp/ss-rust.tar.xz ]]; then
        tar -xf /tmp/ss-rust.tar.xz -C /usr/local/bin/ ssserver 2>/dev/null || true
        chmod +x /usr/local/bin/ssserver 2>/dev/null || true
    fi

    if ! command -v ssserver &>/dev/null && [[ ! -x /usr/local/bin/ssserver ]]; then
        warn "shadowsocks-rust installation failed. Skipping."
        return
    fi

    SS_PASSWORD=$(generate_password)
    read -rp "Enter Shadowsocks port [8388]: " SS_PORT
    SS_PORT="${SS_PORT:-8388}"

    mkdir -p /etc/tommy/shadowsocks-rust
    cat > /etc/tommy/shadowsocks-rust/config.json <<SSEOF
{
    "server": "0.0.0.0",
    "server_port": ${SS_PORT},
    "password": "${SS_PASSWORD}",
    "method": "2022-blake3-aes-256-gcm",
    "mode": "tcp_and_udp",
    "fast_open": true
}
SSEOF

    cat > /etc/systemd/system/tommy-shadowsocks.service <<SVCEOF
[Unit]
Description=Tommy - Shadowsocks-Rust Server
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c /etc/tommy/shadowsocks-rust/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    open_firewall "$SS_PORT" tcp
    open_firewall "$SS_PORT" udp
    systemctl enable tommy-shadowsocks
    systemctl restart tommy-shadowsocks
    sleep 2

    SS_LINK="ss://$(echo -n "2022-blake3-aes-256-gcm:${SS_PASSWORD}" | base64 -w0)@${SERVER_IP}:${SS_PORT}#Tommy-SS2022"
    echo ""
    echo -e "${GREEN}Shadowsocks Link (rust):${NC}"
    echo -e "${CYAN}${SS_LINK}${NC}"
    ACTIVE_PROTOCOLS+=("Shadowsocks-2022:${SS_PORT}/TCP+UDP")
}

# ══════════════════════════════════════════════════════════════════════════════
#  4. TUIC v5
# ══════════════════════════════════════════════════════════════════════════════
setup_tuic() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up TUIC (v5)"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Install TUIC
    if ! command -v tuic-server &>/dev/null; then
        info "Installing TUIC..."
        local ARCH TARCH
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64)  TARCH="x86_64-unknown-linux-gnu" ;;
            aarch64) TARCH="aarch64-unknown-linux-gnu" ;;
            *)       TARCH="x86_64-unknown-linux-gnu" ;;
        esac
        curl -Lo /usr/local/bin/tuic-server \
            "https://github.com/EAimTY/tuic/releases/latest/download/tuic-server-${TARCH}" 2>/dev/null || true
        if [[ -f /usr/local/bin/tuic-server ]]; then
            chmod +x /usr/local/bin/tuic-server
        else
            warn "TUIC binary download failed. Skipping."
            return
        fi
    fi

    if ! command -v tuic-server &>/dev/null; then
        warn "TUIC installation failed. Skipping."
        return
    fi

    TUIC_PASSWORD=$(generate_password)
    TUIC_UUID=$(generate_uuid)
    read -rp "Enter TUIC port [8444]: " TUIC_PORT
    TUIC_PORT="${TUIC_PORT:-8444}"

    # Generate self-signed certs
    CERT_DIR="/etc/tommy/tuic"; mkdir -p "$CERT_DIR"
    openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/server.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${CERT_DIR}/server.key" \
        -out "${CERT_DIR}/server.crt" -subj "/CN=www.bing.com" 2>/dev/null

    # Write TUIC config
    cat > /etc/tommy/tuic/config.json <<TEOF
{
  "server": "[::]:${TUIC_PORT}",
  "users": {
    "${TUIC_UUID}": "${TUIC_PASSWORD}"
  },
  "certificates": [{
    "cert": "${CERT_DIR}/server.crt",
    "key": "${CERT_DIR}/server.key"
  }],
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "max_idle_time": 60000,
  "max_external_packet_size": 1500,
  "log_level": "warn"
}
TEOF

    # Create tommy-prefixed systemd service
    cat > /etc/systemd/system/tommy-tuic.service <<SVCEOF
[Unit]
Description=Tommy - TUIC v5 Server
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tuic-server -c /etc/tommy/tuic/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    # Stop old service if present
    systemctl stop tuic 2>/dev/null || true
    systemctl disable tuic 2>/dev/null || true

    systemctl daemon-reload
    open_firewall "$TUIC_PORT" udp
    systemctl enable tommy-tuic
    systemctl restart tommy-tuic
    sleep 2

    if systemctl is-active --quiet tommy-tuic; then
        info "Tommy-TUIC running on UDP port ${TUIC_PORT}!"
    else
        warn "Tommy-TUIC may have failed. Check: journalctl -u tommy-tuic -n 20"
    fi

    # Generate link
    TUIC_LINK="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${SERVER_IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&insecure=1&sni=www.bing.com#Tommy-TUIC"

    # Save client info
    cat > /root/tuic-client-info.txt <<CEOF
================================================================
  Tommy v3.0 - TUIC v5 - Client Connection Info
================================================================
  Server IP:    ${SERVER_IP}
  Port:         ${TUIC_PORT} (UDP)
  UUID:         ${TUIC_UUID}
  Password:     ${TUIC_PASSWORD}
  Congestion:   bbr
  ALPN:         h3
  Insecure:     true (self-signed)
  Service:      tommy-tuic
----------------------------------------------------------------
  TUIC Link:
  ${TUIC_LINK}
================================================================
CEOF

    echo ""
    echo -e "${GREEN}TUIC Link:${NC}"
    echo -e "${CYAN}${TUIC_LINK}${NC}"
    ACTIVE_PROTOCOLS+=("TUIC:${TUIC_PORT}/UDP")
}

# ══════════════════════════════════════════════════════════════════════════════
#  5. WIREGUARD
# ══════════════════════════════════════════════════════════════════════════════
setup_wireguard() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up WireGuard VPN"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Install WireGuard
    if ! command -v wg &>/dev/null; then
        info "Installing WireGuard..."
        if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
            apt-get install -y wireguard wireguard-tools 2>/dev/null \
                || apt-get install -y wireguard-dkms wireguard-tools 2>/dev/null || true
        elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
            yum install -y wireguard-tools 2>/dev/null || true
        elif [[ "$OS_ID" == "arch" ]]; then
            pacman -Sy --noconfirm wireguard-tools 2>/dev/null || true
        fi
    fi

    if ! command -v wg &>/dev/null; then
        warn "WireGuard installation failed. Skipping."
        return
    fi

    read -rp "Enter WireGuard port [51820]: " WG_PORT
    WG_PORT="${WG_PORT:-51820}"

    # Generate server keys
    SERVER_PRIVKEY=$(wg genkey)
    SERVER_PUBKEY=$(echo "$SERVER_PRIVKEY" | wg pubkey)

    # Generate client keys
    CLIENT_PRIVKEY=$(wg genkey)
    CLIENT_PUBKEY=$(echo "$CLIENT_PRIVKEY" | wg pubkey)

    # Tunnel IP range
    WG_SERVER_IP="10.66.66.1/24"
    WG_CLIENT_IP="10.66.66.2/24"

    # Detect main network interface
    MAIN_IF=$(ip route | grep default | awk '{print $5}' | head -1)
    MAIN_IF="${MAIN_IF:-eth0}"

    # Write server config
    mkdir -p /etc/wireguard
    cat > /etc/wireguard/wg0.conf <<WGEOF
[Interface]
PrivateKey = ${SERVER_PRIVKEY}
Address = ${WG_SERVER_IP}
ListenPort = ${WG_PORT}

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${MAIN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${MAIN_IF} -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBKEY}
AllowedIPs = 10.66.66.2/32
WGEOF

    # Create tommy-prefixed systemd service
    cat > /etc/systemd/system/tommy-wireguard.service <<SVCEOF
[Unit]
Description=Tommy - WireGuard VPN (wg0)
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/wg-quick up wg0
ExecStop=/usr/bin/wg-quick down wg0

[Install]
WantedBy=multi-user.target
SVCEOF

    # Stop old service if present
    wg-quick down wg0 2>/dev/null || true
    systemctl stop wg-quick@wg0 2>/dev/null || true
    systemctl disable wg-quick@wg0 2>/dev/null || true

    systemctl daemon-reload
    open_firewall "$WG_PORT" udp
    systemctl enable tommy-wireguard
    systemctl start tommy-wireguard
    sleep 2

    if wg show wg0 &>/dev/null; then
        info "Tommy-WireGuard running on UDP port ${WG_PORT}!"
    else
        warn "Tommy-WireGuard may have failed. Try: wg-quick up wg0"
    fi

    # Client config
    WG_CLIENT_CONF="[Interface]
PrivateKey = ${CLIENT_PRIVKEY}
Address = ${WG_CLIENT_IP}
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = ${SERVER_PUBKEY}
Endpoint = ${SERVER_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25"

    # Save client info
    cat > /root/wireguard-client-info.txt <<CEOF
================================================================
  Tommy v3.0 - WireGuard - Client Connection Info
================================================================
  Server IP:        ${SERVER_IP}
  Port:             ${WG_PORT} (UDP)
  Server Public:    ${SERVER_PUBKEY}
  Client Private:   ${CLIENT_PRIVKEY}
  Client Public:    ${CLIENT_PUBKEY}
  Client Tunnel IP: ${WG_CLIENT_IP}
  Main Interface:   ${MAIN_IF}
  Service:          tommy-wireguard
----------------------------------------------------------------
  Client Config (save as /etc/wireguard/wg0.conf on client):
${WG_CLIENT_CONF}
================================================================
CEOF

    # Generate QR code for mobile clients
    if command -v qrencode &>/dev/null; then
        echo ""
        info "WireGuard QR Code (scan with Android/iOS WireGuard app):"
        echo "$WG_CLIENT_CONF" | qrencode -t ANSIUTF8 2>/dev/null || true
    fi

    echo ""
    echo -e "${GREEN}WireGuard Client Config:${NC}"
    echo -e "${CYAN}${WG_CLIENT_CONF}${NC}"
    ACTIVE_PROTOCOLS+=("WireGuard:${WG_PORT}/UDP")
}

# ══════════════════════════════════════════════════════════════════════════════
#  6. BROOK
# ══════════════════════════════════════════════════════════════════════════════
setup_brook() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up Brook"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Install Brook
    if ! command -v brook &>/dev/null; then
        info "Installing Brook..."
        local ARCH BARCH
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64)  BARCH="amd64" ;;
            aarch64) BARCH="arm64" ;;
            *)       BARCH="amd64" ;;
        esac
        curl -Lo /tmp/brook \
            "https://github.com/txthinking/brook/releases/latest/download/brook_linux_${BARCH}" 2>/dev/null || true
        if [[ -f /tmp/brook ]]; then
            chmod +x /tmp/brook
            mv /tmp/brook /usr/local/bin/brook
        else
            warn "Brook download failed. Skipping."
            return
        fi
    fi

    BROOK_PASSWORD=$(generate_password)
    read -rp "Enter Brook port [9999]: " BROOK_PORT
    BROOK_PORT="${BROOK_PORT:-9999}"

    # Create tommy-prefixed systemd service
    cat > /etc/systemd/system/tommy-brook.service <<SVCEOF
[Unit]
Description=Tommy - Brook Server
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/brook server -l :${BROOK_PORT} -p ${BROOK_PASSWORD}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    # Stop old service if present
    systemctl stop brook 2>/dev/null || true
    systemctl disable brook 2>/dev/null || true

    systemctl daemon-reload
    open_firewall "$BROOK_PORT" tcp
    open_firewall "$BROOK_PORT" udp
    systemctl enable tommy-brook
    systemctl restart tommy-brook
    sleep 2

    if systemctl is-active --quiet tommy-brook; then
        info "Tommy-Brook running on port ${BROOK_PORT}!"
    else
        warn "Tommy-Brook may have failed. Check: journalctl -u tommy-brook -n 20"
    fi

    # Generate link
    BROOK_LINK="brook://${SERVER_IP}:${BROOK_PORT} ${BROOK_PASSWORD}"

    # Save client info
    cat > /root/brook-client-info.txt <<CEOF
================================================================
  Tommy v3.0 - Brook - Client Connection Info
================================================================
  Server IP:    ${SERVER_IP}
  Port:         ${BROOK_PORT}
  Password:     ${BROOK_PASSWORD}
  Service:      tommy-brook
----------------------------------------------------------------
  Brook Link:
  ${BROOK_LINK}

  Client command (on Iranian server):
  brook client -s ${SERVER_IP}:${BROOK_PORT} -p ${BROOK_PASSWORD} --socks5 127.0.0.1:10808 --http 127.0.0.1:10809
================================================================
CEOF

    echo ""
    echo -e "${GREEN}Brook connection:${NC}"
    echo -e "${CYAN}Server: ${SERVER_IP}:${BROOK_PORT}  Password: ${BROOK_PASSWORD}${NC}"
    ACTIVE_PROTOCOLS+=("Brook:${BROOK_PORT}/TCP+UDP")
}

# ══════════════════════════════════════════════════════════════════════════════
#  7. SSH TUNNEL
# ══════════════════════════════════════════════════════════════════════════════
setup_ssh_tunnel() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up SSH Tunnel"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Ensure SSH is running
    if ! systemctl is-active --quiet sshd 2>/dev/null && ! systemctl is-active --quiet ssh 2>/dev/null; then
        warn "SSH service not found. Installing..."
        if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
            apt-get install -y openssh-server 2>/dev/null || true
        elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
            yum install -y openssh-server 2>/dev/null || true
        fi
        systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null || true
        systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null || true
    fi

    # Create a dedicated tunnel user
    SSH_USER="tommy-tunnel"
    SSH_PASSWORD=$(generate_password | head -c 24)

    if id "$SSH_USER" &>/dev/null; then
        info "User ${SSH_USER} already exists, resetting password."
        echo "${SSH_USER}:${SSH_PASSWORD}" | chpasswd 2>/dev/null || true
    else
        useradd -m -s /bin/bash "$SSH_USER" 2>/dev/null || true
        echo "${SSH_USER}:${SSH_PASSWORD}" | chpasswd 2>/dev/null || true
        info "Created tunnel user: ${SSH_USER}"
    fi

    # Get SSH port
    SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    SSH_PORT="${SSH_PORT:-22}"

    # Configure SSH for tunneling
    # Allow password auth for the tunnel user
    if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
        sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
    fi
    # Ensure AllowTcpForwarding is enabled
    if ! grep -q "AllowTcpForwarding" /etc/ssh/sshd_config 2>/dev/null; then
        echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config
    else
        sed -i 's/^AllowTcpForwarding no/AllowTcpForwarding yes/' /etc/ssh/sshd_config 2>/dev/null || true
    fi
    # Ensure GatewayPorts for -R tunnels
    if ! grep -q "GatewayPorts" /etc/ssh/sshd_config 2>/dev/null; then
        echo "GatewayPorts clientspecified" >> /etc/ssh/sshd_config
    fi
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

    open_firewall "$SSH_PORT" tcp

    # Create a marker systemd service indicating SSH tunnel is configured
    cat > /etc/systemd/system/tommy-ssh-tunnel.service <<SVCEOF
[Unit]
Description=Tommy - SSH Tunnel Configuration (user: ${SSH_USER})
After=sshd.service ssh.service network.target
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
    systemctl enable tommy-ssh-tunnel 2>/dev/null || true

    info "SSH tunnel user: ${SSH_USER}"
    info "SSH tunnel password: ${SSH_PASSWORD}"

    # Save client info
    cat > /root/ssh-tunnel-client-info.txt <<CEOF
================================================================
  Tommy v3.0 - SSH Tunnel - Client Connection Info
================================================================
  Server IP:    ${SERVER_IP}
  SSH Port:     ${SSH_PORT}
  Username:     ${SSH_USER}
  Password:     ${SSH_PASSWORD}
  Service:      tommy-ssh-tunnel
----------------------------------------------------------------
  SOCKS5 Proxy command (on Iranian server):

  ssh -D 10808 -N -f -p ${SSH_PORT} ${SSH_USER}@${SERVER_IP}

  With key-based auth (more secure):
  1. Generate key:   ssh-keygen -t ed25519 -f ~/.ssh/tommy_tunnel_key
  2. Copy to server: ssh-copy-id -i ~/.ssh/tommy_tunnel_key.pub -p ${SSH_PORT} ${SSH_USER}@${SERVER_IP}
  3. Connect:        ssh -D 10808 -N -f -i ~/.ssh/tommy_tunnel_key -p ${SSH_PORT} ${SSH_USER}@${SERVER_IP}

  Using autossh (auto-reconnect):
  autossh -D 10808 -N -f -o "ServerAliveInterval=30" -o "ServerAliveCountMax=3" -p ${SSH_PORT} ${SSH_USER}@${SERVER_IP}
================================================================
CEOF

    echo ""
    echo -e "${GREEN}SSH Tunnel connection:${NC}"
    echo -e "  ${CYAN}ssh -D 10808 -N -f -p ${SSH_PORT} ${SSH_USER}@${SERVER_IP}${NC}"
    echo -e "  Password: ${CYAN}${SSH_PASSWORD}${NC}"
    ACTIVE_PROTOCOLS+=("SSH-Tunnel:${SSH_PORT}/TCP")
}

# ══════════════════════════════════════════════════════════════════════════════
#  9. PORT FORWARDING (External Proxy - Authenticated Tunnel)
# ══════════════════════════════════════════════════════════════════════════════
setup_port_forwarding() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  External Proxy Tunnel Setup"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    echo ""
    info "This creates an authenticated dedicated tunnel between"
    info "this foreign server and an Iranian server."
    info "Like x-ui's 'external proxy' feature."
    echo ""

    # Step 1: Choose tunnel port
    read -rp "Enter tunnel port [443]: " TUNNEL_PORT
    TUNNEL_PORT="${TUNNEL_PORT:-443}"

    # Step 2: Iranian server IP
    read -rp "Enter Iranian server IP address: " IRAN_IP
    if [[ -z "$IRAN_IP" ]]; then
        error "Iranian server IP is required"
    fi

    # Step 3: Speed selection
    echo ""
    echo -e "${CYAN}  Speed Level:${NC}"
    echo -e "  ${YELLOW}1)${NC} Low       - 50 mbps (limited bandwidth)"
    echo -e "  ${YELLOW}2)${NC} Medium    - 200 mbps (balanced)"
    echo -e "  ${YELLOW}3)${NC} High      - 500 mbps (fast)"
    echo -e "  ${YELLOW}4)${NC} Maximum   - 1000 mbps (unlimited)"
    read -rp "Select speed [1-4, default=3]: " SPEED_LEVEL
    SPEED_LEVEL="${SPEED_LEVEL:-3}"

    # Map speed level to buffer sizes
    case "$SPEED_LEVEL" in
        1) STREAM_RECV=2097152;  CONN_RECV=4194304;  BW_LIMIT="50 mbps" ;;
        2) STREAM_RECV=4194304;  CONN_RECV=8388608;  BW_LIMIT="200 mbps" ;;
        3) STREAM_RECV=8388608;  CONN_RECV=16777216; BW_LIMIT="500 mbps" ;;
        4) STREAM_RECV=16777216; CONN_RECV=33554432; BW_LIMIT="1000 mbps" ;;
        *) STREAM_RECV=8388608;  CONN_RECV=16777216; BW_LIMIT="500 mbps"; SPEED_LEVEL=3 ;;
    esac

    # Step 4: Security level
    echo ""
    echo -e "${CYAN}  Security Level:${NC}"
    echo -e "  ${YELLOW}1)${NC} Standard  - VMess + AES-128-GCM (good compatibility)"
    echo -e "  ${YELLOW}2)${NC} Enhanced  - VLESS + TLS (better stealth)"
    echo -e "  ${YELLOW}3)${NC} Maximum   - VLESS + Reality (best stealth, TLS 1.3 masquerade)"
    read -rp "Select security level [1-3, default=3]: " SECURITY_LEVEL
    SECURITY_LEVEL="${SECURITY_LEVEL:-3}"

    # Step 5: Generate private key (UUID)
    TUNNEL_UUID=$(generate_uuid)
    TUNNEL_PRIVATE_KEY="$TUNNEL_UUID"

    info "Generated Private Key (UUID): ${TUNNEL_PRIVATE_KEY}"

    # Step 6: Install Xray if not present
    if command -v xray &>/dev/null; then
        info "Xray already installed: $(xray version | head -1)"
    else
        info "Installing Xray-core for tunnel bridge..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>/dev/null || true
    fi

    if ! command -v xray &>/dev/null; then
        error "Xray installation failed. Cannot set up tunnel bridge."
    fi

    # Step 7: Configure based on security level
    SECURITY_LABEL=""
    case "$SECURITY_LEVEL" in
        1)
            SECURITY_LABEL="VMess+AES"
            _pf_vmess_server
            ;;
        2)
            SECURITY_LABEL="VLESS+TLS"
            _pf_vless_tls_server
            ;;
        3)
            SECURITY_LABEL="VLESS+Reality"
            _pf_vless_reality_server
            ;;
        *)
            SECURITY_LABEL="VLESS+Reality"
            SECURITY_LEVEL=3
            _pf_vless_reality_server
            ;;
    esac

    # Step 8: Create systemd service
    mkdir -p /etc/tommy/pf-tunnel
    cat > /etc/systemd/system/tommy-pf-tunnel.service <<SVCEOF
[Unit]
Description=Tommy - Authenticated Tunnel Bridge (Port ${TUNNEL_PORT})
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c /etc/tommy/pf-tunnel/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    # Step 9: Open firewall
    open_firewall "$TUNNEL_PORT" tcp

    # Step 10: Stop old service if present, then start new one
    systemctl stop tommy-pf-tunnel 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable tommy-pf-tunnel
    systemctl restart tommy-pf-tunnel
    sleep 2

    if systemctl is-active --quiet tommy-pf-tunnel; then
        info "Tommy-PF-Tunnel running on port ${TUNNEL_PORT}!"
    else
        warn "Tommy-PF-Tunnel may have failed. Check: journalctl -u tommy-pf-tunnel -n 30"
    fi

    # Step 11: Build additional info for display
    local ADDITIONAL_INFO=""
    if [[ "$SECURITY_LEVEL" == "3" ]]; then
        ADDITIONAL_INFO="  Reality SNI:    ${CYAN}${PF_REALITY_DEST}${NC}
  Public Key:     ${CYAN}${PF_PUBLIC_KEY}${NC}
  Short ID:       ${CYAN}${PF_SHORT_ID}${NC}"
    elif [[ "$SECURITY_LEVEL" == "2" ]]; then
        ADDITIONAL_INFO="  TLS SNI:        ${CYAN}bing.com${NC}"
    fi

    # Save connection info
    cat > /root/tommy-pf-tunnel-info.txt <<INFOEOF
================================================================
  Tommy v3.0 - Authenticated Tunnel - Foreign Server Side
================================================================
  Tunnel Port:     ${TUNNEL_PORT}
  Iranian IP:      ${IRAN_IP}
  Private Key:     ${TUNNEL_PRIVATE_KEY}
  Security Level:  ${SECURITY_LEVEL} (${SECURITY_LABEL})
  Speed Level:     ${SPEED_LEVEL} (${BW_LIMIT})
  Server IP:       ${SERVER_IP}
  Service:         tommy-pf-tunnel
INFOEOF

    if [[ "$SECURITY_LEVEL" == "3" ]]; then
        cat >> /root/tommy-pf-tunnel-info.txt <<INFOEOF
  Reality SNI:     ${PF_REALITY_DEST}
  Public Key:      ${PF_PUBLIC_KEY}
  Short ID:        ${PF_SHORT_ID}
INFOEOF
    fi

    cat >> /root/tommy-pf-tunnel-info.txt <<INFOEOF
----------------------------------------------------------------
  IRANIAN SERVER SETUP:
  Run tommy-client-iran.sh -> Option 8 (Port Forwarding)

  Enter these values on the Iranian server:
  - Foreign Server IP: ${SERVER_IP}
  - Tunnel Port:       ${TUNNEL_PORT}
  - Private Key:       ${TUNNEL_PRIVATE_KEY}
  - Security Level:    ${SECURITY_LEVEL}
  - Speed Level:       ${SPEED_LEVEL}
================================================================
INFOEOF

    # Display summary
    echo ""
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}  AUTHENTICATED TUNNEL - Foreign Server Side${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo -e "  Tunnel Port:     ${CYAN}${TUNNEL_PORT}${NC}"
    echo -e "  Iranian IP:      ${CYAN}${IRAN_IP}${NC}"
    echo -e "  Private Key:     ${CYAN}${TUNNEL_PRIVATE_KEY}${NC}"
    echo -e "  Security Level:  ${CYAN}${SECURITY_LEVEL} (${SECURITY_LABEL})${NC}"
    echo -e "  Speed Level:     ${CYAN}${SPEED_LEVEL} (${BW_LIMIT})${NC}"
    if [[ -n "$ADDITIONAL_INFO" ]]; then
        echo -e "$ADDITIONAL_INFO"
    fi
    echo ""
    echo -e "${YELLOW}  COPY the Private Key and use it on the Iranian server!${NC}"
    echo -e "${YELLOW}  Run tommy-client-iran.sh -> Option 8 (Port Forwarding)${NC}"
    echo ""

    ACTIVE_PROTOCOLS+=("PF-Tunnel:${TUNNEL_PORT}/${SECURITY_LABEL}")
}

# ── PF Sub-function: VMess + AES-128-GCM Server ──────────────────────────────
_pf_vmess_server() {
    info "Configuring VMess + AES-128-GCM tunnel bridge..."

    mkdir -p /etc/tommy/pf-tunnel

    cat > /etc/tommy/pf-tunnel/config.json <<PFEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${TUNNEL_PORT},
    "protocol": "vmess",
    "settings": {
      "clients": [{ "id": "${TUNNEL_UUID}", "alterId": 0 }],
      "default": "none",
      "allowedIps": ["${IRAN_IP}"]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "none"
    },
    "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
  }],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" },
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true,
          "tcpKeepAliveInterval": 30
        }
      }
    },
    { "protocol": "blackhole", "settings": {} }
  ],
  "policy": {
    "levels": {
      "0": {
        "streamRecvWindow": ${STREAM_RECV},
        "connRecvWindow": ${CONN_RECV}
      }
    },
    "system": {
      "statsInboundUplink": false,
      "statsInboundDownlink": false
    }
  }
}
PFEOF

    chmod 600 /etc/tommy/pf-tunnel/config.json
    info "VMess tunnel bridge configured on port ${TUNNEL_PORT}"
}

# ── PF Sub-function: VLESS + TLS Server ──────────────────────────────────────
_pf_vless_tls_server() {
    info "Configuring VLESS + TLS tunnel bridge..."

    # Generate self-signed certificate
    local CERT_DIR="/etc/tommy/pf-tunnel/certs"
    mkdir -p "$CERT_DIR"
    openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/server.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${CERT_DIR}/server.key" \
        -out "${CERT_DIR}/server.crt" -subj "/CN=bing.com" 2>/dev/null

    mkdir -p /etc/tommy/pf-tunnel

    cat > /etc/tommy/pf-tunnel/config.json <<PFEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${TUNNEL_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${TUNNEL_UUID}", "flow": "" }],
      "decryption": "none",
      "allowedIps": ["${IRAN_IP}"]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "${CERT_DIR}/server.crt",
          "keyFile": "${CERT_DIR}/server.key"
        }]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
  }],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" },
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true,
          "tcpKeepAliveInterval": 30
        }
      }
    },
    { "protocol": "blackhole", "settings": {} }
  ],
  "policy": {
    "levels": {
      "0": {
        "streamRecvWindow": ${STREAM_RECV},
        "connRecvWindow": ${CONN_RECV}
      }
    },
    "system": {
      "statsInboundUplink": false,
      "statsInboundDownlink": false
    }
  }
}
PFEOF

    chmod 600 /etc/tommy/pf-tunnel/config.json
    info "VLESS+TLS tunnel bridge configured on port ${TUNNEL_PORT}"
}

# ── PF Sub-function: VLESS + Reality Server ──────────────────────────────────
_pf_vless_reality_server() {
    info "Configuring VLESS + Reality tunnel bridge..."

    # Generate x25519 key pair
    local X25519_OUTPUT
    X25519_OUTPUT=$(xray x25519)
    PF_PRIVATE_KEY=$(echo "$X25519_OUTPUT" | grep "Private key" | awk '{print $3}')
    PF_PUBLIC_KEY=$(echo "$X25519_OUTPUT" | grep "Public key" | awk '{print $3}')

    # Generate short ID
    PF_SHORT_ID=$(openssl rand -hex 8)

    # Ask for SNI dest
    echo ""
    info "Choose SNI/dest for Reality (major website with TLS 1.3 & H2)."
    info "  Recommended: www.microsoft.com, www.amazon.com, www.apple.com, dl.google.com"
    read -rp "Enter SNI [www.microsoft.com]: " PF_REALITY_DEST
    PF_REALITY_DEST="${PF_REALITY_DEST:-www.microsoft.com}"

    mkdir -p /etc/tommy/pf-tunnel

    cat > /etc/tommy/pf-tunnel/config.json <<PFEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${TUNNEL_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${TUNNEL_UUID}", "flow": "xtls-rprx-vision" }],
      "decryption": "none",
      "allowedIps": ["${IRAN_IP}"]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${PF_REALITY_DEST}:443",
        "xver": 0,
        "serverNames": ["${PF_REALITY_DEST}"],
        "privateKey": "${PF_PRIVATE_KEY}",
        "shortIds": ["${PF_SHORT_ID}", ""]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
  }],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" },
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true,
          "tcpKeepAliveInterval": 30
        }
      }
    },
    { "protocol": "blackhole", "settings": {} }
  ],
  "policy": {
    "levels": {
      "0": {
        "streamRecvWindow": ${STREAM_RECV},
        "connRecvWindow": ${CONN_RECV}
      }
    },
    "system": {
      "statsInboundUplink": false,
      "statsInboundDownlink": false
    }
  }
}
PFEOF

    chmod 600 /etc/tommy/pf-tunnel/config.json
    info "VLESS+Reality tunnel bridge configured on port ${TUNNEL_PORT}"
}

# ── Summary ───────────────────────────────────────────────────────────────────
show_summary() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              TOMMY v3.0 - SETUP COMPLETE                     ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"

    for proto in "${ACTIVE_PROTOCOLS[@]}"; do
        local padding=$((30 - ${#proto}))
        [[ $padding -lt 1 ]] && padding=1
        echo -e "${CYAN}║  ${GREEN}*${NC} ${proto}$(printf '%*s' "$padding" '')${CYAN}║${NC}"
    done

    echo -e "${CYAN}║                                                              ║${NC}"
    echo -e "${CYAN}║  Credentials saved in /root/*-client-info.txt                ║${NC}"
    echo -e "${CYAN}║                                                              ║${NC}"
    echo -e "${CYAN}║  Manage services:                                            ║${NC}"
    echo -e "${CYAN}║    systemctl status tommy-<protocol>                         ║${NC}"
    echo -e "${CYAN}║    systemctl restart tommy-<protocol>                        ║${NC}"
    echo -e "${CYAN}║    journalctl -u tommy-<protocol> -f                         ║${NC}"
    echo -e "${CYAN}║                                                              ║${NC}"
    echo -e "${CYAN}║  Next: Run tommy-client-iran.sh on Iranian server            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

    echo ""
    info "Protocol Comparison:"
    echo ""
    echo "  +--------------------+------------+----------+------------------+"
    echo "  | Protocol           | Transport  | Stealth  | Speed            |"
    echo "  +--------------------+------------+----------+------------------+"
    echo "  | VLESS+Reality      | TCP        | *****    | ****             |"
    echo "  | Hysteria2          | UDP/QUIC   | ****     | *****            |"
    echo "  | Shadowsocks-2022   | TCP+UDP    | ***      | ****             |"
    echo "  | TUIC               | UDP/QUIC   | ***      | ****             |"
    echo "  | WireGuard          | UDP        | **       | ***** (kernel)   |"
    echo "  | Brook              | TCP+UDP    | ***      | ***              |"
    echo "  | SSH Tunnel         | TCP        | **       | **               |"
    echo "  +--------------------+------------+----------+------------------+"
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
    check_root
    detect_os
    get_server_ip
    show_menu
    prepare_system

    [[ "${SETUP_XRAY:-false}" == true ]]     && setup_xray
    [[ "${SETUP_HYSTERIA:-false}" == true ]] && setup_hysteria
    [[ "${SETUP_SS:-false}" == true ]]       && setup_shadowsocks
    [[ "${SETUP_TUIC:-false}" == true ]]     && setup_tuic
    [[ "${SETUP_WG:-false}" == true ]]       && setup_wireguard
    [[ "${SETUP_BROOK:-false}" == true ]]    && setup_brook
    [[ "${SETUP_SSH:-false}" == true ]]      && setup_ssh_tunnel
    [[ "${SETUP_PF:-false}" == true ]]       && setup_port_forwarding

    show_summary
}

main "$@"
