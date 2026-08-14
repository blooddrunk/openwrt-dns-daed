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
    cp "$FIX/wing-db.fixture" "$SB/etc/daed/wing.db"

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
    chmod +x "$SB/bin/uci" "$SB/bin/nft" "$SB/bin/netstat" "$SB/bin/nslookup"

    # init.d 替身
    for svc in dnsmasq https-dns-proxy daed; do
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
    : > "$SB/uci.calls"
}

# run_script <子命令及参数...>  —— 返回脚本 rc，stdout 存入 $SB/last.out
run_script() {
    DD_IGNORE_OS=1 DD_IGNORE_ROOT=1 \
    DD_WORK_DIR="$SB/work" DD_INIT_DIR="$SB/initd" DD_CONFIG_DIR="$SB/etc/config" \
    DD_DAED_DB="$SB/etc/daed/wing.db" \
    UCI_STATE="$SB/uci.state" UCI_CALLS="$SB/uci.calls" INITD_LOG="$SB/initd.log" \
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
assert_grep "DNS: DoH 上游" "$DNSN" "https://dns.google/dns-query"
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
DD_DAED_DB="$SB/etc/daed/wing.db" \
UCI_STATE="$SB/uci.state" UCI_CALLS="$SB/uci.calls" INITD_LOG="$SB/initd.log" \
NFT_OUT="$FIX/nft-clean.txt" PATH="$SB/bin:$PATH" \
sh "$SCRIPT" --config "$SB/etc/conf-gen.conf" install > "$SB/last.out" 2>&1
assert_rc "首装 rc=0" 0 $?
assert_file "模板已生成" "$SB/etc/conf-gen.conf"
assert_grep "模板含 NODE_ENDPOINTS" "$SB/etc/conf-gen.conf" "NODE_ENDPOINTS="
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

echo ""
echo "=========================================="
echo " 测试结果: $PASS 通过, $FAIL 失败"
echo "=========================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
