#!/usr/bin/env bash

set -eo pipefail

on_error() {
    local exit_code=$?
    local line_no=$1
    echo -e "\n${RED}[ERROR]${NC} 脚本在第 ${line_no} 行发生错误，已退出 (错误码: ${exit_code})"
    echo -e "${YELLOW}如需反馈问题，请截图上面的报错信息。${NC}"
}
trap 'on_error $LINENO' ERR

# ------------------------------------------------------------------------------
# 全局变量与路径定义
# ------------------------------------------------------------------------------
readonly CONFIG_PATH="/etc/sing-box/config.json"
readonly INFO_PATH="/root/.sb_info.json"
readonly TLS_DIR="/root/AnyTLS/tls"
readonly SERVICE_NAME="sing-box"
readonly LOCAL_SCRIPT_PATH="/root/sb.sh"

# 颜色与样式
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ------------------------------------------------------------------------------
# 辅助 UI 与工具函数
# ------------------------------------------------------------------------------
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

pause() {
    echo -e "\n${YELLOW}按任意键继续...${NC}"
    read -n 1 -s -r
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "本脚本需要 Root 权限运行，请使用 'sudo -i' 切换到 Root 用户后再试。"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 强制性全局注册函数 ('sb' 命令)
# ------------------------------------------------------------------------------
force_register_shortcut() {
    if [[ -s "$0" ]]; then
        cp -f "$0" "$LOCAL_SCRIPT_PATH" 2>/dev/null || true
    fi

    if [[ ! -s "$LOCAL_SCRIPT_PATH" ]]; then
        curl -fsSL https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/sb.sh -o "$LOCAL_SCRIPT_PATH" 2>/dev/null || \
        wget -qO "$LOCAL_SCRIPT_PATH" https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/sb.sh 2>/dev/null || true
    fi

    chmod +x "$LOCAL_SCRIPT_PATH" 2>/dev/null || true

    local target_paths=("/usr/local/bin/sb" "/usr/bin/sb")

    for path in "${target_paths[@]}"; do
        rm -rf "$path" 2>/dev/null || true

        cat << 'EOF' > "$path"
#!/usr/bin/env bash
if [[ -f /root/sb.sh ]]; then
    bash /root/sb.sh "$@"
else
    bash <(curl -fsSL https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/sb.sh) "$@"
fi
EOF
        chmod +x "$path" 2>/dev/null || true
    done
}

# 校验端口格式
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# 检测端口占用并实时在屏幕打印结果
check_and_print_port_status() {
    local port="$1"
    local is_busy=0

    if command -v ss &>/dev/null; then
        ss -tuln | grep -q ":${port} " && is_busy=1
    elif command -v netstat &>/dev/null; then
        netstat -tuln | grep -q ":${port} " && is_busy=1
    elif command -v lsof &>/dev/null; then
        lsof -i:"${port}" &>/dev/null && is_busy=1
    fi

    if [[ $is_busy -eq 1 ]]; then
        log_warn "检测到端口 ${port} ${RED}已被占用${NC}！"
        return 1
    else
        log_success "检测到端口 ${port} ${GREEN}未被占用${NC}，可以使用。"
        return 0
    fi
}

# 获取公网 IP
get_public_ip() {
    local ip
    ip=$(curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s6 --connect-timeout 5 ifconfig.me 2>/dev/null || true)
    fi
    echo "${ip:-127.0.0.1}"
}

# 自动放行防火墙端口
open_firewall_port() {
    local port="$1"
    log_info "正在为您自动放行防火墙端口 ${port}..."
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        log_success "UFW 防火墙端口 ${port} 放行成功！"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_success "Firewalld 防火墙端口 ${port} 放行成功！"
    fi
}

# 打印当前系统的安装与运行状态卡片
print_system_status() {
    echo -e "${CYAN}-----------------------------------------------------${NC}"

    if ! command -v sing-box &>/dev/null; then
        echo -e " 服务状态: ${RED}${BOLD}○ 未安装 Sing-Box${NC}"
        echo -e "${CYAN}-----------------------------------------------------${NC}"
        return
    fi

    local ver
    ver=$(get_singbox_version)

    if [[ -f "$CONFIG_PATH" && -f "$INFO_PATH" ]]; then
        local protos=()
        jq -e .anytls "$INFO_PATH" >/dev/null 2>&1 && protos+=("AnyTLS")
        jq -e .ss2022 "$INFO_PATH" >/dev/null 2>&1 && protos+=("SS2022")
        jq -e .snell  "$INFO_PATH" >/dev/null 2>&1 && protos+=("Snell v6")
        local installed_proto
        installed_proto=$(IFS=" + "; echo "${protos[*]}")
        [[ -z "$installed_proto" ]] && installed_proto="未知配置"

        if systemctl is-active --quiet "$SERVICE_NAME"; then
            echo -e " 服务状态: ${GREEN}${BOLD}● 已安装并正常运行中${NC} (v${ver:-未知})"
            echo -e " 已配置项: ${CYAN}${installed_proto}${NC}"
        else
            echo -e " 服务状态: ${YELLOW}${BOLD}● 已安装但未运行 (已停止)${NC} (v${ver:-未知})"
            echo -e " 已配置项: ${CYAN}${installed_proto}${NC}"
        fi
    else
        echo -e " 服务状态: ${YELLOW}${BOLD}● 已安装 (v${ver:-未知}) / 未配置节点${NC}"
    fi
    echo -e "${CYAN}-----------------------------------------------------${NC}"
}

# ------------------------------------------------------------------------------
# 依赖与环境准备
# ------------------------------------------------------------------------------
wait_for_apt_lock() {
    if ! command -v fuser &>/dev/null; then
        return
    fi
    local max_wait=60
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [[ $waited -ge $max_wait ]]; then
            log_warn "等待 apt 锁超时 (${max_wait}秒)，仍尝试继续执行..."
            return
        fi
        log_warn "检测到 apt 正被其他进程占用，等待 5 秒后重试... (已等待 ${waited}秒)"
        sleep 5
        waited=$((waited + 5))
    done
}

apt_get_retry() {
    local max_attempts=3
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        wait_for_apt_lock
        if apt-get "$@"; then
            return 0
        fi
        log_warn "命令执行失败 (第 ${attempt}/${max_attempts} 次)，5 秒后重试..."
        sleep 5
        attempt=$((attempt + 1))
    done
    log_error "多次重试后仍然失败: apt-get $*"
    return 1
}

install_dependencies() {
    log_info "检查并安装必要依赖组件..."
    rm -f /etc/sing-box/client_info.json

    if command -v apt-get &>/dev/null; then
        apt_get_retry update -y -qq
        apt_get_retry install -y -qq curl jq net-tools openssl lsof
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl jq net-tools openssl lsof
    elif command -v yum &>/dev/null; then
        yum install -y -q curl jq net-tools openssl lsof
    fi
}

# ------------------------------------------------------------------------------
# Sing-Box 内核安装 / 更新（官方正式版）
# ------------------------------------------------------------------------------
install_singbox_core() {
    log_info "正在安装 Sing-Box (官方正式版内核)..."
    if curl -fsSL https://sing-box.app/install.sh | sh; then
        log_success "Sing-Box 核心组件安装完毕！"
        return 0
    else
        log_error "Sing-Box 安装失败，请检查服务器网络。"
        return 1
    fi
}

update_singbox_core() {
    log_info "正在更新 Sing-Box (官方正式版内核)..."
    if curl -fsSL https://sing-box.app/install.sh | sh; then
        log_success "Sing-Box 核心组件更新完毕！"
        return 0
    else
        log_error "Sing-Box 更新失败，请检查服务器网络。"
        return 1
    fi
}

# 获取当前已安装的 Sing-Box 版本号
get_singbox_version() {
    sing-box version 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([a-zA-Z0-9.\-]*)?' | head -n 1
}

# 获取 GitHub 上 Sing-Box 最新版本号
get_latest_singbox_version() {
    curl -s --connect-timeout 5 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | jq -r '.tag_name' 2>/dev/null | sed 's/^v//' || true
}

# ------------------------------------------------------------------------------
# 证书生成模块
# ------------------------------------------------------------------------------
enable_kernel_tfo() {
    local tfo_val
    tfo_val=$(cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null || echo "0")
    if [[ "$tfo_val" -lt 3 ]]; then
        log_info "正在开启系统内核 TFO 支持..."
        sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
        grep -q "tcp_fastopen" /etc/sysctl.conf 2>/dev/null && \
            sed -i 's/net.ipv4.tcp_fastopen.*/net.ipv4.tcp_fastopen=3/' /etc/sysctl.conf || \
            echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
        log_success "内核 TFO 已开启！"
    else
        log_success "内核 TFO 已就绪 (当前值: ${tfo_val})。"
    fi
}

generate_cert() {
    local sni="$1"
    mkdir -p "$TLS_DIR"
    log_info "正在为域名 [ ${sni} ] 生成自签名 ECC 证书..."
    
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$TLS_DIR/server.key" \
        -out "$TLS_DIR/server.crt" \
        -subj "/CN=${sni}" -days 3650 >/dev/null 2>&1

    if [[ -f "$TLS_DIR/server.key" && -f "$TLS_DIR/server.crt" ]]; then
        log_success "TLS 证书及私钥生成成功！"
    else
        log_error "证书生成失败！"
        pause
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 组件管理（安装 / 更新 Sing-Box 内核）
# ------------------------------------------------------------------------------
install_singbox() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                安装 Sing-Box                       ${NC}"
    echo -e "${CYAN}=====================================================${NC}"

    if command -v sing-box &>/dev/null; then
        local cur_ver
        cur_ver=$(get_singbox_version)
        log_info "已安装，无需重复安装 (当前版本: v${cur_ver:-未知})"
        pause
        return
    fi

    install_dependencies
    install_singbox_core || { pause; return 1; }
    pause
}

update_singbox() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                更新 Sing-Box                       ${NC}"
    echo -e "${CYAN}=====================================================${NC}"

    install_dependencies
    if update_singbox_core; then
        log_info "正在重启 Sing-Box 服务..."
        systemctl restart "$SERVICE_NAME"
        log_success "Sing-Box 服务已重启，现有节点配置保持不变！"
    fi
    pause
}

manage_component() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}              Sing-Box 组件管理                     ${NC}"
    echo -e "${CYAN}=====================================================${NC}"

    if command -v sing-box &>/dev/null; then
        local cur_ver
        cur_ver=$(get_singbox_version)
        echo -e " 1. 安装 Sing-Box ${GREEN}(已安装 v${cur_ver:-未知})${NC}"
    else
        echo -e " 1. 安装 Sing-Box"
    fi

    local latest_ver latest_display=""
    latest_ver=$(get_latest_singbox_version)
    if [[ -n "$latest_ver" && "$latest_ver" != "null" ]]; then
        latest_display=" ${GREEN}(最新版本 v${latest_ver})${NC}"
    fi
    echo -e " 2. 更新 Sing-Box${latest_display}"

    echo -e " 0. 返回主菜单"
    echo -e "${CYAN}-----------------------------------------------------${NC}"

    local opt
    read -rp " 请选择操作 [0-2]: " opt
    case "$opt" in
        1) install_singbox ;;
        2) update_singbox ;;
        0) return ;;
        *) log_error "无效选项"; sleep 1; return ;;
    esac
}

# ------------------------------------------------------------------------------
# 节点配置（仅负责生成节点信息并重启服务，不涉及内核安装）
# ------------------------------------------------------------------------------
configure_node() {
    if ! command -v sing-box &>/dev/null; then
        log_error "未检测到 Sing-Box 内核，请先通过菜单选项 1 (SingBox管理) 进行安装！"
        pause
        return
    fi

    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}             配置 Sing-Box 节点协议                 ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    echo -e " 1. 部署 ${BOLD}AnyTLS${NC}"
    echo -e " 2. 部署 ${BOLD}SS2022${NC}"
    echo -e " 3. 部署 ${BOLD}Snell v6${NC}"
    echo -e " 0. 返回主菜单"
    echo -e "${CYAN}-----------------------------------------------------${NC}"

    local mode
    read -rp " 请选择运行模式 [0-3]: " mode
    case "$mode" in
        1|2|3) ;;
        0) return ;;
        *) log_error "无效选项，请输入 0-3 中的数字。"; sleep 1; return ;;
    esac

    clear
    install_dependencies

    local inbounds_json="[]"
    local info_json="{}"
    if [[ -f "$INFO_PATH" ]]; then
        info_json=$(cat "$INFO_PATH")
    fi
    if [[ -f "$CONFIG_PATH" ]]; then
        inbounds_json=$(jq -c '.inbounds // []' "$CONFIG_PATH")
    fi

    if [[ "$mode" == "1" ]]; then
        echo -e "\n${YELLOW}>>>> 开始配置 AnyTLS <<<<${NC}"

        inbounds_json=$(echo "$inbounds_json" | jq 'map(select(.type != "anytls"))')
        info_json=$(echo "$info_json" | jq 'del(.anytls)')

        local t_port
        while :; do
            read -rp " 请输入端口 [默认: 2026]: " t_port
            t_port=${t_port:-2026}
            if ! validate_port "$t_port"; then
                log_warn "端口号不合法，请输入 1-65535 之间的整数。"
                continue
            fi
            if ! check_and_print_port_status "$t_port"; then
                continue
            fi
            break
        done

        read -rp " 请输入密码 [默认: 自动生成]: " t_pwd
        t_pwd=${t_pwd:-$(openssl rand -hex 16)}

        read -rp " 请输入 TLS 伪装域名 [默认: genshin.hoyoverse.com]: " t_sni
        t_sni=${t_sni:-genshin.hoyoverse.com}

        local t_tfo_enabled=false
        read -rp " 是否开启 TFO (TCP Fast Open)？[y/N]: " t_tfo_input
        if [[ "$t_tfo_input" =~ ^[Yy]$ ]]; then
            t_tfo_enabled=true
            enable_kernel_tfo
        fi

        generate_cert "$t_sni"

        local t_inbound
        t_inbound=$(jq -n \
            --arg p "$t_port" \
            --arg w "$t_pwd" \
            --argjson tfo "$t_tfo_enabled" \
            '{
                type: "anytls",
                listen: "::",
                listen_port: ($p | tonumber),
                tcp_fast_open: $tfo,
                users: [{ password: $w }],
                padding_scheme: ["stop=8","0=30-80","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"],
                tls: {
                    enabled: true,
                    certificate_path: "/root/AnyTLS/tls/server.crt",
                    key_path: "/root/AnyTLS/tls/server.key"
                }
            }')

        inbounds_json=$(echo "$inbounds_json" | jq --argjson new "$t_inbound" '. + [$new]')
        info_json=$(echo "$info_json" | jq --arg p "$t_port" --arg w "$t_pwd" --arg s "$t_sni" --argjson tfo "$t_tfo_enabled" \
            '. + {anytls: {port: $p, pwd: $w, sni: $s, tfo: $tfo}}')

        open_firewall_port "$t_port"
        log_success "AnyTLS 参数配置完成！"
    fi

    # 2) 配置 SS2022
    if [[ "$mode" == "2" ]]; then
        echo -e "\n${YELLOW}>>>> 开始配置 SS2022 <<<<${NC}"

        inbounds_json=$(echo "$inbounds_json" | jq 'map(select(.type != "shadowsocks"))')
        info_json=$(echo "$info_json" | jq 'del(.ss2022)')

        local ss_port
        while :; do
            read -rp " 请输入端口 [默认: 8388]: " ss_port
            ss_port=${ss_port:-8388}
            if ! validate_port "$ss_port"; then
                log_warn "端口号不合法，请输入 1-65535 之间的整数。"
                continue
            fi
            if [[ "$mode" == "3" && "$ss_port" == "$t_port" ]]; then
                log_warn "端口不能与 AnyTLS 端口重复！"
                continue
            fi
            if ! check_and_print_port_status "$ss_port"; then
                continue
            fi
            break
        done

        local ss_method
        while :; do
            echo -e " 请选择加密方式:"
            echo -e " 1. 2022-blake3-aes-128-gcm"
            echo -e " 2. 2022-blake3-aes-256-gcm"
            echo -e " 3. 2022-blake3-chacha20-poly1305"
            read -rp " 请选择 [默认: 1]: " ss_method
            ss_method=${ss_method:-1}
            case "$ss_method" in
                1) ss_method="2022-blake3-aes-128-gcm"; local ss_key_len=16; break ;;
                2) ss_method="2022-blake3-aes-256-gcm"; local ss_key_len=32; break ;;
                3) ss_method="2022-blake3-chacha20-poly1305"; local ss_key_len=32; break ;;
                *) log_warn "无效选项，请输入 1-3。";;
            esac
        done

        local ss_pwd
        read -rp " 请输入密码 [默认: 自动生成]: " ss_pwd
        ss_pwd=${ss_pwd:-$(sing-box generate rand --base64 "$ss_key_len")}

        while :; do
            local decoded_len
            decoded_len=$(printf '%s' "$ss_pwd" | base64 -d 2>/dev/null | wc -c | tr -d ' ' || echo 0)
            if [[ "$decoded_len" == "$ss_key_len" ]]; then
                break
            fi
            log_warn "密码格式或长度不符合 ${ss_method} 要求，请重新输入。"
            read -rp " 请输入密码 [${ss_key_len} 字节 Base64]: " ss_pwd
        done

        local ss_tfo_enabled=false
        read -rp " 是否开启 TFO (TCP Fast Open)？[y/N]: " ss_tfo_input
        if [[ "$ss_tfo_input" =~ ^[Yy]$ ]]; then
            ss_tfo_enabled=true
            enable_kernel_tfo
        fi

        local ss_inbound
        ss_inbound=$(jq -n \
            --arg p "$ss_port" \
            --arg m "$ss_method" \
            --arg w "$ss_pwd" \
            --argjson tfo "$ss_tfo_enabled" \
            '{
                type: "shadowsocks",
                listen: "::",
                listen_port: ($p | tonumber),
                tcp_fast_open: $tfo,
                method: $m,
                password: $w,
                multiplex: {
                    enabled: true
                }
            }')

        inbounds_json=$(echo "$inbounds_json" | jq --argjson new "$ss_inbound" '. + [$new]')
        info_json=$(echo "$info_json" | jq --arg p "$ss_port" --arg m "$ss_method" --arg w "$ss_pwd" --argjson tfo "$ss_tfo_enabled" \
            '. + {ss2022: {port: $p, method: $m, pwd: $w, tfo: $tfo}}')

        open_firewall_port "$ss_port"
        log_success "SS2022 参数配置完成！"
    fi

    # 3) 配置 Snell v6
    if [[ "$mode" == "3" ]]; then
        echo -e "\n${YELLOW}>>>> 开始配置 Snell v6 <<<<${NC}"

        inbounds_json=$(echo "$inbounds_json" | jq 'map(select(.type != "snell"))')
        info_json=$(echo "$info_json" | jq 'del(.snell)')

        local sn_port
        while :; do
            read -rp " 请输入端口 [默认: 6179]: " sn_port
            sn_port=${sn_port:-6179}
            if ! validate_port "$sn_port"; then
                log_warn "端口号不合法，请输入 1-65535 之间的整数。"
                continue
            fi
            if ! check_and_print_port_status "$sn_port"; then
                continue
            fi
            break
        done

        local sn_psk
        read -rp " 请输入 PSK [默认: 自动生成]: " sn_psk
        sn_psk=${sn_psk:-$(openssl rand -hex 16)}
        while :; do
            local psk_len=${#sn_psk}
            if [[ $psk_len -ge 12 && $psk_len -le 255 ]]; then
                break
            fi
            log_warn "PSK 长度不符合要求 (当前: ${psk_len} 字节，需 12~255 字节)，请重新输入。"
            read -rp " 请输入 PSK [12~255 字节]: " sn_psk
        done

        local sn_mode
        while :; do
            echo -e " 请选择流量整形模式:"
            echo -e " 1. default     (推荐，流量特征最分散)"
            echo -e " 2. unshaped    (关闭整形，性能最好)"
            echo -e " 3. unsafe-raw  (不安全原始模式，性能最高)"
            read -rp " 请选择 [默认: 1]: " sn_mode
            sn_mode=${sn_mode:-1}
            case "$sn_mode" in
                1) sn_mode="default"; break ;;
                2) sn_mode="unshaped"; break ;;
                3) sn_mode="unsafe-raw"; break ;;
                *) log_warn "无效选项，请输入 1-3。" ;;
            esac
        done

        local sn_tfo_enabled=false
        read -rp " 是否开启 TFO (TCP Fast Open)？[y/N]: " sn_tfo_input
        if [[ "$sn_tfo_input" =~ ^[Yy]$ ]]; then
            sn_tfo_enabled=true
            enable_kernel_tfo
        fi

        local sn_inbound
        sn_inbound=$(jq -n \
            --arg p "$sn_port" \
            --arg psk "$sn_psk" \
            --arg m "$sn_mode" \
            --argjson tfo "$sn_tfo_enabled" \
            '{
                type: "snell",
                listen: "::",
                listen_port: ($p | tonumber),
                tcp_fast_open: $tfo,
                version: 6,
                psk: $psk,
                mode: $m
            }')

        inbounds_json=$(echo "$inbounds_json" | jq --argjson new "$sn_inbound" '. + [$new]')
        info_json=$(echo "$info_json" | jq --arg p "$sn_port" --arg psk "$sn_psk" --arg m "$sn_mode" --argjson tfo "$sn_tfo_enabled" \
            '. + {snell: {port: $p, psk: $psk, mode: $m, tfo: $tfo}}')

        open_firewall_port "$sn_port"
        log_success "Snell v6 参数配置完成！"
    fi

    echo "$info_json" > "$INFO_PATH"
    mkdir -p "$(dirname "$CONFIG_PATH")"
    jq -n --argjson ib "$inbounds_json" '{log: {level: "info", timestamp: true}, inbounds: $ib}' > "$CONFIG_PATH"

    log_info "正在启动与重载 Sing-Box 服务..."
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"

    log_success "恭喜！Sing-Box 节点配置与部署完全成功！"
    pause
    show_links
}

# ------------------------------------------------------------------------------
# 从 INFO_PATH 重建 CONFIG_PATH 并重启服务
# ------------------------------------------------------------------------------
_rebuild_config() {
    local inbounds_json="[]"

    if jq -e .anytls "$INFO_PATH" >/dev/null 2>&1; then
        local t_inbound
        t_inbound=$(jq -n --argjson d "$(jq .anytls "$INFO_PATH")" '{
            type: "anytls",
            listen: "::",
            listen_port: ($d.port | tonumber),
            tcp_fast_open: $d.tfo,
            users: [{ password: $d.pwd }],
            padding_scheme: ["stop=8","0=30-80","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"],
            tls: { enabled: true, certificate_path: "/root/AnyTLS/tls/server.crt", key_path: "/root/AnyTLS/tls/server.key" }
        }')
        inbounds_json=$(echo "$inbounds_json" | jq --argjson new "$t_inbound" '. + [$new]')
    fi

    if jq -e .ss2022 "$INFO_PATH" >/dev/null 2>&1; then
        local ss_inbound
        ss_inbound=$(jq -n --argjson d "$(jq .ss2022 "$INFO_PATH")" '{
            type: "shadowsocks",
            listen: "::",
            listen_port: ($d.port | tonumber),
            tcp_fast_open: $d.tfo,
            method: $d.method,
            password: $d.pwd,
            multiplex: { enabled: true }
        }')
        inbounds_json=$(echo "$inbounds_json" | jq --argjson new "$ss_inbound" '. + [$new]')
    fi

    if jq -e .snell "$INFO_PATH" >/dev/null 2>&1; then
        local sn_inbound
        sn_inbound=$(jq -n --argjson d "$(jq .snell "$INFO_PATH")" '{
            type: "snell",
            listen: "::",
            listen_port: ($d.port | tonumber),
            tcp_fast_open: $d.tfo,
            version: 6,
            psk: $d.psk,
            mode: $d.mode
        }')
        inbounds_json=$(echo "$inbounds_json" | jq --argjson new "$sn_inbound" '. + [$new]')
    fi

    mkdir -p "$(dirname "$CONFIG_PATH")"
    jq -n --argjson ib "$inbounds_json" '{log: {level: "info", timestamp: true}, inbounds: $ib}' > "$CONFIG_PATH"
}

_reload_service() {
    _rebuild_config
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
    log_success "配置已保存，服务已重启！"
}

# ------------------------------------------------------------------------------
# 节点修改
# ------------------------------------------------------------------------------
modify_node() {
    if [[ ! -f "$INFO_PATH" ]]; then
        log_warn "未找到节点配置，请先部署节点。"
        pause
        return
    fi

    while :; do
        clear
        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}                   节点修改                         ${NC}"
        echo -e "${CYAN}=====================================================${NC}"

        local configured=()
        jq -e .anytls "$INFO_PATH" >/dev/null 2>&1 && configured+=("AnyTLS")
        jq -e .ss2022 "$INFO_PATH" >/dev/null 2>&1 && configured+=("SS2022")
        jq -e .snell  "$INFO_PATH" >/dev/null 2>&1 && configured+=("Snell v6")

        if [[ ${#configured[@]} -eq 0 ]]; then
            log_warn "未找到任何已配置的节点。"
            pause
            return
        fi

        local i=1
        for proto in "${configured[@]}"; do
            echo -e " ${i}. ${proto}"
            i=$((i+1))
        done
        echo -e " 0. 返回主菜单"
        echo -e "${CYAN}-----------------------------------------------------${NC}"

        local sel
        read -rp " 请选择要修改的节点 [0-${#configured[@]}]: " sel
        [[ "$sel" == "0" ]] && return
        if [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -gt "${#configured[@]}" ]]; then
            log_error "无效选项"; sleep 1; continue
        fi

        case "${configured[$((sel-1))]}" in
            "AnyTLS")   modify_anytls ;;
            "SS2022")   modify_ss2022 ;;
            "Snell v6") modify_snell ;;
        esac
    done
}

modify_anytls() {
    while :; do
        clear
        local cur_port cur_pwd cur_sni cur_tfo tfo_label
        cur_port=$(jq -r .anytls.port "$INFO_PATH")
        cur_pwd=$(jq -r .anytls.pwd "$INFO_PATH")
        cur_sni=$(jq -r .anytls.sni "$INFO_PATH")
        cur_tfo=$(jq -r .anytls.tfo "$INFO_PATH")
        tfo_label="关闭"; [[ "$cur_tfo" == "true" ]] && tfo_label="开启"

        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}                修改 AnyTLS 参数                    ${NC}"
        echo -e "${CYAN}=====================================================${NC}"
        echo -e " 1. 修改端口          (当前: ${cur_port})"
        echo -e " 2. 修改密码"
        echo -e " 3. 修改 TLS 伪装域名 (当前: ${cur_sni})"
        echo -e " 4. 重新生成证书"
        echo -e " 5. 切换 TFO          (当前: ${tfo_label})"
        echo -e " ${RED}6. 删除 AnyTLS${NC}"
        echo -e " 0. 返回"
        echo -e "${CYAN}-----------------------------------------------------${NC}"

        local opt
        read -rp " 请选择操作 [0-6]: " opt
        case "$opt" in
            1)
                local new_port
                while :; do
                    read -rp " 请输入新端口 [当前: ${cur_port}]: " new_port
                    new_port=${new_port:-$cur_port}
                    validate_port "$new_port" || { log_warn "端口号不合法。"; continue; }
                    [[ "$new_port" != "$cur_port" ]] && ! check_and_print_port_status "$new_port" && continue
                    break
                done
                jq --arg v "$new_port" '.anytls.port = $v' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                [[ "$new_port" != "$cur_port" ]] && open_firewall_port "$new_port"
                _reload_service; pause
                ;;
            2)
                local new_pwd
                read -rp " 请输入新密码 [回车自动生成]: " new_pwd
                new_pwd=${new_pwd:-$(openssl rand -hex 16)}
                jq --arg v "$new_pwd" '.anytls.pwd = $v' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                _reload_service; pause
                ;;
            3)
                local new_sni
                read -rp " 请输入新伪装域名 [当前: ${cur_sni}]: " new_sni
                new_sni=${new_sni:-$cur_sni}
                generate_cert "$new_sni"
                jq --arg v "$new_sni" '.anytls.sni = $v' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                _reload_service; pause
                ;;
            4)
                generate_cert "$cur_sni"
                _reload_service; pause
                ;;
            5)
                local new_tfo=true
                [[ "$cur_tfo" == "true" ]] && new_tfo=false
                [[ "$new_tfo" == "true" ]] && enable_kernel_tfo
                jq --argjson v "$new_tfo" '.anytls.tfo = $v' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                _reload_service; pause
                ;;
            6)
                read -rp " 确定要删除 AnyTLS 吗？此操作不可恢复 [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    jq 'del(.anytls)' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                    if [[ $(jq 'keys | length' "$INFO_PATH") -eq 0 ]]; then
                        systemctl stop "$SERVICE_NAME" || true
                        log_success "AnyTLS 已删除，当前无任何协议，服务已停止。"
                    else
                        _reload_service
                        log_success "AnyTLS 已删除，服务已重启。"
                    fi
                    pause; return
                fi
                ;;
            0) return ;;
            *) log_error "无效选项"; sleep 1 ;;
        esac
    done
}

modify_ss2022() {
    while :; do
        clear
        local cur_port cur_method cur_pwd cur_tfo tfo_label
        cur_port=$(jq -r .ss2022.port "$INFO_PATH")
        cur_method=$(jq -r .ss2022.method "$INFO_PATH")
        cur_pwd=$(jq -r .ss2022.pwd "$INFO_PATH")
        cur_tfo=$(jq -r .ss2022.tfo "$INFO_PATH")
        tfo_label="关闭"; [[ "$cur_tfo" == "true" ]] && tfo_label="开启"

        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}                修改 SS2022 参数                    ${NC}"
        echo -e "${CYAN}=====================================================${NC}"
        echo -e " 1. 修改端口        (当前: ${cur_port})"
        echo -e " 2. 修改加密方式    (当前: ${cur_method})"
        echo -e " 3. 修改密码"
        echo -e " 4. 切换 TFO        (当前: ${tfo_label})"
        echo -e " ${RED}5. 删除 SS2022${NC}"
        echo -e " 0. 返回"
        echo -e "${CYAN}-----------------------------------------------------${NC}"

        local opt
        read -rp " 请选择操作 [0-5]: " opt
        case "$opt" in
            1)
                local new_port
                while :; do
                    read -rp " 请输入新端口 [当前: ${cur_port}]: " new_port
                    new_port=${new_port:-$cur_port}
                    validate_port "$new_port" || { log_warn "端口号不合法。"; continue; }
                    [[ "$new_port" != "$cur_port" ]] && ! check_and_print_port_status "$new_port" && continue
                    break
                done
                jq --arg v "$new_port" '.ss2022.port = $v' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                [[ "$new_port" != "$cur_port" ]] && open_firewall_port "$new_port"
                _reload_service; pause
                ;;
            2)
                local new_method new_key_len
                while :; do
                    echo -e " 请选择加密方式:"
                    echo -e " 1. 2022-blake3-aes-128-gcm"
                    echo -e " 2. 2022-blake3-aes-256-gcm"
                    echo -e " 3. 2022-blake3-chacha20-poly1305"
                    read -rp " 请选择: " new_method
                    case "$new_method" in
                        1) new_method="2022-blake3-aes-128-gcm";       new_key_len=16; break ;;
                        2) new_method="2022-blake3-aes-256-gcm";       new_key_len=32; break ;;
                        3) new_method="2022-blake3-chacha20-poly1305"; new_key_len=32; break ;;
                        *) log_warn "无效选项。" ;;
                    esac
                done
                log_warn "加密方式已变更，需要重新设置密码。"
                local new_pwd
                new_pwd=$(sing-box generate rand --base64 "$new_key_len")
                read -rp " 请输入新密码 [回车自动生成]: " input_pwd
                [[ -n "$input_pwd" ]] && new_pwd="$input_pwd"
                while :; do
                    local decoded_len
                    decoded_len=$(printf '%s' "$new_pwd" | base64 -d 2>/dev/null | wc -c | tr -d ' ' || echo 0)
                    [[ "$decoded_len" == "$new_key_len" ]] && break
                    log_warn "密码长度不符合 ${new_method} 要求，请重新输入。"
                    read -rp " 请输入密码 [${new_key_len} 字节 Base64]: " new_pwd
                done
                jq --arg m "$new_method" --arg w "$new_pwd" '.ss2022.method = $m | .ss2022.pwd = $w' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                _reload_service; pause
                ;;
            3)
                local cur_key_len=16
                [[ "$cur_method" != "2022-blake3-aes-128-gcm" ]] && cur_key_len=32
                local new_pwd
                new_pwd=$(sing-box generate rand --base64 "$cur_key_len")
                read -rp " 请输入新密码 [回车自动生成]: " input_pwd
                [[ -n "$input_pwd" ]] && new_pwd="$input_pwd"
                while :; do
                    local decoded_len
                    decoded_len=$(printf '%s' "$new_pwd" | base64 -d 2>/dev/null | wc -c | tr -d ' ' || echo 0)
                    [[ "$decoded_len" == "$cur_key_len" ]] && break
                    log_warn "密码长度不符合要求，请重新输入。"
                    read -rp " 请输入密码 [${cur_key_len} 字节 Base64]: " new_pwd
                done
                jq --arg v "$new_pwd" '.ss2022.pwd = $v' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                _reload_service; pause
                ;;
            4)
                local new_tfo=true
                [[ "$cur_tfo" == "true" ]] && new_tfo=false
                [[ "$new_tfo" == "true" ]] && enable_kernel_tfo
                jq --argjson v "$new_tfo" '.ss2022.tfo = $v' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                _reload_service; pause
                ;;
            5)
                read -rp " 确定要删除 SS2022 吗？此操作不可恢复 [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    jq 'del(.ss2022)' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                    if [[ $(jq 'keys | length' "$INFO_PATH") -eq 0 ]]; then
                        systemctl stop "$SERVICE_NAME" || true
                        log_success "SS2022 已删除，当前无任何协议，服务已停止。"
                    else
                        _reload_service
                        log_success "SS2022 已删除，服务已重启。"
                    fi
                    pause; return
                fi
                ;;
            0) return ;;
            *) log_error "无效选项"; sleep 1 ;;
        esac
    done
}

modify_snell() {
    while :; do
        clear
        local cur_port cur_psk cur_mode cur_tfo tfo_label
        cur_port=$(jq -r .snell.port "$INFO_PATH")
        cur_psk=$(jq -r .snell.psk "$INFO_PATH")
        cur_mode=$(jq -r .snell.mode "$INFO_PATH")
        cur_tfo=$(jq -r .snell.tfo "$INFO_PATH")
        tfo_label="关闭"; [[ "$cur_tfo" == "true" ]] && tfo_label="开启"

        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}               修改 Snell v6 参数                   ${NC}"
        echo -e "${CYAN}=====================================================${NC}"
        echo -e " 1. 修改端口          (当前: ${cur_port})"
        echo -e " 2. 修改 PSK"
        echo -e " 3. 修改流量整形模式  (当前: ${cur_mode})"
        echo -e " 4. 切换 TFO          (当前: ${tfo_label})"
        echo -e " ${RED}5. 删除 Snell v6${NC}"
        echo -e " 0. 返回"
        echo -e "${CYAN}-----------------------------------------------------${NC}"

        local opt
        read -rp " 请选择操作 [0-5]: " opt
        case "$opt" in
            1)
                local new_port
                while :; do
                    read -rp " 请输入新端口 [当前: ${cur_port}]: " new_port
                    new_port=${new_port:-$cur_port}
                    validate_port "$new_port" || { log_warn "端口号不合法。"; continue; }
                    [[ "$new_port" != "$cur_port" ]] && ! check_and_print_port_status "$new_port" && continue
                    break
                done
                jq --arg v "$new_port" '.snell.port = $v' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                [[ "$new_port" != "$cur_port" ]] && open_firewall_port "$new_port"
                _reload_service; pause
                ;;
            2)
                local new_psk
                read -rp " 请输入新 PSK [回车自动生成]: " new_psk
                new_psk=${new_psk:-$(openssl rand -hex 16)}
                while :; do
                    local psk_len=${#new_psk}
                    [[ $psk_len -ge 12 && $psk_len -le 255 ]] && break
                    log_warn "PSK 长度不符合要求 (当前: ${psk_len} 字节，需 12~255 字节)。"
                    read -rp " 请输入 PSK: " new_psk
                done
                jq --arg v "$new_psk" '.snell.psk = $v' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                _reload_service; pause
                ;;
            3)
                local new_mode
                while :; do
                    echo -e " 请选择流量整形模式:"
                    echo -e " 1. default     (推荐，流量特征最分散)"
                    echo -e " 2. unshaped    (关闭整形，性能最好)"
                    echo -e " 3. unsafe-raw  (不安全原始模式，性能最高)"
                    read -rp " 请选择 [当前: ${cur_mode}]: " new_mode
                    case "$new_mode" in
                        1) new_mode="default";     break ;;
                        2) new_mode="unshaped";    break ;;
                        3) new_mode="unsafe-raw";  break ;;
                        *) log_warn "无效选项，请输入 1-3。" ;;
                    esac
                done
                jq --arg v "$new_mode" '.snell.mode = $v' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                _reload_service; pause
                ;;
            4)
                local new_tfo=true
                [[ "$cur_tfo" == "true" ]] && new_tfo=false
                [[ "$new_tfo" == "true" ]] && enable_kernel_tfo
                jq --argjson v "$new_tfo" '.snell.tfo = $v' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                _reload_service; pause
                ;;
            5)
                read -rp " 确定要删除 Snell v6 吗？此操作不可恢复 [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    jq 'del(.snell)' "$INFO_PATH" > /tmp/.sb_tmp.json && mv /tmp/.sb_tmp.json "$INFO_PATH"
                    if [[ $(jq 'keys | length' "$INFO_PATH") -eq 0 ]]; then
                        systemctl stop "$SERVICE_NAME" || true
                        log_success "Snell v6 已删除，当前无任何协议，服务已停止。"
                    else
                        _reload_service
                        log_success "Snell v6 已删除，服务已重启。"
                    fi
                    pause; return
                fi
                ;;
            0) return ;;
            *) log_error "无效选项"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 节点链接展示
# ------------------------------------------------------------------------------
show_links() {
    clear
    if [[ ! -f "$INFO_PATH" ]]; then
        log_warn "未找到节点配置元数据，请先进行部署。"
        pause
        return
    fi

    local ip
    ip=$(get_public_ip)

    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}               已生成的节点连接信息                ${NC}"
    echo -e "${CYAN}=====================================================${NC}\n"

    if jq -e .anytls "$INFO_PATH" >/dev/null 2>&1; then
        local p w s
        p=$(jq -r .anytls.port "$INFO_PATH")
        w=$(jq -r .anytls.pwd "$INFO_PATH")
        s=$(jq -r .anytls.sni "$INFO_PATH")

        local t_tfo_uri="" t_tfo_surge=""
        if jq -e '.anytls.tfo == true' "$INFO_PATH" >/dev/null 2>&1; then
            t_tfo_uri="&tfo=1"
            t_tfo_surge=", tfo=true"
        fi

        echo -e "${GREEN}[ AnyTLS 节点 ]: ${NC}"
        echo -e "${YELLOW}anytls://${w}@${ip}:${p}/?sni=${s}&insecure=1${t_tfo_uri}#AnyTLS_${ip}${NC}\n"

        echo -e "${GREEN}[ AnyTLS 节点 (Surge) ]: ${NC}"
        echo -e "${YELLOW}AnyTLS_${ip} = anytls, ${ip}, ${p}, password=${w}, tls=true, sni=${s}, skip-cert-verify=true${t_tfo_surge}${NC}\n"
    fi

    if jq -e .ss2022 "$INFO_PATH" >/dev/null 2>&1; then
        local ss_p ss_m ss_w ss_userinfo ss_uri
        ss_p=$(jq -r .ss2022.port "$INFO_PATH")
        ss_m=$(jq -r .ss2022.method "$INFO_PATH")
        ss_w=$(jq -r .ss2022.pwd "$INFO_PATH")

        local ss_tfo_uri="" ss_tfo_surge=""
        if jq -e '.ss2022.tfo == true' "$INFO_PATH" >/dev/null 2>&1; then
            ss_tfo_uri="?tfo=1"
            ss_tfo_surge=", tfo=true"
        fi

        ss_userinfo=$(printf '%s' "${ss_m}:${ss_w}" | base64 -w 0 2>/dev/null || printf '%s' "${ss_m}:${ss_w}" | base64 | tr -d '\n')
        ss_uri="ss://${ss_userinfo}@${ip}:${ss_p}/${ss_tfo_uri}#SS2022_${ip}"

        echo -e "${GREEN}[ SS2022 节点 ]: ${NC}"
        echo -e "${YELLOW}${ss_uri}${NC}\n"

        echo -e "${GREEN}[ SS2022 节点 (Surge) ]: ${NC}"
        echo -e "${YELLOW}SS2022_${ip} = ss, ${ip}, ${ss_p}, encrypt-method=${ss_m}, password=${ss_w}${ss_tfo_surge}${NC}\n"
    fi

    if jq -e .snell "$INFO_PATH" >/dev/null 2>&1; then
        local sn_p sn_psk sn_m
        sn_p=$(jq -r .snell.port "$INFO_PATH")
        sn_psk=$(jq -r .snell.psk "$INFO_PATH")
        sn_m=$(jq -r .snell.mode "$INFO_PATH")

        local sn_tfo_surge=""
        if jq -e '.snell.tfo == true' "$INFO_PATH" >/dev/null 2>&1; then
            sn_tfo_surge=", tfo=true"
        fi

        echo -e "${GREEN}[ Snell v6 节点 (Surge) ]: ${NC}"
        echo -e "${YELLOW}Snell_${ip} = snell, ${ip}, ${sn_p}, psk=${sn_psk}, version=6, mode=${sn_m}${sn_tfo_surge}${NC}\n"
    fi

    echo -e "${CYAN}=====================================================${NC}"
    pause
}

# ------------------------------------------------------------------------------
# 服务管理与状态模块
# ------------------------------------------------------------------------------
manage_service() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                   服务控制面板                     ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    echo -e " 1. 启动服务"
    echo -e " 2. 停止服务"
    echo -e " 3. 重启服务"
    echo -e " 0. 返回上一菜单"
    echo -e "${CYAN}-----------------------------------------------------${NC}"
    
    read -rp " 请选择操作 [0-3]: " act
    case "$act" in
        1) systemctl start "$SERVICE_NAME" && log_success "Sing-Box 服务启动成功！" ;;
        2) systemctl stop "$SERVICE_NAME" && log_success "Sing-Box 服务已停止！" ;;
        3) systemctl restart "$SERVICE_NAME" && log_success "Sing-Box 服务重启成功！" ;;
        0) return ;;
        *) log_error "无效选项"; sleep 1; return ;;
    esac
    pause
}

show_status() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}               Sing-Box 服务运行状态                ${NC}"
    echo -e "${CYAN}=====================================================${NC}\n"
    systemctl status "$SERVICE_NAME" --no-pager || true
    echo -e "\n${CYAN}=====================================================${NC}"
    pause
}

show_logs() {
    while :; do
        clear
        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}      正在查看实时日志 (退出日志预览按 Ctrl+C)      ${NC}"
        echo -e "${CYAN}=====================================================${NC}\n"
        
        trap - INT
        journalctl -u "$SERVICE_NAME" -e -f -n 50 || true
        
        trap 'echo -e "\n${RED}[!] 操作被用户中断${NC}"; exit 1' INT TERM

        echo -e "\n${CYAN}-----------------------------------------------------${NC}"
        echo -e " 1. 刷新重新查看日志"
        echo -e " 0. 返回主菜单"
        echo -e "${CYAN}-----------------------------------------------------${NC}"
        
        read -rp " 请选择 [0-1]: " log_opt
        case "$log_opt" in
            1) continue ;;
            0) break ;;
            *) break ;;
        esac
    done
}

uninstall_all() {
    clear
    echo -e "${RED}=====================================================${NC}"
    echo -e "${BOLD}                   卸载 Sing-Box                    ${NC}"
    echo -e "${RED}=====================================================${NC}"
    read -rp " 确定要彻底卸载 Sing-Box 及其所有配置文件吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "正在清理并卸载..."
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        
        rm -f /etc/systemd/system/"$SERVICE_NAME".service
        rm -f /usr/bin/"$SERVICE_NAME" /usr/local/bin/"$SERVICE_NAME" /usr/local/bin/sb /usr/bin/sb "$LOCAL_SCRIPT_PATH"
        rm -rf /etc/"$SERVICE_NAME" "$INFO_PATH" /root/AnyTLS
        
        systemctl daemon-reload
        log_success "Sing-Box 及脚本组件已彻底清理卸载完成！"
    else
        log_info "已取消卸载。"
    fi
    pause
}

# ------------------------------------------------------------------------------
# 主菜单循环
# ------------------------------------------------------------------------------
main_menu() {
    check_root
    force_register_shortcut

    while :; do
        clear
        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}       Sing-Box (AnyTLS / SS2022 / Snell) 管理脚本  ${NC}"
        echo -e "         快捷指令: 在终端输入 ${YELLOW}${BOLD}sb${NC} 即可快速打开"
        
        print_system_status

        if command -v sing-box &>/dev/null; then
            local cur_ver
            cur_ver=$(get_singbox_version)
            echo -e " ${GREEN}1.${NC} SingBox管理 (当前: v${cur_ver:-未知})"
        else
            echo -e " ${GREEN}1.${NC} 安装 SingBox"
        fi
        echo -e " ${GREEN}2.${NC} 节点部署"
        echo -e " ${GREEN}3.${NC} 节点修改"
        echo -e " ${GREEN}4.${NC} 服务管理 (启动/停止/重启)"
        echo -e " ${GREEN}5.${NC} 查看节点链接"
        echo -e " ${GREEN}6.${NC} 查看运行状态"
        echo -e " ${GREEN}7.${NC} 查看实时日志"
        echo -e " ${RED}8.${NC} 卸载 Sing-Box"
        echo -e " ${YELLOW}0.${NC} 退出脚本"
        echo -e "${CYAN}=====================================================${NC}"

        read -rp " 请输入选项 [0-8]: " opt
        case "$opt" in
            1)
                if command -v sing-box &>/dev/null; then
                    manage_component
                else
                    install_singbox
                fi
                ;;
            2) configure_node ;;
            3) modify_node ;;
            4) manage_service ;;
            5) show_links ;;
            6) show_status ;;
            7) show_logs ;;
            8) uninstall_all ;;
            0) 
                clear
                echo -e "${GREEN}感谢使用！随时输入 'sb' 唤醒本脚本。${NC}"
                exit 0 
                ;;
            *) 
                log_error "请输入正确的选项 [0-8]"
                sleep 1 
                ;;
        esac
    done
}

main_menu
