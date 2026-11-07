#!/system/bin/sh
# ============================================================
# portmap-5022.sh —— 把手机的 <PORT>（IPv6 入站）映射到 DroidVM guest 的 22
# 纯内核实现（ip6tables DNAT + MASQUERADE），不依赖 Termux 里的 socat。
#
# 为什么需要 guest 有一个 IPv6 地址：
#   Linux 的 NAT 是"每协议族"的，ip6tables 不能把 v6 包 DNAT 成 v4 目标。
#   所以给 br-nat 和 guest 各配一个 ULA，做 v6→v6 的 DNAT，
#   再用 MASQUERADE 把 guest 的回包源改回手机收到的那个地址（不改客户端会丢包）。
#
# 用法（root）：
#   su -c 'sh ~/droidvm/portmap/portmap-5022.sh install'
#   su -c 'sh ~/droidvm/portmap/portmap-5022.sh uninstall'
#   su -c 'sh ~/droidvm/portmap/portmap-5022.sh status'
#
# 幂等：每条规则先 -C 检查再增删；只碰它自己那几条，不 flush、不动别的规则。
# 注意：App 重建网络 / 手机重启后 netfilter 可能被重写，重新跑 install 即可。
# ============================================================
set -u

MODE=${1:-install}
BR=${BR:-br-nat}
PORT=${PORT:-5022}
GUEST_PORT=${GUEST_PORT:-22}
GUEST_V4=${GUEST_V4:-192.168.207.10}
ULA_PREFIX=${ULA_PREFIX:-fd42:6d69:7068::/64}
BR_V6=${BR_V6:-fd42:6d69:7068::1}
GUEST_V6=${GUEST_V6:-fd42:6d69:7068::10}

IP6T=${IP6T:-/system/bin/ip6tables}
[ -x "$IP6T" ] || IP6T=ip6tables
SYSCTL=${SYSCTL:-/system/bin/sysctl}
[ -x "$SYSCTL" ] || SYSCTL=sysctl

say() { echo "[portmap] $*"; }

have_addr() { ip -6 addr show dev "$BR" 2>/dev/null | grep -q "inet6 ${BR_V6}/64"; }

add_addr()   { have_addr || { ip -6 addr add "${BR_V6}/64" dev "$BR" && say "added ${BR_V6}/64 to $BR"; }; }
del_addr()   { have_addr && { ip -6 addr del "${BR_V6}/64" dev "$BR" && say "removed ${BR_V6}/64 from $BR"; }; }

r_add() { "$IP6T" "$@" >/dev/null 2>&1 || true; }
r_chk() { "$IP6T" "$@" >/dev/null 2>&1; }

# 具体规则（-C 用完全相同的参数）
DNAT_SPEC="-t nat -A PREROUTING -p tcp --dport $PORT -j DNAT --to-destination [${GUEST_V6}]:${GUEST_PORT}"
DNAT_CHK="-t nat -C PREROUTING -p tcp --dport $PORT -j DNAT --to-destination [${GUEST_V6}]:${GUEST_PORT}"
SNAT_SPEC="-t nat -A POSTROUTING -s $ULA_PREFIX -j MASQUERADE"
SNAT_CHK="-t nat -C POSTROUTING -s $ULA_PREFIX -j MASQUERADE"
FWD_IN_SPEC="-I FORWARD 1 -i $BR -j ACCEPT"
FWD_IN_CHK="-C FORWARD -i $BR -j ACCEPT"
FWD_OUT_SPEC="-I FORWARD 1 -o $BR -j ACCEPT"
FWD_OUT_CHK="-C FORWARD -o $BR -j ACCEPT"

install_rules() {
  add_addr
  $SYSCTL -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
  r_chk $DNAT_CHK       || { r_add $DNAT_SPEC   && say "DNAT :$PORT -> [$GUEST_V6]:$GUEST_PORT"; }
  r_chk $SNAT_CHK       || { r_add $SNAT_SPEC   && say "MASQUERADE -s $ULA_PREFIX"; }
  r_chk $FWD_IN_CHK     || { r_add $FWD_IN_SPEC  && say "FORWARD -i $BR ACCEPT"; }
  r_chk $FWD_OUT_CHK    || { r_add $FWD_OUT_SPEC && say "FORWARD -o $BR ACCEPT"; }
}

uninstall_rules() {
  r_chk $DNAT_CHK    && { r_add ${DNAT_SPEC/-A/-D}    && say "removed DNAT"; }
  r_chk $SNAT_CHK    && { r_add ${SNAT_SPEC/-A/-D}    && say "removed MASQUERADE"; }
  r_chk $FWD_IN_CHK  && { "$IP6T" -D FORWARD -i "$BR" -j ACCEPT >/dev/null 2>&1 && say "removed FORWARD -i"; }
  r_chk $FWD_OUT_CHK && { "$IP6T" -D FORWARD -o "$BR" -j ACCEPT >/dev/null 2>&1 && say "removed FORWARD -o"; }
  del_addr
}

show_status() {
  echo "--- ip6 addr ($BR)"
  ip -6 addr show dev "$BR" 2>/dev/null | grep -E "inet6" | sed 's/^/    /'
  echo "--- ip6tables nat PREROUTING"
  "$IP6T" -t nat -S PREROUTING 2>/dev/null | grep -E "dport $PORT|DNAT" | sed 's/^/    /'
  echo "--- ip6tables nat POSTROUTING"
  "$IP6T" -t nat -S POSTROUTING 2>/dev/null | grep -E "$ULA_PREFIX|MASQUERADE" | sed 's/^/    /'
  echo "--- ip6tables FORWARD (前 4 条)"
  "$IP6T" -S FORWARD 2>/dev/null | head -4 | sed 's/^/    /'
  echo "--- 计数器"
  "$IP6T" -t nat -vnL PREROUTING 2>/dev/null | grep -E "DNAT.*$PORT" | sed 's/^/    /'
  echo "--- 相关 socket（应无 socat 在 :$PORT）"
  ss -6 -ltn 2>/dev/null | grep ":$PORT " | sed 's/^/    /' || echo "    (none)"
}

case "$MODE" in
  install)   install_rules; echo; show_status ;;
  uninstall) uninstall_rules; echo; show_status ;;
  status)    show_status ;;
  *) echo "用法: $0 {install|uninstall|status}"; exit 2 ;;
esac
