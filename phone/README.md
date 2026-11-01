# ~/droidvm — DroidVM 手机端脚本集

在这台 **Redmi Note 14 Pro+（Snapdragon 7s Gen 3 / SM7635，内核 6.1.138-android14-11）**
上把 DroidVM 跑起来、并把 guest 内存从 512 MB 做到 1 GB 的完整脚本。

> 完整背景、崩机记录与原理见 GitHub 仓库：
> <https://github.com/Internet-viewer/droidvm-sm7635>
> 上游大页模块中文文档快照：`docs/gh-hugepage-reserve-README_cn.md`

---

## 快速开始

```bash
# 1) 环境（重启/重跑 GhostLock 后都要跑一次）
su -c 'sh ~/droidvm/setup.sh'

# 2) 看池子和建议内存
su -c 'sh ~/droidvm/pool.sh status'

# 3) 扩容池子（先停 VM，再杀点后台 App 效果更好）
su -c 'sh ~/droidvm/pool.sh 600 6'

# 4) 按池子设 VM 内存并启动
su -c 'sh ~/droidvm/vm.sh max'          # 看看能开多大
su -c 'sh ~/droidvm/vm.sh set 1024'
su -c 'sh ~/droidvm/vm.sh start'
```

---

## 脚本一览

| 脚本 | 作用 |
|---|---|
| `setup.sh` | 一键环境：`/dev/gunyah_share`、`gunyah-kvcalloc`、大页模块、root sshd、crosvm 包装、VM 配置校验。幂等 |
| `pool.sh` | 大页池扩容。`status` / `cancel` / `<目标页数> <轮数>`（1024 页 = 2 GB） |
| `vm.sh` | VM 管理。`status` / `max` / `set <MB>` / `start` / `stop` / `logs [serial1\|stdio]` |

---

## 运行时必需的四件套（缺一不可）

| 组件 | 为什么 |
|---|---|
| `/dev/gunyah_share`（`gunyah-host-share` 模块） | crosvm 在 `GH_VM_START` 之后要 `open()` 它给 guest 递 memparcel；缺了就是 `ENOENT` |
| `vmshim.so` + crosvm 包装 | 本机 6.1 内核**没有** `GH_VM_SET_BOOT_CONTEXT(0x0a)`，用 LD_PRELOAD 假成功；包装脚本注入（`setprop wrap.*` 传不到子进程） |
| `gunyah-kvcalloc` | 官方 patch#1：大 guest 的页指针数组改 `kvcalloc`，避免连续 kmalloc 失败 |
| crosvm 里的 `ulimit -l unlimited` | Gunyah 的 `account_locked_vm()` 把出借内存计入 RLIMIT_MEMLOCK，Android 默认只有 **64 KB** |

crosvm 包装脚本（`setup.sh` 会自动写好）：

```sh
#!/system/bin/sh
export LD_PRELOAD=/data/data/cn.classfun.droidvm/files/vmshim.so
export DROIDVM_SHIM_PARCEL_MB=512
ulimit -l unlimited 2>/dev/null || ulimit -l 8388608 2>/dev/null
exec /data/data/cn.classfun.droidvm/usr/bin/crosvm.real "$@"
```

---

## 内存上限怎么算

Gunyah 的 guest RAM 由 RM 用 CMA/memparcel 出借，本机 `CmaTotal` 只有 **588 MiB**，
且内核**不支持 256 MB 分块出借** ⇒ 裸跑上限 512 MB，再大不是报错而是**整机崩溃**。

大页池（`gh-hugepage-reserve`）把预留的 2 MiB 页借给 VM，绕开 CMA 碎片：

```
可开 VM 内存 ≈ (pool_total − 12) × 2 MB      # 12 页留给 shim/framebuffer
再向下取 64 的倍数
```

| 池子 | 可开 VM | 实测 |
|---|---|---|
| 无池 | 512 MB | ✅ |
| 335 页 (670 MB) | 640 MB | ✅ |
| 471 页 (942 MB) | 896 MB | ✅ |
| 512 页 (1024 MB) | 960 MB | ✅ |
| 600 页 (1200 MB) | **1024 MB** | ✅ |

VM 配置固定：`prepare_lend_mthp=single`、`hugepages=true`、`protected_vm=pseudo_unprotected`、`boot.protocol=uefi`。

---

## 常见坑

| 现象 | 原因 / 处置 |
|---|---|
| `failed to initialize virtual machine: No such file or directory (2)` | 缺 `/dev/gunyah_share` → 跑 `setup.sh` |
| `GH_VM_SET_BOOT_CONTEXT failed` | crosvm 包装丢了（App 升级会覆盖）→ 重跑 `setup.sh` |
| `SHARE-BLOB ... Out of memory (12)` | VM 内存 > 池子容量 → `pool.sh` 扩容，或 `vm.sh set $(vm.sh max)` |
| **整机崩溃重启** | 超过池子容量 / 点了 App 大页页的 **Enable/保存**（CMA 分支）→ 只用 `pool.sh`，别用 App 那两个按钮 |
| 大页模块加载报 `Invalid magic number: 0x0` | 崩机把 `.ko` 写坏了 → 从 zip 重解；`setup.sh` 会补 `.ko` 路径 |
| `pool.sh` 报 `pool_want` 写失败 | 有 acquire 在跑 → `pool.sh cancel` 再试 |
| 重启后什么都没了 | GhostLock 是 late-load，模块开机钩子不执行 → 重跑 `setup.sh` 和 `pool.sh` |
| ssh 连不上（banner timeout / 公钥被拒） | `setup.sh` 会以 root 常驻方式起 sshd 并显式指定 `AuthorizedKeysFile` |

---

## 常用查询

```bash
# 池子细节
cat /sys/module/gh_hugepage_reserve/parameters/refill_stat | grep -E 'pool_avail|pool_total|acquire_stop_reason'
# 当前 IO 轨迹（bootctx shim 记录）
tail -20 /data/data/cn.classfun.droidvm/files/vmshim-load.log
# 取证目录（vm.sh start 会生成）
ls -dt /data/local/tmp/forensics-* | head
```
