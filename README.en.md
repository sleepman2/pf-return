# pf-return

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](#compatibility)
[![Shell](https://img.shields.io/badge/shell-bash-4EAA25.svg)]()

**Fixes inbound port-forwarding when LAN hosts use a sidecar router as their default gateway.**

English | [简体中文](README.md)

---

## Table of Contents

- [The Problem](#the-problem)
- [How It Works](#how-it-works)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [Configuration](#configuration)
- [Verification](#verification)
- [Compatibility](#compatibility)
- [Alternatives](#alternatives)
- [FAQ](#faq)
- [Security](#security)
- [Contributing](#contributing)
- [License](#license)

---

## The Problem

A common homelab layout:

```
                    ┌────────────────────┐
   Internet ───────▶│ Main router .1      │  NAT + port forwarding
                    └─────────┬──────────┘
                              │ LAN
              ┌───────────────┼────────────────┐
              │               │                │
      ┌───────▼───────┐ ┌─────▼─────┐  ┌───────▼───────┐
      │ Sidecar .21    │ │ Hypervisor │  │ Target .20    │
      │ transparent    │ │ .30        │  │ service :8080 │
      │ proxy          │ │            │  │               │
      └───────▲───────┘ └───────────┘  └───────────────┘
              │                                  │
              └────────── default gateway ──────┘
```

The forward path is fine; the **return path** is not:

| Direction | Path | Result |
|---|---|---|
| Forward | Main router → target | ✅ direct L2 delivery |
| Return | Target → **sidecar** → main router | ❌ source IP/port rewritten, conntrack mismatch |

Symptoms: TCP handshake never completes, connection reset, or the connection drops right after establishing. Meanwhile **everything works from inside the LAN**, which makes it hard to diagnose.

Two independent causes, often present together:

1. The sidecar's LAN zone has `masquerade` enabled → return packets get the sidecar's source IP
2. The sidecar runs a transparent proxy → return packets are intercepted, the TCP connection is terminated and re-originated with a different source IP and port

As long as return traffic passes through the sidecar, both problems persist. **pf-return simply keeps the return traffic of selected ports away from the sidecar.**

## How It Works

On the target host:

```
return packet ──iptables mark 0x1──▶ ip rule 100 ──▶ table 100 ──▶ main router
                                                                  (sidecar bypassed)
```

| Component | Role |
|---|---|
| `iptables -t mangle OUTPUT` | Marks return packets whose **source port** is whitelisted and whose destination is outside the LAN with `fwmark 0x1` |
| `ip rule` | Packets with `fwmark 0x1` consult `table 100` |
| `table 100` | Default route points at the main router instead of the default gateway |

All other traffic — including outbound proxy traffic — is untouched.

## Quick Start

```sh
unzip pf-return-1.1.0.zip
cd pf-return-1.1.0
sudo ./install.sh
```

The installer will:

1. Verify `root`, `systemd`, `ip` and `iptables`
2. Auto-detect the egress interface and LAN CIDR
3. **Ask for the main router address** (the default gateway is usually the sidecar)
4. Back up any existing config, install scripts and the systemd unit
5. Apply rules and verify each component

Non-interactive:

```sh
sudo ./install.sh -y --gateway 192.168.1.1
```

| Option | Description | Default |
|---|---|---|
| `--gateway` | Main router address (return path target) | prompted, defaults to default gateway |
| `--iface` | Egress interface | auto-detected |
| `--lan` | LAN CIDR; traffic to it is not marked | derived from interface |
| `--ports` | Initial whitelist, protocol suffix supported | `8080` |
| `-y, --yes` | Skip confirmation | no |
| `--uninstall` | Uninstall | — |
| `-V, --version` | Show version | — |

> ⚠️ **Make sure `--gateway` is the main router, not the sidecar.**
> Pointing it at the sidecar makes the whole setup a no-op.

Installed files:

| Path | Purpose |
|---|---|
| `/usr/local/sbin/pf-return` | Interactive whitelist manager |
| `/usr/local/sbin/pf-return-sync.sh` | Idempotent rule sync |
| `/usr/local/bin/pf-return` | Convenience symlink |
| `/etc/pf-return/env` | Configuration |
| `/etc/pf-return/ports.conf` | Port whitelist |
| `/etc/systemd/system/pf-return.service` | Apply rules at boot |

## Usage

### Interactive

```sh
sudo pf-return
```

```
================ Port Whitelist ================
Current (port/proto):
  8080/tcp
-----------------------------------------------
  1) Add port
  2) Remove port
  3) Show whitelist
  0) Exit
===============================================
Select [0-3]: 1
Ports (comma separated, e.g. 53/udp): 8901
Protocol [tcp/udp/both] (default tcp): tcp

Result: success
Added 8901/tcp, whitelist: 8080/tcp 8901/tcp
```

- Changes take effect immediately, no restart required
- Batch input: `8901,3306` or `8901 3306`
- Protocol suffix: `53/udp`, `6000/both` (both = one TCP + one UDP rule)
- Removing a bare port (e.g. `6000`) removes both its TCP and UDP entries
- On failure the script prints `Result: failure` and the reason, exit code `1`

### CLI

```sh
pf-return -l         # show whitelist
pf-return -s         # re-apply rules
pf-return --version  # version
```

### Whitelist the **local service port**, not the external port

```
Internet 203.0.113.10:40080 ──DNAT──▶ 192.168.1.20:8080
                                            └── whitelist 8080/tcp
```

The marked packets are those **originating from the target host with source port 8080**.

| Case | Entry |
|---|---|
| Web / API / database (TCP) | `8080` or `8080/tcp` |
| DNS / WireGuard (UDP) | `53/udp`, `51820/udp` |
| Same port, both protocols | `6000/both` |

## Configuration

`/etc/pf-return/env`

| Variable | Description | Default |
|---|---|---|
| `GATEWAY` | Main router address | detected at install |
| `IFACE` | Egress interface | detected at install |
| `TABLE` | Policy routing table | `100` |
| `MARK` | fwmark value | `0x1` |
| `LAN_CIDR` | LAN CIDR (not marked) | derived at install |
| `PORTS_FILE` | Whitelist path | `/etc/pf-return/ports.conf` |
| `COMMENT` | iptables comment tag | `pf-return` |

`/etc/pf-return/ports.conf`

```
# <port>/<tcp|udp>, one per line
8080/tcp
53/udp
6000/tcp
6000/udp
```

Apply changes with `sudo pf-return -s`. A bare port (`8080`) is treated as `8080/tcp`; `6000/both` is expanded automatically.

## Verification

### Rules in place

```sh
pf-return -l
ip rule show | grep fwmark            # 100: from all fwmark 0x1 lookup 100
ip route show table 100               # default via 192.168.1.1
iptables -t mangle -S OUTPUT | grep pf-return

# The two outputs must differ
ip route get 8.8.8.8 mark 0x1         # via main router
ip route get 8.8.8.8                  # via sidecar
```

### TCP services

```sh
tcpdump -i eth0 -nn -e 'tcp port 8080'   # return packet dst MAC = main router?
curl -v http://203.0.113.10:40080/
```

### UDP services

UDP has no handshake, so `nc -vz` is unreliable — inspect packets:

```sh
tcpdump -i eth0 -nn -e 'udp port 51820'
ip route get <client-ip> mark 0x1
```

### External reachability

```sh
curl -s "https://check-host.net/check-tcp?host=203.0.113.10:40080&max_nodes=5" \
     -H 'Accept: application/json'
```

## Compatibility

| Environment | Status |
|---|---|
| CentOS 7 (iptables-legacy) | ✅ tested |
| Debian 11/12, Ubuntu 20.04+ (iptables-nft) | ⚠️ expected to work, untested |
| RHEL 8+ / Rocky / Alma | ⚠️ expected to work, untested |
| Alpine | ⚠️ requires `bash` and `iptables` |
| OpenWrt | ❌ not applicable (it is the sidecar) |
| nftables-only (no `iptables` binary) | ❌ unsupported |

## Alternatives

| Approach | Pros | Cons |
|---|---|---|
| **pf-return** | Keeps the proxy, per-port control, real client IP preserved | Deploy on each mapped host |
| Point the host's gateway at the main router | Zero config, symmetric by design | Host loses the sidecar's proxy |
| Disable masquerade on the sidecar | One command | Ineffective against transparent proxies |
| Hairpin SNAT on the main router | Single place to change | Target loses the real client IP |
| WireGuard / Tailscale / Cloudflare Tunnel | No exposed ports, most secure | Requires clients, changes architecture |

**Do not use pf-return when**: the host's gateway is already the main router, the port forward lives on the sidecar, or the system is nftables-only without an `iptables` compatibility layer.

## FAQ

**Q1: Added the port but it still doesn't work.**

```sh
tcpdump -i eth0 -nn -e 'tcp port 8080'   # is the return packet's dst MAC the main router?
iptables -t mangle -L OUTPUT -n -v        # is the counter increasing?
ip route get <client-ip> mark 0x1
```

**Q2: Stops working after reboot.**

```sh
systemctl status pf-return
systemctl restart pf-return
```

**Q3: Rules disappear after restarting Docker.**

Docker reorders iptables chains. The unit is ordered after `docker.service`; if rules still vanish, run `systemctl restart pf-return`.

**Q4: Does it affect my proxy?**

No. Only return traffic of whitelisted ports is marked; everything else keeps the original default gateway.

**Q5: Is this the same as disabling masquerade on the sidecar?**

No, they are independent. Disabling masquerade alone is usually insufficient — a transparent proxy terminates and re-originates the connection, changing both source IP and port.

**Q6: Can I upgrade from 1.0 without changing the config?**

Yes. A bare port such as `8080` is treated as `8080/tcp`; the file is rewritten to the canonical format on the next add/remove operation.

**Q7: Does it work for SSH and other management ports?**

Yes, any TCP/UDP service works the same way — just whitelist its local port. For management ports, prefer key-based auth or a tunnel instead of long-term public exposure.

## Security

- Requires **root**; modifies `iptables`, `ip rule` and the routing table
- No network access, no telemetry, everything runs locally
- ~300 lines of shell — read it before deploying
- Test in a lab before using it on a production gateway
- Exposing ports to the internet is your own risk assessment: change defaults, use keys, rate-limit, or use a tunnel

See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## Contributing

Issues and PRs are welcome. Before submitting:

```sh
bash -n install.sh payload/pf-return payload/pf-return-sync.sh
sudo ./test/smoke.sh    # exercises add/remove inside an isolated netns
```

## License

[MIT](LICENSE)

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
