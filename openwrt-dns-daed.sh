#!/bin/sh
# =============================================================================
#  openwrt-daed-dns —— OpenWrt 防 DNS 劫持一键部署脚本
#
#  在可能存在企业网关/运营商 DNS 劫持的网络中，一键建立并验证：
#
#    链路 A（LAN / dnsmasq）:
#      LAN 客户端 ->(53 强制拉回 / 853 拒绝)-> dnsmasq :53
#        -> 127.0.0.1:5053 -> https-dns-proxy -> AliDNS DoH
#
#    链路 B（daed 自身分流 DNS）:
#      geosite:cn -> AliDNS DoH ；其余 -> Google DoH
#
#  本脚本负责：备份、dnsmasq 清理与加固、https-dns-proxy 配置、防火墙核对、
#  daed DNS/Routing 配置片段生成与只读校验、连通性验证、回退、清理，
#  以及可选的整机 IPv6 禁用（DISABLE_IPV6=1，见 README「整机禁用 IPv6」）。
#
#  重要边界：daed 的配置保存在 /etc/daed/wing.db（SQLite），按约定不直接写库。
#  脚本只生成可粘贴进 daed GUI 的片段文件，并对 wing.db 做只读信号检查。
#
#  子命令：
#    install   一键部署/修复（幂等，可重复运行；变更前自动备份）
#    check     只读体检，输出各层 PASS/FAIL/WARN 报告
#    update    自更新脚本并重新应用配置
#    backup    手动备份当前 UCI/daed 状态
#    rollback  回退到最近一次（或指定）备份
#    clean     清理脚本产物（默认保留备份与配置文件）
#    version   显示版本
#    help      帮助
#
#  兼容性：OpenWrt 24.10+（fw4/nftables），busybox ash / dash。
#  依赖：https-dns-proxy（必需）、daed（可选，缺失时仅跳过相关步骤）。
#
#  内部/测试用环境变量（一般无需使用）：
#    DD_IGNORE_OS=1   DD_IGNORE_ROOT=1   DD_WORK_DIR=/path
#    DD_INIT_DIR=/path   DD_CONFIG_DIR=/path   DD_DAED_DB=/path
#    DD_TUN_DEV=/path（TUN 设备路径，默认 /dev/net/tun；测试用）
# =============================================================================
#  Licensed under the MIT License.
# =============================================================================

SCRIPT_NAME="openwrt-dns-daed"
SCRIPT_VERSION="1.2.2"

# -----------------------------------------------------------------------------
# 0. 路径常量（部分可被环境变量覆盖，便于沙箱测试）
# -----------------------------------------------------------------------------
WORK_DIR="${DD_WORK_DIR:-/root/${SCRIPT_NAME}}"
BACKUP_ROOT="${WORK_DIR}/backups"
SNIPPET_DIR="${WORK_DIR}/daed"
CONF_FILE_DEFAULT="/etc/${SCRIPT_NAME}.conf"
EXTRA_DIR_DEFAULT="/etc/${SCRIPT_NAME}.d"
INIT_DIR="${DD_INIT_DIR:-/etc/init.d}"
CONFIG_DIR="${DD_CONFIG_DIR:-/etc/config}"
DAED_WING_DB_DEFAULT="${DD_DAED_DB:-/etc/daed/wing.db}"

# update 自更新默认指向本仓库 main 分支；如需指向其他地址，
# 在 /etc/openwrt-dns-daed.conf 中覆盖 SCRIPT_SELFUPDATE_URL 即可。
SCRIPT_SELFUPDATE_URL_DEFAULT="https://raw.githubusercontent.com/blooddrunk/openwrt-dns-daed/main/openwrt-dns-daed.sh"

# daed（kenzok8/openwrt-daede）官方安装脚本，--install-missing 时使用
DAED_INSTALLER_URL_DEFAULT="https://raw.githubusercontent.com/kenzok8/openwrt-daede/refs/heads/main/scripts/install.sh"

# -----------------------------------------------------------------------------
# 1. 可调配置默认值（可被 /etc/openwrt-dns-daed.conf 覆盖；模板见 conf 内嵌 heredoc）
# -----------------------------------------------------------------------------
LAN_IFACES="lan"
# DoH 上游推荐直接用 IP 形式（AliDNS 证书含 223.5.5.5 的 IP SAN）：
# 域名形式需要先解析 DoH 域名本身，解析链路（dnsmasq→hdp→daed relay）
# 恰好是最容易先失效的一环，会形成 daed DNS ↔ hdp 的循环依赖。
HDP_RESOLVER_URL="https://223.5.5.5/dns-query"
HDP_BOOTSTRAP_DNS="223.5.5.5,223.6.6.6"
HDP_LISTEN_ADDR="127.0.0.1"
HDP_LISTEN_PORT="5053"
DAED_DNS_CN_URL="https://223.5.5.5/dns-query"
DAED_DNS_FALLBACK_URL="https://1.1.1.1/dns-query"
# IPv4-only profile for networks whose proxy nodes do not reliably support IPv6.
# Leave empty to omit the setting and allow daed to return IPv6 answers.
DAED_DNS_IPVERSION_PREFER="4"
DAED_GROUP_PROXY="proxy"
DAED_GROUP_PREMIUM="premium"
# daed global/node-check recommendations. These are rendered into a manual
# checklist only; the script deliberately does not write daed's wing.db.
DAED_BOOTSTRAP_RESOLVER=""
DAED_FALLBACK_RESOLVER="8.8.8.8:53"
DAED_TCP_CHECK_URL="http://cp.cloudflare.com"
DAED_TCP_CHECK_IPV4="1.1.1.1"
DAED_UDP_CHECK_DNS="223.5.5.5:53"
# 节点 endpoint 列表，格式 "IP:协议:端口"（IPv6 也支持，如 2001:db8::1:tcp:443）
# 占位符示例 IP 来自 RFC5737/198.51.100.0/24 测试网段，部署前请改成真实节点
NODE_ENDPOINTS="203.0.113.10:tcp:33973 203.0.113.10:udp:50757 198.51.100.20:tcp:12142 198.51.100.20:udp:51237"
# 内部/私有域名（公司内网域名等），直连；geosite:private 会自动追加
DIRECT_INTERNAL_DOMAINS="example.corp example.lan"
# 固定走 premium 组的 geosite；留空则不生成该规则（geosite:openai 如需启用自行加入）
PREMIUM_GEOSITES="anthropic paypal"
# 需强制走代理组的国内域名（在 geosite:cn 直连规则之前生效）
PROXY_CN_DOMAINS="xiaohongshu.com xhscdn.com xhscdn.net nga.cn 178.com ngabbs.com ngacn.cc xueqiu.com imedao.com"
# 整机禁用 IPv6（可选，默认关闭）。适合上游拿不到 IPv6 PD 前缀、或 IPv6 实际
# 不通的网络：daed 会优先用 v6 拨 DoH 上游，v6 不通会导致国外域名 DNS 间歇性
# SERVFAIL，并连累节点域名解析与代理整体可用性（详见 README「整机禁用 IPv6」）。
# =1 时 install 会停用 WAN/WAN6 的 IPv6、删除 ULA 前缀、关闭 LAN 的 RA/DHCPv6/NDP。
DISABLE_IPV6="0"
# apply_ipv6_disable 检测到实际变更时置 1，用于决定是否 reload network
IPV6_NET_RELOAD=0
TEST_DOMAIN="example.com"
MAX_BACKUPS="8"
DAED_EXTRA_DIR="${EXTRA_DIR_DEFAULT}"

CONF_FILE="${CONF_FILE_DEFAULT}"
SCRIPT_SELFUPDATE_URL="${SCRIPT_SELFUPDATE_URL_DEFAULT}"
DAED_INSTALLER_URL="${DAED_INSTALLER_URL_DEFAULT}"

# -----------------------------------------------------------------------------
# 2. 日志与通用辅助
# -----------------------------------------------------------------------------
NL='
'

if [ -t 1 ]; then
    C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[1;31m'
    C_CYAN='\033[1;36m'; C_BOLD='\033[1m'; C_OFF='\033[0m'
else
    C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_BOLD=''; C_OFF=''
fi

log()   { printf "${C_CYAN}>>${C_OFF} %s\n" "$*"; }
info()  { printf "    %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[警告]${C_OFF} %s\n" "$*" >&2; }
err()   { printf "${C_RED}[错误]${C_OFF} %s\n" "$*" >&2; }
# die <消息> [原因与解决提示]
# 第二个参数会以「原因/解决」前缀另起一行输出，为简短报错补充背景，
# 避免用户面对脚本/底层工具的原始报错无处下手。
die() {
    err "$1"
    [ -n "${2:-}" ] && printf "${C_YELLOW}    原因/解决:${C_OFF} %s\n" "$2" >&2
    exit 1
}
section() { printf "\n${C_BOLD}== %s ==${C_OFF}\n" "$*"; }

# 已知底层错误签名 -> 人话解释。输入为文件路径，按固定字符串匹配，
# 命中一条输出一条（不匹配则静默）。新增报错只需在此追加 case 分支。
explain_known_errors() { # explain_known_errors <file>
    [ -f "$1" ] || return 0
    local text
    text=$(tr -d '\r' < "$1" 2>/dev/null) || return 0
    case "$text" in
        *tun-missing*|*"/dev/net/tun"*|*"net/tun"*)
            info " ↳ 已知问题: daed/dae 缺少 TUN 设备（内核未提供 tun 模块）。"
            info "   解决: opkg update && opkg install kmod-tun 后重启路由器；"
            info "         LXC/Docker 内运行 OpenWrt 时需在宿主机开启 /dev/net/tun" ;;
        *"Operation not permitted"*|*"CAP_NET_ADMIN"*|*"not enough privileges"*|*"no enough privilege"*)
            info " ↳ 已知问题: daed/dae 以非 root 或缺少网络管理特权（CAP_NET_ADMIN）运行。"
            info "   解决: 用 ${INIT_DIR}/daed restart 以服务方式启动（procd 会授予所需特权），"
            info "         不要手动以普通用户运行 daed/dae 二进制" ;;
        *"address already in use"*|*"Address already in use"*)
            info " ↳ 已知问题: 端口已被其他进程占用。"
            info "   解决: netstat -lnptu | grep -E '(:53|:5053|:853)' 找到占用者后停用它" ;;
        *"No space left"*|*"no space left"*)
            info " ↳ 已知问题: Flash/磁盘空间不足。"
            info "   解决: df -h 查看，清理日志或扩容 overlay 后重试" ;;
        *"failed to start"*|*"FATA"*)
            info " ↳ 以上为服务自身日志。查看完整上下文: logread -e daed | tail -n 30" ;;
    esac
    return 0
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_root()  { [ "$(id -u 2>/dev/null)" = "0" ]; }
is_openwrt() { [ -f /etc/openwrt_release ] || [ -d /lib/upgrade ]; }

svc_exists() { [ -e "${INIT_DIR}/$1" ]; }

svc_restart() {
    if [ -x "${INIT_DIR}/$1" ]; then
        # 捕获服务自身输出：成功时保持安静，失败时原样展示并尝试解码已知错误
        local svc_out
        svc_out=$(mktemp 2>/dev/null) || svc_out="/tmp/${SCRIPT_NAME}.svc.$$"
        if "${INIT_DIR}/$1" restart >"$svc_out" 2>&1; then
            log "已重启服务 $1"
        else
            warn "重启服务 $1 失败，服务输出如下（截取）:"
            sed -n '1,15p' "$svc_out" >&2
            explain_known_errors "$svc_out"
            info "手动排查: ${INIT_DIR}/$1 restart 前台运行；logread -e $1 | tail -n 20"
            rm -f "$svc_out"
            return 1
        fi
        rm -f "$svc_out"
    else
        warn "缺少 init 脚本 ${INIT_DIR}/$1，跳过重启"
        return 1
    fi
    return 0
}

fetch_to() { # fetch_to <url> <dest>
    if have_cmd curl; then
        curl -fsSL "$1" -o "$2" 2>/dev/null
    elif have_cmd wget; then
        wget -qO "$2" "$1" 2>/dev/null
    elif have_cmd uclient-fetch; then
        uclient-fetch -q -O "$2" "$1" 2>/dev/null
    else
        return 1
    fi
}

# uci 工具封装：无 uci 环境下安全失败
have_uci() { have_cmd uci; }

# 读取 uci list/option 的所有值（每行一个）。对不存在的 option 返回空。
uci_list_values() {
    uci -q show "$1" 2>/dev/null | sed -e "s/^[^=]*=//" | tr "'" "\n" \
        | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" | grep -v "^$"
}

uci_get_value() {
    uci -q get "$1" 2>/dev/null
}

# 对二进制文件做只读字符串包含检查（替代 grep -a / strings）。
# 注意：不可用 tr 的 '[:print:]' 字符类——busybox tr 不支持（会当成字面字符集，
# 整个检查静默失效）；用八进制可打印 ASCII 范围 \040-\176，GNU/busybox 通吃。
db_contains() { # db_contains <file> <literal-string>
    [ -f "$1" ] || return 1
    tr -c '\040-\176' '\n' < "$1" 2>/dev/null | grep -qF -- "$2"
}

# 取字符串在单个 db 文件文本化内容中最后一次出现的行号（未命中输出空）
db_last_lineno() { # db_last_lineno <file> <literal-string>
    [ -f "$1" ] || return 0
    tr -c '\040-\176' '\n' < "$1" 2>/dev/null | grep -nF -- "$2" | tail -1 | cut -d: -f1
    return 0
}

# wing.db 信号文件列表：主库在前、存在的 -wal 在后。
# SQLite WAL 模式下未 checkpoint 时，最新配置可能只存在于 -wal 中，
# 信号检查必须两份都看，否则会把“已在 GUI 粘贴”误报成“尚未应用”。
daed_db_signal_files() { # daed_db_signal_files <db-path>
    [ -f "$1" ] && printf '%s\n' "$1"
    [ -f "${1}-wal" ] && printf '%s\n' "${1}-wal"
    return 0
}

# wing.db（含 -wal）信号包含检查
wingdb_contains() { # wingdb_contains <db-path> <literal-string>
    local f
    # shellcheck disable=SC2046
    for f in $(daed_db_signal_files "$1"); do
        db_contains "$f" "$2" && return 0
    done
    return 1
}

# 判断 daed DNS 当前是否仍是明文 :53 上游。需区分“当前行”与“历史行”：
#   - -wal 追加写且帧按写入时间排序，文件内靠后的行更新——明文行与 DoH 行
#     谁最后出现谁新；daed 默认配置（udp://223.5.5.5:53 等）的历史帧因此被排除；
#   - 主库 checkpoint 后只保留当前行镜像——-wal 缺失或不含相关信号时，
#     沿用“主库含明文即明文”的判定。
# 两种情形都能正确报 FAIL：从未配置过 DoH（只有明文行），以及粘贴 DoH 后又改回明文。
wingdb_plaintext_upstream() { # wingdb_plaintext_upstream <db-path>
    local db="$1" wal="${1}-wal" pl dh
    if [ -s "$wal" ]; then
        pl=$(db_last_lineno "$wal" "udp://223.5.5.5:53")
        [ -z "$pl" ] && pl=$(db_last_lineno "$wal" "tcp+udp://8.8.8.8:53")
        dh=$(db_last_lineno "$wal" "$DAED_DNS_CN_URL")
        [ -z "$dh" ] && dh=$(db_last_lineno "$wal" "$DAED_DNS_FALLBACK_URL")
        if [ -n "$pl" ] || [ -n "$dh" ]; then
            # -wal 中存在相关信号：以 -wal 内最后出现的先后为准
            [ -n "$pl" ] && { [ -z "$dh" ] || [ "$pl" -gt "$dh" ]; } && return 0
            return 1
        fi
        # 两者皆不在 -wal：落到主库判定
    fi
    db_contains "$db" "udp://223.5.5.5:53" || db_contains "$db" "tcp+udp://8.8.8.8:53"
}

list_has_line() { # list_has_line <multiline-text> <line>  （整行精确匹配）
    printf '%s\n' "$1" | grep -qxF -- "$2"
}

# -----------------------------------------------------------------------------
# 3. 计数器（check / install 验证共用）
# -----------------------------------------------------------------------------
RES_PASS=0; RES_FAIL=0; RES_WARN=0; RES_SKIP=0
RES_FAIL_TEXT=""
res() { # res PASS|FAIL|WARN|SKIP <描述>
    case "$1" in
        PASS) RES_PASS=$((RES_PASS + 1)); tag="${C_GREEN}[ ok ]${C_OFF}" ;;
        FAIL) RES_FAIL=$((RES_FAIL + 1)); tag="${C_RED}[FAIL]${C_OFF}"
              RES_FAIL_TEXT="${RES_FAIL_TEXT}${2}${NL}" ;;
        WARN) RES_WARN=$((RES_WARN + 1)); tag="${C_YELLOW}[warn]${C_OFF}" ;;
        SKIP) RES_SKIP=$((RES_SKIP + 1)); tag="[skip]" ;;
        *) tag="[????]" ;;
    esac
    printf '%s %s\n' "$tag" "$2"
}

summary_line() {
    printf "\n${C_BOLD}结果: %d 通过, %d 失败, %d 警告, %d 跳过${C_OFF}\n" \
        "$RES_PASS" "$RES_FAIL" "$RES_WARN" "$RES_SKIP"
}

# check/install 收尾时的 FAIL 速查：把本轮全部失败描述与已知症状匹配，
# 输出一行式修复命令，避免面对 FAIL 列表还要逐条搜索。
print_fail_hints() {
    [ "$RES_FAIL" -gt 0 ] || return 0
    section "FAIL 修复速查"
    local matched=0
    if printf '%s' "$RES_FAIL_TEXT" | grep -qF "TUN 设备"; then
        info "· TUN 缺失            -> opkg update && opkg install kmod-tun 并重启路由器（LXC/容器需宿主开启 tun）"
        matched=1
    fi
    if printf '%s' "$RES_FAIL_TEXT" | grep -qF "https-dns-proxy 未安装"; then
        info "· hdp 未安装          -> opkg update && opkg install https-dns-proxy（或加 --install-missing 重跑）"
        matched=1
    fi
    if printf '%s' "$RES_FAIL_TEXT" | grep -qE 'noresolv|上游缺少|dns_redirect|明文|实例数|残留|HIJACK|force_dns|resolver_url|listen_port'; then
        info "· UCI/防火墙类不符    -> 直接重跑 install（幂等，会按目标值重写并重启服务）"
        matched=1
    fi
    if printf '%s' "$RES_FAIL_TEXT" | grep -qF "IPv6:"; then
        info "· IPv6 禁用未生效     -> 重跑 install（幂等）；仍失败: uci show network / uci show dhcp 对照 README「整机禁用 IPv6」"
        matched=1
    fi
    if printf '%s' "$RES_FAIL_TEXT" | grep -qF ":53 无监听"; then
        info "· :53 无监听          -> /etc/init.d/dnsmasq restart；仍失败: logread -e dnsmasq | tail -n 20"
        matched=1
    fi
    if printf '%s' "$RES_FAIL_TEXT" | grep -qE '5053 无监听|解析失败'; then
        info "· 5053/解析失败       -> /etc/init.d/https-dns-proxy restart；查日志: logread -e https-dns-proxy | tail -n 20；确认 DoH 上游可达"
        matched=1
    fi
    if printf '%s' "$RES_FAIL_TEXT" | grep -qF "明文 :53 上游"; then
        info "· daed 明文上游       -> 在 daed GUI 用 ${SNIPPET_DIR}/daed-dns.dae 整体替换 DNS 配置"
        matched=1
    fi
    [ "$matched" = "1" ] || info "（无自动匹配项；请逐条按 FAIL 行括号内的提示处理）"
    info "完整排查手册: docs/troubleshooting.md"
    return 0
}

# -----------------------------------------------------------------------------
# 4. 依赖检测
# -----------------------------------------------------------------------------
pkg_manager() { # 输出 opkg / apk / 空
    if have_cmd opkg; then echo opkg
    elif have_cmd apk; then echo apk
    else echo ""
    fi
}

hdp_installed() {
    svc_exists https-dns-proxy || have_cmd https-dns-proxy
}

daed_installed() {
    svc_exists daed || [ -x /usr/bin/daed ] || [ -x /usr/bin/dae ]
}

daed_wing_db() { echo "${DD_DAED_DB:-${DAED_WING_DB_DEFAULT}}"; }

install_missing_packages() {
    section "安装缺失的软件包"
    if hdp_installed; then
        info "https-dns-proxy 已安装"
    else
        pm=$(pkg_manager)
        [ -n "$pm" ] || die "未找到 opkg/apk，请手动安装 https-dns-proxy" \
            "固件可能裁剪了包管理器（自编译/精简版 OpenWrt 常见）。手动安装: 下载 ipk 后 opkg install ./https-dns-proxy*.ipk；或换用官方完整固件"
        log "通过 ${pm} 安装 https-dns-proxy"
        case "$pm" in
            opkg) opkg update && opkg install https-dns-proxy || return 1 ;;
            apk)  apk update && apk add https-dns-proxy || return 1 ;;
        esac
    fi

    if daed_installed; then
        info "daed 已安装"
    else
        log "通过官方安装脚本安装 daed（kenzok8/openwrt-daede）"
        log "安装地址: ${DAED_INSTALLER_URL}"
        tmp=$(mktemp 2>/dev/null) || tmp="${WORK_DIR}/.daed-installer.$$"
        if fetch_to "$DAED_INSTALLER_URL" "$tmp"; then
            sh "$tmp" || warn "daed 官方安装脚本返回非零，请查看其输出"
        else
            warn "下载 daed 安装脚本失败，请参考 ${DAED_INSTALLER_URL} 手动安装"
        fi
        rm -f "$tmp"
        if daed_installed; then
            info "daed 安装成功"
        else
            warn "daed 仍未检测到，将继续部署（daed 相关步骤仅生成配置片段）"
        fi
    fi
}

# -----------------------------------------------------------------------------
# 5. 配置文件
# -----------------------------------------------------------------------------
gen_conf_template() { # gen_conf_template <dest>
    cat > "$1" <<'TMPL'
# ============================================================
# openwrt-dns-daed 配置文件
# 首次运行 install 时自动生成；本文件不会被脚本覆盖，可放心编辑。
# 修改后重新运行 install 即可重新生效（幂等）。
# ============================================================

# ---- LAN / https-dns-proxy ----
# force_dns 生效的接口（通常为 lan；多个用空格分隔）
LAN_IFACES="lan"
# DoH 上游默认 IP 形式（无需解析 DoH 域名，避免依赖 dnsmasq/hdp/daed 链路）；
# 如改回域名形式，bootstrap 才会用于解析 DoH 域名本身
HDP_RESOLVER_URL="https://223.5.5.5/dns-query"
HDP_BOOTSTRAP_DNS="223.5.5.5,223.6.6.6"
HDP_LISTEN_ADDR="127.0.0.1"
HDP_LISTEN_PORT="5053"

# ---- daed DNS（粘贴到 daed GUI 的 DNS 标签页）----
DAED_DNS_CN_URL="https://223.5.5.5/dns-query"
# 1.1.1.1:443 国内直连受干扰，务必保留 Routing 中 dip(1.1.1.1/32...) -> premium 钉住规则
DAED_DNS_FALLBACK_URL="https://1.1.1.1/dns-query"
# 默认只返回 IPv4，适合 VPS 节点 IPv6 不稳定的网络；留空则允许 IPv6
DAED_DNS_IPVERSION_PREFER="4"

# ---- daed 全局/节点检测（仅生成 GUI 设置清单，不直接写 wing.db）----
# 引导解析器留空即可使用 dae 默认值；如需显式指定请使用 IPv4 host:port
DAED_BOOTSTRAP_RESOLVER=""
# 备用解析器只在系统 resolv.conf 不可用时使用，当前为 IPv4
DAED_FALLBACK_RESOLVER="8.8.8.8:53"
# IPv4-only 节点检测配置：不要填写 IPv6 检测地址
DAED_TCP_CHECK_URL="http://cp.cloudflare.com"
DAED_TCP_CHECK_IPV4="1.1.1.1"
DAED_UDP_CHECK_DNS="223.5.5.5:53"

# ---- daed Routing（粘贴到 daed GUI 的 Routing 标签页）----
# 分流组名：必须与你在 daed 中实际创建的 Group 名称一致
DAED_GROUP_PROXY="proxy"
DAED_GROUP_PREMIUM="premium"
# 自建节点 endpoint，格式 "IP:协议:端口"，空格分隔。
# 生成规则形如: dip(IP/32) && l4proto(tcp) && dport(443) -> must_direct
# 注意：只放行节点入口端口，不要对整台 VPS /32 must_direct，
# 否则同机部署的 1Panel/Web 等普通服务也会被强制直连。
# IPv6 写法示例: 2001:db8::1:tcp:443
NODE_ENDPOINTS="203.0.113.10:tcp:443 203.0.113.10:udp:8443"
# 内部/私有域名（公司内网域名等），直连；geosite:private 自动追加，无需手写
DIRECT_INTERNAL_DOMAINS="example.corp"
# 固定走 premium 组的 geosite 名称（不含 "geosite:" 前缀）；留空则不生成该规则
PREMIUM_GEOSITES="anthropic paypal"
# 需强制走代理组的国内域名（位于 geosite:cn 直连规则之前）
PROXY_CN_DOMAINS="xiaohongshu.com nga.cn xueqiu.com"

# ---- 其他 ----
# check 时用于连通性测试的域名
TEST_DOMAIN="example.com"
# 可选：整机禁用 IPv6。适合上游拿不到 IPv6 PD 前缀、或 IPv6 实际不通的网络。
# daed 会优先用 v6 拨 DoH 上游，v6 不通会导致国外域名 DNS 间歇性 SERVFAIL、
# 节点域名解析失败，进而代理整体不可用（详见 README「整机禁用 IPv6」与
# docs/troubleshooting.md 情况 F）。
# =1 时 install 将: network.wan.ipv6=0、network.wan6.proto=none、删除 ULA 前缀、
# dhcp.lan 的 ra/dhcpv6/ndp=disabled，并在有变更时自动 reload network；
# 随后主动清理 LAN/WAN 接口上残留的 ULA/动态 IPv6 地址（实测仅 reload 并不
# 总会移除，而客户端会把 br-lan 上残留的 v6 地址继续当 DNS 服务器使用）。
# 恢复: rollback（network 配置随备份一起还原）。
DISABLE_IPV6="0"
# 备份保留份数（回退时用）
MAX_BACKUPS="8"
# 自定义 Routing 追加片段目录（可选）。目录下若存在
#   dns-extra.dae      -> 追加到 DNS 片段末尾
#   routing-extra.dae  -> 插入到「节点 endpoint 规则」之后
# 文件内容为原始 dae 配置行，适合放额外的 must_direct 等规则。
DAED_EXTRA_DIR="/etc/openwrt-dns-daed.d"

# update 自更新地址（默认已指向官方仓库；如 fork 或需禁用，取消注释并改写下面一行）
# SCRIPT_SELFUPDATE_URL="https://raw.githubusercontent.com/blooddrunk/openwrt-dns-daed/main/openwrt-dns-daed.sh"

# daed 官方安装脚本地址（--install-missing 时使用）
DAED_INSTALLER_URL="https://raw.githubusercontent.com/kenzok8/openwrt-daede/refs/heads/main/scripts/install.sh"
TMPL
}

ensure_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        log "生成配置文件 ${CONF_FILE}（含占位符默认值）"
        gen_conf_template "$CONF_FILE" || die "无法写入 ${CONF_FILE}" \
            "常见原因: /etc 所在分区只读或空间不足。排查: df -h /etc；只读则 mount -o remount,rw /"
        warn "请编辑 ${CONF_FILE}（尤其是 NODE_ENDPOINTS），然后重新运行 install"
    fi
}

load_conf() {
    # shellcheck disable=SC1090
    [ -f "$CONF_FILE" ] && . "$CONF_FILE"
    [ -n "$LAN_IFACES" ]     || LAN_IFACES="lan"
    [ -n "$HDP_LISTEN_PORT" ] || HDP_LISTEN_PORT="5053"
    [ "$DISABLE_IPV6" = "1" ] || DISABLE_IPV6="0"
    return 0
}

# -----------------------------------------------------------------------------
# 6. 备份与回退
# -----------------------------------------------------------------------------
rotate_backups() {
    count=$(ls -1 "$BACKUP_ROOT" 2>/dev/null | grep -cE '^[0-9]{8}-[0-9]{6}$')
    while [ "$count" -gt "${MAX_BACKUPS:-8}" ]; do
        oldest=$(ls -1 "$BACKUP_ROOT" | grep -E '^[0-9]{8}-[0-9]{6}$' | head -n 1)
        [ -n "$oldest" ] || break
        rm -rf "${BACKUP_ROOT}/${oldest}"
        count=$((count - 1))
    done
}

do_backup() { # do_backup <原因>
    ts=$(date +%Y%m%d-%H%M%S)
    dir="${BACKUP_ROOT}/${ts}"
    mkdir -p "$dir" || return 1
    have_uci && uci export dhcp > "${dir}/dhcp.uci" 2>/dev/null
    if [ -f "${CONFIG_DIR}/https-dns-proxy" ] && have_uci; then
        uci export https-dns-proxy > "${dir}/https-dns-proxy.uci" 2>/dev/null
    fi
    if [ -f "${CONFIG_DIR}/network" ] && have_uci; then
        uci export network > "${dir}/network.uci" 2>/dev/null
    fi
    [ -f "${CONFIG_DIR}/dhcp" ] && cp "${CONFIG_DIR}/dhcp" "${dir}/dhcp.raw"
    [ -f "${CONFIG_DIR}/https-dns-proxy" ] && \
        cp "${CONFIG_DIR}/https-dns-proxy" "${dir}/https-dns-proxy.raw"
    [ -f "${CONFIG_DIR}/network" ] && \
        cp "${CONFIG_DIR}/network" "${dir}/network.raw"
    db=$(daed_wing_db)
    if [ -f "$db" ]; then
        if cp "$db" "${dir}/wing.db" 2>/dev/null; then
            info "已备份 daed 数据库（运行中复制，仅作兜底；重要配置请用 GUI 导出）"
        fi
        # WAL 未 checkpoint 时最新配置只存在于 -wal 中，一并备份才能完整恢复
        #（-shm 是可重建的索引，无需备份）
        [ -f "${db}-wal" ] && cp "${db}-wal" "${dir}/wing.db-wal" 2>/dev/null
    fi
    have_cmd nft && nft list ruleset > "${dir}/nft.ruleset" 2>/dev/null
    {
        echo "reason=$1"
        echo "version=${SCRIPT_VERSION}"
        echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
    } > "${dir}/info.txt"
    log "已创建备份: ${dir}（原因: $1）"
    rotate_backups
}

latest_backup_dir() {
    d=$(ls -1 "$BACKUP_ROOT" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | tail -n 1)
    [ -n "$d" ] && echo "${BACKUP_ROOT}/${d}"
    return 0
}

# -----------------------------------------------------------------------------
# 7. 应用配置：dnsmasq / https-dns-proxy
# -----------------------------------------------------------------------------
apply_dnsmasq() {
    section "配置 dnsmasq"
    have_uci || die "未找到 uci 命令，无法配置 dnsmasq"
    uci -q show dhcp.@dnsmasq[0] >/dev/null 2>&1 || \
        die "未找到 dhcp.@dnsmasq[0] 配置节" \
            "dnsmasq 未安装，或 /etc/config/dhcp 缺失/损坏。修复: opkg install dnsmasq；若文件为空可从 /etc/config/dhcp 的 rom 副本恢复（/rom/etc/config/dhcp）"

    local want_server="127.0.0.1#${HDP_LISTEN_PORT}"
    local srv="" doh="" dohb="" need_add=1
    srv=$(uci_list_values "dhcp.@dnsmasq[0].server")
    doh=$(uci_list_values "dhcp.@dnsmasq[0].doh_server")
    dohb=$(uci_list_values "dhcp.@dnsmasq[0].doh_backup_server")
    list_has_line "$srv" "$want_server" && need_add=0

    log "设置 noresolv=1（忽略 WAN 下发的明文 DNS 上游）"
    uci set dhcp.@dnsmasq[0].noresolv='1'

    log "关闭 dnsmasq 自带的 DNSMASQ HIJACK（DNS 强制接管只由 https-dns-proxy 负责）"
    uci set dhcp.@dnsmasq[0].dns_redirect='0'

    log "清理失效/明文上游（历史 5054/5055 残留、明文 IP 上游等）"
    local opt e entries
    for opt in server doh_server doh_backup_server; do
        case "$opt" in
            server) entries="$srv" ;;
            doh_server) entries="$doh" ;;
            *) entries="$dohb" ;;
        esac
        [ -n "$entries" ] || continue
        for e in $entries; do
            case "$e" in
                "$want_server") : ;;
                127.0.0.1#*)
                    uci -q del_list "dhcp.@dnsmasq[0].${opt}=${e}"
                    info "已移除 ${opt} 失效条目: ${e}" ;;
                */*)
                    : ;; # 域限定条目（如 canary），由 https-dns-proxy 管理，保留
                *:*)
                    if [ "$opt" = "server" ]; then
                        uci -q del_list "dhcp.@dnsmasq[0].server=${e}"
                        warn "已移除明文 IPv6/特殊 server=${e}（会绕过 DoH 链路）"
                    else
                        warn "保留 ${opt} 条目 ${e}（疑似 IPv6/特殊写法，请人工确认）"
                    fi ;;
                *.*)
                    if [ "$opt" = "server" ]; then
                        uci -q del_list "dhcp.@dnsmasq[0].server=${e}"
                        warn "已移除明文上游 server=${e}（会绕过 DoH 链路）"
                    else
                        warn "保留 ${opt} 条目 ${e}，请人工确认"
                    fi ;;
                *)
                    warn "保留无法识别的 ${opt} 条目: ${e}" ;;
            esac
        done
    done

    if [ "$need_add" = "1" ]; then
        log "添加唯一普通上游: server=${want_server}"
        uci add_list "dhcp.@dnsmasq[0].server=${want_server}"
    else
        info "上游 ${want_server} 已存在，无需重复添加"
    fi

    uci commit dhcp
    log "dnsmasq 配置已提交"
}

apply_hdp() {
    section "配置 https-dns-proxy"
    have_uci || die "未找到 uci 命令，无法配置 https-dns-proxy"
    [ -f "${CONFIG_DIR}/https-dns-proxy" ] || \
        die "未找到 ${CONFIG_DIR}/https-dns-proxy，请确认 https-dns-proxy 已安装"

    # 确保 main 配置节存在
    uci -q get https-dns-proxy.config >/dev/null 2>&1 || \
        uci set https-dns-proxy.config=main

    # 实例唯一化：只保留一个 @https-dns-proxy 实例
    n=$(uci -q show https-dns-proxy 2>/dev/null | grep -cE "=https-dns-proxy$")
    if [ "${n:-0}" -eq 0 ]; then
        log "创建 https-dns-proxy 实例"
        uci add https-dns-proxy https-dns-proxy
        n=1
    fi
    if [ "$n" -gt 1 ]; then
        warn "检测到 ${n} 个实例，仅保留第一个（历史多实例 5054/5055 已废弃）"
        while [ "$n" -gt 1 ]; do
            uci -q delete https-dns-proxy.@https-dns-proxy[-1]
            n=$((n - 1))
        done
    fi

    log "写入 main 节配置"
    uci -q delete https-dns-proxy.config.notrack_dns 2>/dev/null
    uci set https-dns-proxy.config.canary_domains_icloud='1'
    uci set https-dns-proxy.config.canary_domains_mozilla='1'
    uci set https-dns-proxy.config.dnsmasq_config_update='*'
    uci set https-dns-proxy.config.force_dns='1'
    uci set https-dns-proxy.config.procd_trigger_wan6='0'
    uci set https-dns-proxy.config.heartbeat_domain='heartbeat.mossdef.org'
    uci set https-dns-proxy.config.heartbeat_sleep_timeout='10'
    uci set https-dns-proxy.config.heartbeat_wait_timeout='10'
    uci set https-dns-proxy.config.user='nobody'
    uci set https-dns-proxy.config.group='nogroup'
    uci set https-dns-proxy.config.listen_addr="${HDP_LISTEN_ADDR}"

    uci -q delete https-dns-proxy.config.force_dns_port 2>/dev/null
    uci add_list https-dns-proxy.config.force_dns_port='53'
    uci add_list https-dns-proxy.config.force_dns_port='853'

    uci -q delete https-dns-proxy.config.force_dns_src_interface 2>/dev/null
    local ifc
    for ifc in $LAN_IFACES; do
        uci add_list https-dns-proxy.config.force_dns_src_interface="$ifc"
    done

    log "写入实例[0]配置（单实例: ${HDP_LISTEN_ADDR}:${HDP_LISTEN_PORT} -> ${HDP_RESOLVER_URL}）"
    uci set https-dns-proxy.@https-dns-proxy[0].resolver_url="${HDP_RESOLVER_URL}"
    uci set https-dns-proxy.@https-dns-proxy[0].bootstrap_dns="${HDP_BOOTSTRAP_DNS}"
    uci set https-dns-proxy.@https-dns-proxy[0].listen_port="${HDP_LISTEN_PORT}"

    uci commit https-dns-proxy
    log "https-dns-proxy 配置已提交"
}

apply_ipv6_disable() { # DISABLE_IPV6=1 时禁用整机 IPv6（WAN 获取、ULA、LAN RA/DHCPv6/NDP）
    section "禁用整机 IPv6（DISABLE_IPV6=1）"
    have_uci || die "未找到 uci 命令，无法禁用 IPv6"
    IPV6_NET_RELOAD=0

    # WAN：v4 接口（dhcp/pppoe 等）不再获取 IPv6
    if uci -q show network.wan >/dev/null 2>&1; then
        if [ "$(uci_get_value network.wan.ipv6)" != "0" ]; then
            log "停用 network.wan 的 IPv6（ipv6=0）"
            uci set network.wan.ipv6='0'
            IPV6_NET_RELOAD=1
        else
            info "network.wan.ipv6 已为 0"
        fi
    else
        warn "未找到 network.wan，跳过 WAN IPv6 停用（自定义 WAN 接口名请手动处理）"
    fi

    # WAN6：独立 v6 接口置为 none（原配置可经 rollback 还原）
    if uci -q show network.wan6 >/dev/null 2>&1; then
        if [ "$(uci_get_value network.wan6.proto)" != "none" ]; then
            log "停用 network.wan6（proto=none）"
            uci set network.wan6.proto='none'
            IPV6_NET_RELOAD=1
        else
            info "network.wan6.proto 已为 none"
        fi
    else
        info "无 network.wan6 接口，跳过"
    fi

    # ULA：删除全局 ULA 前缀（br-lan 不再持有 IPv6 地址/RDNSS）
    if [ -n "$(uci_get_value network.globals.ula_prefix)" ]; then
        log "删除 network.globals.ula_prefix"
        uci -q delete network.globals.ula_prefix
        IPV6_NET_RELOAD=1
    else
        info "ULA 前缀未设置"
    fi

    # LAN：关闭 RA / DHCPv6 / NDP（客户端不再获得 IPv6 地址与 RDNSS）
    local ifc opt
    for ifc in $LAN_IFACES; do
        if ! uci -q show "dhcp.${ifc}" >/dev/null 2>&1; then
            warn "未找到 dhcp.${ifc}，跳过该接口的 RA/DHCPv6/NDP 关闭"
            continue
        fi
        for opt in ra dhcpv6 ndp; do
            if [ "$(uci_get_value "dhcp.${ifc}.${opt}")" != "disabled" ]; then
                uci set "dhcp.${ifc}.${opt}=disabled"
                IPV6_NET_RELOAD=1
            fi
        done
        log "已确保 dhcp.${ifc} 的 ra/dhcpv6/ndp=disabled"
    done

    uci commit network
    uci commit dhcp
    if [ "$IPV6_NET_RELOAD" = "1" ]; then
        info "IPv6 相关配置有变更，稍后将重载 network 并重启 odhcpd"
    else
        info "IPv6 禁用配置均已就位，无需重载 network"
    fi
    info "随后将检查并清理接口上残留的 IPv6 地址（如有）"
}

reload_network_stack() { # 应用网络层配置变更（IPv6 禁用 / rollback 还原 network 时使用）
    if [ -x "${INIT_DIR}/network" ]; then
        if "${INIT_DIR}/network" reload >/dev/null 2>&1; then
            log "已重载网络服务（network reload）"
        else
            warn "network reload 返回非零，请手动执行 ${INIT_DIR}/network reload 查看输出"
        fi
    else
        warn "缺少 init 脚本 network，跳过网络重载（请手动 ${INIT_DIR}/network reload）"
    fi
    if [ -x "${INIT_DIR}/odhcpd" ]; then
        svc_restart odhcpd || true
    fi
    return 0
}

# DISABLE_IPV6=1 时关心的网络设备：LAN_IFACES 与 wan/wan6 各自的 device
#（旧式 type=bridge 且无 device 选项的配置，运行时设备名为 br-<iface>）。
# 只输出 UCI 中实际存在的接口，去重；不涉及 tailscale0 等非本脚本管理的设备。
ipv6_iface_devices() {
    local ifc dev devs=""
    for ifc in $LAN_IFACES wan wan6; do
        uci -q show "network.${ifc}" >/dev/null 2>&1 || continue
        dev=$(uci_get_value "network.${ifc}.device")
        if [ -z "$dev" ]; then
            [ "$(uci_get_value "network.${ifc}.type")" = "bridge" ] && dev="br-${ifc}" || dev="$ifc"
        fi
        case " $devs " in *" $dev "*) ;; *) devs="$devs $dev" ;; esac
    done
    [ -n "$devs" ] || return 0
    # shellcheck disable=SC2086
    printf '%s\n' $devs
}

# 枚举上述设备上 global 域的 IPv6 地址（ULA fc00::/7 与全球单播均显示为
# scope global），每行输出 "<dev> <addr>"。link-local（fe80::/10）不在其列。
list_stale_ipv6_addrs() {
    have_cmd ip || return 0
    local dev addrs a
    for dev in $(ipv6_iface_devices); do
        addrs=$(ip -6 addr show dev "$dev" 2>/dev/null \
                | sed -n 's/^ *inet6 \([^ ]*\) .*scope global.*/\1/p')
        for a in $addrs; do
            printf '%s %s\n' "$dev" "$a"
        done
    done
    return 0
}

flush_stale_ipv6_addrs() { # DISABLE_IPV6=1 时清除 LAN/WAN 设备上残留的 IPv6 地址
    have_uci || { warn "无 uci 命令，跳过残留 IPv6 地址清理"; return 0; }
    if ! have_cmd ip; then
        warn "无 ip 命令，无法清理残留 IPv6 地址（重启路由器可达到同等效果）"
        return 0
    fi
    local out dev a
    out=$(list_stale_ipv6_addrs)
    if [ -z "$out" ]; then
        info "LAN/WAN 接口上无残留的 global 域 IPv6 地址"
    else
        # reload network 并不总会移除已分配的 ULA/动态地址（实测 br-lan 上可长期
        # 残留为 deprecated，客户端会把 br-lan 的 v6 地址继续当 DNS 服务器使用）
        printf '%s\n' "$out" | while read -r dev a; do
            if ip -6 addr del "$a" dev "$dev" 2>/dev/null; then
                log "已移除 ${dev} 上的残留 IPv6 地址: ${a}"
            else
                warn "移除 ${dev} 上的 ${a} 失败（可能已被内核回收）"
            fi
        done
    fi
    info "客户端已缓存的 ULA/RDNSS 最长约 30 分钟自然老化，重连 Wi-Fi/网线可立即清除"
    return 0
}

# -----------------------------------------------------------------------------
# 8. daed：配置片段生成 + 只读校验（绝不写入 wing.db）
# -----------------------------------------------------------------------------
join_suffix_domains() { # join_suffix_domains "d1 d2" -> "suffix: d1, suffix: d2"
    local out="" d
    for d in $1; do
        if [ -z "$out" ]; then out="suffix: ${d}"; else out="${out}, suffix: ${d}"; fi
    done
    echo "$out"
}

join_geosites() { # join_geosites "a b" -> "geosite:a, geosite:b"
    local out="" g
    for g in $1; do
        if [ -z "$out" ]; then out="geosite:${g}"; else out="${out}, geosite:${g}"; fi
    done
    echo "$out"
}

gen_daed_snippets() {
    section "生成 daed 配置片段（粘贴进 GUI，不直接写库）"
    mkdir -p "$SNIPPET_DIR" || return 1

    # ---- DNS 片段 ----
    local daed_dns_ipversion_line
    if [ -n "$DAED_DNS_IPVERSION_PREFER" ]; then
        daed_dns_ipversion_line="    ipversion_prefer: ${DAED_DNS_IPVERSION_PREFER}${NL}"
    else
        daed_dns_ipversion_line=""
    fi
    if [ -f "${DAED_EXTRA_DIR}/dns-extra.dae" ]; then
        dns_extra=$(cat "${DAED_EXTRA_DIR}/dns-extra.dae")
    else
        dns_extra=""
    fi
    cat > "${SNIPPET_DIR}/daed-dns.dae" <<EOF
# ============================================================
# 由 ${SCRIPT_NAME} v${SCRIPT_VERSION} 生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 用法: daed GUI -> 配置 -> DNS 标签页，整体替换为以下内容后保存
# 目标: 中国域名走 AliDNS DoH，其余走 Cloudflare DoH（全部加密、IP 直连，无 :53 明文）
# IP 版本偏好: ${DAED_DNS_IPVERSION_PREFER:-未设置（允许 IPv6）}
# 注意: 上游为 IP 形式时无需解析 DoH 域名；fallback(1.1.1.1) 需配合
#       Routing 中 dip(...) -> premium 钉住规则从节点出口，直连国内会被干扰
# ============================================================
dns {
${daed_dns_ipversion_line}    upstream {
        alidns: '${DAED_DNS_CN_URL}'
        cloudflaredns: '${DAED_DNS_FALLBACK_URL}'
    }

    routing {
        request {
            qname(geosite:cn) -> alidns
            fallback: cloudflaredns
        }
    }
}
${dns_extra}
EOF

    # ---- Routing 片段 ----
    ep_rules=""
    local ep port t proto ip mask
    for ep in $NODE_ENDPOINTS; do
        port=${ep##*:}
        t=${ep%:*}
        proto=${t##*:}
        ip=${t%:*}
        case "$port" in
            ''|*[!0-9]*) warn "忽略格式错误的 endpoint（端口非数字）: ${ep}"; continue ;;
        esac
        case "$proto" in
            tcp|udp) : ;;
            *) warn "忽略格式错误的 endpoint（协议须为 tcp/udp）: ${ep}"; continue ;;
        esac
        case "$ip" in
            *:*) mask="/128" ;;
            *.*) mask="/32" ;;
            *) warn "忽略格式错误的 endpoint（IP 无效）: ${ep}"; continue ;;
        esac
        ep_rules="${ep_rules}    dip(${ip}${mask}) && l4proto(${proto}) && dport(${port}) -> must_direct${NL}"
    done
    [ -n "$ep_rules" ] || warn "NODE_ENDPOINTS 为空或全部无效，节点 endpoint 规则将为空"

    internal_line=$(join_suffix_domains "$DIRECT_INTERNAL_DOMAINS")
    [ -n "$internal_line" ] && internal_line="${internal_line}, geosite:private" \
                           || internal_line="geosite:private"

    premium_line=$(join_geosites "$PREMIUM_GEOSITES")
    proxy_cn_line=$(join_suffix_domains "$PROXY_CN_DOMAINS")

    if [ -f "${DAED_EXTRA_DIR}/routing-extra.dae" ]; then
        routing_extra=$(cat "${DAED_EXTRA_DIR}/routing-extra.dae")
    else
        routing_extra=""
    fi

    {
        cat <<EOF
# ============================================================
# 由 ${SCRIPT_NAME} v${SCRIPT_VERSION} 生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 用法: daed GUI -> 配置 -> Routing 标签页，整体替换为以下内容后保存
#
# 规则优先级（顺序不可乱）:
#   1. 本机 DNS 进程 must_direct（防 daed 劫持自身形成回环）
#   2. 节点 endpoint 精确 must_direct（IP+协议+端口，勿整台 VPS /32）
#   3. 私网/组播/内部域名直连
#   4. premium 特例  5. 强制代理特例  6. 中国大陆直连  7. fallback 代理
#
# 注意: 组名 ${DAED_GROUP_PROXY}/${DAED_GROUP_PREMIUM} 必须与 daed 中
#       实际创建的 Group 一致，改名后请同步修改配置文件并重新生成。
# ============================================================
routing {
    # 路由器本机 DNS 相关进程必须直连，防止 DNS 流量再次被 dae 接管形成回环
    pname(
        dnsmasq,
        https-dns-proxy
    ) -> must_direct
EOF
        # 节点 endpoint 精确放行（从 NODE_ENDPOINTS 生成）
        if [ -n "$ep_rules" ]; then
            echo ""
            echo "    # 自建代理节点入口精确直连（只匹配目标 IP + 协议 + 端口，"
            echo "    # 不要整台 VPS /32 must_direct，否则同机的 1Panel/Web 等服务也会被强制直连）"
            printf '%s' "$ep_rules"
        fi
        # 用户追加片段
        if [ -n "$routing_extra" ]; then
            echo ""
            echo "    # ---- 以下为自定义追加规则（${DAED_EXTRA_DIR}/routing-extra.dae）----"
            printf '%s\n' "$routing_extra"
        fi
        cat <<EOF

    # IPv4 组播/广播、IPv6 组播直连
    dip(
        224.0.0.0/3,
        255.255.255.255/32,
        'ff00::/8'
    ) -> direct

    # 内部/私有域名直连
    domain(
        ${internal_line}
    ) -> direct

    # 私有 IP 直连
    dip(geoip:private) -> direct
EOF
        # premium 特例（需位于 CN 规则之前）
        if [ -n "$premium_line" ]; then
            cat <<EOF

    # 固定走 ${DAED_GROUP_PREMIUM} 组（位于中国大陆规则与 fallback 之前）
    domain(
        ${premium_line}
    ) -> ${DAED_GROUP_PREMIUM}
EOF
        fi
        # 强制代理特例（需位于 CN 规则之前）
        if [ -n "$proxy_cn_line" ]; then
            cat <<EOF

    # 指定国内站点强制走 ${DAED_GROUP_PROXY}（必须位于 geosite:cn 之前）
    domain(
        ${proxy_cn_line}
    ) -> ${DAED_GROUP_PROXY}
EOF
        fi
        cat <<EOF

    # 中国大陆域名 / IP 直连
    domain(geosite:cn) -> direct
    dip(geoip:cn) -> direct

    # 其余未匹配流量走代理组
    fallback: ${DAED_GROUP_PROXY}
}
EOF
    } > "${SNIPPET_DIR}/daed-routing.dae"

    log "已生成 daed DNS 片段:     ${SNIPPET_DIR}/daed-dns.dae"
    log "已生成 daed Routing 片段: ${SNIPPET_DIR}/daed-routing.dae"
}

gen_daed_global_guide() {
    section "生成 daed 全局/节点检测设置清单（GUI 手动填写）"
    mkdir -p "$SNIPPET_DIR" || return 1

    local bootstrap_display
    if [ -n "$DAED_BOOTSTRAP_RESOLVER" ]; then
        bootstrap_display="$DAED_BOOTSTRAP_RESOLVER"
    else
        bootstrap_display="留空（使用 dae 默认引导解析器）"
    fi

    cat > "${SNIPPET_DIR}/daed-global-settings.txt" <<EOF
# ============================================================
# 由 ${SCRIPT_NAME} v${SCRIPT_VERSION} 生成于 $(date '+%Y-%m-%d %H:%M:%S')
# daed 全局/节点连通性检测推荐设置
#
# 本文件是 GUI 填写清单，不是可单独粘贴的完整 dae 配置；
# 本脚本不会直接写入 /etc/daed/wing.db。
# ============================================================

[全局 -> DNS 解析器]
引导解析器: ${bootstrap_display}
备用解析器: ${DAED_FALLBACK_RESOLVER:-留空（使用 dae 默认备用解析器）}

[全局 -> 节点连通性检测]
TCP 检测链接: ${DAED_TCP_CHECK_URL}
TCP 检测 IPv4: ${DAED_TCP_CHECK_IPV4}
TCP 检测 IPv6: 不配置（IPv4-only profile）
TCP 检测 HTTP 方法: HEAD

UDP 检测 DNS: ${DAED_UDP_CHECK_DNS}
UDP 检测 IPv6: 不配置（IPv4-only profile）

[DNS 配置]
ipversion_prefer: ${DAED_DNS_IPVERSION_PREFER:-未启用（允许 IPv6）}

说明:
- 节点检测 DNS 只用于检测节点到 DNS 目标的连通性，不是 LAN 客户端的日常 DNS。
- 若以后启用 IPv6，应同时恢复 TCP/UDP IPv6 检测地址，并重新评估节点 IPv6 路径。
EOF
    log "已生成 daed 全局设置清单: ${SNIPPET_DIR}/daed-global-settings.txt"
}

daed_readonly_check() {
    section "daed 状态信号（只读检查 wing.db 及 -wal，以 GUI 实际配置为准）"
    local db
    db=$(daed_wing_db)
    if ! daed_installed; then
        warn "未检测到 daed，跳过（相关片段仍已生成，装好 daed 后粘贴即可）"
        return 0
    fi
    # tun-missing 预检：daed 依赖 TUN 设备，缺失时启动即报
    # 「blocked preconditions: tun-missing」。提前在这里给出可操作的修复提示。
    tun_dev="${DD_TUN_DEV:-/dev/net/tun}"
    if [ -e "$tun_dev" ]; then
        res PASS "TUN 设备 ${tun_dev} 存在（daed 启动前提）"
    else
        res FAIL "TUN 设备 ${tun_dev} 不存在（daed 启动会报 blocked preconditions: tun-missing）"
        info "    ↳ 修复: opkg update && opkg install kmod-tun，然后重启路由器"
        info "      LXC/Docker 内运行 OpenWrt 时，需在宿主机开启 /dev/net/tun"
    fi
    if [ ! -f "$db" ]; then
        warn "未找到 ${db}（daed 尚未初始化），请在 GUI 中完成首次配置"
        return 0
    fi
    if wingdb_plaintext_upstream "$db"; then
        res FAIL "daed DNS 疑似仍是明文 :53 上游（在 GUI 中替换为 DoH 片段）"
    fi
    if wingdb_contains "$db" "$DAED_DNS_CN_URL" && wingdb_contains "$db" "$DAED_DNS_FALLBACK_URL"; then
        res PASS "daed DNS 已包含两个 DoH 上游信号"
    else
        res WARN "wing.db 中未同时发现两个 DoH 上游（若已在 GUI 粘贴可忽略，旧数据可能残留）"
    fi
    if [ -n "$DAED_DNS_IPVERSION_PREFER" ]; then
        if wingdb_contains "$db" "ipversion_prefer: ${DAED_DNS_IPVERSION_PREFER}"; then
            res PASS "daed DNS 已包含 ipversion_prefer: ${DAED_DNS_IPVERSION_PREFER} 信号"
        else
            res WARN "wing.db 未见 ipversion_prefer: ${DAED_DNS_IPVERSION_PREFER}（请确认 DNS 片段已重新粘贴）"
        fi
    fi
    if wingdb_contains "$db" "must_direct"; then
        res PASS "wing.db 中存在 must_direct 规则信号"
        local ep t ip ok=1
        for ep in $NODE_ENDPOINTS; do
            t=${ep%:*}; ip=${t%:*}
            wingdb_contains "$db" "$ip" || { ok=0; warn "wing.db 未见 endpoint IP: ${ip}"; }
        done
        [ "$ok" = "1" ] && res PASS "全部节点 endpoint IP 均有信号" \
                       || res WARN "部分节点 endpoint IP 未见信号（确认 Routing 已粘贴）"
    else
        res WARN "wing.db 未见 must_direct 信号（Routing 可能尚未应用）"
    fi
}

# -----------------------------------------------------------------------------
# 9. 验证（install 与 check 共用）
# -----------------------------------------------------------------------------
verify_dnsmasq_uci() {
    if ! have_uci; then res SKIP "无 uci，跳过 dnsmasq UCI 检查"; return 0; fi
    v=$(uci_get_value dhcp.@dnsmasq[0].noresolv)
    [ "$v" = "1" ] && res PASS "dnsmasq noresolv=1" || res FAIL "dnsmasq noresolv!=1（当前: ${v:-未设置}）"

    local want="127.0.0.1#${HDP_LISTEN_PORT}"
    srv=$(uci_list_values "dhcp.@dnsmasq[0].server")
    if list_has_line "$srv" "$want"; then
        res PASS "dnsmasq 上游包含 ${want}"
    else
        res FAIL "dnsmasq 上游缺少 ${want}"
    fi
    stale=$(printf '%s\n' "$srv" | grep -E '^127\.0\.0\.1#[0-9]+$' | grep -vxF "$want" || true)
    [ -z "$stale" ] && res PASS "无失效的 127.0.0.1#50xx 残留" \
                   || res FAIL "存在失效环回上游: $(printf '%s ' $stale)"
    plain=$(printf '%s\n' "$srv" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
    [ -z "$plain" ] && res PASS "server 列表无明文 IP 上游" \
                   || res FAIL "server 列表存在明文 IP 上游: $(printf '%s ' $plain)"
    ipv6_plain=""
    for e in $srv; do
        case "$e" in
            "$want"|*/*) : ;;
            *:*) ipv6_plain="${ipv6_plain}${e} " ;;
        esac
    done
    [ -z "$ipv6_plain" ] && res PASS "server 列表无明文 IPv6 上游" \
                         || res FAIL "server 列表存在明文 IPv6 上游: ${ipv6_plain}"

    v=$(uci_get_value dhcp.@dnsmasq[0].dns_redirect)
    [ "$v" = "0" ] && res PASS "dns_redirect=0（无 DNSMASQ HIJACK 重复劫持）" \
                  || res FAIL "dns_redirect=${v:-未设置}（应为 0，避免与 https-dns-proxy 重复劫持）"
}

verify_dnsmasq_runtime() {
    if ! ls /tmp/etc/dnsmasq.conf.* >/dev/null 2>&1; then
        res SKIP "未发现 /tmp/etc/dnsmasq.conf.*（服务未运行或刚重启，稍后重查）"
        return 0
    fi
    out=$(grep -RnsE '^(server=|no-resolv|resolv-file=|all-servers)' /tmp/etc/dnsmasq.conf.* 2>/dev/null || true)
    if printf '%s\n' "$out" | grep -q '^.*:no-resolv$'; then
        res PASS "运行态存在 no-resolv"
    else
        res FAIL "运行态缺少 no-resolv"
    fi
    bad=$(printf '%s\n' "$out" | grep -E '127\.0\.0\.1#(5054|5055)' || true)
    [ -z "$bad" ] && res PASS "运行态无 5054/5055 残留" \
                   || res FAIL "运行态存在 5054/5055: $(printf '%s ' $bad)"
}

verify_hdp_uci() {
    if ! hdp_installed; then res FAIL "https-dns-proxy 未安装"; return 0; fi
    if ! have_uci; then res SKIP "无 uci，跳过 https-dns-proxy UCI 检查"; return 0; fi
    n=$(uci -q show https-dns-proxy 2>/dev/null | grep -cE "=https-dns-proxy$")
    [ "$n" = "1" ] && res PASS "https-dns-proxy 仅一个实例" \
                  || res FAIL "https-dns-proxy 实例数为 ${n}（应为 1）"
    uci -q get https-dns-proxy.config.notrack_dns >/dev/null 2>&1 && \
        res WARN "存在 notrack_dns 选项（建议删除）" || \
        res PASS "未设置 notrack_dns"

    local pairs="force_dns=1 canary_domains_icloud=1 canary_domains_mozilla=1 dnsmasq_config_update=* listen_addr=${HDP_LISTEN_ADDR} user=nobody group=nogroup procd_trigger_wan6=0 heartbeat_domain=heartbeat.mossdef.org heartbeat_sleep_timeout=10 heartbeat_wait_timeout=10"
    local p k want v
    set -f # 防止 pairs 中的 * 被路径展开
    for p in $pairs; do
        k=${p%%=*}; want=${p#*=}
        v=$(uci_get_value "https-dns-proxy.config.${k}")
        [ "$v" = "$want" ] && res PASS "config.${k}=${want}" \
                         || res FAIL "config.${k}=${v:-未设置}（应为 ${want}）"
    done
    set +f
    ports=$(uci_list_values "https-dns-proxy.config.force_dns_port" | tr '\n' ' ' | sed 's/ $//')
    [ "$ports" = "53 853" ] && res PASS "force_dns_port=53 853" \
                          || res FAIL "force_dns_port=${ports:-未设置}（应为 53 853）"
    local ifc okif=1
    for ifc in $LAN_IFACES; do
        uci_list_values "https-dns-proxy.config.force_dns_src_interface" | grep -qxF "$ifc" || okif=0
    done
    [ "$okif" = "1" ] && res PASS "force_dns_src_interface 包含 ${LAN_IFACES}" \
                    || res FAIL "force_dns_src_interface 缺少接口（期望含 ${LAN_IFACES}）"

    v=$(uci_get_value https-dns-proxy.@https-dns-proxy[0].resolver_url)
    [ "$v" = "$HDP_RESOLVER_URL" ] && res PASS "resolver_url=${HDP_RESOLVER_URL}" \
                                 || res FAIL "resolver_url=${v:-未设置}（应为 ${HDP_RESOLVER_URL}）"
    v=$(uci_get_value https-dns-proxy.@https-dns-proxy[0].bootstrap_dns)
    [ "$v" = "$HDP_BOOTSTRAP_DNS" ] && res PASS "bootstrap_dns=${HDP_BOOTSTRAP_DNS}" \
                                  || res FAIL "bootstrap_dns=${v:-未设置}（应为 ${HDP_BOOTSTRAP_DNS}）"
    v=$(uci_get_value https-dns-proxy.@https-dns-proxy[0].listen_port)
    [ "$v" = "$HDP_LISTEN_PORT" ] && res PASS "listen_port=${HDP_LISTEN_PORT}" \
                                || res FAIL "listen_port=${v:-未设置}（应为 ${HDP_LISTEN_PORT}）"
}

verify_ports() {
    if ! have_cmd netstat; then res SKIP "无 netstat，跳过监听端口检查"; return 0; fi
    out=$(netstat -lnptu 2>/dev/null | grep -E "(:53|:${HDP_LISTEN_PORT})[[:space:]]" || true)
    if printf '%s\n' "$out" | grep -q ":53[[:space:]]"; then
        res PASS "dnsmasq 监听 :53"
    else
        res FAIL ":53 无监听"
    fi
    if printf '%s\n' "$out" | grep -q "127\.0\.0\.1:${HDP_LISTEN_PORT}[[:space:]]"; then
        res PASS "https-dns-proxy 监听 127.0.0.1:${HDP_LISTEN_PORT}"
    else
        res FAIL "127.0.0.1:${HDP_LISTEN_PORT} 无监听"
    fi
}

verify_nft() {
    if ! have_cmd nft; then res SKIP "无 nft，跳过防火墙检查"; return 0; fi
    rules=$(nft list ruleset 2>/dev/null || true)
    if printf '%s\n' "$rules" | grep -qi 'DNSMASQ HIJACK'; then
        res FAIL "nft 中仍存在 DNSMASQ HIJACK（请确认 dns_redirect=0 并重启 dnsmasq）"
    else
        res PASS "无 DNSMASQ HIJACK 重复劫持"
    fi
    if printf '%s\n' "$rules" | grep -qi 'https-dns-proxy'; then
        res PASS "存在 https-dns-proxy 的 DNS 接管规则"
    else
        res FAIL "未见 https-dns-proxy 规则（检查 force_dns=1 并重启服务）"
    fi
    if printf '%s\n' "$rules" | grep -iE '(dport|port) 853' | grep -qiE 'reject'; then
        res PASS "853(DoT) 拒绝规则存在"
    else
        res WARN "未明确识别 853 拒绝规则（人工核对: nft list ruleset | grep 853）"
    fi
}

verify_resolution() {
    if [ "$FLAG_NET_TEST" != "1" ]; then res SKIP "网络测试已禁用"; return 0; fi
    if ! have_cmd nslookup; then res SKIP "无 nslookup，跳过解析测试"; return 0; fi
    out=$(nslookup "$TEST_DOMAIN" "127.0.0.1:${HDP_LISTEN_PORT}" 2>&1)
    if [ $? -eq 0 ] && printf '%s\n' "$out" | grep -q 'Address'; then
        res PASS "nslookup ${TEST_DOMAIN} 127.0.0.1:${HDP_LISTEN_PORT} 正常"
    else
        res FAIL "127.0.0.1:${HDP_LISTEN_PORT} 解析失败（https-dns-proxy 未就绪或 DoH 不通）"
    fi
    out=$(nslookup "$TEST_DOMAIN" 127.0.0.1 2>&1)
    if [ $? -eq 0 ] && printf '%s\n' "$out" | grep -q 'Address'; then
        res PASS "nslookup ${TEST_DOMAIN} 127.0.0.1 正常（dnsmasq 链路）"
    else
        res FAIL "127.0.0.1:53 解析失败（dnsmasq -> 5053 链路异常）"
    fi
}

verify_snippets() {
    if [ -f "${SNIPPET_DIR}/daed-dns.dae" ] && [ -f "${SNIPPET_DIR}/daed-routing.dae" ]; then
        res PASS "daed 配置片段已生成（${SNIPPET_DIR}）"
    else
        res WARN "daed 配置片段未生成（运行 install 生成）"
    fi
    if [ -f "${SNIPPET_DIR}/daed-global-settings.txt" ]; then
        res PASS "daed 全局/节点检测设置清单已生成（${SNIPPET_DIR}）"
    else
        res WARN "daed 全局/节点检测设置清单未生成（运行 install 生成）"
    fi
}

verify_ipv6() {
    if [ "$DISABLE_IPV6" != "1" ]; then
        res SKIP "IPv6 禁用未启用（DISABLE_IPV6=0；若上游 IPv6 不通/无 PD，建议开启，见 README「整机禁用 IPv6」）"
        return 0
    fi
    have_uci || { res SKIP "无 uci 命令，跳过 IPv6 禁用检查"; return 0; }
    local ifc opt v ok
    if uci -q show network.wan >/dev/null 2>&1; then
        v=$(uci_get_value network.wan.ipv6)
        [ "$v" = "0" ] && res PASS "IPv6: network.wan.ipv6=0" \
            || res FAIL "IPv6: network.wan.ipv6=${v:-未设置}（应为 0；重跑 install 修正）"
    else
        res SKIP "IPv6: 无 network.wan 接口，跳过该项检查"
    fi
    if uci -q show network.wan6 >/dev/null 2>&1; then
        v=$(uci_get_value network.wan6.proto)
        [ "$v" = "none" ] && res PASS "IPv6: network.wan6.proto=none" \
            || res FAIL "IPv6: network.wan6.proto=${v:-未设置}（应为 none；重跑 install 修正）"
    else
        res SKIP "IPv6: 无 network.wan6 接口"
    fi
    v=$(uci_get_value network.globals.ula_prefix)
    [ -z "$v" ] && res PASS "IPv6: ULA 前缀未设置" \
        || res FAIL "IPv6: ULA 前缀仍为 ${v}（应删除；重跑 install 修正）"
    for ifc in $LAN_IFACES; do
        if ! uci -q show "dhcp.${ifc}" >/dev/null 2>&1; then
            res SKIP "IPv6: 无 dhcp.${ifc} 节，跳过"
            continue
        fi
        ok=1
        for opt in ra dhcpv6 ndp; do
            [ "$(uci_get_value "dhcp.${ifc}.${opt}")" = "disabled" ] || ok=0
        done
        [ "$ok" = "1" ] && res PASS "IPv6: dhcp.${ifc} 的 ra/dhcpv6/ndp=disabled" \
            || res FAIL "IPv6: dhcp.${ifc} 的 ra/dhcpv6/ndp 未全部 disabled（重跑 install 修正）"
    done
    # 运行态：LAN/WAN 设备上不应再有 global 域 IPv6 地址（ULA/动态 GUA 残留）
    if have_cmd ip; then
        local out
        out=$(list_stale_ipv6_addrs)
        if [ -z "$out" ]; then
            res PASS "IPv6: LAN/WAN 接口无残留的 global 域 IPv6 地址"
        else
            set -- $out
            while [ $# -ge 2 ]; do
                res FAIL "IPv6: ${1} 仍残留 ${2}（重跑 install 清理）"
                shift 2
            done
        fi
    else
        res SKIP "IPv6: 无 ip 命令，跳过残留地址检查"
    fi
    return 0
}

verify_layer_a() {
    section "验证链路 A: dnsmasq / https-dns-proxy / nftables"
    verify_dnsmasq_uci
    verify_dnsmasq_runtime
    verify_hdp_uci
    verify_ports
    verify_nft
    verify_resolution
    verify_ipv6
}

verify_layer_b() {
    section "验证链路 B: daed"
    verify_snippets
    daed_readonly_check
}

# -----------------------------------------------------------------------------
# 10. 子命令实现
# -----------------------------------------------------------------------------
preflight_mutating() {
    if [ "${DD_IGNORE_ROOT:-0}" != "1" ] && ! is_root; then
        die "需要 root 权限（当前用户非 root）"
    fi
    if [ "${DD_IGNORE_OS:-0}" != "1" ] && ! is_openwrt; then
        die "未检测到 OpenWrt（缺少 /etc/openwrt_release）。测试环境请设置 DD_IGNORE_OS=1"
    fi
}

self_copy() {
    # 仅当 $0 是包含本脚本标记的普通文件时，复制自身到 WORK_DIR 便于离线重跑
    case "$0" in
        */*) : ;;
        *) return 0 ;;
    esac
    [ -f "$0" ] && grep -q "SCRIPT_NAME=\"openwrt-dns-daed\"" "$0" 2>/dev/null || return 0
    mkdir -p "$WORK_DIR" || return 0
    if ! [ -f "${WORK_DIR}/${SCRIPT_NAME}.sh" ] || ! cmp -s "$0" "${WORK_DIR}/${SCRIPT_NAME}.sh"; then
        cp "$0" "${WORK_DIR}/${SCRIPT_NAME}.sh" 2>/dev/null && \
            log "已复制脚本到 ${WORK_DIR}/${SCRIPT_NAME}.sh（可离线重跑）"
    fi
}

print_daed_next_steps() {
    cat <<EOF

${C_BOLD}下一步（daed 部分需要手动完成一次）:${C_OFF}
  1. 打开 daed GUI（LuCI -> 服务 -> daede，或 daed 面板）
  2. 配置 -> 全局/节点检测: 参照 ${SNIPPET_DIR}/daed-global-settings.txt 填写
  3. 配置 -> DNS:     用 ${SNIPPET_DIR}/daed-dns.dae 内容整体替换并保存
  4. 配置 -> Routing: 用 ${SNIPPET_DIR}/daed-routing.dae 内容整体替换并保存
  5. 重启 daed（${INIT_DIR}/daed restart 或 GUI 内重启）
  6. 运行 ${SCRIPT_NAME}.sh check 复查全部信号

提示:
  - daed 配置保存在 $(daed_wing_db)，本脚本不会直接写库，请通过 GUI 操作
  - 重要变更前可用 GUI 的配置导出功能备份，或运行 $0 backup
EOF
}

cmd_install() {
    preflight_mutating
    mkdir -p "$WORK_DIR" "$SNIPPET_DIR" "$BACKUP_ROOT" || die "无法创建工作目录 ${WORK_DIR}" \
        "常见原因: Flash 空间不足或 /root 只读。排查: df -h /root；空间不足可清理日志或用 DD_WORK_DIR 指向 USB 存储"
    load_conf
    log "openwrt-dns-daed v${SCRIPT_VERSION} 开始部署（配置文件: ${CONF_FILE}）"

    section "依赖检测"
    if hdp_installed; then
        info "https-dns-proxy: 已安装"
    elif [ "$FLAG_INSTALL_MISSING" = "1" ]; then
        install_missing_packages
    else
        die "https-dns-proxy 未安装。加 --install-missing 自动安装，或: opkg install https-dns-proxy"
    fi
    if daed_installed; then
        info "daed: 已安装"
    elif [ "$FLAG_INSTALL_MISSING" = "1" ]; then
        install_missing_packages
    else
        warn "daed 未安装，将只生成配置片段（可加 --install-missing 自动安装）"
    fi
    hdp_installed || die "缺少 https-dns-proxy，无法继续" \
        "上一步自动安装未成功（--install-missing 时安装器输出见上）。手动安装: opkg update && opkg install https-dns-proxy"

    do_backup "install"
    apply_dnsmasq
    apply_hdp
    if [ "$DISABLE_IPV6" = "1" ]; then
        apply_ipv6_disable
        if [ "$IPV6_NET_RELOAD" = "1" ]; then
            reload_network_stack
        fi
        # 兜底：reload 并不总是移除已分配的 ULA/动态地址，主动清理，
        # 避免客户端把 br-lan 上残留的 v6 地址继续当 DNS 服务器使用
        flush_stale_ipv6_addrs
    fi
    section "重启服务（顺序: dnsmasq -> https-dns-proxy）"
    svc_restart dnsmasq
    svc_restart https-dns-proxy
    sleep 2

    verify_layer_a
    gen_daed_snippets
    gen_daed_global_guide
    verify_layer_b

    self_copy
    summary_line
    print_fail_hints
    print_daed_next_steps
    if [ "$RES_FAIL" -gt 0 ]; then
        warn "存在 ${RES_FAIL} 项失败，请按上面速查与提示排查（docs/troubleshooting.md）"
        return 1
    fi
    log "部署完成"
    return 0
}

cmd_check() {
    load_conf
    log "openwrt-dns-daed v${SCRIPT_VERSION} 只读体检（不修改任何配置）"
    section "环境"
    if is_openwrt; then info "OpenWrt 环境: 正常"; else warn "非 OpenWrt 环境（DD_IGNORE_OS/检查项会相应跳过）"; fi
    if hdp_installed; then info "https-dns-proxy: 已安装"; else warn "https-dns-proxy: 未安装"; fi
    if daed_installed; then info "daed: 已安装"; else warn "daed: 未安装"; fi
    have_uci || warn "无 uci 命令，UCI 检查将跳过"
    verify_layer_a
    verify_layer_b
    summary_line
    print_fail_hints
    [ "$RES_FAIL" -eq 0 ] || return 1
    return 0
}

cmd_backup() {
    preflight_mutating
    mkdir -p "$BACKUP_ROOT" || die "无法创建 ${BACKUP_ROOT}" \
        "常见原因: Flash 空间不足或分区只读。排查: df -h /root；只读则 mount -o remount,rw /"
    load_conf
    do_backup "manual"
    log "现有备份列表:"
    ls -1 "$BACKUP_ROOT" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | while read -r d; do
        reason=$(sed -n 's/^reason=//p' "${BACKUP_ROOT}/${d}/info.txt" 2>/dev/null)
        printf '    %s  (%s)\n' "$d" "${reason:-未知原因}"
    done
    return 0
}

cmd_rollback() {
    preflight_mutating
    load_conf
    have_uci || die "未找到 uci 命令，无法回退"
    local dir
    if [ -n "$FLAG_BACKUP_TO" ]; then
        dir="$FLAG_BACKUP_TO"
    else
        dir=$(latest_backup_dir)
    fi
    [ -n "$dir" ] && [ -d "$dir" ] || die "未找到可用备份（目录: ${BACKUP_ROOT}）" \
        "尚无任何备份（install 会自动创建），或 --to 指定的目录不存在。查看现有备份: ls -1 ${BACKUP_ROOT}；创建备份: $0 backup"
    log "回退到备份: ${dir}"
    [ -f "${dir}/info.txt" ] && info "备份信息: $(tr '\n' ' ' < "${dir}/info.txt")"

    section "恢复 UCI 配置"
    if [ -f "${dir}/dhcp.uci" ]; then
        uci import dhcp < "${dir}/dhcp.uci" && uci commit dhcp \
            && log "已恢复 dhcp 配置" || die "恢复 dhcp 配置失败" \
            "备份文件可能损坏或与当前 uci 版本不兼容。检查: cat ${dir}/dhcp.uci；可手动执行 uci import dhcp < 该文件 查看具体报错"
    else
        warn "备份中无 dhcp.uci，跳过"
    fi
    if [ -f "${dir}/https-dns-proxy.uci" ]; then
        uci import https-dns-proxy < "${dir}/https-dns-proxy.uci" \
            && uci commit https-dns-proxy \
            && log "已恢复 https-dns-proxy 配置" \
            || die "恢复 https-dns-proxy 配置失败" \
               "备份文件可能损坏，或 https-dns-proxy 已卸载导致 uci 无法导入。检查: cat ${dir}/https-dns-proxy.uci；已卸载则先 opkg install https-dns-proxy"
    else
        warn "备份中无 https-dns-proxy.uci，跳过"
    fi
    local net_restored=0
    if [ -f "${dir}/network.uci" ]; then
        uci import network < "${dir}/network.uci" && uci commit network \
            && log "已恢复 network 配置" \
            || die "恢复 network 配置失败" \
                "备份文件可能损坏。检查: cat ${dir}/network.uci；可手动执行 uci import network < 该文件 查看具体报错"
        net_restored=1
    else
        info "备份中无 network.uci（旧版本备份），跳过"
    fi

    if [ "$FLAG_WITH_DAED" = "1" ]; then
        section "恢复 daed 数据库"
        db=$(daed_wing_db)
        if [ -f "${dir}/wing.db" ]; then
            svc_exists daed && "${INIT_DIR}/daed" stop >/dev/null 2>&1
            # 先清掉现役 -wal/-shm：把旧主库直接盖回去而留下新 -wal，SQLite 会把
            # 过期帧当有效数据读到；-shm 无需恢复，daed 启动时会自动重建
            rm -f "${db}-wal" "${db}-shm"
            if cp "${dir}/wing.db" "$db" 2>/dev/null; then
                log "已恢复 ${db}"
                [ -f "${dir}/wing.db-wal" ] && cp "${dir}/wing.db-wal" "${db}-wal" 2>/dev/null \
                    && log "已恢复 ${db}-wal"
            else
                warn "恢复 wing.db 失败"
            fi
            svc_exists daed && "${INIT_DIR}/daed" start >/dev/null 2>&1
            warn "注意: 该操作会覆盖 daed 当前全部配置（含备份之后的所有改动）"
        else
            warn "备份中无 wing.db，跳过"
        fi
    fi

    section "重启服务"
    if [ "$net_restored" = "1" ]; then
        reload_network_stack
    fi
    svc_restart dnsmasq
    svc_exists https-dns-proxy && svc_restart https-dns-proxy
    log "回退完成。建议运行 check 验证: $(basename "$0") check"
    return 0
}

update_child_args() { # 构造传给子脚本的参数（继承关键全局选项）
    UPDATE_CHILD_ARGS="install --config ${CONF_FILE}"
    [ "$FLAG_NET_TEST" = "1" ] || UPDATE_CHILD_ARGS="${UPDATE_CHILD_ARGS} --no-net-test"
    [ "$FLAG_INSTALL_MISSING" = "1" ] && UPDATE_CHILD_ARGS="${UPDATE_CHILD_ARGS} --install-missing"
    return 0
}

cmd_update() {
    preflight_mutating
    load_conf
    local target="${WORK_DIR}/${SCRIPT_NAME}.sh"
    if [ -n "$SCRIPT_SELFUPDATE_URL" ]; then
        log "从 ${SCRIPT_SELFUPDATE_URL} 获取最新脚本"
        tmp=$(mktemp 2>/dev/null) || tmp="${WORK_DIR}/.update.$$"
        fetch_to "$SCRIPT_SELFUPDATE_URL" "$tmp" || { rm -f "$tmp"; die "下载失败（${SCRIPT_SELFUPDATE_URL}）" \
            "常见原因: 路由器无出站网络/DNS 不可用/防火墙拦截 GitHub，或地址失效。手动验证: curl -fsSL '${SCRIPT_SELFUPDATE_URL}' -o /tmp/t.sh；也可直接重新运行一键安装命令获取最新脚本"; }
        sh -n "$tmp" || { rm -f "$tmp"; die "下载的脚本语法校验失败，放弃更新"; }
        newver=$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "$tmp" | head -n 1)
        mkdir -p "$WORK_DIR"
        cp "$tmp" "$target" && chmod +x "$target"
        rm -f "$tmp"
        log "已更新脚本: ${SCRIPT_VERSION} -> ${newver:-未知版本}"
        log "使用新版本重新应用配置"
        update_child_args
        if [ -f "$target" ]; then
            sh "$target" $UPDATE_CHILD_ARGS
            return $?
        fi
    else
        warn "未配置 SCRIPT_SELFUPDATE_URL，跳过在线自更新"
        if [ -f "$target" ]; then
            log "使用本地副本重新应用配置: ${target}"
            update_child_args
            sh "$target" $UPDATE_CHILD_ARGS
            return $?
        fi
        warn "本地副本不存在。请重新运行在线一键安装命令获取最新脚本"
    fi
    return 0
}

cmd_clean() {
    preflight_mutating
    load_conf
    section "清理 ${SCRIPT_NAME} 产物"
    if [ "$FLAG_PURGE" = "1" ]; then
        rm -rf "$WORK_DIR"
        [ -f "$CONF_FILE" ] && rm -f "$CONF_FILE" && info "已删除配置文件 ${CONF_FILE}"
        [ -d "$DAED_EXTRA_DIR" ] && rm -rf "$DAED_EXTRA_DIR" && info "已删除追加片段目录 ${DAED_EXTRA_DIR}"
        log "已彻底清理（含全部备份）"
    else
        rm -rf "$SNIPPET_DIR" "${WORK_DIR}/logs" "${WORK_DIR}/${SCRIPT_NAME}.sh"
        [ -d "$WORK_DIR" ] && find "$WORK_DIR" -maxdepth 1 -name '.*' -type f -delete 2>/dev/null
        log "已清理生成片段/日志/脚本副本"
        info "已保留: ${BACKUP_ROOT}（回退用，可用 --purge 一并删除）"
        info "已保留: ${CONF_FILE}（配置文件，可用 --purge 一并删除）"
    fi
    info "未改动任何 UCI/daed 配置；如需还原配置请先运行 rollback"
    return 0
}

cmd_version() {
    echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
}

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} —— OpenWrt 防 DNS 劫持一键部署（dnsmasq + https-dns-proxy + daed）

用法:
  ${SCRIPT_NAME}.sh [全局选项] <命令> [命令选项]

命令:
  install    一键部署/修复（幂等可重跑；变更前自动备份）
  check      只读体检，输出各层 PASS/FAIL/WARN 报告
  update     自更新脚本并重新应用配置（需在配置文件中填写 SCRIPT_SELFUPDATE_URL）
  backup     手动备份当前 UCI/防火墙/daed 状态
  rollback   回退到最近一次（或 --to 指定）备份
  clean      清理脚本产物（默认保留备份与配置文件；--purge 全部删除）
  version    显示版本
  help       本帮助

全局选项:
  --config <路径>      指定配置文件（默认 /etc/${SCRIPT_NAME}.conf）
  --install-missing    自动安装缺失的 https-dns-proxy / daed
  --no-net-test        跳过 nslookup 连通性测试
  -h, --help           帮助
  -V, --version        版本

命令专属选项:
  install --restart-daed        部署完成后顺带重启 daed（默认只提示手动重启）
  rollback --to <备份目录>      指定回退到哪个备份（默认最近一次）
  rollback --with-daed          同时恢复 daed 数据库 wing.db（覆盖备份之后的全部改动，慎用）
  clean    --purge              连同备份与配置文件一起删除

示例:
  # 在线一键安装
  curl -fsSL https://raw.githubusercontent.com/blooddrunk/${SCRIPT_NAME}/main/${SCRIPT_NAME}.sh | sh -s -- install

  # 本地运行
  sh ./${SCRIPT_NAME}.sh install
  sh ./${SCRIPT_NAME}.sh check
  sh ./${SCRIPT_NAME}.sh rollback --with-daed

内部/测试环境变量:
  DD_IGNORE_OS / DD_IGNORE_ROOT / DD_WORK_DIR / DD_INIT_DIR / DD_CONFIG_DIR / DD_DAED_DB / DD_TUN_DEV
EOF
}

# -----------------------------------------------------------------------------
# 11. 参数解析与分发
# -----------------------------------------------------------------------------
COMMAND=""
FLAG_INSTALL_MISSING=0
FLAG_NET_TEST=1
FLAG_RESTART_DAED=0
FLAG_WITH_DAED=0
FLAG_BACKUP_TO=""
FLAG_PURGE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --config)
            [ $# -ge 2 ] || die "--config 需要一个参数"
            CONF_FILE="$2"; shift 2 ;;
        --config=*) CONF_FILE="${1#*=}"; shift ;;
        --install-missing) FLAG_INSTALL_MISSING=1; shift ;;
        --no-net-test) FLAG_NET_TEST=0; shift ;;
        --restart-daed) FLAG_RESTART_DAED=1; shift ;;
        --with-daed) FLAG_WITH_DAED=1; shift ;;
        --to)
            [ $# -ge 2 ] || die "--to 需要一个参数"
            FLAG_BACKUP_TO="$2"; shift 2 ;;
        --to=*) FLAG_BACKUP_TO="${1#*=}"; shift ;;
        --purge) FLAG_PURGE=1; shift ;;
        --keep-backups) shift ;; # 兼容别名：默认行为即保留备份
        -h|--help) usage; exit 0 ;;
        -V|--version) cmd_version; exit 0 ;;
        -*) die "未知选项: $1（查看 help）" ;;
        *)
            if [ -z "$COMMAND" ]; then COMMAND="$1"; else die "多余的参数: $1"; fi
            shift ;;
    esac
done
: "${COMMAND:=install}"

run_logged() { # run_logged <函数> [参数...] —— 输出同时记录到日志文件
    # 说明: die() 直接 exit 时不会写 rc_file，按约定以 1 处理（die 均为致命错误）
    #       rc_file 放在 /tmp 而非 WORK_DIR，避免 clean --purge 删除目录后丢失 rc
    local rc_file log_dir log_file
    log_dir="${WORK_DIR}/logs"
    mkdir -p "$log_dir" 2>/dev/null || { "$@"; return $?; }
    log_file="${log_dir}/$(date +%Y%m%d-%H%M%S)-${COMMAND}.log"
    rc_file="/tmp/${SCRIPT_NAME}.rc.$$"
    rm -f "$rc_file"
    (
        "$@"
        echo $? > "$rc_file"
    ) 2>&1 | tee "$log_file"
    rc=1
    [ -f "$rc_file" ] && rc=$(cat "$rc_file" 2>/dev/null)
    case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
    rm -f "$rc_file"
    log "日志已保存: ${log_file}"
    return "$rc"
}

case "$COMMAND" in
    install)
        # install 期间需要先生成配置文件骨架（若不存在），再由 load_conf 读取
        if [ ! -f "$CONF_FILE" ]; then
            preflight_mutating
            ensure_conf
        fi
        run_logged cmd_install
        rc=$?
        if [ "$FLAG_RESTART_DAED" = "1" ] && daed_installed; then
            svc_restart daed || true
        fi
        exit $rc
        ;;
    check|status)    cmd_check;  exit $? ;; # 只读命令，不写日志
    update)          run_logged cmd_update; exit $? ;;
    backup)          run_logged cmd_backup; exit $? ;;
    rollback)        run_logged cmd_rollback; exit $? ;;
    clean|uninstall) run_logged cmd_clean;   exit $? ;;
    version)         cmd_version ;;
    help|--help)     usage ;;
    *) die "未知命令: ${COMMAND}（查看 help）" ;;
esac
exit 0
