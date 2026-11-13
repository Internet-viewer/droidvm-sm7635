# 已验证的构建配置与产物

本文件记录 2026-11-13 两次构建（一次从 7.2.12 全新构建、一次从回滚到 6.12 的
qcow2 重建）实际使用的参数与产物指纹。改动任何一项都应重新跑验证。

## 内核

```
包:      linux-image-7.2.12+deb13-arm64
来源:    trixie-backports
头文件:  linux-headers-7.2.12+deb13-arm64
```

启动行：

```
BOOT_IMAGE=/boot/vmlinuz-7.2.12+deb13-arm64
root=PARTUUID=4cba83b2-97b0-4b9b-8794-a7dde491028c ro
console=tty0 console=ttyS0,115200
```

GRUB：`GRUB_DEFAULT=0`、`GRUB_TIMEOUT=5`

7.x 相比 6.12 新增的 virtio-gpu 特性：`+blob_alignment`

## wayland

```
libwayland-client0  1.26.0-1~bpo13+1     (trixie-backports)
libwayland-dev      1.26.0-1~bpo13+1     (编译 Mesa 时同样必须用 backports 版)
```

必要条件：`libwayland-client.so.0` 必须导出 `wl_fixes_interface`，
否则 `libvulkan_gfxstream.so` 加载失败。

## Mesa

```
仓库:    https://github.com/Droid-VM/mesa
分支:    droidvm
版本:    26.3.0-devel
源码:    /root/mesa-droidvm
构建:    /root/build-mesa
日志:    /root/mesa-build.log
目标数:  1737
```

meson 选项（实测生效值）：

```
buildtype        = release
prefix           = /usr/local
libdir           = lib/aarch64-linux-gnu
platforms        = ['x11']
gallium-drivers  = ['zink', 'llvmpipe']
vulkan-drivers   = ['gfxstream', 'freedreno', 'virtio']
freedreno-kmds   = ['msm', 'virtio']
glvnd            = enabled
llvm             = enabled
```

产物：

```
/usr/local/lib/aarch64-linux-gnu/libgallium-26.3.0-devel.so     25147408 字节
/usr/local/lib/aarch64-linux-gnu/libvulkan_gfxstream.so          3108192 字节
/usr/local/share/vulkan/icd.d/gfxstream_vk_icd.aarch64.json           204 字节
/usr/local/share/vulkan/icd.d/freedreno_icd.aarch64.json              204 字节
/usr/local/share/vulkan/icd.d/virtio_icd.aarch64.json                 201 字节
```

注意 ICD 文件名在 arm64 上带 `.aarch64` 后缀。

gfxstream ICD 内容：

```json
{
    "ICD": {
        "api_version": "1.1.358",
        "library_arch": "64",
        "library_path": "/usr/local/lib/aarch64-linux-gnu/libvulkan_gfxstream.so"
    },
    "file_format_version": "1.0.1"
}
```

### 构建里程碑

用于判断一次构建卡在哪一段：

```
[  117/1737]  src/util                    ralloc / 基础工具
[  369/1737]  src/compiler/nir            着色器编译器
[  619/1737]  src/mesa                    GL 状态机
[ 1019/1737]  src/gallium/drivers/zink    zink（关键）
[ 1288/1737]  src/vulkan/runtime          Vulkan runtime
[ 1601/1737]  src/freedreno/vulkan        freedreno
[ 1654/1737]  src/gfxstream/guest/vulkan   gfxstream（关键 ICD）
[ 1737/1737]  linking libdril_dri.so / dri_gbm.so
```

`-j4` 全程约 95 分钟。

## guest-additions

```
仓库:    https://github.com/Droid-VM/droidvm-guest-additions
分支:    droidvm
commit:  cccd907  "virtio_gpu: probe the venus_host pool node"
源码:    /root/ga7
```

7.2 API 适配（`struct drm_atomic_state *` → `struct drm_atomic_commit *`）：

| 文件 | 替换处数 |
|------|----------|
| `virtio_gpu/virtgpu_display.c` | 4 |
| `virtio_gpu/virtgpu_plane.c` | 3 |

产物（**两次独立构建逐字节相同**，可作为复现性的判据）：

```
gunyah_guest/gunyah_guest.ko     442472 字节
virtio_gpu/virtio-gpu.ko        5207952 字节
```

安装位置：

```
/lib/modules/7.2.12+deb13-arm64/updates/droidvm/gunyah_guest.ko
/lib/modules/7.2.12+deb13-arm64/updates/droidvm/virtio-gpu.ko
```

运行时 `lsmod` 显示 `virtio_gpu 102400`（补丁版）而非原版 `90112`。

## 持久化配置

必须三处齐全，否则重启会退回原版驱动：

**`/etc/initramfs-tools/modules`** — 决定 initramfs 打包哪一份

```
virtio_gpu
```

原因：`virtio_gpu` 会被打进 initramfs 并在根文件系统挂载**之前**加载。若不指定，
打包的是 `kernel/drivers/gpu/drm/virtio/virtio-gpu.ko.xz`（原版）；指定后打包
`updates/droidvm/virtio-gpu.ko`（补丁版）。之后 `modprobe` 只是复用已加载模块，
所以这一步漏了会**静默**退回原版。

**`/etc/modprobe.d/droidvm-ga.conf`** — 加载顺序

```
softdep virtio_gpu pre: gunyah_guest virtio_dma_buf
```

**`/etc/modules-load.d/droidvm-ga.conf`** — 开机自动加载

```
virtio_dma_buf
gunyah_guest
virtio_gpu
```

## Xorg

**`/etc/lightdm/lightdm.conf.d/60-droidvm-zink.conf`**

```
[Seat:*]
xserver-command=/usr/bin/env MESA_LOADER_DRIVER_OVERRIDE=zink VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/gfxstream_vk_icd.aarch64.json VK_ICD_FILENAMES=/usr/local/share/vulkan/icd.d/gfxstream_vk_icd.aarch64.json X -core
```

写 `/etc/profile.d/` 是**无效的** —— lightdm 以干净环境启动 Xorg，读不到。

## 运行时指纹

```
Vulkan deviceName   = Virtio-GPU GFXStream (Adreno (TM) 810)
Vulkan apiVersion   = 1.4.359
Vulkan driverVersion= 26.2.99
Vulkan vendorID     = 0x5143
Vulkan deviceID     = 0x44010000
deviceType          = PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU

GL renderer         = zink Vulkan 1.4(Virtio-GPU GFXStream (Adreno (TM) 810) (MESA_GFXSTREAM))
GL version          = Mesa 26.3.0-devel
Accelerated         = yes
```

## 跑分（glmark2，1024x600）

| 场景 | FPS 范围 | FrameTime |
|------|----------|-----------|
| build | 369 – 583 | 1.717 – 2.712 ms |
| texture | 432 – 679 | 1.475 – 2.318 ms |
| shading | 333 – 540 | 1.853 – 3.011 ms |

波动来自 VM 负载与 thermal 状态，不是渲染栈不稳定。最好的一组出现在
Mesa 全量重建后的首次运行（build 583 / shading 540）。

## 宿主机环境

```
手机:    Redmi Note 14 Pro+ 5G，型号 24115RA8EC，代号 amethyst
SoC:     Qualcomm SM7635 (Snapdragon 7s Gen 3)
GPU:     Qualcomm Adreno 810
Android: 16
VM:      DroidVM (cn.classfun.droidvm) + crosvm
crosvm:  context-types=gfxstream-vulkan, vulkan=true
```

VM 侧 GPU 配置：

```
gpu_mode     = gfxstream
gpu_backend  = gpu_gfxstream
gpu_provider = vk_gfxstream
```

## 已知环境问题（与 GPU 无关）

1. **guest 内 `reboot` 后 crosvm 有时不自启**，表现为 `No route to host`。
   在手机上重跑 `boot_now.py` 即可。6.12 时代就存在。
2. **termux → guest 的 SSH 隧道会间歇断开**，且 Termux 进后台会被 Android 挂起
   连带断掉隧道。长任务务必放 guest 内的 tmux。
3. 从 termux 里用 `am start` 拉起 DroidVM 会重启应用进程，从而打断隧道 ——
   手动点开应用更稳。
