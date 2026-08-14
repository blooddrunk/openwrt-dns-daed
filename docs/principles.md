# 架构与原理

> 本文解释 openwrt-dns-daed 这套配置**为什么**这样设计。全部规则与地址均为脱敏示例。

## 两条彼此独立的 DNS 链路

这套配置最容易踩的坑，是以为配置了 https-dns-proxy 之后「所有 DNS 都加密了」。实际上有两条链路，必须分别处理：

### 链路 A：LAN / 路由器常规 DNS

```text
LAN 客户端
   ↓ TCP/UDP 53
https-dns-proxy force_dns（强制拉回路由器）
   ↓
dnsmasq :53
   ↓ 唯一上游 127.0.0.1:5053
https-dns-proxy
   ↓ HTTPS/443
AliDNS DoH
```

同时：

```text
LAN 客户端 TCP/UDP 853（DoT）→ REJECT
```

### 链路 B：daed 自己用于域名分流的 DNS

```text
中国域名 geosite:cn → AliDNS DoH
其他域名          → Google Public DNS DoH
```

**关键理解**：`https-dns-proxy` 只负责 dnsmasq/LAN 这条链路；它不会自动把 daed 自己的 DNS upstream 加密。所以 daed 的 DNS upstream 也必须单独改成 DoH，否则国外域名的解析仍走明文 53，继续受企业网关/运营商干扰。

## dnsmasq 层的三个决策

### 1. `noresolv=1`——WAN 下发的 DNS 不再是上游

`/tmp/resolv.conf.d/resolv.conf.auto` 里出现公司 DNS（如 DHCP 下发的 `172.18.x.x`）**并不代表 dnsmasq 在使用它**。只要 `no-resolv` 生效，dnsmasq 就只使用显式配置的 `server=`。排障时不要盯着 resolv.conf.auto。

### 2. 唯一上游 `127.0.0.1#5053`

历史遗留的多实例（5054/5055）端口已无进程监听，属于失效条目，会让排障时的链路判断混乱。目标状态：普通上游只剩 `server=127.0.0.1#5053`。

注意保留 `/域名/` 形式的域限定条目（如 `/mask.icloud.com/`、`/use-application-dns.net/`），它们是 https-dns-proxy 集成管理的 canary，不是异常。

### 3. `dns_redirect=0`——DNS 劫持只由一家负责

若 dnsmasq 的 DNSMASQ HIJACK 与 https-dns-proxy 的 force_dns 同时存在，nftables 里会出现两套 dport 53 规则。职责必须单一：**DNS 强制接管只由 https-dns-proxy 负责**（53 重定向回路由器 + 853 DoT 拒绝 + canary 约束）。

## daed Routing 层的关键规则

### 为什么 DNS 进程要 `must_direct` 而不是 `direct`

```text
pname(dnsmasq, https-dns-proxy) -> must_direct
```

`must_direct` 的目的不是普通分流，而是让这两个本机 DNS 进程的流量**不再被 dae 的透明接管/DNS 劫持捕获**。如果写成普通 `direct`，仍可能形成：

```text
DNS → daed → DNS → daed → ...（回环）
```

这也是「开 daed 后 DNS 失效」的头号原因。

同理，不要把桌面 Linux 的通用示例（NetworkManager、systemd-resolved）带进 OpenWrt——这台设备上真正参与 DNS 的只有 dnsmasq 和 https-dns-proxy。

### 为什么节点 endpoint 必须精确 `must_direct`

自建代理节点的入口流量，如果被 `fallback: proxy` 再次捕获，会形成「代理套代理」：

```text
客户端 / v2rayN
   ↓
代理节点 endpoint
   ↓
daed 再次代理
   ↓
另一个代理节点（甚至可能是自身）
```

症状：Reality / Hysteria2 节点测试异常、真连接延迟 `-1 ms`、连接超时。

正确做法是按「目标 IP + 传输协议 + 目标端口」精确放行：

```text
dip(203.0.113.10/32) && l4proto(tcp) && dport(33973) -> must_direct
dip(203.0.113.10/32) && l4proto(udp) && dport(50757) -> must_direct
```

**不要**写成整台 VPS 直连：

```text
dip(203.0.113.10/32) -> must_direct          # 错误示范
```

同一台 VPS 往往还承载 1Panel、面板、Web/HTTPS 等普通服务。整 IP `must_direct` 会让这些流量也被强制直连，失去通过代理改善访问速度的机会。精确 endpoint 规则下：

```text
203.0.113.10:33973/tcp  → must_direct        # 节点入口
203.0.113.10:443        → 不命中，继续向下匹配
1Panel / 其他端口       → 不命中，继续向下匹配 → fallback: proxy
```

### 规则顺序不可乱

```text
1. DNS/本机保护（pname must_direct）
2. 代理节点 endpoint 精确 must_direct
3. 私网 / 组播 / 内部域名直连
4. premium 特例（geosite:anthropic 等）
5. proxy 特例（需要走代理的国内域名）
6. 中国大陆 direct（geosite:cn / geoip:cn）
7. fallback: proxy
```

例如 `xiaohongshu.com` 虽然属于中国域名，但它的 `-> proxy` 规则写在 `geosite:cn -> direct` 之前，所以仍走代理。同理 Anthropic/PayPal 优先命中 premium。

### 关于 OpenAI 特例

`geosite:openai` 的 premium 特例默认**不启用**（保持注释状态）。需要时把它加入配置文件的 `PREMIUM_GEOSITES` 再重新生成即可。

## bootstrap DNS 的作用

```text
bootstrap_dns = 223.5.5.5,223.6.6.6
```

它只在 https-dns-proxy 启动阶段用于解析 `dns.alidns.com` 这个 DoH 域名本身；之后的实际查询全部走 HTTPS/443。只保留 IPv4 引导即可。

## 这套方案的两个限制

1. **强 53 / 拒 853 ≠ 能阻止所有 DoH**。客户端仍可能自行通过 HTTPS/443 访问第三方 DoH 服务。`canary_domains_icloud` / `canary_domains_mozilla` 能约束一部分系统/浏览器行为，但不能等价于「封锁互联网上所有 DoH」。
2. **daed 配置不要直接编辑数据库**。daed 的配置底层在 `/etc/daed/wing.db`（SQLite），但应通过 GUI 操作（GUI 支持导入/导出）。重装流程：导入 daed 配置 → 核对 DNS → 核对 Routing → 重启验证。

## 推荐的部署/排障顺序

```text
1. 安装并启动 dnsmasq / https-dns-proxy
2. 整理 dnsmasq：no-resolv + 只留 5053
3. 配置 https-dns-proxy：AliDNS DoH + force DNS
4. 验证 5053 / nftables / dnsmasq          ← openwrt-dns-daed.sh install 自动完成 1-4
5. 导入/粘贴 daed DNS 与 Routing 配置      ← 片段由脚本生成，GUI 手动粘贴
6. 重启 daed
7. 完整连通性测试                           ← openwrt-dns-daed.sh check
```

**原则：每完成一层先验证，再进入下一层。** 这样一旦出问题，可以明确故障发生在 `客户端 → dnsmasq → https-dns-proxy → DoH` 还是 `daed DNS → daed Routing → 代理组`，而不是把 DNS、透明代理和防火墙一起改掉之后再猜。
