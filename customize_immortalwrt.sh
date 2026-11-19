#!/bin/bash
#=================================================
# Copyright (c) 2019-2023 sky2016cn
# Author: sky2016cn
# licensed under the MIT License
# See /LICENSE for more information
# Description: Build OpenWrt using GitHub Actions
#=================================================

# 修改默认主机名
sed -i 's/ImmortalWrt/ImmortalWrt/g' /builder/openwrt/package/base-files/files/bin/config_generate

# 1. 预置 PassWall 所需的 GeoIP & GeoSite 规则库
mkdir -p /builder/openwrt/files/usr/share/v2ray

DAT_HOST="https://github.com/Loyalsoldier"
DAT_REPO="v2ray-rules-dat/releases/latest/download"

curl -fsSL "${DAT_HOST}/${DAT_REPO}/geoip.dat" -o /builder/openwrt/files/usr/share/v2ray/geoip.dat
curl -fsSL "${DAT_HOST}/${DAT_REPO}/geosite.dat" -o /builder/openwrt/files/usr/share/v2ray/geosite.dat

# 2. 生成 uci-defaults 首次开机自动初始化脚本
mkdir -p /builder/openwrt/files/etc/uci-defaults

cat > /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip <<'EOF'
#!/bin/sh

# 2.1 开启并配置 2.4G radio0 基础无线参数
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country='CN'
uci set wireless.default_radio0.ssid='MT7968_AX6000_2.4G'
uci set wireless.default_radio0.encryption='psk2+ccmp'

# 2.2 开启并配置 5G radio1 基础无线参数
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='CN'
uci set wireless.default_radio1.ssid='MT7968_AX6000_5G'
uci set wireless.default_radio1.encryption='psk2+ccmp'

# 2.3 防火墙安全与兼容 PassWall 深度优化（关闭硬件加速防规则绕过，开启 FullCone NAT）
uci set firewall.@defaults.synflood_protect='1'
uci set firewall.@defaults.drop_invalid='1'
uci set firewall.@defaults.input='ACCEPT'
uci set firewall.@defaults.output='ACCEPT'
uci set firewall.@defaults.forward='REJECT'
uci delete firewall.@defaults.flow_offloading 2>/dev/null
uci delete firewall.@defaults.flow_offloading_hw 2>/dev/null
uci set firewall.@defaults.fullcone='1'
uci commit firewall

# 2.4 调大系统最大连接数并开启 BBR 拥塞控制 + FQ 队列
cat << 'SYSCTL' >> /etc/sysctl.conf
net.netfilter.nf_conntrack_max=65536
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL
sysctl -p >/dev/null 2>&1

# 2.5 首次开机联网后，后台全自动下载并安装最新版 AdGuard Home 官方内核进闪存（零手动干预）
cat << 'AGH_AUTO' > /etc/adguardhome_auto_install.sh
#!/bin/sh
# 等待 45 秒确保宽带 PPPoE 拨号及 PassWall 代理均已顺利连通
sleep 45

# 读取助手配置的内核存放路径（默认位于闪存 /usr/bin/AdGuardHome）
CORE_PATH=$(uci -q get adguardhome_lite.config.core_path || echo "/usr/bin/AdGuardHome")
mkdir -p "$(dirname "$CORE_PATH")"

# 若内核尚未安装，则通过国内高速镜像下载最新 arm64 官方正式版核心并解压安装
if [ ! -x "$CORE_PATH" ]; then
    DL_URL="https://gh-proxy.org"
    if curl -fsSL --connect-timeout 15 --max-time 120 "$DL_URL" -o /tmp/agh_latest.tar.gz; then
        tar -xzf /tmp/agh_latest.tar.gz -C /tmp/
        if [ -f /tmp/AdGuardHome/AdGuardHome ]; then
            mv -f /tmp/AdGuardHome/AdGuardHome "$CORE_PATH"
            chmod +x "$CORE_PATH"
            rm -rf /tmp/AdGuardHome /tmp/agh_latest.tar.gz
            # 内核安装完成后，自动重启 AdGuard Home 助手服务使其立即上线工作
            /etc/init.d/adguardhome_lite restart >/dev/null 2>&1 || true
        fi
    fi
fi
# 执行完毕后自动删除自身临时脚本，保持系统纯净
rm -f /etc/adguardhome_auto_install.sh
AGH_AUTO

chmod +x /etc/adguardhome_auto_install.sh
# 放入后台异步执行，完全不阻塞正常开机流程
/etc/adguardhome_auto_install.sh >/dev/null 2>&1 &
EOF

# 3. 安全注入 2.4G & 5G WiFi 密码（从 GitHub Secrets 读取）
printf "uci set wireless.default_radio0.key='%s'\n" "$WIFI_PASS" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
printf "uci set wireless.default_radio1.key='%s'\n" "$WIFI_PASS" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
printf "uci commit wireless\n" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip

# 4. 安全注入后台 root 登录密码
printf "printf '%%s\\\\n%%s\\\\n' '%s' '%s' | passwd root >/dev/null 2>&1\n" "$ROOT_PASS" "$ROOT_PASS" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip

# 5. 安全注入 PPPoE 宽带账号与密码
printf "uci set network.wan.proto='pppoe'\n" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
printf "uci set network.wan.username='%s'\n" "$PPPOE_USER" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
printf "uci set network.wan.password='%s'\n" "$PPPOE_PASS" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
printf "uci commit network\nexit 0\n" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip

chmod +x /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip

# 6. 自动还原加密注入的 PassWall 配置文件
if [ -n "$PASSWALL_CONF_B64" ]; then
  mkdir -p /builder/openwrt/files/etc/config
  echo "$PASSWALL_CONF_B64" | base64 -d > /builder/openwrt/files/etc/config/passwall
  chmod 0600 /builder/openwrt/files/etc/config/passwall
  echo "✅ PassWall 配置文件已成功打包进固件！"
fi
