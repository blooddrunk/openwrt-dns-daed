# openwrt-dns-daed

**OpenWrt 防 DNS 劫持一键部署脚本** —— `dnsmasq` + `https-dns-proxy` + `daed`

适用于企业网关/运营商存在 **DNS 劫持、错误解析、明文 DNS 干扰** 的网络环境。本脚本把一套经过实机验证的加固配置（原为手工排查 checklist）自动化为一条命令，并支持更新、只读体检、备份、回退与清理。

```text
███████╗ OpenWrt 24.10+ · busybox ash · 无交互提问 · 幂等可重跑 · 变更前自动备份
```

---

## 目录

- [背景与架构](#背景与架构)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [首次部署流程](#首次部署流程)
- [命令参考](#命令参考)
- [配置文件详解](#配置文件详解)
- [daed 的手动步骤（GUI）](#daed-的手动步骤gui)
- [脚本到底改了什么](#脚本到底改了什么)
- [验证](#验证)
- [更新 / 回退 / 清理](#更新--回退--清理)
- [常见问题](#常见问题)
- [已知限制](#已知限制)
- [安全注意事项](#安全注意事项)
- [项目结构与开发](#项目结构与开发)

---

## 背景与架构

在企业网络中自建代理节点（VPS + 3x-ui 等）时，节点域名可能被公司网关/运营商劫持或解析到错误 IP，导致节点频繁失联。本方案建立**两条彼此独立、职责清晰**的 DNS 链路：

### 链路 A —— LAN / 路由器常规 DNS

```text
LAN 客户端
   ↓ TCP/UDP 53（硬编码 DNS 被 force_dns 拉回路由器）
dnsmasq :53（no-resolv，忽略 WAN 下发的公司 DNS）
   ↓ 唯一上游 127.0.0.1:5053
https-dns-proxy
   ↓ HTTPS/443 加密
AliDNS DoH

LAN 客户端 TCP/UDP 853（DoT）
   ↓
REJECT（阻止绕过路由器 DNS）
```

### 链路 B —— daed 自身用于域名分流的 DNS

```text
中国域名 geosite:cn → AliDNS DoH
其他域名          → Google Public DNS DoH
默认 ipversion_prefer: 4 → 有 A/AAAA 时仅响应 A，AAAA 返回空答案
```

**关键点**：`https-dns-proxy` 只负责链路 A；daed 自己的 DNS upstream 不会因此自动加密，必须单独改为 DoH，否则国外域名仍会被明文 53 端口的干扰影响。默认的 `ipversion_prefer: 4` 只影响 daed 处理的 DNS，不会改变链路 A 中 `https-dns-proxy` 返回的记录。

详细原理（为什么 `must_direct`、为什么节点要按 endpoint 精确放行等）见 [docs/principles.md](docs/principles.md)。

---

## 环境要求

| 组件 | 要求 | 说明 |
|---|---|---|
| OpenWrt | 24.10+（fw4/nftables） | 24.10/25.x 均可；iptables 旧版本为尽力兼容 |
| Shell | busybox ash / dash | 纯 POSIX sh，无 bash 依赖 |
| `https-dns-proxy` | 必需 | 缺失时脚本会拒绝执行（可用 `--install-missing` 从官方源自动安装） |
| `daed` | 可选 | [kenzok8/openwrt-daede](https://github.com/kenzok8/openwrt-daede)；缺失时仅生成配置片段供后续粘贴 |
| 下载工具 | curl / wget / uclient-fetch 任一 | 仅在线安装与自更新时需要 |

---

## 快速开始

**方式一：管道执行（不落地文件）**

```sh
curl -fsSL https://raw.githubusercontent.com/blooddrunk/openwrt-dns-daed/main/openwrt-dns-daed.sh | sh -s -- install
```

**方式二：先下载再执行（推荐，便于重跑与排障）**

```sh
wget -O /tmp/odd.sh https://raw.githubusercontent.com/blooddrunk/openwrt-dns-daed/main/openwrt-dns-daed.sh
sh /tmp/odd.sh install
```

脚本全程**无交互提问**（对管道执行安全），执行逻辑：

1. 环境与依赖检测（`https-dns-proxy` / `daed` 是否存在）
2. 自动备份当前 UCI / 防火墙 / daed 状态到 `/root/openwrt-dns-daed/backups/`
3. 清理并加固 dnsmasq（`no-resolv`、清掉失效的 5054/5055、关闭重复劫持）
4. 配置 https-dns-proxy（AliDNS DoH、force DNS 53/853、单实例）
5. 重启服务并逐层验证
6. 生成 daed DNS / Routing 配置片段、全局/节点检测设置清单，并对 `wing.db` 做**只读**信号检查
7. 输出报告与后续手动步骤提示

---

## 首次部署流程

```text
1. 在路由器上运行 install（首次会自动生成 /etc/openwrt-dns-daed.conf 模板）
2. 编辑 /etc/openwrt-dns-daed.conf —— 填入你的真实节点 endpoint、内网域名等
3. 再次运行 install —— 用你的配置重新生成 daed 片段与 GUI 设置清单
4. 打开 daed GUI，先按 `daed-global-settings.txt` 设置全局/节点检测
5. 把生成的 DNS / Routing 片段粘贴进对应标签页，保存并重启 daed
6. 运行 check 复查全部信号
```

配置文件**一旦生成永不被覆盖**，升级脚本也不影响你的自定义内容。

---

## 命令参考

```text
openwrt-dns-daed.sh [全局选项] <命令> [命令选项]
```

| 命令 | 说明 |
|---|---|
| `install` | 一键部署/修复（幂等，可重复运行；变更前自动备份） |
| `check` | **只读**体检，逐项输出 PASS/FAIL/WARN 报告，不修改任何配置 |
| `update` | 自更新脚本到最新版并重新应用配置（需配置 `SCRIPT_SELFUPDATE_URL`） |
| `backup` | 手动备份当前 UCI / 防火墙 / daed 状态 |
| `rollback` | 回退到最近一次（或 `--to` 指定）备份 |
| `clean` | 清理脚本产物（默认保留备份与配置文件；`--purge` 全部删除） |
| `version` / `help` | 版本 / 帮助 |

| 选项 | 适用命令 | 说明 |
|---|---|---|
| `--config <路径>` | 全局 | 指定配置文件（默认 `/etc/openwrt-dns-daed.conf`） |
| `--install-missing` | install | 自动安装缺失的 https-dns-proxy（官方源）与 daed（kenzok8 官方脚本） |
| `--no-net-test` | install/check | 跳过 nslookup 连通性测试 |
| `--restart-daed` | install | 部署完成后顺带重启 daed 服务（默认只提示手动重启） |
| `--to <备份目录>` | rollback | 指定回退到哪个备份 |
| `--with-daed` | rollback | 同时恢复 daed 数据库 `wing.db`（会覆盖备份之后的全部 daed 改动，慎用） |
| `--purge` | clean | 连同备份、配置文件、追加片段目录一起删除 |

示例：

```sh
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh check
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh rollback --with-daed
sh /tmp/odd.sh install --install-missing --restart-daed
```

---

## 配置文件详解

配置文件位于 `/etc/openwrt-dns-daed.conf`（可用 `--config` 改路径），模板见仓库中的 [openwrt-dns-daed.conf.example](openwrt-dns-daed.conf.example)。

### LAN / https-dns-proxy

| 变量 | 默认值 | 说明 |
|---|---|---|
| `LAN_IFACES` | `lan` | force_dns 生效的接口，多个用空格分隔 |
| `HDP_RESOLVER_URL` | `https://dns.alidns.com/dns-query` | dnsmasq 上游 DoH 解析器 |
| `HDP_BOOTSTRAP_DNS` | `223.5.5.5,223.6.6.6` | 引导 DNS，仅用于启动时解析 DoH 域名本身 |
| `HDP_LISTEN_ADDR` | `127.0.0.1` | https-dns-proxy 监听地址 |
| `HDP_LISTEN_PORT` | `5053` | https-dns-proxy 监听端口 |

### daed DNS / Routing

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DAED_DNS_CN_URL` | `https://dns.alidns.com/dns-query` | 中国域名（geosite:cn）使用的 DoH |
| `DAED_DNS_FALLBACK_URL` | `https://dns.google/dns-query` | 其余域名使用的 DoH |
| `DAED_DNS_IPVERSION_PREFER` | `4` | daed DNS 遇到同时存在 A/AAAA 的域名时仅响应 A；留空则省略该设置并允许 IPv6 |
| `DAED_GROUP_PROXY` | `proxy` | 普通代理组名，**必须与 daed 中实际组名一致** |
| `DAED_GROUP_PREMIUM` | `premium` | 高级代理组名，同上 |
| `NODE_ENDPOINTS` | 占位符 | **重点配置**。格式 `IP:协议:端口`，空格分隔；支持 IPv6（如 `2001:db8::1:tcp:443`）。只放行节点入口端口，不要对整台 VPS `/32` must_direct |
| `DIRECT_INTERNAL_DOMAINS` | 占位符 | 内部/私有域名（公司内网域名等）直连；`geosite:private` 自动追加 |
| `PREMIUM_GEOSITES` | `anthropic paypal` | 固定走 premium 组的 geosite（不含前缀）；留空则不生成该规则 |
| `PROXY_CN_DOMAINS` | 小红书/NGA/雪球等 | 需强制走代理组的国内域名（在 geosite:cn 直连之前生效） |

### 其他

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DISABLE_IPV6` | `0` | 可选整机禁用 IPv6（见下节）。适合上游拿不到 PD / IPv6 实际不通的网络 |
| `TEST_DOMAIN` | `example.com` | check 连通性测试域名 |
| `MAX_BACKUPS` | `8` | 备份保留份数，超出自动轮转删除 |
| `DAED_EXTRA_DIR` | `/etc/openwrt-dns-daed.d` | 追加片段目录（见下） |
| `SCRIPT_SELFUPDATE_URL` | 内置官方仓库地址 | `update` 在线自更新的脚本地址；fork 后请覆盖，显式置空则禁用在线更新 |
| `DAED_INSTALLER_URL` | kenzok8 官方脚本 | `--install-missing` 安装 daed 时使用 |

### daed 全局 / 节点检测（手动 GUI 清单）

以下变量只用于生成 `daed-global-settings.txt`，脚本不会直接写入 daed 的 `wing.db`：

| 变量 | 默认值 | GUI 中的推荐值/作用 |
|---|---|---|
| `DAED_BOOTSTRAP_RESOLVER` | 空 | 引导解析器留空，使用 dae 默认值；如显式填写请使用 IPv4 `host:port`（可选加固见「节点去 DNS 依赖」） |
| `DAED_FALLBACK_RESOLVER` | `8.8.8.8:53` | 备用解析器；当前值已是 IPv4，仅在系统 DNS 不可用时使用 |
| `DAED_TCP_CHECK_URL` | `http://cp.cloudflare.com` | 节点 TCP 检测链接 |
| `DAED_TCP_CHECK_IPV4` | `1.1.1.1` | 节点 TCP 检测 IPv4 地址 |
| `DAED_UDP_CHECK_DNS` | `223.5.5.5:53` | 节点 UDP 检测 DNS；IPv4-only 配置，不填写 IPv6 地址 |

在当前 IPv4-only 配置下，TCP/UDP 节点检测都不要保留 IPv6 检测地址。若以后需要使用 IPv6，应同时恢复 IPv6 检测并重新评估节点的 IPv6 线路质量。

### 整机禁用 IPv6（DISABLE_IPV6，可选）

**适用场景**：上游拿不到 IPv6 PD 前缀（例如上级是光猫/路由器 NAT、企业内网），或 WAN 上虽有全球 IPv6 地址但实际不通的宽带。

**为什么建议关掉**：WAN 上存在「有名无实」的全球 IPv6 地址时，daed 解析 DoH 上游（如 cloudflare-dns.com）会拿到 AAAA 并优先用 v6 拨号，而 v6 实际不通会导致：

1. 国外域名 DNS 间歇性 SERVFAIL（国内 alidns 正常，表现为「国内能上、外网全挂」）；
2. DNS 瘫痪连累节点域名（如 `*.haoqi90.top`）解析失败，daed 将节点标记不可用，代理整体下线（v4 也一样超时）；
3. LAN 客户端从 RA 拿到 ULA 后不断尝试 IPv6 连接，产生大量 `handleConn: failed to dial [v6]:443` 日志。

重启 daed 只是复位 DNS 连接与节点状态，**不是必然恢复，更不是根治**；彻底移除这个「假 IPv6」才是。

**开启方法**：在 `/etc/openwrt-dns-daed.conf` 中设置后重跑 `install`：

```sh
DISABLE_IPV6="1"
```

`install` 将执行（幂等，仅在值有变化时才 `reload network`）：

- `network.wan.ipv6='0'`（v4 WAN 接口不再获取 IPv6）
- `network.wan6.proto='none'`（独立 v6 WAN 接口停用）
- 删除 `network.globals.ula_prefix`（br-lan 不再持有 ULA/RDNSS）
- `dhcp.lan`（及 `LAN_IFACES` 内全部接口）的 `ra` / `dhcpv6` / `ndp` = `disabled`
- 备份自本版本起包含 `network` 配置，`rollback` 可整体还原

**注意**：

- 客户端已缓存的 ULA/RA 最长约 30 分钟自然老化，重连 Wi-Fi/网线可立即清除；
- 备份与 `check` 均已覆盖 IPv6 状态；`DISABLE_IPV6=0` 时 `check` 会显示一条 SKIP 提示，不产生 FAIL；
- Tailscale 等自带 v6 隧道的接口不受影响（脚本只操作标准 `wan`/`wan6` 与 `LAN_IFACES`）。

### 节点去 DNS 依赖（可选加固）

daed 的节点来自订阅时，server 通常是域名（如 `bwh.example.top`），每次拨号前都要先解析；DNS 链路瘫痪时节点会连坐失联（日志特征：`bootstrap resolver returned no usable address`、`Marking dialer as unavailable`）。两项可选加固，按需启用：

**1. 显式指定 daed 引导解析器（最简单，推荐先做）**

daed 面板 → 配置 → 全局 → 「引导解析器」填 IPv4 的 `223.5.5.5:53`。这样节点域名与 DoH 上游域名的解析不再依赖系统 resolv.conf 链路，而是直连 AliDNS 明文 53（国内毫秒级、与 DoH 链路和节点完全独立）。对应配置变量 `DAED_BOOTSTRAP_RESOLVER`（脚本只生成 GUI 清单，不写 `wing.db`，需手动填写一次）。

**2. Sub-Store 订阅改写：节点 server 域名 → IP（彻底零解析依赖）**

自建 Sub-Store 的，在对应订阅下添加一个「脚本」类型的节点操作：

```js
// 将节点 server 从域名改写为 IP；SNI/serverName 保持域名不变，握手不受影响
const ipMap = {
  'bwh.example.top': '203.0.113.10',
  'nosla.example.top': '198.51.100.20',
  // 按需补充其余节点
};
function operator(proxies) {
  for (const p of proxies) {
    if (ipMap[p.server]) p.server = ipMap[p.server];
  }
  return proxies;
}
```

注意：

- Reality 的 `serverName`/SNI 是独立字段，改写 server 后**保持域名不动**，否则握手失败；
- VPS 换 IP 时需同步修改 `ipMap` 与本脚本的 `NODE_ENDPOINTS`（两者本来就要求一致，不增加维护面）。

只做第 1 项即可消除绝大部分连坐风险；第 2 项适合追求「DNS 全挂也不影响节点拨号」的场景。

### fallback DoH 上游固定走 Reality 节点（可选加固）

**背景**：daed 自身对 fallback DoH 上游（如 cloudflare-dns.com）的查询也会被 dae 按 Routing 分流，通常命中 `fallback: proxy` 从节点出口发出——这也是国外域名 DNS 答案不被污染的原因。代价是 fallback DNS 的可用性 = 所选节点的可用性：当分组策略（如 `min_moving_avg`）选中 Hysteria2 节点、而其 UDP/QUIC 隧道受 QoS 抖动时，DoH 会跟着间歇失败（日志特征：`DNS forward to upstream failed dialer=xx-hysteria2 ... connect error: http3: ...`，该 `http3` 报错来自 Hysteria2 隧道层而非 DoH3）。

**做法**：把 cloudflare-dns.com 的固定 A 记录（`104.16.248.249` / `104.16.249.249`，可 `nslookup cloudflare-dns.com 223.5.5.5` 复核）指向只含 Reality/TCP 节点的分组，规则需位于 `fallback: proxy` 之前：

```text
dip(104.16.248.249/32, 104.16.249.249/32) -> premium
```

前提：目标组（示例为 `premium`）只含 Reality/TCP 节点；若混有 Hysteria2，请先新建一个纯 Reality 组并替换规则右侧。该规则只影响发往这两个 DoH 专用地址的流量（客户端自行直连 cloudflare-dns.com 的 DoH 也会顺路受益），不影响其他 Cloudflare 服务。

两种落地方式：

1. **脚本原生（推荐）**：写入 `DAED_EXTRA_DIR`（默认 `/etc/openwrt-dns-daed.d/`）下的 `routing-extra.dae`（会自动插入到节点 endpoint 规则之后、不会被后续规则遮蔽），重跑 `install` 后把重新生成的 `daed-routing.dae` 整体粘贴到 daed GUI；
2. **手动**：直接在 daed GUI 的 Routing 中该位置添加此行，保存并重启 daed。

**验证**：触发若干次国外域名解析后观察日志，不再出现 `-hysteria2` 的上游失败即为生效：

```sh
grep "DNS forward to upstream failed" /var/log/daed/daed.log | tail
```

### 追加自定义 Routing 规则

在 `DAED_EXTRA_DIR`（默认 `/etc/openwrt-dns-daed.d/`）下放置：

- `routing-extra.dae` —— 插入到「节点 endpoint 规则」之后（适合额外的 `must_direct`）
- `dns-extra.dae` —— 追加到 DNS 片段末尾

文件内容为原始 dae 配置行，例如：

```text
# routing-extra.dae
dip(203.0.113.99/32) && l4proto(tcp) && dport(8443) -> must_direct
```

---

## daed 的手动步骤（GUI）

daed 的配置保存在 `/etc/daed/wing.db`（SQLite 数据库）。按约定**本脚本绝不直接写库**，只生成片段并做只读检查；全局/节点检测设置需要按清单手动填写，DNS/Routing 需要在 GUI 中粘贴：

1. 打开 daed 面板（LuCI → 服务 → daede，或独立面板地址）
2. **配置 → 全局 / 节点检测**：参照 `/root/openwrt-dns-daed/daed/daed-global-settings.txt` 逐项填写
3. **配置 → DNS**：用 `/root/openwrt-dns-daed/daed/daed-dns.dae` 的内容整体替换并保存
4. **配置 → Routing**：用 `/root/openwrt-dns-daed/daed/daed-routing.dae` 的内容整体替换并保存
5. 重启 daed（GUI 内重启，或 `/etc/init.d/daed restart`）
6. 运行 `check` 复查

生成的 DNS / Routing 片段长这样（按你的配置自动生成）：

```text
dns {
    ipversion_prefer: 4
    upstream {
        alidns: 'https://dns.alidns.com/dns-query'
        googledns: 'https://dns.google/dns-query'
    }
    routing {
        request {
            qname(geosite:cn) -> alidns
            fallback: googledns
        }
    }
}

routing {
    pname(dnsmasq, https-dns-proxy) -> must_direct

    # 节点入口精确直连（IP + 协议 + 端口）
    dip(203.0.113.10/32) && l4proto(tcp) && dport(33973) -> must_direct
    dip(203.0.113.10/32) && l4proto(udp) && dport(50757) -> must_direct

    dip(224.0.0.0/3, 255.255.255.255/32, 'ff00::/8') -> direct
    domain(suffix: example.corp, geosite:private) -> direct
    dip(geoip:private) -> direct

    domain(geosite:anthropic, geosite:paypal) -> premium   # 需在 CN 规则之前
    domain(suffix: xiaohongshu.com, ...) -> proxy          # 需在 CN 规则之前

    domain(geosite:cn) -> direct
    dip(geoip:cn) -> direct
    fallback: proxy
}
```

> **重装提示**：daed GUI 支持配置导出/导入。重装 OpenWrt 时先导出 daed 配置，装好后再导入，最后运行本脚本核对。

---

## 脚本到底改了什么

<details>
<summary>点击展开完整变更清单</summary>

**dnsmasq（`/etc/config/dhcp`）**

- `noresolv='1'`：忽略 `/tmp/resolv.conf.d/resolv.conf.auto` 中 WAN 下发的 DNS（公司 DNS 即使出现在这里也不会被使用）
- `dns_redirect='0'`：关闭 dnsmasq 自带的 DNSMASQ HIJACK，DNS 强制接管只由 https-dns-proxy 一家负责
- 清理 `server` / `doh_server` / `doh_backup_server` 中的失效条目：`127.0.0.1#5054`、`127.0.0.1#5055` 等非 5053 环回端口、明文 IPv4/IPv6 上游（如 `223.5.5.5` 或 `2001:4860:4860::8888`）
- **保留** `/域名/` 形式的域限定条目（https-dns-proxy 管理的 canary，如 `/mask.icloud.com/`）
- 确保唯一普通上游 `server=127.0.0.1#5053`

**https-dns-proxy（`/etc/config/https-dns-proxy`）**

- 实例唯一化：只保留一个 `@https-dns-proxy` 实例（历史多实例 5054/5055 已废弃）
- 删除 `notrack_dns`（版本相关的隐藏行为）
- `canary_domains_icloud=1`、`canary_domains_mozilla=1`、`dnsmasq_config_update='*'`
- `force_dns=1`，`force_dns_port` = `53 853`，`force_dns_src_interface` = `lan`
- `procd_trigger_wan6=0`、heartbeat 三项、`user=nobody`、`group=nogroup`、`listen_addr=127.0.0.1`
- 实例：`resolver_url` = AliDNS DoH，`bootstrap_dns` = `223.5.5.5,223.6.6.6`，`listen_port=5053`

**network / dhcp 的 LAN 侧（仅当 `DISABLE_IPV6=1`）**

- `network.wan.ipv6='0'`、`network.wan6.proto='none'`、删除 `network.globals.ula_prefix`
- `LAN_IFACES` 各接口的 `ra` / `dhcpv6` / `ndp` = `disabled`
- 有实际变更时先 `network reload` + 重启 odhcpd，再走下面的服务重启

**重启顺序**：dnsmasq → https-dns-proxy（`DISABLE_IPV6=1` 且有变更时，最前面额外 network reload + odhcpd）

**daed**：生成带 `ipversion_prefer: 4` 的 DNS 片段，并生成全局/节点检测 GUI 设置清单；不直接改动 `wing.db` 或防火墙其他规则（LAN/WAN 接口配置仅在 `DISABLE_IPV6=1` 时按上节调整）

</details>

---

## 验证

```sh
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh check
```

逐项检查（只读）：dnsmasq UCI 与运行态、https-dns-proxy 全部选项与实例数、监听端口、nftables（53 重定向 / 853 拒绝 / 无 DNSMASQ HIJACK）、nslookup 连通性、IPv6 禁用状态（`DISABLE_IPV6=1` 时）、daed 片段与 wing.db 信号。输出示例：

```text
== 验证链路 A: dnsmasq / https-dns-proxy / nftables ==
[ ok ] dnsmasq noresolv=1
[ ok ] dnsmasq 上游包含 127.0.0.1#5053
[ ok ] 无失效的 127.0.0.1#50xx 残留
[ ok ] dns_redirect=0（无 DNSMASQ HIJACK 重复劫持）
...
结果: 32 通过, 0 失败, 1 警告, 2 跳过
```

有任何 FAIL 时按提示排查，常见定位方法见 [docs/troubleshooting.md](docs/troubleshooting.md)。

---

## 更新 / 回退 / 清理

**更新**

```sh
# 方式一：重新执行在线一键安装命令（始终拉最新脚本）
curl -fsSL https://raw.githubusercontent.com/blooddrunk/openwrt-dns-daed/main/openwrt-dns-daed.sh | sh -s -- install

# 方式二：脚本内置自更新地址，直接运行即可（fork 仓库请在配置文件中覆盖 SCRIPT_SELFUPDATE_URL）
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh update
```

`install` 是幂等的：重复运行不会产生重复条目，也不会覆盖你的配置文件。

**回退**

```sh
ls /root/openwrt-dns-daed/backups/                 # 查看备份点
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh rollback           # 回退到最近一次
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh rollback --to /root/openwrt-dns-daed/backups/20260814-120000
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh rollback --with-daed   # 连 wing.db 一起恢复（慎用）
```

每次 `install`/`backup` 前自动创建备份，包含：`uci export` 与原始配置文件、nftables 规则集快照、`wing.db` 副本。默认保留最近 8 份。

**清理**

```sh
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh clean           # 删除片段/日志/脚本副本，保留备份与配置
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh clean --purge   # 全部删除
```

`clean` **不会**还原任何 UCI/daed 配置；需要还原请先 `rollback`。

---

## 常见问题

**Q: WAN DNS 里出现公司 DNS，是被用了吗？**
只要 dnsmasq 运行态存在 `no-resolv` 就不会。`/tmp/resolv.conf.d/resolv.conf.auto` 只是 WAN 下发记录，不必盯着它排障。

**Q: dnsmasq 里又出现 5054/5055 了？**
重跑 `install` 即可清理（幂等），或按 [troubleshooting](docs/troubleshooting.md) 情况 B 手工处理。

**Q: 开 daed 后 DNS 失效 / 回环？**
检查 Routing 开头是否有 `pname(dnsmasq, https-dns-proxy) -> must_direct`，这是防止 daed 接管自身 DNS 形成回环的关键（情况 D）。

**Q: v2rayN 真连接延迟 `-1 ms`？**
节点 endpoint 被 `fallback: proxy` 再次捕获形成代理套代理。按 `IP+协议+端口` 精确 `must_direct`（情况 G）。本脚本生成的片段已按此原则生成，确认 `NODE_ENDPOINTS` 填写正确并在 GUI 粘贴即可。

**Q: 域名还是被解析到错误 IP？**
确认 daed DNS 已全部 DoH 化（情况 E）——GUI 中不能再有 `udp://...:53` / `tcp+udp://...:53` 上游。

**Q: 时不时「国内能上、外网全挂」，重启 daed 有时能恢复？**
典型根因是 WAN 上有「有名无实」的 IPv6：daed 用 v6 拨 DoH 上游超时 → 国外域名 SERVFAIL → 节点域名也解析不出 → 代理整体下线。重启只是复位状态。用 `ping -6 2400:3200::1` 验证 v6 是否真通；不通则在配置中设 `DISABLE_IPV6="1"` 重跑 `install`（见 [整机禁用 IPv6](#整机禁用-ipv6disable_ipv6可选) 与 [troubleshooting 情况 F](docs/troubleshooting.md)）。

**Q: 我的宽带有 IPv6，但 VPS 节点的 IPv6 不稳定，应该怎么办？**
默认生成的 daed DNS 片段包含 `ipversion_prefer: 4`，并且全局节点检测清单只保留 IPv4 检测。注意：该设置只影响 daed 处理的 DNS，且实测部分版本并不会过滤 AAAA；脚本的 LAN `dnsmasq → https-dns-proxy` 链路返回的 AAAA 也需单独处理。最彻底的做法是 `DISABLE_IPV6="1"` 整机关闭 IPv6。详见 [troubleshooting 情况 F](docs/troubleshooting.md)。

更多见 [docs/troubleshooting.md](docs/troubleshooting.md)。

---

## 已知限制

1. **强 53 / 拒 853 ≠ 封锁所有 DoH**：客户端仍可能自行通过 443 端口访问第三方 DoH。canary 域名能约束部分系统/浏览器行为，但不等于全网封锁。
2. **daed 部分需要手动粘贴一次**：本脚本不直接写 `wing.db`，DNS/Routing 需在 GUI 中粘贴脚本生成的片段（这也是 daed 官方推荐方式）。
3. **`force_dns` 端口重定向**只覆盖 `LAN_IFACES` 指定的接口（默认 `lan`）。
4. 默认 `ipversion_prefer: 4` 只影响 daed DNS，不会自动过滤 `https-dns-proxy` 链路返回的 AAAA（部分 daed 版本对自身处理的查询也不过滤）；需要硬保证时用 `DISABLE_IPV6="1"`。
5. https-dns-proxy 未来版本的 UCI 选项如有变化，`check` 会以 FAIL 形式提示差异，便于及时发现。

---

## 安全注意事项

- **本仓库所有文件均已脱敏**：节点 IP 使用 RFC 5737 文档保留地址占位，内网域名使用 `example.corp` 占位。推送前请再次确认没有误提交真实节点 IP、公司域名。
- 切勿提交/公开：daed Dashboard 密码、订阅 URL、节点 UUID/密钥、Reality/TLS 私钥、API Token。
- DNS 与 Routing 规则本身可以公开，但涉及公司内部域名时请保持脱敏。
- 备份目录 `/root/openwrt-dns-daed/backups/` 含 `wing.db` 副本（内含订阅与节点信息），**不要**把该目录内容贴到公开场合。

---

## 项目结构与开发

```text
openwrt-dns-daed/
├── openwrt-dns-daed.sh            # 主脚本（单文件、自包含、POSIX sh）
├── openwrt-dns-daed.conf.example  # 配置模板（与脚本内嵌模板一致）
├── docs/
│   ├── principles.md              # 架构与原理（为什么这样配）
│   └── troubleshooting.md         # 常见故障快速定位
├── tests/
│   ├── bin/uci                    # uci 命令最小替身（状态持久化）
│   ├── fixtures/                  # 脏/净状态种子、nft/netstat/wing.db 样本
│   ├── run_tests.sh               # 沙箱冒烟测试（无需真实路由器）
│   └── README.md                  # 测试说明
├── LICENSE                        # MIT
└── README.md
```

本地开发验证（无需 OpenWrt 设备）：

```sh
dash -n openwrt-dns-daed.sh && busybox sh -n openwrt-dns-daed.sh   # 语法检查
sh tests/run_tests.sh                                              # 沙箱冒烟测试
```

测试沙箱用 uci/nft/netstat/nslookup/init.d 替身模拟路由器环境，覆盖 install 修复脏状态、幂等重跑、备份、回退（含 wing.db）、清理、模板生成等场景（82 项断言）。

---

## License

[MIT](LICENSE)
