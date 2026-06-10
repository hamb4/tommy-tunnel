# tommy-tunnel
# Tommy v3.0

<p align="center">
<strong>Secure Tunnel — Iran Server ↔ Foreign Server</strong><br>
Author: <strong>hamb4</strong> | Repository: https://github.com/hamb4/tommy-tunnel
</p>

---

## What is Tommy?

Tommy is an automated tunneling tool that connects your Iranian server to a foreign server with high speed, stability, and complete IP obfuscation. It supports 7 tunnel protocols and 4 port forwarding methods — all via interactive scripts without the need for manual editing.

## Protocols

| # | Protocol | Transmission | Obfuscation | Speed ​​| Suitable for |
|---|-------|--------|------------|-------|
| 1 | **VLESS+Reality** | TCP | ★★★★★ | ★★★★ | Best obfuscation, undetectable |
| 2 | **Hysteria2** | UDP/QUIC | ★★★★ | ★★★★★ | Highest speed when TCP is limited |
| 3 | **Shadowsocks-2022** | TCP+UDP | ★★★ | ★★★★ | Tested and reliable |
| 4 | **TUIC v5** | UDP/QUIC | ★★★ | ★★★★ | Low latency QUIC |
| 5 | **WireGuard** | UDP | ★★ | ★★★★★ | Kernel level VPN, fastest |
| 6 | **Brook** | TCP+UDP | ★★★ | ★★★ | Lightweight and simple |
| 7 | **SSH Tunnel** | TCP | ★★ | ★★ | No additional software required |

## Port Forwarding

Tommy has integrated port forwarding **into every protocol**. After setting up each tunnel, you will be asked if you want to forward specific ports.

| Method | Protocols | How it works |
|------|------------|------|
| **Xray dokodemo-door** | VLESS+Reality | Add transparent port inbounds to Xray config |
| **SSH -L / -R** | SSH Tunnel | Local and remote forwarding via autossh |
| **iptables DNAT** | WireGuard | Kernel level NAT forwarding (TCP+UDP) |
| **socat over SOCKS5** | Hysteria2, SS, TUIC, Brook | TCP relay over SOCKS5 proxy |

### Port Forwarding Modes
- **Local (-L)**: Forward a port on the Iranian server → Remote host via tunnel
- **Remote (-R)**: Forward a port on the foreign server → Return to the Iranian server
- **Multiple rules**: Forward multiple ports simultaneously

## Quick start

### Step 1: Foreign server

```bash
# Upload and run on the foreign server
chmod +x tommy-server-setup.sh
sudo ./tommy-server-setup.sh
```

Select protocols (suggested: `1 2 3`). The script prints the connection links and saves the information in `/root/*-client-info.txt`.

### Step 2: Iran Server

```bash
# Upload and run on Iranian server
chmod +x tommy-client-iran.sh
sudo ./tommy-client-iran.sh
```

Select the same protocol, enter the connection information from step 1. Script:
1. Client starts tunnel
2. Asks about port forwarding → configures if needed
3. Asks about global proxy → configures if needed
4. Automatically tests the connection

### Step 3: Verify

```bash
# Check the new IP (should show the IP of the foreign server)
curl -x socks5h://127.0.0.1:10808 https://api.ipify.org

# Or with HTTP proxy
curl -x http://127.0.0.1:10809 https://api.ipify.org

# Compare with direct IP
curl https://api.ipify.org
```

## Examples of port forwarding

### Accessing a foreign database from Iran
```
Forward rule: 3306:db.example.com:3306
→ Now connect to the Iranian server from localhost:3306
```

### Show local web service via foreign IP
```
Remote forward: foreign_ip:8080 → localhost:3000
→ Accessing http://foreign_ip:8080 reaches your local server
```

### Multiple ports at the same time
```
Rule 1: 3306:db.example.com:3306
Rule 2: 6379:redis.example.com:6379
Rule 3: 8080:api.service.com:443
```

## Files

| File | Usage |
|------|-------|
| `tommy-server-setup.sh` | Run on foreign server (create tunnel servers) |
| `tommy-client-iran.sh` | Run on Iran server (create tunnel clients + forward port) |

## Foreign server location

Choose a foreign server close to Iran for the lowest latency:

| Location | Latency | Description |
|------|------|--------|
| Turkey (Istanbul) | 20-40ms | Nearest, some ISP restrictions |
| Germany (Frankfurt) | 60-90ms | Good connection |
| Netherlands (Amsterdam) | 70-100ms | Popular for privacy |
| France (Paris) | 65-95ms | Good Middle East routing |

## Manage Services

All services use the `tommy-` prefix:

```bash
# Check status
systemctl status tommy-xray
systemctl status tommy-hysteria
systemctl status tommy-shadowsocks
systemctl status tommy-tuic
systemctl status tommy-brook
systemctl status tommy-ssh

# Restart
systemctl restart tommy-xray

# View logs
journalctl -u tommy-xray -f

# Forward port services
systemctl status tommy-pf-ssh-3306
systemctl status tommy-pf-socat-8080
```

## Security Tips

- VLESS+Reality has the most obfuscation — traffic looks like regular HTTPS
- Hysteria2 pretends to be a web server when probed
- SSH tunnels are detectable but do not require additional software
- WireGuard is the fastest but most detectable is
- Always use SSH key authentication
- Change connection information periodically

## Prerequisites

- **Outgoing server**: Ubuntu 20.04+ / Debian 11+ / CentOS 8+ / Rocky Linux
- **Iranian server**: Same OS requirements
- **Root access** on both servers
- **Open outbound ports** on the outgoing server (443/TCP, 8443/UDP, etc.)

## License

MIT License — Free to use, modify, and distribute.

---

**Tommy v3.0** — by **hamb4**
