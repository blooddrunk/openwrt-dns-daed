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

## 情况 F：开启 daed 后，v2rayN 真连接延迟 `-1 ms`

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

## 情况 G：install/check 报 https-dns-proxy 选项 FAIL

https-dns-proxy 的 UCI 选项在不同版本间偶有增减。如果 `check` 报某选项不符：

1. `opkg list-installed | grep https-dns-proxy` 确认版本
2. `uci show https-dns-proxy` 核对该版本实际支持的选项
3. 重跑 `install` 让脚本按目标值重新写入

## 情况 H：需要彻底还原本脚本的所有改动

```sh
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh rollback          # 还原 UCI（最近一次备份）
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh rollback --with-daed   # 连 daed 数据库一起还原
sh /root/openwrt-dns-daed/openwrt-dns-daed.sh clean --purge     # 删除脚本全部产物
```

`rollback --with-daed` 会用备份时的 `wing.db` 覆盖当前数据库（备份之后的 daed 改动全部丢失），仅在你确定需要时使用。
