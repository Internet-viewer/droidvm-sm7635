#!/usr/bin/env bash
# Inject a root password + SSH key into an Alpine cloud qcow2 image.
#
# WHY: Alpine *cloud* images ship with root locked (root:!*), and DroidVM provides
# no cloud-init seed, so there is no password to type at the serial console.
#
# RUN THIS ON A LINUX HOST (not on the phone): DroidVM's bundled qemu-img cannot
# decompress this image's compressed clusters and silently produces an all-zero raw.
#
#   sudo ./inject-alpine-password.sh alpine.qcow2 [PASSWORD] [PUBKEY_FILE]
#
# Then copy the resulting *.injected.qcow2 to the phone and use it as the VM disk.
set -euo pipefail

IMG=${1:?usage: $0 <image.qcow2> [password] [pubkey_file]}
PASS=${2:-alpine}
KEYFILE=${3:-$HOME/.ssh/id_ed25519.pub}
OUT=${IMG%.qcow2}.injected.qcow2
RAW=$(mktemp -u /tmp/alpine-XXXX.raw)
MNT=$(mktemp -d /tmp/alpine-mnt-XXXX)

[ "$(id -u)" = 0 ] || { echo "run as root (loop mount)"; exit 1; }
command -v qemu-img >/dev/null || { echo "qemu-img missing (apt install qemu-utils)"; exit 1; }

echo "[1/6] qcow2 -> raw"
qemu-img convert -f qcow2 -O raw "$IMG" "$RAW"

echo "[2/6] parse GPT for the root partition offset"
OFF=$(python3 - "$RAW" <<'PY'
import sys, struct
f=open(sys.argv[1],'rb'); f.seek(512); h=f.read(92)
if h[:8]!=b'EFI PART': raise SystemExit("not GPT")
lba,n,esz=struct.unpack_from('<QII',h,0x48); f.seek(lba*512)
best=None
for i in range(n):
    e=f.read(esz)
    if e[:16]==b'\0'*16: continue
    first,last=struct.unpack_from('<QQ',e,32)
    name=e[56:128].decode('utf-16le','ignore').rstrip('\0')
    if name in ('/','root'): best=first
if best is None: raise SystemExit("root partition not found")
print(best*512)
PY
)
echo "      offset=$OFF"

echo "[3/6] loop mount"
LOOP=$(losetup -f --show -o "$OFF" "$RAW")
trap 'umount "$MNT" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; rm -f "$RAW"' EXIT
mount "$LOOP" "$MNT"

echo "[4/6] set root password (SHA-512 crypt)"
HASH=$(openssl passwd -6 "$PASS")
sed -i "s|^root:[^:]*:|root:${HASH}:|" "$MNT/etc/shadow"
grep -q '^root:' "$MNT/etc/shadow" && echo "      ok"

echo "[5/6] authorized_keys + sshd (optional)"
if [ -f "$KEYFILE" ]; then
  mkdir -p "$MNT/root/.ssh"; chmod 700 "$MNT/root/.ssh"
  cat "$KEYFILE" >> "$MNT/root/.ssh/authorized_keys"
  chmod 600 "$MNT/root/.ssh/authorized_keys"
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$MNT/etc/ssh/sshd_config" 2>/dev/null || true
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$MNT/etc/ssh/sshd_config" 2>/dev/null || true
fi

echo "[6/6] repack"
sync; umount "$MNT"; losetup -d "$LOOP"; rm -f "$RAW"; trap - EXIT
qemu-img convert -f raw -O qcow2 "$RAW" "$OUT" 2>/dev/null || true
echo "done -> $OUT"
ls -l "$OUT"; sha256sum "$OUT"
