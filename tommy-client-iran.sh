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
#    8) Port Forwarding        (External Proxy - Authenticated Tunnel)
#
#  USAGE:
#    chmod +x tommy-client-iran.sh
#    sudo ./tommy-client-iran.sh
#===============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# ── Config ────────────────────────────────────────────────────────────────────
SOCKS_PORT="10808"
HTTP_PORT="10809"
FOREIGN_IP=""
PROTOCOL=""
TOMMY_VER="3.0"
TUNNEL_UUID=""
TUNNEL_PORT=""
SPEED_LEVEL=""
SECURITY_LEVEL=""

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
            apt-get install -y curl wget unzip openssl wireguard-tools autossh sshpass qrencode 2>/dev/null || true
        elif [[ "$ID" == "centos" || "$ID" == "rhel" || "$ID" == "rocky" ]]; then
            yum install -y curl wget unzip openssl wireguard-tools autossh sshpass 2>/dev/null || true
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
}

# ══════════════════════════════════════════════════════════════════════════════
#  SECURITY HARDENING
# ══════════════════════════════════════════════════════════════════════════════
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
    mkdir -p /etc/tommy
    chmod 700 /etc/tommy
    chown root:root /etc/tommy

    # 6. Warning if SSH still using password auth
    if [[ -f /etc/ssh/sshd_config ]]; then
        if grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config 2>/dev/null; then
            warn "SSH still allows password authentication!"
            warn "Consider setting up SSH keys and disabling password auth for better security."
        fi
    fi

    info "Security hardening applied."
}

# ══════════════════════════════════════════════════════════════════════════════
#  PORT FORWARDING (x-ui External Proxy Client Model)
# ══════════════════════════════════════════════════════════════════════════════
setup_port_forwarding() {
    echo ""
    info "━━━ External Proxy Tunnel - Iranian Server Side ━━━"
    info "This connects to the foreign server's authenticated tunnel"
    info "and provides local SOCKS5 and HTTP proxy access."
    echo ""

    # Step 1: Foreign server IP
    read -rp "Enter FOREIGN server IP: " FOREIGN_IP
    [[ -z "$FOREIGN_IP" ]] && error "Foreign server IP required."

    # Step 2: Tunnel port (same as foreign server)
    read -rp "Enter tunnel port (same as foreign server) [443]: " TUNNEL_PORT
    TUNNEL_PORT="${TUNNEL_PORT:-443}"

    # Step 3: Private key from foreign server
    echo ""
    info "Enter the PRIVATE KEY generated on the foreign server."
    info "This was displayed when you ran Option 9 on the foreign server."
    read -rp "Private Key (UUID): " TUNNEL_UUID
    [[ -z "$TUNNEL_UUID" ]] && error "Private key is required."

    # Step 4: Speed level
    echo ""
    info "Select SPEED level (must match foreign server):"
    echo "  1) Low       - 50 mbps"
    echo "  2) Medium    - 200 mbps"
    echo "  3) High      - 500 mbps"
    echo "  4) Maximum   - 1000 mbps"
    read -rp "Select speed [1-4, default=3]: " SPEED_LEVEL
    SPEED_LEVEL="${SPEED_LEVEL:-3}"

    # Step 5: Security level
    echo ""
    info "Select SECURITY level (must match foreign server):"
    echo "  1) Standard  - VMess + AES-128-GCM"
    echo "  2) Enhanced  - VLESS + TLS"
    echo "  3) Maximum   - VLESS + Reality"
    read -rp "Select security [1-3, default=3]: " SECURITY_LEVEL
    SECURITY_LEVEL="${SECURITY_LEVEL:-3}"

    # Step 6: Install Xray
    if ! command -v xray &>/dev/null; then
        info "Installing Xray..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>/dev/null || true
    fi
    if ! command -v xray &>/dev/null; then
        error "Xray installation failed. Cannot set up tunnel."
    fi
    info "Xray installed: $(xray version 2>/dev/null | head -1)"

    # Step 7: Configure based on security level
    if [[ "$SECURITY_LEVEL" == "1" ]]; then
        _pf_vmess_client
    elif [[ "$SECURITY_LEVEL" == "2" ]]; then
        _pf_vless_tls_client
    else
        _pf_vless_reality_client
    fi

    # Step 8: Create systemd service tommy-pf-tunnel
    info "Creating tunnel service..."
    cat > /etc/systemd/system/tommy-pf-tunnel.service <<SVCEOF
[Unit]
Description=Tommy Port Forwarding Tunnel (Xray Client)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    # Stop default xray service if running, use tommy service instead
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true

    # Step 9: Start service
    systemctl daemon-reload
    systemctl enable tommy-pf-tunnel
    systemctl restart tommy-pf-tunnel
    sleep 2

    if systemctl is-active --quiet tommy-pf-tunnel; then
        info "Tunnel service running!"
    else
        warn "Tunnel service may have failed. Check: journalctl -u tommy-pf-tunnel -n 30"
    fi

    # Step 10: Set up system-wide proxy
    setup_system_proxy

    # Step 11: Test connection
    test_connection

    # Step 12: Show summary
    _pf_show_summary
}

# ── VMess client config (Security Level 1: Standard) ─────────────────────────
_pf_vmess_client() {
    info "Configuring VMess + AES-128-GCM tunnel client..."
    mkdir -p /usr/local/etc/xray

    # Speed-based buffer sizes
    local STREAM_RECV=8388608
    local CONN_RECV=20971520
    case "$SPEED_LEVEL" in
        1) STREAM_RECV=2097152;  CONN_RECV=4194304 ;;
        2) STREAM_RECV=4194304;  CONN_RECV=8388608 ;;
        3) STREAM_RECV=8388608;  CONN_RECV=20971520 ;;
        4) STREAM_RECV=16777216; CONN_RECV=33554432 ;;
    esac

    cat > /usr/local/etc/xray/config.json <<XEOF
{
  "log": {"loglevel":"warning"},
  "inbounds": [
    {"tag":"socks","listen":"127.0.0.1","port":${SOCKS_PORT},"protocol":"socks","settings":{"auth":"noauth","udp":true}},
    {"tag":"http","listen":"127.0.0.1","port":${HTTP_PORT},"protocol":"http","settings":{"allowTransparent":false}}
  ],
  "outbounds": [
    {"tag":"vmess-tunnel","protocol":"vmess","settings":{"vnext":[{"address":"${FOREIGN_IP}","port":${TUNNEL_PORT},"users":[{"id":"${TUNNEL_UUID}","alterId":0,"security":"aes-128-gcm"}]}]},"streamSettings":{"network":"tcp","sockopt":{"tcpFastOpen":true,"tcpKeepAliveInterval":30},"receiveWindow":${STREAM_RECV},"congestionControl":"bbr"}},
    {"tag":"direct","protocol":"freedom","settings":{}}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]}
}
XEOF
    chmod 600 /usr/local/etc/xray/config.json
    info "VMess tunnel client configured."
}

# ── VLESS + TLS client config (Security Level 2: Enhanced) ───────────────────
_pf_vless_tls_client() {
    info "Configuring VLESS + TLS tunnel client..."
    mkdir -p /usr/local/etc/xray

    local STREAM_RECV=8388608
    local CONN_RECV=20971520
    case "$SPEED_LEVEL" in
        1) STREAM_RECV=2097152;  CONN_RECV=4194304 ;;
        2) STREAM_RECV=4194304;  CONN_RECV=8388608 ;;
        3) STREAM_RECV=8388608;  CONN_RECV=20971520 ;;
        4) STREAM_RECV=16777216; CONN_RECV=33554432 ;;
    esac

    cat > /usr/local/etc/xray/config.json <<XEOF
{
  "log": {"loglevel":"warning"},
  "inbounds": [
    {"tag":"socks","listen":"127.0.0.1","port":${SOCKS_PORT},"protocol":"socks","settings":{"auth":"noauth","udp":true},"sniffing":{"enabled":true,"destOverride":["http","tls"]}},
    {"tag":"http","listen":"127.0.0.1","port":${HTTP_PORT},"protocol":"http","settings":{"allowTransparent":false},"sniffing":{"enabled":true,"destOverride":["http","tls"]}}
  ],
  "outbounds": [
    {"tag":"vless-tunnel","protocol":"vless","settings":{"vnext":[{"address":"${FOREIGN_IP}","port":${TUNNEL_PORT},"users":[{"id":"${TUNNEL_UUID}","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"serverName":"bing.com","allowInsecure":true},"sockopt":{"tcpFastOpen":true,"tcpKeepAliveInterval":30},"receiveWindow":${STREAM_RECV},"congestionControl":"bbr"}},
    {"tag":"direct","protocol":"freedom","settings":{}}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]}
}
XEOF
    chmod 600 /usr/local/etc/xray/config.json
    info "VLESS + TLS tunnel client configured."
}

# ── VLESS + Reality client config (Security Level 3: Maximum) ────────────────
_pf_vless_reality_client() {
    info "Configuring VLESS + Reality tunnel client (Maximum Security)..."
    echo ""
    info "VLESS + Reality requires extra parameters from the foreign server."
    info "These were shown when you ran Option 9 on the foreign server."
    echo ""

    read -rp "Enter Public Key (from foreign server): " PBK
    read -rp "Enter Short ID (from foreign server): " SID
    read -rp "Enter SNI [www.microsoft.com]: " SNI
    SNI="${SNI:-www.microsoft.com}"
    read -rp "Enter Fingerprint [chrome]: " FP
    FP="${FP:-chrome}"
    [[ -z "$PBK" || -z "$SID" ]] && error "Public Key and Short ID are required."

    mkdir -p /usr/local/etc/xray

    local STREAM_RECV=8388608
    local CONN_RECV=20971520
    case "$SPEED_LEVEL" in
        1) STREAM_RECV=2097152;  CONN_RECV=4194304 ;;
        2) STREAM_RECV=4194304;  CONN_RECV=8388608 ;;
        3) STREAM_RECV=8388608;  CONN_RECV=20971520 ;;
        4) STREAM_RECV=16777216; CONN_RECV=33554432 ;;
    esac

    cat > /usr/local/etc/xray/config.json <<XEOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[
    {"tag":"socks","listen":"127.0.0.1","port":${SOCKS_PORT},"protocol":"socks","settings":{"auth":"noauth","udp":true},"sniffing":{"enabled":true,"destOverride":["http","tls"]}},
    {"tag":"http","listen":"127.0.0.1","port":${HTTP_PORT},"protocol":"http","settings":{"allowTransparent":false},"sniffing":{"enabled":true,"destOverride":["http","tls"]}}
  ],
  "outbounds":[
    {"tag":"vless-reality","protocol":"vless","settings":{"vnext":[{"address":"${FOREIGN_IP}","port":${TUNNEL_PORT},"users":[{"id":"${TUNNEL_UUID}","encryption":"none","flow":"xtls-rprx-vision"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"${SNI}","fingerprint":"${FP}","publicKey":"${PBK}","shortId":"${SID}"}},"sockopt":{"tcpFastOpen":true,"tcpKeepAliveInterval":30}},
    {"tag":"direct","protocol":"freedom","settings":{}}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]}
}
XEOF
    chmod 600 /usr/local/etc/xray/config.json
    info "VLESS + Reality tunnel client configured."
}

# ── PF Summary ───────────────────────────────────────────────────────────────
_pf_show_summary() {
    local SEC_LABEL=""
    case "$SECURITY_LEVEL" in
        1) SEC_LABEL="VMess+AES" ;;
        2) SEC_LABEL="VLESS+TLS" ;;
        3) SEC_LABEL="VLESS+Reality" ;;
        *) SEC_LABEL="Unknown" ;;
    esac
    local SPEED_LABEL=""
    case "$SPEED_LEVEL" in
        1) SPEED_LABEL="50 mbps" ;;
        2) SPEED_LABEL="200 mbps" ;;
        3) SPEED_LABEL="500 mbps" ;;
        4) SPEED_LABEL="1000 mbps" ;;
        *) SPEED_LABEL="Unknown" ;;
    esac

    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Tommy v${TOMMY_VER} - Tunnel Setup Complete!              ║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  Mode:     Port Forwarding (External Proxy)      ║${NC}"
    echo -e "${CYAN}║  Foreign:  ${FOREIGN_IP}$(printf '%*s' $((30 - ${#FOREIGN_IP})) '')║${NC}"
    echo -e "${CYAN}║  Port:     ${TUNNEL_PORT}$(printf '%*s' $((30 - ${#TUNNEL_PORT})) '')║${NC}"
    echo -e "${CYAN}║  Security: ${SEC_LABEL}$(printf '%*s' $((30 - ${#SEC_LABEL})) '')║${NC}"
    echo -e "${CYAN}║  Speed:    ${SPEED_LABEL}$(printf '%*s' $((30 - ${#SPEED_LABEL})) '')║${NC}"
    echo -e "${CYAN}║  SOCKS5:   127.0.0.1:${SOCKS_PORT}                      ║${NC}"
    echo -e "${CYAN}║  HTTP:     127.0.0.1:${HTTP_PORT}                      ║${NC}"
    echo -e "${CYAN}║  Service:  tommy-pf-tunnel                       ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════╝${NC}"

    # Save info file
    cat > /etc/tommy/pf-tunnel-info.txt <<IEOF
================================================================
  Tommy v${TOMMY_VER} - Port Forwarding Tunnel Info
================================================================
  Foreign Server:  ${FOREIGN_IP}
  Tunnel Port:     ${TUNNEL_PORT}
  Security Level:  ${SEC_LABEL}
  Speed Level:     ${SPEED_LABEL}
  SOCKS5 Proxy:    127.0.0.1:${SOCKS_PORT}
  HTTP Proxy:      127.0.0.1:${HTTP_PORT}
  Service:         tommy-pf-tunnel
  Config:          /usr/local/etc/xray/config.json
================================================================
  To check status:  systemctl status tommy-pf-tunnel
  To restart:       systemctl restart tommy-pf-tunnel
  To stop:          systemctl stop tommy-pf-tunnel
  To view logs:     journalctl -u tommy-pf-tunnel -f
================================================================
IEOF
    chmod 600 /etc/tommy/pf-tunnel-info.txt
    info "Tunnel info saved to /etc/tommy/pf-tunnel-info.txt"
}

# ══════════════════════════════════════════════════════════════════════════════
#  SYSTEM-WIDE PROXY
# ══════════════════════════════════════════════════════════════════════════════
setup_system_proxy() {
    echo ""
    if [[ "$PROTOCOL" == "wireguard" ]]; then
        info "WireGuard tunnels all traffic at kernel level. No proxy env needed."
        return
    fi

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
    info "━━━ Testing Connection ━━━"
    sleep 3

    if [[ "$PROTOCOL" == "wireguard" ]]; then
        RESULT=$(curl -s --connect-timeout 10 https://api.ipify.org 2>/dev/null || echo "FAILED")
        info "Tunnel IP: ${RESULT}"
        if [[ "$RESULT" != "FAILED" ]]; then
            info "SUCCESS! Traffic routes through foreign server."
        else
            warn "Connection test failed."
        fi
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
        if [[ "$HTTP_RESULT" != "FAILED" ]]; then
            info "HTTP proxy OK! Tunnel IP: ${HTTP_RESULT}"
        else
            warn "HTTP proxy test failed."
        fi
    fi

    DIRECT_IP=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo "unknown")
    info "Direct IP: ${DIRECT_IP}"
    if [[ "$SOCKS_RESULT" != "FAILED" && "$SOCKS_RESULT" != "$DIRECT_IP" ]]; then
        info "SUCCESS! Your IP is hidden through Tommy!"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  SHOW SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
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

# ══════════════════════════════════════════════════════════════════════════════
#  MENU
# ══════════════════════════════════════════════════════════════════════════════
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
    echo -e "${CYAN}║  8) Port Forwarding        (Ext. Proxy Auth. Tunnel)     ║${NC}"
    echo -e "${CYAN}║  9) Exit                                                  ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "Select [1-9]: " CHOICE
    case "$CHOICE" in
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
    if ! command -v xray &>/dev/null; then
        info "Installing Xray..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>/dev/null || true
    fi
    if ! command -v xray &>/dev/null; then
        error "Xray installation failed."
    fi

    echo ""
    info "Enter credentials from foreign server (/root/xray-client-info.txt):"
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
    chmod 600 /usr/local/etc/xray/config.json

    # Stop default xray service if running, use tommy service
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true

    cat > /etc/systemd/system/tommy-xray.service <<SVCEOF
[Unit]
Description=Tommy Xray VLESS+Reality Client
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable tommy-xray
    systemctl restart tommy-xray
    sleep 2

    if systemctl is-active --quiet tommy-xray; then
        info "Xray running! SOCKS5:${SOCKS_PORT} HTTP:${HTTP_PORT}"
    else
        warn "Xray may have failed. Check: journalctl -u tommy-xray -n 30"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  2. HYSTERIA2 CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_hysteria2_client() {
    info "━━━ Hysteria2 Client ━━━"
    if ! command -v hysteria &>/dev/null; then
        info "Installing Hysteria2..."
        bash <(curl -fsSL https://get.hy2.sh/) 2>/dev/null || true
    fi
    if ! command -v hysteria &>/dev/null; then
        error "Hysteria2 installation failed."
    fi

    echo ""
    info "Enter credentials from foreign server:"
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
    chmod 600 /etc/hysteria/client.yaml

    cat > /etc/systemd/system/tommy-hysteria.service <<SEOF
[Unit]
Description=Tommy Hysteria2 Client
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria client -c /etc/hysteria/client.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SEOF

    # Stop old service if present
    systemctl stop hysteria-client 2>/dev/null || true
    systemctl disable hysteria-client 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable tommy-hysteria
    systemctl restart tommy-hysteria
    sleep 2

    if systemctl is-active --quiet tommy-hysteria; then
        info "Hysteria2 running! SOCKS5:${SOCKS_PORT} HTTP:${HTTP_PORT}"
    else
        warn "Hysteria2 may have failed. Check: journalctl -u tommy-hysteria -n 30"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  3. SHADOWSOCKS CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_shadowsocks_client() {
    info "━━━ Shadowsocks-2022 Client ━━━"
    if ! command -v sing-box &>/dev/null; then
        info "Installing sing-box..."
        bash -c "$(curl -fsSL https://sing-box.app/deb-install.sh)" 2>/dev/null || {
            local ARCH SARCH
            ARCH=$(uname -m)
            SARCH=$([[ "$ARCH" == "aarch64" ]] && echo "arm64" || echo "amd64")
            curl -Lo /tmp/sing-box.deb "https://github.com/SagerNet/sing-box/releases/latest/download/sing-box_${SARCH}.deb" 2>/dev/null || true
            [[ -f /tmp/sing-box.deb ]] && dpkg -i /tmp/sing-box.deb 2>/dev/null || true
        }
    fi

    if command -v sing-box &>/dev/null; then
        echo ""
        info "Enter credentials:"
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
        chmod 600 /etc/sing-box/client.json

        cat > /etc/systemd/system/tommy-shadowsocks.service <<SVEOF
[Unit]
Description=Tommy Shadowsocks Client
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/client.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVEOF

        # Stop old service if present
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true

        systemctl daemon-reload
        systemctl enable tommy-shadowsocks
        systemctl restart tommy-shadowsocks
        sleep 2

        if systemctl is-active --quiet tommy-shadowsocks; then
            info "Shadowsocks running! SOCKS5:${SOCKS_PORT} HTTP:${HTTP_PORT}"
        else
            warn "Shadowsocks may have failed. Check: journalctl -u tommy-shadowsocks -n 30"
        fi
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
        local TARCH
        TARCH=$([[ "$(uname -m)" == "aarch64" ]] && echo "aarch64-unknown-linux-gnu" || echo "x86_64-unknown-linux-gnu")
        curl -Lo /usr/local/bin/tuic-client "https://github.com/EAimTY/tuic/releases/latest/download/tuic-client-${TARCH}" 2>/dev/null && chmod +x /usr/local/bin/tuic-client || { warn "TUIC download failed."; return; }
    fi
    if ! command -v tuic-client &>/dev/null; then
        error "TUIC installation failed."
    fi

    echo ""
    info "Enter credentials:"
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
    chmod 600 /etc/tuic/client.json

    cat > /etc/systemd/system/tommy-tuic.service <<SVEOF
[Unit]
Description=Tommy TUIC Client
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tuic-client -c /etc/tuic/client.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVEOF

    # Stop old service if present
    systemctl stop tuic 2>/dev/null || true
    systemctl disable tuic 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable tommy-tuic
    systemctl restart tommy-tuic
    sleep 2

    if systemctl is-active --quiet tommy-tuic; then
        info "TUIC running! SOCKS5:${SOCKS_PORT}"
    else
        warn "TUIC may have failed. Check: journalctl -u tommy-tuic -n 30"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  5. WIREGUARD CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_wireguard_client() {
    info "━━━ WireGuard Client ━━━"
    if ! command -v wg &>/dev/null; then
        info "Installing WireGuard..."
        apt-get install -y wireguard-tools 2>/dev/null || yum install -y wireguard-tools 2>/dev/null || true
    fi
    if ! command -v wg &>/dev/null; then
        error "WireGuard installation failed."
    fi

    echo ""
    info "Enter/paste WireGuard client config (from foreign server):"
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

    # Enable IP forwarding
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf 2>/dev/null || true
    fi
    sysctl -p /etc/sysctl.conf 2>/dev/null || true

    wg-quick up wg0 2>/dev/null || true
    sleep 2

    if wg show wg0 &>/dev/null; then
        info "WireGuard connected! All traffic tunneled."
    else
        warn "WireGuard may have failed."
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  6. BROOK CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_brook_client() {
    info "━━━ Brook Client ━━━"
    if ! command -v brook &>/dev/null; then
        info "Installing Brook..."
        local BARCH
        BARCH=$([[ "$(uname -m)" == "aarch64" ]] && echo "arm64" || echo "amd64")
        curl -Lo /tmp/brook "https://github.com/txthinking/brook/releases/latest/download/brook_linux_${BARCH}" && chmod +x /tmp/brook && mv /tmp/brook /usr/local/bin/brook || { warn "Brook download failed."; return; }
    fi
    if ! command -v brook &>/dev/null; then
        error "Brook installation failed."
    fi

    echo ""
    info "Enter credentials:"
    read -rp "Port [9999]: " BK_PORT; BK_PORT="${BK_PORT:-9999}"
    read -rp "Password: " BK_PASS
    [[ -z "$BK_PASS" ]] && error "Password required."

    cat > /etc/systemd/system/tommy-brook.service <<SVEOF
[Unit]
Description=Tommy Brook Client
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/brook client -s ${FOREIGN_IP}:${BK_PORT} -p ${BK_PASS} --socks5 127.0.0.1:${SOCKS_PORT} --http 127.0.0.1:${HTTP_PORT}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVEOF

    # Stop old service if present
    systemctl stop brook 2>/dev/null || true
    systemctl disable brook 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable tommy-brook
    systemctl restart tommy-brook
    sleep 2

    if systemctl is-active --quiet tommy-brook; then
        info "Brook running! SOCKS5:${SOCKS_PORT} HTTP:${HTTP_PORT}"
    else
        warn "Brook may have failed. Check: journalctl -u tommy-brook -n 30"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  7. SSH TUNNEL CLIENT
# ══════════════════════════════════════════════════════════════════════════════
setup_ssh_client() {
    info "━━━ SSH Tunnel Client ━━━"
    if ! command -v autossh &>/dev/null; then
        apt-get install -y autossh 2>/dev/null || yum install -y autossh 2>/dev/null || true
    fi

    echo ""
    info "Enter SSH credentials:"
    read -rp "SSH Port [22]: " SSH_PORT; SSH_PORT="${SSH_PORT:-22}"
    read -rp "Username [tommy-tunnel]: " SSH_USER; SSH_USER="${SSH_USER:-tommy-tunnel}"
    read -rp "Password (blank=key auth): " SSH_PASSWORD

    if [[ -n "$SSH_PASSWORD" ]]; then
        if ! command -v sshpass &>/dev/null; then
            apt-get install -y sshpass 2>/dev/null || yum install -y sshpass 2>/dev/null || true
        fi
        cat > /etc/systemd/system/tommy-ssh.service <<SVEOF
[Unit]
Description=Tommy SSH Tunnel
After=network.target
Wants=network.target

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
        if [[ ! -f ~/.ssh/tommy_key ]]; then
            ssh-keygen -t ed25519 -f ~/.ssh/tommy_key -N "" -q
            info "Key generated. Add to foreign server:"
            cat ~/.ssh/tommy_key.pub
            read -rp "Press Enter after adding key..."
        fi
        cat > /etc/systemd/system/tommy-ssh.service <<SVEOF
[Unit]
Description=Tommy SSH Tunnel
After=network.target
Wants=network.target

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

    systemctl daemon-reload
    systemctl enable tommy-ssh
    systemctl restart tommy-ssh
    sleep 3

    if systemctl is-active --quiet tommy-ssh; then
        info "SSH tunnel running! SOCKS5:${SOCKS_PORT}"
    else
        warn "SSH tunnel may have failed. Check: journalctl -u tommy-ssh -n 30"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
    banner
    check_root
    show_menu
    install_deps
    harden_security

    if [[ "$PROTOCOL" == "portforward" ]]; then
        setup_port_forwarding
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

    # System-wide proxy
    setup_system_proxy

    # Test connection
    test_connection

    # Summary
    show_summary
}

main "$@"
