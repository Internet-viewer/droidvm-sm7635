# Debian 13 GPU 硬件加速 — 完整安装与配置指南

**目标设备**：Redmi Note 14 Pro+ 5G (SM7635 / amethyst)，DroidVM

**结果**：Debian 13 (trixie) guest 内 GPU 硬件加速打通，Vulkan + OpenGL 全部走 Adreno 810。

```
CPU:    Snapdragon SM7635
GPU:    Qualcomm Adreno 810
Guest:  Debian GNU/Linux 13.7 (trixie)
Kernel: 7.2.12+deb13-arm64  (trixie-backports)
```

---

## 0. 成果速览

### 渲染栈

```
Vulkan: Virtio-GPU GFXStream (Adreno (TM) 810)
        apiVersion    1.4.359
        driverVersion 26.2.99
        vendorID      0x5143
        deviceType    PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU

OpenGL: zink Vulkan 1.4(Virtio-GPU GFXStream (Adreno (TM) 810) (MESA_GFXSTREAM))
        Mesa 26.3.0-devel
        Accelerated: yes
```

### glmark2 跑分（1024x600）

| 场景 | FPS | FrameTime | Score |
|------|-----|-----------|-------|
| build | 369–583 | 1.717–2.712 ms | 368–582 |
| **texture** | **432–679** | **1.475–2.318 ms** | 431–678 |
| shading | 333–540 | 1.853–3.011 ms | 332–539 |

波动主要来自虚拟机负载与 thermal 状态，不是渲染栈本身不稳定。
最好的一组（build 583 / shading 540）出现在 Mesa 全量重建后的首次运行。
所有数字都是在 **guest 内原生运行**，无任何 CPU 回退（`llvmpipe` 未参与）。

### 重启后自动生效

所有配置已持久化，**重启后零手动操作**即可获得硬件加速：

```
$ lsmod | grep virtio_gpu
virtio_gpu   102400   14      ← 补丁版，从 initramfs 自动加载
```

---

## 1. 前提与关键结论

### 1.1 必须用 7.x 内核

guest-additions 是围绕 Linux 7.x 的 DRM 写的。在 6.12 上移植代价极大且**必然失败**：

```
Internal error: Oops: 0000000096000044 [#1] SMP
pc : __drm_fb_helper_initial_config_and_unlock+0x2ec/0x5f0 [drm_kms_helper]
```

**正确做法：装 trixie-backports 的 7.2.12 内核**，让驱动在它的原生环境里编译。7.x 上只需改 6 处类型签名。

### 1.2 不要用预编译的 mesa-guest 包

它要求 **GLIBC_2.43**，而 Debian 13 是 **2.41**；而且它装到
`/usr/local/lib/aarch64-linux-gnu/`，该路径在 `/etc/ld.so.conf.d/` 里排在系统库**前面**，
会直接打崩整个 GL 栈：

```
eglInitialize failed
couldn't find RGB GLX visual
```

若不慎装了：`sudo apt purge mesa-guest && sudo ldconfig`

### 1.3 在 guest 本机编译 Mesa

交叉编译（x86 机器 + qemu-user 跑 `debian:trixie` arm64 容器）可行，但 1737 个目标约需
**3 小时**（每分钟 5–10 个）。**guest 本机原生编译约 1.5 小时**，且 ABI 天然匹配。

---

## 2. 安装步骤

### 2.1 启用 backports 并安装 7.2.12 内核

Debian 13 的 `/etc/apt/sources.list.d/debian.sources` 默认已含 `trixie-backports`
（检查 `Suites:` 行是否包含）。

```sh
sudo apt update
sudo apt install -y -t trixie-backports \
    linux-image-7.2.12+deb13-arm64 \
    linux-headers-7.2.12+deb13-arm64
sudo update-grub
sudo reboot          # 重启后 uname -r 应为 7.2.12+deb13-arm64
```

验证 GRUB 默认项指向新内核：

```sh
awk '/^menuentry .Debian GNU.Linux/{f=1} f && /linux.*vmlinuz/{print; exit}' /boot/grub/grub.cfg
# 应显示 /boot/vmlinuz-7.2.12+deb13-arm64
```

7.x 内核的 virtio-gpu 特性比 6.12 多一项：

```
[drm] features: +virgl +edid +resource_blob +host_visible
[drm] features: +context_init +blob_alignment      ← blob_alignment 是 7.x 新增
```

### 2.2 升级 wayland 到 ≥ 1.24（Mesa 26.3 要求）

Debian 13 自带 wayland **1.23.1**，`libvulkan_gfxstream.so` 会因缺少
`wl_fixes_interface` 符号而无法加载：

```
undefined symbol: wl_fixes_interface
```

用 backports 的 **1.26.0**：

```sh
sudo apt install -y -t trixie-backports \
    libwayland-client0 libwayland-server0 libwayland-egl1 libwayland-cursor0

# 若之后要编译 Mesa，dev 包也必须从 backports 装，否则版本冲突：
sudo apt install -y -t trixie-backports libwayland-dev wayland-protocols
```

验证符号存在：

```sh
nm -D /usr/lib/aarch64-linux-gnu/libwayland-client.so.0 | grep -c wl_fixes_interface
# 期望 >= 1
```

### 2.3 编译 Mesa 26.3

依赖：

```sh
sudo apt install -y meson ninja-build cmake glslang-tools pkg-config \
    python3-mako python3-yaml build-essential bison flex llvm-dev \
    libdrm-dev libexpat1-dev zlib1g-dev libzstd-dev \
    libx11-dev libx11-xcb-dev libxext-dev libxrandr-dev libxfixes-dev \
    libxxf86vm-dev libxcb1-dev libxcb-dri2-0-dev libxcb-dri3-dev \
    libxcb-present-dev libxcb-sync-dev libxcb-glx0-dev libxcb-shm0-dev \
    libxshmfence-dev libglvnd-dev libudev-dev
```

**用 tarball 而不是 `git clone`** —— 手机网络下 clone 经常在打包阶段失败
（`tmp_pack` 丢失）：

```sh
curl -L -o /root/mesa.tar.gz \
  https://github.com/Droid-VM/mesa/archive/refs/heads/droidvm.tar.gz
tar xzf /root/mesa.tar.gz           # -> /root/mesa-droidvm/
```

配置与编译：

```sh
cd /root
meson setup build-mesa mesa-droidvm \
  --buildtype release --prefix /usr/local --libdir lib/aarch64-linux-gnu \
  -Dplatforms=x11 \
  -Dgallium-drivers=zink,llvmpipe \
  -Dvulkan-drivers=gfxstream,freedreno,virtio \
  -Dfreedreno-kmds=msm,virtio \
  -Dglvnd=enabled -Dllvm=enabled
ninja -C build-mesa -j4
sudo ninja -C build-mesa install
sudo ldconfig
```

产物：

```
/usr/local/share/vulkan/icd.d/gfxstream_vk_icd.aarch64.json
/usr/local/share/vulkan/icd.d/freedreno_vk_icd.aarch64.json
/usr/local/share/vulkan/icd.d/virtio_icd.aarch64.json
/usr/local/lib/aarch64-linux-gnu/libgallium-26.3.0-devel.so
```

> **注意**：若 meson 需要显式指定 python，用 native-file，并且把它放在
> **非 `/tmp`** 的路径下（如 `/root/native.ini`）。`/tmp` 被清理后 `ninja`
> 会因找不到 native-file 而无法重新生成 `build.ninja`。

### 2.4 编译 guest-additions（7.2 需改 6 处签名）

```sh
git clone -b droidvm https://github.com/Droid-VM/droidvm-guest-additions /root/ga7
```

**7.2.12 的 API 变化**：DRM atomic 回调的第二个参数从 `struct drm_atomic_state *`
改成了 `struct drm_atomic_commit *`。

需要修改的文件与函数：

`virtio_gpu/virtgpu_display.c`（4 个）：

| 函数 |
|------|
| `virtio_gpu_crtc_atomic_enable` |
| `virtio_gpu_crtc_atomic_disable` |
| `virtio_gpu_crtc_atomic_check` |
| `virtio_gpu_crtc_atomic_flush` |

`virtio_gpu/virtgpu_plane.c`（2 个）：

| 函数 | 说明 |
|------|------|
| `virtio_gpu_plane_atomic_check` | 约 253 行 |
| `virtio_gpu_primary_plane_update` / `virtio_gpu_cursor_plane_update` | 约 446 行附近 |

一次性正则替换：

```python
import re
for P in ("/root/ga7/virtio_gpu/virtgpu_display.c",
          "/root/ga7/virtio_gpu/virtgpu_plane.c"):
    s = open(P).read()
    s = re.sub(r"struct drm_atomic_state \*state\)",
               "struct drm_atomic_commit *state)", s)
    open(P, "w").write(s)
```

编译：

```sh
cd /root/ga7
make KDIR=/lib/modules/7.2.12+deb13-arm64/build
```

产物：

```
gunyah_guest/gunyah_guest.ko    442472 字节
virtio_gpu/virtio-gpu.ko       5207952 字节
```

### 2.5 安装模块

```sh
sudo mkdir -p /lib/modules/$(uname -r)/updates/droidvm
sudo cp /root/ga7/gunyah_guest/gunyah_guest.ko \
        /root/ga7/virtio_gpu/virtio-gpu.ko \
        /lib/modules/$(uname -r)/updates/droidvm/
sudo depmod -a
```

验证 `depmod` 解析到补丁版：

```sh
modinfo -F filename virtio_gpu
# /lib/modules/7.2.12+deb13-arm64/updates/droidvm/virtio-gpu.ko
```

加载并验证：

```sh
sudo systemctl stop lightdm
sudo rmmod virtio_gpu 2>/dev/null
sudo modprobe gunyah_guest
sudo modprobe virtio_gpu
```

期望 dmesg：

```
gunyah_guest: RM client ready (tx_capid=... rx_capid=...)
gunyah_accept virtio8: gunyah accept transport ready (rm available), pool queue up
[drm] features: +virgl +edid +resource_blob +host_visible
[drm] features: +context_init
[drm] Initialized virtio_gpu 0.1.0 for 0000:00:03.0 on minor 0
```

`lsmod` 应显示 `virtio_gpu 102400`（补丁版），**Oops 计数为 0**。

### 2.6 持久化：让重启后自动加载补丁版

**这一步容易漏掉。** `virtio_gpu` 可能已被打进 **initramfs**，会在根文件系统挂载
**之前**就加载原版驱动，之后 `modprobe` 只是复用已加载的模块，导致重启后永远是
原版（90112）而不是补丁版（102400）。

检查：

```sh
lsinitramfs /boot/initrd.img-$(uname -r) | grep -i virtio-gpu
# 若出现 usr/lib/modules/.../kernel/drivers/gpu/drm/virtio/virtio-gpu.ko.xz
# 说明会先加载原版
```

修复 —— 三个配置文件：

```sh
# (a) 让 initramfs 打包补丁版模块
echo 'virtio_gpu' | sudo tee -a /etc/initramfs-tools/modules

# (b) 保证 gunyah_guest 在 virtio_gpu 之前加载
sudo tee /etc/modprobe.d/droidvm-ga.conf >/dev/null <<'EOF'
# DroidVM guest additions: load gunyah_guest before the patched virtio-gpu
softdep virtio_gpu pre: gunyah_guest virtio_dma_buf
EOF

# (c) 开机自动加载
sudo tee /etc/modules-load.d/droidvm-ga.conf >/dev/null <<'EOF'
virtio_dma_buf
gunyah_guest
virtio_gpu
EOF
```

重建 initramfs 并验证打包了补丁版：

```sh
sudo update-initramfs -u -k $(uname -r)
lsinitramfs /boot/initrd.img-$(uname -r) | grep -i virtio-gpu
# 应显示 usr/lib/modules/.../updates/droidvm/virtio-gpu.ko
#                                                    ^^^^^^^^^^^^^^^ 补丁版路径
```

重启后验证：

```sh
uname -r                      # 7.2.12+deb13-arm64
lsmod | grep virtio_gpu       # virtio_gpu 102400  ← 补丁版
```

### 2.7 让 Xorg 走 zink

Mesa 的 zink 环境变量只写在 `/etc/profile.d/` 是**没用的** —— Xorg 由 lightdm
以干净环境启动，读不到。必须注入到 `xserver-command`：

```sh
sudo mkdir -p /etc/lightdm/lightdm.conf.d
sudo tee /etc/lightdm/lightdm.conf.d/60-droidvm-zink.conf >/dev/null <<'EOF'
[Seat:*]
xserver-command=/usr/bin/env MESA_LOADER_DRIVER_OVERRIDE=zink VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/gfxstream_vk_icd.aarch64.json VK_ICD_FILENAMES=/usr/local/share/vulkan/icd.d/gfxstream_vk_icd.aarch64.json X -core
EOF
sudo systemctl stop lightdm; sleep 3; sudo pkill -9 Xorg; sleep 2
sudo systemctl start lightdm
```

验证：

```sh
grep -E "glamor.*enabled" /var/log/Xorg.0.log
# glamor X acceleration enabled on zink Vulkan 1.4(Virtio-GPU GFXStream (Adreno (TM) 810))

su - dvmuser -c 'DISPLAY=:0 glxinfo -B | grep -E "Device|Accelerated"'
# Device: zink Vulkan 1.4(Virtio-GPU GFXStream (Adreno (TM) 810) (MESA_GFXSTREAM))
# Accelerated: yes
```

---

## 3. 验证清单

```sh
# 1) 内核
uname -r                                  # 7.2.12+deb13-arm64

# 2) 模块（必须是 102400）
lsmod | grep -E 'virtio_gpu|gunyah_guest'
# virtio_gpu      102400  14
# gunyah_guest     24576  1 virtio_gpu

# 3) 无内存错误
dmesg | grep -icE 'Oops|BUG:|general protection'

# 4) Vulkan
vulkaninfo --summary | grep -E 'deviceName|apiVersion'
# deviceName = Virtio-GPU GFXStream (Adreno (TM) 810)
# apiVersion = 1.4.359

# 5) OpenGL
glxinfo -B | grep -E 'OpenGL renderer|Accelerated'
# OpenGL renderer: zink Vulkan 1.4(Virtio-GPU GFXStream ...)
# Accelerated: yes

# 6) 跑分
glmark2 --benchmark build:texture:shading
```

---

## 4. 踩过的坑

| # | 坑 | 现象 | 解法 |
|---|----|------|------|
| 1 | 用 6.x 内核 | fbdev Oops；需移植 buddy API | **装 backports 7.2.12** |
| 2 | 预编译 mesa-guest | 需 GLIBC_2.43；且劫持 ld.so 路径 | 本机编译；`apt purge mesa-guest` |
| 3 | wayland < 1.24 | `undefined symbol: wl_fixes_interface` | backports 升到 1.26 |
| 4 | `git clone` Mesa | 手机上频繁中途失败（tmp_pack 丢失） | 改用 tarball（111 MB，31 秒） |
| 5 | `CONFIG_GPU_BUDDY` 隐藏 bool | 手写进 `.config` 被 syncconfig 剥掉 | 仅 6.12 移植需要；7.x 不再需要 |
| 6 | meson native-file 放 /tmp | `/tmp` 清理后 ninja 无法 regenerate | 放 `/root/native.ini` |
| 7 | dkms 残留 | `lsmod` 仍显示旧版驱动 | 删 `updates/dkms/` 后 `depmod -a` |
| 8 | **initramfs 抢先加载原版** | 重启后 `virtio_gpu` 是 90112 而非 102400 | 把补丁版加入 `/etc/initramfs-tools/modules` 并重建 initramfs |
| 9 | zink 环境变量写在 profile.d | Xorg 读不到，仍是 llvmpipe | 注入 `lightdm.conf.d` 的 `xserver-command` |
| 10 | 内核模块树被删 | `/lib/modules/*/kernel/drivers/gpu/drm/virtio/` 空 | `apt-get download linux-image-* && dpkg-deb -x` |

---

## 5. 从干净的 6.12 镜像重建（实操时间线）

把 qcow2 还原到装 backports 之前的状态（`6.12.116+deb13-arm64`、wayland 1.23.1、
无 `updates/droidvm/`），按上面流程重走一遍的实际耗时：

| 阶段 | 耗时 | 备注 |
|------|------|------|
| `apt install` 7.2.12 image+headers | ~12 min | 包大，网络是瓶颈 |
| 重启进 7.2.12 | ~5 min | VM 重启后可能不自启，需 `boot_now.py` 再拉一次 |
| wayland 升 1.26 | ~3 min | |
| Mesa 构建依赖 | ~8 min | |
| 下载 Mesa tarball (111 MB) | ~6 min | |
| **Mesa 编译 1737/1737** | **~95 min** | `-j4`，与 guest 并行编译 guest-additions |
| guest-additions 编译 | ~6 min | `-j2`，可与 Mesa 并行 |
| 持久化 + initramfs 重建 | ~4 min | |
| 验证 + 跑分 | ~10 min | |

**总计约 2.5 小时**，其中 Mesa 编译占 60%。

### 并行技巧

Mesa 编译期间可以同时完成 guest-additions 的编译（`make -j2`），两者互不依赖；
但不要同时跑 `ninja -j4` 和 `make -j4`，4 核 guest 会因换页而明显变慢。

### Mesa 进度自查

```sh
# 后台启动
tmux new -d -s mesa 'cd /root && ninja -C build-mesa -j4 > /root/mesa-build.log 2>&1; echo EXIT=$? >> /root/mesa-build.log'
# 查进度
tail -1 /root/mesa-build.log          # [1288/1737] Compiling ...
grep 'EXIT=' /root/mesa-build.log     # EXIT=0 表示成功
```

构建过程中的阶段性里程碑（可用于判断卡在哪一段）：

```
[  117/1737]  src/util              ralloc / 基础工具
[  369/1737]  src/compiler/nir      着色器编译器
[  619/1737]  src/mesa              GL 状态机
[ 1019/1737]  src/gallium/drivers/zink
[ 1288/1737]  src/vulkan/runtime
[ 1601/1737]  src/freedreno/vulkan
[ 1654/1737]  src/gfxstream/guest/vulkan   ← 关键 ICD
[ 1737/1737]  linking libdril_dri.so / dri_gbm.so
```

---

## 6. 回滚

```sh
# 回到原版内核（保留 7.2.12 在 GRUB 中可选）
sudo grub-reboot 1 && sudo reboot

# 移除补丁驱动
sudo rm -rf /lib/modules/$(uname -r)/updates/droidvm
sudo depmod -a

# 移除持久化配置
sudo rm -f /etc/modprobe.d/droidvm-ga.conf \
           /etc/modules-load.d/droidvm-ga.conf \
           /etc/lightdm/lightdm.conf.d/60-droidvm-zink.conf
sudo sed -i '/^virtio_gpu$/d' /etc/initramfs-tools/modules
sudo update-initramfs -u -k $(uname -r)
```

---

## 7. 环境摘要

| 项 | 值 |
|----|-----|
| 手机 | Redmi Note 14 Pro+ 5G，型号 24115RA8EC，代号 amethyst |
| SoC | Qualcomm SM7635 (Snapdragon 7s Gen 3) |
| GPU | Qualcomm Adreno 810 |
| Android | 16 |
| VM 方案 | DroidVM (`cn.classfun.droidvm`) + crosvm |
| Guest OS | Debian GNU/Linux 13.7 (trixie) |
| 内核 | 7.2.12+deb13-arm64 (trixie-backports) |
| Mesa | 26.3.0-devel（本机编译） |
| wayland | 1.26.0-1~bpo13+1 |
| GPU 后端 | `gpu_mode=gfxstream`, `gpu_backend=gpu_gfxstream`, `gpu_provider=vk_gfxstream` |
| crosvm 参数 | `context-types=gfxstream-vulkan`, `vulkan=true` |

---

## 8. 时间线

- **2026-11-13** — 从 6.12 移植方案切换到 backports 7.2.12，6 处 API 适配后一次通过。
  完成 zink + gfxstream 全链路验证，glmark2 texture 达 679 FPS。
  修补 initramfs 抢先加载问题，实现重启后零干预自动生效。
- **2026-11-13（二次）** — qcow2 还原到 backports 之前后完整重走一遍，全流程 2.5 小时。
  Mesa 1737/1737 EXIT=0，glmark2 build 583 / shading 540（该次为历史最好）。
  确认流程可重复：两次构建产出的 guest-additions 尺寸逐字节相同
  （`gunyah_guest.ko` 442472、`virtio-gpu.ko` 5207952）。
- **已知环境问题**：VM 内 `reboot` 后 crosvm 偶尔不会自动拉起新实例，表现为
  `No route to host`。此时在手机上重跑 `boot_now.py` 即可；与 GPU 配置无关（6.12 时代就有）。
  termux 到 guest 的 SSH 隧道也会间歇断开，长任务建议在 guest 内用 tmux 承载。
