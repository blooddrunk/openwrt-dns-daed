# 新路由器 Reapply Runbook（2026-10-30 实战版）

> 目标：把本仓库方案 + 当日全部改进（`doh` 跨 VPS DoH 承载组、`routing-extra.dae` 附加规则、`check_tolerance` 选点粘性）完整重放到另一台 OpenWrt 路由器。
>
> 产物分三层，职责不同：
>
> | 层 | 载体 | 谁来写 |
> |---|---|---|
> | UCI / 服务层（dnsmasq、https-dns-proxy、防火墙、IPv6） | `/etc/openwrt-dns-daed.conf` + 脚本 | 脚本自动（幂等） |
> | 脚本片段层（DNS / Routing 文本） | `/root/openwrt-dns-daed/daed/*.dae` | 脚本生成（含 extras 合并），粘贴到 GUI |
> | daed 分组 / 全局层 | `/etc/daed/wing.db` | **GUI 手工**（脚本绝不写库） |
>
> 脚本无法代劳的第三层是重放时最容易漏的部分，本文逐步列出。现网实际取值（真实 IP/端口/域名）以在用路由器的 `/etc/openwrt-dns-daed.conf` 与 `/etc/openwrt-dns-daed.d/routing-extra.dae` 为准，本仓库全部脱敏。

## 0. 前提

- OpenWrt 24.10+（fw4/nftables），SSH 可用；`daed` 已安装（kenzok8/openwrt-daede），`/dev/net/tun` 就绪；
- 自建 VPS 若干（示例三台：`nosla`、`bitsflow`、`lightlayer`=premium 线路），每台 **Reality(tcp) + Hysteria2(udp) 双入口**；
- 占位符约定与仓库一致：IP 用 `203.0.113.10/20/30`，域名用 `*.example.top`。

## 1. 安装脚本（生成 conf 模板）

```sh
curl -fsSL https://raw.githubusercontent.com/blooddrunk/openwrt-dns-daed/main/openwrt-dns-daed.sh | sh -s -- install
```

## 2. 填写 `/etc/openwrt-dns-daed.conf`

生成后**永不被覆盖**，重点填：

```sh
# 全部节点入口（IP:协议:端口，空格分隔；hy2 的 udp 入口也要列）
NODE_ENDPOINTS="203.0.113.10:tcp:39654 203.0.113.10:udp:51237 \
                203.0.113.20:tcp:20185 203.0.113.20:udp:47777 \
                203.0.113.30:tcp:56917 203.0.113.30:udp:36143"
DIRECT_INTERNAL_DOMAINS="internal.example.corp"    # 内网域名，geosite:private 自动追加
PROXY_CN_DOMAINS="xiaohongshu.com nga.cn xueqiu.com"  # 需强制走代理的国内域名
# DAED_DNS_CN_URL / DAED_DNS_FALLBACK_URL 保持 v1.2.2 默认（IP 形式 DoH）即可
```

注意：**hy2 回程 `sip(sport)` 规则脚本不生成**，进第 3 步的 extras 文件维护。

## 3. 放置 `routing-extra.dae`

```sh
mkdir -p /etc/openwrt-dns-daed.d
# 把仓库 examples/routing-extra.dae.example 拷过去，替换占位符
vi /etc/openwrt-dns-daed.d/routing-extra.dae
```

内容模板见 [examples/routing-extra.dae.example](../examples/routing-extra.dae.example)，承载 install 不生成的全部附加规则：hy2 回程 `sip`、STUN 3478、headscale 控制面/DERP 锁出口、自建 CF Access、Google 显式代理、**fallback DoH 钉到 `doh` 组**、Cloudflare Tunnel 直连。插入位置由脚本保证（endpoint 规则之后），规则与 CN/私网规则目标无重叠。

## 4. 重跑 install 生成片段

```sh
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh install
```

产物：`daed-dns.dae`（IP 形式 DoH + `ipversion_prefer: 4`）、`daed-routing.dae`（含 extras 自动合并）、`daed-global-settings.txt`。

## 5. daed GUI 手工项（脚本不做、重放最易漏）

### 5.1 订阅与节点命名

按 VPS 组织订阅（如 main / premium / JP / DE）。**节点命名建议带协议与线路**（`xx-reality-tcp-…`、`xx-hysteria2`）——第 5.2 步 `doh` 组用 `reality` 正则过滤节点，命名规范是前提。

### 5.2 分组（配置 → 分组）

| 分组 | 成员 | 过滤正则 | 策略 | 用途 |
|---|---|---|---|---|
| `proxy` | 主订阅全量 | — | `min` | 日常代理（hy2+reality 混合无妨） |
| `premium` | premium 订阅全量（单 VPS 时保持独占） | — | `min` | 出口质量敏感规则（anthropic/paypal/自建 Access） |
| `doh` | **每台 VPS 的订阅各加一个** | `reality` | `min` | fallback DoH 专用承载：**跨 VPS、纯 Reality/TCP**（硬要求见 README「fallback DoH 上游固定走 Reality 节点」） |
| `tailscale-ctrl` | 出口在 headscale 控制面 VPS 本机的订阅 | — | `min` | 控制面锁出口 |
| `tailscale-derp` | 出口在 DERP VPS 本机的订阅 | — | `min` | DERP 锁出口 |

### 5.3 全局（配置 → 全局）

- **`check_tolerance: 50ms`**（dae 默认；语义：新节点延迟 ≤ 现任−容差才切换。0 容差会在几 ms 差距间反复换节点）；
- 引导解析器留空或 `223.5.5.5:53`，备用解析器 IPv4；TCP/UDP 节点检测按 `daed-global-settings.txt`（IPv4-only）。

### 5.4 粘贴并重启

DNS / Routing 标签页用生成片段**整体替换**保存，然后：

```sh
/etc/init.d/daed restart    # 完整重启；daed UI 里的停止/启动可能只拉起面板、核心不加载
```

## 6. 验证

```sh
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh check          # 期望 0 FAIL
grep -c "no proper dialer" /var/log/daed/daed.log             # 新窗口期应为 0
grep "Group 'doh'" /var/log/daed/daed.log | tail              # 应列出跨 VPS 的 reality 节点及延迟
nslookup www.baidu.com 192.168.10.1 && nslookup www.google.com 192.168.10.1
grep "Health check will only verify" /var/log/daed/daed.log | tail -1   # outbounds 应含 doh
```

## 7. 附录：无 GUI 时的直改库流程（高级，慎用）

> **先检查管理通道是否依赖 daed（2026-10-30 实战教训）**：若这台路由器只能经 tailnet/自建 DERP 访问，而 DERP 流量本身又由 daed 分组承载（`tailscale-ctrl` 等），则**停 daed = 自断管理通道**。在这种设备上绝不能用「SSH 里跑一长串 stop→改→start」的裸流程——连接中途断开就会把 daed 永远停在 stopped，只能现场断电。安全做法：把整个变更写成一个**自愈式一次性脚本**放到路由器上，用 `nohup` 脱离会话执行；并在动手前预置一条兜底延时启动（见下）。

远程自动化或无法访问 GUI 时可直改 `wing.db`（本流程 2026-10-30 实战验证）。脚本本身仍不写库，此为人工操作：

0. **自愈式执行模板**（管理通道依赖 daed 的设备必用；其他设备也建议用，等价于崩溃安全）：

   ```sh
   cat > /tmp/fix-daed.sh <<'EOS'
   #!/bin/sh
   # 幂等：new 库在则换入；无论如何最后都把 daed 拉起
   if [ -f /tmp/wing.db.new ]; then
       rm -f /etc/daed/wing.db-wal /etc/daed/wing.db-shm
       mv /tmp/wing.db.new /etc/daed/wing.db
       chmod 640 /etc/daed/wing.db
   fi
   /etc/init.d/daed restart
   EOS
   # 兜底：即使主脚本意外中断，90 秒后也强制拉起 daed
   nohup sh -c 'sleep 90; /etc/init.d/daed start' >/dev/null 2>&1 &
   nohup sh /tmp/fix-daed.sh >/tmp/fix-daed.log 2>&1 &
   ```

1. 备份三件套：`cp -a /etc/daed/wing.db* <备份目录>/`；
2. `/etc/init.d/daed stop`；拉回 db+`-wal`+`-shm`，用 SQLite 工具改：
   - 新增分组：`INSERT INTO groups (id,name,policy,version,system_id) VALUES (…,'doh','min',1,1)`；
   - 成员：`INSERT INTO group_subscriptions (group_id,subscription_id,name_filter_regex) VALUES (…,'reality')`；
   - 规则文本：改 `routings.routing`（DoH 钉住行 `-> doh`）等，并 `version=version+1`；`dns.dns` / `configs.global` 同理（check_tolerance 在 `configs.global`）；
   - `PRAGMA wal_checkpoint(TRUNCATE)` 后 **`VACUUM`**（清历史行残影，否则脚本「主库含明文即明文」检查可能误报，见 [troubleshooting 情况 E](troubleshooting.md)）；
3. 回传主库，**先删目标机 `-wal`/`-shm` 再覆盖**，`chmod 640`；
4. `/etc/init.d/daed start`，按第 6 节验证（分组/数据完整性在覆盖前用只读查询自证）。

## 8. 相关文档

- README：「fallback DoH 上游固定走 Reality 节点」（doh 组设计与 add_latency 结论）、「自建 Headscale 场景」、「追加自定义 Routing 规则」
- [troubleshooting](troubleshooting.md)：情况 D（回环）、E（明文残影/VACUUM）、F 附（DoH 经分组转发）、L（no proper dialer）
