#!/bin/bash
#=================================================
# Copyright (c) 2019-2023 sky2016cn
# Author: sky2016cn
# licensed under the MIT License
# See /LICENSE for more information
# Description: Build OpenWrt using GitHub Actions
#=================================================
# Modify hostname
sed -i 's/ImmortalWrt/ImmortalWrt/g' /builder/openwrt/package/base-files/files/bin/config_generate

# 1. 预置全局共享的 GeoIP & GeoSite 规则库 (PassWall 与 daed 共用)
mkdir -p /builder/openwrt/files/usr/share/v2ray
mkdir -p /builder/openwrt/files/usr/share/daed

curl -fsSL "https://github.com" -o /builder/openwrt/files/usr/share/v2ray/geoip.dat
curl -fsSL "https://github.com" -o /builder/openwrt/files/usr/share/v2ray/geosite.dat

# 创建软链接映射给 daed (零额外空间占用)
ln -sf /usr/share/v2ray/geoip.dat /builder/openwrt/files/usr/share/daed/geoip.dat
ln -sf /usr/share/v2ray/geosite.dat /builder/openwrt/files/usr/share/daed/geosite.dat

# 2. 生成 uci-defaults 首次开机自动配置
mkdir -p /builder/openwrt/files/etc/uci-defaults

cat > /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip <<'EOF'
#!/bin/sh

# 2.4G radio0 基础配置
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country='CN'
uci set wireless.default_radio0.ssid='MT7968_AX6000_2.4G'
uci set wireless.default_radio0.encryption='psk2+ccmp'

# 5G radio1 基础配置
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='CN'
uci set wireless.default_radio1.ssid='MT7968_AX6000_5G'
uci set wireless.default_radio1.encryption='psk2+ccmp'

# 防火墙安全与兼容 daed/PassWall 深度优化
uci set firewall.@defaults.synflood_protect='1'
uci set firewall.@defaults.drop_invalid='1'
uci set firewall.@defaults.input='ACCEPT'
uci set firewall.@defaults.output='ACCEPT'
uci set firewall.@defaults.forward='REJECT'
uci delete firewall.@defaults.flow_offloading 2>/dev/null
uci delete firewall.@defaults.flow_offloading_hw 2>/dev/null
uci set firewall.@defaults.fullcone='1'
uci commit firewall

# 调大系统最大连接数并开启 BBR 拥塞控制
cat << 'SYSCTL' >> /etc/sysctl.conf
net.netfilter.nf_conntrack_max=65536
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL
sysctl -p >/dev/null 2>&1
EOF

# 安全注入 2.4G & 5G WiFi 密码
printf "uci set wireless.default_radio0.key='%s'\n" "$WIFI_PASS" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
printf "uci set wireless.default_radio1.key='%s'\n" "$WIFI_PASS" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
printf "uci commit wireless\n" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip

# 安全注入后台 root 登录密码
printf "printf '%%s\\\\n%%s\\\\n' '%s' '%s' | passwd root >/dev/null 2>&1\n" "$ROOT_PASS" "$ROOT_PASS" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip

# 安全注入 PPPoE 宽带账号与密码
printf "uci set network.wan.proto='pppoe'\n" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
printf "uci set network.wan.username='%s'\n" "$PPPOE_USER" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
printf "uci set network.wan.password='%s'\n" "$PPPOE_PASS" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
printf "uci commit network\nexit 0\n" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip

chmod +x /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
