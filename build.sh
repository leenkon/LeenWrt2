#!/bin/bash
# LeenWrt 本地编译脚本（Debian/Ubuntu）
# 单核心由 cores/<core>.conf 驱动：leenwrt(fork 自 immortalwrt 上游, OC/ADGH 全功能)。
# 用法: chmod +x build.sh && ./build.sh

set -e

# 颜色定义
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
error_exit() { echo -e "${RED}错误：$1${NC}" >&2; exit 1; }
success() { echo -e "${GREEN}[OK] $1${NC}"; }

# 默认配置
DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.2"
DEF_GATEWAY="10.10.10.1"
ROOT_PASSWORD="password"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_CONF_DIR="$SCRIPT_DIR/cores"

# ========== 核心描述（单核 leenwrt） ==========
echo "========================================"
echo "    路由固件本地编译脚本"
echo "========================================"
CORE="leenwrt"
CORE_CONF="$CORE_CONF_DIR/$CORE.conf"
[ -f "$CORE_CONF" ] || error_exit "缺失核心描述: $CORE_CONF"
# shellcheck disable=SC1090
source "$CORE_CONF"
success "核心: $CORE ($REPO_URL)"

# ========== 版本选择（来自核心描述 VERSION_OPTIONS） ==========
echo -e "\n请选择 $CORE 版本："
i=1
for v in $VERSION_OPTIONS; do echo "  $i) $v"; i=$((i+1)); done
read -p "请输入选择 [1-$(($i-1))，默认 1]: " vsel
vsel=${vsel:-1}
VERSION=$(echo $VERSION_OPTIONS | awk -v n="$vsel" '{print $n}')
[ -n "$VERSION" ] || error_exit "无效选择"
success "版本: $VERSION"

# ========== 配置选择 ==========
echo -e "\n请选择编译配置："
echo "  1) Full (完整路由/主路由)  2) Mini (旁路由)"
read -p "请输入选择 [1-2，默认 1]: " p
p=${p:-1}
case "$p" in 1) PROFILE="Full";; 2) PROFILE="Mini";; *) error_exit "无效选择";; esac

# 解析配置（Full = 完整路由/主路由基底；Mini = 旁路由 bypass）
case "$PROFILE" in
  Full) CFG_PREFIX=full; RUN_TYPE=full;;
  Mini) CFG_PREFIX=mini; RUN_TYPE=bypass;;
  *) error_exit "无效配置: $PROFILE";;
esac
MAIN_VER=${VERSION%.*}

# 自定义IP
echo -e "\n[LAN IP]"
[[ "$RUN_TYPE" == "bypass" ]] && DEF_IP="$DEF_BYPASS_IP" || DEF_IP="$DEF_MAIN_IP"
read -p "自定义LAN IP [默认: $DEF_IP，回车跳过]: " custom_ip
ROUTER_IP="${custom_ip:-$DEF_IP}"
success "LAN IP: $ROUTER_IP"

# 网关(仅旁路由)
GATEWAY_IP=""
[[ "$RUN_TYPE" == "bypass" ]] && { read -p "网关IP [默认: $DEF_GATEWAY]: " gw; GATEWAY_IP="${gw:-$DEF_GATEWAY}"; success "网关: $GATEWAY_IP"; }

# PPPoE (完整路由)
PPPOE_USER="" PPPOE_PASS=""
[[ "$RUN_TYPE" == "full" ]] && { read -p "配置PPPoE? [y/N]: " pp; [[ "$pp" =~ ^[Yy]$ ]] && { read -p "用户名: " PPPOE_USER; read -p "密码: " PPPOE_PASS; success "PPPoE已配置"; } || success "使用DHCP"; }

# OC / ADGH：旁路由(Mini)固定启用；完整路由(Full)由下方交互勾选决定
WITH_OC="false"; WITH_ADGH="false"
if [[ "$RUN_TYPE" == "bypass" ]]; then
  WITH_OC=true; WITH_ADGH=true
else
  read -p "包含 OpenClash 代理? [Y/n]: " oc; WITH_OC=true; [[ "$oc" =~ ^[Nn]$ ]] && WITH_OC="false"
  read -p "包含 AdGuardHome 去广告? [Y/n]: " adgh; WITH_ADGH=true; [[ "$adgh" =~ ^[Nn]$ ]] && WITH_ADGH="false"
fi
NO_ADGH="false"; [ "$WITH_ADGH" = "false" ] && NO_ADGH="true"


# 同理，OC 仅显式开启时才传 --with-oc（避免 "false" 非空串误展开）
OC_FLAG=""
[ "$WITH_OC" = "true" ] && OC_FLAG="--with-oc"

# Root密码
read -p "Root密码 [默认: password]: " rp
ROOT_PWD="${rp:-$ROOT_PASSWORD}"
success "密码已设置"

# 确认
echo -e "\n========================================  准备编译  ========================================"
echo "  核心: $CORE | 版本: $VERSION | 配置: $PROFILE | IP: $ROUTER_IP | 类型: $RUN_TYPE"
[[ -n "$GATEWAY_IP" ]] && echo "  网关: $GATEWAY_IP"
[[ -n "$PPPOE_USER" ]] && echo "  PPPoE: $PPPOE_USER"
echo "==================================================================================="
read -p "确认开始? [Y/n]: " c; [[ "$c" =~ ^[Nn]$ ]] && exit 0

# ========== 编译 ==========
OPENWRT_DIR="$SCRIPT_DIR/openwrt"
DIY="$SCRIPT_DIR/scripts/diy.sh"
FEEDS_FILE_ABS="$SCRIPT_DIR/$FEEDS_FILE"
FILES_DIR_ABS="$SCRIPT_DIR/$FILES_DIR"

# 1. 换行符（路由器 ash 不兼容 CRLF）：统一修复 scripts/ 与 files/ 下所有脚本、YAML 及 init.d
echo -e "\n${YELLOW}[1/7] 检查换行符和权限...${NC}"
find "$SCRIPT_DIR/scripts" "$SCRIPT_DIR/$FILES_DIR" -type f \
  \( -name "*.sh" -o -name "*.yaml" -o -name "dns-hijack" -o -name "99-adgh-filters" -o -path "*/init.d/*" \) \
  -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod +x "$DIY" "$SCRIPT_DIR/build.sh" "$SCRIPT_DIR/scripts/upgrade-adgh-binary.sh" "$SCRIPT_DIR/scripts/upgrade-openclash-core.sh" "$SCRIPT_DIR/scripts/upgrade-openclash-luci.sh"
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

# 3. 源码
echo -e "\n${YELLOW}[3/7] 拉取源码...${NC}"
# 取源引用：leenwrt 用上游 tag（v${VERSION}）克隆检出
SRC_REF="${REF_PREFIX}${VERSION}"
if [[ -d "$OPENWRT_DIR" ]]; then
    read -p "删除现有目录? [y/N]: " r
    [[ "$r" =~ ^[Yy]$ ]] && rm -rf "$OPENWRT_DIR" || { error_exit "请先删除 $OPENWRT_DIR"; }
fi
if [[ ! -d "$OPENWRT_DIR" ]]; then
    # 直接按 SRC_REF（tag/分支）克隆检出，避免浅克隆 fetch 后无本地 ref 致 checkout 失败
    git clone --depth 1 --single-branch --branch "$SRC_REF" "$REPO_URL" "$OPENWRT_DIR" || error_exit "源码克隆失败"
fi
success "完成（取源引用: $SRC_REF）"

# 4. 配置
echo -e "\n${YELLOW}[4/7] 准备配置...${NC}"
cd "$OPENWRT_DIR"
"$DIY" -v "$MAIN_VER" -p before -t "$RUN_TYPE" --feeds "$FEEDS_FILE_ABS"
./scripts/feeds update -a

# ruby YJIT 解耦（分支头 ruby 默认拉 rust/host 致构建失败；仅 WITH_OC 时）
if [[ "$WITH_OC" == "true" ]]; then
  "$DIY" -v "$MAIN_VER" -p ruby -t "$RUN_TYPE"
fi

# OpenClash LuCI 替换（仅 Mini 旁路由 / Full 勾选 OC 时）
if [[ "$WITH_OC" == "true" ]]; then
  "$SCRIPT_DIR/scripts/upgrade-openclash-luci.sh" "$OPENWRT_DIR"
fi

# AdGuardHome LuCI 壳去除对引擎包(adguardhome)的硬依赖（leenwrt 25.12；引擎走二进制注入）
if [[ "$MAIN_VER" = "25.12" ]]; then
  ADGH_LUCI_MK="$OPENWRT_DIR/feeds/luci/applications/luci-app-adguardhome/Makefile"
  if [ -f "$ADGH_LUCI_MK" ]; then
    sed -i -e 's/+adguardhome //g' -e '/LUCI_EXTRA_DEPENDS:=adguardhome/d' "$ADGH_LUCI_MK"
    echo "[build] 已去除 luci-app-adguardhome 对 adguardhome 的硬依赖（引擎走二进制注入）"
  else
    echo "[build] 警告: 未找到 luci-app-adguardhome Makefile，跳过依赖去除"
  fi
fi

./scripts/feeds install -a -f

# leenwrt：直接套用本地 .config 种子（configs/${CONFIG_PREFIX}-${CFG_PREFIX}.config）
cp "$SCRIPT_DIR/configs/${CONFIG_PREFIX}-${CFG_PREFIX}.config" .config || error_exit "配置文件不存在: configs/${CONFIG_PREFIX}-${CFG_PREFIX}.config"
sed -i 's/\r$//' .config


# OpenClash / AdGuardHome 选装包（勾选时注入，清单单一来源 configs/{oc,adgh}-packages.list）
_inject_pkg_list() {
  local _list="$1" _label="$2"
  [ -f "$_list" ] || return 0
  {
    echo ""
    echo "# ===== $_label ====="
    while read -r _pkg; do
      [[ -n "$_pkg" && "$_pkg" != \#* ]] && echo "CONFIG_PACKAGE_${_pkg}=y"
    done < "$_list"
  } >> .config
  echo "[build] 已追加 $_label（来自 $_list）"
}
[ "$WITH_OC" = "true" ] && _inject_pkg_list "$SCRIPT_DIR/configs/oc-packages.list" "OpenClash 选装包"
[ "$WITH_ADGH" = "true" ] && _inject_pkg_list "$SCRIPT_DIR/configs/adgh-packages.list" "AdGuardHome 选装包"

success "完成"

# 5. 网络配置
echo -e "\n${YELLOW}[5/7] 生成网络配置...${NC}"
# --no-adgh 仅在 NO_ADGH=true 时传入（Full 未勾选 AdGuardHome 时）
NOADGH_ARG=""
[ "$NO_ADGH" = "true" ] && NOADGH_ARG="--no-adgh"
"$DIY" -v "$MAIN_VER" -p after -t "$RUN_TYPE" --files-dir "$FILES_DIR_ABS" \
  ${ROUTER_IP:+--ip "$ROUTER_IP"} \
  ${GATEWAY_IP:+--gateway "$GATEWAY_IP"} \
  ${PPPOE_USER:+--pppoe-user "$PPPOE_USER"} ${PPPOE_PASS:+--pppoe-pass "$PPPOE_PASS"} \
  ${NOADGH_ARG:+"$NOADGH_ARG"} \
  ${OC_FLAG} \
  --root-pass "$ROOT_PWD"
success "完成"

# 6. 预装核心 + 打包 files
echo -e "\n${YELLOW}[6/7] 预装核心与打包文件...${NC}"
# OpenClash Meta 核心预装（仅 Mini 旁路由 / Full 勾选 OC 时）
if [[ "$WITH_OC" == "true" ]]; then
    "$SCRIPT_DIR/scripts/upgrade-openclash-core.sh" "$SCRIPT_DIR" --files-dir "$FILES_DIR_ABS"
fi
# AdGuardHome 官方预编译二进制注入（仅 Mini 旁路由 / Full 勾选 AdGuardHome 时；未勾选时不注入）
if [[ "$WITH_ADGH" == "true" ]]; then
    "$SCRIPT_DIR/scripts/upgrade-adgh-binary.sh" "$SCRIPT_DIR" --files-dir "$FILES_DIR_ABS"
fi
[[ -d "$FILES_DIR_ABS" ]] && { rm -rf "$OPENWRT_DIR/files"; cp -rf "$FILES_DIR_ABS" "$OPENWRT_DIR/files"; }

# 离线 .apk：拷入镜像首启安装目录 /etc/firstboot-pkgs/apps/（由 firstboot-pkgs 用 --allow-untrusted 安装）
mkdir -p "$OPENWRT_DIR/files/etc/firstboot-pkgs/apps"
shopt -s nullglob
_copied=0
for _apk in "$SCRIPT_DIR/apps/"*.apk; do
  cp -f "$_apk" "$OPENWRT_DIR/files/etc/firstboot-pkgs/apps/"
  _copied=$((_copied + 1))
done
shopt -u nullglob
if [ "$_copied" -gt 0 ]; then
  success "已拷贝 $_copied 个离线 .apk 到镜像首启安装目录"
else
  echo "[build] 警告: apps/ 下无 .apk，自定义离线包将不会随固件安装"
fi

# 文件清理：按勾选删除不需要的静态文件（在 openwrt 副本上操作，不修改源树）
case "$RUN_TYPE" in
  bypass)
    rm -f "$OPENWRT_DIR/files/usr/sbin/dns-hijack"
    ;;
  full)
    # 未勾选 AdGuardHome：清理 ADGH 静态文件，且不劫持 DNS(dnsmasq 占 :53)
    if [ "$WITH_ADGH" = "false" ]; then
      rm -rf "$OPENWRT_DIR/files/etc/adguardhome"
      rm -f "$OPENWRT_DIR/files/usr/bin/AdGuardHome"
      rm -f "$OPENWRT_DIR/files/etc/init.d/adguardhome"
      rm -f "$OPENWRT_DIR/files/etc/config/adguardhome"
      rm -f "$OPENWRT_DIR/files/usr/sbin/dns-hijack"
    fi
    # 未勾选 OpenClash：清理 OC 静态文件
    if [ "$WITH_OC" = "false" ]; then
      rm -rf "$OPENWRT_DIR/files/etc/openclash"
    fi
    ;;
esac
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
