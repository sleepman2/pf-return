# pf-return

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](#兼容性)
[![Shell](https://img.shields.io/badge/shell-bash-4EAA25.svg)]()

**修复「主路由做端口映射 + 内网设备网关指向旁路由」场景下的外网访问问题。**

[English](README.en.md) | 简体中文

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [工作原理](#工作原理)
- [快速开始](#快速开始)
- [使用](#使用)
- [配置](#配置)
- [验证](#验证)
- [兼容性](#兼容性)
- [替代方案](#替代方案)
- [常见问题](#常见问题)
- [安全说明](#安全说明)
- [贡献](#贡献)
- [许可证](#许可证)

---

## 它解决什么问题

很多家庭/小型办公网络会这样搭：

```
                     ┌──────────────────┐
   互联网 ──────────▶│  主路由 192.168.1.1 │  做 NAT + 端口映射
                     └────────┬─────────┘
                              │ LAN
              ┌───────────────┼────────────────┐
              │               │                │
      ┌───────▼───────┐ ┌─────▼─────┐  ┌───────▼───────┐
      │ 旁路由 192.168.1.21 │ │ 虚拟化宿主   │  │ 目标机 192.168.1.20 │
      │ 透明代理 / 分流     │ │ 192.168.1.30│  │ 服务 :8080    │
      └───────────────┘ └───────────┘  └───────────────┘
              ▲                                  │
              └────────── 默认网关 ──────────────┘
```

去程一切正常，回程却出了问题：

| 方向 | 路径 | 结果 |
|---|---|---|
| 去程 | 主路由 → 目标机 | ✅ 二层直达 |
| 回程 | 目标机 → **旁路由** → 主路由 | ❌ 源地址/源端口被改写，主路由 conntrack 匹配失败 |

外部表现：TCP 握手完不成、连接被重置、或者连上就断。而**局域网内访问完全正常**，非常具有迷惑性。

根因通常有两个，且常常同时存在：

1. 旁路由 LAN 区域开了 `masquerade`，回包源 IP 被改写成旁路由
2. 旁路由跑着透明代理，回包被劫持后**终结 TCP 并重新发起**，源 IP 和源端口全变

只要回包还经过旁路由，这两个问题就绕不开。**pf-return 的做法是让指定端口的回包根本不经过旁路由。**

## 工作原理

在目标机上做三件事：

```
目标机回包 ──iptables mark 0x1──▶ ip rule 100 ──▶ table 100 ──▶ 主路由
                                                                （旁路由不在路径上）
```

| 组件 | 作用 |
|---|---|
| `iptables -t mangle OUTPUT` | 给「源端口命中白名单、且目标不在局域网」的回包打 `fwmark 0x1` |
| `ip rule` | `fwmark 0x1` 的报文查 `table 100` |
| `table 100` | 默认路由指向主路由，而不是默认网关 |

未被标记的流量（包括出站代理流量）完全不受影响。

## 快速开始

```sh
unzip pf-return-1.1.0.zip
cd pf-return-1.1.0
sudo ./install.sh
```

安装脚本会：

1. 检查 `root`、`systemd`、`ip`、`iptables`
2. 自动探测出口网卡和局域网段
3. **询问主路由地址**（默认网关通常是旁路由，必须手动确认）
4. 备份已有配置，安装脚本与 systemd 服务
5. 下发规则并逐项校验

非交互安装：

```sh
sudo ./install.sh -y --gateway 192.168.1.1
```

| 参数 | 说明 | 默认 |
|---|---|---|
| `--gateway` | 主路由地址（回包要交给它） | 交互式询问，默认取默认网关 |
| `--iface` | 出口网卡 | 自动探测 |
| `--lan` | 局域网网段，发往该网段的回包不标记 | 按网卡地址推导 |
| `--ports` | 初始白名单，可带协议（`53/udp`、`6000/both`） | `8080` |
| `-y, --yes` | 跳过确认 | 否 |
| `--uninstall` | 卸载 | — |
| `-V, --version` | 显示版本 | — |

> ⚠️ **务必确认 `--gateway` 是主路由，不是旁路由。**
> 如果填成旁路由，规则等于没做。

安装后的文件：

| 路径 | 说明 |
|---|---|
| `/usr/local/sbin/pf-return` | 交互式白名单管理 |
| `/usr/local/sbin/pf-return-sync.sh` | 规则同步（幂等） |
| `/usr/local/bin/pf-return` | 软链，便于直接调用 |
| `/etc/pf-return/env` | 配置文件 |
| `/etc/pf-return/ports.conf` | 端口白名单 |
| `/etc/systemd/system/pf-return.service` | 开机自动同步 |

## 使用

### 交互式

```sh
sudo pf-return
```

```
================ 端口白名单管理 ================
当前白名单（端口/协议）:
  8080/tcp
-----------------------------------------------
  1) 添加端口
  2) 删除端口
  3) 查看白名单
  0) 退出
===============================================
请选择操作 [0-3]: 1
请输入端口号（多个用逗号分隔，可写 53/udp）: 8901
协议 [tcp/udp/both]（默认 tcp）: tcp

结果: 成功
说明: 已添加 8901/tcp，当前白名单: 8080/tcp 8901/tcp
```

- 修改**立即生效**，无需重启
- 支持批量：`8901,3306` 或 `8901 3306`
- 端口可直接带协议：`53/udp`、`6000/both`（both = TCP + UDP 各一条）
- 删除时写裸端口（如 `6000`）会同时删除该端口的 TCP 与 UDP 条目
- 失败时输出 `结果: 失败` + `原因: ...`，退出码 `1`

### 命令行

```sh
pf-return -l        # 查看白名单
pf-return -s        # 重新同步规则
pf-return --version # 版本
```

### 白名单填「本机服务端口」，不是「外部端口」

```
外网 203.0.113.10:40080 ──DNAT──▶ 192.168.1.20:8080
                                        └── 白名单填 8080/tcp
```

被标记的是**目标机发出的、源端口为 8080 的回包**，所以填内部端口。

| 场景 | 填法 |
|---|---|
| Web / API / 数据库（TCP） | `8080` 或 `8080/tcp` |
| DNS / WireGuard（UDP） | `53/udp`、`51820/udp` |
| 同端口两种协议 | `6000/both` |

## 配置

`/etc/pf-return/env`

| 变量 | 含义 | 默认 |
|---|---|---|
| `GATEWAY` | 主路由地址 | 安装时探测 |
| `IFACE` | 出口网卡 | 安装时探测 |
| `TABLE` | 策略路由表号 | `100` |
| `MARK` | fwmark 值 | `0x1` |
| `LAN_CIDR` | 局域网网段（不标记的目标） | 安装时推导 |
| `PORTS_FILE` | 白名单文件路径 | `/etc/pf-return/ports.conf` |
| `COMMENT` | 规则注释，用于识别自身规则 | `pf-return` |

`/etc/pf-return/ports.conf`

```
# <端口>/<tcp|udp>，一行一条
8080/tcp
53/udp
6000/tcp
6000/udp
```

改完执行 `sudo pf-return -s` 生效。兼容裸端口写法（`8080` 等价于 `8080/tcp`），也支持 `6000/both`。

## 验证

### 规则是否就位

```sh
pf-return -l
ip rule show | grep fwmark            # 100: from all fwmark 0x1 lookup 100
ip route show table 100               # default via 192.168.1.1
iptables -t mangle -S OUTPUT | grep pf-return

# 最直观：两条命令结果应该不同
ip route get 8.8.8.8 mark 0x1         # via 主路由
ip route get 8.8.8.8                  # via 旁路由
```

### TCP 服务

```sh
# 目标机抓包，看回包的 dst MAC 是不是主路由
tcpdump -i eth0 -nn -e 'tcp port 8080'

# 外网侧
curl -v http://203.0.113.10:40080/
```

### UDP 服务

UDP 没有握手，`nc -vz` 不可靠，只能看包：

```sh
tcpdump -i eth0 -nn -e 'udp port 51820'
ip route get <客户端IP> mark 0x1
```

回包 `dst MAC` 是主路由即正确。

### 外网可达性（不依赖本机）

```sh
# 用第三方节点从境外发起 TCP 探测
curl -s "https://check-host.net/check-tcp?host=203.0.113.10:40080&max_nodes=5" \
     -H 'Accept: application/json'
```

## 兼容性

| 环境 | 状态 |
|---|---|
| CentOS 7（iptables-legacy） | ✅ 已实测 |
| Debian 11/12、Ubuntu 20.04+（iptables-nft） | ⚠️ 理论支持，未实测 |
| RHEL 8+ / Rocky / Alma | ⚠️ 理论支持，未实测 |
| Alpine | ⚠️ 需自行安装 `bash` 与 `iptables` |
| OpenWrt | ❌ 不适用（旁路由本身不需要此工具） |
| 纯 nftables（无 iptables 命令） | ❌ 不支持 |

## 替代方案

pf-return 不是唯一解，先看你的场景是否更适合别的做法：

| 方案 | 优点 | 代价 |
|---|---|---|
| **pf-return** | 不影响代理，按端口精细控制，客户端 IP 保留 | 需在每台被映射的机器上部署 |
| 直接把设备网关改成主路由 | 零配置，回程天然对称 | 该设备失去旁路由的代理能力 |
| 关闭旁路由 masquerade | 一行命令 | 对透明代理无效（代理仍会改写） |
| 在主路由做 hairpin SNAT | 只改一处 | 目标机看不到真实客户端 IP |
| WireGuard / Tailscale / Cloudflare Tunnel | 不暴露端口，最安全 | 需要客户端配合，架构变化 |

**不该用 pf-return 的情况**：设备网关本来就是主路由（不需要）、端口映射做在旁路由上（问题不同）、纯 nftables 且无法安装 iptables。

## 常见问题

**Q1：加了白名单还是连不上？**

```sh
tcpdump -i eth0 -nn -e 'tcp port 8080'   # 回包 dst MAC 是主路由吗
iptables -t mangle -L OUTPUT -n -v        # 规则命中计数在涨吗
ip route get <客户端IP> mark 0x1          # 路由决策对吗
```

**Q2：重启后失效？**

```sh
systemctl status pf-return
systemctl restart pf-return
```

**Q3：Docker 重启后规则没了？**

Docker 会重排 iptables 链。服务已配置在 `docker.service` 之后启动，仍丢失时执行 `systemctl restart pf-return`。

**Q4：会影响代理吗？**

不会。只有白名单端口的**回包**被标记，其余流量仍走原默认网关。

**Q5：和旁路由关 masquerade 冲突吗？**

不冲突，两者独立。但只关 masq 通常不够——透明代理会终结并重发 TCP，源地址和端口都会变。

**Q6：1.0 的配置能直接升级吗？**

可以。旧格式 `8080` 会被当作 `8080/tcp`，首次增删操作时文件自动重写为标准格式。

**Q7：支持 SSH 等管理端口吗？**

支持，任何 TCP/UDP 服务都一样，把服务端口加入白名单即可。出于安全考虑，建议这类管理端口配合密钥登录或改为内网穿透，不要长期暴露在公网。

## 安全说明

- 本工具需要 **root** 权限，会修改 `iptables`、`ip rule` 和路由表
- 不联网、不上报、不收集任何信息，全部逻辑在本地执行
- 代码约 300 行，建议部署前通读一遍
- 生产网关上使用前，请先在测试环境验证
- 暴露端口到公网请自行评估风险：改默认端口、强口令/密钥、限流或改用隧道

漏洞报告请见 [SECURITY.md](SECURITY.md)。

## 贡献

欢迎 Issue 和 PR。提交前请：

```sh
bash -n install.sh payload/pf-return payload/pf-return-sync.sh
sudo ./test/smoke.sh    # 在独立 netns 中验证增删逻辑
```

## 许可证

[MIT](LICENSE)

## 变更记录

见 [CHANGELOG.md](CHANGELOG.md)。
