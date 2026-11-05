#!/system/bin/sh
# Belt-and-braces hook for gh-hugepage-reserve on a late-load KSU phone.
# Same stage as the other service.d scripts (frpc etc.), idempotent, reuses the
# module's own load.sh.
#
# Install:
#   su -c 'cp scripts/pool-boot/service.d-99-pool-load.sh /data/adb/service.d/99-pool-load.sh'
#   su -c 'chmod 755 /data/adb/service.d/99-pool-load.sh'
D=/data/adb/modules/gh-hugepage-reserve
LOG=/data/adb/pool-boot.log
[ -e /dev/gh_pinprobe ] && exit 0
[ -f "$D/disable" ] && exit 0
[ -f "$D/gh_hugepage_reserve.ko" ] || exit 0
echo "=== service.d pool load $(date) ===" >> "$LOG"
sh "$D/module/load.sh" >> "$LOG" 2>&1
exit 0
