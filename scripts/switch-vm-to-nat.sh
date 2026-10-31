#!/system/bin/sh
# Point the DroidVM VM at a Linux-bridge network with L3 routing (DHCP + SNAT) and
# give it DNS. Run as root on the phone, with the VM STOPPED.
#
# WHY: a "Wi-Fi pseudo-bridge" network bridges L2 to the phone's Wi-Fi STA, so the
# guest must get its address from the router's DHCP. On this device that never
# happened (the guest only got an IPv6 link-local), so `apk update` failed with
# "temporary error". An L3 bridge with DroidVM's own DHCP+SNAT fixes it.
#
# usage: su -c 'sh switch-vm-to-nat.sh <network_id> <vm_id>'
set -u
NETID=${1:?network_id}
VMID=${2:?vm_id}
D=/data/data/cn.classfun.droidvm
PY=/data/data/com.termux/files/usr/bin/python3
J=$D/files/vms.json
N=$D/files/networks.json
CLI=/data/local/tmp/dv/assets/bin/arm64-v8a/droidvm

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
cd "$D" || exit 1

echo "== stop VM =="; $CLI stop "$VMID" >/dev/null 2>&1; sleep 4
cp -a "$J" "$J.bak-net-$(date +%H%M%S)"
cp -a "$N" "$N.bak-dns-$(date +%H%M%S)"

echo "== set DNS on the L3 network =="
$PY - "$N" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for n in d['networks']:
    l3=n.get('l3')
    if not l3: continue
    l3['dns_servers']=["1.1.1.1","8.8.8.8"]
    for v in l3.get('vlans',[]):
        if v.get('ipv4'): v['ipv4']['dns_servers']=["1.1.1.1","8.8.8.8"]
        if v.get('ipv6'): v['ipv6']['dns_servers']=["2606:4700:4700::1111"]
    print("  patched", n['name'])
json.dump(d, open(p,'w'), indent=4)
PY

echo "== attach VM to the network =="
$PY - "$J" "$NETID" <<'PY'
import json,sys
jp,netid=sys.argv[1],sys.argv[2]
d=json.load(open(jp)); vm=d['vms'][0]
old=vm.get('networks') or []
mac=old[0]['mac_address'] if old else "02:93:c9:f7:c2:f4"
vm['networks']=[{"network_id":netid,"mac_address":mac}]
json.dump(d, open(jp,'w'), indent=4)
print("  vm networks:", vm['networks'])
PY

chown 10512:10512 "$J" "$N" 2>/dev/null; chmod 600 "$J" "$N"
echo "== restart the app so the daemon reloads the network config, then start the VM from the UI =="
am force-stop cn.classfun.droidvm; sleep 2
am start -n cn.classfun.droidvm/.ui.main.MainActivity >/dev/null 2>&1
