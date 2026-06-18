#!/bin/bash
# ===================================================
# ===================================================

if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 用户或 sudo 执行此脚本！"
    exit 1
fi

echo "=== 开始主力机一键优化 (1C1G + ss2022/snell) ==="

# 1. 时间同步（ss2022 强制要求，snell 不强制但同步时间总没坏处）
echo ">>> 配置时间同步..."
apt-get update -qq && apt-get install -y chrony -qq
systemctl enable --now chrony
chronyc tracking 2>/dev/null

# 2. 创建 1GB Swap（1C1G 机器的安全垫）
if [ ! -f /swapfile ]; then
    echo ">>> 创建 1GB Swap..."
    dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "Swap 创建成功。"
else
    echo "Swap 已存在，跳过。"
fi

# 3. 检查内核是否支持 BBR
echo ">>> 检查 BBR 支持..."
modprobe tcp_bbr 2>/dev/null
if ! lsmod | grep -q bbr && ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    echo "警告：当前内核可能不支持 BBR，建议升级内核到 4.9 以上。"
fi

# 4. 写入内核网络参数
echo ">>> 写入内核网络参数..."

cat > /etc/sysctl.conf << 'SYSCTL'
# --- 1. 系统基础与 1G 内存防护 ---
kernel.pid_max = 65535
kernel.panic = 10
vm.swappiness = 10
vm.overcommit_memory = 0

# --- 2. 核心网络队列 ---
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 8192
net.core.somaxconn = 4096

# --- 3. 缓冲区（兼顾后续美西等高延迟线路） ---
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# --- 4. BBR 拥塞控制 ---
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072

# --- 5. TCP Fast Open 与连接优化 ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 16384
net.ipv4.tcp_sack = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_mtu_probing = 1

# --- 6. 端口与邻居表 ---
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.neigh.default.gc_thresh3 = 2048
net.ipv4.neigh.default.gc_thresh2 = 1024
net.ipv4.neigh.default.gc_thresh1 = 512

# --- 7. 基础安全防护 ---
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
SYSCTL

# 5. 生效
sysctl -p >/dev/null 2>&1

# 6. 验证结果
echo ""
echo "=== 验证结果 ==="
echo -n "拥塞控制算法: "; sysctl -n net.ipv4.tcp_congestion_control
echo -n "队列算法: "; sysctl -n net.core.default_qdisc
echo -n "Fast Open 状态: "; sysctl -n net.ipv4.tcp_fastopen
echo -n "Swap 状态: "; free -h | grep Swap
echo -n "时间同步: "; chronyc tracking 2>/dev/null | grep "Leap status" || echo "请稍后手动检查 chronyc tracking"

echo ""
echo "================================================="
echo " 主力机优化完成！"
echo " BBR + TFO 已开启，Swap 已就位，时间已同步。"
echo " 可以放心部署 ss2022 / snell 了。"
echo "================================================="
