#!/system/bin/sh
# ============================================================
# DroidVM 大页池扩容助手
# 用途：把 gh-hugepage-reserve 的池子尽量凑大，好给更大的 VM 用。
#      每跑一轮 acquire=3 是一次单向扫描；被自己 evict 出来、
#      落在扫描游标后方的窗口，只有下一轮才捡得到 —— 所以要多跑几轮。
#
# 用法（必须 root）：
#   su -c 'sh ~/droidvm/pool.sh'            # 目标 1024 页(=2GB)，默认 4 轮
#   su -c 'sh ~/droidvm/pool.sh 1200 6'     # 目标 1200 页，跑 6 轮
#   su -c 'sh ~/droidvm/pool.sh status'     # 只看当前状态（不加载/不扩容）
#   su -c 'sh ~/droidvm/pool.sh cancel'     # 取消正在跑的 acquire
#
# 换算：pool_avail(页) × 2MB = 可用大页内存
#       可跑的 VM 内存 ≈ pool_avail×2 − 40 (MB)，向下取整到 64 的倍数
# ============================================================

P=/sys/module/gh_hugepage_reserve/parameters
M=/data/adb/modules/gh-hugepage-reserve
KO=$M/gh_hugepage_reserve.ko
KOSRC=$M/ko/gh_hugepage_reserve/android14-6.1.ko

[ "$(id -u)" = 0 ] || { echo "请用 root： su -c 'sh $0 ...'"; exit 1; }

stat_one() { sed -n "s/^$1=//p" $P/refill_stat 2>/dev/null | head -1; }

show() {
  av=$(stat_one pool_avail); tt=$(stat_one pool_total)
  wn=$(stat_one pool_want);  wc=$(stat_one pool_want_with_cma)
  st=$(stat_one acquire_stop_reason); ac=$(stat_one acquire_active)
  echo "  状态: ${st:-?}    正在跑: ${ac:-?}"
  echo "  池子: 可用 ${av:-0} 页 (= $(( ${av:-0} * 2 )) MB)，已证明容量 ${tt:-0} 页"
  echo "  目标: pool_want=${wn:-0} 页 (= $(( ${wn:-0} * 2 )) MB)，with_cma=${wc:-?}（0=已关 CMA）"
  if [ -n "$tt" ]; then
    vm=$(( tt * 2 - 40 )); vm=$(( vm / 64 * 64 ))
    [ "$vm" -lt 512 ] && vm=512
    echo "  → 池子全空时可开 VM ≤ ${vm} MB（当前有 VM 在跑时 avail 会很低，属正常）"
  fi
}

ensure_module() {
  if ! grep -q gh_hugepage /proc/modules; then
    if [ ! -f "$KO" ] && [ -f "$KOSRC" ]; then cp -f "$KOSRC" "$KO"; chmod 644 "$KO"; fi
    [ -f "$KO" ] || { echo "!! 缺少 $KO"; return 1; }
    echo "  模块未加载，用模块自带 load.sh 拉起…"
    [ -x "$M/module/load.sh" ] && sh "$M/module/load.sh" >/dev/null 2>&1
    grep -q gh_hugepage /proc/modules || /data/adb/ksud insmod "$KO" >/dev/null 2>&1
  fi
  grep -q gh_hugepage /proc/modules
}

case "${1:-grow}" in
  status) ensure_module || { echo "模块不可用"; exit 1; }; show; exit 0 ;;
  cancel) echo 0 > $P/acquire 2>/dev/null && echo "已取消 acquire"; show; exit 0 ;;
esac

WANT=${1:-1024}
ROUNDS=${2:-4}
case "$WANT" in ''|*[!0-9]*) echo "目标页数必须是数字（1024 页 = 2GB）"; exit 2 ;; esac

ensure_module || { echo "模块不可用"; exit 1; }

echo "=== 目标 ${WANT} 页 (= $(( WANT * 2 )) MB)，最多 ${ROUNDS} 轮 ==="
show

[ "$(stat_one pool_want_with_cma)" = "0" ] || { echo 0 > $P/pool_want_with_cma 2>/dev/null; echo "  已把 with_cma 归 0（关 CMA，避开崩机分支）"; }

cur=$(cat $P/pool_want 2>/dev/null)
if [ "$cur" != "$WANT" ]; then
  echo 0 > $P/acquire 2>/dev/null; sleep 1
  if echo "$WANT" > $P/pool_want 2>/dev/null; then
    echo "  pool_want: ${cur:-?} → $(cat $P/pool_want) 页"
  else
    echo "  !! 写 pool_want 失败（可能仍有 run 在跑，先 pool.sh cancel）"; exit 1
  fi
fi

r=0
while [ "$r" -lt "$ROUNDS" ]; do
  r=$((r+1))
  av=$(stat_one pool_avail)
  [ "${av:-0}" -ge "$WANT" ] && { echo "=== 已达目标 ${WANT} 页，停止 ==="; break; }
  echo "--- 第 ${r}/${ROUNDS} 轮（当前 ${av:-?} 页 / 目标 ${WANT}）---"
  sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
  echo 3 > $P/acquire 2>/dev/null || { echo "  acquire 写入失败"; break; }
  i=0
  while [ "$i" -lt 24 ]; do
    i=$((i+1)); sleep 10
    a=$(stat_one acquire_active); v=$(stat_one pool_avail)
    echo "    ${i}0s: active=${a:-?} avail=${v:-?}"
    [ "$a" = "0" ] && [ "$i" -gt 2 ] && break
  done
  show
done

echo "=== 最终 ==="; show
echo
echo "提示：想再涨，先关掉后台大 App（微信/京东/支付宝等），再跑一次本脚本。"
echo "      给 VM 设内存：App → 编辑 VM → 基础 → 内存（不要超过上面的建议值）。"
