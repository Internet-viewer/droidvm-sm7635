# portmap-5022 — 手机 5022(IPv6) → DroidVM guest 22

## 结论先说：这台手机不能用 iptables 做这个映射

| 检查 | 结果 |
|---|---|
| `ip6tables -t nat -L` | `can't initialize ip6tables table 'nat': Table does not exist` |
| `/proc/config.gz` | `CONFIG_IP6_NF_IPTABLES=y` 但**没有 `CONFIG_IP6_NF_NAT`**；`# CONFIG_NF_TABLES is not set` |
| `/vendor/lib/modules` 里的 `ip6table_nat.ko` | 不存在（而且这是编进内核的选项，模块补不了） |

而且就算有 IPv6 NAT，**Linux NAT 也不能跨协议族**：`ip6tables` 的 DNAT 只能指向 IPv6 地址，
不能把 v6 包送到 v4 的 `192.168.207.10`。Termux 里的
`socat TCP6-LISTEN:5022 ... TCP:192.168.207.10:22` 之所以行，是因为它在**用户态**终结 v6 连接、
再新建一条 v4 连接。

> `portmap-5022.sh` 保留在目录里作为"内核方案"的记录（含 ULA + DNAT + MASQUERADE），
> 在本机跑不起来，只作参考。

## 实际可用方案：root 托管的 socat（`portmap-socat.sh`）

socat 由 **root** 启动并用 supervisor 循环守护，**不依赖 Termux App 存活**（Termux 关掉不影响）：

```bash
su -c 'sh ~/droidvm/portmap/portmap-socat.sh start'
su -c 'sh ~/droidvm/portmap/portmap-socat.sh status'
su -c 'sh ~/droidvm/portmap/portmap-socat.sh stop'
```

实测属主：

```
7857 7855 root socat        # socat 本身是 root
7855        sh              # supervisor
LISTEN *:5022
```

幂等：已在监听就不重复启动；`stop` 只杀自己这套（按 pidfile + `TCP6-LISTEN:<port>` 匹配）。

## ⚠️ 开了 NekoBox 之后：入站能收到，回包会被黑洞

实测（VPN 开启时）：

```
ping6 2408:8206:4855:dcc0:dc6b:7bff:fe6d:47e9   → 0% loss（ICMP 由内核回，能出去）
TCP   同地址:5022                                 → 超时（没有 SYN-ACK）
```

原因（`dumpsys connectivity` 里的 VPN NetworkAgentInfo）：

```
Uids: <{99900000-99999999, 0-99999}>        ← 抓了所有 uid，包括 root(0)
Routes: [ … , ::/0 unreachable mtu 0 ]      ← tun 里的 IPv6 是"不可达"黑洞
```

socat 是 root 进程 → 它的 socket 被 VPN 接管 → 回包往 tun0 的 `::/0 unreachable` 走 → 丢弃。
ICMP 是内核代答，不走这条 uid 规则，所以 ping 通而 TCP 不通。

**要么** 在 NekoBox 里启用 IPv6 / 关掉「阻止 IPv6」，让 `::/0` 走隧道而不是 unreachable；
**要么** 把 NekoBox 改成「仅代理选定应用」，让 root 的 socat 留在物理网络。

## 地址提醒

手机有两个不同的 v6 出口：

| 接口 | 地址 |
|---|---|
| wlan0（Wi-Fi） | `2408:8206:4855:dcc0:dc6b:7bff:fe6d:47e9`（另有 `…:ef7:747c:39f8:9df5`） |
| rmnet_data1（蜂窝 LTE） | `240e:404:4a20:215e:5c26:54ff:fed1:2be9` |

外网要连哪个，取决于对端走哪条路；蜂窝地址每次重连可能变。

## 开机自愈（可选）

把 `portmap-socat.sh start` 放进 KernelSU 的 `/data/adb/service.d/99-portmap.sh` 即可
（root 在开机后执行；放在 service.d 比 Termux:Boot 可靠）。
