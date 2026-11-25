#!/bin/bash
# pf-return 安装脚本
# 用法: sudo ./install.sh [选项]
set -euo pipefail

VERSION="1.1.1"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PAYLOAD="$SCRIPT_DIR/payload"

BIN_DIR="/usr/local/sbin"
SYMLINK="/usr/local/bin/pf-return"
CONF_DIR="/etc/pf-return"
UNIT_PATH="/etc/systemd/system/pf-return.service"

GATEWAY=""
GATEWAY_EXPLICIT=0
IFACE=""
LAN_CIDR=""
PORTS="8080"
ASSUME_YES=0
DO_UNINSTALL=0

c_info()  { printf '\033[32m[信息]\033[0m %s\n' "$*"; }
c_warn()  { printf '\033[33m[警告]\033[0m %s\n' "$*"; }
c_err()   { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }
die()     { c_err "$*"; exit 1; }

usage() {
    cat <<'EOF'
pf-return 安装脚本

用法:
  sudo ./install.sh [选项]

选项:
  --gateway <IP>     主路由地址（交互式询问，默认取默认网关）
  --iface <网卡>     出口网卡（默认自动探测）
  --lan <CIDR>       局域网网段（默认按网卡地址自动推导）
  --ports "<列表>"   初始白名单，逗号或空格分隔（默认 "8080"）
                     可带协议：8080 53/udp 6000/both
  -y, --yes          跳过交互确认
  --uninstall        卸载
  -V, --version      显示版本
  -h, --help         显示帮助

示例:
  sudo ./install.sh
  sudo ./install.sh --gateway 192.168.1.1 --iface eth0 --lan 192.168.1.0/24 --ports "8080 8901"
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --gateway)   GATEWAY="${2:-}"; GATEWAY_EXPLICIT=1; shift 2 ;;
        --iface)     IFACE="${2:-}"; shift 2 ;;
        --lan)       LAN_CIDR="${2:-}"; shift 2 ;;
        --ports)     PORTS="${2:-}"; shift 2 ;;
        -y|--yes)    ASSUME_YES=1; shift ;;
        --uninstall) DO_UNINSTALL=1; shift ;;
        -V|--version) echo "pf-return installer $VERSION"; exit 0 ;;
        -h|--help)   usage; exit 0 ;;
        *)           c_err "未知参数: $1"; usage; exit 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "需要 root 权限，请用 sudo 运行"

# ---------------------------------------------------------------- 卸载
if [ "$DO_UNINSTALL" -eq 1 ]; then
    c_info "开始卸载 pf-return"
    systemctl disable --now pf-return.service >/dev/null 2>&1 || true
    rm -f "$UNIT_PATH" "$SYMLINK" "$BIN_DIR/pf-return" "$BIN_DIR/pf-return-sync.sh"
    systemctl daemon-reload >/dev/null 2>&1 || true

    MARK=$(grep -E '^MARK=' "$CONF_DIR/env" 2>/dev/null | cut -d= -f2 || true)
    TABLE=$(grep -E '^TABLE=' "$CONF_DIR/env" 2>/dev/null | cut -d= -f2 || true)
    MARK=${MARK:-0x1}; TABLE=${TABLE:-100}

    iptables -t mangle -L OUTPUT --line-numbers -n 2>/dev/null \
        | awk '/^[0-9]+/ && /MARK/ && /spt:[0-9]+/ {print $1}' | sort -rn \
        | while read -r n; do iptables -t mangle -D OUTPUT "$n" >/dev/null 2>&1 || true; done

    ip rule del fwmark "$MARK" lookup "$TABLE" >/dev/null 2>&1 || true
    ip route flush table "$TABLE" >/dev/null 2>&1 || true

    if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
        read -r -p "是否删除配置文件 $CONF_DIR ? [y/N] " ans
        case "$ans" in y|Y) rm -rf "$CONF_DIR" ;; *) c_info "保留配置目录 $CONF_DIR" ;; esac
    else
        rm -rf "$CONF_DIR"
    fi

    c_info "卸载完成"
    exit 0
fi

# ---------------------------------------------------------------- 依赖检查
c_info "检查运行环境"
[ -d /run/systemd/system ] || c_warn "未检测到 systemd，服务将无法开机自启（脚本仍可手动运行）"
command -v ip >/dev/null 2>&1       || die "缺少 ip 命令，请先安装 iproute2"
command -v iptables >/dev/null 2>&1 || die "缺少 iptables 命令，请先安装 iptables（Debian/Ubuntu: apt install iptables；RHEL/CentOS: yum install iptables）"
[ -f "$PAYLOAD/pf-return" ]          || die "安装包不完整：找不到 $PAYLOAD/pf-return"

# ---------------------------------------------------------------- 自动探测
detect() {
    local def
    def=$(ip route show default 2>/dev/null | awk '/^default/ {print $3" "$5; exit}')
    [ -n "$def" ] || die "无法探测默认路由，请用 --gateway 和 --iface 手动指定"

    [ -z "$IFACE" ] && IFACE=$(echo "$def" | awk '{print $2}')

    if [ -z "$LAN_CIDR" ]; then
        LAN_CIDR=$(ip -o -4 route show dev "$IFACE" 2>/dev/null \
                   | awk '$2=="proto" && $3=="kernel" && $1 !~ /^169\.254\./ {print $1; exit}')
    fi
    [ -n "$LAN_CIDR" ] || die "无法推导局域网网段，请用 --lan 手动指定（如 192.168.1.0/24）"
    case "$LAN_CIDR" in */*) ;; *) die "局域网段格式不正确：$LAN_CIDR（应形如 192.168.1.0/24）" ;; esac

    ip link show "$IFACE" >/dev/null 2>&1 || die "网卡 $IFACE 不存在"
}

detect

# 注意：默认网关很可能就是旁路由，而回包必须交给【主路由】。
if [ "$GATEWAY_EXPLICIT" -eq 0 ]; then
    DEF_GW=$(ip route show default | awk '/^default/ {print $3; exit}')
    if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
        echo
        c_warn "检测到默认网关为 $DEF_GW。"
        c_warn "如果它是旁路由（透明代理），这里必须填写【主路由】的地址，否则回包仍会被改写。"
        read -r -p "主路由 IP（回包要交给它）[$DEF_GW]: " gw_in
        GATEWAY="${gw_in:-$DEF_GW}"
    else
        GATEWAY="$DEF_GW"
        c_warn "未指定 --gateway，暂用默认网关 $GATEWAY（若它是旁路由，请重新用 --gateway 指定主路由）"
    fi
fi

ip route get "$GATEWAY" >/dev/null 2>&1 || die "主路由 $GATEWAY 不可达，请检查 --gateway / --iface"

# 端口列表规范化（逗号/空格 -> 空格，去重排序）
normalize_ports() {
    local e p pr out=""
    for e in $(echo "$1" | tr ',，;；' '    '); do
        case "$e" in
            */*) p=${e%/*}; pr=${e#*/} ;;
            *)   p=$e;       pr=tcp     ;;
        esac
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || continue
        case "$pr" in
            both)    out="$out $p/tcp $p/udp" ;;
            tcp|udp) out="$out $p/$pr" ;;
            *)       continue ;;
        esac
    done
    printf '%s\n' $out | sort -t/ -k1,1n -k2,2 -u | tr '\n' ' ' | sed 's/ $//'
}
PORTS_NORM=$(normalize_ports "$PORTS")
[ -n "$PORTS_NORM" ] || PORTS_NORM="8080"

echo
c_info "安装参数"
printf '  %-12s %s\n' "主路由"   "$GATEWAY"
printf '  %-12s %s\n' "出口网卡" "$IFACE"
printf '  %-12s %s\n' "局域网段" "$LAN_CIDR"
printf '  %-12s %s\n' "初始白名单" "$PORTS_NORM"
echo

if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
    read -r -p "确认安装？[Y/n] " ans
    case "${ans:-Y}" in n|N) c_info "已取消"; exit 0 ;; esac
fi

# ---------------------------------------------------------------- 备份旧配置
if [ -d "$CONF_DIR" ]; then
    BAK="$CONF_DIR.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$CONF_DIR" "$BAK" 2>/dev/null && c_info "已备份旧配置到 $BAK"
fi

# ---------------------------------------------------------------- 安装文件
c_info "安装脚本到 $BIN_DIR"
install -m 0755 "$PAYLOAD/pf-return"          "$BIN_DIR/pf-return"
install -m 0755 "$PAYLOAD/pf-return-sync.sh"  "$BIN_DIR/pf-return-sync.sh"
ln -sf "$BIN_DIR/pf-return" "$SYMLINK"

c_info "写入配置到 $CONF_DIR"
mkdir -p "$CONF_DIR"
# 升级时保留原有的界面语言设置
OLD_UI_LANG=""
[ -r "$CONF_DIR/env" ] && OLD_UI_LANG=$(grep -E '^UI_LANG=' "$CONF_DIR/env" 2>/dev/null | head -1 | cut -d= -f2-)
cat >"$CONF_DIR/env" <<EOF
# pf-return 配置文件（由 install.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')）
GATEWAY=$GATEWAY
IFACE=$IFACE
TABLE=100
MARK=0x1
LAN_CIDR=$LAN_CIDR
PORTS_FILE=$CONF_DIR/ports.conf
COMMENT=pf-return
# 界面语言：zh / en，留空则跟随系统 locale
UI_LANG=${OLD_UI_LANG:-}
EOF

# 已存在白名单则保留，否则写入初始值
if [ -f "$CONF_DIR/ports.conf" ] && [ -s "$CONF_DIR/ports.conf" ]; then
    c_info "检测到已有白名单，保留原内容：$(tr '\n' ' ' <"$CONF_DIR/ports.conf")"
else
    printf '%s\n' $PORTS_NORM >"$CONF_DIR/ports.conf"
fi

c_info "安装 systemd 服务"
install -m 0644 "$PAYLOAD/pf-return.service" "$UNIT_PATH"

# ---------------------------------------------------------------- 启用并应用
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload
    systemctl enable pf-return.service >/dev/null 2>&1 || true
    # 用 restart 而不是 enable --now：服务已是 active 时 --now 不会重跑 ExecStart，
    # 会导致新写入的白名单没有真正下发。
    systemctl restart pf-return.service >/dev/null 2>&1 || true
    if ! systemctl is-active --quiet pf-return.service; then
        c_warn "服务未能启动，尝试直接执行同步脚本"
        "$BIN_DIR/pf-return-sync.sh" || die "规则下发失败，请检查上面的报错"
    fi
else
    "$BIN_DIR/pf-return-sync.sh" || die "规则下发失败"
fi

# ---------------------------------------------------------------- 验证
echo
c_info "验证结果"
FAIL=0

if ip rule show | grep -q "fwmark 0x1 lookup 100"; then
    echo "  [OK]   ip rule 已就绪"
else
    echo "  [FAIL] ip rule 缺失"; FAIL=1
fi

if ip route show table 100 | grep -q "^default via $GATEWAY"; then
    echo "  [OK]   策略路由表 100 -> $GATEWAY"
else
    echo "  [FAIL] 策略路由表 100 未指向 $GATEWAY"; FAIL=1
fi

CNT=$(iptables -t mangle -S OUTPUT 2>/dev/null | grep -c 'pf-return' || true)
if [ "$CNT" -ge 1 ]; then
    LIST=$(iptables -t mangle -S OUTPUT | grep 'pf-return' \
           | sed -E 's/.*-p (tcp|udp).*--sport ([0-9]+).*/\2\/\1/' | tr '\n' ' ' | sed 's/ $//')
    echo "  [OK]   iptables 标记规则 $CNT 条：$LIST"
else
    echo "  [FAIL] 未找到 iptables 标记规则"; FAIL=1
fi

if [ -d /run/systemd/system ]; then
    if systemctl is-enabled --quiet pf-return.service; then
        echo "  [OK]   开机自启已启用"
    else
        echo "  [FAIL] 开机自启未启用"; FAIL=1
    fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
    c_info "安装成功（v$VERSION）"
    echo
    echo "  下一步："
    echo "    1. 在【主路由】上把外部端口映射到本机的服务端口"
    echo "    2. 运行  sudo pf-return  把【服务端口】加入白名单"
    echo "    3. 从外网验证：curl http://<公网IP>:<外部端口>/"
    echo
    echo "  详细说明见 README.md"
else
    c_err "安装完成但校验未通过，请检查上面的 FAIL 项"
    exit 1
fi
