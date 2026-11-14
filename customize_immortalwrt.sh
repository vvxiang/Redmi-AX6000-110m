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

# ========== 新增：生成uci-defaults 首次开机自动配置 LAN IP + WiFi ==========
# 源码内files目录，编译时打包进固件
mkdir -p /builder/openwrt/files/etc/uci-defaults

cat > /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip <<'EOF'
#!/bin/sh

# 2.4G radio0
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country='CN'
uci set wireless.default_radio0.ssid='MT7968_AX6000_2.4G'
uci set wireless.default_radio0.encryption='psk2+ccmp'

# 5G radio1
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='CN'
uci set wireless.default_radio1.ssid='MT7968_AX6000_5G'
uci set wireless.default_radio1.encryption='psk2+ccmp'
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
