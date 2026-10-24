#!/bin/bash
# pf-return-sync.sh — 按白名单同步回程路由与 iptables 标记规则
# 支持 TCP / UDP，幂等，可反复执行。
set -u

VERSION="1.1.0"

if [ "${1:-}" = "--version" ]; then
    echo "pf-return-sync $VERSION"
    exit 0
fi

ENV_FILE=${PF_RETURN_ENV:-/etc/pf-return/env}
[ -r "$ENV_FILE" ] && . "$ENV_FILE" || { echo "失败: 找不到 $ENV_FILE" >&2; exit 1; }

# 默认值仅作示例，生产环境请在 env 中显式指定
GATEWAY=${GATEWAY:-192.168.1.1}
IFACE=${IFACE:-eth0}
TABLE=${TABLE:-100}
MARK=${MARK:-0x1}
LAN_CIDR=${LAN_CIDR:-192.168.1.0/24}
PORTS_FILE=${PORTS_FILE:-/etc/pf-return/ports.conf}
COMMENT=${COMMENT:-pf-return}

die() { echo "失败: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "需要 root 权限"
command -v ip       >/dev/null 2>&1 || die "系统缺少 ip 命令（iproute2）"
command -v iptables >/dev/null 2>&1 || die "系统缺少 iptables 命令"
ip link show "$IFACE" >/dev/null 2>&1 || die "网卡 $IFACE 不存在（检查配置文件中的 IFACE）"
ip route get "$GATEWAY" >/dev/null 2>&1 || die "网关 $GATEWAY 不可达（检查配置文件中的 GATEWAY/IFACE）"

# 1) 策略路由：table $TABLE 默认走主路由
ip route replace default via "$GATEWAY" dev "$IFACE" table "$TABLE" >/dev/null 2>&1 \
    || die "写入 table $TABLE 的默认路由失败"

if ! ip rule show | grep -q "fwmark ${MARK} lookup ${TABLE}"; then
    ip rule add fwmark "$MARK" lookup "$TABLE" priority 100 >/dev/null 2>&1 \
        || die "添加 ip rule(fwmark $MARK -> table $TABLE) 失败"
fi

# 2) 清掉上一次下发的旧规则（按行号倒序删除，避免行号漂移）
NUMS=$(iptables -t mangle -L OUTPUT --line-numbers -n 2>/dev/null \
       | awk '/^[0-9]+/ && /MARK/ && /spt:[0-9]+/ {print $1}' | sort -rn)
for n in $NUMS; do
    iptables -t mangle -D OUTPUT "$n" >/dev/null 2>&1
done

# 3) 解析白名单条目：<端口>[/tcp|/udp|/both]，不带协议默认 tcp
#    输出 "port proto"，非法返回 1
parse_entry() {
    local e=$1 p pr
    case "$e" in
        */*) p=${e%/*}; pr=${e#*/} ;;
        *)   p=$e;       pr=tcp     ;;
    esac
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1
    case "$pr" in tcp|udp|both) ;; *) return 1 ;; esac
    printf '%s %s\n' "$p" "$pr"
}

add_rule() {
    local p=$1 proto=$2
    if ! iptables -t mangle -A OUTPUT -p "$proto" -m "$proto" --sport "$p" \
            ! -d "$LAN_CIDR" -m comment --comment "$COMMENT" \
            -j MARK --set-xmark "${MARK}/0xffffffff" 2>/tmp/.pf-return.err; then
        die "端口 $p/$proto 下发失败: $(tr '\n' ' ' </tmp/.pf-return.err)"
    fi
}

# 4) 按白名单重建
COUNT=0
APPLIED=""
if [ -r "$PORTS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        e=$(printf '%s' "$line" | sed 's/#.*//' | tr -d ' \t\r')
        [ -z "$e" ] && continue

        parsed=$(parse_entry "$e") || { echo "警告: 跳过非法条目 [$line]" >&2; continue; }
        p=${parsed% *}
        pr=${parsed#* }

        case "$pr" in
            both)
                add_rule "$p" tcp; add_rule "$p" udp
                COUNT=$((COUNT + 2)); APPLIED="$APPLIED $p/tcp $p/udp" ;;
            *)
                add_rule "$p" "$pr"
                COUNT=$((COUNT + 1)); APPLIED="$APPLIED $p/$pr" ;;
        esac
    done < "$PORTS_FILE"
fi

echo "成功: 策略路由已就绪（table $TABLE via $GATEWAY），共应用 $COUNT 条规则:$APPLIED"
exit 0
