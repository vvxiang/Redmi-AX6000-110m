#!/bin/bash
#=================================================
# Copyright (c) 2019-2023 sky2016cn
# Author: sky2016cn
# licensed under the MIT License
# See /LICENSE for more information
# Description: Build OpenWrt using GitHub Actions
# 修复版：修正 UCI 匿名段语法 + 补齐 WED 硬件加速配置
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
uci set wireless.default_radio0.ssid='MT7986_AX6000_2.4G'
uci set wireless.default_radio0.encryption='psk2+ccmp'

# 2.2 开启并配置 5G radio1 基础无线参数
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='CN'
uci set wireless.default_radio1.ssid='MT7986_AX6000_5G'
uci set wireless.default_radio1.encryption='psk2+ccmp'
uci set wireless.radio1.htmode='HE160'
uci set wireless.radio1.channel='36'

# 2.3 防火墙安全与千兆硬件加速优化
# 【修复】匿名 section 必须写成 @defaults[0]，原代码 @defaults 缺少索引会导致 uci set 失败，
#         结果是 flow_offloading / flow_offloading_hw 根本没有生效，硬件加速完全没开。
uci set firewall.@defaults[0].synflood_protect='1'
uci set firewall.@defaults[0].drop_invalid='1'
uci set firewall.@defaults[0].input='ACCEPT'
uci set firewall.@defaults[0].output='ACCEPT'
uci set firewall.@defaults[0].forward='REJECT'
uci set firewall.@defaults[0].flow_offloading='1'
# 【关键】关闭硬件流量卸载：Tailscale 底层是 WireGuard，其与 hw flow offload 有已知兼容性问题
# （加密流量被 PPE 旁路，导致节点在线但数据通道不通）。软件卸载仍能跑满千兆且不碰 WireGuard。
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci set firewall.@defaults[0].fullcone='1'

# 【修复】zone 也是匿名 section 且有多个(lan/wan)，原写法 @zone 无索引会失败。
#         这里按 name 精确找到 lan zone 再把 tailscale0 加进去。
for z in $(uci show firewall 2>/dev/null | sed -n 's/^\(firewall\.@zone\[[0-9]*\]\)\.name=.*/\1/p'); do
    if [ "$(uci get ${z}.name 2>/dev/null)" = "lan" ]; then
        uci add_list ${z}.device='tailscale0'
    fi
done

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

# 2.4 调大系统最大连接数、开启 BBR 拥塞控制，并从内核运行时彻底禁用 IPv6
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

# 2.5 自动启用 Tailscale：等待网络就绪后登录，失败自动重试，全程写日志
cat << 'TS_GUARD' > /etc/tailscale_guard.sh
#!/bin/sh
TS_KEY="__TS_AUTHKEY_PLACEHOLDER__"
LOG="/var/log/tailscale-guard.log"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
log "guard started"

/etc/init.d/tailscale enable >/dev/null 2>&1
/etc/init.d/tailscale start >/dev/null 2>&1

# 等待 PPPoE 拿到默认路由（最多 3 分钟），避免网络未就绪时登录失败
for i in $(seq 1 60); do
    ip route 2>/dev/null | grep -q '^default' && break
    sleep 3
done
log "network wait done"

# 最多重试 10 次（间隔 30 秒），确认已登录后退出
for i in $(seq 1 10); do
    if tailscale status 2>&1 | grep -qiE 'logged out|needs login|not logged'; then
        if [ -n "$TS_KEY" ] && [ "$TS_KEY" != "__TS_AUTHKEY_PLACEHOLDER__" ]; then
            log "attempt $i: tailscale up with authkey"
            tailscale up --authkey="$TS_KEY" --advertise-routes=192.168.100.0/24 \
                --accept-routes=false --accept-dns=false --snat-subnet-routes=true >>"$LOG" 2>&1
        else
            log "TS_AUTHKEY not injected, skip"
            break
        fi
    else
        log "tailscale already logged in"
        break
    fi
    sleep 30
done
log "guard exit"
TS_GUARD

chmod +x /etc/tailscale_guard.sh
nohup /etc/tailscale_guard.sh >/dev/null 2>&1 &
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
printf "uci set network.wan.peerdns='0'\n" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
printf "uci set network.wan.dns='223.5.5.5 119.29.29.29'\n" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip
printf "uci commit network\nexit 0\n" >> /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip

chmod +x /builder/openwrt/files/etc/uci-defaults/99-set-default-wifi-ip

# 6. 自动还原加密注入的 PassWall 配置文件
if [ -n "$PASSWALL_CONF_B64" ]; then
  mkdir -p /builder/openwrt/files/etc/config
  echo "$PASSWALL_CONF_B64" | base64 -d > /builder/openwrt/files/etc/config/passwall
  chmod 0600 /builder/openwrt/files/etc/config/passwall
  echo "✅ PassWall 配置文件已成功打包进固件！"
fi

# 7. 【关键新增】开启 MT7986 5G 无线硬件加速 WED
# 原代码注释声称"启用 WED"，但通篇没有任何实际写入，导致无线流量全靠 CPU 软转发。
# 按 OpenWrt 官方文档，OpenWrt 24.10+（含 25.12）需写入 /etc/modules.conf。
mkdir -p /builder/openwrt/files/etc
echo 'options mt7915e wed_enable=Y' > /builder/openwrt/files/etc/modules.conf
echo "✅ 已为 MT7986 5G  radio 开启 WED 硬件加速 (wed_enable=Y)"

# 8. 写入 SSH 登录欢迎横幅
BUILD_TAG=$(TZ=Asia/Shanghai date +%Y%m%d-%H%M)
cat << EOF > /builder/openwrt/files/etc/rc.local
#!/bin/sh
sed -i "s/PRETTY_NAME=.*/PRETTY_NAME=\"ImmortalWrt 25.12 (AX6000-110M-${BUILD_TAG})\"/g" /usr/lib/os-release
sed -i "s/DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION='ImmortalWrt 25.12 (AX6000-110M-${BUILD_TAG})'/g" /etc/openwrt_release
if [ -x /etc/init.d/tailscale ]; then
    /etc/init.d/tailscale enabled || /etc/init.d/tailscale enable
    /etc/init.d/tailscale running || /etc/init.d/tailscale start
fi
# 每次开机拉起 Tailscale 登录守护（带防重复），未登录时用 authkey 自动重试
if [ -x /etc/tailscale_guard.sh ] && ! pgrep -f tailscale_guard >/dev/null 2>&1; then
    nohup /etc/tailscale_guard.sh >/dev/null 2>&1 &
fi
exit 0
EOF
chmod +x /builder/openwrt/files/etc/rc.local

cat << EOF > /builder/openwrt/files/etc/banner
  ___                               _        _ __        __         _
 |_ _|_ __ ___  _ __ ___   ___  _ __| |_ __ _| |\ \      / / __ ___ | |_
  | || '_ \` _ \| '_ \` _ \ / _ \| '__| __/ _\` | | \ \ /\ / / '__/ _ \| __|
  | || | | | | | | | | | | (_) | |  | || (_| | |  \ V  V /| | | (_) | |_
 |___|_| |_| |_|_| |_| |_|\___/|_|   \__\__,_|_|   \_/\_/ |_|  \___/ \__|
 -------------------------------------------------------------------------
  AX6000 110M Compact Build | 编译时间: ${BUILD_TAG} (北京时间)
 -------------------------------------------------------------------------
EOF
