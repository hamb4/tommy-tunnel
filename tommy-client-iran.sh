#!/usr/bin/env bash
#===============================================================================
#  Tommy Client Setup Script v2.0 - Iranian Server Side
#
#  Supports: VLESS+Reality, Hysteria2, Shadowsocks-2022, TUIC,
#            WireGuard, Brook, SSH Tunnel, Port Forwarding
#
#  USAGE:
#    chmod +x tommy-client-iran.sh
#    sudo ./tommy-client-iran.sh
#===============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

check_root() { [[ $EUID -eq 0 ]] || error "Run as root."; }

FOREIGN_IP=""
PROTOCOL=""

# Default proxy ports
SOCKS_PORT="10808"
HTTP_PORT="10809"

# ── Menu ──────────────────────────────────────────────────────────────────────
show_menu() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         Tommy Client Setup - Iranian Server Side               ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║                                                                  ║${NC}"
    echo -e "${CYAN}║  1) Xray VLESS + Reality   (Best stealth, TCP-based)           ║${NC}"
    echo -e "${CYAN}║  2) Hysteria2              (Best speed, UDP/QUIC-based)        ║${NC}"
    echo -e "${CYAN}║  3) Shadowsocks-2022       (Battle-tested, simple & fast)      ║${NC}"
    echo -e "${CYAN}║  4) TUIC                   (QUIC-based, low latency)           ║${NC}"
    echo -e "${CYAN}║  5) WireGuard              (Kernel VPN, fastest throughput)    ║${NC}"
    echo -e "${CYAN}║  6) Brook                  (Ultra-lightweight, zero-config)    ║${NC}"
    echo -e "${CYAN}║  7) SSH Tunnel             (No extra software needed)          ║${NC}"
    echo -e "${CYAN}║  8) Port Forwarding        (Forward local ports through tunnel)║${NC}"
    echo -e "${CYAN}║  9) Exit                                                        ║${NC}"
    echo -e "${CYAN}║                                                                  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "Select protocol [1-9]: " PROTOCOL_CHOICE

    case "$PROTOCOL_CHOICE" in
        1) PROTOCOL="xray" ;;
        2) PROTOCOL="hysteria2" ;;
        3) PROTOCOL="shadowsocks" ;;
        4) PROTOCOL="tuic" ;;
        5) PROTOCOL="wireguard" ;;
        6) PROTOCOL="brook" ;;
        7) PROTOCOL="ssh" ;;
        8) PROTOCOL="portforward" ;;
        9) exit 0 ;;
        *) error "Invalid choice." ;;
    esac
}

# ── Get Foreign Server Info ───────────────────────────────────────────────────
get_foreign_ip() {
    echo ""
    read -rp "Enter your FOREIGN server IP: " FOREIGN_IP
    [[ -z "$FOREIGN_IP" ]] && error "Foreign server IP is required."
    info "Foreign server: ${FOREIGN_IP}"
}

# ── Install Dependencies ──────────────────────────────────────────────────────
install_deps() {
    info "Installing dependencies..."
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
            apt-get update -y
            apt-get install -y curl wget unzip openssl wireguard-tools autossh 2>/dev/null || true
        elif [[ "$ID" == "centos" || "$ID" == "rhel" || "$ID" == "rocky" ]]; then
            yum install -y curl wget unzip openssl 2>/dev/null || true
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  1. XRAY CLIENT (VLESS+Reality)
# ══════════════════════════════════════════════════════════════════════════════
setup_xray_client() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up Xray Client (VLESS+Reality)"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if ! command -v xray &>/dev/null; then
        info "Installing Xray-core..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    echo ""
    info "Enter VLESS+Reality credentials from foreign server."
    info "(Found in /root/xray-client-info.txt on foreign server)"
    echo ""
    read -rp "VLESS UUID: " VLESS_UUID
    read -rp "Port [443]: " VLESS_PORT; VLESS_PORT="${VLESS_PORT:-443}"
    read -rp "SNI [www.microsoft.com]: " REALITY_SNI; REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
    read -rp "Public Key: " REALITY_PBK
    read -rp "Short ID: " REALITY_SID
    read -rp "Fingerprint [chrome]: " REALITY_FP; REALITY_FP="${REALITY_FP:-chrome}"

    [[ -z "$VLESS_UUID" ]] && error "UUID is required."
    [[ -z "$REALITY_PBK" ]] && error "Public key is required."
    [[ -z "$REALITY_SID" ]] && error "Short ID is required."

    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<XEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "socks",
      "listen": "127.0.0.1",
      "port": ${SOCKS_PORT},
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true },
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    },
    {
      "tag": "http",
      "listen": "127.0.0.1",
      "port": ${HTTP_PORT},
      "protocol": "http",
      "settings": { "allowTransparent": false },
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    }
  ],
  "outbounds": [
    {
      "tag": "vless-reality",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "${FOREIGN_IP}",
          "port": ${VLESS_PORT},
          "users": [{
            "id": "${VLESS_UUID}",
            "encryption": "none",
            "flow": "xtls-rprx-vision"
          }]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${REALITY_SNI}",
          "fingerprint": "${REALITY_FP}",
          "publicKey": "${REALITY_PBK}",
          "shortId": "${REALITY_SID}"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" }
    ]
  }
}
XEOF

    systemctl enable xray; systemctl restart xray; sleep 2

    if systemctl is-active --quiet xray; then
        info "Xray client running! SOCKS5: 127.0.0.1:${SOCKS_PORT}  HTTP: 127.0.0.1:${HTTP_PORT}"
    else
        error "Xray failed. Check: journalctl -u xray -n 30"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  2. HYSTERIA2 CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_hysteria2_client() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up Hysteria2 Client"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if ! command -v hysteria &>/dev/null; then
        info "Installing Hysteria2..."
        bash <(curl -fsSL https://get.hy2.sh/)
    fi

    echo ""
    info "Enter Hysteria2 credentials from foreign server."
    read -rp "Password: " HY_PASSWORD
    read -rp "Port [8443]: " HY_PORT; HY_PORT="${HY_PORT:-8443}"
    read -rp "SNI [bing.com]: " HY_SNI; HY_SNI="${HY_SNI:-bing.com}"
    [[ -z "$HY_PASSWORD" ]] && error "Password is required."

    mkdir -p /etc/hysteria
    cat > /etc/hysteria/client.yaml <<HEOF
server: ${FOREIGN_IP}:${HY_PORT}
auth: ${HY_PASSWORD}
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
  maxIdleTimeout: 60s
bandwidth:
  up: 100 mbps
  down: 200 mbps
HEOF

    cat > /etc/systemd/system/hysteria-client.service <<SEOF
[Unit]
Description=Hysteria2 Client
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

    systemctl daemon-reload
    systemctl enable hysteria-client; systemctl restart hysteria-client; sleep 2

    if systemctl is-active --quiet hysteria-client; then
        info "Hysteria2 client running! SOCKS5: 127.0.0.1:${SOCKS_PORT}  HTTP: 127.0.0.1:${HTTP_PORT}"
    else
        warn "Hysteria2 client may have failed. Check: journalctl -u hysteria-client -n 20"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  3. SHADOWSOCKS CLIENT (sing-box)
# ══════════════════════════════════════════════════════════════════════════════
setup_shadowsocks_client() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up Shadowsocks-2022 Client (sing-box)"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Install sing-box
    if ! command -v sing-box &>/dev/null; then
        info "Installing sing-box..."
        bash -c "$(curl -fsSL https://sing-box.app/deb-install.sh)" 2>/dev/null || {
            ARCH=$(uname -m)
            case "$ARCH" in
                x86_64) SARCH="amd64" ;;
                aarch64) SARCH="arm64" ;;
                *) SARCH="amd64" ;;
            esac
            curl -Lo /tmp/sing-box.deb "https://github.com/SagerNet/sing-box/releases/latest/download/sing-box_${SARCH}.deb" 2>/dev/null || true
            [[ -f /tmp/sing-box.deb ]] && dpkg -i /tmp/sing-box.deb 2>/dev/null || true
        }
    fi

    if ! command -v sing-box &>/dev/null; then
        warn "sing-box not available. Trying shadowsocks-rust client..."
        setup_shadowsocks_rust_client
        return
    fi

    echo ""
    info "Enter Shadowsocks credentials from foreign server."
    read -rp "Port [8388]: " SS_PORT; SS_PORT="${SS_PORT:-8388}"
    read -rp "Method [2022-blake3-aes-256-gcm]: " SS_METHOD; SS_METHOD="${SS_METHOD:-2022-blake3-aes-256-gcm}"
    read -rp "Password: " SS_PASSWORD
    [[ -z "$SS_PASSWORD" ]] && error "Password is required."

    mkdir -p /etc/sing-box
    cat > /etc/sing-box/client.json <<SEOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "socks",
      "listen": "127.0.0.1",
      "listen_port": ${SOCKS_PORT}
    },
    {
      "type": "http",
      "listen": "127.0.0.1",
      "listen_port": ${HTTP_PORT}
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "server": "${FOREIGN_IP}",
      "server_port": ${SS_PORT},
      "method": "${SS_METHOD}",
      "password": "${SS_PASSWORD}"
    }
  ]
}
SEOF

    cat > /etc/systemd/system/sing-box-client.service <<SVEOF
[Unit]
Description=sing-box Client (Shadowsocks)
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

    systemctl daemon-reload
    systemctl enable sing-box-client; systemctl restart sing-box-client; sleep 2

    if systemctl is-active --quiet sing-box-client; then
        info "Shadowsocks client running! SOCKS5: 127.0.0.1:${SOCKS_PORT}  HTTP: 127.0.0.1:${HTTP_PORT}"
    else
        warn "Shadowsocks client may have failed. Check: journalctl -u sing-box-client -n 20"
    fi
}

# Fallback: sslocal (shadowsocks-rust)
setup_shadowsocks_rust_client() {
    info "Installing shadowsocks-rust client..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) RARCH="x86_64-unknown-linux-gnu" ;;
        aarch64) RARCH="aarch64-unknown-linux-gnu" ;;
        *) RARCH="x86_64-unknown-linux-gnu" ;;
    esac
    curl -Lo /tmp/ss-rust.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/latest/download/shadowsocks-v-${RARCH}.tar.xz" 2>/dev/null || true
    if [[ -f /tmp/ss-rust.tar.xz ]]; then
        tar -xf /tmp/ss-rust.tar.xz -C /usr/local/bin/ sslocal 2>/dev/null || true
    fi

    echo ""
    read -rp "Port [8388]: " SS_PORT; SS_PORT="${SS_PORT:-8388}"
    read -rp "Password: " SS_PASSWORD
    [[ -z "$SS_PASSWORD" ]] && error "Password required."

    cat > /etc/systemd/system/sslocal.service <<SVEOF
[Unit]
Description=Shadowsocks Local Client
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/sslocal -s ${FOREIGN_IP}:${SS_PORT} -m 2022-blake3-aes-256-gcm -k ${SS_PASSWORD} --socks 127.0.0.1:${SOCKS_PORT} -b 127.0.0.1:${HTTP_PORT}
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
SVEOF

    systemctl daemon-reload
    systemctl enable sslocal; systemctl restart sslocal; sleep 2
    info "Shadowsocks client started via sslocal."
}

# ══════════════════════════════════════════════════════════════════════════════
#  4. TUIC CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_tuic_client() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up TUIC Client"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if ! command -v tuic-client &>/dev/null; then
        info "Installing TUIC client..."
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) TARCH="x86_64-unknown-linux-gnu" ;;
            aarch64) TARCH="aarch64-unknown-linux-gnu" ;;
            *) TARCH="x86_64-unknown-linux-gnu" ;;
        esac
        curl -Lo /usr/local/bin/tuic-client "https://github.com/EAimTY/tuic/releases/latest/download/tuic-client-${TARCH}" 2>/dev/null || true
        if [[ -f /usr/local/bin/tuic-client ]]; then
            chmod +x /usr/local/bin/tuic-client
        else
            warn "TUIC client download failed."
            return
        fi
    fi

    echo ""
    info "Enter TUIC credentials from foreign server."
    read -rp "UUID: " TUIC_UUID
    read -rp "Password: " TUIC_PASSWORD
    read -rp "Port [8444]: " TUIC_PORT; TUIC_PORT="${TUIC_PORT:-8444}"
    [[ -z "$TUIC_UUID" ]] && error "UUID required."
    [[ -z "$TUIC_PASSWORD" ]] && error "Password required."

    mkdir -p /etc/tuic
    cat > /etc/tuic/client.json <<TEOF
{
  "relay": {
    "server": "${FOREIGN_IP}:${TUIC_PORT}",
    "uuid": "${TUIC_UUID}",
    "password": "${TUIC_PASSWORD}"
  },
  "local": {
    "server": "127.0.0.1:${SOCKS_PORT}"
  },
  "tls": {
    "insecure": true,
    "alpn": ["h3"]
  }
}
TEOF

    cat > /etc/systemd/system/tuic-client.service <<SVEOF
[Unit]
Description=TUIC Client
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

    systemctl daemon-reload
    systemctl enable tuic-client; systemctl restart tuic-client; sleep 2

    if systemctl is-active --quiet tuic-client; then
        info "TUIC client running! SOCKS5: 127.0.0.1:${SOCKS_PORT}"
    else
        warn "TUIC client may have failed. Check: journalctl -u tuic-client -n 20"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  5. WIREGUARD CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_wireguard_client() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up WireGuard Client"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if ! command -v wg &>/dev/null; then
        info "Installing WireGuard tools..."
        apt-get install -y wireguard-tools 2>/dev/null || yum install -y wireguard-tools 2>/dev/null || true
    fi

    echo ""
    info "Enter WireGuard credentials from foreign server."
    info "(Found in /root/wireguard-client-info.txt on foreign server)"
    echo ""
    echo "Paste the entire [Interface]...[Peer] config block:"
    echo "(End with a blank line)"
    WG_CONFIG=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        WG_CONFIG="${WG_CONFIG}${line}"$'\n'
    done

    if [[ -z "$WG_CONFIG" ]]; then
        # Manual entry
        read -rp "Client Private Key: " WG_PRIVKEY
        read -rp "Client Tunnel IP [10.66.66.2/24]: " WG_CLIENT_IP; WG_CLIENT_IP="${WG_CLIENT_IP:-10.66.66.2/24}"
        read -rp "Server Public Key: " WG_SERVER_PUBKEY
        read -rp "Server Port [51820]: " WG_PORT; WG_PORT="${WG_PORT:-51820}"

        WG_CONFIG="[Interface]
PrivateKey = ${WG_PRIVKEY}
Address = ${WG_CLIENT_IP}
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = ${WG_SERVER_PUBKEY}
Endpoint = ${FOREIGN_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25"
    fi

    echo "$WG_CONFIG" > /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf

    # Enable IP forwarding for forwarding traffic
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf 2>/dev/null || true
    sysctl -p /etc/sysctl.conf 2>/dev/null || true

    systemctl enable wg-quick@wg0
    wg-quick up wg0 2>/dev/null || true
    sleep 2

    if wg show wg0 &>/dev/null; then
        info "WireGuard connected! All traffic routes through tunnel."
        info "Your tunnel IP: $(wg show wg0 | grep -oP 'peer:.*?allowed ips: \K[0-9./]+' | head -1 || echo 'check with: wg show wg0')"
    else
        warn "WireGuard may have failed. Try: wg-quick up wg0"
    fi

    # WireGuard routes ALL traffic, no need for separate proxy
    info "With WireGuard, ALL traffic is tunneled at kernel level - no proxy needed."
    info "Test: curl -s https://api.ipify.org (should show foreign server IP)"
    return
}

# ══════════════════════════════════════════════════════════════════════════════
#  6. BROOK CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_brook_client() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up Brook Client"
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
            warn "Brook download failed."
            return
        fi
    fi

    echo ""
    info "Enter Brook credentials from foreign server."
    read -rp "Port [9999]: " BROOK_PORT; BROOK_PORT="${BROOK_PORT:-9999}"
    read -rp "Password: " BROOK_PASSWORD
    [[ -z "$BROOK_PASSWORD" ]] && error "Password required."

    cat > /etc/systemd/system/brook-client.service <<SVEOF
[Unit]
Description=Brook Client
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/brook client -s ${FOREIGN_IP}:${BROOK_PORT} -p ${BROOK_PASSWORD} --socks5 127.0.0.1:${SOCKS_PORT} --http 127.0.0.1:${HTTP_PORT}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SVEOF

    systemctl daemon-reload
    systemctl enable brook-client; systemctl restart brook-client; sleep 2

    if systemctl is-active --quiet brook-client; then
        info "Brook client running! SOCKS5: 127.0.0.1:${SOCKS_PORT}  HTTP: 127.0.0.1:${HTTP_PORT}"
    else
        warn "Brook client may have failed. Check: journalctl -u brook-client -n 20"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  7. SSH TUNNEL CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_ssh_client() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up SSH Tunnel Client"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    echo ""
    info "Enter SSH credentials from foreign server."
    read -rp "SSH Port [22]: " SSH_PORT; SSH_PORT="${SSH_PORT:-22}"
    read -rp "Username [tunneluser]: " SSH_USER; SSH_USER="${SSH_USER:-tunneluser}"
    read -rp "Password (or leave blank to use SSH key): " SSH_PASSWORD

    # Install autossh for auto-reconnect
    if ! command -v autossh &>/dev/null; then
        apt-get install -y autossh 2>/dev/null || yum install -y autossh 2>/dev/null || true
    fi

    if [[ -n "$SSH_PASSWORD" ]]; then
        # Password-based SSH tunnel
        info "Setting up SSH tunnel with password auth..."
        info "Note: For auto-reconnect with password, you need sshpass."

        if ! command -v sshpass &>/dev/null; then
            apt-get install -y sshpass 2>/dev/null || yum install -y sshpass 2>/dev/null || true
        fi

        cat > /etc/systemd/system/ssh-tunnel.service <<SVEOF
[Unit]
Description=SSH Tunnel (SOCKS5 Proxy)
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/sshpass -p '${SSH_PASSWORD}' autossh -D 127.0.0.1:${SOCKS_PORT} -N -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p ${SSH_PORT} ${SSH_USER}@${FOREIGN_IP}
Restart=on-failure
RestartSec=10
LimitNOFILE=65535
Environment="AUTOSSH_GATETIME=0"
[Install]
WantedBy=multi-user.target
SVEOF
    else
        # Key-based SSH tunnel (more secure)
        info "Setting up SSH tunnel with key auth..."
        if [[ ! -f ~/.ssh/tunnel_key ]]; then
            ssh-keygen -t ed25519 -f ~/.ssh/tunnel_key -N "" -q
            info "Generated SSH key at ~/.ssh/tunnel_key"
            info "Public key (add to foreign server's authorized_keys):"
            cat ~/.ssh/tunnel_key.pub
            read -rp "Press Enter after adding the key to the foreign server..."
        fi

        cat > /etc/systemd/system/ssh-tunnel.service <<SVEOF
[Unit]
Description=SSH Tunnel (SOCKS5 Proxy)
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/autossh -D 127.0.0.1:${SOCKS_PORT} -N -i /root/.ssh/tunnel_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p ${SSH_PORT} ${SSH_USER}@${FOREIGN_IP}
Restart=on-failure
RestartSec=10
LimitNOFILE=65535
Environment="AUTOSSH_GATETIME=0"
[Install]
WantedBy=multi-user.target
SVEOF
    fi

    systemctl daemon-reload
    systemctl enable ssh-tunnel; systemctl restart ssh-tunnel; sleep 3

    if systemctl is-active --quiet ssh-tunnel; then
        info "SSH tunnel running! SOCKS5: 127.0.0.1:${SOCKS_PORT}"
    else
        warn "SSH tunnel may have failed. Check: journalctl -u ssh-tunnel -n 20"
    fi

    # SSH only provides SOCKS5, set up a simple HTTP proxy relay if needed
    info "Note: SSH only provides SOCKS5. For HTTP proxy, use:"
    info "  curl -x socks5h://127.0.0.1:${SOCKS_PORT} https://example.com"
}

# ══════════════════════════════════════════════════════════════════════════════
#  8. PORT FORWARDING
# ══════════════════════════════════════════════════════════════════════════════
setup_port_forwarding() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Setting up Port Forwarding"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    info "Port Forwarding forwards specific local ports on the Iranian"
    info "server to remote ports on the foreign server (or any internet"
    info "host via the foreign server). This is useful for:"
    info "  - Accessing foreign services blocked in Iran"
    info "  - Exposing local services through the foreign server's IP"
    info "  - Building relay chains for services"
    echo ""
    info "Choose forwarding method:"
    echo "  1) SSH Port Forwarding     (Local/Remote, simplest)"
    echo "  2) Xray Port Forwarding   (Via VLESS+Reality tunnel)"
    echo "  3) iptables Port Forwarding (Direct NAT, needs WireGuard)"
    echo "  4) socat Port Forwarding  (Simple TCP/UDP relay)"
    read -rp "Select method [1-4]: " PF_METHOD

    case "$PF_METHOD" in
        1) pf_ssh ;;
        2) pf_xray ;;
        3) pf_iptables ;;
        4) pf_socat ;;
        *) error "Invalid choice." ;;
    esac
}

# ── SSH Port Forwarding ────────────────────────────────────────────────────────
pf_ssh() {
    info "Setting up SSH Port Forwarding..."
    echo ""
    info "Choose direction:"
    echo "  L) Local  - Forward LOCAL port to REMOTE host via SSH"
    echo "  R) Remote - Forward REMOTE port to LOCAL host via SSH"
    read -rp "Direction [L/R]: " PF_DIR
    PF_DIR="${PF_DIR^^}"

    read -rp "Enter FOREIGN server IP: " FOREIGN_IP
    [[ -z "$FOREIGN_IP" ]] && error "IP required."
    read -rp "SSH Port [22]: " SSH_PORT; SSH_PORT="${SSH_PORT:-22}"
    read -rp "SSH Username [tunneluser]: " SSH_USER; SSH_USER="${SSH_USER:-tunneluser}"

    if [[ "$PF_DIR" == "L" ]]; then
        # Local port forwarding: local:port -> foreign:remote_port
        info "LOCAL forwarding: Iranian:local_port -> foreign:remote_port"
        read -rp "Listen on LOCAL port (on this Iranian server): " LOCAL_PORT
        read -rp "Forward to REMOTE host:port (on foreign side): " REMOTE_DEST
        REMOTE_HOST=$(echo "$REMOTE_DEST" | cut -d: -f1)
        REMOTE_PORT=$(echo "$REMOTE_DEST" | cut -d: -f2)
        [[ -z "$LOCAL_PORT" || -z "$REMOTE_HOST" || -z "$REMOTE_PORT" ]] && error "All fields required."

        # Install autossh
        command -v autossh &>/dev/null || apt-get install -y autossh 2>/dev/null || true

        read -rp "Password (or leave blank for SSH key): " SSH_PASSWORD

        if [[ -n "$SSH_PASSWORD" ]]; then
            command -v sshpass &>/dev/null || apt-get install -y sshpass 2>/dev/null || true
            cat > /etc/systemd/system/tommy-pf-ssh.service <<SVEOF
[Unit]
Description=Tommy SSH Local Port Forward (:${LOCAL_PORT} -> ${REMOTE_HOST}:${REMOTE_PORT})
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/sshpass -p '${SSH_PASSWORD}' autossh -L 0.0.0.0:${LOCAL_PORT}:${REMOTE_HOST}:${REMOTE_PORT} -N -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p ${SSH_PORT} ${SSH_USER}@${FOREIGN_IP}
Restart=on-failure
RestartSec=10
Environment="AUTOSSH_GATETIME=0"
[Install]
WantedBy=multi-user.target
SVEOF
        else
            [[ ! -f ~/.ssh/tunnel_key ]] && ssh-keygen -t ed25519 -f ~/.ssh/tunnel_key -N "" -q
            cat > /etc/systemd/system/tommy-pf-ssh.service <<SVEOF
[Unit]
Description=Tommy SSH Local Port Forward (:${LOCAL_PORT} -> ${REMOTE_HOST}:${REMOTE_PORT})
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/autossh -L 0.0.0.0:${LOCAL_PORT}:${REMOTE_HOST}:${REMOTE_PORT} -N -i /root/.ssh/tunnel_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p ${SSH_PORT} ${SSH_USER}@${FOREIGN_IP}
Restart=on-failure
RestartSec=10
Environment="AUTOSSH_GATETIME=0"
[Install]
WantedBy=multi-user.target
SVEOF
        fi

        open_firewall "$LOCAL_PORT" tcp
        info "Local forwarding: 0.0.0.0:${LOCAL_PORT} -> ${REMOTE_HOST}:${REMOTE_PORT} (via ${FOREIGN_IP})"

    elif [[ "$PF_DIR" == "R" ]]; then
        # Remote port forwarding: foreign:port -> local:local_port
        info "REMOTE forwarding: foreign:remote_port -> this_server:local_port"
        read -rp "Listen on REMOTE port (on foreign server): " REMOTE_PORT
        read -rp "Forward to LOCAL host:port (on this Iranian server): " LOCAL_DEST
        LOCAL_HOST=$(echo "$LOCAL_DEST" | cut -d: -f1)
        LOCAL_PORT=$(echo "$LOCAL_DEST" | cut -d: -f2)
        [[ -z "$REMOTE_PORT" || -z "$LOCAL_HOST" || -z "$LOCAL_PORT" ]] && error "All fields required."

        command -v autossh &>/dev/null || apt-get install -y autossh 2>/dev/null || true
        read -rp "Password (or leave blank for SSH key): " SSH_PASSWORD

        if [[ -n "$SSH_PASSWORD" ]]; then
            command -v sshpass &>/dev/null || apt-get install -y sshpass 2>/dev/null || true
            cat > /etc/systemd/system/tommy-pf-ssh.service <<SVEOF
[Unit]
Description=Tommy SSH Remote Port Forward (${FOREIGN_IP}:${REMOTE_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT})
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/sshpass -p '${SSH_PASSWORD}' autossh -R 0.0.0.0:${REMOTE_PORT}:${LOCAL_HOST}:${LOCAL_PORT} -N -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p ${SSH_PORT} ${SSH_USER}@${FOREIGN_IP}
Restart=on-failure
RestartSec=10
Environment="AUTOSSH_GATETIME=0"
[Install]
WantedBy=multi-user.target
SVEOF
        else
            [[ ! -f ~/.ssh/tunnel_key ]] && ssh-keygen -t ed25519 -f ~/.ssh/tunnel_key -N "" -q
            cat > /etc/systemd/system/tommy-pf-ssh.service <<SVEOF
[Unit]
Description=Tommy SSH Remote Port Forward (${FOREIGN_IP}:${REMOTE_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT})
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/autossh -R 0.0.0.0:${REMOTE_PORT}:${LOCAL_HOST}:${LOCAL_PORT} -N -i /root/.ssh/tunnel_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p ${SSH_PORT} ${SSH_USER}@${FOREIGN_IP}
Restart=on-failure
RestartSec=10
Environment="AUTOSSH_GATETIME=0"
[Install]
WantedBy=multi-user.target
SVEOF
        fi

        info "Remote forwarding: ${FOREIGN_IP}:${REMOTE_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT}"
    fi

    systemctl daemon-reload
    systemctl enable tommy-pf-ssh; systemctl restart tommy-pf-ssh; sleep 2

    if systemctl is-active --quiet tommy-pf-ssh; then
        info "SSH Port Forwarding active!"
    else
        warn "SSH Port Forwarding may have failed. Check: journalctl -u tommy-pf-ssh -n 20"
    fi
}

# ── Xray Port Forwarding ──────────────────────────────────────────────────────
pf_xray() {
    info "Setting up Xray Port Forwarding (via VLESS+Reality tunnel)..."
    echo ""
    info "This forwards a local port through the VLESS+Reality tunnel"
    info "to any destination on the internet (via the foreign server)."
    echo ""
    read -rp "Enter FOREIGN server IP: " FOREIGN_IP
    [[ -z "$FOREIGN_IP" ]] && error "IP required."

    info "Enter VLESS+Reality credentials from foreign server."
    read -rp "VLESS UUID: " VLESS_UUID
    read -rp "VLESS Port [443]: " VLESS_PORT; VLESS_PORT="${VLESS_PORT:-443}"
    read -rp "SNI [www.microsoft.com]: " REALITY_SNI; REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
    read -rp "Public Key: " REALITY_PBK
    read -rp "Short ID: " REALITY_SID
    [[ -z "$VLESS_UUID" || -z "$REALITY_PBK" || -z "$REALITY_SID" ]] && error "All fields required."

    echo ""
    info "Enter port forwarding rules."
    info "Format: local_port:dest_host:dest_port (one per line, blank to finish)"
    info "Example: 3306:db.example.com:3306"
    info "         8080:api.service.com:443"
    echo ""

    PF_RULES=()
    PF_INBOUNDS=""
    PF_ROUTING_RULES=""
    RULE_IDX=0
    while true; do
        read -rp "Forwarding rule (blank to finish): " PF_RULE
        [[ -z "$PF_RULE" ]] && break
        LOCAL_P=$(echo "$PF_RULE" | cut -d: -f1)
        DEST_H=$(echo "$PF_RULE" | cut -d: -f2)
        DEST_P=$(echo "$PF_RULE" | cut -d: -f3)
        [[ -z "$LOCAL_P" || -z "$DEST_H" || -z "$DEST_P" ]] && { warn "Invalid format. Use local_port:dest_host:dest_port"; continue; }

        PF_RULES+=("${LOCAL_P}:${DEST_H}:${DEST_P}")

        # Build inbound for this rule
        PF_INBOUNDS+="$(cat <<IBEOF
    {
      "tag": "pf-${RULE_IDX}",
      "listen": "0.0.0.0",
      "port": ${LOCAL_P},
      "protocol": "dokodemo-door",
      "settings": {
        "address": "${DEST_H}",
        "port": ${DEST_P},
        "network": "tcp"
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    },
IBEOF
)"

        # Build routing rule
        PF_ROUTING_RULES+="$(cat <<RREOF
    { "type": "field", "inboundTag": ["pf-${RULE_IDX}"], "outboundTag": "vless-reality" },
RREOF
)"

        open_firewall "$LOCAL_P" tcp
        info "Rule: 0.0.0.0:${LOCAL_P} -> ${DEST_H}:${DEST_P} (via VLESS+Reality)"
        ((RULE_IDX++)) || true
    done

    if [[ ${#PF_RULES[@]} -eq 0 ]]; then
        warn "No rules entered. Exiting."
        return
    fi

    # Remove trailing commas
    PF_INBOUNDS=$(echo "$PF_INBOUNDS" | sed '$ s/,$//')
    PF_ROUTING_RULES=$(echo "$PF_ROUTING_RULES" | sed '$ s/,$//')

    # Install Xray if needed
    if ! command -v xray &>/dev/null; then
        info "Installing Xray-core..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    # Generate full config
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<XEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
${PF_INBOUNDS}
  ],
  "outbounds": [
    {
      "tag": "vless-reality",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "${FOREIGN_IP}",
          "port": ${VLESS_PORT},
          "users": [{
            "id": "${VLESS_UUID}",
            "encryption": "none",
            "flow": "xtls-rprx-vision"
          }]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${REALITY_SNI}",
          "fingerprint": "chrome",
          "publicKey": "${REALITY_PBK}",
          "shortId": "${REALITY_SID}"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
${PF_ROUTING_RULES}
    ]
  }
}
XEOF

    systemctl enable xray; systemctl restart xray; sleep 2

    if systemctl is-active --quiet xray; then
        info "Xray Port Forwarding active!"
        for rule in "${PF_RULES[@]}"; do
            info "  0.0.0.0:${rule}"
        done
    else
        warn "Xray may have failed. Check: journalctl -u xray -n 30"
    fi
}

# ── iptables Port Forwarding (via WireGuard) ──────────────────────────────────
pf_iptables() {
    info "Setting up iptables Port Forwarding (requires WireGuard)..."
    echo ""
    if ! wg show wg0 &>/dev/null; then
        warn "WireGuard is not running. Set up WireGuard first (option 5)."
        return
    fi

    echo ""
    info "Enter port forwarding rules."
    info "Format: local_port:dest_host:dest_port (one per line, blank to finish)"
    info "Example: 80:10.66.66.1:80"
    echo ""

    PF_SCRIPT="/etc/tommy-port-forward.sh"
    echo "#!/bin/bash" > "$PF_SCRIPT"

    while true; do
        read -rp "Forwarding rule (blank to finish): " PF_RULE
        [[ -z "$PF_RULE" ]] && break
        LOCAL_P=$(echo "$PF_RULE" | cut -d: -f1)
        DEST_H=$(echo "$PF_RULE" | cut -d: -f2)
        DEST_P=$(echo "$PF_RULE" | cut -d: -f3)
        [[ -z "$LOCAL_P" || -z "$DEST_H" || -z "$DEST_P" ]] && { warn "Invalid format."; continue; }

        # Add iptables NAT rules
        cat >> "$PF_SCRIPT" <<IPEOF
# Forward :${LOCAL_P} -> ${DEST_H}:${DEST_P}
iptables -t nat -A PREROUTING -p tcp --dport ${LOCAL_P} -j DNAT --to-destination ${DEST_H}:${DEST_P}
iptables -t nat -A PREROUTING -p udp --dport ${LOCAL_P} -j DNAT --to-destination ${DEST_H}:${DEST_P}
iptables -t nat -A POSTROUTING -d ${DEST_H} -j MASQUERADE
IPEOF

        open_firewall "$LOCAL_P" tcp
        open_firewall "$LOCAL_P" udp
        info "Rule: 0.0.0.0:${LOCAL_P} -> ${DEST_H}:${DEST_P} (via WireGuard)"
    done

    chmod +x "$PF_SCRIPT"
    bash "$PF_SCRIPT"

    # Make rules persistent
    cat > /etc/systemd/system/tommy-pf-iptables.service <<SVEOF
[Unit]
Description=Tommy iptables Port Forwarding
After=network.target wg-quick@wg0.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${PF_SCRIPT}
ExecStop=/bin/true
[Install]
WantedBy=multi-user.target
SVEOF

    systemctl daemon-reload
    systemctl enable tommy-pf-iptables
    info "iptables Port Forwarding rules applied and will persist across reboots."
}

# ── socat Port Forwarding ─────────────────────────────────────────────────────
pf_socat() {
    info "Setting up socat Port Forwarding..."
    echo ""
    # Install socat
    if ! command -v socat &>/dev/null; then
        info "Installing socat..."
        apt-get install -y socat 2>/dev/null || yum install -y socat 2>/dev/null || true
    fi

    read -rp "Enter target host:port (to forward to): " DEST
    DEST_HOST=$(echo "$DEST" | cut -d: -f1)
    DEST_PORT=$(echo "$DEST" | cut -d: -f2)
    read -rp "Listen on local port: " LOCAL_PORT
    read -rp "Protocol [tcp/udp]: " PF_PROTO; PF_PROTO="${PF_PROTO:-tcp}"
    [[ -z "$DEST_HOST" || -z "$DEST_PORT" || -z "$LOCAL_PORT" ]] && error "All fields required."

    cat > /etc/systemd/system/tommy-pf-socat.service <<SVEOF
[Unit]
Description=Tommy socat Forward (:${LOCAL_PORT} -> ${DEST_HOST}:${DEST_PORT})
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/socat ${PF_PROTO^}-LISTEN:${LOCAL_PORT},fork,reuseaddr ${PF_PROTO^}:${DEST_HOST}:${DEST_PORT}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SVEOF

    systemctl daemon-reload
    open_firewall "$LOCAL_PORT" "$PF_PROTO"
    systemctl enable tommy-pf-socat; systemctl restart tommy-pf-socat; sleep 1

    if systemctl is-active --quiet tommy-pf-socat; then
        info "socat forwarding active: 0.0.0.0:${LOCAL_PORT} -> ${DEST_HOST}:${DEST_PORT} (${PF_PROTO})"
    else
        warn "socat may have failed. Check: journalctl -u tommy-pf-socat -n 20"
    fi
}

# ── Firewall helper (needed for port forwarding) ──────────────────────────────
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
#  SYSTEM-WIDE PROXY (Optional)
# ══════════════════════════════════════════════════════════════════════════════
setup_system_proxy() {
    echo ""
    info "Do you want to set up system-wide proxy for this server?"
    read -rp "Set up system-wide proxy? [y/N]: " SET_SYS_PROXY
    [[ "${SET_SYS_PROXY,,}" != "y" ]] && return

    # For WireGuard, all traffic is already tunneled
    if [[ "$PROTOCOL" == "wireguard" ]]; then
        info "WireGuard already tunnels ALL traffic at kernel level. No proxy env needed."
        return
    fi

    cat > /etc/profile.d/tunnel-proxy.sh <<ENVEOF
export http_proxy="http://127.0.0.1:${HTTP_PORT}"
export https_proxy="http://127.0.0.1:${HTTP_PORT}"
export HTTP_PROXY="http://127.0.0.1:${HTTP_PORT}"
export HTTPS_PROXY="http://127.0.0.1:${HTTP_PORT}"
export no_proxy="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
export NO_PROXY="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
ENVEOF

    chmod +x /etc/profile.d/tunnel-proxy.sh
    source /etc/profile.d/tunnel-proxy.sh

    info "System-wide proxy set: http://127.0.0.1:${HTTP_PORT}"

    # APT proxy
    if [[ -d /etc/apt ]]; then
        cat > /etc/apt/apt.conf.d/99tunnel-proxy <<PEOF
Acquire::http::Proxy "http://127.0.0.1:${HTTP_PORT}";
Acquire::https::Proxy "http://127.0.0.1:${HTTP_PORT}";
PEOF
        info "APT proxy configured."
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  CONNECTION TEST
# ══════════════════════════════════════════════════════════════════════════════
test_connection() {
    echo ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Testing Tunnel Connection"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    sleep 3

    if [[ "$PROTOCOL" == "wireguard" ]]; then
        # WireGuard tunnels all traffic directly
        RESULT=$(curl -s --connect-timeout 10 https://api.ipify.org 2>/dev/null || echo "FAILED")
        DIRECT=$(curl -s --connect-timeout 5 --interface eth0 https://api.ipify.org 2>/dev/null || echo "unknown")
        info "Tunnel IP: ${RESULT}"
        info "Direct IP: ${DIRECT}"
        if [[ "$RESULT" != "FAILED" && "$RESULT" != "$DIRECT" ]]; then
            info "SUCCESS! Your IP is hidden through WireGuard."
        fi
        return
    fi

    # Test SOCKS5 proxy
    info "Testing SOCKS5 proxy (127.0.0.1:${SOCKS_PORT})..."
    SOCKS_RESULT=$(curl -x socks5h://127.0.0.1:${SOCKS_PORT} -s --connect-timeout 10 https://api.ipify.org 2>/dev/null || echo "FAILED")

    if [[ "$SOCKS_RESULT" != "FAILED" && -n "$SOCKS_RESULT" ]]; then
        info "SOCKS5 proxy working! Tunnel IP: ${SOCKS_RESULT}"
    else
        warn "SOCKS5 proxy test failed."
    fi

    # Test HTTP proxy (if available)
    if [[ "$PROTOCOL" != "ssh" ]]; then
        info "Testing HTTP proxy (127.0.0.1:${HTTP_PORT})..."
        HTTP_RESULT=$(curl -x http://127.0.0.1:${HTTP_PORT} -s --connect-timeout 10 https://api.ipify.org 2>/dev/null || echo "FAILED")
        if [[ "$HTTP_RESULT" != "FAILED" && -n "$HTTP_RESULT" ]]; then
            info "HTTP proxy working! Tunnel IP: ${HTTP_RESULT}"
        else
            warn "HTTP proxy test failed."
        fi
    fi

    # Compare with direct
    DIRECT_IP=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo "unknown")
    info "Direct IP (without tunnel): ${DIRECT_IP}"

    if [[ "$SOCKS_RESULT" != "FAILED" && "$SOCKS_RESULT" != "$DIRECT_IP" ]]; then
        info "SUCCESS! Your IP is hidden! Traffic goes through the foreign server."
    elif [[ "$SOCKS_RESULT" == "$DIRECT_IP" ]]; then
        warn "WARNING: Tunnel IP matches direct IP - tunnel may not be working."
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
show_summary() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              CLIENT SETUP COMPLETE                           ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Protocol: ${PROTOCOL}$(printf '%*s' $((40 - ${#PROTOCOL})) '')${CYAN}║${NC}"
    echo -e "${CYAN}║  Foreign Server: ${FOREIGN_IP}$(printf '%*s' $((33 - ${#FOREIGN_IP})) '')${CYAN}║${NC}"
    echo -e "${CYAN}║                                                              ║${NC}"

    if [[ "$PROTOCOL" == "wireguard" ]]; then
        echo -e "${CYAN}║  All traffic tunneled at kernel level. No proxy needed.     ║${NC}"
    else
        echo -e "${CYAN}║  SOCKS5: 127.0.0.1:${SOCKS_PORT}                                ║${NC}"
        if [[ "$PROTOCOL" != "ssh" ]]; then
            echo -e "${CYAN}║  HTTP:   127.0.0.1:${HTTP_PORT}                                ║${NC}"
        fi
    fi

    echo -e "${CYAN}║                                                              ║${NC}"
    echo -e "${CYAN}║  Usage examples:                                             ║${NC}"
    echo -e "${CYAN}║    curl -x socks5h://127.0.0.1:${SOCKS_PORT} https://ipify.org  ║${NC}"
    echo -e "${CYAN}║    curl -x http://127.0.0.1:${HTTP_PORT} https://ipify.org       ║${NC}"
    echo -e "${CYAN}║                                                              ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════════════════╗"
    echo "  ║   Tommy Client - Iranian Server Side  v2.0   ║"
    echo "  ║   VLESS+Reality | Hysteria2 | Shadowsocks-2022  ║"
    echo "  ║   TUIC | WireGuard | Brook | SSH Tunnel         ║"
    echo "  ╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_root
    show_menu
    install_deps
    get_foreign_ip

    case "$PROTOCOL" in
        xray)        setup_xray_client ;;
        hysteria2)   setup_hysteria2_client ;;
        shadowsocks) setup_shadowsocks_client ;;
        tuic)        setup_tuic_client ;;
        wireguard)   setup_wireguard_client ;;
        brook)       setup_brook_client ;;
        ssh)         setup_ssh_client ;;
        portforward) setup_port_forwarding ;;
    esac

    if [[ "$PROTOCOL" != "portforward" ]]; then
        setup_system_proxy
        test_connection
    fi
    show_summary
}

main "$@"
