#!/usr/bin/env bash
# Tommy Tunnel Strong - multi-transport tunnel for restrictive/unstable networks
# Project: https://github.com/hamb4/tommy-tunnel
# Run on BOTH servers: sudo bash tommy-tunnel-strong.sh
set -Eeuo pipefail

APP="tommy"
BASE_DIR="/etc/${APP}"
REGISTRY="${BASE_DIR}/registry"
BIN_DIR="/usr/local/bin"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log(){ echo -e "${GREEN}[${APP}]${NC} $*"; }
info(){ echo -e "${CYAN}[info]${NC} $*"; }
warn(){ echo -e "${YELLOW}[warn]${NC} $*"; }
err(){ echo -e "${RED}[error]${NC} $*" >&2; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }; }

safe_name(){ local n="${1:-tommy0}"; n="$(echo "$n" | tr -cd '[:alnum:]_-')"; [[ -n "$n" ]] || n="tommy0"; echo "$n"; }
prompt_default(){ local p="$1" d="$2" v; read -r -p "$p [$d]: " v || true; echo "${v:-$d}"; }
rand_hex(){ openssl rand -hex "${1:-12}"; }
b64enc(){ base64 -w0 2>/dev/null || base64 | tr -d '\n'; }
b64dec(){ base64 -d 2>/dev/null || base64 -D; }

install_deps(){
  log "Installing base dependencies..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl jq openssl ca-certificates iproute2 iptables socat gzip tar coreutils openssh-client openssh-server
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl jq openssl ca-certificates iproute iptables socat gzip tar coreutils openssh-clients openssh-server
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y curl jq openssl ca-certificates iproute iptables socat gzip tar coreutils openssh-clients openssh-server
  else
    err "Unsupported distribution. Install curl jq openssl socat openssh manually."
    exit 1
  fi
}

optimize_network(){
  log "Applying high-loss / unstable-network TCP tuning..."
  cat >/etc/sysctl.d/99-tommy-strong.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_keepalive_time=45
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_syn_retries=5
net.ipv4.tcp_synack_retries=5
net.ipv4.ip_local_port_range=10000 65000
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
net.core.netdev_max_backlog=250000
net.core.rmem_max=268435456
net.core.wmem_max=268435456
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
EOF
  sysctl --system >/dev/null || warn "Some sysctl options are unsupported by this kernel. Continuing."
}

open_firewall(){
  local proto="$1" port="$2"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then ufw allow "${port}/${proto}" || true; fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then firewall-cmd --permanent --add-port="${port}/${proto}" || true; firewall-cmd --reload || true; fi
}

detect_public_ip(){ curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true; }

make_cert(){
  local name="$1" domain="$2" dir="${BASE_DIR}/${name}"
  mkdir -p "$dir"
  if [[ ! -s "${dir}/cert.pem" || ! -s "${dir}/key.pem" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
      -subj "/CN=${domain}" \
      -keyout "${dir}/key.pem" -out "${dir}/cert.pem" >/dev/null 2>&1
    chmod 600 "${dir}/key.pem"
  fi
}

install_gost(){
  if command -v gost >/dev/null 2>&1; then return 0; fi
  log "Installing GOST..."
  bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install
  command -v gost >/dev/null 2>&1 || { err "GOST install failed."; exit 1; }
}

install_chisel(){
  if command -v chisel >/dev/null 2>&1; then return 0; fi
  log "Installing chisel..."
  local arch url tmp
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv7) arch="armv7" ;;
    *) err "Unsupported CPU architecture for chisel: $(uname -m)"; exit 1 ;;
  esac
  url=$(curl -fsSL https://api.github.com/repos/jpillora/chisel/releases/latest | jq -r ".assets[].browser_download_url" | grep "linux_${arch}.*gz$" | head -n1)
  [[ -n "$url" ]] || { err "Could not find chisel Linux ${arch} release."; exit 1; }
  tmp="/tmp/chisel.gz"
  curl -fL "$url" -o "$tmp"
  gzip -dc "$tmp" >"${BIN_DIR}/chisel"
  chmod +x "${BIN_DIR}/chisel"
  command -v chisel >/dev/null 2>&1 || { err "chisel install failed."; exit 1; }
}

service_common(){ cat <<EOF
Restart=always
RestartSec=2
StartLimitIntervalSec=0
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal
EOF
}

create_foreign_chisel(){
  install_chisel
  local name="$1" server_addr="$2" listen_port="$3" target_host="$4" target_port="$5" user pass domain bin dir code json
  user="u$(rand_hex 4)"; pass="p$(rand_hex 16)"; domain="${server_addr}"
  make_cert "$name" "$domain"
  bin=$(command -v chisel); dir="${BASE_DIR}/${name}"
  cat >"/etc/systemd/system/${APP}-${name}.service" <<EOF
[Unit]
Description=Tommy Strong chisel HTTPS tunnel ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${bin} server --host 0.0.0.0 --port ${listen_port} --auth ${user}:${pass} --tls-cert ${dir}/cert.pem --tls-key ${dir}/key.pem --keepalive 10s
$(service_common)

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable --now "${APP}-${name}.service"; open_firewall tcp "$listen_port"
  json=$(jq -nc --arg app "tommy-tunnel" --arg method "chisel_https" --arg name "$name" --arg server "$server_addr" --arg port "$listen_port" --arg user "$user" --arg pass "$pass" --arg th "$target_host" --arg tp "$target_port" '{v:2,app:$app,method:$method,name:$name,server:$server,port:$port,user:$user,pass:$pass,target_host:$th,target_port:$tp}')
  code=$(printf '%s' "$json" | b64enc)
  print_code "$code" "chisel HTTPS/WebSocket"
}

create_foreign_gost(){
  local method="$1" name="$2" server_addr="$3" listen_port="$4" target_host="$5" target_port="$6" user pass path proto bin dir url code json
  install_gost
  user="u$(rand_hex 4)"; pass="p$(rand_hex 16)"; path="/$(rand_hex 8)"
  make_cert "$name" "$server_addr"
  bin=$(command -v gost); dir="${BASE_DIR}/${name}"
  if [[ "$method" == "gost_wss" ]]; then
    proto="relay+wss"
    url="${proto}://${user}:${pass}@:${listen_port}/${target_host}:${target_port}?path=${path}&cert=${dir}/cert.pem&key=${dir}/key.pem"
  else
    proto="relay+tls"
    url="${proto}://${user}:${pass}@:${listen_port}/${target_host}:${target_port}?cert=${dir}/cert.pem&key=${dir}/key.pem"
  fi
  cat >"/etc/systemd/system/${APP}-${name}.service" <<EOF
[Unit]
Description=Tommy Strong ${method} tunnel ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${bin} -L ${url}
$(service_common)

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable --now "${APP}-${name}.service"; open_firewall tcp "$listen_port"
  json=$(jq -nc --arg app "tommy-tunnel" --arg method "$method" --arg name "$name" --arg server "$server_addr" --arg port "$listen_port" --arg user "$user" --arg pass "$pass" --arg path "$path" '{v:2,app:$app,method:$method,name:$name,server:$server,port:$port,user:$user,pass:$pass,path:$path}')
  code=$(printf '%s' "$json" | b64enc)
  print_code "$code" "$method"
}

create_foreign_ssh(){
  local name="$1" server_addr="$2" ssh_port target_host="$3" target_port="$4" ssh_user keydir pub priv code json ak
  ssh_port=$(prompt_default 'SSH port on foreign server' '22')
  ssh_user="tommy_${name}"
  keydir="${BASE_DIR}/${name}/ssh"; mkdir -p "$keydir"
  ssh-keygen -t ed25519 -N '' -f "${keydir}/id_ed25519" -C "tommy-${name}" >/dev/null
  pub=$(cat "${keydir}/id_ed25519.pub"); priv=$(cat "${keydir}/id_ed25519")
  if ! id "$ssh_user" >/dev/null 2>&1; then useradd -m -s /bin/bash "$ssh_user"; passwd -l "$ssh_user" >/dev/null 2>&1 || true; fi
  install -d -m 700 -o "$ssh_user" -g "$ssh_user" "/home/${ssh_user}/.ssh"
  ak="permitopen=\"${target_host}:${target_port}\",no-pty,no-X11-forwarding,no-agent-forwarding,no-user-rc ${pub}"
  echo "$ak" >"/home/${ssh_user}/.ssh/authorized_keys"
  chown "$ssh_user:$ssh_user" "/home/${ssh_user}/.ssh/authorized_keys"; chmod 600 "/home/${ssh_user}/.ssh/authorized_keys"
  systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
  open_firewall tcp "$ssh_port"
  json=$(jq -nc --arg app "tommy-tunnel" --arg method "ssh_tcp" --arg name "$name" --arg server "$server_addr" --arg port "$ssh_port" --arg user "$ssh_user" --arg key "$priv" --arg th "$target_host" --arg tp "$target_port" '{v:2,app:$app,method:$method,name:$name,server:$server,port:$port,user:$user,private_key:$key,target_host:$th,target_port:$tp}')
  code=$(printf '%s' "$json" | b64enc)
  print_code "$code" "SSH TCP fallback"
}

print_code(){
  local code="$1" method="$2"
  log "Foreign endpoint is ready using ${method}."
  echo
  echo "================ TOMMY CONNECTION CODE ================"
  echo "$code"
  echo "======================================================="
  echo
  warn "Keep this code private. It contains tunnel credentials."
}

foreign_menu(){
  need_root; install_deps; optimize_network; mkdir -p "$BASE_DIR" "$REGISTRY"
  local detected server_addr name listen_port target_host target_port method
  name=$(safe_name "$(prompt_default 'Tunnel name' 'tommy0')")
  detected=$(detect_public_ip)
  if [[ -n "$detected" ]]; then
    server_addr=$(prompt_default 'Foreign server public IP/domain for Iran server to connect to' "$detected")
  else
    server_addr=$(prompt_default 'Foreign server public IP/domain for Iran server to connect to' 'YOUR_FOREIGN_IP_OR_DOMAIN')
  fi
  target_host=$(prompt_default 'Foreign target host, usually local 3x-ui/xray' '127.0.0.1')
  target_port=$(prompt_default 'Foreign target TCP port, usually your inbound port' '443')
  echo
  echo "Choose transport for restrictive networks:"
  echo "1) chisel_https  - recommended: HTTPS/WebSocket over TCP, stable behind bad routes"
  echo "2) gost_wss      - GOST Relay over WebSocket+TLS, good anti-filter shape"
  echo "3) gost_tls      - GOST Relay over pure TLS/TCP, fast and simple"
  echo "4) ssh_tcp       - fallback: ordinary SSH local forwarding over TCP"
  read -r -p 'Method [1]: ' method; method=${method:-1}
  case "$method" in
    1) listen_port=$(prompt_default 'Foreign tunnel TCP listen port' '443'); create_foreign_chisel "$name" "$server_addr" "$listen_port" "$target_host" "$target_port" ;;
    2) listen_port=$(prompt_default 'Foreign tunnel TCP listen port' '443'); create_foreign_gost "gost_wss" "$name" "$server_addr" "$listen_port" "$target_host" "$target_port" ;;
    3) listen_port=$(prompt_default 'Foreign tunnel TCP listen port' '8443'); create_foreign_gost "gost_tls" "$name" "$server_addr" "$listen_port" "$target_host" "$target_port" ;;
    4) create_foreign_ssh "$name" "$server_addr" "$target_host" "$target_port" ;;
    *) err "Invalid method."; exit 1 ;;
  esac
}

connect_iran(){
  need_root; install_deps; optimize_network; mkdir -p "$BASE_DIR" "$REGISTRY"
  local code json method name server port user pass path public_port target_host target_port bin url keyfile
  read -r -p 'Paste Tommy Connection Code: ' code
  json=$(printf '%s' "$code" | tr -d '[:space:]' | b64dec)
  [[ "$(jq -r '.app // empty' <<<"$json")" == "tommy-tunnel" ]] || { err "Invalid Tommy code."; exit 1; }
  method=$(jq -r '.method' <<<"$json")
  name=$(safe_name "$(prompt_default 'Local tunnel name' "$(jq -r '.name' <<<"$json")")")
  server=$(jq -r '.server' <<<"$json"); port=$(jq -r '.port' <<<"$json")
  public_port=$(prompt_default 'Iran server public TCP listen port for users / 3x-ui External Proxy' '443')

  case "$method" in
    chisel_https)
      install_chisel
      user=$(jq -r '.user' <<<"$json"); pass=$(jq -r '.pass' <<<"$json"); target_host=$(jq -r '.target_host' <<<"$json"); target_port=$(jq -r '.target_port' <<<"$json"); bin=$(command -v chisel)
      cat >"/etc/systemd/system/${APP}-${name}.service" <<EOF
[Unit]
Description=Tommy Strong Iran chisel client ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${bin} client --auth ${user}:${pass} --tls-skip-verify --keepalive 10s https://${server}:${port} 0.0.0.0:${public_port}:${target_host}:${target_port}
$(service_common)

[Install]
WantedBy=multi-user.target
EOF
      ;;
    gost_wss|gost_tls)
      install_gost
      user=$(jq -r '.user' <<<"$json"); pass=$(jq -r '.pass' <<<"$json"); path=$(jq -r '.path // empty' <<<"$json"); bin=$(command -v gost)
      if [[ "$method" == "gost_wss" ]]; then url="relay+wss://${user}:${pass}@${server}:${port}?path=${path}&secure=false"; else url="relay+tls://${user}:${pass}@${server}:${port}?secure=false"; fi
      cat >"/etc/systemd/system/${APP}-${name}.service" <<EOF
[Unit]
Description=Tommy Strong Iran ${method} client ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${bin} -L tcp://:${public_port} -F ${url}
$(service_common)

[Install]
WantedBy=multi-user.target
EOF
      ;;
    ssh_tcp)
      target_host=$(jq -r '.target_host' <<<"$json"); target_port=$(jq -r '.target_port' <<<"$json"); user=$(jq -r '.user' <<<"$json")
      keyfile="${BASE_DIR}/${name}/id_ed25519"; mkdir -p "${BASE_DIR}/${name}"; jq -r '.private_key' <<<"$json" >"$keyfile"; chmod 600 "$keyfile"
      cat >"/etc/systemd/system/${APP}-${name}.service" <<EOF
[Unit]
Description=Tommy Strong Iran SSH TCP client ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ssh -N -T -i ${keyfile} -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes -o StrictHostKeyChecking=accept-new -L 0.0.0.0:${public_port}:${target_host}:${target_port} -p ${port} ${user}@${server}
$(service_common)

[Install]
WantedBy=multi-user.target
EOF
      ;;
    *) err "Unknown method in code: ${method}"; exit 1 ;;
  esac
  systemctl daemon-reload; systemctl enable --now "${APP}-${name}.service"; open_firewall tcp "$public_port"
  log "Iran side is ready. Use this in users/3x-ui External Proxy:"
  echo "  $(detect_public_ip || true):${public_port}"
}

list_tunnels(){ need_root; systemctl list-units --type=service --all "${APP}-*.service" --no-pager || true; }
status_tunnel(){ need_root; local name; name=$(safe_name "$(prompt_default 'Tunnel name' 'tommy0')"); systemctl --no-pager status "${APP}-${name}.service" || true; }
restart_tunnel(){ need_root; local name; name=$(safe_name "$(prompt_default 'Tunnel name to restart' 'tommy0')"); systemctl restart "${APP}-${name}.service"; log "Restarted ${name}."; }
remove_tunnel(){
  need_root; local name; name=$(safe_name "$(prompt_default 'Tunnel name to remove' 'tommy0')")
  warn "This removes Tommy config/service from THIS server only."
  read -r -p 'Continue? [y/N]: ' yn; [[ "$yn" =~ ^[Yy]$ ]] || exit 0
  systemctl disable --now "${APP}-${name}.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/${APP}-${name}.service"; rm -rf "${BASE_DIR:?}/${name}"
  systemctl daemon-reload; log "Removed ${name}."
}

main_menu(){
  cat <<EOF

Tommy Tunnel Strong
Run this same script on both servers.

1) Set up FOREIGN server endpoint  (run this ON the foreign server)
2) Connect IRAN server to endpoint (run this ON the Iran server)
3) List Tommy services
4) Restart tunnel
5) Remove tunnel
6) Status/logs
0) Exit
EOF
  read -r -p 'Select: ' c
  case "${c:-}" in
    1) foreign_menu ;;
    2) connect_iran ;;
    3) list_tunnels ;;
    4) restart_tunnel ;;
    5) remove_tunnel ;;
    6) status_tunnel ;;
    0) exit 0 ;;
    *) err "Invalid choice."; exit 1 ;;
  esac
}

need_root
main_menu
