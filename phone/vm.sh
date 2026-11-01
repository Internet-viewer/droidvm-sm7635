#!/system/bin/sh
# ============================================================
# DroidVM VM 管理助手
#   su -c 'sh ~/droidvm/vm.sh status'     # 状态 + 池子 + 建议内存
#   su -c 'sh ~/droidvm/vm.sh max'        # 按池子算出能开的最大内存
#   su -c 'sh ~/droidvm/vm.sh set 1024'   # 设置 VM 内存(MB)，会先停 VM
#   su -c 'sh ~/droidvm/vm.sh start'      # 启动（带取证，输出 tail）
#   su -c 'sh ~/droidvm/vm.sh stop'
#   su -c 'sh ~/droidvm/vm.sh logs [serial|stdio]'
# ============================================================
D=/data/data/cn.classfun.droidvm
CLI=/data/local/tmp/dv/assets/bin/arm64-v8a/droidvm
J=$D/files/vms.json
P=/sys/module/gh_hugepage_reserve/parameters
PY=/data/data/com.termux/files/usr/bin/python3

[ "$(id -u)" = 0 ] || { echo "请用 root： su -c 'sh $0 ...'"; exit 1; }
[ -x "$CLI" ] || { echo "!! 缺少 droidvm CLI: $CLI"; exit 1; }

vm_id() { $PY -c "import json;print(json.load(open('$J'))['vms'][0]['id'])" 2>/dev/null; }
stat_one() { sed -n "s/^$1=//p" $P/refill_stat 2>/dev/null | head -1; }

pool_total() { stat_one pool_total; }
max_mb() {
  t=$(pool_total)
  [ -z "$t" ] && { echo 512; return; }
  v=$(( (t - 12) * 2 )); v=$(( v / 64 * 64 ))
  [ "$v" -lt 512 ] && v=512
  echo "$v"
}

show() {
  ID=$(vm_id)
  echo "  VM: $(grep -oE '"name": "[^"]*"' $J | head -1 | cut -d'"' -f4)  id=${ID:-?}"
  echo "  cfg: $(grep -oE '"(memory_mb|prepare_lend_mthp|hugepages|protected_vm)": [^,]*' $J | tr '\n' ' ')"
  [ -n "$ID" ] && echo "  state: $($CLI status "$ID" 2>/dev/null | grep -oE '"state" : "[a-z]+"' | head -1)"
  if [ -d /sys/module/gh_hugepage_reserve ]; then
    echo "  pool: avail=$(stat_one pool_avail) total=$(stat_one pool_total) want=$(stat_one pool_want) ($(stat_one acquire_stop_reason))"
    echo "  → 建议 VM 内存 ≤ $(max_mb) MB"
  else
    echo "  pool: 未加载（只能 512 MB）"
  fi
}

case "${1:-status}" in
  status) show ;;
  max) max_mb ;;
  set)
    MB=${2:-}; case "$MB" in ''|*[!0-9]*) echo "用法: vm.sh set <MB>"; exit 2 ;; esac
    ID=$(vm_id)
    echo "  停止 VM…"; $CLI stop "$ID" >/dev/null 2>&1; sleep 4
    $PY - "$MB" <<'PY'
import json,sys
mb=int(sys.argv[1]); p='/data/data/cn.classfun.droidvm/files/vms.json'
d=json.load(open(p)); vm=d['vms'][0]
vm['memory_mb']=mb; vm['prepare_lend_mthp']='single'; vm['hugepages']=True
json.dump(d, open(p,'w'), indent=4)
print("  memory_mb =", mb)
PY
    chown 10512:10512 $J; chmod 600 $J
    echo "  提示: 池子总量 $(pool_total) 页，建议上限 $(max_mb) MB"
    ;;
  start)
    ID=$(vm_id)
    setsid nohup sh /data/local/tmp/vm-forensics.sh >/dev/null 2>&1 &
    am force-stop cn.classfun.droidvm; sleep 2
    am start -n cn.classfun.droidvm/.ui.main.MainActivity >/dev/null 2>&1
    sleep 8
    uiautomator dump /sdcard/u.xml >/dev/null 2>&1
    if grep -q 'text="Test Build"' /sdcard/u.xml; then input tap 949 1794; sleep 3; fi
    input tap 366 2496; sleep 3      # VM tab
    input tap 500 560; sleep 3       # 第一台 VM
    input tap 323 874; sleep 8       # Start
    uiautomator dump /sdcard/u2.xml >/dev/null 2>&1
    grep -qiE 'parcel|reserve is short' /sdcard/u2.xml && echo "  !! 有弹窗: $(grep -oE 'text="[^"]{1,50}"' /sdcard/u2.xml | head -3 | tr '\n' ' ')"
    sleep 35
    echo "  state: $($CLI status "$ID" 2>/dev/null | grep -oE '"state" : "[a-z]+"')"
    echo "  --- serial ---"; $CLI logs "$ID" serial1 2>/dev/null | tail -5
    ;;
  stop) ID=$(vm_id); $CLI stop "$ID" 2>&1 | grep -E '"success"' | head -1 ;;
  logs) ID=$(vm_id); $CLI logs "$ID" "${2:-serial1}" 2>/dev/null | tail -20 ;;
  *) echo "用法: vm.sh status|max|set <MB>|start|stop|logs [serial1|stdio]"; exit 2 ;;
esac
