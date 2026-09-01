#!/bin/bash
set -e

error_exit() { echo "ERR: $1" >&2; exit 1; }

_escape_uci() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

is_valid_ipv4() {
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$1"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        case "$o" in ''|*[!0-9]*) return 1 ;; esac
        [ "$o" -le 255 ] || return 1
    done
    case "$o1" in 0|127) return 1 ;; 169) [ "$o2" = "254" ] && return 1 ;; esac
    { [ "$o4" -eq 0 ] || [ "$o4" -eq 255 ]; } && return 1
    return 0
}

DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.2"
SUBNET_MASK="255.255.255.0"
DNS_MAIN="223.5.5.5"
DNS_BACKUP="223.6.6.6"

VERSION="" PHASE="" PROFILE_TYPE="" CORE="fanchmwrt" FEEDS_SRC="" FILES_DIR_NAME="files"
CUSTOM_IP="" CUSTOM_GATEWAY="" BYPASS_IP="" PPPOE_USERNAME="" PPPOE_PASSWORD="" ROOT_PASSWORD=""

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version) VERSION="$2"; shift 2 ;;
        -p|--phase)   PHASE="$2"; shift 2 ;;
        -t|--type)    PROFILE_TYPE="$2"; shift 2 ;;
        --ip)         CUSTOM_IP="$2"; shift 2 ;;
        --gateway)    CUSTOM_GATEWAY="$2"; shift 2 ;;
        --pppoe-user) PPPOE_USERNAME="$2"; shift 2 ;;
        --pppoe-pass) PPPOE_PASSWORD="$2"; shift 2 ;;
        --root-pass)  ROOT_PASSWORD="$2"; shift 2 ;;
        --core)      CORE="$2"; shift 2 ;;
        --feeds)     FEEDS_SRC="$2"; shift 2 ;;
        --files-dir) FILES_DIR_NAME="$2"; shift 2 ;;
        --bypass-ip) BYPASS_IP="$2"; shift 2 ;;
        *) error_exit "未知参数 $1" ;;
    esac
done

[ -n "$VERSION" ] && [ -n "$PHASE" ] || error_exit "必填 --version / --phase"
[ "$PHASE" = "after" ] && [ -z "$PROFILE_TYPE" ] && error_exit "after阶段必须指定 --type main/bypass"
case "$PROFILE_TYPE" in ""|main|bypass) ;; *) error_exit "--type 仅支持 main / bypass" ;; esac

if [ "$PROFILE_TYPE" = "bypass" ]; then
    [ -z "$CUSTOM_IP" ] && CUSTOM_IP="$DEF_BYPASS_IP"
    [ -z "$CUSTOM_GATEWAY" ] && CUSTOM_GATEWAY="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法旁路由IP: $CUSTOM_IP"
    is_valid_ipv4 "$CUSTOM_GATEWAY" || error_exit "非法旁路由网关: $CUSTOM_GATEWAY"
    [ -n "$PPPOE_USERNAME" ] || [ -n "$PPPOE_PASSWORD" ] && error_exit "旁路由不支持PPPoE，请使用 --type main"
elif [ "$PROFILE_TYPE" = "main" ]; then
    [ -z "$CUSTOM_IP" ] && CUSTOM_IP="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法路由IP: $CUSTOM_IP"
fi

if [ -n "$PPPOE_USERNAME" ] || [ -n "$PPPOE_PASSWORD" ]; then
    [ -z "$PPPOE_USERNAME" ] || [ -z "$PPPOE_PASSWORD" ] && error_exit "PPPoE账号密码必须成对传入"
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
[ -d "$PROJECT_ROOT" ] || error_exit "无法定位项目根目录: $PROJECT_ROOT"

case "$PHASE" in
before)
    echo "[diy] before: $VERSION (core=$CORE)"
    if [ -n "$FEEDS_SRC" ]; then
        FEED_CONF_SRC="$FEEDS_SRC"
    else
        FEED_CONF_SRC="$PROJECT_ROOT/feeds/$VERSION.conf"
    fi
    [ -f "$FEED_CONF_SRC" ] || error_exit "缺失feed配置: $FEED_CONF_SRC"
    rm -f feeds.conf
    cp "$FEED_CONF_SRC" feeds.conf
    ;;

ruby)
    # ruby YJIT 解耦：分支头 lang/ruby 默认 RUBY_ENABLE_YJIT=y -> 拉 rust/host -> rustc LLVM 404 构建挂。
    # OpenClash 依赖 ruby(不可选)，故仅在 WITH_OC 时由 workflow 调用。须 feeds update 后、install 前执行。
    echo "[diy] ruby: 解耦 YJIT 与 rust/host（x86_64/aarch64）"
    RUBY_DIR="$PROJECT_ROOT/openwrt/feeds/packages/lang/ruby"
    if [ -d "$RUBY_DIR" ]; then
        # Makefile: 去掉 RUBY_ENABLE_YJIT:rust/host 条件依赖，仅保留 ruby/host（用 # 作分隔符避路径斜杠）
        sed -i -E 's#(PKG_BUILD_DEPENDS:=ruby/host) RUBY_ENABLE_YJIT:rust/host#\1#' "$RUBY_DIR/Makefile"
        # Config.in: 删除 x86_64/aarch64 默认开启 YJIT（让 defconfig 不再翻成 =y）
        sed -i -E '/^[[:space:]]*default y if x86_64\|\|aarch64[[:space:]]*$/d' "$RUBY_DIR/Makefile"
        echo "[diy] ruby: 已解耦 YJIT（Makefile 依赖 + Config.in default 均清除）"
    else
        echo "[diy] WARN: 未找到 $RUBY_DIR（feeds update 是否已执行？），跳过 ruby YJIT 解耦" >&2
    fi
    ;;

themes)
    # 须在 feeds update -a 之后运行：fanchmwrt 主题在克隆仓内(非独立 feed)，glob 定位；argon/bootstrap 在 feeds/luci。
    # 所有主题统一处理：
    #  1) 标题用 <% %> Lua（{{ }} 是 JS 模板语法，LuCI .ut 不解析 → 显示字面量 {{主机名}}）。
    #  2) footer 只隐藏不删除：删了 argon menu-argon.js 的 renderModeMenu() 会 appendChild 到已消失的 #modemenu
    #     → render() 抛错 → 整条侧边栏不渲染。保留 DOM 则 JS 不崩、导航保留（含装 OAF 时的 argon）。
    echo "[diy] themes: 处理 fanchmwrt/argon/bootstrap 主题标题与 footer"
    OPENWRT_DIR="$PROJECT_ROOT/openwrt"
    python3 - "$OPENWRT_DIR" <<'PY'
import sys, os, re, glob
openwrt = sys.argv[1]

# LuCI .ut 用 Lua 模板：boardinfo.hostname / node.title 均为模板上下文变量；striptags 为内置函数。
TITLE_NEW = "<title><%= striptags((boardinfo.hostname or '?') .. (node and ' - ' .. node.title or '')) %> - LuCI</title>"
# 隐藏 footer 但保留 DOM（#modemenu 仍在，menu-argon.js 不崩）；整串用于重复构建去重。
HIDE_CSS = '<style id="leenwrt-hide-footer">footer{display:none!important}</style>'

def fix_header(path):
    s0 = open(path, encoding='utf-8').read()
    s = s0
    # 标题：容忍 <title ...> 属性，替换为合法 Lua 表达式
    s, n = re.subn(r'<title[^>]*>.*?</title>', TITLE_NEW, s, count=1, flags=re.S)
    if n and HIDE_CSS not in s:
        # 紧跟 </title> 之后注入（位于 <head> 内），不依赖 </head> 是否存在
        s = s.replace(TITLE_NEW, TITLE_NEW + "\n    " + HIDE_CSS, 1)
    if s != s0:
        open(path, 'w', encoding='utf-8').write(s)
        print("[diy] 标题+footer隐藏已应用: " + path)
    elif n:
        print("[diy] 标题已替换，footer CSS 已存在(无变更): " + path)
    else:
        print("[diy] 未在 header.ut 找到 <title>: " + path)

theme_dirs = set()
for p in glob.glob(os.path.join(openwrt, '**', 'luci-theme-*'), recursive=True):
    if os.path.isdir(p):
        theme_dirs.add(p)

for d in sorted(theme_dirs):
    for h in glob.glob(os.path.join(d, '**', 'header.ut'), recursive=True):
        fix_header(h)
PY

    # fwxd：修复 dashboard 联网状态误报（DNS 劫持/ADGH 未就绪时 www.baidu.com 解析失败）
    # LeenWrt2 的 fwxd 源码在主仓 clone（package/fcm/fwxd），非 feeds/fwx（immortalwrt 才用 src-link）
    FWXD_DIR="$OPENWRT_DIR/package/fcm/fwxd"
    FWXD_CHECK="$FWXD_DIR/src/check_main.c"
    FWXD_PATCH="$PROJECT_ROOT/patches/fwx/fwxd-internet-check-dns-agnostic.patch"
    [ -d "$FWXD_DIR" ] || error_exit "未找到 fwxd 源码目录: $FWXD_DIR（主仓 clone 路径是否变化？）"
    if patch -p1 --dry-run -d "$FWXD_DIR" < "$FWXD_PATCH" >/dev/null 2>&1; then
        patch -p1 -d "$FWXD_DIR" < "$FWXD_PATCH"
        echo "[diy] 已应用 fwxd 联网检查补丁 -> $FWXD_CHECK"
    else
        error_exit "fwxd 联网检查补丁上下文不符，未应用（详见 $FWXD_PATCH）"
    fi

    # fwx 内核模块：DPI 边界钳制（read_skb 的 kmalloc(len) 须 clamp 到 skb 尾部，
    # 否则发送方伪造 tot_len/udph->len/doff 越界，触发 FORTIFY memcpy BUG / 原子分配失败→panic/重启。
    # 与 LeenWrt 共用同一补丁；fanchmwrt 内核已导出 4 参 nf_send_reset，故无需 kmod-nf_send_reset 补丁。
    # LeenWrt2 走分支头（fanchmwrt-${VERSION}，不可钉 SHA）→ 采用 fail-soft：
    # 补丁能 apply 则应用；apply 不上则视为上游已自带钳制而跳过（warn），避免上游合入修复后误 abort 构建；
    # 仅当"补丁 apply 不上且上游仍未钳制"才 error_exit（代码漂移需重新核对）。
    FWX_DIR="$OPENWRT_DIR/package/fcm/fwx"
    FWX_SRC="$FWX_DIR/src/fwx_main.c"
    FWX_PATCH="$PROJECT_ROOT/patches/fwx/fwx-match-feature-crash.patch"
    [ -d "$FWX_DIR" ] || error_exit "未找到 fwx 内核模块源码目录: $FWX_DIR（主仓 clone 路径是否变化？）"
    if patch -p1 --dry-run -d "$FWX_DIR" < "$FWX_PATCH" >/dev/null 2>&1; then
        patch -p1 -d "$FWX_DIR" < "$FWX_PATCH"
        echo "[diy] 已应用 fwx DPI 边界钳制补丁 -> $FWX_SRC"
    elif grep -Eq 'skb_tail_pointer|tail - ipp|pskb_may_pull' "$FWX_SRC" 2>/dev/null; then
        # 上游已自带 skb 边界钳制（已修复此 bug），补丁上下文不符属正常，跳过以免 abort 构建
        echo "[diy][warn] 上游 fwx_main.c 已自带 skb 边界钳制，DPI 补丁跳过（上游已修复，自动让位）"
    else
        error_exit "fwx DPI 边界钳制补丁上下文不符且上游未自带钳制（详见 $FWX_PATCH）；fwx 版本漂移需重新核对"
    fi
    ;;

after)
    echo "[diy] after: $PROFILE_TYPE (core=$CORE)"
    case "$FILES_DIR_NAME" in
      /*) FB_DIR="$FILES_DIR_NAME" ;;
      *)  FB_DIR="$PROJECT_ROOT/$FILES_DIR_NAME" ;;
    esac
    OUT="$FB_DIR/etc/uci-defaults/99-custom.sh"
    SHADOW="$FB_DIR/etc/shadow"
    mkdir -p "$(dirname "$OUT")"
    rm -f "$OUT" "$SHADOW"

    ip_esc=$(_escape_uci "$CUSTOM_IP")

    # FanchmWrt：diy.sh 仅写 IP/WAN/主机名/flow_offloading；OC/ADGH/DNS_HIJACK 由首启 firstboot-pkgs 布设
    case "$PROFILE_TYPE" in
      bypass) FB_PROFILE="mini" ;;
      *)      FB_PROFILE="default" ;;
    esac
    mkdir -p "$FB_DIR/etc/firstboot-pkgs"
    echo "$FB_PROFILE" > "$FB_DIR/etc/firstboot-pkgs/profile"
    # 双路由主路由：写入对端旁路由 IP，供 firstboot-pkgs 布 dns_hijack_bypass_ip（dns-hijack 据此排除，防二次劫持）；单路由/旁路由留空=全量劫持
    [ -n "$BYPASS_IP" ] && echo "$BYPASS_IP" > "$FB_DIR/etc/firstboot-pkgs/bypass_ip"

    echo '#!/bin/sh' > "$OUT"
    echo "logger -t uci-defaults \"开始应用 LeenWrt ${PROFILE_TYPE} 配置\"" >> "$OUT"

    # 确保 loopback 接口存在：overlay/rootfs 挂载异常时默认配置可能缺失，导致 lo 未 UP、127.0.0.1 不可达，
    # 进而 ADGH/OC/dnsmasq/LuCI 全挂。放开头供 main/bypass 共用。
    cat >> "$OUT" <<'EOF'
if ! uci -q get network.loopback >/dev/null 2>&1; then
    uci set network.loopback=interface
    uci set network.loopback.device='lo'
    uci set network.loopback.proto='static'
    uci set network.loopback.ipaddr='127.0.0.1'
    uci set network.loopback.netmask='255.0.0.0'
fi
EOF

    # 端口：主路由 WAN 锁 eth1（else 分支）；旁路由不建 WAN，全口桥接 LAN

    if [ "$PROFILE_TYPE" = "bypass" ]; then
        gw_esc=$(_escape_uci "$CUSTOM_GATEWAY")
        cat >> "$OUT" <<EOT
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ip_esc'
uci set network.lan.netmask='$SUBNET_MASK'
uci set network.lan.gateway='$gw_esc'
uci -q delete network.lan.dns
uci add_list network.lan.dns='$DNS_MAIN'
uci add_list network.lan.dns='$DNS_BACKUP'
uci -q delete network.lan6
uci -q delete network.wan
uci -q delete network.wan6
uci commit network

uci set dhcp.lan.ignore='1'
uci set dhcp.lan6.ignore='1'
uci -q set dhcp.@dnsmasq[0].rebind_protection='0'
uci commit dhcp
EOT
        # 旁路由：所有网口桥接为 LAN，重建 br-lan
        cat >> "$OUT" <<'EOT'
# 旁路由 LAN 桥接重建
_fw_all=$(ls /sys/class/net 2>/dev/null | grep -E '^eth[0-9]+$' | sort -V)
if [ -n "$_fw_all" ]; then
  for _d in $(uci show network 2>/dev/null | sed -n "s/^\(network\.[^.]*\)\.name='br-lan'$/\1/p"); do
    uci -q delete "$_d"
  done
  uci set network.br_lan=device
  uci set network.br_lan.name='br-lan'
  uci set network.br_lan.type='bridge'
  uci -q delete network.br_lan.ports
  for _e in $_fw_all; do
    uci add_list network.br_lan.ports="$_e"
  done
  uci set network.lan.device='br-lan'
  uci -q delete network.lan.type
  uci -q delete network.lan.ports
  uci -q delete network.lan.ifname
  uci commit network
fi
EOT
    else
        if [ -n "$PPPOE_USERNAME" ]; then
            u=$(_escape_uci "$PPPOE_USERNAME"); p=$(_escape_uci "$PPPOE_PASSWORD")
            WAN_FANCHM=$(cat <<EOT
uci set network.wan.proto='pppoe'
uci set network.wan.username='$u'
uci set network.wan.password='$p'
uci set network.wan.ipv6='auto'
uci set network.wan.peerdns='1'
uci set network.wan.device='eth1'
uci set network.wan.mtu_fix='1'
uci set network.wan.mssfix='1'
uci -q delete network.wan6
EOT
)
        else
            WAN_FANCHM=$(cat <<EOT
uci set network.wan.proto='dhcp'
uci set network.wan.device='eth1'
uci set network.wan.peerdns='1'
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='auto'
EOT
)
        fi
        # 端口：WAN 锁 eth1（物理前口映射为 eth1；fanchmwrt 默认末口=WAN 会指到 eth3，必须显式指定）
        PORT_FANCHM=$(cat <<'EOT'
# 先删既有 br-lan device（默认配置含匿名段，不删会并存两个同名桥 → 端口双归属、LuCI 解析异常）
for _d in $(uci show network 2>/dev/null | sed -n "s/^\(network\.[^.]*\)\.name='br-lan'$/\1/p"); do
  uci -q delete "$_d"
done
_lan_eth=$(ls /sys/class/net 2>/dev/null | grep -E '^eth[0-9]+$' | grep -v '^eth1$' | sort -V)
uci set network.br_lan=device
uci set network.br_lan.name='br-lan'
uci set network.br_lan.type='bridge'
uci -q delete network.br_lan.ports
for _e in $_lan_eth; do uci add_list network.br_lan.ports="$_e"; done
uci set network.lan.device='br-lan'
uci -q delete network.lan.type
uci -q delete network.lan.ports
uci -q delete network.lan.ifname
uci commit network
EOT
)
        cat >> "$OUT" <<EOT
$WAN_FANCHM
$PORT_FANCHM
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ip_esc'
uci set network.lan.netmask='$SUBNET_MASK'
uci commit network

uci -q delete dhcp.lan.dhcp_option
uci add_list dhcp.lan.dhcp_option='6,$ip_esc'
uci set dhcp.lan.start='7'
uci set dhcp.lan.limit='149'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra='server'
uci -q set dhcp.@dnsmasq[0].rebind_protection='0'
uci set dhcp.@dnsmasq[0].sequential_ip='1'
uci commit dhcp
EOT
    fi

    cat >> "$OUT" <<EOT
# fwx 依赖 conntrack，与流卸载冲突，关闭 flow_offloading
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
# FullCone：需 kmod-nft-fullcone(见 fanchmwrt-lean.config)；fw4 探测不到该表达式会自动回退 masquerade
uci set firewall.@defaults[0].fullcone='1'
uci commit firewall

uci set system.@system[0].hostname='LeenWrt'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci -q delete system.ntp.server
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='cn.pool.ntp.org'
uci commit system

chmod 755 /etc/init.d/cpufreq-perf
/etc/init.d/cpufreq-perf enable
/etc/init.d/cpufreq-perf start

# 首启安装由 rc.local 触发；enable 备下次启动兜底
chmod 755 /etc/init.d/firstboot-pkgs
/etc/init.d/firstboot-pkgs enable

    # FanchmWrt 的 uhttpd 首启不自动拉起，兜底 enable+start
if [ -x /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd enable 2>/dev/null
    /etc/init.d/uhttpd start 2>/dev/null
fi
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd enable 2>/dev/null
# 网页后台登录复用 root 系统密码（fanchmwrt 默认未委托，需显式设置以对齐 LeenWrt 行为）
uci -q get rpcd.@login[0] >/dev/null 2>&1 || uci add rpcd login
uci set rpcd.@login[0].username='root'
uci set rpcd.@login[0].password='\$p\$root'
uci commit rpcd
/etc/init.d/rpcd restart 2>/dev/null

    # 主题默认浅色（覆盖 fwx 出厂 theme_mode=1 深色）
    if uci -q get fwx.global >/dev/null 2>&1; then
        uci set fwx.global.theme_mode='0'
        uci commit fwx
    fi

logger -t uci-defaults "LeenWrt 配置应用完成"
EOT
    chmod 755 "$OUT" 2>/dev/null || true
    echo "[diy] 输出: $OUT (FanchmWrt lean)"

    if [ -n "$ROOT_PASSWORD" ]; then
        command -v openssl >/dev/null 2>&1 || error_exit "缺失依赖: openssl (用于 root 密码哈希)"
        # musl crypt 仅认 DES/MD5($1$)，dropbear 才支持 SHA-512；用 -1 保证 SSH 与网页登录一致
        crypt=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -1 -stdin) || error_exit "openssl密码加密失败"
        echo "root:$crypt:0:0:99999:7:::" > "$SHADOW"
        chmod 600 "$SHADOW" 2>/dev/null || true
    fi
    ;;
*) error_exit "PHASE仅支持 before / after / ruby / themes" ;;
esac

echo "[diy] done: $PHASE ${PROFILE_TYPE:-N/A}"
