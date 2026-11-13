#!/bin/bash
# build-guest-additions.sh — 为 Debian 13 + 7.2.12 编译 DroidVM guest-additions
#
# 背景：
#   guest-additions 是针对 7.x 的 DRM API 写的。7.2.12 把 atomic 回调的第二个
#   参数从 struct drm_atomic_state * 改成了 struct drm_atomic_commit *，因此
#   上游源码直接编译会失败，需要 6 处签名替换（本脚本自动完成）。
#
#   在 6.12 内核上不要尝试这条路径：fbdev 初始化必然 Oops
#   (__drm_fb_helper_initial_config_and_unlock)，需要移植 buddy API。
#
# 用法:
#   bash build-guest-additions.sh            # 克隆 + 打补丁 + 编译 + 安装
#   bash build-guest-additions.sh patch      # 只打补丁
#   bash build-guest-additions.sh build      # 只编译
#   bash build-guest-additions.sh install    # 只安装到 updates/droidvm
#   bash build-guest-additions.sh clean      # 清理编译产物（不删源码）
set -euo pipefail

GA_REPO="https://github.com/Droid-VM/droidvm-guest-additions"
GA_BRANCH="droidvm"
GA_SRC="${GA_SRC:-/root/ga7}"
KVER_EXPECT="7.2.12+deb13-arm64"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }

need_root() { [ "$(id -u)" = 0 ] || { red "必须以 root 运行"; exit 1; }; }

kver()    { uname -r; }
kdir()    { echo "/lib/modules/$(kver)/build"; }
moddir()  { echo "/lib/modules/$(kver)/updates/droidvm"; }

check_kdir() {
  local kd; kd=$(kdir)
  [ -d "$kd" ] || {
    red "找不到内核构建目录: $kd"
    red "先装内核头并重启:  bash install-debian13-gpu.sh kernel"
    exit 1
  }
}

do_fetch() {
  need_root
  if [ -d "$GA_SRC/.git" ]; then
    ylw "源码已存在: $GA_SRC"
    ( cd "$GA_SRC" && git log --oneline -1 )
    return 0
  fi
  step "克隆 guest-additions（分支 $GA_BRANCH）"
  git clone -b "$GA_BRANCH" "$GA_REPO" "$GA_SRC"
  ( cd "$GA_SRC" && git log --oneline -1 )
}

do_patch() {
  need_root
  [ -d "$GA_SRC" ] || { red "缺少源码，先跑: bash $0 fetch"; exit 1; }

  step "应用 7.2 API 适配（drm_atomic_state -> drm_atomic_commit）"

  # 幂等：已经替换过的文件不会再次命中该正则
  python3 - "$GA_SRC" <<'PY'
import re, sys, pathlib

root = pathlib.Path(sys.argv[1])
targets = [
    root / "virtio_gpu" / "virtgpu_display.c",   # 期望 4 处
    root / "virtio_gpu" / "virtgpu_plane.c",     # 期望 2-3 处
]
pattern = re.compile(r"struct drm_atomic_state \*state\)")
total = 0
for p in targets:
    if not p.exists():
        print(f"  ! 缺失 {p}")
        continue
    s = p.read_text()
    s2, n = pattern.subn("struct drm_atomic_commit *state)", s)
    if n:
        p.write_text(s2)
    print(f"  {p.name:22s} 替换 {n} 处")
    total += n

print(f"  合计 {total} 处")
if total == 0:
    print("  （已打过补丁，无需改动）")
PY

  step "确认无残留"
  local left
  left=$(grep -c 'struct drm_atomic_state \*state)' \
           "$GA_SRC/virtio_gpu/virtgpu_display.c" \
           "$GA_SRC/virtio_gpu/virtgpu_plane.c" 2>/dev/null | \
         awk -F: '{s+=$2} END{print s+0}')
  if [ "$left" = 0 ]; then
    grn "  所有 drm_atomic_state 回调已改为 drm_atomic_commit ✓"
  else
    red "  仍有 $left 处未替换"
    exit 1
  fi
}

do_build() {
  need_root
  check_kdir
  [ -d "$GA_SRC" ] || { red "缺少源码"; exit 1; }

  step "make KDIR=$(kdir)"
  # -j2：与 Mesa 同时编译时避免 4 核 guest 换页抖动
  ( cd "$GA_SRC" && make KDIR="$(kdir)" -j"${JOBS:-2}" )

  step "产物"
  local gg="$GA_SRC/gunyah_guest/gunyah_guest.ko"
  local vg="$GA_SRC/virtio_gpu/virtio-gpu.ko"
  for f in "$gg" "$vg"; do
    [ -f "$f" ] || { red "缺少产物: $f"; exit 1; }
    printf "  %-40s %s 字节\n" "$f" "$(stat -c%s "$f")"
  done
  grn "编译完成（参考尺寸: 442472 / 5207952）"
}

do_install() {
  need_root
  local gg="$GA_SRC/gunyah_guest/gunyah_guest.ko"
  local vg="$GA_SRC/virtio_gpu/virtio-gpu.ko"
  [ -f "$gg" ] && [ -f "$vg" ] || { red "未编译，先跑: bash $0 build"; exit 1; }

  step "安装到 $(moddir)"
  install -d "$(moddir)"
  install -m 644 "$gg" "$(moddir)/"
  install -m 644 "$vg" "$(moddir)/"
  depmod -a

  step "校验 depmod 解析路径"
  local picked
  picked=$(modinfo -F filename virtio_gpu)
  echo "  modinfo virtio_gpu -> $picked"
  case "$picked" in
    */updates/droidvm/*) grn "  解析到补丁版 ✓" ;;
    */updates/dkms/*)    red "  仍解析到 dkms 残留，删掉 updates/dkms/ 后 depmod -a"; exit 1 ;;
    *)                   red "  未解析到补丁版"; exit 1 ;;
  esac

  ylw "
下一步（持久化，否则重启会退回原版驱动）:
  bash install-debian13-gpu.sh persist
"
}

do_clean() {
  need_root
  [ -d "$GA_SRC" ] || exit 0
  step "清理编译产物"
  ( cd "$GA_SRC" && make clean KDIR="$(kdir)" 2>/dev/null || true )
  grn "已清理（源码与补丁保留）"
}

ACTION="${1:-all}"
case "$ACTION" in
  fetch)   do_fetch ;;
  patch)   do_patch ;;
  build)   do_build ;;
  install) do_install ;;
  clean)   do_clean ;;
  all)     do_fetch; do_patch; do_build; do_install ;;
  *) red "未知动作: $ACTION"; echo "可用: fetch|patch|build|install|clean|all"; exit 1 ;;
esac
