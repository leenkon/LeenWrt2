#!/bin/bash
# LeenWrt2 本地编译脚本（FanchmWrt 原生方案，固件主机名 LeenWrt）
# 单核心 fanchmwrt：取源分支 fanchmwrt-${VERSION}（fwx 内核栈 kmod-fwx/fwxd 仅该分支有，所有 v25.12.x tag 均不含），
# 内联最小 config(configs/fanchmwrt-lean.config，含镜像格式/分区) + 首启 lists/ 在线装 + apps/ 离线装。
# 用法: chmod +x build.sh && ./build.sh

set -e

# 颜色定义
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
error_exit() { echo -e "${RED}错误：$1${NC}" >&2; exit 1; }
success() { echo -e "${GREEN}[OK] $1${NC}"; }

DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.2"
DEF_GATEWAY="10.10.10.1"
ROOT_PASSWORD="password"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_CONF_DIR="$SCRIPT_DIR/cores"

# ========== 1. 核心（固定 fanchmwrt） ==========
CORE="fanchmwrt"
CORE_CONF="$CORE_CONF_DIR/$CORE.conf"
[ -f "$CORE_CONF" ] || error_exit "缺失核心描述: $CORE_CONF"
# shellcheck disable=SC1090
source "$CORE_CONF"
success "核心: $CORE ($REPO_URL)"

# ========== 2. 版本选择（来自核心描述 VERSION_OPTIONS） ==========
echo -e "\n请选择 $CORE 版本："
i=1
for v in $VERSION_OPTIONS; do echo "  $i) $v"; i=$((i+1)); done
read -p "请输入选择 [1-$(($i-1))，默认 1]: " vsel
vsel=${vsel:-1}
VERSION=$(echo $VERSION_OPTIONS | awk -v n="$vsel" '{print $n}')
[ -n "$VERSION" ] || error_exit "无效选择"
success "版本: $VERSION"

# ========== 3. 配置选择（FanchmWrt 仅 Main/Mini） ==========
echo -e "\n请选择编译配置："
echo "  1) Main (主路由)  2) Mini (旁路由)"
read -p "请输入选择 [1-2，默认 1]: " p
p=${p:-1}
case "$p" in 1) PROFILE="Main";; 2) PROFILE="Mini";; *) error_exit "无效选择";; esac
case "$PROFILE" in
  Main) CFG_PREFIX=default; RUN_TYPE=main;;
  Mini) CFG_PREFIX=mini;    RUN_TYPE=bypass;;
  *) error_exit "无效配置: $PROFILE";;
esac

# 自定义IP
echo -e "\n[LAN IP]"
[[ "$RUN_TYPE" == "bypass" ]] && DEF_IP="$DEF_BYPASS_IP" || DEF_IP="$DEF_MAIN_IP"
read -p "自定义LAN IP [默认: $DEF_IP，回车跳过]: " custom_ip
ROUTER_IP="${custom_ip:-$DEF_IP}"
success "LAN IP: $ROUTER_IP"

# 网关(仅旁路由)
GATEWAY_IP=""
[[ "$RUN_TYPE" == "bypass" ]] && { read -p "网关IP [默认: $DEF_GATEWAY]: " gw; GATEWAY_IP="${gw:-$DEF_GATEWAY}"; success "网关: $GATEWAY_IP"; }

# 旁路由IP(仅主路由)：双路由填写对端旁路由 IP，供 DNS 劫持排除(防二次劫持)；单路由留空=全量劫持
BYPASS_PEER_IP=""
[[ "$RUN_TYPE" == "main" ]] && { read -p "旁路由IP(双路由填写，留空=单路由全量劫持) [默认空]: " bip; BYPASS_PEER_IP="${bip:-}"; success "旁路由IP: ${BYPASS_PEER_IP:-空(单路由)}"; }

# PPPoE (主路由)
PPPOE_USER="" PPPOE_PASS=""
[[ "$RUN_TYPE" == "main" ]] && { read -p "配置PPPoE? [y/N]: " pp; [[ "$pp" =~ ^[Yy]$ ]] && { read -p "用户名: " PPPOE_USER; read -p "密码: " PPPOE_PASS; success "PPPoE已配置"; } || success "使用DHCP"; }

# Root密码
read -p "Root密码 [默认: password]: " rp
ROOT_PWD="${rp:-$ROOT_PASSWORD}"
success "密码已设置"

# AdGuardHome / OpenClash（可独立勾选：勾选才编译进固件并布 DNS 链）
read -p "安装 AdGuardHome? [Y/n]: " a
case "$a" in [Nn]*) WITH_ADGH=0;; *) WITH_ADGH=1;; esac
read -p "安装 OpenClash? [Y/n]: " o
case "$o" in [Nn]*) WITH_OC=0;; *) WITH_OC=1;; esac
[ "$WITH_ADGH" = "1" ] && success "将装入固件(二进制注入): AdGuardHome" || success "不装入 AdGuardHome"
[ "$WITH_OC" = "1" ] && success "将装入固件(核心预装+LuCI编译): OpenClash" || success "不装入 OpenClash"

# DNS 劫持开关（仅主路由且装 ADGH 时生效）：开=重定向 LAN :53 -> ADGH；关=REJECT LAN 出向 :53 强制回退 DHCP DNS
read -p "启用 DNS 劫持(重定向)? [Y/n，选 n 则 reject 出向 :53]: " h
case "$h" in [Nn]*) WITH_DNS_HIJACK=0;; *) WITH_DNS_HIJACK=1;; esac
[ "$WITH_DNS_HIJACK" = "1" ] && success "DNS 劫持(重定向)开启" || success "DNS 劫持关闭(改 REJECT 出向 :53)"

# 确认
echo -e "\n========================================  准备编译  ========================================"
echo "  核心: $CORE | 版本: $VERSION | 配置: $PROFILE | IP: $ROUTER_IP | 类型: $RUN_TYPE"
[[ -n "$GATEWAY_IP" ]] && echo "  网关: $GATEWAY_IP"
[[ -n "$PPPOE_USER" ]] && echo "  PPPoE: $PPPOE_USER"
echo "  ADGH/OC: ADGH=$([ "$WITH_ADGH" = 1 ] && echo 装入 || echo 不装入) / OC=$([ "$WITH_OC" = 1 ] && echo 装入 || echo 不装入)"
echo "  DNS 劫持: $([ "$WITH_DNS_HIJACK" = 1 ] && echo 重定向 || echo REJECT出向53)"
echo "==================================================================================="
read -p "确认开始? [Y/n]: " c; [[ "$c" =~ ^[Nn]$ ]] && exit 0

# ========== 编译 ==========
OPENWRT_DIR="$SCRIPT_DIR/openwrt"
DIY="$SCRIPT_DIR/scripts/diy.sh"
FEEDS_FILE_ABS="$SCRIPT_DIR/$FEEDS_FILE"
FILES_DIR_ABS="$SCRIPT_DIR/$FILES_DIR"

# 1. 换行符（路由器 ash 不兼容 CRLF）：统一修复 scripts/ 与 files/ 下所有脚本及 init.d
echo -e "\n${YELLOW}[1/7] 检查换行符和权限...${NC}"
find "$SCRIPT_DIR/scripts" "$SCRIPT_DIR/$FILES_DIR" "$SCRIPT_DIR/files/common" -type f \
  \( -name "*.sh" -o -name "*.yaml" -o -path "*/init.d/*" \) \
  -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod +x "$DIY" "$SCRIPT_DIR/scripts/upgrade-adgh-binary.sh" "$SCRIPT_DIR/scripts/upgrade-openclash.sh"
success "完成"

# 2. 依赖
echo -e "\n${YELLOW}[2/7] 安装依赖...${NC}"
sudo apt update -y
sudo apt install -y ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk gettext gcc-multilib \
g++-multilib git gnutls-dev gperf haveged help2man intltool lib32gcc-s1 libc6-dev-i386 libelf-dev \
libglib2.0-dev libgmp-dev libltdl-dev libmpc-dev libmpfr-dev libncurses-dev libpython3-dev \
libreadline-dev libssl-dev libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano \
ninja-build p7zip-full patch pkgconf python3 python3-pip python3-ply python3-docutils \
python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig uglifyjs \
upx-ucl unzip vim wget xmlto xxd zlib1g-dev
success "完成"

# 3. 源码（分支取源：fwx 内核栈仅 fanchmwrt-${VERSION} 分支有）
echo -e "\n${YELLOW}[3/7] 拉取源码...${NC}"
SRC_REF="fanchmwrt-${VERSION}"
if [[ -d "$OPENWRT_DIR" ]]; then
    read -p "删除现有目录? [y/N]: " r
    [[ "$r" =~ ^[Yy]$ ]] && rm -rf "$OPENWRT_DIR" || { error_exit "请先删除 $OPENWRT_DIR"; }
fi
if [[ ! -d "$OPENWRT_DIR" ]]; then
    git clone --depth 1 --single-branch --branch "$SRC_REF" "$REPO_URL" "$OPENWRT_DIR" || error_exit "源码克隆失败"
fi
success "完成（取源引用: $SRC_REF）"

# 4. 配置
echo -e "\n${YELLOW}[4/7] 准备配置...${NC}"
cd "$OPENWRT_DIR"
"$DIY" -v "${VERSION%.*}" -p before -t "$RUN_TYPE" --core "$CORE" --feeds "$FEEDS_FILE_ABS"
./scripts/feeds update -a

# ruby YJIT 解耦（仅 WITH_OC 时）：分支头 lang/ruby 默认拉 rust/host 致构建失败，须 install 前执行
if [ "$WITH_OC" = "1" ]; then
  "$SCRIPT_DIR/scripts/diy.sh" -v "${VERSION%.*}" -p ruby -t "$RUN_TYPE" --core "$CORE"
fi

# OpenClash LuCI 替换官方仓库（WITH_OC 时）：feeds update 后、install 前执行
if [ "$WITH_OC" = "1" ]; then
  "$SCRIPT_DIR/scripts/upgrade-openclash.sh" luci "$OPENWRT_DIR"
fi

# AdGuardHome：去除 luci-app 对引擎包(adguardhome)硬依赖，引擎走二进制注入（25.12）
if [ "${VERSION%.*}" = "25.12" ]; then
  ADGH_LUCI_MK="$OPENWRT_DIR/feeds/luci/applications/luci-app-adguardhome/Makefile"
  if [ -f "$ADGH_LUCI_MK" ]; then
    sed -i -e 's/+adguardhome //g' -e '/LUCI_EXTRA_DEPENDS:=adguardhome/d' "$ADGH_LUCI_MK"
    echo "[build] 已去除 luci-app-adguardhome 对 adguardhome 引擎的硬依赖（引擎走二进制注入）"
  else
    echo "[build] 警告: 未找到 luci-app-adguardhome Makefile，跳过依赖去除"
  fi
fi

./scripts/feeds install -a -f

# FanchmWrt：内联最小 .config（target+kmod+apk+fwx+镜像格式/分区，见 configs/fanchmwrt-lean.config），make defconfig 展开
cat "$SCRIPT_DIR/configs/fanchmwrt-lean.config" > .config
sed -i 's/\r$//' .config
# ADGH/OC 选装包：勾选时注入 CONFIG_PACKAGE_*（清单单一来源：configs/{adgh,oc}-packages.list）
# 引擎不编译：AdGuardHome 走 upgrade-adgh-binary.sh 注入二进制；OpenClash 核心走 upgrade-openclash.sh core 预装
_inject_pkg_list() {
  local _list="$1" _label="$2"
  [ -f "$_list" ] || return 0
  {
    echo ""
    echo "# ===== $_label ====="
    while read -r _pkg; do
      [ -n "$_pkg" ] && [ "$_pkg" != \#* ] && echo "CONFIG_PACKAGE_${_pkg}=y"
    done < "$_list"
  } >> .config
  echo "[build] 已追加 $_label（来自 $_list）"
}
[ "$WITH_OC" = "1" ] && _inject_pkg_list "$SCRIPT_DIR/configs/oc-packages.list" "OpenClash 选装包"
[ "$WITH_ADGH" = "1" ] && _inject_pkg_list "$SCRIPT_DIR/configs/adgh-packages.list" "AdGuardHome 选装包"
echo "[build] FanchmWrt: 已写入最小 .config（configs/fanchmwrt-lean.config）+ ADGH/OC 选装包，make defconfig 将展开"

# 用本项目定制 feature.cfg 覆盖 fwxd 自带应用特征库（同为 #format v3.0 应用特征库，可直接替换）
FWXD_CFG="$OPENWRT_DIR/package/fcm/fwxd/files/feature.cfg"
if [[ -f "$SCRIPT_DIR/appfilter-assets/feature.cfg" && -f "$FWXD_CFG" ]]; then
  cp -f "$SCRIPT_DIR/appfilter-assets/feature.cfg" "$FWXD_CFG"
  echo "[build] FanchmWrt: 已用 appfilter-assets/feature.cfg 覆盖 fwxd 应用特征库 (-> /etc/fwxd/feature.cfg)"
elif [[ -f "$SCRIPT_DIR/appfilter-assets/feature.cfg" ]]; then
  echo "[build] 警告: 未找到 fwxd feature.cfg（package/fcm/fwxd/files/feature.cfg），跳过覆盖"
fi
success "完成"

# 5. 网络配置
echo -e "\n${YELLOW}[5/7] 生成网络配置...${NC}"
"$DIY" -v "${VERSION%.*}" -p after -t "$RUN_TYPE" --core "$CORE" --files-dir "$FILES_DIR_ABS" \
  ${ROUTER_IP:+--ip "$ROUTER_IP"} \
  ${GATEWAY_IP:+--gateway "$GATEWAY_IP"} \
  ${BYPASS_PEER_IP:+--bypass-ip "$BYPASS_PEER_IP"} \
  ${PPPOE_USER:+--pppoe-user "$PPPOE_USER"} ${PPPOE_PASS:+--pppoe-pass "$PPPOE_PASS"} \
  --root-pass "$ROOT_PWD"
success "完成"

# 6. 预装核心 + 打包 files
echo -e "\n${YELLOW}[6/7] 预装核心与打包文件...${NC}"
# OpenClash Meta 核心预装（WITH_OC 时）：注入 files/etc/openclash/core/clash_meta，跳过首启下载
if [ "$WITH_OC" = "1" ]; then
  "$SCRIPT_DIR/scripts/upgrade-openclash.sh" core "$SCRIPT_DIR" --files-dir "$FILES_DIR_ABS"
fi
# AdGuardHome 官方预编译二进制注入（WITH_ADGH 时）：注入 files/usr/bin/AdGuardHome；未勾选不注入
if [ "$WITH_ADGH" = "1" ]; then
  "$SCRIPT_DIR/scripts/upgrade-adgh-binary.sh" "$SCRIPT_DIR" --files-dir "$FILES_DIR_ABS"
fi
[[ -d "$FILES_DIR_ABS" ]] && { rm -rf "$OPENWRT_DIR/files"; cp -rf "$FILES_DIR_ABS" "$OPENWRT_DIR/files"; }
# 共享静态文件层（如 cpufreq-perf）：覆盖到核专属 files 之上
[[ -d "$SCRIPT_DIR/files/common" ]] && { cp -rf "$SCRIPT_DIR/files/common/." "$OPENWRT_DIR/files/"; }

# 文件清理：按勾选删除不需要的静态文件（在 openwrt 副本上操作，不修改源树）
case "$RUN_TYPE" in
  bypass)
    # 新拓扑：旁路由与主路由同走 dnsmasq :53 兜底 + ADGH :5353 + 重定向，dns-hijack 保留
    ;;
  main)
    # 未勾选 AdGuardHome：清理 ADGH 静态文件（引擎二进制由 upgrade 脚本注入，未勾选则不注入）
    if [ "$WITH_ADGH" = "0" ]; then
      rm -rf "$OPENWRT_DIR/files/etc/adguardhome"
      rm -f "$OPENWRT_DIR/files/usr/bin/AdGuardHome"
      rm -f "$OPENWRT_DIR/files/etc/init.d/adguardhome"
      rm -f "$OPENWRT_DIR/files/etc/config/adguardhome"
      rm -f "$OPENWRT_DIR/files/etc/hotplug.d/iface/99-adgh-filters"
    fi
    # 未装 ADGH 或关闭劫持(改用 REJECT)：dns-hijack 脚本不再使用
    if [ "$WITH_ADGH" = "0" ] || [ "$WITH_DNS_HIJACK" = "0" ]; then
      rm -f "$OPENWRT_DIR/files/usr/sbin/dns-hijack"
    fi
    # 未勾选 OpenClash：清理 OC 静态文件
    if [ "$WITH_OC" = "0" ]; then
      rm -rf "$OPENWRT_DIR/files/etc/openclash"
    fi
    ;;
esac

# 离线 .apk + 在线 lists：拷入镜像首启安装目录（由 firstboot-pkgs 用 --allow-untrusted 安装）
mkdir -p "$OPENWRT_DIR/files/etc/firstboot-pkgs/apps"
cp -f "$SCRIPT_DIR/apps/"*.apk "$OPENWRT_DIR/files/etc/firstboot-pkgs/apps/" 2>/dev/null || true
mkdir -p "$OPENWRT_DIR/files/etc/firstboot-pkgs/lists"
cp -f "$SCRIPT_DIR/lists/common.txt" "$OPENWRT_DIR/files/etc/firstboot-pkgs/lists/" 2>/dev/null || true
cp -f "$SCRIPT_DIR/lists/default.txt" "$OPENWRT_DIR/files/etc/firstboot-pkgs/lists/" 2>/dev/null || true
# DNS 劫持开关标记（1=重定向 LAN :53 -> ADGH；0=REJECT LAN 出向 :53 强制回退 DHCP DNS）；firstboot-pkgs 读取
echo "$WITH_DNS_HIJACK" > "$OPENWRT_DIR/files/etc/firstboot-pkgs/dns_hijack" 2>/dev/null || true

# 确保脚本可执行（Windows 无 Unix x 位，按路径/扩展名匹配）
find "$OPENWRT_DIR/files" -type f \( -path "*/sbin/*" -o -path "*/init.d/*" -o -path "*/hotplug.d/*" -o -path "*/uci-defaults/*" -o -name "*.sh" \) -exec chmod 755 {} + 2>/dev/null || true
make defconfig && make download && make clean
success "完成"

# 7. 编译
echo -e "\n${YELLOW}[7/7] 编译固件...${NC}"
make -j$(nproc) || make -j1 V=s

echo -e "\n${GREEN}========================================  编译完成!  ========================================${NC}"
echo "固件位置: $OPENWRT_DIR/bin/targets/x86/64/"
ls -la "$OPENWRT_DIR/bin/targets/x86/64/"*combined*.img.gz 2>/dev/null || true
