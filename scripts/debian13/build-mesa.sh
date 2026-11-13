#!/bin/bash
# build-mesa.sh — 在 Debian 13 guest 内原生编译 DroidVM 的 Mesa 26.3
#
# 为什么要本机编译：
#   DroidVM 提供的预编译 mesa-guest 包要求 GLIBC_2.43，而 Debian 13 是 2.41；
#   且它装到 /usr/local/lib/aarch64-linux-gnu/，该路径在 ld.so.conf 中排在
#   系统库前面，会直接打崩整个 GL 栈（eglInitialize failed /
#   couldn't find RGB GLX visual）。本机编译 ABI 天然匹配。
#
# 前置条件：
#   - 已装 backports 7.2.12 内核并重启（见 install-debian13-gpu.sh kernel）
#   - wayland >= 1.24（见 install-debian13-gpu.sh wayland）
#
# 用法:
#   bash build-mesa.sh              # 完整构建 + 安装
#   bash build-mesa.sh deps         # 只装依赖
#   bash build-mesa.sh fetch        # 只下载源码
#   bash build-mesa.sh configure    # 只跑 meson setup
#   bash build-mesa.sh build        # 只跑 ninja（可放 tmux）
#   bash build-mesa.sh install      # 只安装
#   bash build-mesa.sh status       # 查构建进度
set -euo pipefail

MESA_REPO="https://github.com/Droid-VM/mesa"
MESA_BRANCH="droidvm"
SRC="/root/mesa-droidvm"
BUILD="/root/build-mesa"
TARBALL="/root/mesa.tar.gz"
LOG="/root/mesa-build.log"
JOBS="${JOBS:-4}"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }

need_root() { [ "$(id -u)" = 0 ] || { red "必须以 root 运行"; exit 1; }; }

# 这些选项必须与已验证配置一致，否则 zink/gfxstream 链路会断
MESON_OPTS=(
  --buildtype release
  --prefix /usr/local
  --libdir lib/aarch64-linux-gnu
  -Dplatforms=x11
  -Dgallium-drivers=zink,llvmpipe
  -Dvulkan-drivers=gfxstream,freedreno,virtio
  -Dfreedreno-kmds=msm,virtio
  -Dglvnd=enabled
  -Dllvm=enabled
)

do_deps() {
  need_root
  step "安装构建依赖"

  apt install -y meson ninja-build cmake glslang-tools pkg-config \
      python3-mako python3-yaml build-essential bison flex llvm-dev \
      libdrm-dev libexpat1-dev zlib1g-dev libzstd-dev \
      libx11-dev libx11-xcb-dev libxext-dev libxrandr-dev libxfixes-dev \
      libxxf86vm-dev libxcb1-dev libxcb-dri2-0-dev libxcb-dri3-dev \
      libxcb-present-dev libxcb-sync-dev libxcb-glx0-dev libxcb-shm0-dev \
      libxshmfence-dev libglvnd-dev libudev-dev

  # wayland dev 必须也是 backports 版，否则与运行库版本冲突
  apt install -y -t trixie-backports libwayland-dev wayland-protocols

  grn "依赖就绪: $(ninja --version 2>/dev/null) / $(meson --version 2>/dev/null)"
}

do_fetch() {
  need_root
  if [ -d "$SRC" ]; then
    ylw "源码已存在: $SRC（如需强制拉新请先删除）"
    return 0
  fi
  step "下载 Mesa 源码"
  # 用 tarball 而非 git clone：手机网络下 clone 经常在打包阶段失败
  # (tmp_pack 丢失)，tarball 111MB 约 30 秒完成。
  curl -fL --retry 3 -o "$TARBALL" \
    "${MESA_REPO}/archive/refs/heads/${MESA_BRANCH}.tar.gz"
  step "解压"
  tar xzf "$TARBALL" -C /root
  # 上游 tarball 解出来是 mesa-droidvm/（分支名即目录名）
  [ -d "$SRC" ] || { red "解压后找不到 $SRC"; ls -d /root/mesa-*; exit 1; }
  grn "源码: $(du -sh "$SRC" | cut -f1)"
  [ -f "$SRC/VERSION" ] && grn "版本: $(cat "$SRC/VERSION")"
}

do_configure() {
  need_root
  [ -d "$SRC" ] || { red "缺少源码，先跑: bash $0 fetch"; exit 1; }

  # 本构建要求本机内核与驱动侧一致；7.x 才能用上 blob_alignment
  local kver; kver=$(uname -r)
  case "$kver" in
    7.*) grn "内核 $kver ✓" ;;
    *)   ylw "当前内核 $kver 不是 7.x；编译可以，但运行需要 7.2.12" ;;
  esac

  step "meson setup $BUILD"
  rm -rf "$BUILD"
  ( cd /root && meson setup "$(basename "$BUILD")" "$(basename "$SRC")" "${MESON_OPTS[@]}" )

  grn "配置完成，有效选项:"
  meson introspect "$BUILD" --buildoptions 2>/dev/null | python3 -c '
import json,sys
keys={"buildtype","prefix","libdir","platforms","gallium-drivers",
      "vulkan-drivers","freedreno-kmds","glvnd","llvm"}
for o in json.load(sys.stdin):
    if o["name"] in keys:
        print(f"  {o[\"name\"]}={o[\"value\"]}")
' 2>/dev/null || true
}

do_build() {
  need_root
  [ -f "$BUILD/build.ninja" ] || { red "未配置，先跑: bash $0 configure"; exit 1; }

  step "ninja -j${JOBS}（约 95 分钟）"
  # 长任务建议脱离 SSH 会话：tmux new -d -s mesa 'bash build-mesa.sh build'
  ninja -C "$BUILD" -j"$JOBS" 2>&1 | tee "$LOG"
  grn "构建完成。日志: $LOG"
}

do_install() {
  need_root
  [ -f "$BUILD/build.ninja" ] || { red "未配置"; exit 1; }

  step "ninja install"
  ninja -C "$BUILD" install
  ldconfig

  step "校验产物"
  local ok=1
  for f in /usr/local/share/vulkan/icd.d/gfxstream_vk_icd.aarch64.json \
           /usr/local/lib/aarch64-linux-gnu/libvulkan_gfxstream.so; do
    if [ -e "$f" ]; then echo "  ✓ $f"; else echo "  ✗ $f"; ok=0; fi
  done
  ls -1 /usr/local/share/vulkan/icd.d/ 2>/dev/null | sed 's/^/  ICD: /'
  ls -1 /usr/local/lib/aarch64-linux-gnu/libgallium*.so 2>/dev/null | sed 's/^/  /'

  [ "$ok" = 1 ] && grn "安装完成" || { red "产物缺失"; exit 1; }
}

do_status() {
  if [ -f "$LOG" ]; then
    echo "--- 最新进度 ---"
    tail -1 "$LOG"
    echo "--- 是否结束 ---"
    grep 'EXIT=' "$LOG" 2>/dev/null || echo "仍在编译中"
  else
    echo "无构建日志: $LOG"
  fi
  echo "--- 产物 ---"
  ls -1 /usr/local/share/vulkan/icd.d/ 2>/dev/null || echo "尚未安装"
}

ACTION="${1:-all}"
case "$ACTION" in
  deps)      do_deps ;;
  fetch)     do_fetch ;;
  configure) do_configure ;;
  build)     do_build ;;
  install)   do_install ;;
  status)    do_status ;;
  all)
    do_deps; do_fetch; do_configure; do_build; do_install
    grn "\n完成。验证: bash install-debian13-gpu.sh verify"
    ;;
  *) red "未知动作: $ACTION"; echo "可用: deps|fetch|configure|build|install|status|all"; exit 1 ;;
esac
