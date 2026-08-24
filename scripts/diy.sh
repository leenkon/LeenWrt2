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

    # ===== FanchmWrt 精简分支（仅 IP/WAN/主机名；无 OC/ADGH/DNS_HIJACK/OAF） =====
    case "$PROFILE_TYPE" in
      bypass) FB_PROFILE="mini" ;;
      *)      FB_PROFILE="default" ;;
    esac
    mkdir -p "$FB_DIR/etc/firstboot-pkgs"
    echo "$FB_PROFILE" > "$FB_DIR/etc/firstboot-pkgs/profile"

    echo '#!/bin/sh' > "$OUT"
    echo "logger -t uci-defaults \"开始应用 LeenWrt ${PROFILE_TYPE} 配置\"" >> "$OUT"

    # FanchmWrt x86 默认 network 由 board.d/03-default-network 在首启生成：源码原把“末口”当 WAN、其余桥接为 LAN。
    # 翻转为“首口=WAN”（其余桥接为 LAN）。board.d 会正确建立 DSA br-lan 桥，main 无需 diy 再处理端口；
    # 旁路由在下方单独把全部网口桥接为 LAN（无独立 WAN）。
    _SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../openwrt" 2>/dev/null && pwd || true)"
    [ -z "$_SRC_ROOT" ] && _SRC_ROOT="."
    _03net="$_SRC_ROOT/target/linux/x86/base-files/etc/board.d/03-default-network"
    if [ -f "$_03net" ]; then
      sed -i 's/\[ "$idx" -eq "$eth_count" \]/[ "$idx" -eq 1 ]/' "$_03net"
    fi

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
        # 旁路由：所有网口桥接为 LAN（无独立 WAN），显式重建 br-lan 设备
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
uci -q delete network.wan6
EOT
)
        else
            WAN_FANCHM=$(cat <<EOT
uci set network.wan.proto='dhcp'
uci set network.wan.peerdns='1'
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='auto'
EOT
)
        fi
        cat >> "$OUT" <<EOT
$WAN_FANCHM
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
# fwx 应用过滤(DPI 内核模块)依赖 conntrack，与流卸载冲突会导致连接不稳/应用过滤失效，故关闭
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
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

chmod 755 /etc/init.d/firstboot-pkgs
/etc/init.d/firstboot-pkgs enable
/etc/init.d/firstboot-pkgs start

# FanchmWrt 的 uhttpd 首启不会自动拉起（immortalWrt 不受影响），兜底 enable+start 确保后台立即可访问
if [ -x /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd enable 2>/dev/null
    /etc/init.d/uhttpd start 2>/dev/null
fi
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd enable 2>/dev/null

logger -t uci-defaults "LeenWrt 配置应用完成"
EOT
    chmod 755 "$OUT" 2>/dev/null || true
    echo "[diy] 输出: $OUT (FanchmWrt lean)"
    ;;
*) error_exit "PHASE仅支持 before / after" ;;
esac

echo "[diy] done: $PHASE ${PROFILE_TYPE:-N/A}"
