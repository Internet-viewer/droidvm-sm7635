# Debian 13 GPU 加速 — 构建脚本

三个脚本，覆盖从裸 6.12 镜像到硬件加速的完整链路。全部在 **guest 内以 root 运行**。

## 脚本一览

| 脚本 | 作用 | 耗时 |
|------|------|------|
| `install-debian13-gpu.sh` | 内核 / wayland / 持久化 / Xorg / 验证 | ~20 min（不含 Mesa） |
| `build-mesa.sh` | 原生编译 Mesa 26.3 | **~95 min** |
| `build-guest-additions.sh` | 编译并安装 guest-additions | ~6 min |

## 完整流程

```sh
# 1. 装 7.2.12 内核（之后必须重启）
bash install-debian13-gpu.sh kernel
reboot

# 2. 重启回来后继续
bash install-debian13-gpu.sh wayland

# 3. 编译 Mesa（长任务，建议放 tmux）
tmux new -d -s mesa 'bash build-mesa.sh all'
tmux attach -t mesa            # 观察
bash build-mesa.sh status      # 或者从别的会话查进度

# 4. 编译 guest-additions（可与 Mesa 并行）
bash build-guest-additions.sh all

# 5. 持久化 + Xorg 配置
bash install-debian13-gpu.sh persist
bash install-debian13-gpu.sh xorg

# 6. 验证
bash install-debian13-gpu.sh verify
```

一步到位（会依次执行，Mesa 阶段很慢）：

```sh
bash install-debian13-gpu.sh all
```

## 各阶段细节

### install-debian13-gpu.sh

| 子命令 | 内容 | 关键校验 |
|--------|------|----------|
| `kernel` | 装 `trixie-backports` 的 7.2.12 image+headers | 提示重启 |
| `wayland` | 升到 1.26（backports） | 确认 `wl_fixes_interface` 符号存在 |
| `mesa` | 转调 build-mesa.sh | — |
| `ga` | 转调 build-guest-additions.sh | — |
| `persist` | initramfs + modprobe + modules-load | 确认 initramfs 内含补丁版 |
| `xorg` | lightdm 注入 zink 环境 | 确认 Xorg 日志出现 `glamor ... on zink` |
| `verify` | 全栈检查 | 驱动尺寸、Oops 计数、Vulkan、GL |

### build-mesa.sh

```sh
bash build-mesa.sh deps        # 装依赖（含 backports 的 wayland dev）
bash build-mesa.sh fetch       # 下载 tarball 并解压到 /root/mesa-droidvm
bash build-mesa.sh configure   # meson setup /root/build-mesa
bash build-mesa.sh build       # ninja -j4，日志 /root/mesa-build.log
bash build-mesa.sh install     # ninja install + ldconfig
bash build-mesa.sh status      # 查进度与产物
```

固定选项（改动会导致 zink/gfxstream 链路断裂）：

```
--buildtype release  --prefix /usr/local  --libdir lib/aarch64-linux-gnu
-Dplatforms=x11
-Dgallium-drivers=zink,llvmpipe
-Dvulkan-drivers=gfxstream,freedreno,virtio
-Dfreedreno-kmds=msm,virtio
-Dglvnd=enabled  -Dllvm=enabled
```

**为什么必须本机编译**：DroidVM 的预编译 `mesa-guest` 包要求 `GLIBC_2.43`，
Debian 13 只有 `2.41`；且它装到 `/usr/local/lib/aarch64-linux-gnu/`，该路径在
`ld.so.conf` 中排在系统库**前面**，会直接打崩整个 GL 栈。

### build-guest-additions.sh

```sh
bash build-guest-additions.sh fetch    # clone 分支 droidvm
bash build-guest-additions.sh patch    # 6 处 API 适配（幂等）
bash build-guest-additions.sh build    # make KDIR=/lib/modules/<ver>/build
bash build-guest-additions.sh install   # 装到 updates/droidvm + depmod
bash build-guest-additions.sh clean
```

`patch` 做的是 7.2 的 API 适配 —— atomic 回调第二参数改名：

| 文件 | 函数 |
|------|------|
| `virtgpu_display.c` | `crtc_atomic_enable` / `disable` / `check` / `flush` |
| `virtgpu_plane.c` | `plane_atomic_check`、primary/cursor plane update |

`install` 会断言 `modinfo -F filename virtio_gpu` 解析到 `updates/droidvm/`。
如果解析到 `updates/dkms/`，说明有旧 dkms 包残留，先
`rm -rf /lib/modules/$(uname -r)/updates/dkms && depmod -a`。

## 常见错误

| 报错 | 原因 | 处理 |
|------|------|------|
| `找不到内核构建目录` | 7.2.12 没装或没重启 | `bash install-debian13-gpu.sh kernel` + reboot |
| `undefined symbol: wl_fixes_interface` | wayland < 1.24 | `bash install-debian13-gpu.sh wayland` |
| `eglInitialize failed` | 装了预编译 mesa-guest | `apt purge mesa-guest && ldconfig` |
| 重启后 `virtio_gpu` 是 90112 | 没做 persist | `bash install-debian13-gpu.sh persist` |
| Xorg 仍是 llvmpipe | zink 环境变量没注入 lightdm | `bash install-debian13-gpu.sh xorg` |
| `解析到 dkms 残留` | 旧 dkms 模块优先 | 删 `updates/dkms/` 后 `depmod -a` |

## 验证标准

```sh
uname -r                      # 7.2.12+deb13-arm64
lsmod | grep virtio_gpu       # virtio_gpu 102400（补丁版；原版是 90112）
dmesg | grep -icE 'Oops|BUG:'  # 0
vulkaninfo --summary | grep deviceName
# deviceName = Virtio-GPU GFXStream (Adreno (TM) 810)
glxinfo -B | grep Accelerated  # Accelerated: yes
```

跑分参考（1024x600，波动来自 VM 负载）：

| 场景 | FPS |
|------|-----|
| build | 369–583 |
| texture | 432–679 |
| shading | 333–540 |
