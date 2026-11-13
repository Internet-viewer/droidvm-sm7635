#!/bin/bash
# install-debian13-gpu.sh — Debian 13 (trixie) guest 内打通 GPU 硬件加速
#
# 目标: DroidVM / crosvm + virtio-gpu gfxstream + Adreno
# 前提: 已在 guest 内以 root 运行，网络可用
#
# 用法:
#   bash install-debian13-gpu.sh              # 全流程
#   bash install-debian13-gpu.sh kernel       # 只装 7.2.12 内核
#   bash install-debian13-gpu.sh wayland      # 只升 wayland
#   bash install-debian13-gpu.sh mesa         # 只编译 Mesa
#   bash install-debian13-gpu.sh ga           # 只编译/装 guest-additions
#   bash install-debian13-gpu.sh persist      # 只做持久化
#   bash install-debian13-gpu.sh xorg         # 只配 zink
#   bash install-debian13-gpu.sh verify       # 只验证
set -euo pipefail

KVER="7.2.12+deb13-arm64"
KDIR="/lib/modules/${KVER}/build"
GA_SRC="/root/ga7"
MESA_SRC="/root/mesa-droidvm"
MESA_BUILD="/root/build-mesa"
ICD="/usr/local/share/vulkan/icd.d/gfxstream_vk_icd.aarch64.json"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }

need_root() {
  [ "$(id -u)" = 0 ] || { red "必须以 root 运行"; exit 1; }
}

# ---------------------------------------------------------------- kernel
do_kernel() {
  need_root
  step "安装 ${KVER} (trixie-backports)"

  grep -q backports /etc/apt/sources.list.d/debian.sources 2>/dev/null \
    || ylw "警告: sources 里没看到 backports，请手动确认"

  apt update
  apt install -y -t trixie-backports \
      "linux-image-${KVER}" "linux-headers-${KVER}"
  update-grub

  echo
  grn "内核已安装。当前运行: $(uname -r)"
  if [ "$(uname -r)" != "$KVER" ]; then
    ylw "需要重启进入新内核:  sudo reboot"
    ylw "重启后再执行:        bash $0 wayland"
    exit 0
  fi
}

# --------------------------------------------------------------- wayland
do_wayland() {
  need_root
  step "升级 wayland 到 >= 1.24 (Mesa 26.3 需要)"
  apt install -y -t trixie-backports \
      libwayland-client0 libwayland-server0 libwayland-egl1 libwayland-cursor0

  local n
  n=$(nm -D /usr/lib/aarch64-linux-gnu/libwayland-client.so.0 2>/dev/null \
      | grep -c wl_fixes_interface || true)
  if [ "${n:-0}" -ge 1 ]; then
    grn "wayland 符号 wl_fixes_interface 已存在"
  else
    red "wayland 仍然缺少 wl_fixes_interface，gfxstream 无法加载"
    exit 1
  fi
  dpkg -l libwayland-client0 | tail -1 | awk '{print "  版本:", $3}'
}

# ------------------------------------------------------------------ mesa
do_mesa() {
  need_root
  step "编译 Mesa 26.3 (本机原生)"

  apt install -y meson ninja-build cmake glslang-tools pkg-config \
      python3-mako python3-yaml build-essential bison flex llvm-dev \
      libdrm-dev libexpat1-dev zlib1g-dev libzstd-dev \
      libx11-dev libx11-xcb-dev libxext-dev libxrandr-dev libxfixes-dev \
      libxxf86vm-dev libxcb1-dev libxcb-dri2-0-dev libxcb-dri3-dev \
      libxcb-present-dev libxcb-sync-dev libxcb-glx0-dev libxcb-shm0-dev \
      libxshmfence-dev libglvnd-dev libudev-dev
  apt install -y -t trixie-backports libwayland-dev wayland-protocols

  if [ ! -d "$MESA_SRC" ]; then
    step "下载 Mesa 源码 (tarball，git clone 在手机上不可靠)"
    curl -fL -o /root/mesa.tar.gz \
      https://github.com/Droid-VM/mesa/archive/refs/heads/droidvm.tar.gz
    tar xzf /root/mesa.tar.gz -C /root
    mv /root/mesa-droidvm-master "$MESA_SRC" 2>/dev/null || true
    [ -d "$MESA_SRC" ] || { red "解压后目录名不符，请检查 $MESA_SRC"; exit 1; }
  fi

  step "meson setup"
  if [ ! -f "$MESA_BUILD/build.ninja" ]; then
    ( cd /root && meson setup build-mesa mesa-droidvm \
        --buildtype release --prefix /usr/local --libdir lib/aarch64-linux-gnu \
        -Dplatforms=x11 \
        -Dgallium-drivers=zink,llvmpipe \
        -Dvulkan-drivers=gfxstream,freedreno,virtio \
        -Dfreedreno-kmds=msm,virtio \
        -Dglvnd=enabled -Dllvm=enabled )
  fi

  step "ninja (约 1.5 小时，-j4)"
  ninja -C "$MESA_BUILD" -j4
  ninja -C "$MESA_BUILD" install
  ldconfig

  step "验证 ICD"
  ls -l /usr/local/share/vulkan/icd.d/*.json
}

# -------------------------------------------------------- guest-additions
do_ga() {
  need_root
  step "编译 DroidVM guest-additions (7.2 API 适配)"

  [ -d "$KDIR" ] || { red "找不到内核头: $KDIR"; red "先跑: bash $0 kernel 并重启"; exit 1; }

  if [ ! -d "$GA_SRC" ]; then
    git clone -b droidvm \
      https://github.com/Droid-VM/droidvm-guest-additions "$GA_SRC"
  fi

  step "应用 7.2 签名补丁 (drm_atomic_state -> drm_atomic_commit)"
  python3 - <<'PY'
import re
total = 0
for P in ("/root/ga7/virtio_gpu/virtgpu_display.c",
          "/root/ga7/virtio_gpu/virtgpu_plane.c"):
    s = open(P).read()
    s2, n = re.subn(r"struct drm_atomic_state \*state\)",
                    "struct drm_atomic_commit *state)", s)
    if n:
        open(P, "w").write(s2)
    print(f"  {P.split('/')[-1]:22s} 替换 {n} 处")
    total += n
print(f"  合计 {total} 处")
# display.c 期望 4 处，plane.c 期望 2 处
PY

  step "make KDIR=$KDIR"
  ( cd "$GA_SRC" && make KDIR="$KDIR" )

  step "安装模块到 updates/droidvm"
  install -d "/lib/modules/${KVER}/updates/droidvm"
  install -m 644 "$GA_SRC/gunyah_guest/gunyah_guest.ko" \
                 "/lib/modules/${KVER}/updates/droidvm/"
  install -m 644 "$GA_SRC/virtio_gpu/virtio-gpu.ko" \
                 "/lib/modules/${KVER}/updates/droidvm/"
  depmod -a

  local picked
  picked=$(modinfo -F filename virtio_gpu)
  echo "  modinfo virtio_gpu -> $picked"
  case "$picked" in
    */updates/droidvm/*) grn "  depmod 解析到补丁版 ✓" ;;
    *) red "  depmod 没解析到补丁版！检查 updates/dkms 残留"; exit 1 ;;
  esac
}

# ------------------------------------------------------------- persistence
do_persist() {
  need_root
  step "持久化：initramfs + modprobe + modules-load"

  # (a) initramfs 打包补丁版，否则开机先加载原版
  grep -qx 'virtio_gpu' /etc/initramfs-tools/modules 2>/dev/null \
    || echo 'virtio_gpu' >> /etc/initramfs-tools/modules

  # (b) 加载顺序
  cat > /etc/modprobe.d/droidvm-ga.conf <<'EOF'
# DroidVM guest additions: load gunyah_guest before the patched virtio-gpu
softdep virtio_gpu pre: gunyah_guest virtio_dma_buf
EOF

  # (c) 开机自动加载
  cat > /etc/modules-load.d/droidvm-ga.conf <<'EOF'
virtio_dma_buf
gunyah_guest
virtio_gpu
EOF

  step "重建 initramfs"
  update-initramfs -u -k "$KVER"

  step "确认 initramfs 里是补丁版"
  if lsinitramfs "/boot/initrd.img-${KVER}" | grep -q 'updates/droidvm/virtio-gpu.ko'; then
    grn "  initramfs 含补丁版 ✓"
  else
    red "  initramfs 里没有补丁版，重启后会加载原版！"
    exit 1
  fi
}

# ------------------------------------------------------------------ xorg
do_xorg() {
  need_root
  step "配置 lightdm 让 Xorg 走 zink"

  [ -f "$ICD" ] || { red "找不到 ICD: $ICD"; red "先跑: bash $0 mesa"; exit 1; }

  install -d /etc/lightdm/lightdm.conf.d
  cat > /etc/lightdm/lightdm.conf.d/60-droidvm-zink.conf <<EOF
[Seat:*]
xserver-command=/usr/bin/env MESA_LOADER_DRIVER_OVERRIDE=zink VK_DRIVER_FILES=${ICD} VK_ICD_FILENAMES=${ICD} X -core
EOF

  systemctl stop lightdm || true
  sleep 3
  pkill -9 Xorg || true
  sleep 2
  systemctl start lightdm || true
  sleep 5

  if grep -qE 'glamor.*enabled on zink' /var/log/Xorg.0.log 2>/dev/null; then
    grn "Xorg 已启用 zink 加速 ✓"
  else
    ylw "Xorg 日志未见 zink，检查 /var/log/Xorg.0.log"
  fi
}

# ---------------------------------------------------------------- verify
do_verify() {
  step "验证"

  echo "--- 内核"
  uname -r

  echo "--- 模块 (virtio_gpu 应为 102400)"
  lsmod | grep -E '^virtio_gpu|^gunyah_guest' || echo "  模块未加载"

  echo "--- 内存错误计数 (应为 0)"
  dmesg 2>/dev/null | grep -icE 'Oops|BUG:|general protection' || echo 0

  echo "--- Vulkan"
  if command -v vulkaninfo >/dev/null; then
    vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|apiVersion' | head -4
  else
    echo "  vulkaninfo 未安装 (apt install vulkan-tools)"
  fi

  echo "--- OpenGL"
  local u
  for u in dvmuser debian; do
    if id "$u" >/dev/null 2>&1; then
      su - "$u" -c 'DISPLAY=:0 glxinfo -B 2>/dev/null | grep -E "OpenGL renderer|Accelerated"' \
        || echo "  ($u) glxinfo 失败"
      break
    fi
  done

  echo "--- glmark2"
  if command -v glmark2 >/dev/null; then
    for u in dvmuser debian; do
      if id "$u" >/dev/null 2>&1; then
        su - "$u" -c 'DISPLAY=:0 glmark2 --benchmark build 2>&1 | grep -E "FPS|Score"'
        break
      fi
    done
  else
    echo "  glmark2 未安装 (apt install glmark2)"
  fi
}

# ------------------------------------------------------------------ main
ACTION="${1:-all}"
case "$ACTION" in
  kernel)    do_kernel ;;
  wayland)   do_wayland ;;
  mesa)      do_mesa ;;
  ga)        do_ga ;;
  persist)   do_persist ;;
  xorg)      do_xorg ;;
  verify)    do_verify ;;
  all)
    do_kernel
    [ "$(uname -r)" = "$KVER" ] || { ylw "请重启后继续"; exit 0; }
    do_wayland
    do_mesa
    do_ga
    do_persist
    do_xorg
    do_verify
    grn "\n全部完成。重启后验证:  bash $0 verify"
    ;;
  *)
    red "未知动作: $ACTION"
    echo "可用: kernel|wayland|mesa|ga|persist|xorg|verify|all"
    exit 1
    ;;
esac
