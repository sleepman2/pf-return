#!/bin/bash
# smoke.sh — 在独立 network namespace 中验证增删逻辑
# 不触碰宿主机的 iptables / 路由表。
#
# 用法: sudo ./test/smoke.sh
set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)
NS="pfret-test"
HOST_VETH="veth-pfret"
NS_VETH="veth-gw"
GW_IP="192.0.2.1"
HOST_IP="192.0.2.2"
LAN="192.0.2.0/24"
TMP=$(mktemp -d)
PASS=0
FAIL=0

cleanup() {
    ip netns del "$NS"        >/dev/null 2>&1 || true
    ip link del "$HOST_VETH"  >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
reset_net() {
    ip netns del "$NS"        >/dev/null 2>&1 || true
    ip link del "$HOST_VETH"  >/dev/null 2>&1 || true
}
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || { echo "需要 root 权限"; exit 1; }
command -v ip       >/dev/null 2>&1 || { echo "缺少 ip 命令"; exit 1; }
command -v iptables >/dev/null 2>&1 || { echo "缺少 iptables 命令"; exit 1; }
[ -x "$SRC/payload/pf-return-sync.sh" ] || { echo "找不到 payload 脚本，请在包目录内运行"; exit 1; }

check() {
    local desc=$1
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  [PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $desc"
        FAIL=$((FAIL + 1))
    fi
}

in_ns() {
    ip netns exec "$NS" env \
        PF_RETURN_ENV="$TMP/env" \
        PF_RETURN_SYNC="$SRC/payload/pf-return-sync.sh" \
        "$@"
}

echo "== 准备隔离环境 =="
reset_net
ip netns add "$NS"                      || { echo "无法创建 netns"; exit 1; }
ip link add "$HOST_VETH" type veth peer name "$NS_VETH" || exit 1
ip link set "$NS_VETH" netns "$NS"
ip addr add "$GW_IP/24" dev "$HOST_VETH"
ip link set "$HOST_VETH" up
ip netns exec "$NS" ip addr add "$HOST_IP/24" dev "$NS_VETH"
ip netns exec "$NS" ip link set "$NS_VETH" up
ip netns exec "$NS" ip link set lo up
echo "  netns=$NS gw=$GW_IP host=$HOST_IP"

cat >"$TMP/env" <<EOF
GATEWAY=$GW_IP
IFACE=$NS_VETH
TABLE=100
MARK=0x1
LAN_CIDR=$LAN
PORTS_FILE=$TMP/ports.conf
COMMENT=pf-return
EOF
printf '8080/tcp\n' >"$TMP/ports.conf"

echo
echo "== 同步脚本 =="
in_ns "$SRC/payload/pf-return-sync.sh" >/dev/null 2>&1
check "生成 TCP 标记规则"      bash -c "ip netns exec $NS iptables -t mangle -S OUTPUT | grep -q -- '-p tcp.*--sport 8080'"
check "ip rule 已创建"         bash -c "ip netns exec $NS ip rule show | grep -q 'fwmark 0x1 lookup 100'"
check "table 100 指向网关"     bash -c "ip netns exec $NS ip route show table 100 | grep -q 'default via $GW_IP'"
check "规则注释正确"           bash -c "ip netns exec $NS iptables -t mangle -S OUTPUT | grep -q -- '--sport 8080'"

echo
echo "== 交互式添加 UDP =="
printf '1\n53/udp\n\n0\n' | in_ns "$SRC/payload/pf-return" >/dev/null 2>&1
check "UDP 规则已生成"         bash -c "ip netns exec $NS iptables -t mangle -S OUTPUT | grep -q -- '-p udp.*--sport 53'"
check "白名单含 53/udp"        bash -c "grep -qx '53/udp' $TMP/ports.conf"

echo
echo "== 交互式删除 UDP =="
printf '2\n53/udp\n0\n' | in_ns "$SRC/payload/pf-return" >/dev/null 2>&1
check "UDP 规则已移除"         bash -c "! ip netns exec $NS iptables -t mangle -S OUTPUT | grep -q -- '-p udp.*--sport 53'"
check "白名单不含 53/udp"      bash -c "! grep -qx '53/udp' $TMP/ports.conf"

echo
echo "== 批量与 both =="
printf '1\n6000/both\n\n0\n' | in_ns "$SRC/payload/pf-return" >/dev/null 2>&1
check "both 展开为 TCP+UDP"    bash -c "ip netns exec $NS iptables -t mangle -S OUTPUT | grep -c -- '--sport 6000' | grep -qx 2"

echo
echo "== 裸端口删除（应同时删两种协议）=="
printf '2\n6000\n0\n' | in_ns "$SRC/payload/pf-return" >/dev/null 2>&1
check "6000 全部移除"          bash -c "! ip netns exec $NS iptables -t mangle -S OUTPUT | grep -q -- '--sport 6000'"

echo
echo "== 失败路径 =="
check "非法端口返回非零"       bash -c "printf '1\n99999\n\n' | ip netns exec $NS env PF_RETURN_ENV=$TMP/env PF_RETURN_SYNC=$SRC/payload/pf-return-sync.sh $SRC/payload/pf-return >/dev/null 2>&1; [ \$? -ne 0 ]"
check "重复添加返回非零"       bash -c "printf '1\n8080\n\n' | ip netns exec $NS env PF_RETURN_ENV=$TMP/env PF_RETURN_SYNC=$SRC/payload/pf-return-sync.sh $SRC/payload/pf-return >/dev/null 2>&1; [ \$? -ne 0 ]"

echo
echo "======================================="
echo "通过: $PASS    失败: $FAIL"
[ "$FAIL" -eq 0 ] && { echo "结果: 全部通过"; exit 0; } || { echo "结果: 存在失败项"; exit 1; }
