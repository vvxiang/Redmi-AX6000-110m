#!/bin/bash
#=================================================
# Copyright (c) 2019-2023 sky2016cn
# Author: sky2016cn
# licensed under the MIT License
# See /LICENSE for more information
# Description: Build OpenWrt using GitHub Actions
#=================================================
#1. Modify default IP
sed -i 's/192.168.1.1/192.168.100.1/g' /builder/openwrt/package/base-files/files/bin/config_generate

#2. 修改默认皮肤
sed -i 's/+luci-theme-bootstrap/+luci-theme-argon/g' /builder/openwrt/feeds/luci/collections/luci/Makefile

#3. Replace with JerryKuKu’s Argon
#rm /builder/openwrt/package/lean/luci-theme-argon -rf

#4. Modify hostname
sed -i 's/ImmortalWrt/RedmiWrt/g' /builder/openwrt/package/base-files/files/bin/config_generate

# ========== 新增：生成uci-defaults 首次开机自动配置 LAN IP + WiFi ==========
# 源码内files目录，编译时打包进固件
#mkdir -p /builder/openwrt/files/etc/uci-defaults

#cat > /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip <<'EOF'
##!/bin/sh

# 设置LAN IP
# uci set network.lan.ipaddr='192.168.16.1'
# uci set network.lan.netmask='255.255.255.0'

# 2.4G radio0
#uci set wireless.radio0.disabled='0'
#uci set wireless.radio0.country='CN'
#uci set wireless.default_radio0.ssid='MT7968_AX6000_2.4G'
#uci set wireless.default_radio0.encryption='psk2+ccmp'
#uci set wireless.default_radio0.key='xwvv#642531'

# 5G radio1
#uci set wireless.radio1.disabled='0'
#uci set wireless.radio1.country='CN'
#uci set wireless.default_radio1.ssid='MT7968_AX6000_5G'
#uci set wireless.default_radio1.encryption='psk2+ccmp'
#uci set wireless.default_radio1.key='xwvv#642531'

#uci commit network
#uci commit wireless
#exit 0
#EOF

# ========== 4. 生成 uci-defaults 首次开机自动配置无线 WiFi ==========
# files 目录会在编译时直接打包进固件的根系统
mkdir -p /builder/openwrt/files/etc/uci-defaults

cat > /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip <<'EOF'
#!/bin/sh

# 开启无线硬件
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country='CN'
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='CN'

# 【完美适配 24.10/25.12】动态遍历所有无线接口，绑定对应的 SSID 和加密密码
# 解决新版源码中接口名可能叫 wifinet0 或 default_radio0 的不确定性
idx=0
while true; do
    device=$(uci -q get wireless.@wifi-iface[$idx].device)
    [ -z "$device" ] && break

    if [ "$device" = "radio0" ]; then
        # 配置 2.4G 无线参数
        uci set wireless.@wifi-iface[$idx].ssid='MT7968_AX6000_2.4G'
        uci set wireless.@wifi-iface[$idx].encryption='psk2+ccmp'
        uci set wireless.@wifi-iface[$idx].key='xwvv#642531'
    elif [ "$device" = "radio1" ]; then
        # 配置 5G 无线参数
        uci set wireless.@wifi-iface[$idx].ssid='MT7968_AX6000_5G'
        uci set wireless.@wifi-iface[$idx].encryption='psk2+ccmp'
        uci set wireless.@wifi-iface[$idx].key='xwvv#642531'
    fi
    idx=$((idx + 1))
done

# 提交并应用无线配置
uci commit wireless
exit 0
EOF
# 赋予开机自启脚本可执行权限
chmod +x /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
#chmod +x /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
