# 测试说明

本目录提供一套**无需真实 OpenWrt 设备**的沙箱冒烟测试，用于验证主脚本
`openwrt-dns-daed.sh` 的核心逻辑。

## 组成

| 文件 | 作用 |
|---|---|
| `bin/uci` | OpenWrt `uci` 命令的最小可测替身：实现 `show/get/set/add/add_list/del_list/delete/import/export/commit`，状态持久化于 `UCI_STATE` 指定的文件，变更同时记录到 `UCI_CALLS` |
| `fixtures/` | 种子与样本：脏/净状态下的 nft 规则集、netstat 输出、wing.db 文本替身、uci 配置种子 |
| `run_tests.sh` | 测试驱动：搭建沙箱（含 nft/netstat/nslookup/init.d 替身）并执行 T0–T16 场景 |

## 运行

```sh
sh tests/run_tests.sh
```

要求宿主机有 `dash` 或 `busybox`（语法检查）与基本 POSIX 工具。测试不会触碰
真实系统的 `/etc`（所有路径均重定向到 `tests/.sandbox/`，通过脚本的
`DD_*` 环境变量注入）。

## 覆盖的场景

- **T1** version/help 输出
- **T2** 脏状态（5054/5055 残留、明文 IPv4/IPv6 上游、双实例、notrack_dns、DNSMASQ HIJACK）下 `check` 应报 FAIL 且 rc=1
- **T3** `install` 从脏状态修复：逐条校验 uci 调用序列（noresolv/dns_redirect/清理/单实例化/force_dns 53+853）、canary 保留、自动备份、daed DNS 的 `ipversion_prefer: 4`、全局/节点检测清单、daed 片段生成（endpoint 规则、premium/proxy 特例、fallback）、服务重启顺序
- **T4** 安装后 `check` 全过（rc=0）
- **T5** 重复 `install` 幂等：无重复 add_list、无多余 del_list/实例删除
- **T6** 手动 `backup` 与轮转
- **T7** `rollback` 恢复 UCI（含篡改后复原）
- **T8** `rollback --with-daed` 恢复 `wing.db`（daed stop/start）
- **T9** `update` 未配置自更新 URL 时回退为本地副本重跑
- **T10** `clean` 保留备份 / `--purge` 全清
- **T11** 首次运行自动生成配置模板
- **T12** 非法命令/选项报错
- **T13** `--no-net-test` 生效
- **T14** TUN 设备缺失（`DD_TUN_DEV` 指向不存在路径）时 `check` 报 `tun-missing` FAIL，输出 kmod-tun 修复速查；恢复后对照通过
- **T15** `update` 遇死链时 `die` 输出「原因/解决」提示
- **T16** 服务重启失败时原样展示服务输出，并解码 `tun-missing` 为 kmod-tun 处理建议

## 局限

- 替身 uci 只覆盖本项目用到的语义子集，并非完整 uci 实现。
- `/tmp/etc/dnsmasq.conf.*` 运行态检查在沙箱中始终走 SKIP 分支（宿主机无该文件）。
- daed 全局/节点检测设置只生成 `daed-global-settings.txt` 手动清单，测试不会模拟 GUI 写入 `wing.db`。
- daed 安装器（`--install-missing`）与在线自更新走真实网络，未纳入沙箱。
