#!/bin/sh
# 在 guest（Debian）里执行一次：给 enp0s6 加 ULA 地址 + 默认 v6 路由，并持久化。
# 由 portmap-5022.sh 的 DNAT 目标使用。
set -e
IF=${IF:-enp0s6}
ULA_PREFIX=${ULA_PREFIX:-fd42:6d69:7068::/64}
GUEST_V6=${GUEST_V6:-fd42:6d69:7068::10}
BR_V6=${BR_V6:-fd42:6d69:7068::1}
ip -6 addr show dev "$IF" | grep -q "inet6 ${GUEST_V6}/64" || ip -6 addr add "${GUEST_V6}/64" dev "$IF"
ip -6 route show default | grep -q "$BR_V6" || ip -6 route add default via "$BR_V6" dev "$IF"
mkdir -p /etc/systemd/network/20-wired.network.d
cat > /etc/systemd/network/20-wired.network.d/60-ula6.conf <<CONF
[Network]
Address=${GUEST_V6}/64
Gateway=${BR_V6}
CONF
echo "--- 现状"
ip -6 -br addr show "$IF"
ip -6 route | head -3
systemctl restart systemd-networkd 2>/dev/null || true
