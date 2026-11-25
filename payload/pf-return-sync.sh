#!/bin/bash
# pf-return-sync.sh — 按白名单同步回程路由与 iptables 标记规则
# 支持 TCP / UDP，幂等，可反复执行，支持中英文输出。
set -u

VERSION="1.1.1"

LANG_CLI=""
while [ $# -gt 0 ]; do
    case "$1" in
        --lang)   LANG_CLI="${2:-}"; shift 2 ;;
        --lang=*) LANG_CLI="${1#*=}"; shift ;;
        --version|-V) echo "pf-return-sync $VERSION"; exit 0 ;;
        *) shift ;;
    esac
done

ENV_FILE=${PF_RETURN_ENV:-/etc/pf-return/env}
LANG_SEL="${LANG_CLI:-${PF_RETURN_LANG:-}}"

t() {
    local k=$1; shift
    case "${LANG_SEL}:${k}" in
        zh:err_env)      printf '%s' "失败: 找不到 $1" ;;
        en:err_env)      printf '%s' "error: not found: $1" ;;
        zh:err_root)     printf '%s' '需要 root 权限' ;;
        en:err_root)     printf '%s' 'root privileges required' ;;
        zh:err_ip)       printf '%s' '系统缺少 ip 命令（iproute2）' ;;
        en:err_ip)       printf '%s' 'ip command not found (iproute2)' ;;
        zh:err_ipt)      printf '%s' '系统缺少 iptables 命令' ;;
        en:err_ipt)      printf '%s' 'iptables not found' ;;
        zh:err_iface)    printf '%s' "网卡 $1 不存在（检查配置文件中的 IFACE）" ;;
        en:err_iface)    printf '%s' "interface $1 does not exist (check IFACE)" ;;
        zh:err_gw)       printf '%s' "网关 $1 不可达（检查配置文件中的 GATEWAY/IFACE）" ;;
        en:err_gw)       printf '%s' "gateway $1 unreachable (check GATEWAY/IFACE)" ;;
        zh:err_route)    printf '%s' "写入 table $1 的默认路由失败" ;;
        en:err_route)    printf '%s' "failed to write default route into table $1" ;;
        zh:err_rule)     printf '%s' "添加 ip rule(fwmark $1 -> table $2) 失败" ;;
        en:err_rule)     printf '%s' "failed to add ip rule (fwmark $1 -> table $2)" ;;
        zh:warn_skip)    printf '%s' "警告: 跳过非法条目 [$1]" ;;
        en:warn_skip)    printf '%s' "warning: skipping invalid entry [$1]" ;;
        zh:err_port)     printf '%s' "端口 $1/$2 下发失败: $3" ;;
        en:err_port)     printf '%s' "failed to apply $1/$2: $3" ;;
        zh:done)         printf '%s' "成功: 策略路由已就绪（table $1 via $2），共应用 $3 条规则:$4" ;;
        en:done)         printf '%s' "ok: policy routing ready (table $1 via $2), $3 rule(s) applied:$4" ;;
        *) printf '%s' "$k" ;;
    esac
}

[ -r "$ENV_FILE" ] && . "$ENV_FILE" || { echo "$(t err_env "$ENV_FILE")" >&2; exit 1; }

# 语言优先级: --lang > PF_RETURN_LANG > env 文件 UI_LANG > 系统 locale
if [ -z "$LANG_SEL" ]; then
    LANG_SEL="${UI_LANG:-}"
fi
if [ -z "$LANG_SEL" ]; then
    case "${LC_ALL:-${LANG:-}}" in
        zh*)              LANG_SEL=zh ;;
        ""|C|POSIX|C.*)   LANG_SEL=zh ;;
        *)                LANG_SEL=en ;;
    esac
fi

# 默认值仅作示例，生产环境请在 env 中显式指定
GATEWAY=${GATEWAY:-192.168.1.1}
IFACE=${IFACE:-eth0}
TABLE=${TABLE:-100}
MARK=${MARK:-0x1}
LAN_CIDR=${LAN_CIDR:-192.168.1.0/24}
PORTS_FILE=${PORTS_FILE:-/etc/pf-return/ports.conf}
COMMENT=${COMMENT:-pf-return}

[ "$(id -u)" -eq 0 ] || { echo "$(t err_root)" >&2; exit 1; }
command -v ip       >/dev/null 2>&1 || { echo "$(t err_ip)" >&2; exit 1; }
command -v iptables >/dev/null 2>&1 || { echo "$(t err_ipt)" >&2; exit 1; }
ip link show "$IFACE" >/dev/null 2>&1 || { echo "$(t err_iface "$IFACE")" >&2; exit 1; }
ip route get "$GATEWAY" >/dev/null 2>&1 || { echo "$(t err_gw "$GATEWAY")" >&2; exit 1; }

# 1) 策略路由：table $TABLE 默认走主路由
ip route replace default via "$GATEWAY" dev "$IFACE" table "$TABLE" >/dev/null 2>&1 \
    || { echo "$(t err_route "$TABLE")" >&2; exit 1; }

if ! ip rule show | grep -q "fwmark ${MARK} lookup ${TABLE}"; then
    ip rule add fwmark "$MARK" lookup "$TABLE" priority 100 >/dev/null 2>&1 \
        || { echo "$(t err_rule "$MARK" "$TABLE")" >&2; exit 1; }
fi

# 2) 清掉上一次下发的旧规则（按行号倒序删除，避免行号漂移）
NUMS=$(iptables -t mangle -L OUTPUT --line-numbers -n 2>/dev/null \
       | awk '/^[0-9]+/ && /MARK/ && /spt:[0-9]+/ {print $1}' | sort -rn)
for n in $NUMS; do
    iptables -t mangle -D OUTPUT "$n" >/dev/null 2>&1
done

# 3) 解析白名单条目：<端口>[/tcp|/udp|/both]，不带协议默认 tcp
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
        echo "$(t err_port "$p" "$proto" "$(tr '\n' ' ' </tmp/.pf-return.err)")" >&2
        exit 1
    fi
}

# 4) 按白名单重建
COUNT=0
APPLIED=""
if [ -r "$PORTS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        e=$(printf '%s' "$line" | sed 's/#.*//' | tr -d ' \t\r')
        [ -z "$e" ] && continue

        parsed=$(parse_entry "$e") || { echo "$(t warn_skip "$line")" >&2; continue; }
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

echo "$(t done "$TABLE" "$GATEWAY" "$COUNT" "$APPLIED")"
exit 0
