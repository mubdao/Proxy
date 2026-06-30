#!/usr/bin/env bash
export LANG=C LC_ALL=C
set -e

CYELLOW="\033[1;33m"; CCYAN="\033[1;36m"; CEND="\033[0m"
OUT_ALERT(){ echo -e "${CYELLOW}$1${CEND}"; }
OUT_INFO(){ echo -e "${CCYAN}$1${CEND}"; }

OUT_ALERT "[信息] 优化性能中（1C1G 特供轻量版）！"
apt remove tuned --autoremove -y 2>/dev/null || true
# 1C 只有单核，删掉 irqbalance 节省常驻内存，且不需要手动钉核
apt purge irqbalance --autoremove -y 2>/dev/null || true   

# ---- KSM / ksmtuned (仅 PVE/KVM 宿主存在，纯 Debian 自动跳过) ----
if systemctl list-unit-files 2>/dev/null | grep -q '^ksmtuned'; then
    systemctl disable --now ksmtuned 2>/dev/null || true
    rm -f /etc/systemd/system/ksmtuned.service
fi
if [ -w /sys/kernel/mm/ksm/run ]; then
    echo 2 > /sys/kernel/mm/ksm/run
fi
if [ -e /usr/sbin/ksmtuned ]; then
    chattr -i /usr/sbin/ksmtuned 2>/dev/null || true
    : > /usr/sbin/ksmtuned
    chattr +i /usr/sbin/ksmtuned 2>/dev/null || true
fi

# ---- 关闭透明大页 ----
cat > /etc/systemd/system/disable-transparent-huge-pages.service << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
[Install]
WantedBy=basic.target
EOF
systemctl daemon-reload
systemctl enable --now disable-transparent-huge-pages

OUT_ALERT "[信息] 优化参数中！"
# ---- nf_conntrack 轻量化调整 ----
modprobe nf_conntrack 2>/dev/null || true
echo nf_conntrack > /etc/modules-load.d/nf_conntrack.conf
# 哈希表降至 16384，兼顾性能与低内存占用
echo "options nf_conntrack hashsize=16384" > /etc/modprobe.d/nf_conntrack.conf

# ---- sysctl 改用 drop-in (适合 1C1G) ----
cat > /etc/sysctl.d/99-network-optimize.conf << 'EOF'
fs.file-max = 200000
fs.nr_open = 200000
fs.inotify.max_user_watches = 65536
fs.inotify.max_user_instances = 256
net.core.default_qdisc = fq
net.core.somaxconn = 2048
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.ip_default_ttl = 128
net.ipv4.ip_forward = 1
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_max_orphans = 16384
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 15
net.ipv4.tcp_rfc1337 = 1
# TCP 读写缓冲区最大上限压减到约 6MB，防止并发下载时爆运行内存
net.ipv4.tcp_rmem = 4096 87380 6291456
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_wmem = 4096 65536 6291456
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.netfilter.nf_conntrack_generic_timeout = 60
net.netfilter.nf_conntrack_icmp_timeout = 10
# 最大连接跟踪数限制在 65536
net.netfilter.nf_conntrack_max = 65536
net.netfilter.nf_conntrack_tcp_max_retrans = 3
net.netfilter.nf_conntrack_tcp_timeout_close = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 15
net.netfilter.nf_conntrack_tcp_timeout_max_retrans = 60
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 60
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged = 60
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60
# 1G 内存必须留有 Swap 退路，防止突发流量触发 OOM 杀进程
vm.swappiness = 20
EOF

# ---- 按内存动态计算 tcp_mem 追加 ----
mems=$(free --bytes | awk '/Mem/{print $2}')
page=$(getconf PAGESIZE)
size=$((mems/page))
# 适当调低 1G 内存下的 TCP 协议栈最大页数占比（按 10% 30% 50% 比例分档）
echo "net.ipv4.tcp_mem = $((size/100*10)) $((size/100*30)) $((size/100*50))" >> /etc/sysctl.d/99-network-optimize.conf

# ---- limits 调整为适合 1C1G 的常规高性能档位 ----
cat > /etc/security/limits.conf << 'EOF'
* soft nofile 65535
* hard nofile 65535
* soft nproc unlimited
* hard nproc unlimited
root soft nofile 65535
root hard nofile 65535
root soft nproc unlimited
root hard nproc unlimited
EOF

# ---- journald 日志限制收紧，腾出更多内存和空间 ----
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/optimize.conf << 'EOF'
[Journal]
SystemMaxUse=64M
SystemMaxFileSize=16M
ForwardToSyslog=no
EOF
systemctl restart systemd-journald

# ---- 加载所有 sysctl drop-in ----
sysctl --system > /dev/null 2>&1

OUT_INFO "[信息] 1C1G 优化完成！"
