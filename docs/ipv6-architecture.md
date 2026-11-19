# IPv6 单 /64 共享体系：架构与工作流程

本文描述 `files/usr/bin/ipv6-maint.sh` 实现的 IPv6 体系。该脚本固化的场景是：
**单 WAN（PPPoE 无 PD，仅有一个 /64）+ 单 LAN，LAN 侧自行做 SLAAC，公网入站靠镜像 IPv4 端口转发规则下发 IPv6 DNAT**。
它不是通用 NDP proxy，也不处理多 WAN / 有 PD 的场景。

相关文件：

| 路径 | 作用 |
|---|---|
| `files/usr/bin/ipv6-maint.sh` | 主脚本（本文主角），cron 每 5 分钟 + hotplug 触发 |
| `files/etc/hotplug.d/iface/99-ipv6-maint` | WAN/LAN ifup 后立刻触发一次，覆盖重拨换前缀 |
| `files/etc/crontabs/root` | 定时调度入口 |
| `files/etc/config/dhcp` | dnsmasq / odhcpd 通用配置（静态绑定由实机本地维护，不入库） |
| `files/etc/uci-defaults/*.sh` | 首次开机设置（zram / argon / fullcone / cronloglevel） |

---

## 1. 设计目标与约束

1. **电信线路只下发一个 /64，无 PD**：WAN 口自己拿一个 GUA，LAN 设备无法从上游获得独立前缀。
   解决方式：把 WAN 的 /64 直接"落地"到 br-lan（配 `::1/64` + 回程路由），让 LAN 设备在这个 /64 内自行 SLAAC。
2. **公网入站要能进 LAN**：SLAAC 地址是动态的、会轮换，无法靠固定 IP 做 DNAT。
   解决方式：复用 LuCI 里已有的 IPv4 端口转发规则（`config redirect`），用 `dest_ip`（内网 IPv4）反查该设备的 IPv6 GUA，生成等价的 IPv6 DNAT。
3. **不写 UCI / 不改持久化配置**：所有运行时状态放 `/var/run/ipv6-maint`（重启即清，前缀重拨会变，符合预期）。
4. **失败不破坏现状**：nft 事务失败时保留原有规则与状态，等下一轮自愈。

---

## 2. 四大职责

```
                       ┌──────────────────────────┐
                       │  ipv6-maint.sh 主入口     │
                       │  flock 互斥 + WORK 临时目录│
                       └────────────┬─────────────┘
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
   ① 前缀发现 / 落地        ② IPv4→IPv6 地址解析        ③ 防火墙下发
   do_relay()               resolve_gua()              do_portfwd()
   - WAN /64 提取            - MAC 快照（租约+ARP）      - fw4 旧规则清理
   - br-lan ::1/64           - IPv6 邻居表 + DHCPv6      - DNAT 表原子重建
   - 回程路由 metric 64      - EUI-64 / 记忆 / 租约      - fw4 accept 插入
   - 清反向 /128 毒路由      - 状态记忆写 map            - 状态差异记日志
```

### 2.1 前缀发现与落地（`do_relay`）

- `ipv6_records wan` 从 `pppoe-wan` 的 global 地址中挑 `/64` 且首字节为 `2`/`3`（全球单播）的前缀，展开成 8 组补零小写形式的前 4 组（如 `240e:0368:0818:1d5d`）。
- 在 `br-lan` 上确保存在 `PFX::1/64`（作为 odhcpd RA/DHCPv6 的地址池与 LAN 默认网关）。
- 添加 `PFX::/64 dev br-lan metric 64` 回程路由，metric 必须压过 PPPoE 内核的 onlink 路由（256），否则公网入站流量会走错接口。
- 清理 odhcpd 可能误加的"前缀内 /128 指向 pppoe-wan"的毒路由（它会黑洞公网入站）。
- 旧前缀配置只在**新配置成功后**才撤销（记录 prev prefix + device + metric），支持精确回滚。

### 2.2 IPv4 → IPv6 地址解析（`resolve_gua`）

这是把 IPv4 端口转发"镜像"到 IPv6 的关键。三级数据源、四级回退：

**主机快照 `snapshot_hosts()`**（一次采集，避免逐条规则重复查询）：

| 数据 | 来源 | 提取方式 |
|---|---|---|
| IPv4 → MAC | dnsmasq 租约 `/tmp/dhcp.leases` + ARP 邻居 | awk 提取，校验 MAC 格式（6 组 2 位 hex），统一小写 |
| MAC → GUA（邻居） | `ip -6 neigh` | 排除 FAILED/INCOMPLETE，只保留当前前缀 |
| MAC → GUA（租约） | `ubus dhcp ipv6leases` | **jshn 按对象关联 DUID 与地址**，按 DUID-LLT/LL 结构解析出 MAC，不看字段顺序 |
| 历史锁定 | `/var/run/ipv6-maint/map` | 上次解析结果（防止隐私临时地址轮换导致规则漂移） |

**回退优先级**（`resolve_gua`）：

1. 结果缓存（`results`，同一轮内同 IP 只解析一次）
2. EUI-64 稳定地址（`mac` 首字节 U/L 位翻转 + `ff:fe` 插入，精确匹配邻居表）
3. 状态记忆命中的旧 GUA（仍在邻居表中才复用）
4. DHCPv6 租约地址
5. 邻居表首个候选，并写入 map 供下轮复用

> 为什么需要 map：macOS / iOS 等设备用隐私临时地址，邻居表里同一个 MAC 会有多个 GUA，不锁定就会每 5 分钟换一次 DNAT 目标。

**地址规范化**：`ipv6_records` 的 awk `expand()` 把所有地址统一展开成 8 组 4 位小写 hex，比较前缀时用 `substr(a,1,19)`。
这一步很关键——`240e:368:...::70c` 和 `240e:0368:...:0000:070c` 是同一个地址，不做规范化就会误判为不同。

### 2.3 防火墙下发（`do_portfwd`）

遍历 `config redirect`（LuCI 端口转发），逐条镜像：

- 只处理：`src` = WAN zone、`target` = DNAT、enabled 的规则。
- **安全护栏**：带任何访问限制项（`src_ip`/`src_mac`/`ipset`/`mark`/时间限制等）的 IPv4 规则直接跳过，绝不把受限规则悄悄放大成不受限 IPv6 放行。
- 端口：源端口允许列表/范围（nft `{ }` 集合），目标端口只允许单端口或单范围（`ports()` 校验 1–65535）。
- 目标为路由本机（`dest_ip` 为空或匹配 LAN IP 列表）：只加 `input_wan` 放行 + `fib daddr type local`。
- 目标为 LAN 设备：解析出 GUA 后，生成 `dnat ip6 to [GUA]:port`，并插入 `forward_wan` 的 `ct status dnat accept`（DNAT 后的转发放行，优先于 zone reject）。

**nft 原子事务**：所有 fw4 旧规则删除、`ipv6fwd` 表 flush + 重建、fw4 accept 插入，写在同一个 batch 里用 `nft -f` 一次提交——无规则空窗。失败则整批回滚，保留原状。

> ⚠️ 实机坑（已修复）：本设备 nft 不接受**带引号的 chain 名**，如 `delete rule inet fw4 "forward_wan" handle 2332` 会报 `syntax error, unexpected quoted string`。
> chain 名一律不带引号（`delete rule inet fw4 forward_wan handle 2332`）。脚本用 `identifier()` 白名单校验 zone 名（仅 `a-zA-Z0-9_.-`），去掉引号是安全的。

### 2.4 状态与日志

- 状态文件在 `/var/run/ipv6-maint/`：`map`（MAC→GUA 锁定）、`relay`（前缀/设备/metric）、`state`（规则快照）、`lock`（flock 锁文件）。重启即清。
- 日志只在规则状态**真变化时**输出一次完整快照（`cmp -s` 比较），避免每 5 分钟刷屏。cron 的执行记录由 `cronloglevel=8` 抑制（见 uci-defaults）。

---

## 3. 触发与并发

| 触发源 | 时机 | 说明 |
|---|---|---|
| cron | 每 5 分钟 | `*/5 * * * * /usr/bin/ipv6-maint.sh >/dev/null 2>&1` |
| hotplug iface | WAN/LAN ifup | 重拨换前缀后立即执行，不等 cron |
| 手动 `--resolve <IPv4>` | 调试 | 只解析并打印 GUA，不改防火墙 |

并发控制：`flock -n 9` 对 `STATE_DIR/lock` 加内核锁，非阻塞；两个实例同时来，后者直接退出。内核锁在进程退出 / SIGKILL 后自动释放，**没有锁残留问题**（早期版本用 mkdir + 时间戳文件，需要自愈逻辑，已弃用）。

---

## 4. 依赖与入口参数

- 依赖：`/lib/functions.sh`、`/lib/functions/network.sh`、`/usr/share/libubox/jshn.sh`、`flock`、`ip`、`nft`、`ubus`、BusyBox awk/sed。
- 环境变量覆盖（便于适配）：`WAN_NETWORK`（默认自动由 `network_find_wan6` 发现）、`LAN_NETWORK`（默认 `lan`）、`WAN_IF`/`LAN_IF`（默认取 netifd `l3_device`）、`STATE_DIR`、`ROUTE_METRIC`。
- 本机 LAN IPv4 列表由 `network_get_ipaddrs` 从 UCI 动态获取，不硬编码。

---

## 5. 实机验证记录（AX3000T，2026-11-18）

在小米 AX3000T（ImmortalWrt / mediatek-filogic）上验证：

| 项目 | 结果 |
|---|---|
| `sh -n` 语法 | ✅ |
| 全量执行 | `run_exit=0` |
| 前缀落地 | `br-lan` 有 `240e:368:818:1d5d::1/64`，relay 文件记录 `240e:0368:0818:1d5d br-lan 64` |
| 端口转发状态 | `V6: 192.168.99.250 tcp/9999 -> ...:070c:9999` |
| ipv6fwd DNAT | `iifname pppoe-wan` + `fib daddr type local` + `tcp dport 9999 dnat to [::70c]:9999`，两个链（prerouting / output）均在 |
| fw4 放行 | `ip6 daddr ...:070c tcp dport 9999 ct status dnat accept comment "ipv6-maint"` |
| `--resolve` ARP 路径（.250 静态 IP） | ✅ 返回 GUA |
| `--resolve` DHCPv6 路径（.100） | ✅ 返回 GUA |
| 不可达 IPv4 | 返回 1，跳过，不改规则 |
| 连续两次执行 state md5 | 一致（幂等） |
| zone 自动发现 | `network_find_wan6` → `wan_6` → `pppoe-wan` |

**结论**：脚本逻辑正确、幂等、失败安全。修复 nft chain 引号问题后全链路贯通。
