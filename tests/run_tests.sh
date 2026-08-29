#!/bin/sh
# =============================================================================
# tests/run_tests.sh —— openwrt-dns-daed 沙箱冒烟测试
#
# 在非 OpenWrt 主机上，用 uci/nft/netstat/nslookup/init.d 替身搭建一个
# 最小"假路由器"环境，端到端验证 install / check / backup / rollback /
# update / clean 的行为与幂等性。
#
# 用法: sh tests/run_tests.sh
# =============================================================================
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/openwrt-dns-daed.sh"
FIX="$ROOT/tests/fixtures"
SB="$ROOT/tests/.sandbox"
PASS=0; FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

assert_rc() { # 描述 期望rc 实际rc
    if [ "$2" = "$3" ]; then ok "$1 (rc=$3)"; else bad "$1 (期望 rc=$2, 实际 rc=$3)"; fi
}
assert_grep() { # 描述 文件 固定字符串
    if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 [在 $2 中未找到: $3]"; fi
}
assert_not_grep() { # 描述 文件 固定字符串
    if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1 [在 $2 中不应出现: $3]"; else ok "$1"; fi
}
assert_file() { [ -e "$2" ] && ok "$1" || bad "$1 [缺少: $2]"; }
assert_no_file() { [ ! -e "$2" ] && ok "$1" || bad "$1 [不应存在: $2]"; }

# ---- 搭建沙箱 ----
build_sandbox() {
    rm -rf "$SB"
    mkdir -p "$SB/bin" "$SB/initd" "$SB/etc/config" "$SB/etc/daed" "$SB/work" "$SB/etc/extra.d"

    cp "$FIX/dhcp.seed" "$SB/etc/config/dhcp"
    cp "$FIX/https-dns-proxy.seed" "$SB/etc/config/https-dns-proxy"
    cp "$FIX/network.seed" "$SB/etc/config/network"
    cp "$FIX/wing-db.fixture" "$SB/etc/daed/wing.db"

    # TUN 设备替身：让 /dev/net/tun 预检在沙箱中结果确定（T14 会指向不存在的路径）
    : > "$SB/tun-dev"

    # 测试配置（覆盖默认值，并指向沙箱内的追加片段目录，避免触碰真实 /etc）
    cat > "$SB/etc/openwrt-dns-daed.conf" <<EOF
NODE_ENDPOINTS="203.0.113.10:tcp:33973 203.0.113.10:udp:50757 198.51.100.20:tcp:12142"
DIRECT_INTERNAL_DOMAINS="corp.example"
PREMIUM_GEOSITES="anthropic paypal"
PROXY_CN_DOMAINS="xiaohongshu.com nga.cn"
DAED_GROUP_PROXY="proxy"
DAED_GROUP_PREMIUM="premium"
DAED_EXTRA_DIR="$SB/etc/extra.d"
# 测试环境禁用在线自更新，走本地副本分支
SCRIPT_SELFUPDATE_URL=""
EOF

    # 命令替身
    cat > "$SB/bin/nft" <<EOF
#!/bin/sh
cat "\${NFT_OUT:-$FIX/nft-clean.txt}"
EOF
    cat > "$SB/bin/netstat" <<EOF
#!/bin/sh
[ "\$1" = "-lnptu" ] && cat "$FIX/netstat.txt" || exit 1
EOF
    cat > "$SB/bin/nslookup" <<'EOF'
#!/bin/sh
# busybox nslookup 替身：对 127.0.0.1 系列服务器返回成功
case "$2" in
    127.0.0.1*)
        echo "Server:    $2"
        echo "Address 1: 93.184.216.34 $1"
        exit 0 ;;
    *) exit 1 ;;
esac
EOF
    cp "$ROOT/tests/bin/uci" "$SB/bin/uci"

    # busybox 兼容哨兵：目标是 OpenWrt 的 busybox tr，它不支持 GNU 的
    # [:class:] 字符类（会被当成字面字符集、检查静默失效）。沙箱运行在
    # GNU coreutils 上，用此替身让任何字符类用法在测试期就报错。
    cat > "$SB/bin/tr" <<'EOF'
#!/bin/sh
for a in "$@"; do
    case "$a" in
        *\[:*]:*) echo "tr(GNU-only class): $a" >&2; exit 1 ;;
    esac
done
exec /usr/bin/tr "$@"
EOF

    # iproute2 替身：维护每设备 IPv6 地址（模拟 br-lan 上残留的 deprecated ULA、
    # WAN 上的动态 GUA 与不受影响的 link-local）
    cat > "$SB/bin/ip" <<'EOF'
#!/bin/sh
# 用法子集: ip -6 addr show dev DEV / ip -6 addr del ADDR dev DEV
# 状态文件 $IP_STATE 每行: <dev> <addr> <scope> [flags...]
# 删除调用记录到 $IP_CALLS
STATE="${IP_STATE:?IP_STATE 未设置}"
CALLS="${IP_CALLS:-}"
[ "$1" = "-6" ] && [ "$2" = "addr" ] || exit 1
shift 2
case "$1" in
    show)
        [ "$2" = "dev" ] || exit 1
        dev="$3"
        out=$(grep "^${dev} " "$STATE" 2>/dev/null)
        [ -n "$out" ] || exit 0
        printf '%s\n' "$out" | while read -r d a s rest; do
            printf '    inet6 %s scope %s %s\n' "$a" "$s" "$rest"
        done
        ;;
    del)
        # ip -6 addr del ADDR dev DEV
        addr="$2"; [ "$3" = "dev" ] || exit 1
        dev="$4"
        if grep -q "^${dev} ${addr} " "$STATE" 2>/dev/null; then
            grep -v "^${dev} ${addr} " "$STATE" > "${STATE}.tmp" && mv "${STATE}.tmp" "$STATE"
            [ -n "$CALLS" ] && echo "del $addr dev $dev" >> "$CALLS"
            exit 0
        fi
        exit 1
        ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$SB/bin/uci" "$SB/bin/ip" "$SB/bin/nft" "$SB/bin/netstat" "$SB/bin/nslookup" "$SB/bin/tr"

    # IPv6 地址初始状态：br-lan 残留 deprecated ULA + link-local，WAN 有动态 GUA
    cat > "$SB/ip.state" <<'EOF'
br-lan fde7:59de:5678::1/60 global deprecated dynamic
br-lan fe80::ca75:f4ff:fe5c:e77c/64 link
eth1 2408:8207:1234:5678::1/64 global dynamic
EOF
    : > "$SB/ip.calls"

    # init.d 替身
    for svc in dnsmasq https-dns-proxy daed network odhcpd; do
        cat > "$SB/initd/$svc" <<'EOF'
#!/bin/sh
echo "$(basename "$0") $*" >> "$INITD_LOG"
exit 0
EOF
        chmod +x "$SB/initd/$svc"
    done
    : > "$SB/initd.log"
}

seed_uci() {
    rm -f "$SB/uci.state" "$SB/uci.calls"
    UCI_STATE="$SB/uci.state" "$SB/bin/uci" import dhcp < "$SB/etc/config/dhcp"
    UCI_STATE="$SB/uci.state" "$SB/bin/uci" import https-dns-proxy < "$SB/etc/config/https-dns-proxy"
    UCI_STATE="$SB/uci.state" "$SB/bin/uci" import network < "$SB/etc/config/network"
    : > "$SB/uci.calls"
    : > "$SB/ip.calls"
}

# run_script <子命令及参数...>  —— 返回脚本 rc，stdout 存入 $SB/last.out
run_script() {
    DD_IGNORE_OS=1 DD_IGNORE_ROOT=1 \
    DD_WORK_DIR="$SB/work" DD_INIT_DIR="$SB/initd" DD_CONFIG_DIR="$SB/etc/config" \
    DD_DAED_DB="$SB/etc/daed/wing.db" \
    DD_TUN_DEV="${DD_TUN_DEV:-$SB/tun-dev}" \
    UCI_STATE="$SB/uci.state" UCI_CALLS="$SB/uci.calls" INITD_LOG="$SB/initd.log" \
    IP_STATE="$SB/ip.state" IP_CALLS="$SB/ip.calls" \
    NFT_OUT="$NFT_OUT" \
    PATH="$SB/bin:$PATH" \
    sh "$SCRIPT" --config "$SB/etc/openwrt-dns-daed.conf" "$@" > "$SB/last.out" 2>&1
}

show_state() { UCI_STATE="$SB/uci.state" "$SB/bin/uci" show "$1" 2>/dev/null; }

echo "== T0: 环境与沙箱搭建 =="
build_sandbox
assert_file "沙箱已搭建" "$SB/bin/uci"

echo "== T1: version / help =="
PATH="$SB/bin:$PATH" sh "$SCRIPT" version > "$SB/t1.out" 2>&1
assert_rc "version rc=0" 0 $?
assert_grep "version 输出" "$SB/t1.out" "openwrt-dns-daed v"
PATH="$SB/bin:$PATH" sh "$SCRIPT" help > "$SB/t1b.out" 2>&1
assert_rc "help rc=0" 0 $?
assert_grep "help 含 install" "$SB/t1b.out" "install"
assert_grep "help 含 rollback" "$SB/t1b.out" "rollback"

echo "== T2: 脏状态下 check 应报 FAIL (rc=1) =="
build_sandbox
seed_uci
NFT_OUT="$FIX/nft-dirty.txt" run_script check
assert_rc "check(脏) rc=1" 1 $?
assert_grep "报 noresolv 失败" "$SB/last.out" "noresolv!=1"
assert_grep "报 dns_redirect 失败" "$SB/last.out" "dns_redirect=1"
assert_grep "报明文上游失败" "$SB/last.out" "223.5.5.5"
assert_grep "报明文 IPv6 上游失败" "$SB/last.out" "2001:4860:4860::8888#53"
assert_grep "报实例数失败" "$SB/last.out" "实例数为 2"
assert_grep "报失效环回上游" "$SB/last.out" "存在失效环回上游"
assert_grep "报 DNSMASQ HIJACK" "$SB/last.out" "DNSMASQ HIJACK"
assert_grep "报 notrack_dns 警告" "$SB/last.out" "notrack_dns"

echo "== T3: install 从脏状态修复 (rc=0) =="
NFT_OUT="$FIX/nft-clean.txt" run_script install
assert_rc "install rc=0" 0 $?
CALLS="$SB/uci.calls"
assert_grep "设置 noresolv=1" "$CALLS" "set dhcp.@dnsmasq[0].noresolv=1"
assert_grep "设置 dns_redirect=0" "$CALLS" "set dhcp.@dnsmasq[0].dns_redirect=0"
assert_grep "清理 server 5054" "$CALLS" "del_list dhcp.@dnsmasq[0].server=127.0.0.1#5054"
assert_grep "清理 server 5055" "$CALLS" "del_list dhcp.@dnsmasq[0].server=127.0.0.1#5055"
assert_grep "清理 doh_server 5054" "$CALLS" "del_list dhcp.@dnsmasq[0].doh_server=127.0.0.1#5054"
assert_grep "清理 doh_backup 5054" "$CALLS" "del_list dhcp.@dnsmasq[0].doh_backup_server=127.0.0.1#5054"
assert_grep "清理明文上游 223.5.5.5" "$CALLS" "del_list dhcp.@dnsmasq[0].server=223.5.5.5"
assert_grep "清理明文 IPv6 上游" "$CALLS" "del_list dhcp.@dnsmasq[0].server=2001:4860:4860::8888#53"
assert_not_grep "5053 已存在不再 add_list" "$CALLS" "add_list dhcp.@dnsmasq[0].server="
assert_grep "删除多余 hdp 实例" "$CALLS" "delete https-dns-proxy.@https-dns-proxy[-1]"
assert_grep "删除 notrack_dns" "$CALLS" "delete https-dns-proxy.config.notrack_dns"
assert_grep "force_dns_port 53" "$CALLS" "add_list https-dns-proxy.config.force_dns_port=53"
assert_grep "force_dns_port 853" "$CALLS" "add_list https-dns-proxy.config.force_dns_port=853"
assert_grep "提交 dhcp" "$CALLS" "commit dhcp"
assert_grep "提交 https-dns-proxy" "$CALLS" "commit https-dns-proxy"
# 备份与片段
first_backup=$(ls -1 "$SB/work/backups" | head -n 1)
assert_file "自动备份已创建" "$SB/work/backups/$first_backup/dhcp.uci"
assert_grep "备份含 package 头" "$SB/work/backups/$first_backup/dhcp.uci" "package dhcp"
assert_file "备份 wing.db" "$SB/work/backups/$first_backup/wing.db"
RT="$SB/work/daed/daed-routing.dae"
DNSN="$SB/work/daed/daed-dns.dae"
assert_grep "Routing: endpoint tcp 规则" "$RT" "dip(203.0.113.10/32) && l4proto(tcp) && dport(33973) -> must_direct"
assert_grep "Routing: endpoint udp 规则" "$RT" "dip(203.0.113.10/32) && l4proto(udp) && dport(50757) -> must_direct"
assert_grep "Routing: fallback 组" "$RT" "fallback: proxy"
assert_grep "Routing: 强制代理域名" "$RT" "suffix: xiaohongshu.com"
assert_grep "Routing: premium 组" "$RT" "geosite:anthropic"
assert_grep "Routing: 内部域名" "$RT" "suffix: corp.example"
assert_grep "Routing: geosite:cn 直连" "$RT" "domain(geosite:cn) -> direct"
assert_grep "DNS: CN 分流" "$DNSN" "qname(geosite:cn) -> alidns"
assert_grep "DNS: DoH CN 上游(IP)" "$DNSN" "https://223.5.5.5/dns-query"
assert_grep "DNS: DoH fallback 上游(IP)" "$DNSN" "https://1.1.1.1/dns-query"
assert_grep "DNS: fallback 上游键名" "$DNSN" "fallback: cloudflaredns"
assert_grep "DNS: IPv4 优先" "$DNSN" "ipversion_prefer: 4"
GLOBAL="$SB/work/daed/daed-global-settings.txt"
assert_file "daed 全局设置清单" "$GLOBAL"
assert_grep "全局清单 IPv4 fallback" "$GLOBAL" "备用解析器: 8.8.8.8:53"
assert_grep "全局清单 UDP IPv4" "$GLOBAL" "UDP 检测 DNS: 223.5.5.5:53"
assert_grep "全局清单禁用 IPv6 检测" "$GLOBAL" "TCP 检测 IPv6: 不配置"
# 服务重启顺序
assert_grep "重启顺序: dnsmasq 在前" "$SB/initd.log" "dnsmasq restart"
if grep -n "dnsmasq restart" "$SB/initd.log" | head -1 | cut -d: -f1 | \
   awk -v f="$(grep -n "https-dns-proxy restart" "$SB/initd.log" | head -1 | cut -d: -f1)" \
       'NR==1 { exit !($1 < f) }'; then
    ok "dnsmasq 先于 https-dns-proxy 重启"
else
    bad "dnsmasq 应先于 https-dns-proxy 重启"
fi
# canary 域限定条目保留、失效条目清理（最终状态）
show_state dhcp > "$SB/state.show"
assert_grep "最终状态保留 canary" "$SB/state.show" "/use-application-dns.net/"
if grep -qF "127.0.0.1#5054" "$SB/state.show"; then bad "最终状态仍含 5054"; else ok "最终状态无 5054"; fi

echo "== T4: install 后 check 应全过 (rc=0) =="
run_script check
assert_rc "check(净) rc=0" 0 $?
assert_grep "check 输出通过统计" "$SB/last.out" "结果:"
sleep 1

echo "== T5: 重复 install 幂等 =="
: > "$SB/uci.calls"
run_script install
assert_rc "重复 install rc=0" 0 $?
assert_not_grep "无 server add_list" "$SB/uci.calls" "add_list dhcp.@dnsmasq[0].server="
assert_not_grep "无 server del_list" "$SB/uci.calls" "del_list dhcp.@dnsmasq[0]"
assert_not_grep "无多余实例删除" "$SB/uci.calls" "delete https-dns-proxy.@https-dns-proxy[-1]"
assert_grep "幂等输出提示已存在" "$SB/last.out" "已存在"
sleep 1

echo "== T6: 手动 backup =="
run_script backup
assert_rc "backup rc=0" 0 $?
n=$(ls -1 "$SB/work/backups" | grep -cE '^[0-9]{8}-[0-9]{6}$')
[ "$n" -ge 3 ] && ok "备份数量>=3 (实际 $n)" || bad "备份数量异常: $n"
sleep 1

echo "== T7: rollback 恢复 UCI =="
UCI_STATE="$SB/uci.state" "$SB/bin/uci" add_list 'dhcp.@dnsmasq[0].server=8.8.8.8'
UCI_STATE="$SB/uci.state" "$SB/bin/uci" set 'dhcp.@dnsmasq[0].noresolv=0'
run_script rollback
assert_rc "rollback rc=0" 0 $?
show_state dhcp > "$SB/state7.show"
assert_grep "回退后 noresolv=1" "$SB/state7.show" "noresolv='1'"
if grep -qF "8.8.8.8" "$SB/state7.show"; then bad "回退后仍含 8.8.8.8"; else ok "回退后无 8.8.8.8"; fi

echo "== T8: rollback --with-daed 恢复 wing.db =="
echo "tampered" > "$SB/etc/daed/wing.db"
run_script rollback --to "$SB/work/backups/$first_backup" --with-daed
assert_rc "rollback --with-daed rc=0" 0 $?
assert_grep "wing.db 已恢复" "$SB/etc/daed/wing.db" "must_direct"
if grep -qF "tampered" "$SB/etc/daed/wing.db"; then bad "wing.db 仍含篡改内容"; else ok "wing.db 篡改内容已清除"; fi
assert_grep "daed 已 stop" "$SB/initd.log" "daed stop"
assert_grep "daed 已 start" "$SB/initd.log" "daed start"

echo "== T9: update 无 URL 时用本地副本重跑 =="
run_script update
cp "$SB/last.out" "$SB/t9.out"
assert_rc "update rc=0" 0 $?
assert_grep "提示使用本地副本" "$SB/last.out" "使用本地副本重新应用配置"
assert_file "本地脚本副本存在" "$SB/work/openwrt-dns-daed.sh"

echo "== T10: clean 保留备份 / --purge 全清 =="
run_script clean
assert_rc "clean rc=0" 0 $?
assert_no_file "片段已删除" "$SB/work/daed/daed-routing.dae"
assert_file "备份仍保留" "$SB/work/backups"
assert_file "配置文件仍保留" "$SB/etc/openwrt-dns-daed.conf"
run_script clean --purge
assert_rc "clean --purge rc=0" 0 $?
assert_no_file "工作目录已删除" "$SB/work"
assert_no_file "配置文件已删除" "$SB/etc/openwrt-dns-daed.conf"
assert_no_file "追加片段目录已删除" "$SB/etc/extra.d"

echo "== T11: 配置文件模板生成 =="
mkdir -p "$SB/work2"
DD_IGNORE_OS=1 DD_IGNORE_ROOT=1 \
DD_WORK_DIR="$SB/work2" DD_INIT_DIR="$SB/initd" DD_CONFIG_DIR="$SB/etc/config" \
DD_DAED_DB="$SB/etc/daed/wing.db" DD_TUN_DEV="$SB/tun-dev" \
UCI_STATE="$SB/uci.state" UCI_CALLS="$SB/uci.calls" INITD_LOG="$SB/initd.log" \
NFT_OUT="$FIX/nft-clean.txt" PATH="$SB/bin:$PATH" \
sh "$SCRIPT" --config "$SB/etc/conf-gen.conf" install > "$SB/last.out" 2>&1
assert_rc "首装 rc=0" 0 $?
assert_file "模板已生成" "$SB/etc/conf-gen.conf"
assert_grep "模板含 NODE_ENDPOINTS" "$SB/etc/conf-gen.conf" "NODE_ENDPOINTS="
assert_grep "模板含 IPv4 DNS 偏好" "$SB/etc/conf-gen.conf" "DAED_DNS_IPVERSION_PREFER=\"4\""
assert_grep "模板含 UDP 检测 DNS" "$SB/etc/conf-gen.conf" "DAED_UDP_CHECK_DNS=\"223.5.5.5:53\""
assert_grep "提示编辑配置" "$SB/last.out" "请编辑"

echo "== T12: 非法命令/选项应报错 =="
run_script bogus-cmd
assert_rc "未知命令 rc!=0" 1 $?
assert_grep "未知命令提示" "$SB/last.out" "未知命令"
run_script --bogus-flag check
assert_rc "未知选项 rc!=0" 1 $?
assert_grep "未知选项提示" "$SB/last.out" "未知选项"

echo "== T13: check --no-net-test =="
run_script check --no-net-test
assert_grep "跳过网络测试" "$SB/last.out" "网络测试已禁用"

echo "== T14: TUN 缺失时 check 报 FAIL 并给出 kmod-tun 修复速查 =="
DD_TUN_DEV="$SB/no-such-tun" run_script check
assert_rc "check(无 TUN) rc=1" 1 $?
assert_grep "报 tun-missing FAIL" "$SB/last.out" "blocked preconditions: tun-missing"
assert_grep "FAIL 行给出修复指向" "$SB/last.out" "opkg update && opkg install kmod-tun"
assert_grep "速查段含 TUN 项" "$SB/last.out" "TUN 缺失"
# 恢复 TUN 存在时同一状态应回到通过（对照）
run_script check
assert_rc "check(有 TUN) rc=0" 0 $?

echo "== T15: update 下载失败时输出 原因/解决 提示 =="
cat >> "$SB/etc/openwrt-dns-daed.conf" <<EOF
SCRIPT_SELFUPDATE_URL="http://127.0.0.1:1/unreachable.sh"
EOF
run_script update
assert_rc "update(死链) rc=1" 1 $?
assert_grep "报下载失败" "$SB/last.out" "下载失败"
assert_grep "输出原因/解决提示" "$SB/last.out" "原因/解决"

echo "== T16: 服务重启失败时展示输出并解码 tun-missing =="
cat > "$SB/initd/daed" <<'EOF'
#!/bin/sh
echo "[ERROR] blocked preconditions: tun-missing" >&2
exit 1
EOF
chmod +x "$SB/initd/daed"
run_script install --restart-daed
assert_grep "原样展示服务输出" "$SB/last.out" "[ERROR] blocked preconditions: tun-missing"
assert_grep "解码出 kmod-tun 提示" "$SB/last.out" "缺少 TUN 设备"
assert_grep "给出手动排查入口" "$SB/last.out" "logread -e daed"

echo "== T17: DISABLE_IPV6=1 时 install 禁用整机 IPv6 =="
build_sandbox
seed_uci
cat >> "$SB/etc/openwrt-dns-daed.conf" <<EOF
DISABLE_IPV6="1"
EOF
run_script install
assert_rc "install(ipv6) rc=0" 0 $?
CALLS="$SB/uci.calls"
assert_grep "停用 wan.ipv6" "$CALLS" "set network.wan.ipv6=0"
assert_grep "停用 wan6" "$CALLS" "set network.wan6.proto=none"
assert_grep "删除 ULA 前缀" "$CALLS" "delete network.globals.ula_prefix"
assert_grep "关闭 LAN RA" "$CALLS" "set dhcp.lan.ra=disabled"
assert_grep "关闭 LAN DHCPv6" "$CALLS" "set dhcp.lan.dhcpv6=disabled"
assert_grep "关闭 LAN NDP" "$CALLS" "set dhcp.lan.ndp=disabled"
assert_grep "提交 network" "$CALLS" "commit network"
assert_grep "重载 network" "$SB/initd.log" "network reload"
assert_grep "重启 odhcpd" "$SB/initd.log" "odhcpd restart"
assert_grep "清理 br-lan 残留 ULA" "$SB/last.out" "已移除 br-lan 上的残留 IPv6 地址: fde7:59de:5678::1/60"
assert_grep "清理 WAN 残留 GUA" "$SB/last.out" "已移除 eth1 上的残留 IPv6 地址: 2408:8207:1234:5678::1/64"
assert_grep "del 调用含 ULA" "$SB/ip.calls" "del fde7:59de:5678::1/60 dev br-lan"
assert_not_grep "link-local 不受影响" "$SB/ip.calls" "fe80"
first17_backup=$(ls -1 "$SB/work/backups" | head -n 1)
assert_grep "备份含 network.uci" "$SB/work/backups/$first17_backup/network.uci" "package network"
show_state network > "$SB/state17n.show"
assert_grep "wan6 已停用" "$SB/state17n.show" "proto='none'"
assert_grep "wan.ipv6=0" "$SB/state17n.show" "ipv6='0'"
if grep -qF "ula_prefix" "$SB/state17n.show"; then bad "ULA 前缀仍存在"; else ok "ULA 前缀已删除"; fi
run_script check
assert_rc "check(ipv6) rc=0" 0 $?
assert_grep "IPv6 wan 检查 PASS" "$SB/last.out" "IPv6: network.wan.ipv6=0"
assert_grep "IPv6 LAN 检查 PASS" "$SB/last.out" "ra/dhcpv6/ndp=disabled"
assert_grep "IPv6 残留地址检查 PASS" "$SB/last.out" "IPv6: LAN/WAN 接口无残留的 global 域 IPv6 地址"
sleep 1
: > "$SB/initd.log"
: > "$SB/ip.calls"
run_script install
assert_rc "重复 install(ipv6) rc=0" 0 $?
assert_not_grep "幂等: 不再 reload network" "$SB/initd.log" "network reload"
assert_not_grep "幂等: 无残留时不产生 del 调用" "$SB/ip.calls" "del "
assert_grep "幂等: 提示无残留地址" "$SB/last.out" "无残留的 global 域 IPv6 地址"
sleep 1
run_script rollback --to "$SB/work/backups/$first17_backup"
assert_rc "rollback(ipv6) rc=0" 0 $?
show_state network > "$SB/state17r.show"
assert_grep "wan6 恢复 dhcpv6" "$SB/state17r.show" "proto='dhcpv6'"
assert_grep "ULA 前缀恢复" "$SB/state17r.show" "ula_prefix"
show_state dhcp > "$SB/state17d.show"
assert_grep "RA 恢复 hybrid" "$SB/state17d.show" "ra='hybrid'"
assert_grep "rollback 后重载 network" "$SB/initd.log" "network reload"

echo "== T18: WAL 未 checkpoint 时信号从 -wal 读取，明文历史行不误报 =="
build_sandbox
seed_uci
run_script install
assert_rc "install(wal 场景) rc=0" 0 $?
# 主库 = 陈旧快照（不含任何 daed 配置信号）；当前配置全部位于 -wal：
# 前半是 daed 默认明文 DNS 的历史帧，后半是当前 DoH 配置帧
cat > "$SB/etc/daed/wing.db" <<'EOF'
FAKE-SQLITE-HEADER (stale checkpoint snapshot, no config rows)
EOF
cat > "$SB/etc/daed/wing.db-wal" <<'EOF'
WAL frame 1: historical revision (daed default plaintext DNS)
dns: upstream { alidns: 'udp://223.5.5.5:53' googledns: 'tcp+udp://8.8.8.8:53' }
WAL frame 2: current revision (DoH snippet pasted)
dns: upstream alidns='https://223.5.5.5/dns-query' cloudflaredns='https://1.1.1.1/dns-query'
dns: ipversion_prefer: 4
dns: routing qname(geosite:cn) -> alidns, fallback: cloudflaredns
routing: dip(203.0.113.10/32) && l4proto(tcp) && dport(33973) -> must_direct
routing: dip(203.0.113.10/32) && l4proto(udp) && dport(50757) -> must_direct
routing: dip(198.51.100.20/32) && l4proto(tcp) && dport(12142) -> must_direct
group: proxy premium
EOF
run_script check
assert_rc "check(wal) rc=0" 0 $?
assert_not_grep "明文历史行不误报" "$SB/last.out" "疑似仍是明文"
assert_grep "两个 DoH 上游信号来自 -wal" "$SB/last.out" "daed DNS 已包含两个 DoH 上游信号"
assert_grep "ipversion 信号来自 -wal" "$SB/last.out" "ipversion_prefer: 4 信号"
assert_grep "must_direct 信号来自 -wal" "$SB/last.out" "存在 must_direct 规则信号"
assert_grep "endpoint IP 信号来自 -wal" "$SB/last.out" "全部节点 endpoint IP 均有信号"
assert_not_grep "DoH 上游 WARN 不出现" "$SB/last.out" "未同时发现两个 DoH 上游"
assert_not_grep "ipversion WARN 不出现" "$SB/last.out" "未见 ipversion_prefer"
assert_not_grep "must_direct WARN 不出现" "$SB/last.out" "未见 must_direct"

echo "== T19: -wal 中明文为最新写入（DoH 后改回明文）应报 FAIL =="
cat > "$SB/etc/daed/wing.db-wal" <<'EOF'
WAL frame 1: old DoH revision
dns: upstream alidns='https://223.5.5.5/dns-query' cloudflaredns='https://1.1.1.1/dns-query'
routing: dip(203.0.113.10/32) && l4proto(tcp) && dport(33973) -> must_direct
WAL frame 2: reverted to plaintext (latest write)
dns: upstream { alidns: 'udp://223.5.5.5:53' googledns: 'tcp+udp://8.8.8.8:53' }
EOF
run_script check
assert_rc "check(改回明文) rc=1" 1 $?
assert_grep "明文 FAIL 按最新写入触发" "$SB/last.out" "daed DNS 疑似仍是明文 :53 上游"

echo "== T20: backup 备份 -wal；rollback --with-daed 正确处置 sidecar =="
run_script backup
assert_rc "backup rc=0" 0 $?
t20_backup=$(ls -1 "$SB/work/backups" | tail -n 1)
assert_file "备份含 wing.db-wal" "$SB/work/backups/$t20_backup/wing.db-wal"
assert_grep "-wal 内容完整" "$SB/work/backups/$t20_backup/wing.db-wal" "reverted to plaintext"
echo "tampered-wal" > "$SB/etc/daed/wing.db-wal"
run_script rollback --to "$SB/work/backups/$t20_backup" --with-daed
assert_rc "rollback(含 wal) rc=0" 0 $?
assert_grep "-wal 随备份恢复" "$SB/etc/daed/wing.db-wal" "reverted to plaintext"
if grep -qF "tampered-wal" "$SB/etc/daed/wing.db-wal"; then bad "-wal 恢复失败"; else ok "-wal 篡改内容已清除"; fi
# 回滚到无 -wal 的旧备份：现役 -wal 必须清掉，避免旧主库 + 新 -wal 叠加错乱
t20_old=$(ls -1 "$SB/work/backups" | head -n 1)
rm -f "$SB/work/backups/$t20_old/wing.db-wal"
run_script rollback --to "$SB/work/backups/$t20_old" --with-daed
assert_rc "rollback(无 wal 备份) rc=0" 0 $?
if [ -e "$SB/etc/daed/wing.db-wal" ]; then bad "回滚到无 -wal 备份后残留 -wal"; else ok "回滚后现役 -wal 已清除"; fi

echo ""
echo "=========================================="
echo " 测试结果: $PASS 通过, $FAIL 失败"
echo "=========================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
