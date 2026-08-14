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
```

**关键点**：`https-dns-proxy` 只负责链路 A；daed 自己的 DNS upstream 不会因此自动加密，必须单独改为 DoH，否则国外域名仍会被明文 53 端口的干扰影响。

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
6. 生成 daed DNS / Routing 配置片段，并对 `wing.db` 做**只读**信号检查
7. 输出报告与后续手动步骤提示

---

## 首次部署流程

```text
1. 在路由器上运行 install（首次会自动生成 /etc/openwrt-dns-daed.conf 模板）
2. 编辑 /etc/openwrt-dns-daed.conf —— 填入你的真实节点 endpoint、内网域名等
3. 再次运行 install —— 用你的配置重新生成 daed 片段
4. 打开 daed GUI，把生成的 DNS / Routing 片段粘贴进对应标签页，保存并重启 daed
5. 运行 check 复查全部信号
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
| `DAED_GROUP_PROXY` | `proxy` | 普通代理组名，**必须与 daed 中实际组名一致** |
| `DAED_GROUP_PREMIUM` | `premium` | 高级代理组名，同上 |
| `NODE_ENDPOINTS` | 占位符 | **重点配置**。格式 `IP:协议:端口`，空格分隔；支持 IPv6（如 `2001:db8::1:tcp:443`）。只放行节点入口端口，不要对整台 VPS `/32` must_direct |
| `DIRECT_INTERNAL_DOMAINS` | 占位符 | 内部/私有域名（公司内网域名等）直连；`geosite:private` 自动追加 |
| `PREMIUM_GEOSITES` | `anthropic paypal` | 固定走 premium 组的 geosite（不含前缀）；留空则不生成该规则 |
| `PROXY_CN_DOMAINS` | 小红书/NGA/雪球等 | 需强制走代理组的国内域名（在 geosite:cn 直连之前生效） |

### 其他

| 变量 | 默认值 | 说明 |
|---|---|---|
| `TEST_DOMAIN` | `example.com` | check 连通性测试域名 |
| `MAX_BACKUPS` | `8` | 备份保留份数，超出自动轮转删除 |
| `DAED_EXTRA_DIR` | `/etc/openwrt-dns-daed.d` | 追加片段目录（见下） |
| `SCRIPT_SELFUPDATE_URL` | 内置官方仓库地址 | `update` 在线自更新的脚本地址；fork 后请覆盖，显式置空则禁用在线更新 |
| `DAED_INSTALLER_URL` | kenzok8 官方脚本 | `--install-missing` 安装 daed 时使用 |

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

daed 的配置保存在 `/etc/daed/wing.db`（SQLite 数据库）。按约定**本脚本绝不直接写库**，只生成片段并做只读检查，DNS/Routing 需要你在 GUI 中粘贴一次：

1. 打开 daed 面板（LuCI → 服务 → daede，或独立面板地址）
2. **配置 → DNS**：用 `/root/openwrt-dns-daed/daed/daed-dns.dae` 的内容整体替换并保存
3. **配置 → Routing**：用 `/root/openwrt-dns-daed/daed/daed-routing.dae` 的内容整体替换并保存
4. 重启 daed（GUI 内重启，或 `/etc/init.d/daed restart`）
5. 运行 `check` 复查

生成的 Routing 片段长这样（按你的配置自动生成）：

```text
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
- 清理 `server` / `doh_server` / `doh_backup_server` 中的失效条目：`127.0.0.1#5054`、`127.0.0.1#5055` 等非 5053 环回端口、明文 IP 上游（如 `223.5.5.5`）
- **保留** `/域名/` 形式的域限定条目（https-dns-proxy 管理的 canary，如 `/mask.icloud.com/`）
- 确保唯一普通上游 `server=127.0.0.1#5053`

**https-dns-proxy（`/etc/config/https-dns-proxy`）**

- 实例唯一化：只保留一个 `@https-dns-proxy` 实例（历史多实例 5054/5055 已废弃）
- 删除 `notrack_dns`（版本相关的隐藏行为）
- `canary_domains_icloud=1`、`canary_domains_mozilla=1`、`dnsmasq_config_update='*'`
- `force_dns=1`，`force_dns_port` = `53 853`，`force_dns_src_interface` = `lan`
- `procd_trigger_wan6=0`、heartbeat 三项、`user=nobody`、`group=nogroup`、`listen_addr=127.0.0.1`
- 实例：`resolver_url` = AliDNS DoH，`bootstrap_dns` = `223.5.5.5,223.6.6.6`，`listen_port=5053`

**重启顺序**：dnsmasq → https-dns-proxy

**不改动**：daed 的 `wing.db`（只读检查）、防火墙其他规则、任何 LAN/WAN 接口配置

</details>

---

## 验证

```sh
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh check
```

逐项检查（只读）：dnsmasq UCI 与运行态、https-dns-proxy 全部选项与实例数、监听端口、nftables（53 重定向 / 853 拒绝 / 无 DNSMASQ HIJACK）、nslookup 连通性、daed 片段与 wing.db 信号。输出示例：

```text
== 验证链路 A: dnsmasq / https-dns-proxy / nftables ==
[ ok ] dnsmasq noresolv=1
[ ok ] dnsmasq 上游包含 127.0.0.1#5053
[ ok ] 无失效的 127.0.0.1#50xx 残留
[ ok ] dns_redirect=0（无 DNSMASQ HIJACK 重复劫持）
...
结果: 28 通过, 0 失败, 1 警告, 2 跳过
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
节点 endpoint 被 `fallback: proxy` 再次捕获形成代理套代理。按 `IP+协议+端口` 精确 `must_direct`（情况 F）。本脚本生成的片段已按此原则生成，确认 `NODE_ENDPOINTS` 填写正确并在 GUI 粘贴即可。

**Q: 域名还是被解析到错误 IP？**
确认 daed DNS 已全部 DoH 化（情况 E）——GUI 中不能再有 `udp://...:53` / `tcp+udp://...:53` 上游。

更多见 [docs/troubleshooting.md](docs/troubleshooting.md)。

---

## 已知限制

1. **强 53 / 拒 853 ≠ 封锁所有 DoH**：客户端仍可能自行通过 443 端口访问第三方 DoH。canary 域名能约束部分系统/浏览器行为，但不等于全网封锁。
2. **daed 部分需要手动粘贴一次**：本脚本不直接写 `wing.db`，DNS/Routing 需在 GUI 中粘贴脚本生成的片段（这也是 daed 官方推荐方式）。
3. **`force_dns` 端口重定向**只覆盖 `LAN_IFACES` 指定的接口（默认 `lan`）。
4. https-dns-proxy 未来版本的 UCI 选项如有变化，`check` 会以 FAIL 形式提示差异，便于及时发现。

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
