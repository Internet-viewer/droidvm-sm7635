#!/system/bin/sh
# ============================================================
# portmap-socat.sh —— 手机 <PORT>(IPv6) → DroidVM guest 22
# 由 root 托管 socat：不随 Termux App 关闭而消失。
#
# 为什么不用 iptables：本机内核 CONFIG_IP6_NF_NAT 未编、nftables 也未开启，
#   ip6tables -t nat 直接 "Table does not exist"，且 Linux NAT 不能跨协议族
#   （v6 入站 → v4 guest 必须靠用户态终结重建）。
#
# 用法（root）：
#   su -c 'sh ~/droidvm/portmap/portmap-socat.sh start'
#   su -c 'sh ~/droidvm/portmap/portmap-socat.sh status'
#   su -c 'sh ~/droidvm/portmap/portmap-socat.sh stop'
# 幂等：已在监听就什么都不做；stop 只杀自己这套。
# ============================================================
set -u
PORT=${PORT:-5022}
GUEST=${GUEST:-192.168.207.10}
GUEST_PORT=${GUEST_PORT:-22}
SOCAT=${SOCAT:-/data/data/com.termux/files/usr/bin/socat}
RUN=/data/local/tmp/portmap-5022
PIDF=$RUN/supervisor.pid
LOG=$RUN/portmap.log
mkdir -p "$RUN"

listening() { ss -ltn 2>/dev/null | grep -q "[:.]$PORT[[:space:]]"; }
running()   { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; }

case "${1:-start}" in
  start)
    if running; then echo "supervisor already running (pid $(cat "$PIDF"))"; 
    elif listening; then echo "port $PORT already served by another process; not starting"; 
    else
      setsid nohup /system/bin/sh -c \
        "while :; do '$SOCAT' TCP6-LISTEN:$PORT,bind=[::],reuseaddr,fork TCP:$GUEST:$GUEST_PORT >>'$LOG' 2>&1; sleep 2; done" \
        >/dev/null 2>&1 </dev/null &
      echo $! > "$PIDF"
      sleep 2
      echo "started supervisor pid $(cat "$PIDF")"
    fi
    ;;
  stop)
    [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null
    pkill -f "TCP6-LISTEN:$PORT" 2>/dev/null
    rm -f "$PIDF"
    echo "stopped"
    ;;
  status)
    echo "--- listener (: $PORT)"
    ss -6 -ltnp 2>/dev/null | grep ":$PORT " | sed 's/^/    /' || echo "    (none)"
    echo "--- supervisor pid"
    if running; then echo "    $(cat "$PIDF")"; else echo "    (not running)"; fi
    echo "--- target"
    echo "    $SOCAT  TCP6-LISTEN:$PORT,bind=[::],reuseaddr,fork  ->  TCP:$GUEST:$GUEST_PORT"
    echo "--- log tail"
    tail -3 "$LOG" 2>/dev/null | sed 's/^/    /' || true
    ;;
  *) echo "用法: $0 {start|stop|status}"; exit 2 ;;
esac
