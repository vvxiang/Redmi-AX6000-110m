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
uci add_list firewall.@zone[0].device='tailscale0'

# 彻底清理 WAN/LAN 接口上的 IPv6 配置与 ULA 局域网 IPv6 前缀
uci delete network.wan6 2>/dev/null
uci delete network.globals.ula_prefix 2>/dev/null
uci set network.wan.ipv6='0'
uci set network.lan.ipv6='0'
uci set network.lan.delegate='0'
uci delete dhcp.lan.ra 2>/dev/null
uci delete dhcp.lan.dhcpv6 2>/dev/null

uci commit network
uci commit dhcp
uci commit firewall

# 2.4 调大系统最大连接数、开启 BBR 拥塞控制，并从内核运行时彻底禁用 IPv6（消除所有 fe80:: 本地地址）
cat << 'SYSCTL' >> /etc/sysctl.conf
net.netfilter.nf_conntrack_max=65536
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
SYSCTL
sysctl -p >/dev/null 2>&1

# 2.5 自动启用纯官方 Tailscale 后台服务，并使用 Auth Key 免扫码全自动登录与宣告子网路由
cat << 'TS_AUTO' > /etc/tailscale_auto_up.sh
#!/bin/sh
sleep 35
if [ -x /etc/init.d/tailscale ]; then
    /etc/init.d/tailscale enable
    /etc/init.d/tailscale start
    sleep 5
    TS_KEY="__TS_AUTHKEY_PLACEHOLDER__"
    if [ -n "$TS_KEY" ] && [ "$TS_KEY" != "__TS_AUTHKEY_PLACEHOLDER__" ]; then
        tailscale up --authkey="$TS_KEY" --advertise-routes=192.168.100.0/24 --accept-routes=false --accept-dns=false --snat-subnet-routes=true >/dev/null 2>&1 &
    else
        tailscale up --advertise-routes=192.168.100.0/24 --accept-routes=false --accept-dns=false --snat-subnet-routes=true >/dev/null 2>&1 &
    fi
fi
rm -f /etc/tailscale_auto_up.sh
TS_AUTO

chmod +x /etc/tailscale_auto_up.sh
/etc/tailscale_auto_up.sh >/dev/null 2>&1 &
EOF

# 安全将 GitHub Secrets 中的 TS_AUTHKEY 替换进路由器的首次开机初始化脚本中
if [ -n "$TS_AUTHKEY" ]; then
    sed -i "s|__TS_AUTHKEY_PLACEHOLDER__|${TS_AUTHKEY}|g" /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
fi


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
