#!/usr/bin/env bash
# Tommy Tunnel - fast/stable WireGuard + TCP relay tunnel
# Project: https://github.com/hamb4/tommy-tunnel
# Usage: sudo bash tommy-tunnel.sh
set -Eeuo pipefail

APP="tommy"
BASE_DIR="/etc/${APP}"
REGISTRY="${BASE_DIR}/registry"
WG_NET_DEFAULT="10.88.0.0/30"
SERVER_WG_IP_DEFAULT="10.88.0.1"
CLIENT_WG_IP_DEFAULT="10.88.0.2"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

log(){ echo -e "${GREEN}[${APP}]${NC} $*"; }
warn(){ echo -e "${YELLOW}[warn]${NC} $*"; }
err(){ echo -e "${RED}[error]${NC} $*" >&2; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }; }

safe_name(){
  local n="${1:-tommy0}"
  n="$(echo "$n" | tr -cd '[:alnum:]_-')"
  [[ -n "$n" ]] || n="tommy0"
  echo "$n"
}

prompt_default(){
  local prompt="$1" default="$2" var
  read -r -p "$prompt [$default]: " var || true
  echo "${var:-$default}"
}

install_deps(){
  log "Installing dependencies (wireguard, socat, jq, curl)..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y wireguard wireguard-tools socat jq curl iproute2 iptables ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y epel-release || true
    dnf install -y wireguard-tools socat jq curl iproute iptables ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y wireguard-tools socat jq curl iproute iptables ca-certificates
  else
    err "Unsupported Linux distribution. Install wireguard-tools, socat, jq, curl manually."
    exit 1
  fi
}

optimize_sysctl(){
  log "Applying TCP/BBR stability optimizations..."
  cat >/etc/sysctl.d/99-tommy-tunnel.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.ip_forward=1
net.core.rmem_max=268435456
net.core.wmem_max=268435456
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
EOF
  sysctl --system >/dev/null || warn "Some sysctl values could not be applied on this kernel."
}

open_firewall(){
  local proto="$1" port="$2"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    ufw allow "${port}/${proto}" || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${port}/${proto}" || true
    firewall-cmd --reload || true
  fi
}

b64enc(){ base64 -w0 2>/dev/null || base64 | tr -d '\n'; }
b64dec(){ base64 -d 2>/dev/null || base64 -D; }

make_service_foreign(){
  local name="$1" bind_ip="$2" listen_port="$3" target_host="$4" target_port="$5"
  cat >"/etc/systemd/system/${APP}-${name}-relay.service" <<EOF
[Unit]
Description=Tommy Tunnel foreign relay ${name}
After=network-online.target wg-quick@${APP}-${name}.service
Wants=network-online.target
Requires=wg-quick@${APP}-${name}.service

[Service]
Type=simple
ExecStart=/usr/bin/socat -d -d TCP-LISTEN:${listen_port},bind=${bind_ip},reuseaddr,fork,keepalive,nodelay TCP:${target_host}:${target_port},keepalive,nodelay
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP}-${name}-relay
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

make_service_iran(){
  local name="$1" public_port="$2" server_wg_ip="$3" remote_port="$4"
  cat >"/etc/systemd/system/${APP}-${name}-public.service" <<EOF
[Unit]
Description=Tommy Tunnel Iran public listener ${name}
After=network-online.target wg-quick@${APP}-${name}.service
Wants=network-online.target
Requires=wg-quick@${APP}-${name}.service

[Service]
Type=simple
ExecStart=/usr/bin/socat -d -d TCP-LISTEN:${public_port},bind=0.0.0.0,reuseaddr,fork,keepalive,nodelay TCP:${server_wg_ip}:${remote_port},keepalive,nodelay
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP}-${name}-public
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

create_foreign(){
  need_root; install_deps; optimize_sysctl
  mkdir -p "$BASE_DIR" "$REGISTRY"

  local name public_ip wg_port target_host target_port remote_port mtu profile
  name=$(safe_name "$(prompt_default 'Tunnel name' 'tommy0')")
  public_ip=$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)
  public_ip=$(prompt_default 'Foreign server public IPv4/domain' "${public_ip:-YOUR_FOREIGN_IP}")
  wg_port=$(prompt_default 'WireGuard UDP listen port' '51820')
  target_host=$(prompt_default 'Foreign local target host (3x-ui/xray usually 127.0.0.1)' '127.0.0.1')
  target_port=$(prompt_default 'Foreign local target TCP port (3x-ui/xray inbound)' '443')
  remote_port=$(prompt_default 'Port inside the tunnel on foreign side' "$target_port")
  echo "Profile: 1) balanced  2) speed  3) stability"
  read -r -p 'Choose profile [1]: ' profile || true; profile=${profile:-1}
  case "$profile" in
    2) mtu=1420 ;;
    3) mtu=1280 ;;
    *) mtu=1380 ;;
  esac

  umask 077
  local server_priv server_pub client_priv client_pub wg_conf
  server_priv=$(wg genkey); server_pub=$(printf '%s' "$server_priv" | wg pubkey)
  client_priv=$(wg genkey); client_pub=$(printf '%s' "$client_priv" | wg pubkey)
  wg_conf="/etc/wireguard/${APP}-${name}.conf"

  cat >"$wg_conf" <<EOF
[Interface]
Address = ${SERVER_WG_IP_DEFAULT}/30
ListenPort = ${wg_port}
PrivateKey = ${server_priv}
MTU = ${mtu}

[Peer]
PublicKey = ${client_pub}
AllowedIPs = ${CLIENT_WG_IP_DEFAULT}/32
EOF

  make_service_foreign "$name" "$SERVER_WG_IP_DEFAULT" "$remote_port" "$target_host" "$target_port"
  systemctl daemon-reload
  systemctl enable --now "wg-quick@${APP}-${name}" "${APP}-${name}-relay"
  open_firewall udp "$wg_port"

  cat >"${REGISTRY}/${name}.env" <<EOF
ROLE=foreign
WG_PORT=${wg_port}
TARGET=${target_host}:${target_port}
REMOTE_PORT=${remote_port}
EOF

  local code json
  json=$(jq -nc \
    --arg name "$name" --arg server_ip "$public_ip" --arg wg_port "$wg_port" \
    --arg server_pub "$server_pub" --arg client_priv "$client_priv" \
    --arg server_wg_ip "$SERVER_WG_IP_DEFAULT" --arg client_wg_ip "$CLIENT_WG_IP_DEFAULT" \
    --arg remote_port "$remote_port" --arg mtu "$mtu" \
    '{v:1,app:"tommy-tunnel",name:$name,server_ip:$server_ip,wg_port:$wg_port,server_pub:$server_pub,client_priv:$client_priv,server_wg_ip:$server_wg_ip,client_wg_ip:$client_wg_ip,remote_port:$remote_port,mtu:$mtu}')
  code=$(printf '%s' "$json" | b64enc)

  log "Foreign side is ready. Save this Connection Code securely:"
  echo
  echo "$code"
  echo
  warn "The code contains a WireGuard client private key. Anyone with it can connect to this tunnel."
}

connect_iran(){
  need_root; install_deps; optimize_sysctl
  mkdir -p "$BASE_DIR" "$REGISTRY"

  local code json name server_ip wg_port server_pub client_priv server_wg_ip client_wg_ip remote_port mtu public_port wg_conf
  read -r -p 'Paste Tommy Connection Code: ' code
  json=$(printf '%s' "$code" | tr -d '[:space:]' | b64dec)
  [[ "$(jq -r '.app // empty' <<<"$json")" == "tommy-tunnel" ]] || { err "Invalid Tommy code."; exit 1; }

  name=$(safe_name "$(prompt_default 'Local tunnel name' "$(jq -r '.name' <<<"$json")")")
  server_ip=$(jq -r '.server_ip' <<<"$json")
  wg_port=$(jq -r '.wg_port' <<<"$json")
  server_pub=$(jq -r '.server_pub' <<<"$json")
  client_priv=$(jq -r '.client_priv' <<<"$json")
  server_wg_ip=$(jq -r '.server_wg_ip' <<<"$json")
  client_wg_ip=$(jq -r '.client_wg_ip' <<<"$json")
  remote_port=$(jq -r '.remote_port' <<<"$json")
  mtu=$(jq -r '.mtu // "1380"' <<<"$json")
  public_port=$(prompt_default 'Iran server public TCP listen port for users/3x-ui external proxy' "$remote_port")

  umask 077
  wg_conf="/etc/wireguard/${APP}-${name}.conf"
  cat >"$wg_conf" <<EOF
[Interface]
Address = ${client_wg_ip}/30
PrivateKey = ${client_priv}
MTU = ${mtu}

[Peer]
PublicKey = ${server_pub}
AllowedIPs = ${server_wg_ip}/32
Endpoint = ${server_ip}:${wg_port}
PersistentKeepalive = 25
EOF

  make_service_iran "$name" "$public_port" "$server_wg_ip" "$remote_port"
  systemctl daemon-reload
  systemctl enable --now "wg-quick@${APP}-${name}" "${APP}-${name}-public"
  open_firewall tcp "$public_port"

  cat >"${REGISTRY}/${name}.env" <<EOF
ROLE=iran
SERVER=${server_ip}:${wg_port}
PUBLIC_PORT=${public_port}
REMOTE=${server_wg_ip}:${remote_port}
EOF

  log "Iran side is ready. Point users or 3x-ui External Proxy to:"
  echo "  $(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'):${public_port}"
}

list_tunnels(){
  need_root
  echo "Tommy services:"
  systemctl list-units --type=service --all "${APP}-*.service" --no-pager || true
  echo
  echo "WireGuard interfaces:"
  wg show || true
}

restart_tunnel(){
  need_root
  local name; name=$(safe_name "$(prompt_default 'Tunnel name to restart' 'tommy0')")
  systemctl restart "wg-quick@${APP}-${name}" || true
  systemctl restart "${APP}-${name}-relay" 2>/dev/null || true
  systemctl restart "${APP}-${name}-public" 2>/dev/null || true
  log "Restarted ${name}."
}

remove_tunnel(){
  need_root
  local name; name=$(safe_name "$(prompt_default 'Tunnel name to remove' 'tommy0')")
  warn "This will remove ${name} services and configs from this server only."
  read -r -p 'Continue? [y/N]: ' yn || true
  [[ "$yn" =~ ^[Yy]$ ]] || exit 0
  systemctl disable --now "${APP}-${name}-relay" 2>/dev/null || true
  systemctl disable --now "${APP}-${name}-public" 2>/dev/null || true
  systemctl disable --now "wg-quick@${APP}-${name}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${APP}-${name}-relay.service" "/etc/systemd/system/${APP}-${name}-public.service" "/etc/wireguard/${APP}-${name}.conf" "${REGISTRY}/${name}.env"
  systemctl daemon-reload
  log "Removed ${name}."
}

status_tunnel(){
  need_root
  local name; name=$(safe_name "$(prompt_default 'Tunnel name' 'tommy0')")
  systemctl --no-pager status "wg-quick@${APP}-${name}" || true
  systemctl --no-pager status "${APP}-${name}-relay" 2>/dev/null || true
  systemctl --no-pager status "${APP}-${name}-public" 2>/dev/null || true
  wg show "${APP}-${name}" || true
}

menu(){
  cat <<EOF

Tommy Tunnel - WireGuard TCP relay
1) Foreign server: create tunnel and connection code
2) Iran server: connect using connection code
3) List tunnels/status summary
4) Restart tunnel
5) Remove tunnel
6) Detailed status
0) Exit
EOF
  read -r -p 'Select: ' choice
  case "${choice:-}" in
    1) create_foreign ;;
    2) connect_iran ;;
    3) list_tunnels ;;
    4) restart_tunnel ;;
    5) remove_tunnel ;;
    6) status_tunnel ;;
    0) exit 0 ;;
    *) err "Invalid choice"; exit 1 ;;
  esac
}

need_root
menu
