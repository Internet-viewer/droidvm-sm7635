# 在 Redmi Note 14 Pro+（Snapdragon 7s Gen 3 / SM7635）上跑 DroidVM（Gunyah 硬件虚拟化）

> 实测环境：Redmi Note 14 Pro+ 5G（`24115RA8EC` / `amethyst` / `ro.board.platform=volcano` = SM7635）、
> Android 16、内核 `6.1.138-android14-11-g0c3d559bcd85-ab14529422`、
> Root = **GhostLock（CVE 提权）+ KernelSU LKM late-load（jailbreak 模式）**、SELinux Enforcing。
>
> 结果：**DroidVM（crosvm + Qualcomm Gunyah）成功启动 Alpine Linux 3.22（UEFI / 内核 6.12.114-0-virt）到 login**。
> guest 侧 `VCPU_RUN` 计数 13 万+，两次独立复现。

---

## 0. TL;DR — 官方"7 系不支持"并不绝对

DroidVM 文档写"高通需骁龙 8 Gen 3+ 且开启 Gunyah"。在 SM7635 上实测：

| 官方说法 | 本机实测 |
|---|---|
| 需要 Gunyah | ✅ `/dev/gunyah` **存在**（`crw-rw-rw- u:object_r:vendor_gunyah_dev:s0 10,121`），整套 gunyah 内核栈在跑（`gh_rm_drv`/`gunyah_loader`/`gunyah_qcom`/`hvc_gunyah`/`gzvm`） |
| SoC 需 8 Gen 3+ | ⚠️ 只是保守列表；DroidVM 自己的芯片表已含 SM7635（App 显示 `SoC supported: SM7635`） |
| 有节点就能跑 | ❌ 本机还差两样东西（见下），补上即可 |

**补上这两样就能跑**：

1. **`/dev/gunyah_share`**（`gunyah-host-share` 内核模块）——不加载时 crosvm 在 `GH_VM_START` 之后 `open()` 失败 → `ENOENT`
2. **假造 `GH_VM_SET_BOOT_CONTEXT`**（用户态 LD_PRELOAD 拦截 ioctl）——本机 6.1 内核没有这个 ioctl

---

## 1. 两个根因（含证据）

### 1.1 缺 `/dev/gunyah_share`

crosvm 的启动链：`CREATE_VM → SET_USER_MEM_REGION → LEND_USER_MEM → SET_DTB_CONFIG → boot_context → GH_VM_START → share_guest_ram_window()`
最后一步要打开 `/dev/gunyah_share` 发 `GHSM_SHARE_BLOB`，节点不存在时：

```
GH-DIAG: GH_VM_SET_BOOT_CONTEXT failed        ← 当时另一处问题
failed to initialize virtual machine No such file or directory (os error 2)
```

对照探针实测（见附录 A）：`/dev/gunyah` 上 `0x02 SET_DTB_CONFIG` 存在，`0x14 SHARE_BLOB` 走的是**另一个设备节点**。

### 1.2 内核缺 `GH_VM_SET_BOOT_CONTEXT`（ioctl `0x0a`）

用自写探针对 `/dev/gunyah` 逐号探测（type `0x47`）：

| ioctl | 本机结果 |
|---|---|
| `0x00` CREATE_VM | ✅ |
| `0x01` SET_USER_MEM_REGION (sz 32) | ✅ |
| `0x02` SET_DTB_CONFIG (sz 16) | ✅ ret=0 |
| `0x03` GH_VM_START | ✅ |
| `0x04` ADD_FUNCTION | ✅ |
| `0x06` VCPU_MMAP_SIZE | ✅ 返回 4096 |
| `0x07` REMOVE_FUNCTION | ✅ |
| **`0x0a` SET_BOOT_CONTEXT** | ❌ **ENOTTY（sz 0~128 全试）** |

上游佐证：`GH_VM_SET_BOOT_CONTEXT` 是 **android15-6.6** 世代才引入的（kernel/common 提交 `e70e053 ANDROID: virt: gunyah: Check GUNYAH_VM_SET_BOOT_CONTEXT reg upper bits` 等）。
crosvm 只在 `payload offset == 0` 时容忍它缺失；DroidVM 的 GH-SHIM 把 payload 放在 `0x80600000`（base `0x80000000`，offset 6MB），所以必然失败。

---

## 2. 完整步骤

### 2.0 前置

- Android 13+、ARM64、已 root（Magisk/KernelSU/APatch，本机是 GhostLock + KernelSU late-load）
- 手机上有 **`/dev/gunyah`**（`ls -l /dev/gunyah`）
- 手机能自己下载东西（镜像别走 ssh 推，见 §5）

### 2.1 装 DroidVM

用 dev 版（官方要求 issue 走 dev）：
`DroidVM-0.0.6.r242.3348830-dev.apk`（sha256 `5df12a9b00e4326255c44a5a17a0f48aa9f14dd8d53b9a6f8ea8abb7e9781c1a`）

```bash
su -c 'pm install -r -g /data/local/tmp/droidvm.apk'
```

### 2.2 走完首次设置向导

依次会检查：Root → SoC → 虚拟化节点 → 文件访问权限 → prebuilt 解压 → 内核模块 → 网络。
本机实测：`Root ✅ / SoC supported: SM7635 ✅ / Virtualization support found ✅`。
权限里要授「所有文件访问」。**内核模块那一步可以全部跳过**（我们后面手动只装必要的一个）。

### 2.3 导入镜像（建议用 Alpine 云镜像，小且 UEFI 可引导）

```bash
# 在手机上（Termux）直接下载，别用电脑 ssh 推
curl -L -o ~/storage/downloads/alpine-tiny.qcow2 \
  https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud/alpine-3.22.7-aarch64-uefi-tiny-r0.qcow2
sha256sum ~/storage/downloads/alpine-tiny.qcow2
# 138,805,248 B ; sha256 d6b98edfb60da4b6ab06f88a7cd2f5dbad323fc85002393f357e0fd4b5eb5f74
```

App 里：**Disks → Create → Import existing file**，选它。导入后位于 `/storage/emulated/0/DroidVM/`。

> 如果 SAF 文件选择器不好点，可临时用手机本地 HTTP 服务：
> `cd ~/storage/downloads && python3 -m http.server 8099 --bind 127.0.0.1`
> 然后 App 里 **Create → Download from URL** → `http://127.0.0.1:8099/alpine-tiny.qcow2`

### 2.4 建 VM（能跑起来的关键配置）

**Create Wizard → Customize**：

| 项 | 值 |
|---|---|
| Backend | **CrosVM** |
| Hypervisor | **Qualcomm Gunyah** |
| Protected VM | **Pseudo Unprotected** |
| Boot protocol | **UEFI**（固件留空 = 内置 EDK2） |
| Memory / CPU | **512 MiB / 1 vCPU**（先保守，稳定后再加） |
| Storage | 2.3 导入的那块 qcow2 |
| Network | 建一个 `br-wifi`（Wi-Fi pseudo-bridge 或 Linux bridge 均可） |
| 预分配大页（prepare-lend-mthp） | **single**（默认；不要 chunked） |

等价配置（`/data/data/cn.classfun.droidvm/files/vms.json` 片段）：

```json
"backend": "crosvm", "hypervisor": "gunyah",
"protected_vm": "pseudo_unprotected", "memory_mb": 512, "cpu_count": 1,
"prepare_lend_mthp": "single", "hugepages": true,
"boot": { "protocol": "uefi", ... }
```

### 2.5 ⭐ Workaround A：补 `/dev/gunyah_share`

DroidVM 自带各 KMI 的模块：

```bash
ls /data/data/cn.classfun.droidvm/usr/lib/modules/android14-6.1/
# gh-unmovable  gunyah-host-share  gunyah-kvcalloc  nproc-guard  udmabuf  (对应内核 6.1)

su -c '/data/adb/ksud insmod /data/data/cn.classfun.droidvm/usr/lib/modules/android14-6.1/gunyah-host-share-gki-6.1.ko'
ls -l /dev/gunyah_share     # crw------- root root 10, 99
dmesg | grep gunyah_share   # gunyah_share: loaded (v2: liveness GC ...)
```

**每次重启后都要重做**（原因见 §5「GhostLock late-load」）。

### 2.6 ⭐ Workaround B：假造 boot context（LD_PRELOAD 拦截器）

完整源码 `vmshim.c`：

```c
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>

static int (*real_ioctl)(int, int, ...) = 0;
static int logfd = -2;

static void wr(const char *s) {
    if (logfd == -2) logfd = open("/data/local/tmp/vmshim-load.log", O_WRONLY|O_CREAT|O_APPEND, 0666);
    if (logfd >= 0) { ssize_t w = write(logfd, s, strlen(s)); (void)w; }
}
static void note(const char *fmt, unsigned int r, int ret) {
    char b[256];
    snprintf(b, sizeof b, "pid=%d %s req=0x%08x type=0x%02x nr=0x%02x ret=%d\n",
             getpid(), fmt, r, _IOC_TYPE(r), _IOC_NR(r), ret);
    wr(b);
}
__attribute__((constructor)) static void ctor(void) { char b[64]; snprintf(b,sizeof b,"LOADED pid=%d\n",getpid()); wr(b); }

int ioctl(int fd, int req, ...) {
    va_list ap; void *arg;
    va_start(ap, req); arg = va_arg(ap, void *); va_end(ap);
    if (!real_ioctl) real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    unsigned int r = (unsigned int)req, t = _IOC_TYPE(r), nr = _IOC_NR(r);
    /* 6.1 内核没有 GH_VM_SET_BOOT_CONTEXT(0x0a)：告诉 crosvm "成功" */
    if (nr == 0x0a && (t == 0x47 || t == 0x41)) { note("FAKE_BOOT_CONTEXT", r, 0); return 0; }
    int ret = real_ioctl(fd, req, arg);
    if (t == 0x47 || t == 0x41) note("pass", r, ret);
    return ret;
}
```

编译（手机上用 Termux 的 clang 即可，需静态可加载）：

```bash
clang -O2 -shared -fPIC -o vmshim.so vmshim.c -ldl
```

安装 + **包装 crosvm 二进制**（`setprop wrap.*` 传不到子进程，必须包装二进制）：

```bash
D=/data/data/cn.classfun.droidvm
su -c "cp vmshim.so $D/files/vmshim.so; chown 10512:10512 $D/files/vmshim.so; chmod 644 $D/files/vmshim.so"

# 备份原始 crosvm 并替换成包装脚本
su -c "cp -a $D/usr/bin/crosvm $D/usr/bin/crosvm.real"
su -c "cat > $D/usr/bin/crosvm" <<'EOF'
#!/system/bin/sh
export LD_PRELOAD=/data/data/cn.classfun.droidvm/files/vmshim.so
exec /data/data/cn.classfun.droidvm/usr/bin/crosvm.real "$@"
EOF
su -c "chmod 755 $D/usr/bin/crosvm; chown 10512:10512 $D/usr/bin/crosvm"
```

### 2.7 启动并读串口

App 里点 **Start**。控制台可用 daemon CLI 读（无需 GUI）：

```bash
CLI=/data/local/tmp/dv/assets/bin/arm64-v8a/droidvm    # 从 APK assets/bin/arm64-v8a/droidvm 解出
cd /data/data/cn.classfun.droidvm
$CLI status <vm_id>              # "state": "running"
$CLI console <vm_id>             # 列出流：stdout stderr stdio serial1
$CLI logs <vm_id> serial1 | tail -20
```

---

## 3. 实测结果（证据）

```
crosvm.real --extended-status run --name alpine --mem 512 --cpus 1 \
  --hypervisor gunyah --protected-vm-pseudo-unprotected --no-balloon \
  --disable-sandbox --hugepages --prepare-lend-mthp-mode single ...
```

ioctl 轨迹（由 vmshim 记录）：

```
CREATE_VM(0x00) → LEND_USER_MEM(0x11) → SET_USER_MEM_REGION(0x01)×2
→ ADD_FUNCTION(0x04)×43 → VCPU_MMAP_SIZE(0x06)=4096 → SET_DTB_CONFIG(0x02)
→ boot_context(0x0a, 被 shim 假成功) → GH_VM_START(0x03)=0
→ SHARE_BLOB(0x14) 149.7 ms          ← 需要 /dev/gunyah_share
→ VCPU_RUN(0x05) ×131,348            ← vCPU 持续执行 guest 代码
```

guest 串口（`serial1`）：

```
EXT4-fs (vda2): mounted filesystem 30f79144-... ro
Mounting root: ok.

Welcome to Alpine Linux 3.22
Kernel 6.12.114-0-virt on aarch64 (/dev/ttyS0)

MiWiFi-R3600-srv login:
```

---

## 4. 已知问题 / 坑

| 现象 | 原因 | 处置 |
|---|---|---|
| `failed to initialize virtual machine: No such file or directory (os error 2)`，且 SHIM 之后无新 ioctl | 缺 `/dev/gunyah_share` | 见 §2.5 |
| `GH-DIAG: GH_VM_SET_BOOT_CONTEXT failed` | 6.1 内核无该 ioctl，且 payload offset≠0 | 见 §2.6 |
| `Huge-page reserve is short` 弹窗 | 大页预留不足（未装 `gh-hugepage-reserve`） | **不要点 Start anyway**（本机实测会导致整机崩溃）。要么取消，要么装大页模块 |
| **整机崩溃 / 需要重跑 GhostLock 才恢复 root** | 曾用 `Protected without firmware + 直接内核引导`，以及绕过 huge-page 守卫 | **禁止**这两条；坚持 `pseudo_unprotected + UEFI + 512MB` |
| `gpu_display_android: Failed to lock surface scanout` | App 不在前台、没有可用 Surface | 无害，guest 正常；在 App 里打开 VM 画面即可 |
| 没有 GPU 加速（走 CPU 路径） | 缺 `/dev/gh_pinprobe`（`gh-hugepage-reserve` 未加载） | 可选装该模块（会预留约 2GiB，谨慎） |
| VM 一启动，Termux / VPN / sshd 全掉 | Android 按 **uid 连坐**回收 App 进程，`oom_score_adj` 挡不住 | 把 sshd/frpc 等做成 **root 常驻**（独立于 App） |
| 重启后 `/dev/gunyah_share`、sshd 都不在 | **GhostLock 是 late-load**：KernelSU 在开机后才载入，模块的 `post-fs-data.sh`/`service.sh` **不会执行** | 每次重跑 GhostLock 后手工执行一次启动脚本（见 §5） |

---

## 5. 让环境"重启后自动就位"（可选，KernelSU 模块）

本机 root 是漏洞提权 + late-load，标准 boot 钩子不生效。做法：写一个幂等的启动脚本，重跑 GhostLock 后执行一次。

`/data/adb/modules/droidvm-host/service.sh` 要点：

```sh
# 1) 补 /dev/gunyah_share
[ -e /dev/gunyah_share ] || /data/adb/ksud insmod <path>/gunyah-host-share-gki-6.1.ko

# 2) 起 sshd（root 常驻，避免被 App 回收连带杀死）
#    su <uid> 会把 HOME 重置为 /data，必须显式指定
setsid /data/data/com.termux/files/usr/bin/sshd -D -o UseDNS=no \
       -o AuthorizedKeysFile=/data/data/com.termux/files/home/.ssh/authorized_keys
```

执行方式：

```bash
su -c 'sh /data/adb/modules/droidvm-host/service.sh'
```

---

## 6. 卸载 / 还原

```bash
D=/data/data/cn.classfun.droidvm
# 还原 crosvm
su -c "mv -f $D/usr/bin/crosvm.real $D/usr/bin/crosvm"
# 卸载 App（配置与镜像保留在 /storage/emulated/0/DroidVM）
su -c 'pm uninstall cn.classfun.droidvm'
# 移除模块
su -c 'rm -rf /data/adb/modules/droidvm-host'
```

---

## 附录 A：gunyah ioctl 探针（用于判断本机驱动支持哪些 ABI）

```c
#define _GNU_SOURCE
#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <sys/ioctl.h>
#define IOW(t,nr,sz) (unsigned long)((1u<<30)|((unsigned)sz<<16)|((t)<<8)|(nr))
int main(void){
    int fd = open("/dev/gunyah", O_RDWR);
    if (fd < 0) { printf("open: %s\n", strerror(errno)); return 1; }
    int vm = ioctl(fd, (unsigned long)((0x47<<8)|0x00), 0);   /* CREATE_VM */
    printf("vmfd=%d\n", vm);
    char buf[512] = {0};
    for (unsigned nr = 0x01; nr <= 0x18; nr++) {
        int seen = 0;
        for (unsigned sz = 0; sz <= 64; sz += 8) {
            errno = 0; long r = ioctl(vm, IOW(0x47, nr, sz), buf); int e = errno;
            if (e != ENOTTY) { printf("nr=0x%02x sz=%u ret=%ld errno=%d\n", nr, sz, r, e); seen = 1; break; }
        }
        if (!seen) printf("nr=0x%02x not implemented\n", nr);
    }
    return 0;
}
```

编译运行（手机 Termux）：`clang -O2 -o ghprobe ghprobe.c && su -c ./ghprobe`

## 附录 B：镜像信息

| | |
|---|---|
| 镜像 | `alpine-3.22.7-aarch64-uefi-tiny-r0.qcow2` |
| 大小 / sha256 | 138,805,248 B / `d6b98edfb60da4b6ab06f88a7cd2f5dbad323fc85002393f357e0fd4b5eb5f74` |
| guest 内核 | `6.12.114-0-virt`（镜像自带） |
| 引导 | UEFI（DroidVM 内置 EDK2） |
| 登录 | 串口 `ttyS0`；cloud 镜像 root 默认无密码 |

## 7. 拿到「能登录」的镜像（Alpine cloud 的 root 是锁定的）

`alpine-*-uefi-cloudinit-r0.qcow2` 靠 cloud-init 注入用户；DroidVM 不提供 seed，所以镜像里就是：

```
/etc/shadow: root:!*:...      ← 账户锁定，串口既不能空密码也没有可猜的默认密码
```

**离线注入密码 + 公钥**（镜像必须先停 VM）：

```bash
sudo ./scripts/inject-alpine-password.sh alpine.qcow2 alpine ~/.ssh/id_ed25519.pub
# -> alpine.injected.qcow2 （root/alpine，已注入公钥、PermitRootLogin yes）
```

> ⚠️ **必须在 Linux 主机上做，不要在手机上做**：DroidVM 自带的 `qemu-img` 解不开该镜像的**压缩簇**，
> `qemu-img convert` 出来的 raw **全是 0**（实测前 41 MB 非零字节数 = 0），改出来的镜像不可引导。
> 主机上正常 qemu-img（10.x）转换后 GPT/ESP 都完整。

## 8. 磁盘镜像完整性自检（换盘后必查）

| 检查 | 命令 | 正常值 |
|---|---|---|
| MAGIC | `od -A d -t x1 -N 8 disk.qcow2` | `51 46 49 fb`（`QFI\xfb`） |
| 格式/容量 | `qemu-img info disk.qcow2` | `file format: qcow2` + `virtual size: 330 MiB` |
| crosvm 识别 | `droidvm logs <id> stdio \| grep 'disk size'` | 应为 **346030080**（虚拟容量） |

若 `disk size` 等于**文件大小**（例如 139001856），说明 crosvm 把 qcow2 容器当**裸盘**处理了，
里面自然没有分区 → UEFI 找不到启动项 → 掉 PXE。

## 9. UEFI 变量存储（pflash）导致的 PXE 回退

症状：

```
BdsDxe: failed to load Boot0002 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x1,0x0): Not Found
>>Start PXE over IPv4.
```

原因：pflash 里保存的启动项指向已不存在的设备（换过盘/换过镜像后常见）。修法（VM 停止时）：

```json
"boot": { "protocol": "uefi", "uefi": { "vars_enabled": false, "vars": "", "firmware": "" } }
```

关掉 vars 后固件会走默认启动顺序，命中 ESP 里的 `EFI/BOOT/BOOTAA64.EFI`。

## 10. `GUNYAH-SHARE-BLOB ... Out of memory (os error 12)`

另一类启动失败（与 boot context 无关）：

```
GUNYAH-SHARE-BLOB: gpa=0x80600000 size=0x1f600000 flags=0x7 FAILED after 17ms: Out of memory (os error 12)
[730.854] gunyah_share: crosvm is gone but the RM still refuses label=525824 (-22)
[734.852] gunyah_share: mem_alloc FAILED ret=-12 gpa=0x80600000 size=0x1f600000 label=525824
```

两件事叠加：① 上次异常退出在 Gunyah RM 里留下的 memparcel（label = `gpa>>12`）还没释放；② 502 MB 的连续内存吃紧。

处置顺序（都不需要重启手机）：

```bash
su -c 'rmmod gunyah_host_share_gki_6.1; sleep 1; /data/adb/ksud insmod /data/data/cn.classfun.droidvm/usr/lib/modules/android14-6.1/gunyah-host-share-gki-6.1.ko'
su -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
# 然后从 App 重新 Start（512 MB 配置即可成功，实测 SHARE-BLOB 453ms）
```

> ⚠️ **`Huge-page reserve is short` 弹窗不要点 Start anyway**：实测会导致整机崩溃（需硬重启 + 重跑 GhostLock）。
> 另外 App 只接受「它自己安装的」大页模块池：手动 `insmod` 的模块虽然出现 `/dev/gh_pinprobe`，
> 但 Pool Size 一直是 0、Save 灰掉、Acquire 无效 —— 正确做法是在 App 的 HugePage 页面里 `Install` 再设池子。

## 11. Guest 网络：为什么 `apk update` 不通 + 正确配法

**症状**：guest 里 `apk update` 全是 `temporary error (try again later)`。

**根因**：VM 挂在 `Wi-Fi pseudo-bridge`（L2 伪桥）上，guest 的地址要靠**路由器** DHCP 下发；
本机实测 guest 只拿到 IPv6 链路本地地址（`ip neigh show dev br-wifi` 只有 `fe80::…`），**没有 IPv4** ⇒ 无默认路由。

**修法**：换成 **Linux bridge + L3 routing（DroidVM 自带 DHCP + SNAT）**，并补 DNS（默认 `dns_servers` 是空数组）：

```bash
su -c 'sh scripts/switch-vm-to-nat.sh <network_id> <vm_id>'
```

等价配置（`files/networks.json`）：

```json
"l3": { "dns_servers": ["1.1.1.1", "8.8.8.8"],
  "vlans": [ { "vlan_id": 0, "ipv4": { "cidr": "192.168.207.1/24", "snat": true,
      "dhcp": { "enabled": true, "offset_start": 128, "offset_end": 192 },
      "dns_servers": ["1.1.1.1", "8.8.8.8"] } } ] }
```

实测结果：guest 拿到 `192.168.207.128`（宿主 ↔ guest ping 1.5 ms），`apk update` 正常。

**路由实际怎么走**（手机上的真实规则）：

```
ip rule 9000: from all iif brded40231 lookup tun1      ← guest 流量先查 VPN 表
ip rule 9001: from all iif brded40231 lookup wlan0_local
ip rule 9002: from all iif brded40231 lookup wlan0

iptables -t nat: -A droidvm_pst_brded40231 -s 192.168.207.0/24 ! -o brded40231+ -j MASQUERADE
```

⇒ guest → 桥（192.168.207.1，DroidVM DHCP）→ SNAT → 手机当前上行（**优先 tun1 = miphone VPN**）。
conntrack 里能看到回包目的地址是 `10.231.87.3`（tun1），即 **guest 共享手机 VPN 出口**。

| 场景 | guest 能否上网 |
|---|---|
| 换 Wi-Fi | ✅（规则回落到 wlan0 表） |
| Wi-Fi + VPN | ✅（走 tun1，公网 IP = VPN 出口） |
| 只蜂窝 + VPN | ✅ |
| **只蜂窝、无 VPN** | ⚠️ 默认规则里没有 rmnet 表，`main` 表也无默认路由 → 会断；需额外加 `ip rule … lookup rmnet_dataN` |

**Alpine 侧不用改任何 IP**：`192.168.207.128/24` + 网关 `.1` 是手机内部网段，换上行不影响；
只有已建立的 TCP 连接在切换瞬间会断一下（NAT 重绑），重连即可。DNS 由 DHCP 下发，也不用改 `resolv.conf`。

## 12. 硬重启 + 重跑 GhostLock 之后的一键复原

GhostLock 是 **late-load**：KernelSU 在开机后才载入，模块的 `post-fs-data.sh` / `service.sh` **不会执行**。
所以每次重新拿到 root 后跑一次：

```bash
su -c 'sh /data/local/tmp/droidvm-bootstrap.sh'
```

它做 8 件事（幂等）：补 `/dev/gunyah_share` → 可选大页模块 → 关幻影进程监控 → 起 **root 常驻 sshd**（`su` 会重置 `HOME`，脚本显式指回 Termux 家目录）→ 校验 `vmshim.so` + crosvm 包装（App 升级覆盖后自动重建）→ 校验 VM 配置（512MB / mTHP single / hugepages true / pseudo_unprotected / uefi）→ 给关键进程打 `oom_score_adj=-1000` → 打印汇总。

## 12.1 脚本清单

| 脚本 | 用途 | 在哪跑 |
|---|---|---|
| `scripts/droidvm-bootstrap.sh` | 重启后一键复原（模块 + sshd + 包装 + 配置） | 手机 root |
| `scripts/inject-alpine-password.sh` | 给 Alpine cloud 镜像注入 root 密码/公钥 | Linux 主机 |
| `scripts/switch-vm-to-nat.sh` | 把 VM 切到 L3(NAT+DHCP) 网络并补 DNS | 手机 root |

## 参考

- DroidVM：<https://github.com/Droid-VM/DroidVM> ｜ 文档 <https://droid-vm.github.io/>
- 环境要求：<https://droid-vm.github.io/guide/requirements>
- FAQ：<https://droid-vm.github.io/guide/faq>
- `gunyah-host-share` 相关 issue 与 sm8650 内核补丁（官方 FAQ 收录）：
  - <https://github.com/Andy312432/android_kernel_samsung_sm8650_gunyah/commit/3d8767092fa186b77dfcbc5fd14b53ae17b04bb2>
  - <https://github.com/Andy312432/android_kernel_samsung_sm8650_gunyah/commit/b2ffff284b1f8b6cd79c280fb746b27fb6f0cbae>

---

## 13. 突破 512 MB：用大页池把 guest 内存做到 1 GB

### 13.1 为什么裸跑 512 MB 是上限

Gunyah 的 guest RAM 不是普通 malloc，而是由 RM 以 **memparcel** 形式从 **CMA** 出借：

```
CmaTotal = 602112 kB (588 MiB)          ← 本机硬上限
512 MB VM 的窗口 = 502 MB               → 塞得下 ✅
1 GB  VM 的窗口 = 1024 MB               → 超过 CMA 总量 ❌
kernel: 不支持 256 MB 分块出借（App 弹窗 "cannot lend in 256 MB parcels"）
调大 CMA: 只有 `cma=` cmdline / DT reserved-memory 能改 → 需刷 boot/dtbo（锁 BL 不可行）
```

### 13.2 实测的崩机记录（都是整机崩溃，需要重启 + 重跑 GhostLock）

| 触发动作 | 结果 |
|---|---|
| 1 GB VM（single，无池） | ❌ 崩机 |
| 1 GB VM（512 MB 分片） | ❌ 崩机 |
| App 大页页「Enable」 | ❌ 崩机（模块默认 `system_reserve_mb=6144`，一次要预留 6 GB） |
| App 大页页「保存」2.5 GiB | ❌ 崩机（CMA 分支） |
| `gunyah-kvcalloc` 加载后 1 GB | ❌ 仍崩（kvcalloc 解决的是页指针数组的 kmalloc，不是 CMA） |
| `ulimit -l unlimited` 后 1 GB | ❌ 仍崩 |
| 绕过 `Huge-page reserve is short` 点 Start anyway | ❌ 崩机 |

**结论：在 Gunyah 上，只要 guest 窗口 > 池子/CMA 能提供的量，就不是"报错"而是"崩机"**。
所以**绝不能超过容量**，只能先把池子做大。

### 13.3 正确的大页池用法（关键：别用 App 的 Enable/Save）

```bash
# 1) 装模块（KernelSU/Magisk 模块目录），并确认 .ko 在 load.sh 期望的位置
#    手动 unzip 安装会漏掉 customize.sh，导致 .ko 只在 ko/ 子目录 → 必须补这一步：
cp -f /data/adb/modules/gh-hugepage-reserve/ko/gh_hugepage_reserve/android14-6.1.ko \
      /data/adb/modules/gh-hugepage-reserve/gh_hugepage_reserve.ko

# 2) settings.prop（模块目录）—— 关键是 with_cma=0，关掉会崩机的 CMA 分支
cat > /data/adb/modules/gh-hugepage-reserve/settings.prop <<'P'
pool_want=512
pool_want_with_cma=0
boot_acquire=3
boot_acquire_runs=2
P

# 3) 用模块自己的 loader 加载（不是 App 的 Enable）
su -c 'sh /data/adb/modules/gh-hugepage-reserve/module/load.sh'
```

`pool_want` 单位是 **2 MiB 页**：512 = 1 GB，600 = 1.2 GB。

### 13.4 把池子继续做大

每轮 `acquire=3`（逐窗 evict）是**单向扫一遍**；被自己 evict 出来、落在扫描游标后方的窗口
只有下一轮才捡得到 → **多跑几轮**。跑之前先停 VM（否则页被它占着）。

```sh
echo 3 > /sys/module/gh_hugepage_reserve/parameters/acquire
# 轮询 acquire_active 直到 0，再看 refill_stat 的 pool_avail / acquire_stop_reason
```

`acquire_stop_reason="scanned all present memory"` = 内存已经扫完，到顶了；
想再涨只能**先腾物理内存**（关后台大 App / 清缓存）。

本仓库的 `scripts/pool.sh` 把以上封装好了：

```bash
su -c 'sh ~/droidvm/pool.sh status'        # 只看状态
su -c 'sh ~/droidvm/pool.sh 600 6'         # 目标 600 页，最多 6 轮
su -c 'sh ~/droidvm/pool.sh cancel'
```

### 13.5 三个必须同时满足的前置

| 组件 | 做法 | 作用 |
|---|---|---|
| `gunyah-kvcalloc-gki-6.1.ko` | `ksud insmod .../gunyah-kvcalloc-gki-6.1.ko` | 官方 FAQ patch#1：页指针数组改 `kvcalloc`，避免大 guest 的连续 kmalloc 失败 |
| `ulimit -l unlimited` | 写进 `usr/bin/crosvm` 包装脚本 | Gunyah 的 `account_locked_vm()` 把出借内存计入 RLIMIT_MEMLOCK，Android 默认只有 **64 KB** |
| `DROIDVM_SHIM_PARCEL_MB=512` | 同上，包装脚本里 export | 把 SHIM 窗口拆成多笔 memparcel（例如 1024 MB → 512+502） |

crosvm 包装脚本最终形态：

```sh
#!/system/bin/sh
export LD_PRELOAD=/data/data/cn.classfun.droidvm/files/vmshim.so   # 6.1 缺 GH_VM_SET_BOOT_CONTEXT
export DROIDVM_SHIM_PARCEL_MB=512
ulimit -l unlimited 2>/dev/null || ulimit -l 8388608 2>/dev/null
exec /data/data/cn.classfun.droidvm/usr/bin/crosvm.real "$@"
```

### 13.6 容量换算与实测结果

```
可开 VM 内存 ≈ (pool_total − 12) × 2 MB      # 12 页留给 shim / framebuffer / 杂项
再向下取 64 的倍数
```

| 池子 | 可开 VM（上限） | 实测 |
|---|---|---|
| 无池（裸跑） | 512 MB | ✅ 稳定 |
| 335 页 = 670 MB | 640 MB | ✅ 到 `login:` |
| 471 页 = 942 MB | 896 MB | ✅ 到 `login:` |
| 512 页 = 1024 MB | 960 MB | ✅ 到 `login:` |
| **600 页 = 1200 MB** | **1024 MB（1 GB）** | ✅ **到 `login:`，`SHARE-BLOB` 512+502 MB，`VCPU_RUN` +64,207** |

VM 设置：`memory_mb=<上面算的值>`、`prepare_lend_mthp=single`、`hugepages=true`、`protected_vm=pseudo_unprotected`。

> ⚠️ 每次改内存前先 **停 VM**；`/dev/gunyah_share` 必须在（用 `scripts/droidvm-bootstrap.sh` 或手动 `insmod gunyah-host-share`）。

### 13.7 上游文档

`gh-hugepage-reserve` 的中文 README 已快照到本仓库：[docs/gh-hugepage-reserve-README_cn.md](docs/gh-hugepage-reserve-README_cn.md)
（含 sysfs 参数契约、`settings.prop` 键、`load.sh` 阶梯、`acquire` 三模式、CMA 两个 lever 等细节）。
