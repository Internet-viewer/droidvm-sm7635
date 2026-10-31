#!/system/bin/sh
# ============================================================
# droidvm-bootstrap.sh
# 硬重启 + 重跑 GhostLock 取得 root 之后，执行一次：
#     su -c 'sh /data/local/tmp/droidvm-bootstrap.sh'
# 作用：加载 gunyah 内核模块、拉起稳定的 root sshd、修复 crosvm 的
#       boot-context 注入、校验 VM 配置、加固关键进程。
# 幂等：重复执行安全。
# ============================================================
LOG=/data/adb/droidvm-bootstrap.log
D=/data/data/cn.classfun.droidvm
DV=$D/usr/lib/modules/android14-6.1
THOME=/data/data/com.termux/files/home
PREFIX=/data/data/com.termux/files/usr
AUTH=$THOME/.ssh/authorized_keys
PORTCFG=18022

say() { echo "$*"; echo "$*" >> "$LOG"; }
warn() { echo "!! $*"; echo "!! $*" >> "$LOG"; }

[ "$(id -u)" = 0 ] || { echo "请用 root 跑： su -c 'sh $0'"; exit 1; }
[ -d "$D" ] || { echo "找不到 DroidVM 数据目录 $D"; exit 1; }
APPUID=$(stat -c %u "$D")
say "=== droidvm-bootstrap $(date) ==="

# ---------- 1) gunyah host-share (/dev/gunyah_share) ----------
if [ -e /dev/gunyah_share ]; then
    say "[1] /dev/gunyah_share already present"
else
    if [ -f "$DV/gunyah-host-share-gki-6.1.ko" ]; then
        if /data/adb/ksud insmod "$DV/gunyah-host-share-gki-6.1.ko" >>"$LOG" 2>&1; then
            say "[1] gunyah-host-share: insmod issued"
            # 内核创建设备节点有延迟，最多等 5 秒
            i=0
            while [ $i -lt 10 ] && [ ! -e /dev/gunyah_share ]; do sleep 0.5; i=$((i+1)); done
            [ -e /dev/gunyah_share ] && say "[1] node ready after ~$((i/2))s" || warn "[1] node did not appear"
        else
            warn "[1] insmod gunyah-host-share FAILED (see $LOG)"
        fi
    else
        warn "[1] ko missing: $DV/gunyah-host-share-gki-6.1.ko"
    fi
fi
[ -e /dev/gunyah_share ] && say "    node: $(ls -l /dev/gunyah_share | awk '{print $1, $5, $6}')" || warn "    node still missing"

# ---------- 2) optional hugepage reserve (opt-in) ----------
HP=$THOME/gh-hp/ko/gh_hugepage_reserve/android14-6.1.ko
if [ -f /data/adb/ENABLE_HUGEPAGE ]; then
    if [ ! -e /dev/gh_pinprobe ] && [ -f "$HP" ]; then
        /data/adb/ksud insmod "$HP" >>"$LOG" 2>&1 && say "[2] hugepage reserve: loaded" || warn "[2] hugepage reserve FAILED"
    else
        say "[2] hugepage reserve: already present or ko missing"
    fi
else
    say "[2] hugepage reserve: skipped (create /data/adb/ENABLE_HUGEPAGE to enable)"
fi

# ---------- 3) android phantom process killer off ----------
settings put global settings_enable_monitor_phantom_procs false 2>/dev/null
say "[3] phantom_procs monitoring: $(settings get global settings_enable_monitor_phantom_procs 2>/dev/null)"

# ---------- 4) sshd (root-run, survives app/uid kills) ----------
if ss -ltn 2>/dev/null | grep -q "[:.]$PORTCFG[[:space:]]"; then
    say "[4] sshd already listening on $PORTCFG"
else
    if [ -x "$PREFIX/bin/sshd" ]; then
        setsid "$PREFIX/bin/sshd" -D -o UseDNS=no -o PermitRootLogin=yes \
            -o "AuthorizedKeysFile=$AUTH" >>"$LOG" 2>&1 < /dev/null &
        sleep 2
        if ss -ltn 2>/dev/null | grep -q "[:.]$PORTCFG[[:space:]]"; then
            say "[4] sshd started (root) on $PORTCFG"
        else
            warn "[4] sshd did not start; see $LOG"
        fi
    else
        warn "[4] sshd binary missing: $PREFIX/bin/sshd"
    fi
fi

# ---------- 5) crosvm boot-context shim (LD_PRELOAD wrapper) ----------
SHIM=$D/files/vmshim.so
if [ ! -f "$SHIM" ]; then
    warn "[5] vmshim.so missing -> boot context will NOT be faked (VM 可能启动失败)"
else
    say "[5] vmshim.so: $(stat -c %s "$SHIM") bytes"
fi
BIN=$D/usr/bin/crosvm
REAL=$D/usr/bin/crosvm.real
if [ -f "$BIN" ]; then
    if [ "$(head -c 2 "$BIN" 2>/dev/null)" = '#!' ]; then
        say "[5] crosvm wrapper: present"
    else
        # ELF (App 升级后会被覆盖) -> 备份并包装
        [ -f "$REAL" ] || cp -a "$BIN" "$REAL"
        printf '#!/system/bin/sh\nexport LD_PRELOAD=%s/files/vmshim.so\nexec %s "$@"\n' "$D" "$REAL" > "$BIN"
        chmod 755 "$BIN"; chown "$APPUID:$APPUID" "$BIN"
        say "[5] crosvm wrapper: re-created"
    fi
    # 包装指向的 .real 必须存在
    if [ ! -f "$REAL" ]; then warn "[5] crosvm.real missing! 原始二进制丢失"; fi
else
    warn "[5] crosvm binary missing: $BIN"
fi

# ---------- 6) VM 配置校验（已知可用值） ----------
J=$D/files/vms.json
if [ -f "$J" ]; then
    cp -a "$J" "$J.bak-bootstrap-$(date +%H%M%S)" 2>/dev/null
    sed -i 's/"memory_mb": [0-9]*/"memory_mb": 512/' "$J"
    sed -i 's/"prepare_lend_mthp": "[a-z]*"/"prepare_lend_mthp": "single"/' "$J"
    sed -i 's/"hugepages": false/"hugepages": true/' "$J"
    sed -i 's/"protected_vm": "[a-z_]*"/"protected_vm": "pseudo_unprotected"/' "$J"
    sed -i 's/"protocol": "[a-z]*"/"protocol": "uefi"/' "$J"
    chown "$APPUID:$APPUID" "$J"; chmod 600 "$J"
    say "[6] vms.json: $(grep -oE '"(memory_mb|prepare_lend_mthp|hugepages|protected_vm)": [^,]*' "$J" | tr '\n' ' ')"
else
    warn "[6] vms.json missing"
fi

# ---------- 7) 进程加固（App 层被杀时别连累关键进程） ----------
for pkg in com.termux com.wireguard.android com.follow.clash; do
    dumpsys deviceidle whitelist +$pkg >/dev/null 2>&1
done
for p in $(pgrep -x sshd) $(pidof com.termux) $(pgrep -f com.wireguard.android) $(pgrep -f com.follow.clash); do
    echo -1000 > /proc/$p/oom_score_adj 2>/dev/null
done
say "[7] oom_score_adj=-1000 applied to: $(for p in $(pgrep -x sshd) $(pidof com.termux); do echo -n "$p "; done)"

# ---------- 8) 汇总 ----------
say "--- summary ---"
say "  gunyah_share : $([ -e /dev/gunyah_share ] && echo OK || echo MISSING)"
say "  sshd:$PORTCFG: $(ss -ltn 2>/dev/null | grep -q "[:.]$PORTCFG[[:space:]]" && echo LISTENING || echo DOWN)"
say "  crosvm wrap  : $([ "$(head -c 2 "$BIN" 2>/dev/null)" = '#!' ] && echo OK || echo RAW)"
say "  VM status    : $( [ -x /data/local/tmp/dv/assets/bin/arm64-v8a/droidvm ] && cd "$D" && /data/local/tmp/dv/assets/bin/arm64-v8a/droidvm status $(grep -oE '"id": "[0-9a-f-]{36}"' "$J" | head -1 | grep -oE '[0-9a-f-]{36}') 2>/dev/null | grep -oE '"state" : "[a-z]+"' || echo "n/a")"
say "=== done $(date) ==="
