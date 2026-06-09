#!/usr/bin/env bash
#===============================================================================
#  Tommy Server Setup Script v2.0
#  Connects an Iranian server to a foreign (outside) server
#
#  Protocols:
#    1) Xray VLESS + Reality   (Best stealth, TCP-based)
#    2) Hysteria2              (Best speed, UDP/QUIC-based)
#    3) Shadowsocks-2022       (Battle-tested, simple)
#    4) TUIC                   (QUIC-based, low latency)
#    5) WireGuard              (Kernel-level VPN, fastest raw throughput)
#    6) Brook                  (Ultra-lightweight, simple)
#    7) SSH Tunnel             (No extra software, always available)
#
#  USAGE:
#    Run on the FOREIGN (outside-Iran) server as root:
#      chmod +x tommy-server-setup.sh
#      sudo ./tommy-server-setup.sh
#===============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── Helper Functions ──────────────────────────────────────────────────────────
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

check_root() { [[ $EUID -eq 0 ]] || error "This script must be run as root."; }

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
    else
        OS_ID="unknown"
    fi
    info "Detected OS: ${OS_ID} ${OS_VERSION}"
}

generate_uuid() { uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid; }
generate_password() { openssl rand -base64 32; }
generate_port() { shuf -i 10000-60000 -n 1; }

SERVER_IP=""
ACTIVE_PROTOCOLS=()

# ── Get Server IP ─────────────────────────────────────────────────────────────
get_server_ip() {
    info "Detecting server public IP..."
    SERVER_IP=$(curl -s4 https://ifconfig.me 2>/dev/null || curl -s4 https://api.ipify.org 2>/dev/null || curl -s4 https://ip.sb 2>/dev/null)
    if [[ -z "$SERVER_IP" ]]; then
        read -rp "Could not auto-detect IP. Enter your server's public IP: " SERVER_IP
    fi
    info "Server IP: ${SERVER_IP}"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
show_menu() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           Tommy Server Setup - Foreign Server Side             ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║                                                                  ║${NC}"
    echo -e "${CYAN}║  1)  Xray VLESS + Reality   (Best stealth, TCP-based)           ║${NC}"
    echo -e "${CYAN}║  2)  Hysteria2              (Best speed, UDP/QUIC-based)        ║${NC}"
    echo -e "${CYAN}║  3)  Shadowsocks-2022       (Battle-tested, simple & fast)      ║${NC}"
    echo -e "${CYAN}║  4)  TUIC                   (QUIC-based, low latency)           ║${NC}"
    echo -e "${CYAN}║  5)  WireGuard              (Kernel VPN, fastest throughput)    ║${NC}"
    echo -e "${CYAN}║  6)  Brook                  (Ultra-lightweight, zero-config)    ║${NC}"
    echo -e "${CYAN}║  7)  SSH Tunnel             (No extra software needed)          ║${NC}"
    echo -e "${CYAN}║  8)  Install ALL            (Recommended: VLESS+Hysteria2+SS)   ║${NC}"
    echo -e "${CYAN}║  9)  Exit                                                        ║${NC}"
    echo -e "${CYAN}║                                                                  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Enter protocol numbers separated by spaces (e.g. ${YELLOW}1 2 3${NC}):"
    read -rp "Select protocol(s): " PROTOCOL_INPUT

    if [[ "$PROTOCOL_INPUT" == "9" ]]; then exit 0; fi
    if [[ "$PROTOCOL_INPUT" == "8" ]]; then
        PROTOCOL_INPUT="1 2 3"
    fi

    SETUP_XRAY=false; SETUP_HYSTERIA=false; SETUP_SS=false
    SETUP_TUIC=false; SETUP_WG=false; SETUP_BROOK=false; SETUP_SSH=false

    for choice in $PROTOCOL_INPUT; do
        case "$choice" in
            1) SETUP_XRAY=true ;;
            2) SETUP_HYSTERIA=true ;;
            3) SETUP_SS=true ;;
            4) SETUP_TUIC=true ;;
            5) SETUP_WG=true ;;
            6) SETUP_BROOK=true ;;
            7) SETUP_SSH=true ;;
            *) warn "Unknown choice: $choice, skipping" ;;
        esac
    done
}

# ── System Preparation ────────────────────────────────────────────────────────
prepare_system() {
    info "Updating system packages..."
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        apt-get update -y
        apt-get install -y curl wget unzip openssl qrencode netcat-openbsd wireguard-tools 2>/dev/null || true
    elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
        yum install -y curl wget unzip openssl qrencode nmap-ncat 2>/dev/null || true
    elif [[ "$OS_ID" == "arch" ]]; then
        pacman -Sy --noconfirm curl wget unzip openssl qrencode gnu-netcat 2>/dev/null || true
    else
        apt-get update -y && apt-get install -y curl wget unzip openssl 2>/dev/null || true
    fi

    # Enable BBR
    info "Enabling BBR congestion control..."
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p /etc/sysctl.conf 2>/dev/null || true
        info "BBR enabled."
    else
        info "BBR already enabled."
    fi

    # UDP buffer optimization
    if ! grep -q "rmem_max=16777216" /etc/sysctl.conf 2>/dev/null; then
        info "Optimizing UDP buffer sizes..."
        cat >> /etc/sysctl.conf <<'EOF'
# UDP buffer optimization
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.core.netdev_max_backlog=65536
net.ipv4.udp_mem=1048576 2097152 4194304
# WireGuard / IP forwarding
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
        sysctl -p /etc/sysctl.conf 2>/dev/null || true
    fi
}

# ── Firewall Helper ───────────────────────────────────────────────────────────
open_firewall() {
    local port=$1
    local proto=${2:-tcp}
    info "Opening ${proto^^} port ${port} in firewall..."
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    if command -v iptables &>/dev/null; then
        iptables -I INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || true
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  1. XRAY VLESS + REALITY
# ══════════════════════════════════════════════════════════════════════════════
setup_xray() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up Xray VLESS + Reality"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if command -v xray &>/dev/null; then
        info "Xray already installed: $(xray version | head -1)"
    else
        info "Installing Xray-core..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    VLESS_UUID=$(generate_uuid)
    X25519_OUTPUT=$(xray x25519)
    PRIVATE_KEY=$(echo "$X25519_OUTPUT" | grep "Private key" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$X25519_OUTPUT" | grep "Public key" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8)

    info "UUID:        ${VLESS_UUID}"
    info "Private Key: ${PRIVATE_KEY}"
    info "Public Key:  ${PUBLIC_KEY}"
    info "Short ID:    ${SHORT_ID}"

    echo ""
    info "Choose SNI/dest (major website with TLS 1.3 & H2)."
    info "  Recommended: www.microsoft.com, www.amazon.com, www.apple.com, dl.google.com"
    read -rp "Enter SNI [www.microsoft.com]: " REALITY_DEST
    REALITY_DEST="${REALITY_DEST:-www.microsoft.com}"

    read -rp "Enter port [443]: " XRAY_PORT
    XRAY_PORT="${XRAY_PORT:-443}"

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

    open_firewall "$XRAY_PORT" tcp
    systemctl enable xray; systemctl restart xray; sleep 2

    if systemctl is-active --quiet xray; then
        info "Xray running on port ${XRAY_PORT}!"
    else
        warn "Xray may have failed. Check: journalctl -u xray -n 30"
    fi

    VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DEST}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Tommy-VLESS-Reality"

    cat > /root/xray-client-info.txt <<CEOF
================================================================
  Xray VLESS + Reality - Client Connection Info
================================================================
  Server IP:    ${SERVER_IP}
  Port:         ${XRAY_PORT}
  UUID:         ${VLESS_UUID}
  Flow:         xtls-rprx-vision
  SNI:          ${REALITY_DEST}
  Fingerprint:  chrome
  Public Key:   ${PUBLIC_KEY}
  Short ID:     ${SHORT_ID}
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

    if ! command -v hysteria &>/dev/null; then
        info "Installing Hysteria2..."
        bash <(curl -fsSL https://get.hy2.sh/)
    fi

    HY_PASSWORD=$(generate_password)
    read -rp "Enter Hysteria2 port [8443]: " HY_PORT
    HY_PORT="${HY_PORT:-8443}"

    # Generate self-signed cert
    CERT_DIR="/etc/hysteria"; mkdir -p "$CERT_DIR"
    openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/server.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${CERT_DIR}/server.key" \
        -out "${CERT_DIR}/server.crt" -subj "/CN=bing.com" 2>/dev/null

    read -rp "Enter masquerade URL [https://www.bing.com]: " HY_MASQ
    HY_MASQ="${HY_MASQ:-https://www.bing.com}"

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
  output: /var/log/hysteria.log
HYEOF

    open_firewall "$HY_PORT" udp
    systemctl enable hysteria-server 2>/dev/null || true
    systemctl restart hysteria-server 2>/dev/null || systemctl restart hysteria 2>/dev/null || true
    sleep 2

    if systemctl is-active --quiet hysteria-server 2>/dev/null || systemctl is-active --quiet hysteria 2>/dev/null; then
        info "Hysteria2 running on UDP port ${HY_PORT}!"
    else
        warn "Hysteria2 may have failed. Check: journalctl -u hysteria-server -n 20"
    fi

    HY_LINK="hysteria2://${HY_PASSWORD}@${SERVER_IP}:${HY_PORT}?insecure=1&sni=bing.com#Tommy-Hysteria2"

    cat > /root/hysteria2-client-info.txt <<CEOF
================================================================
  Hysteria2 - Client Connection Info
================================================================
  Server IP:    ${SERVER_IP}
  Port:         ${HY_PORT} (UDP)
  Password:     ${HY_PASSWORD}
  SNI:          bing.com
  Insecure:     true
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
#  3. SHADOWSOCKS-2022 (sing-box)
# ══════════════════════════════════════════════════════════════════════════════
setup_shadowsocks() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up Shadowsocks-2022 (via sing-box)"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Install sing-box
    if ! command -v sing-box &>/dev/null; then
        info "Installing sing-box..."
        bash -c "$(curl -fsSL https://sing-box.app/deb-install.sh)" 2>/dev/null || {
            # Manual install
            ARCH=$(uname -m)
            case "$ARCH" in
                x86_64) SARCH="amd64" ;;
                aarch64) SARCH="arm64" ;;
                *) SARCH="amd64" ;;
            esac
            curl -Lo /tmp/sing-box.deb "https://github.com/SagerNet/sing-box/releases/latest/download/sing-box_${SARCH}.deb" 2>/dev/null || \
            curl -Lo /tmp/sing-box.deb "https://github.com/SagerNet/sing-box/releases/download/v1.10.0/sing-box_${SARCH}.deb" 2>/dev/null || true
            if [[ -f /tmp/sing-box.deb ]]; then
                dpkg -i /tmp/sing-box.deb 2>/dev/null || apt-get install -f -y 2>/dev/null || true
            else
                # Try yum/rpm
                curl -Lo /tmp/sing-box.rpm "https://github.com/SagerNet/sing-box/releases/latest/download/sing-box_${SARCH}.rpm" 2>/dev/null || true
                rpm -i /tmp/sing-box.rpm 2>/dev/null || true
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
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/config.json <<SSEOF
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

    # Create systemd service
    cat > /etc/systemd/system/sing-box.service <<SVCEOF
[Unit]
Description=sing-box (Shadowsocks-2022)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    open_firewall "$SS_PORT" tcp
    systemctl enable sing-box; systemctl restart sing-box; sleep 2

    if systemctl is-active --quiet sing-box; then
        info "Shadowsocks-2022 running on port ${SS_PORT}!"
    else
        warn "Shadowsocks may have failed. Check: journalctl -u sing-box -n 20"
    fi

    SS_LINK="ss://$(echo -n "2022-blake3-aes-256-gcm:${SS_PASSWORD}" | base64 -w0)@${SERVER_IP}:${SS_PORT}#Tommy-Shadowsocks2022"

    cat > /root/shadowsocks-client-info.txt <<CEOF
================================================================
  Shadowsocks-2022 - Client Connection Info
================================================================
  Server IP:    ${SERVER_IP}
  Port:         ${SS_PORT}
  Method:       2022-blake3-aes-256-gcm
  Password:     ${SS_PASSWORD}
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
    ACTIVE_PROTOCOLS+=("Shadowsocks-2022:${SS_PORT}/TCP")
}

# Fallback: shadowsocks-rust
setup_shadowsocks_rust() {
    info "Installing shadowsocks-rust..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) RARCH="x86_64-unknown-linux-gnu" ;;
        aarch64) RARCH="aarch64-unknown-linux-gnu" ;;
        *) RARCH="x86_64-unknown-linux-gnu" ;;
    esac
    curl -Lo /tmp/ss-rust.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/latest/download/shadowsocks-v-${RARCH}.tar.xz" 2>/dev/null || true
    if [[ -f /tmp/ss-rust.tar.xz ]]; then
        tar -xf /tmp/ss-rust.tar.xz -C /usr/local/bin/ ssserver 2>/dev/null || true
    fi

    SS_PASSWORD=$(generate_password)
    read -rp "Enter Shadowsocks port [8388]: " SS_PORT
    SS_PORT="${SS_PORT:-8388}"

    mkdir -p /etc/shadowsocks-rust
    cat > /etc/shadowsocks-rust/config.json <<SSEOF
{
    "server": "0.0.0.0",
    "server_port": ${SS_PORT},
    "password": "${SS_PASSWORD}",
    "method": "2022-blake3-aes-256-gcm",
    "mode": "tcp_and_udp",
    "fast_open": true
}
SSEOF

    cat > /etc/systemd/system/shadowsocks-rust.service <<SVCEOF
[Unit]
Description=Shadowsocks-Rust Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    open_firewall "$SS_PORT" tcp
    open_firewall "$SS_PORT" udp
    systemctl enable shadowsocks-rust; systemctl restart shadowsocks-rust; sleep 2

    SS_LINK="ss://$(echo -n "2022-blake3-aes-256-gcm:${SS_PASSWORD}" | base64 -w0)@${SERVER_IP}:${SS_PORT}#Tommy-SS2022"
    echo ""
    echo -e "${GREEN}Shadowsocks Link:${NC}"
    echo -e "${CYAN}${SS_LINK}${NC}"
    ACTIVE_PROTOCOLS+=("Shadowsocks-2022:${SS_PORT}/TCP+UDP")
}

# ══════════════════════════════════════════════════════════════════════════════
#  4. TUIC
# ══════════════════════════════════════════════════════════════════════════════
setup_tuic() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up TUIC (v5)"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Install TUIC
    if ! command -v tuic-server &>/dev/null; then
        info "Installing TUIC..."
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) TARCH="x86_64-unknown-linux-gnu" ;;
            aarch64) TARCH="aarch64-unknown-linux-gnu" ;;
            *) TARCH="x86_64-unknown-linux-gnu" ;;
        esac
        curl -Lo /tmp/tuic.tar.gz "https://github.com/EAimTY/tuic/releases/latest/download/tuic-server-${TARCH}" 2>/dev/null || true
        if [[ -f /tmp/tuic.tar.gz ]]; then
            chmod +x /tmp/tuic.tar.gz
            mv /tmp/tuic.tar.gz /usr/local/bin/tuic-server
        else
            # Try cargo install
            warn "Binary download failed. Trying cargo install..."
            command -v cargo &>/dev/null && cargo install tuic-server || warn "Could not install TUIC."
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
    CERT_DIR="/etc/tuic"; mkdir -p "$CERT_DIR"
    openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/server.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${CERT_DIR}/server.key" \
        -out "${CERT_DIR}/server.crt" -subj "/CN=www.bing.com" 2>/dev/null

    cat > /etc/tuic/config.json <<TEOF
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

    cat > /etc/systemd/system/tuic.service <<SVCEOF
[Unit]
Description=TUIC Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tuic-server -c /etc/tuic/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    open_firewall "$TUIC_PORT" udp
    systemctl enable tuic; systemctl restart tuic; sleep 2

    if systemctl is-active --quiet tuic; then
        info "TUIC running on UDP port ${TUIC_PORT}!"
    else
        warn "TUIC may have failed. Check: journalctl -u tuic -n 20"
    fi

    TUIC_LINK="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${SERVER_IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&insecure=1&sni=www.bing.com#Tommy-TUIC"

    cat > /root/tuic-client-info.txt <<CEOF
================================================================
  TUIC v5 - Client Connection Info
================================================================
  Server IP:    ${SERVER_IP}
  Port:         ${TUIC_PORT} (UDP)
  UUID:         ${TUIC_UUID}
  Password:     ${TUIC_PASSWORD}
  Congestion:   bbr
  ALPN:         h3
  Insecure:     true (self-signed)
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
            apt-get install -y wireguard 2>/dev/null || { apt-get install -y wireguard-dkms wireguard-tools 2>/dev/null; } || true
        elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" ]]; then
            yum install -y wireguard-tools 2>/dev/null || true
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

    # Choose a tunnel IP range
    WG_SERVER_IP="10.66.66.1/24"
    WG_CLIENT_IP="10.66.66.2/24"

    # Server config
    cat > /etc/wireguard/wg0.conf <<WGEOF
[Interface]
PrivateKey = ${SERVER_PRIVKEY}
Address = ${WG_SERVER_IP}
ListenPort = ${WG_PORT}

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBKEY}
AllowedIPs = 10.66.66.2/32
WGEOF

    # Fix PostUp/PostDown if main interface is not eth0
    MAIN_IF=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -n "$MAIN_IF" && "$MAIN_IF" != "eth0" ]]; then
        sed -i "s/eth0/${MAIN_IF}/g" /etc/wireguard/wg0.conf
    fi

    open_firewall "$WG_PORT" udp
    systemctl enable wg-quick@wg0; wg-quick up wg0 2>/dev/null || true
    sleep 2

    if wg show wg0 &>/dev/null; then
        info "WireGuard running on UDP port ${WG_PORT}!"
    else
        warn "WireGuard may have failed. Try: wg-quick up wg0"
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

    cat > /root/wireguard-client-info.txt <<CEOF
================================================================
  WireGuard - Client Connection Info
================================================================
  Server IP:        ${SERVER_IP}
  Port:             ${WG_PORT} (UDP)
  Server Public:    ${SERVER_PUBKEY}
  Client Private:   ${CLIENT_PRIVKEY}
  Client Public:    ${CLIENT_PUBKEY}
  Client Tunnel IP: ${WG_CLIENT_IP}
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

    if ! command -v brook &>/dev/null; then
        info "Installing Brook..."
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) BARCH="amd64" ;;
            aarch64) BARCH="arm64" ;;
            *) BARCH="amd64" ;;
        esac
        curl -Lo /tmp/brook "https://github.com/txthinking/brook/releases/latest/download/brook_linux_${BARCH}" 2>/dev/null || true
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

    cat > /etc/systemd/system/brook.service <<SVCEOF
[Unit]
Description=Brook Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/brook server -l :${BROOK_PORT} -p ${BROOK_PASSWORD}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    open_firewall "$BROOK_PORT" tcp
    open_firewall "$BROOK_PORT" udp
    systemctl enable brook; systemctl restart brook; sleep 2

    if systemctl is-active --quiet brook; then
        info "Brook running on port ${BROOK_PORT}!"
    else
        warn "Brook may have failed. Check: journalctl -u brook -n 20"
    fi

    BROOK_LINK="brook://${SERVER_IP}:${BROOK_PORT} ${BROOK_PASSWORD}"

    cat > /root/brook-client-info.txt <<CEOF
================================================================
  Brook - Client Connection Info
================================================================
  Server IP:    ${SERVER_IP}
  Port:         ${BROOK_PORT}
  Password:     ${BROOK_PASSWORD}
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
        apt-get install -y openssh-server 2>/dev/null || yum install -y openssh-server 2>/dev/null || true
        systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null || true
        systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null || true
    fi

    # Create a dedicated tunnel user
    SSH_USER="tunneluser"
    SSH_PASSWORD=$(generate_password | head -c 20)

    if id "$SSH_USER" &>/dev/null; then
        info "User ${SSH_USER} already exists."
    else
        useradd -m -s /bin/bash "$SSH_USER" 2>/dev/null || true
        echo "${SSH_USER}:${SSH_PASSWORD}" | chpasswd 2>/dev/null || true
        info "Created tunnel user: ${SSH_USER}"
    fi

    # Get SSH port
    SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    SSH_PORT="${SSH_PORT:-22}"

    # Allow password auth (needed for tunnel user)
    sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
    # Ensure AllowTcpForwarding is enabled
    grep -q "AllowTcpForwarding" /etc/ssh/sshd_config 2>/dev/null || echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

    open_firewall "$SSH_PORT" tcp

    info "SSH tunnel user: ${SSH_USER}"
    info "SSH tunnel password: ${SSH_PASSWORD}"

    cat > /root/ssh-tunnel-client-info.txt <<CEOF
================================================================
  SSH Tunnel - Client Connection Info
================================================================
  Server IP:    ${SERVER_IP}
  SSH Port:     ${SSH_PORT}
  Username:     ${SSH_USER}
  Password:     ${SSH_PASSWORD}
----------------------------------------------------------------
  SOCKS5 Proxy command (on Iranian server):

  ssh -D 10808 -N -f -p ${SSH_PORT} ${SSH_USER}@${SERVER_IP}

  With key-based auth (more secure):
  1. Generate key:   ssh-keygen -t ed25519 -f ~/.ssh/tunnel_key
  2. Copy to server: ssh-copy-id -i ~/.ssh/tunnel_key.pub -p ${SSH_PORT} ${SSH_USER}@${SERVER_IP}
  3. Connect:        ssh -D 10808 -N -f -i ~/.ssh/tunnel_key -p ${SSH_PORT} ${SSH_USER}@${SERVER_IP}

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

# ── Summary ───────────────────────────────────────────────────────────────────
show_summary() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                  SETUP COMPLETE                              ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"

    for proto in "${ACTIVE_PROTOCOLS[@]}"; do
        echo -e "${CYAN}║  ${GREEN}✅${NC} ${proto}$(printf '%*s' $((30 - ${#proto})) '')${CYAN}║${NC}"
    done

    echo -e "${CYAN}║                                                              ║${NC}"
    echo -e "${CYAN}║  Credentials saved in /root/*-client-info.txt                ║${NC}"
    echo -e "${CYAN}║                                                              ║${NC}"
    echo -e "${CYAN}║  Next: Run tommy-client-iran.sh on Iranian server          ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

    echo ""
    info "Protocol Comparison:"
    echo ""
    echo "  ┌────────────────────┬────────────┬──────────┬──────────────────┐"
    echo "  │ Protocol           │ Transport  │ Stealth  │ Speed            │"
    echo "  ├────────────────────┼────────────┼──────────┼──────────────────┤"
    echo "  │ VLESS+Reality      │ TCP        │ ★★★★★   │ ★★★★            │"
    echo "  │ Hysteria2          │ UDP/QUIC   │ ★★★★    │ ★★★★★           │"
    echo "  │ Shadowsocks-2022   │ TCP+UDP    │ ★★★     │ ★★★★            │"
    echo "  │ TUIC               │ UDP/QUIC   │ ★★★     │ ★★★★            │"
    echo "  │ WireGuard          │ UDP        │ ★★       │ ★★★★★ (kernel)  │"
    echo "  │ Brook              │ TCP+UDP    │ ★★★     │ ★★★             │"
    echo "  │ SSH Tunnel         │ TCP        │ ★★       │ ★★              │"
    echo "  └────────────────────┴────────────┴──────────┴──────────────────┘"
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════════════════╗"
    echo "  ║   IR Tommy Setup - Foreign Server Side  v2.0    ║"
    echo "  ║   VLESS+Reality | Hysteria2 | Shadowsocks-2022  ║"
    echo "  ║   TUIC | WireGuard | Brook | SSH Tunnel         ║"
    echo "  ╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_root
    detect_os
    get_server_ip
    show_menu
    prepare_system

    [[ "${SETUP_XRAY:-false}" == true ]] && setup_xray
    [[ "${SETUP_HYSTERIA:-false}" == true ]] && setup_hysteria
    [[ "${SETUP_SS:-false}" == true ]] && setup_shadowsocks
    [[ "${SETUP_TUIC:-false}" == true ]] && setup_tuic
    [[ "${SETUP_WG:-false}" == true ]] && setup_wireguard
    [[ "${SETUP_BROOK:-false}" == true ]] && setup_brook
    [[ "${SETUP_SSH:-false}" == true ]] && setup_ssh_tunnel

    show_summary
}

main "$@"
