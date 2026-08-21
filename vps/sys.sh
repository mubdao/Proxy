#!/bin/bash

# ============================================================
# 极简 VPS 系统管理脚本 V2
# 适用于 Debian / Ubuntu
#
# 主要功能：
# 1. BBR + FQ
# 2. IPv4 / IPv6 出站与入站
# 3. DNS 设置与安全锁定
# 4. Swap 配置
# 5. 系统时间 / NTP
# 6. 安全磁盘清理（真正 Dry-Run）
# 7. 磁盘占用分析
#
# 设计原则：
# - 尽量不修改无关系统配置
# - 不自动删除用户普通文件
# - 不无差别删除 /var/log
# - Dry-Run 模式不执行任何删除
# ============================================================

# -----------------------------
# 基础设置
# -----------------------------

if [ "$EUID" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本！"
    exit 1
fi

DRY_RUN=0


# ============================================================
# 通用函数
# ============================================================

pause_return() {
    read -rp "按回车键返回菜单..."
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

get_used_mb() {
    df -Pm / | awk 'NR==2 {print $3}'
}

get_free_mb() {
    df -Pm / | awk 'NR==2 {print $4}'
}

get_disk_info() {
    df -h /
}

# 安全删除：
# 只删除指定目录下满足 mtime 条件的内容
safe_find_delete() {
    local path="$1"
    local days="$2"

    if [[ ! -d "$path" ]]; then
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] $path 下超过 $days 天的内容："
        find "$path" -mindepth 1 -mtime +"$days" -print 2>/dev/null | head -n 50
    else
        find "$path" -mindepth 1 -mtime +"$days" -exec rm -rf {} + 2>/dev/null || true
    fi
}


# ============================================================
# 系统状态
# ============================================================

get_system_status() {

    # -------------------------
    # BBR
    # -------------------------

    local cc
    local qdisc

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")

    if [[ "$cc" == "bbr" ]]; then
        bbr_status="已开启 (BBR / $qdisc)"
    else
        bbr_status="未开启 (当前: $cc / $qdisc)"
    fi


    # -------------------------
    # 出站 IPv4 / IPv6
    # -------------------------

    if grep -qE "^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100" /etc/gai.conf 2>/dev/null; then
        outbound_status="优先 IPv4"

    elif grep -qE "^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+10" /etc/gai.conf 2>/dev/null; then
        outbound_status="优先 IPv6"

    else
        outbound_status="系统默认"
    fi


    # -------------------------
    # IPv6
    # -------------------------

    local disable_ipv6

    disable_ipv6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "未知")

    if [[ "$disable_ipv6" == "1" ]]; then
        inbound_status="IPv6 已禁用（仅 IPv4）"
    elif [[ "$disable_ipv6" == "0" ]]; then
        inbound_status="双栈开启（IPv4 + IPv6）"
    else
        inbound_status="未知"
    fi


    # -------------------------
    # DNS
    # -------------------------

    local dns_list

    dns_list=$(grep -E "^[[:space:]]*nameserver[[:space:]]+" /etc/resolv.conf 2>/dev/null \
        | awk '{print $2}' \
        | tr '\n' ' ' \
        | sed 's/ $//' \
        | sed 's/ / | /g')

    [[ -z "$dns_list" ]] && dns_list="未配置"


    # resolv.conf 类型

    local dns_type

    if [[ -L /etc/resolv.conf ]]; then
        dns_type="符号链接"

    elif [[ -f /etc/resolv.conf ]]; then
        dns_type="普通文件"

    else
        dns_type="未知"
    fi


    # immutable 属性

    local dns_lock=""

    if [[ -e /etc/resolv.conf ]] && command_exists lsattr; then
        if lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
            dns_lock="🔒已锁定"
        else
            dns_lock="🔓未锁定"
        fi
    else
        dns_lock="未知"
    fi

    dns_status="${dns_list} [$dns_type / $dns_lock]"


    # -------------------------
    # Swap
    # -------------------------

    local swap_total
    local swap_used

    swap_total=$(free -h | awk '/^Swap:/ {print $2}')
    swap_used=$(free -h | awk '/^Swap:/ {print $3}')

    if [[ "$swap_total" == "0B" || "$swap_total" == "0" || -z "$swap_total" ]]; then
        swap_status="未启用"
    else
        swap_status="已启用 (容量: $swap_total / 已用: $swap_used)"
    fi


    # -------------------------
    # 时间
    # -------------------------

    local current_tz
    local current_time

    current_tz=$(timedatectl 2>/dev/null | awk '/Time zone:/ {print $3}')

    if [[ -z "$current_tz" ]]; then
        current_tz=$(date +%Z)
    fi

    current_time=$(date "+%Y-%m-%d %H:%M:%S")

    time_status="$current_tz ($current_time)"


    # -------------------------
    # 磁盘
    # -------------------------

    local disk_used
    local disk_free
    local disk_percent

    disk_used=$(df -h / | awk 'NR==2 {print $3}')
    disk_free=$(df -h / | awk 'NR==2 {print $4}')
    disk_percent=$(df -h / | awk 'NR==2 {print $5}')

    disk_status="已用 $disk_used / 剩余 $disk_free / 使用率 $disk_percent"


    # -------------------------
    # 输出
    # -------------------------

    echo "【当前 VPS 系统状态预览】"
    echo "▸ BBR 加速状态 : $bbr_status"
    echo "▸ 出站 IP 偏好 : $outbound_status"
    echo "▸ 入站协议状态 : $inbound_status"
    echo "▸ 当前系统 DNS : $dns_status"
    echo "▸ 虚拟内存 Swap: $swap_status"
    echo "▸ 系统时区时间 : $time_status"
    echo "▸ 根目录磁盘   : $disk_status"
}


# ============================================================
# 主菜单
# ============================================================

show_menu() {

    clear

    echo "========== 极简 VPS 系统管理脚本 V2 =========="
    echo " 1. BBR / FQ 网络加速"
    echo " 2. 修改网络出入站模式"
    echo " 3. 修改系统 DNS"
    echo " 4. 配置虚拟内存 Swap"
    echo " 5. 系统时间与 NTP"
    echo " 6. 安全磁盘清理"
    echo " 7. 磁盘占用分析"
    echo " 0. 退出脚本"
    echo "----------------------------------------------"

    get_system_status

    echo "=============================================="

    read -rp "请输入选项 [0-7]: " choice

    case "$choice" in

        1)
            bbr_menu
            ;;

        2)
            set_ip_preference
            ;;

        3)
            set_dns
            ;;

        4)
            set_swap
            ;;

        5)
            sync_time
            ;;

        6)
            clean_disk_menu
            ;;

        7)
            disk_usage_menu
            ;;

        0)
            exit 0
            ;;

        *)
            echo "无效选项。"
            pause_return
            show_menu
            ;;
    esac
}


# ============================================================
# 1. BBR
# ============================================================

bbr_menu() {

    clear

    echo "========== BBR / FQ 网络加速 =========="
    echo " 1. 开启 BBR + FQ"
    echo " 2. 恢复传统 cubic + fq_codel"
    echo " 0. 返回主菜单"
    echo "======================================="

    read -rp "请选择 [0-2]: " choice

    case "$choice" in

        1)
            enable_bbr
            ;;

        2)
            disable_bbr
            ;;

        0)
            show_menu
            ;;

        *)
            echo "无效选择。"
            pause_return
            bbr_menu
            ;;
    esac
}


enable_bbr() {

    echo "正在配置 BBR + FQ..."

    # 删除旧配置
    sed -i '/^[[:space:]]*net.core.default_qdisc[[:space:]]*=/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net.ipv4.tcp_congestion_control[[:space:]]*=/d' /etc/sysctl.conf

    cat >> /etc/sysctl.conf <<'EOF'

# VPS 网络优化
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl -p >/dev/null 2>&1

    echo
    echo "BBR 配置完成。"
    echo

    sysctl net.ipv4.tcp_congestion_control
    sysctl net.core.default_qdisc

    pause_return
    show_menu
}


disable_bbr() {

    echo "正在恢复 cubic + fq_codel..."

    sed -i '/^[[:space:]]*net.core.default_qdisc[[:space:]]*=/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net.ipv4.tcp_congestion_control[[:space:]]*=/d' /etc/sysctl.conf

    cat >> /etc/sysctl.conf <<'EOF'

# 恢复传统网络配置
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=cubic
EOF

    sysctl -p >/dev/null 2>&1

    echo
    echo "已恢复 cubic + fq_codel。"
    echo

    sysctl net.ipv4.tcp_congestion_control
    sysctl net.core.default_qdisc

    pause_return
    show_menu
}


# ============================================================
# 2. IPv4 / IPv6
# ============================================================

set_ip_preference() {

    clear

    echo "========== 网络与 IP 模式设置 =========="
    echo " 1. 修改【出站】IP 优先级"
    echo " 2. 修改【入站】IPv4 / IPv6"
    echo " 0. 返回主菜单"
    echo "========================================"

    read -rp "请输入选项 [0-2]: " sub_choice

    case "$sub_choice" in

        1)
            set_outbound
            ;;

        2)
            set_inbound
            ;;

        0)
            show_menu
            ;;

        *)
            echo "无效选择。"
            pause_return
            set_ip_preference
            ;;
    esac
}


set_outbound() {

    clear

    echo "--- 修改【出站】IP 访问优先级 ---"
    echo
    echo "1) 优先使用 IPv4"
    echo "2) 优先使用 IPv6"
    echo "3) 恢复系统默认"
    echo

    read -rp "请选择 [1-3]: " out_choice

    # 删除本脚本之前设置的配置
    sed -i '/^[[:space:]]*precedence[[:space:]]\+::ffff:0:0\/96/d' /etc/gai.conf 2>/dev/null

    case "$out_choice" in

        1)

            echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf

            echo
            echo "已设置：IPv4 优先出站。"
            ;;

        2)

            echo "precedence ::ffff:0:0/96  10" >> /etc/gai.conf

            echo
            echo "已设置：IPv6 优先出站。"
            ;;

        3)

            echo
            echo "已恢复系统默认出站地址选择。"
            ;;

        *)

            echo "无效选择。"
            ;;
    esac

    pause_return
    set_ip_preference
}


set_inbound() {

    clear

    echo "--- 修改【入站】系统 IPv4 / IPv6 ---"
    echo
    echo "1) 开启 IPv4 + IPv6 双栈"
    echo "2) 禁用 IPv6，仅保留 IPv4"
    echo "0) 返回"
    echo

    read -rp "请选择 [0-2]: " in_choice

    case "$in_choice" in

        1)

            # 当前立即生效
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null

            # 持久化
            sed -i '/^[[:space:]]*net.ipv6.conf.all.disable_ipv6[[:space:]]*=/d' /etc/sysctl.conf
            sed -i '/^[[:space:]]*net.ipv6.conf.default.disable_ipv6[[:space:]]*=/d' /etc/sysctl.conf

            cat >> /etc/sysctl.conf <<'EOF'

# IPv4 + IPv6 双栈
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
EOF

            sysctl -p >/dev/null 2>&1

            echo
            echo "已开启 IPv4 + IPv6 双栈，并设置为永久配置。"
            ;;

        2)

            sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
            sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null

            sed -i '/^[[:space:]]*net.ipv6.conf.all.disable_ipv6[[:space:]]*=/d' /etc/sysctl.conf
            sed -i '/^[[:space:]]*net.ipv6.conf.default.disable_ipv6[[:space:]]*=/d' /etc/sysctl.conf

            cat >> /etc/sysctl.conf <<'EOF'

# 禁用 IPv6
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF

            sysctl -p >/dev/null 2>&1

            echo
            echo "已禁用 IPv6，并设置为永久配置。"
            ;;

        0)
            set_ip_preference
            return
            ;;

        *)
            echo "无效选择。"
            ;;
    esac

    pause_return
    set_ip_preference
}


# ============================================================
# 3. DNS
# ============================================================

show_dns_info() {

    echo
    echo "当前 /etc/resolv.conf："

    if [[ -L /etc/resolv.conf ]]; then
        echo "类型：符号链接"
        echo "目标：$(readlink -f /etc/resolv.conf 2>/dev/null)"
    else
        echo "类型：普通文件"
    fi

    echo
    cat /etc/resolv.conf 2>/dev/null || true
    echo
}


set_dns() {

    clear

    echo "========== 系统 DNS 设置 =========="
    echo " 1. 使用默认 DNS（Google + Cloudflare）"
    echo " 2. 手动输入 DNS"
    echo " 3. 锁定当前 DNS"
    echo " 4. 解锁 DNS"
    echo " 5. 查看当前 DNS"
    echo " 0. 返回主菜单"
    echo "==================================="

    read -rp "请选择 [0-5]: " dns_choice

    case "$dns_choice" in

        1)
            set_default_dns
            ;;

        2)
            set_custom_dns
            ;;

        3)
            lock_dns
            ;;

        4)
            unlock_dns
            ;;

        5)
            show_dns_info
            pause_return
            set_dns
            ;;

        0)
            show_menu
            ;;

        *)
            echo "无效选择。"
            pause_return
            set_dns
            ;;
    esac
}


prepare_resolv_conf() {

    if [[ -L /etc/resolv.conf ]]; then

        echo
        echo "⚠️  检测到 /etc/resolv.conf 是符号链接："
        echo "    $(readlink -f /etc/resolv.conf 2>/dev/null)"
        echo
        echo "直接覆盖可能破坏 systemd-resolved / 网络管理器的 DNS 管理。"
        echo

        read -rp "是否继续并将其转换为普通文件？[y/N]: " confirm

        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "已取消。"
            return 1
        fi

        chattr -i /etc/resolv.conf 2>/dev/null || true

        rm -f /etc/resolv.conf

        touch /etc/resolv.conf

    else

        chattr -i /etc/resolv.conf 2>/dev/null || true

    fi

    return 0
}


set_default_dns() {

    if ! prepare_resolv_conf; then
        pause_return
        set_dns
        return
    fi

    cat > /etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1111
EOF

    echo
    echo "DNS 已设置为："
    cat /etc/resolv.conf
    echo

    read -rp "是否立即锁定 DNS，防止系统覆盖？[Y/n]: " lock_confirm

    lock_confirm=${lock_confirm:-Y}

    if [[ "$lock_confirm" =~ ^[Yy]$ ]]; then

        if chattr +i /etc/resolv.conf 2>/dev/null; then
            echo "🔒 DNS 已锁定。"
        else
            echo "⚠️ DNS 设置成功，但锁定失败。"
        fi

    else

        echo "🔓 DNS 保持未锁定。"

    fi

    pause_return
    show_menu
}


set_custom_dns() {

    if ! prepare_resolv_conf; then
        pause_return
        set_dns
        return
    fi

    read -rp "请输入主 DNS： " main_dns
    read -rp "请输入备用 DNS（可选）： " sub_dns

    if [[ -z "$main_dns" ]]; then
        echo "未输入主 DNS，取消修改。"
        pause_return
        set_dns
        return
    fi

    # 简单校验：只允许 IPv4 / IPv6 常见字符，避免写入非法内容
    local dns_re='^[0-9a-fA-F.:]+$'

    if [[ ! "$main_dns" =~ $dns_re ]]; then
        echo "错误：主 DNS 格式不合法（仅允许数字、字母 a-f、'.'、':'）。"
        pause_return
        set_dns
        return
    fi

    if [[ -n "$sub_dns" && ! "$sub_dns" =~ $dns_re ]]; then
        echo "错误：备用 DNS 格式不合法（仅允许数字、字母 a-f、'.'、':'）。"
        pause_return
        set_dns
        return
    fi

    {
        echo "nameserver $main_dns"

        if [[ -n "$sub_dns" ]]; then
            echo "nameserver $sub_dns"
        fi

    } > /etc/resolv.conf

    echo
    echo "DNS 修改成功："
    cat /etc/resolv.conf
    echo

    read -rp "是否立即锁定 DNS？[Y/n]: " lock_confirm

    lock_confirm=${lock_confirm:-Y}

    if [[ "$lock_confirm" =~ ^[Yy]$ ]]; then

        if chattr +i /etc/resolv.conf 2>/dev/null; then
            echo "🔒 DNS 已锁定。"
        else
            echo "⚠️ DNS 设置成功，但锁定失败。"
        fi

    else

        echo "🔓 DNS 未锁定。"

    fi

    pause_return
    show_menu
}


lock_dns() {

    if [[ -L /etc/resolv.conf ]]; then

        echo
        echo "⚠️ /etc/resolv.conf 是符号链接。"
        echo "不建议直接对它执行 chattr +i。"
        echo
        echo "当前目标：$(readlink -f /etc/resolv.conf 2>/dev/null)"

    else

        if chattr +i /etc/resolv.conf 2>/dev/null; then
            echo "🔒 DNS 已成功锁定。"
        else
            echo "⚠️ DNS 锁定失败。"
        fi

    fi

    pause_return
    set_dns
}


unlock_dns() {

    if chattr -i /etc/resolv.conf 2>/dev/null; then
        echo "🔓 DNS 已解锁。"
    else
        echo "⚠️ DNS 解锁失败。"
    fi

    pause_return
    set_dns
}


# ============================================================
# 4. Swap
# ============================================================

set_swap() {

    clear

    echo "========== Swap 配置 =========="
    echo
    free -h
    echo
    echo "当前 Swap："

    if command_exists swapon; then
        swapon --show
    fi

    echo
    echo " 1. 创建 / 调整 Swapfile"
    echo " 2. 删除 /swapfile"
    echo " 3. 查看 Swap 状态"
    echo " 0. 返回"
    echo "==============================="

    read -rp "请选择 [0-3]: " swap_choice

    case "$swap_choice" in

        1)
            create_swap
            ;;

        2)
            remove_swap
            ;;

        3)
            free -h
            echo
            swapon --show 2>/dev/null || true
            pause_return
            set_swap
            ;;

        0)
            show_menu
            ;;

        *)
            echo "无效选择。"
            pause_return
            set_swap
            ;;
    esac
}


create_swap() {

    echo
    read -rp "请输入 Swap 大小（MB，例如 1024 / 2048）： " swap_size

    if [[ ! "$swap_size" =~ ^[0-9]+$ ]] || [[ "$swap_size" -le 0 ]]; then
        echo "错误：请输入有效数字。"
        pause_return
        set_swap
        return
    fi

    # 限制最大 8GB
    if [[ "$swap_size" -gt 8192 ]]; then
        echo "错误：单个 Swapfile 最大允许 8192 MB。"
        pause_return
        set_swap
        return
    fi

    local free_mb
    free_mb=$(get_free_mb)

    # 要求至少留 512MB 空间
    if [[ "$swap_size" -gt $((free_mb - 512)) ]]; then
        echo
        echo "错误：磁盘剩余空间不足。"
        echo "当前可用：${free_mb} MB"
        echo "建议至少保留 512 MB 磁盘空间。"
        pause_return
        set_swap
        return
    fi

    echo
    echo "准备创建 ${swap_size} MB Swap。"

    # 如果已有 /swapfile，先确认
    if [[ -e /swapfile ]]; then

        echo
        echo "检测到现有 /swapfile。"

        read -rp "是否替换现有 /swapfile？[y/N]: " confirm

        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "已取消。"
            pause_return
            set_swap
            return
        fi

        if swapon --show=NAME 2>/dev/null | grep -qx "/swapfile"; then
            swapoff /swapfile
        fi

        rm -f /swapfile
    fi

    echo
    echo "正在创建 Swapfile..."

    if command_exists fallocate; then
        fallocate -l "${swap_size}M" /swapfile
    else
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_size" status=progress
    fi

    chmod 600 /swapfile

    if ! mkswap /swapfile >/dev/null; then
        echo "mkswap 失败。"
        rm -f /swapfile
        pause_return
        set_swap
        return
    fi

    if ! swapon /swapfile; then
        echo "swapon 失败。"
        rm -f /swapfile
        pause_return
        set_swap
        return
    fi

    # 确保 fstab 只有一条 /swapfile
    sed -i '\|^[[:space:]]*/swapfile[[:space:]]|d' /etc/fstab

    echo "/swapfile none swap sw 0 0" >> /etc/fstab

    echo
    echo "✅ Swap 设置成功。"
    echo
    free -h
    echo
    swapon --show

    pause_return
    show_menu
}


remove_swap() {

    if [[ ! -e /swapfile ]]; then
        echo "当前不存在 /swapfile。"
        pause_return
        set_swap
        return
    fi

    echo
    read -rp "确定删除 /swapfile？[y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        pause_return
        set_swap
        return
    fi

    if swapon --show=NAME 2>/dev/null | grep -qx "/swapfile"; then
        swapoff /swapfile
    fi

    rm -f /swapfile

    sed -i '\|^[[:space:]]*/swapfile[[:space:]]|d' /etc/fstab

    echo "Swapfile 已删除。"

    pause_return
    show_menu
}


# ============================================================
# 5. 时间 / NTP
# ============================================================

sync_time() {

    clear

    echo "========== 系统时间与 NTP =========="
    echo
    echo "当前时间：$(date)"
    echo

    if command_exists timedatectl; then
        timedatectl status 2>/dev/null | grep -E "Time zone|System clock|NTP|synchronized" || true
    fi

    echo
    echo "1) 设置时区为 Asia/Shanghai"
    echo "2) 设置时区为 UTC"
    echo "3) 开启系统 NTP 自动同步"
    echo "4) 查看时间同步状态"
    echo "0) 返回"
    echo

    read -rp "请选择 [0-4]: " time_choice

    case "$time_choice" in

        1)

            timedatectl set-timezone Asia/Shanghai 2>/dev/null \
                || ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

            echo "已设置为 Asia/Shanghai。"
            ;;

        2)

            timedatectl set-timezone UTC 2>/dev/null \
                || ln -sf /usr/share/zoneinfo/UTC /etc/localtime

            echo "已设置为 UTC。"
            ;;

        3)

            if command_exists timedatectl; then
                timedatectl set-ntp true 2>/dev/null
                echo "已开启系统 NTP 自动同步。"
            else
                echo "系统没有 timedatectl。"
            fi
            ;;

        4)

            timedatectl status 2>/dev/null || date
            ;;

        0)

            show_menu
            return
            ;;

        *)

            echo "无效选择。"
            ;;
    esac

    echo
    echo "当前时间：$(date)"

    pause_return
    show_menu
}


# ============================================================
# 6. 磁盘清理
# ============================================================

clean_disk_menu() {

    clear

    echo "========== 安全磁盘清理 =========="
    echo
    echo " 1. 真实清理"
    echo " 2. Dry-Run 预览（绝不删除）"
    echo " 3. 仅清理 APT 缓存"
    echo " 4. 仅清理 Journal 日志"
    echo " 5. 仅清理临时文件"
    echo " 0. 返回主菜单"
    echo "=================================="

    read -rp "请选择 [0-5]: " clean_choice

    case "$clean_choice" in

        1)
            DRY_RUN=0
            execute_deep_clean
            ;;

        2)
            DRY_RUN=1
            execute_deep_clean
            ;;

        3)
            DRY_RUN=0
            clean_apt
            pause_return
            show_menu
            ;;

        4)
            DRY_RUN=0
            clean_journal
            pause_return
            show_menu
            ;;

        5)
            DRY_RUN=0
            clean_temp
            pause_return
            show_menu
            ;;

        0)
            show_menu
            ;;

        *)
            echo "无效选择。"
            pause_return
            clean_disk_menu
            ;;
    esac
}


# -----------------------------
# APT 清理
# -----------------------------

clean_apt() {

    echo
    echo "[APT] 清理软件包缓存..."

    apt-get clean 2>/dev/null || true
    apt-get autoclean -y 2>/dev/null || true

    echo "[APT] 完成。"
}


# -----------------------------
# Journal 清理
# -----------------------------

clean_journal() {

    echo
    echo "[Journal] 当前日志占用："

    journalctl --disk-usage 2>/dev/null || true

    echo
    echo "保留最近 7 天，并限制总大小 300MB。"

    journalctl --vacuum-time=7d 2>/dev/null || true
    journalctl --vacuum-size=300M 2>/dev/null || true

    echo
    echo "[Journal] 清理完成。"
}


# -----------------------------
# 临时文件
# -----------------------------

clean_temp() {

    echo
    echo "[TMP] 清理超过 1 天的 /tmp..."

    safe_find_delete "/tmp" 1

    echo
    echo "[TMP] 清理超过 7 天的 /var/tmp..."

    safe_find_delete "/var/tmp" 7

    if command_exists systemd-tmpfiles; then
        echo
        echo "[TMP] 执行 systemd-tmpfiles --clean..."

        systemd-tmpfiles --clean 2>/dev/null || true
    fi

    echo
    echo "[TMP] 完成。"
}


# -----------------------------
# 深度清理
# -----------------------------

execute_deep_clean() {

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo
        echo "当前模式：👀 DRY-RUN 预览"
        echo "⚠️ 本次不会执行任何删除操作。"
    else
        echo
        echo "当前模式：🧹 真实清理"
    fi

    echo
    echo "=================================================="

    BEFORE_MB=$(get_used_mb)
    BEFORE_USED=$(df -h / | awk 'NR==2 {print $3}')
    BEFORE_PERC=$(df -h / | awk 'NR==2 {print $5}')


    # ========================================================
    # 1. APT
    # ========================================================

    echo
    echo "[1/8] APT 软件包缓存"

    if [[ "$DRY_RUN" -eq 1 ]]; then

        echo "[DRY-RUN] apt-get clean"
        echo "[DRY-RUN] apt-get autoclean"

    else

        clean_apt

    fi


    # ========================================================
    # 2. 已卸载软件残留配置
    # ========================================================

    echo
    echo "[2/8] 已卸载软件残留配置"

    RC_PACKAGES=$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}' || true)

    if [[ -n "$RC_PACKAGES" ]]; then

        echo "$RC_PACKAGES"

        if [[ "$DRY_RUN" -eq 1 ]]; then

            echo "[DRY-RUN] 上述残留配置将被 purge。"

        else

            echo "$RC_PACKAGES" | xargs -r dpkg --purge 2>/dev/null || true

        fi

    else

        echo "没有发现残留配置。"

    fi


    # ========================================================
    # 3. Journal
    # ========================================================

    echo
    echo "[3/8] systemd Journal 日志"

    journalctl --disk-usage 2>/dev/null || true

    if [[ "$DRY_RUN" -eq 1 ]]; then

        echo "[DRY-RUN] journalctl --vacuum-time=7d"
        echo "[DRY-RUN] journalctl --vacuum-size=300M"

    else

        clean_journal

    fi


    # ========================================================
    # 4. Crash
    # ========================================================

    echo
    echo "[4/8] 系统崩溃转储"

    if command_exists coredumpctl; then

        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "[DRY-RUN] coredumpctl purge"
        else
            coredumpctl purge 2>/dev/null || true
        fi

    fi

    if [[ -d /var/crash ]]; then

        if [[ "$DRY_RUN" -eq 1 ]]; then

            echo "[DRY-RUN] 将清理 /var/crash 中的旧崩溃文件："

            find /var/crash -mindepth 1 -maxdepth 1 -print 2>/dev/null

        else

            find /var/crash -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

        fi

    fi


    # ========================================================
    # 5. TMP
    # ========================================================

    echo
    echo "[5/8] 系统临时目录"

    if [[ "$DRY_RUN" -eq 1 ]]; then

        safe_find_delete "/tmp" 1
        safe_find_delete "/var/tmp" 7

    else

        clean_temp

    fi


    # ========================================================
    # 6. 用户缓存
    # ========================================================

    echo
    echo "[6/8] 用户缓存"

    for user_home in /home/* /root; do

        [[ -d "$user_home" ]] || continue


        # 普通 cache：只删除超过 14 天
        if [[ -d "$user_home/.cache" ]]; then

            echo
            echo "检查：$user_home/.cache"

            safe_find_delete "$user_home/.cache" 14

        fi


        # pip cache
        if [[ -d "$user_home/.cache/pip" ]]; then

            echo
            echo "检查：$user_home/.cache/pip"

            safe_find_delete "$user_home/.cache/pip" 7

        fi


        # npm cache
        if [[ -d "$user_home/.npm/_cacache" ]]; then

            echo
            echo "检查：$user_home/.npm/_cacache"

            safe_find_delete "$user_home/.npm/_cacache" 14

        fi


        # Trash
        if [[ -d "$user_home/.local/share/Trash/files" ]]; then

            echo
            echo "检查：$user_home/.local/share/Trash/files"

            safe_find_delete "$user_home/.local/share/Trash/files" 30

        fi

    done


    # ========================================================
    # 7. Flatpak / Snap
    # ========================================================

    echo
    echo "[7/8] Flatpak / Snap"

    if command_exists flatpak; then

        if [[ "$DRY_RUN" -eq 1 ]]; then

            echo "[DRY-RUN] flatpak uninstall --unused -y"

        else

            flatpak uninstall --unused -y 2>/dev/null || true

        fi

    fi

    # Snap 不主动删除 snap 包
    # 因为 VPS 通常不需要 Snap，而且 snap 的清理策略比较特殊。


    # ========================================================
    # 8. 不自动碰 /var/log
    # ========================================================

    echo
    echo "[8/8] 系统日志"

    echo "安全策略：不直接删除 /var/log 下的普通日志文件。"
    echo "Journal 日志已经在第 3 步进行限制。"

    echo
    echo "如发现 /var/log 有异常大文件，请使用“磁盘占用分析”定位后再处理。"


    # ========================================================
    # 结果
    # ========================================================

    AFTER_MB=$(get_used_mb)
    AFTER_USED=$(df -h / | awk 'NR==2 {print $3}')
    AFTER_PERC=$(df -h / | awk 'NR==2 {print $5}')

    FREED_MB=$((BEFORE_MB - AFTER_MB))

    if [[ "$FREED_MB" -lt 0 ]]; then
        FREED_MB=0
    fi

    echo
    echo "=================================================="

    if [[ "$DRY_RUN" -eq 1 ]]; then

        echo "        👀 Dry-Run 预览完成"
        echo "        ⚠️ 未执行删除操作"

    else

        echo "        🎉 安全清理完成"

    fi

    echo "=================================================="

    echo "【清理前】已用空间：$BEFORE_USED"
    echo "【清理前】使用率：$BEFORE_PERC"
    echo
    echo "【清理后】已用空间：$AFTER_USED"
    echo "【清理后】使用率：$AFTER_PERC"

    if [[ "$DRY_RUN" -eq 0 ]]; then

        echo

        if [[ "$FREED_MB" -ge 1024 ]]; then

            FREED_GB=$(awk "BEGIN {printf \"%.2f\", $FREED_MB/1024}")

            echo "✨ 本次释放：${FREED_GB} GB"

        else

            echo "✨ 本次释放：${FREED_MB} MB"

        fi

    fi

    echo "=================================================="

    pause_return
    show_menu
}


# ============================================================
# 7. 磁盘占用分析
# ============================================================

disk_usage_menu() {

    clear

    echo "========== VPS 磁盘占用分析 =========="
    echo
    echo "根目录整体："
    df -h /
    echo

    echo "--------------------------------------"
    echo "一级目录占用："
    echo

    du -xhd1 / 2>/dev/null | sort -h

    echo
    echo "--------------------------------------"
    echo "常见大目录："
    echo

    for path in /root /var /usr /home /opt /tmp; do

        if [[ -d "$path" ]]; then

            size=$(du -shx "$path" 2>/dev/null | awk '{print $1}')

            echo "$size    $path"

        fi

    done

    echo
    echo "--------------------------------------"
    echo "如果需要寻找真正的大文件，可执行："
    echo
    echo "find / -xdev -type f -size +100M -ls 2>/dev/null"
    echo

    pause_return
    show_menu
}


# ============================================================
# 启动
# ============================================================

show_menu
