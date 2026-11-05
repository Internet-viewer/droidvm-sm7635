#!/system/bin/sh
# usr/bin/crosvm wrapper for DroidVM on a 6.1-android14 Gunyah kernel.
# All three lines matter (README §13.5):
#   LD_PRELOAD                - interposer that answers the missing GH_VM_SET_BOOT_CONTEXT (0x0a)
#   DROIDVM_SHIM_PARCEL_MB=512- split the window into memparcels the kernel accepts (1024 -> 512+502)
#   ulimit -l unlimited       - Gunyah accounts lent memory against RLIMIT_MEMLOCK (Android default 64 KB)
#
# Install (keep the real binary; a guard that copies only when crosvm.real is
# absent will silently keep a PREVIOUS build's binary -- check sizes):
#   su -c 'D=/data/data/cn.classfun.droidvm; cp -a $D/usr/bin/crosvm $D/usr/bin/crosvm.real'
#   su -c 'cp scripts/pool-boot/crosvm-wrapper.sh $D/usr/bin/crosvm'
#   su -c 'chmod 755 $D/usr/bin/crosvm; chown <app-uid>:<app-uid> $D/usr/bin/crosvm'
export LD_PRELOAD=/data/data/cn.classfun.droidvm/files/vmshim.so
export DROIDVM_SHIM_PARCEL_MB=512
ulimit -l unlimited 2>/dev/null || ulimit -l 8388608 2>/dev/null
exec /data/data/cn.classfun.droidvm/usr/bin/crosvm.real "$@"
