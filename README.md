# Tommy Tunnel v1.0.5

**Author:** hamb4
**License:** Apache License 2.0
**Repository:** [https://github.com/hamb4/tommy-tunnel](https://github.com/hamb4/tommy-tunnel)

---

## What is Tommy?

Tommy is a port forwarding tunnel tool that connects an Iranian server to an external server. Tommy **works alongside the External Proxy feature in 3x-ui** — the tunnel itself does not require x-ray. The tunnel just forwards a port between the two servers, and you enter the Iranian server IP and the tunnel port in the 3x-ui stream settings.

### How it works

```
User in Iran → Iran server (Tommy client) → Tunnel → Foreign server (Tommy server) → 3x-ui → Free Internet
```

1. **Foreign server**: Runs the script `tommy-server-setup.sh` to create a tunnel point
2. **Iran server**: Runs the script `tommy-client-iran.sh` and enters the **Connection code** from the foreign server
3. **3x-ui**: In Stream settings → External Proxy, set the Iran server IP + tunnel port
4. Users in Iran pass through the tunnel through the Iran server and connect to the 3x-ui foreign server and then the free Internet

---

## Features

- **4 tunnel methods**: SSH Tunnel, WireGuard, Gost TLS Relay, Hysteria2
- **Connection code**: The foreign server generates a unique code — just paste it into the Iran server and that's it Automatic configuration
- **Tunnel Management**: Create, list, start, stop, restart and delete tunnels
- **Service Management**: Full integration with systemd with `tommy-` prefix
- **Tunnel Removal**: Full removal of services, configs, firewall rules and registry
- **Port Validation**: If you do not enter a number, the default value is used
- **Speed/Security Profile**: Balanced, Speed ​​Priority, or Security Priority
- **BBR and Buffer Optimization**: Automatically enable BBR and adjust UDP buffer
- **No x-ray required**: Pure port forwarding — works with External Proxy in 3x-ui
---

## Prerequisite
To tunnel Gost, first install it into the Iranian server using the following command, then create a tunnel through Gost.
```bash 
bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install
```
## Hysterya2
```bash
bash <(curl -fsSL https://get.hy2.sh/)
```

---

## Quick Guide

### Step 1: External Server

```bash
bash <(curl -Ls https://raw.githubusercontent.com/hamb4/tommy-tunnel/main/tommy-server-setup.sh)
```

- Select the "Create a new tunnel" option
- Select the tunnel method
- Enter the port forwarding (same as your 3x-ui port, default: 443)
- Select the profile
- Copy the **Connection Code** that is displayed at the end

### Step 2: Iran Server

```bash
bash <(curl -LSs https://raw.githubusercontent.com/hamb4/tommy-tunnel/main/tommy-client-iran.sh)
```

- Select the "Connect via Connection Code" option (recommended)
- Paste the **Connection Code** from the external server
- Enter the tunnel name
- The tunnel will be automatically configured with all the external server settings

### Step 3: External Proxy in 3x-ui

In the 3x-ui panel On the external server:

1. Go to your inbound **Stream Settings**
2. Find the **External Proxy** section
3. Set:
- **IP**: Iran server public IP
- **Port**: The port you chose to forward (e.g. 443)

---

## Tunnel Methods

| Method | Protocol | Encryption | Speed ​​| DPI Resistance | Best for |
|------|--------|-----|------------|------------|-------------|
| SSH Tunnel | TCP | Yes (ED25519) | Good | Low | Easy and secure setup |
| WireGuard | UDP | Yes (ChaCha20) | Very fast | Medium | Maximum speed |
| Gost TLS Relay | TCP | Yes (TLS) | Good | High | Similar to HTTPS traffic |
| Hysteria2 | UDP/QUIC | Yes (TLS) | Very fast | Very high | Best DPI resistance |

---

## Connection Code System

**Connection Code** is a key feature of Tami version 1.0.5. This system ensures that all settings on the Iranian server **exactly match** the foreign server.

### How it works

1. When creating a tunnel to a foreign server, Tommy generates a **base64-encoded connection code**

2. This code contains all the tunnel settings: method, server IP, port forwarding, profile and information specific to each method (keys, passwords, ports)

3. On the Iranian server, just paste the code and Tommy will configure everything automatically

4. No manual errors — if the code is valid, the settings are guaranteed to match

### Connection code security

- The connection code is stored in the path `/root/tommy-<name>-connection-code.txt` on the foreign server with access `600`

- SSH private keys inside the code are base64-encoded
- Treat connection codes like sensitive information — anyone with the code can connect to your tunnel

---

## Service management

All tunnels are created by systemd services with the `tommy-` prefix They do:

```bash
# Check tunnel status
systemctl status tommy-tunnel1

# Start tunnel
systemctl start tommy-tunnel1

# Stop tunnel
systemctl stop tommy-tunnel1

# Restart tunnel
systemctl restart tommy-tunnel1

# View logs
journalctl -u tommy-tunnel1 -n 50
```

Or use the built-in **Service Management** (option 4 on foreign server, option 5 on Iranian server) for interactive menu.

---

## Tunnel Removal

Tommy cleans up everything properly when removing a tunnel:

1. Stops and disables the systemd service
2. Removes the service file from `/etc/systemd/system/`
3. For WireGuard: Stops the port forwarding helper service as well
4. Removes the tunnel config folder from `/etc/tommy/<name>/`
5. Removes the connection code file from `/root/`
6. Closes firewall ports
7. Removes the tunnel from the registry

---

## File Paths

| File | Path |
|------|------|
| Tunnel config | `/etc/tommy/<tunnel-name>/` |
| Tunnel info | `/etc/tommy/<tunnel-name>/tunnel-info.txt` |
| Tunnel Registry | `/etc/tommy/tunnels.registry` |
| Connection code | `/root/tommy-<name>-connection-code.txt` |
| Systemd services | `/etc/systemd/system/tommy-<name>.service` |

---

## Troubleshooting

### Tunnel "started" but not working

1. Check that the service is actually running: `systemctl status tommy-<name>`
2. Check the logs: `journalctl -u tommy-<name> -n 50`
3. Check the port: `ss -tlnp | grep <port>`
4. Make sure the firewall allows the port

### Connection code not working

1. Make sure you copied the entire code (it's a long base64 string)
2. The code is version-dependent — both servers must be using Tommy v1.0.5
3. Use the "Manual Setup" option instead

### WireGuard tunnel fails

1. Make sure the WireGuard kernel module is available: `modprobe wireguard`
2. Check that the UDP port is open in the firewall
3. Check the client config: `cat /etc/tommy/<name>/wg0.conf`

---

## Version history

- **v1.0.5** — Connection code system, tunnel name caching, port validation, proper tunnel removal, service management improvements
