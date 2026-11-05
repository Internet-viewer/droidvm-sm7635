#!/system/bin/sh
# gh-hugepage-reserve: root-level service.sh (KernelSU service stage).
#
# Why here: a GhostLock/late-load KernelSU phone does NOT execute the
# post-fs-data stage (proven: the module dir has no load.log/stamp after a boot,
# while droidvm-host's root-level service.sh does run), so a load that lives only
# in module/post-fs-data.sh never happens. The insmod itself stays in
# module/load.sh -- the upstream single source of truth (kapi_check/BTF
# preflight + v10 CMA args + the insmod ladder).
#
# Install:
#   su -c 'cp scripts/pool-boot/module-service.sh /data/adb/modules/gh-hugepage-reserve/service.sh'
#   su -c 'chmod 755 /data/adb/modules/gh-hugepage-reserve/service.sh'
#
# Do NOT copy post-fs-data.sh to the module root instead: its stamp/crash
# watchdog touches `disable` after any boot that did not reach boot-completed,
# which is how the module stops loading after a single crash.
D=/data/adb/modules/gh-hugepage-reserve
LOG=/data/adb/pool-boot.log
THP=/sys/kernel/mm/transparent_hugepage/shmem_enabled
[ -e "$THP" ] && echo advise > "$THP"

if [ ! -e /dev/gh_pinprobe ] && [ ! -f "$D/disable" ] && [ -f "$D/gh_hugepage_reserve.ko" ]; then
    echo "=== service.sh pool load $(date) ===" >> "$LOG"
    sh "$D/module/load.sh" >> "$LOG" 2>&1
    echo "rc=$? node=$([ -e /dev/gh_pinprobe ] && echo yes || echo no)" >> "$LOG"
fi

# post-fs-data.sh is not used here; keep a stale stamp from lingering anyway.
[ -f "$D/stamp" ] && ( sleep 30; rm -f "$D/stamp" ) &
exit 0
