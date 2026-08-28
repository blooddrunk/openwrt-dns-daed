# 常见故障快速定位

> 配合 `openwrt-dns-daed.sh check` 使用；本文按症状组织，命令均可在路由器 SSH 中直接执行。

## 情况 A：WAN DNS 里出现公司 DNS，担心被使用

先看：

```sh
uci show dhcp.@dnsmasq[0] | grep noresolv
grep -Rns '^no-resolv' /tmp/etc/dnsmasq.conf.* 2>/dev/null
```

只要运行态有 `no-resolv`，就不要继续盯着 `/tmp/resolv.conf.d/resolv.conf.auto` 排障——它只是 WAN 下发记录，不是实际上游。

## 情况 B：dnsmasq 里又出现 5054 / 5055

```sh
uci show dhcp.@dnsmasq[0] | grep -E 'server|doh_'
netstat -lnptu 2>/dev/null | grep -E '(:5053|:5054|:5055)[[:space:]]'
```

如果只有 5053 在监听，则 5054/5055 是失效条目。最快的处理方式是重跑一次幂等安装：

```sh
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh install
```

或手工清理（`del_list` 提示条目不存在可忽略）：

```sh
for opt in server doh_server doh_backup_server; do
  uci del_list dhcp.@dnsmasq[0].${opt}='127.0.0.1#5054'
  uci del_list dhcp.@dnsmasq[0].${opt}='127.0.0.1#5055'
done
uci commit dhcp && /etc/init.d/dnsmasq restart
```

## 情况 C：DNS 规则看起来重复

```sh
nft list ruleset 2>/dev/null | grep -i -C 4 \
  -E 'https-dns-proxy|DNSMASQ HIJACK|dport (53|853)'
```

目标状态：

- `dstnat_lan` 中 TCP/UDP 53 → `redirect to :53`
- `forward_lan` 中 TCP/UDP 853 → REJECT
- **不再出现** `DNSMASQ HIJACK`（它由 `dns_redirect='0'` 控制）

## 情况 D：开 daed 后 DNS 失效 / 出现回环

第一优先检查 Routing 开头是否有：

```text
pname(
    dnsmasq,
    https-dns-proxy
) -> must_direct
```

必须是 `must_direct`，不能是普通 `direct`。

## 情况 E：国外域名仍出现可疑解析

检查 daed DNS 是否误退回传统 53 端口：

```text
错误示例:  udp://223.5.5.5:53        tcp+udp://8.8.8.8:53
正确:      https://dns.alidns.com/dns-query   https://dns.google/dns-query
```

`openwrt-dns-daed.sh check` 会对 `wing.db` 做只读信号检查并提示。

## 情况 F：宽带有 IPv6，但 VPS 节点 IPv6 不稳定

如果节点本身没有 IPv6、IPv6 线路没有优化，或节点的 IPv6 质量不稳定，按以下方式设置 daed：

1. 在 **配置 → DNS** 中粘贴脚本生成的 `daed-dns.dae`，确认包含：

   ```text
   ipversion_prefer: 4
   ```

   对同时有 A/AAAA 记录的域名，daed 将仅响应 A，对 AAAA 返回空答案。
2. 在 **配置 → 全局 / 节点检测** 中按 `daed-global-settings.txt` 填写：TCP 使用 `http://cp.cloudflare.com` 和 IPv4 `1.1.1.1`，UDP 使用 `223.5.5.5:53`，不要填写 TCP/UDP IPv6 检测地址。
3. “引导解析器”留空、“备用解析器”保持 IPv4 的 `8.8.8.8:53` 即可；这两个字段不是 LAN 客户端的日常 DNS，也不是 DNS 片段中的 DoH 上游。

该设置只影响 daed 的 DNS。若 LAN 客户端仍拿到 AAAA，这是 `dnsmasq → https-dns-proxy` 链路的独立问题（实测部分 daed 版本连自身处理的 AAAA 查询也不会过滤，向 `192.168.10.1` 查 google 的 AAAA 仍会返回真实记录）。

**根治手段（推荐）**：当 WAN 上的 IPv6「有名无实」时（有全球地址但 `ping -6 2400:3200::1` 不通，或上级 NAT 不下发 PD），在 `/etc/openwrt-dns-daed.conf` 设置：

```sh
DISABLE_IPV6="1"
```

重跑 `install` 即可整机禁用 IPv6（WAN 获取 / ULA / LAN RA 全关，详见 README「整机禁用 IPv6」）。此时客户端没有 IPv6 地址，AAAA 记录即使返回也无害。

install 同时会清理 LAN/WAN 设备上残留的 ULA/动态 IPv6 地址（v1.2.0 起）——实测仅 reload network 并不总是移除已分配的地址，br-lan 上会长期残留 deprecated ULA，客户端会把它继续当 DNS 服务器使用。已部署旧版本、暂不便重跑 install 的，可手动清理或重启路由器达到同等效果：

```sh
ip -6 addr show dev br-lan | grep "scope global"   # 找到残留地址
ip -6 addr del fde7:xxxx::1/60 dev br-lan          # 逐个删除
```

### 情况 F 附：间歇性「外网全挂、重启 daed 有时恢复」的完整链条

若日志同时出现下面三类信息，基本可以确定是同一个根因——WAN 上的假 IPv6：

```text
WARN DNS ingress fast path failed; sending SERVFAIL ... error=Get "https://[2606:4700:...]:443/dns-query...": TLS handshake timeout   # daed 用不通的 v6 拨 DoH 上游
WARN handleConn: failed to dial ... [REALITY]: dial to xxx.example.top:443: bootstrap resolver returned no usable address                # DNS 瘫痪连累节点域名解析
WARN Marking dialer as unavailable due to persistent proxy IP failures ...                                                            # 节点被标记不可用，代理整体下线
```

链条：v6 拨 DoH 上游超时 → 国外域名 SERVFAIL（国内 alidns 正常，所以只有外网挂）→ 节点域名解析不出 → dialer 标记不可用 → v4/v6 代理流量全部超时。重启 daed 只是复位 DNS 连接与 dialer 状态，不是必然恢复；`DISABLE_IPV6="1"` 才是根治。

**关于 fallback DoH 上游的补充（排障必读）**：daed 自身对 DoH 上游（如 cloudflare-dns.com）的查询也会被 dae 按 Routing 分流，通常命中 `fallback: proxy` 从节点出口发出（这也是国外域名答案不被污染的原因）。判别证据：

```text
WARN DNS forward to upstream failed dialer=xx-hysteria2 ... network=tcp+4
     outbound=proxy target=104.16.248.249:443 upstream=https://cloudflare-dns.com:443/dns-query
```

两个推论：

1. 此时的报错 `http3: parsing frame failed: timeout: no recent network activity` 来自 **Hysteria2 隧道的 QUIC 层**，不是 DoH3（dae 中 `https://` 本来就是 TCP/h2，`h3://` 才是 DoH3），GUI 里没有「DoH3 改 DoH」的开关可动；
2. fallback DNS 的可用性 = 所选节点的可用性。Hysteria2（UDP）受 QoS 抖动时 DoH 跟着抖。若日志中 `DNS forward to upstream failed` 集中在某 `-hysteria2` dialer 上，可在 Routing 的 `fallback: proxy` 之前把 Cloudflare DoH 的 IP 固定到 Reality（TCP）节点组：

   ```text
   dip(104.16.248.249/32, 104.16.249.249/32) -> premium
   ```

   （`premium` 需为只含 Reality/TCP 节点的组；`cloudflare-dns.com` 的 A 记录长期为这两个地址，可用 `nslookup cloudflare-dns.com 223.5.5.5` 复核。也可再加一条 `domain(suffix: cloudflare-dns.com) -> premium` 覆盖 A 记录变化——注意这条流量只能靠 SNI 嗅探命中 domain 规则，`dip` 是确定性兜底，详见 README「fallback DoH 上游固定走 Reality 节点」。）

## 情况 G：开启 daed 后，v2rayN 真连接延迟 `-1 ms`

关闭 daed 后节点测试立即恢复 → 代理节点 endpoint 被 `fallback: proxy` 再次捕获。按「目标 IP + 协议 + 端口」精确 `must_direct`：

```text
dip(203.0.113.10/32) && l4proto(tcp) && dport(47664) -> must_direct
dip(203.0.113.10/32) && l4proto(udp) && dport(55529) -> must_direct
```

**不要**为了修测速写成 `dip(203.0.113.10/32) -> must_direct`（整台 VPS 直连），否则同机部署的 1Panel / Web / HTTPS 等普通服务也会被强制直连。

验证顺序：

1. 保持 daed 开启
2. 应用 endpoint 精确规则（确认已在 GUI 粘贴最新 Routing）
3. v2rayN 重新测试 Reality / Hysteria2 真连接延迟
4. 访问该 VPS 上的 Web 服务，确认其仍可经 `fallback: proxy` 获得较好访问速度

## 情况 H：install/check 报 https-dns-proxy 选项 FAIL

https-dns-proxy 的 UCI 选项在不同版本间偶有增减。如果 `check` 报某选项不符：

1. `opkg list-installed | grep https-dns-proxy` 确认版本
2. `uci show https-dns-proxy` 核对该版本实际支持的选项
3. 重跑 `install` 让脚本按目标值重新写入

## 情况 I：需要彻底还原本脚本的所有改动

```sh
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh rollback          # 还原 UCI（最近一次备份）
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh rollback --with-daed   # 连 daed 数据库一起还原
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh clean --purge     # 删除脚本全部产物
```

`rollback --with-daed` 会用备份时的 `wing.db` 覆盖当前数据库（备份之后的 daed 改动全部丢失），仅在你确定需要时使用。

## 情况 J：daed 启动报错 / 无法启动

daed 自身日志里常见两类「看不出原因」的报错，含义与处理如下：

| 日志关键词 | 含义 | 处理 |
| --- | --- | --- |
| `blocked preconditions: tun-missing`（或提到 `/dev/net/tun`） | 内核没有提供 TUN 设备，daed 启动前提不满足 | `opkg update && opkg install kmod-tun` 后**重启路由器**；LXC/Docker 里跑 OpenWrt 的，需在宿主机开启 `/dev/net/tun` |
| `Operation not permitted` / 提到特权不足 | daed 没有以 root/CAP_NET_ADMIN 特权运行 | 用 `/etc/init.d/daed restart` 以服务方式启动（procd 会授予特权），不要手动降权运行二进制 |
| `address already in use` | 端口被占用（常见 53/853 与 dnsmasq 冲突） | `netstat -lnptu | grep -E '(:53|:5053|:853)'` 找到占用者后停用 |

验证 TUN 是否就绪：

```sh
ls -l /dev/net/tun        # 应显示字符设备 c 10 200
```

脚本侧的配合：`check` 会在 daed 已安装时自动检查 `/dev/net/tun`；`install --restart-daed` 或服务重启失败时，脚本会原样展示服务输出并对上表关键词给出「原因/解决」提示，无需再搜索。

其他 daed 报错先看完整上下文：

```sh
logread -e daed | tail -n 30
```

## 情况 K：脚本自身报 [错误] 并退出

脚本的致命错误（`[错误]` + 退出）都会在下一行输出 `原因/解决:` 提示，按提示操作即可。常见几类：

- **无法写入 / 无法创建目录**：Flash 空间不足或分区只读，`df -h` 排查；空间紧张时可用 `DD_WORK_DIR` 指向 USB 存储。
- **下载失败（update）**：路由器出站网络/DNS/防火墙问题，或自更新地址失效；按提示 `curl -fsSL <地址>` 手动验证。
- **未找到可用备份（rollback）**：还没有备份，先运行 `backup`。
- **恢复配置失败（rollback）**：备份文件损坏或不兼容，按提示手动 `uci import` 查看具体报错。

`check`/`install` 结束若有 FAIL，会输出「FAIL 修复速查」段落，逐条给出一行式修复命令。

