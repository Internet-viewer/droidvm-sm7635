#!/system/bin/sh
# ============================================================
# DroidVM 环境一键配置 (root)
#   su -c 'sh ~/droidvm/setup.sh'
#
# 做 6 件事（幂等，可重复跑）：
#   1) insmod gunyah-host-share  -> /dev/gunyah_share（crosvm 必需）
#   2) insmod gunyah-kvcalloc    -> 大 guest 的页指针数组改 kvcalloc（官方 patch#1）
#   3) 加载 gh-hugepage-reserve  -> 大页池（可选，用 pool.sh 扩容）
#   4) 起 root 常驻 sshd（HOME 指回 Termux，避免 su 重置 HOME 导致找不到公钥）
#   5) 修 crosvm 包装脚本（bootctx shim + PARCEL_MB + ulimit -l）
#   6) 校验 VM 配置（single / hugepages / pseudo_unprotected）
# ============================================================
D=/data/data/cn.classfun.droidvm
DV=$D/usr/lib/modules/android14-6.1
M=$D/../..                           # 占位，实际路径在下面
HPM=/data/adb/modules/gh-hugepage-reserve
THOME=/data/data/com.termux/files/home
PREFIX=/data/data/com.termux/files/usr
PORT=18022

say() { echo "[$1] $2"; }

[ "$(id -u)" = 0 ] || { echo "请用 root： su -c 'sh $0'"; exit 1; }

# ---------- 1) gunyah host share ----------
if [ -e /dev/gunyah_share ]; then
  say 1 "/dev/gunyah_share 已存在"
else
  if [ -f "$DV/gunyah-host-share-gki-6.1.ko" ]; then
    /data/adb/ksud insmod "$DV/gunyah-host-share-gki-6.1.ko" >/dev/null 2>&1
    i=0; while [ $i -lt 10 ] && [ ! -e /dev/gunyah_share ]; do sleep 0.5; i=$((i+1)); done
    [ -e /dev/gunyah_share ] && say 1 "gunyah_share 已加载" || say 1 "!! gunyah_share 失败"
  else say 1 "!! 缺少 gunyah-host-share .ko"; fi
fi

# ---------- 2) kvcalloc ----------
if grep -q gunyah_kvcalloc /proc/modules; then
  say 2 "kvcalloc 已加载"
elif [ -f "$DV/gunyah-kvcalloc-gki-6.1.ko" ]; then
  /data/adb/ksud insmod "$DV/gunyah-kvcalloc-gki-6.1.ko" >/dev/null 2>&1
  grep -q gunyah_kvcalloc /proc/modules && say 2 "kvcalloc 已加载" || say 2 "!! kvcalloc 失败"
else say 2 "!! 缺少 gunyah-kvcalloc .ko"; fi

# ---------- 3) 大页模块（可选） ----------
if grep -q gh_hugepage /proc/modules; then
  say 3 "gh-hugepage-reserve 已加载"
elif [ -d "$HPM" ] && [ ! -f "$HPM/disable" ]; then
  # 手动 unzip 安装会漏掉 customize.sh：.ko 必须在模块根目录
  [ -f "$HPM/gh_hugepage_reserve.ko" ] || \
    cp -f "$HPM/ko/gh_hugepage_reserve/android14-6.1.ko" "$HPM/gh_hugepage_reserve.ko" 2>/dev/null
  [ -x "$HPM/module/load.sh" ] && sh "$HPM/module/load.sh" >/dev/null 2>&1
  grep -q gh_hugepage /proc/modules && say 3 "大页模块已加载" || say 3 "!! 大页模块加载失败"
else
  say 3 "未安装大页模块（跳过，池子不可用）"
fi

# ---------- 4) root sshd ----------
if ss -ltn 2>/dev/null | grep -q "[:.]$PORT[[:space:]]"; then
  say 4 "sshd 已在 $PORT 监听"
else
  if [ -x "$PREFIX/bin/sshd" ]; then
    setsid "$PREFIX/bin/sshd" -D -o UseDNS=no -o PermitRootLogin=yes \
      -o "AuthorizedKeysFile=$THOME/.ssh/authorized_keys" >/dev/null 2>&1 < /dev/null &
    sleep 2
    ss -ltn 2>/dev/null | grep -q "[:.]$PORT[[:space:]]" && say 4 "sshd 已启动" || say 4 "!! sshd 启动失败"
  else say 4 "!! 缺少 sshd"; fi
fi

# ---------- 5) crosvm 包装 ----------
BIN=$D/usr/bin/crosvm; REAL=$D/usr/bin/crosvm.real
if [ -f "$BIN" ] && [ "$(head -c 2 "$BIN" 2>/dev/null)" != '#!' ]; then
  [ -f "$REAL" ] || cp -a "$BIN" "$REAL"
  say 5 "备份原始 crosvm -> crosvm.real"
fi
if [ -f "$REAL" ]; then
  cat > "$BIN" <<'W'
#!/system/bin/sh
export LD_PRELOAD=/data/data/cn.classfun.droidvm/files/vmshim.so
export DROIDVM_SHIM_PARCEL_MB=512
ulimit -l unlimited 2>/dev/null || ulimit -l 8388608 2>/dev/null
exec /data/data/cn.classfun.droidvm/usr/bin/crosvm.real "$@"
W
  chmod 755 "$BIN"; chown 10512:10512 "$BIN"
  say 5 "crosvm 包装已写入（shim + PARCEL_MB=512 + ulimit）"
else
  say 5 "!! 缺少 crosvm.real，跳过"
fi
[ -f "$D/files/vmshim.so" ] || say 5 "!! 缺少 vmshim.so（boot context 假成功依赖它）"

# ---------- 6) VM 配置 ----------
J=$D/files/vms.json
if [ -f "$J" ]; then
  cp -a "$J" "$J.bak-setup-$(date +%H%M%S)" 2>/dev/null
  sed -i 's/"prepare_lend_mthp": "[a-z]*"/"prepare_lend_mthp": "single"/' "$J"
  sed -i 's/"hugepages": false/"hugepages": true/' "$J"
  sed -i 's/"protected_vm": "[a-z_]*"/"protected_vm": "pseudo_unprotected"/' "$J"
  sed -i 's/"protocol": "[a-z]*"/"protocol": "uefi"/' "$J"
  chown 10512:10512 "$J"; chmod 600 "$J"
  say 6 "VM 配置: $(grep -oE '"(memory_mb|prepare_lend_mthp|hugepages|protected_vm)": [^,]*' "$J" | tr '\n' ' ')"
else
  say 6 "!! 缺少 vms.json"
fi

echo
echo "=== 完成。下一步 ==="
echo "  池子:  su -c 'sh ~/droidvm/pool.sh status'"
echo "  VM  :  su -c 'sh ~/droidvm/vm.sh max'   # 算当前池子能开多大"
