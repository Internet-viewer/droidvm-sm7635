#!/system/bin/sh
# 让 DroidVM 的 br-nat 网桥能出网（幂等，可反复跑）。
# 手机重启 / App 重建网络后，下面三样里通常只留下链和 MASQUERADE 规则，
# 跳转和 FORWARD 放行会丢：
#   1) POSTROUTING 没有 -j droidvm_pst         -> NAT 永不执行
#   2) FORWARD 没有 br-nat 的 ACCEPT，而 tetherctrl_FORWARD 末尾是 -j DROP
# 用法: su -c 'sh ~/droidvm/fix-brnat-nat.sh [网桥名]'
set -u
B=${1:-br-nat}
SUB=${B//-/_}
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

# 1) 确保 app 的 NAT 链与规则存在
iptables -t nat -N droidvm_pst 2>/dev/null
iptables -t nat -N "droidvm_pst_$B" 2>/dev/null
iptables -t nat -C "droidvm_pst_$B" -s 192.168.207.0/24 ! -o "$B+" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A "droidvm_pst_$B" -s 192.168.207.0/24 ! -o "$B+" -j MASQUERADE
iptables -t nat -C droidvm_pst -j "droidvm_pst_$B" 2>/dev/null \
  || iptables -t nat -A droidvm_pst -j "droidvm_pst_$B"

# 2) 补 POSTROUTING 跳转
iptables -t nat -C POSTROUTING -j droidvm_pst 2>/dev/null \
  || iptables -t nat -A POSTROUTING -j droidvm_pst

# 3) 补 FORWARD 放行（放最前，绕开 tetherctrl_FORWARD 的 DROP）
iptables -C FORWARD -i "$B" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$B" -j ACCEPT
iptables -C FORWARD -o "$B" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o "$B" -j ACCEPT

echo "--- POSTROUTING"; iptables -t nat -S POSTROUTING | tail -3
echo "--- FORWARD";     iptables -S FORWARD | head -3
echo "--- NAT 计数";    iptables -t nat -vnL "droidvm_pst_$B" 2>/dev/null | tail -2
