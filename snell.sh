#!/usr/bin/env bash

set -eo pipefail

# ------------------------------------------------------------------------------
# 全局变量与路径定义
# ------------------------------------------------------------------------------
readonly CONFIG_PATH="/etc/snell/snell-server.conf"
readonly SERVICE_PATH="/etc/systemd/system/snell.service"
readonly INFO_PATH="/root/.snell_info.json"
readonly LOCAL_SCRIPT_PATH="/root/snell.sh"
readonly BINARY_PATH="/usr/local/bin/snell-server"
readonly GITHUB_RELEASES_API="https://api.github.com/repos/passeway/Snell/releases?per_page=100"

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
# 全局唤醒命令
# ------------------------------------------------------------------------------
force_register_shortcut() {
    if [[ -s "$0" && "$0" != "bash" && "$0" != "-bash" && "$0" != "/bin/bash" && "$0" != "/usr/bin/bash" ]]; then
        cp -f "$0" "$LOCAL_SCRIPT_PATH" 2>/dev/null || true
    elif [[ -n "${BASH_SOURCE[0]:-}" && -s "${BASH_SOURCE[0]}" && "${BASH_SOURCE[0]}" != "$0" ]]; then
        cp -f "${BASH_SOURCE[0]}" "$LOCAL_SCRIPT_PATH" 2>/dev/null || true
    fi

    if [[ ! -s "$LOCAL_SCRIPT_PATH" ]]; then
        log_warn "检测到脚本以管道方式运行，无法注册 'snell' 快捷命令。"
        log_warn "请改用：curl -fsSL -o snell.sh <脚本地址> && bash snell.sh 的方式运行一次。"
    fi

    chmod +x "$LOCAL_SCRIPT_PATH" 2>/dev/null || true

    local target_paths=("/usr/local/bin/snell" "/usr/bin/snell")

    for path in "${target_paths[@]}"; do
        rm -rf "$path" 2>/dev/null || true

        cat << 'SCRIPT' > "$path"
#!/usr/bin/env bash
if [[ -s /root/snell.sh ]]; then
    exec bash /root/snell.sh "$@"
else
    echo -e "\033[0;31m[ERROR]\033[0m 未找到 /root/snell.sh，请先运行本脚本一次。"
    exit 1
fi
SCRIPT
        chmod +x "$path" 2>/dev/null || true
    done
}

# ------------------------------------------------------------------------------
# 端口与公网 IP
# ------------------------------------------------------------------------------
validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

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

    if (( is_busy )); then
        log_warn "检测到端口 ${port} ${RED}已被占用${NC}！"
        return 1
    fi

    log_success "检测到端口 ${port} ${GREEN}未被占用${NC}，可以使用。"
}

get_public_ip() {
    local ip
    ip=$(curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || true)
    [[ -z "$ip" ]] && ip=$(curl -s6 --connect-timeout 5 ifconfig.me 2>/dev/null || true)
    echo "${ip:-127.0.0.1}"
}

open_firewall_port() {
    local port="$1"
    log_info "正在为您自动放行防火墙端口 ${port}..."

    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        ufw allow "${port}/udp" >/dev/null 2>&1 || true
        log_success "UFW 防火墙端口 ${port} 放行成功！"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-port="${port}/udp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_success "Firewalld 防火墙端口 ${port} 放行成功！"
    fi
}

# ------------------------------------------------------------------------------
# 系统与架构检测
# ------------------------------------------------------------------------------
get_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        i386|i686) echo "i386" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armv7|armhf) echo "armv7l" ;;
        *)
            log_error "暂不支持的 CPU 架构: $(uname -m)"
            return 1
            ;;
    esac
}

install_dependencies() {
    log_info "检查并安装必要依赖组件..."

    if command -v apt-get &>/dev/null; then
        apt-get update -y -qq
        apt-get install -y -qq curl jq unzip ca-certificates openssl net-tools lsof
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl jq unzip ca-certificates openssl net-tools lsof
    elif command -v yum &>/dev/null; then
        yum install -y -q curl jq unzip ca-certificates openssl net-tools lsof
    else
        log_error "未识别到 apt/dnf/yum 包管理器。"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 动态获取官方最新 Release
# ------------------------------------------------------------------------------
get_latest_release_json() {
    local releases_json

    releases_json=$(curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: snell-installer" \
        "$GITHUB_RELEASES_API") || {
        log_error "无法从 GitHub 获取 Snell 官方 Release 列表。"
        return 1
    }

    echo "$releases_json" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 || {
        if echo "$releases_json" | jq -e '.message // "" | test("rate limit"; "i")' >/dev/null 2>&1; then
            log_error "GitHub API 请求过于频繁，已触发限流，请稍后再试。"
        else
            log_error "获取到的 Release 数据无效或为空。"
        fi
        return 1
    }

    # 不使用 GitHub 的 latest 字段；按官方发布时间从完整 Release 列表中选择最新发布项。
    echo "$releases_json" | jq '
        map(select((.draft == false) and ((.tag_name // "") | test("^v[0-9]+\\.[0-9]+\\.[0-9]+"))))
        | sort_by(.published_at // .created_at)
        | last
    '
}

get_release_info() {
    local release_json="$1"

    RELEASE_TAG=$(echo "$release_json" | jq -r '.tag_name')
    RELEASE_NAME=$(echo "$release_json" | jq -r '.name // .tag_name')
    RELEASE_PRERELEASE=$(echo "$release_json" | jq -r '.prerelease')
    RELEASE_URL=$(echo "$release_json" | jq -r '.html_url')

    RELEASE_MAJOR=$(echo "$RELEASE_TAG" | sed -nE 's/^v([0-9]+)\..*$/\1/p')
    RELEASE_MINOR=$(echo "$RELEASE_TAG" | sed -nE 's/^v[0-9]+\.([0-9]+)\..*$/\1/p')
    RELEASE_PATCH=$(echo "$RELEASE_TAG" | sed -nE 's/^v[0-9]+\.[0-9]+\.([0-9]+).*$/\1/p')

    if [[ -z "$RELEASE_MAJOR" ]]; then
        log_error "无法解析 Snell 版本号。"
        return 1
    fi

    if (( RELEASE_MAJOR > 6 )); then
        log_error "检测到 Snell v${RELEASE_MAJOR}；当前脚本按 Surge 当前支持的 Snell v1-v6 生成客户端配置。"
        return 1
    fi
}

find_release_asset() {
    local release_json="$1"
    local arch="$2"
    local asset_url

    asset_url=$(echo "$release_json" | jq -r --arg arch "$arch" '
        .assets[]
        | select((.name | ascii_downcase | test("linux")))
        | select((.name | ascii_downcase | contains($arch)))
        | select((.name | ascii_downcase | endswith(".zip")))
        | .browser_download_url
    ' | head -n 1)

    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
        log_error "未找到与架构 ${arch} 匹配的官方 Snell Linux ZIP 资产。"
        log_error "当前 Release: ${RELEASE_TAG}"
        echo "$release_json" | jq -r '.assets[].name' | sed 's/^/  - /'
        return 1
    fi

    echo "$asset_url"
}

# ------------------------------------------------------------------------------
# 版本能力判断
# ------------------------------------------------------------------------------
version_supports_mode() {
    [[ "$RELEASE_MAJOR" == "6" ]] || return 1

    # v6.0.0b3+、RC、正式版支持 mode。
    if [[ "$RELEASE_TAG" =~ ^v6\.[0-9]+\.[0-9]+b([0-9]+) ]]; then
        local beta_num="${BASH_REMATCH[1]}"
        if (( beta_num >= 3 )); then
            return 0
        else
            return 1
        fi
    fi

    if [[ "$RELEASE_TAG" =~ ^v6\.[0-9]+\.[0-9]+rc ]]; then
        return 0
    fi

    # v6 正式版
    if [[ "$RELEASE_TAG" =~ ^v6\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi

    return 1
}

# ------------------------------------------------------------------------------
# 配置生成
# ------------------------------------------------------------------------------
generate_psk() {
    openssl rand -hex 16
}

configure_mode() {
    SNELL_MODE=""

    if ! version_supports_mode; then
        return 0
    fi

    echo -e "\n${YELLOW}>>>> 配置 Snell v6 模式 <<<<${NC}"
    echo -e " 1. default       加密 + 流量整形（推荐）"
    echo -e " 2. unshaped      仅加密，关闭流量整形"
    echo -e " 3. unsafe-raw    明文模式（不推荐）"
    echo -e "${CYAN}-----------------------------------------------------${NC}"

    local mode_opt
    while :; do
        read -rp " 请选择模式 [默认: 1]: " mode_opt
        mode_opt=${mode_opt:-1}

        case "$mode_opt" in
            1)
                SNELL_MODE="default"
                break
                ;;
            2)
                SNELL_MODE="unshaped"
                break
                ;;
            3)
                log_warn "unsafe-raw 会关闭加密与流量整形，流量将以明文传输。"
                read -rp " 确认使用 unsafe-raw？[y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    SNELL_MODE="unsafe-raw"
                    break
                fi
                ;;
            *)
                log_warn "无效选项，请输入 1-3。"
                ;;
        esac
    done
}

write_config() {
    local port="$1"
    local psk="$2"

    mkdir -p "$(dirname "$CONFIG_PATH")"

    {
        echo "[snell-server]"
        echo "listen = 0.0.0.0:${port},[::]:${port}"
        echo "psk = ${psk}"
        if [[ -n "$SNELL_MODE" ]]; then
            echo "mode = ${SNELL_MODE}"
        fi
    } > "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
}

write_systemd_service() {
    cat > "$SERVICE_PATH" << EOF2
[Unit]
Description=Snell Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BINARY_PATH} -c ${CONFIG_PATH}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF2
}

# ------------------------------------------------------------------------------
# 安装 / 重构
# ------------------------------------------------------------------------------
install_node() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                  配置 Snell 节点                  ${NC}"
    echo -e "${CYAN}=====================================================${NC}"

    install_dependencies || return
    local arch
    arch=$(get_arch) || return

    log_info "当前系统架构: ${arch}"
    log_info "正在检查 Snell 官方最新 Release..."

    local release_json
    release_json=$(get_latest_release_json) || { pause; return; }
    get_release_info "$release_json" || { pause; return; }

    local asset_url
    asset_url=$(find_release_asset "$release_json" "$arch") || { pause; return; }

    echo -e "\n${CYAN}-----------------------------------------------------${NC}"
    echo -e " 最新版本: ${GREEN}${RELEASE_NAME}${NC}"
    echo -e " Tag:      ${GREEN}${RELEASE_TAG}${NC}"
    if [[ "$RELEASE_PRERELEASE" == "true" ]]; then
        echo -e " 类型:     ${YELLOW}Pre-release${NC}"
    else
        echo -e " 类型:     ${GREEN}正式版${NC}"
    fi
    echo -e " 架构:     ${GREEN}${arch}${NC}"
    echo -e "${CYAN}-----------------------------------------------------${NC}"

    local port
    while :; do
        read -rp " 请输入端口 [默认: 7177]: " port
        port=${port:-7177}
        if ! validate_port "$port"; then
            log_warn "端口号不合法，请输入 1-65535 之间的整数。"
            continue
        fi
        if ! check_and_print_port_status "$port"; then continue; fi
        break
    done

    local psk
    read -rp " 请输入 PSK [默认: 自动生成]: " psk
    psk=${psk:-$(generate_psk)}
    local psk_len
    psk_len=$(printf '%s' "$psk" | wc -c | tr -d ' ')
    while (( psk_len < 16 || psk_len > 255 )); do
        log_warn "PSK 长度必须在 16-255 字节之间。"
        read -rp " 请重新输入 PSK: " psk
        psk_len=$(printf '%s' "$psk" | wc -c | tr -d ' ')
    done

    configure_mode

    local tmp_dir archive_path
    tmp_dir=$(mktemp -d)
    archive_path="${tmp_dir}/snell.zip"

    log_info "正在下载官方 Snell ${RELEASE_TAG}..."
    curl -fL --connect-timeout 10 --retry 3 -o "$archive_path" "$asset_url" || {
        log_error "Snell 官方程序下载失败。"
        rm -rf "$tmp_dir"
        pause
        return
    }

    log_info "正在安装 Snell Server..."
    rm -f "$BINARY_PATH"
    if ! unzip -oq "$archive_path" -d "$tmp_dir/extract"; then
        log_error "官方 Snell 安装包解压失败。"
        rm -rf "$tmp_dir"
        pause
        return
    fi

    local extracted_binary
    extracted_binary=$(find "$tmp_dir/extract" -maxdepth 3 -type f -name "snell-server" | head -n 1)
    if [[ -z "$extracted_binary" ]]; then
        log_error "下载的官方 ZIP 中未找到 snell-server 二进制文件。"
        rm -rf "$tmp_dir"
        pause
        return
    fi

    if ! install -m 0755 "$extracted_binary" "$BINARY_PATH"; then
        log_error "Snell Server 二进制安装失败。"
        rm -rf "$tmp_dir"
        pause
        return
    fi
    rm -rf "$tmp_dir"

    write_config "$port" "$psk"
    write_systemd_service
    jq -n \
        --arg version "$RELEASE_TAG" \
        --arg name "$RELEASE_NAME" \
        --arg port "$port" \
        --arg psk "$psk" \
        --arg arch "$arch" \
        --arg mode "$SNELL_MODE" \
        '{version:$version,release_name:$name,port:$port,psk:$psk,arch:$arch,mode:$mode}' > "$INFO_PATH"
    chmod 600 "$INFO_PATH"

    open_firewall_port "$port"
    log_info "正在启动与重载 Snell 服务..."
    systemctl daemon-reload
    systemctl enable snell.service >/dev/null 2>&1
    systemctl restart snell.service

    if ! systemctl is-active --quiet snell.service; then
        log_error "Snell 服务启动失败，请查看运行状态和日志。"
        systemctl status snell.service --no-pager || true
        pause
        return
    fi

    log_success "Snell ${RELEASE_TAG} 安装与配置完成！"
    pause
    show_links
}

# ------------------------------------------------------------------------------
# 状态展示
# ------------------------------------------------------------------------------
print_system_status() {
    echo -e "${CYAN}-----------------------------------------------------${NC}"
    if [[ -f "$CONFIG_PATH" && -f "$INFO_PATH" && -x "$BINARY_PATH" ]]; then
        local version mode
        version=$(jq -r '.version // "未知"' "$INFO_PATH" 2>/dev/null || echo "未知")
        mode=$(jq -r '.mode // ""' "$INFO_PATH" 2>/dev/null || true)

        if systemctl is-active --quiet snell.service; then
            local pid
            pid=$(pgrep -f "snell-server" | head -n 1 || echo "未知")
            echo -e " 服务状态: ${GREEN}${BOLD}● 已安装并正常运行中${NC} (PID: ${pid})"
        else
            echo -e " 服务状态: ${YELLOW}${BOLD}● 已安装但未运行 (已停止)${NC}"
        fi
        echo -e " Snell 版本: ${CYAN}${version}${NC}"
        [[ -n "$mode" ]] && echo -e " 运行模式:   ${CYAN}${mode}${NC}"
    else
        echo -e " 服务状态: ${RED}${BOLD}○ 未安装 / 未配置${NC}"
    fi
    echo -e "${CYAN}-----------------------------------------------------${NC}"
}

# ------------------------------------------------------------------------------
# 节点信息展示
# ------------------------------------------------------------------------------
show_links() {
    clear
    if [[ ! -f "$INFO_PATH" ]]; then
        log_warn "未找到 Snell 节点配置，请先进行部署。"
        pause
        return
    fi

    local ip port psk version mode major
    ip=$(get_public_ip)
    port=$(jq -r '.port' "$INFO_PATH")
    psk=$(jq -r '.psk' "$INFO_PATH")
    version=$(jq -r '.version' "$INFO_PATH")
    mode=$(jq -r '.mode // ""' "$INFO_PATH")
    major=$(sed -nE 's/^v([0-9]+)\..*$/\1/p' <<<"$version")

    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}               已生成的 Snell 节点信息              ${NC}"
    echo -e "${CYAN}=====================================================${NC}\n"
    echo -e "${GREEN}[ Snell 节点 (Surge) ]: ${NC}"

    if [[ "$major" == "6" && -n "$mode" ]]; then
        echo -e "${YELLOW}Snell_${ip} = snell, ${ip}, ${port}, psk=${psk}, version=6, mode=${mode}${NC}"
    elif [[ "$major" == "6" ]]; then
        echo -e "${YELLOW}Snell_${ip} = snell, ${ip}, ${port}, psk=${psk}, version=6${NC}"
    else
        echo -e "${YELLOW}Snell_${ip} = snell, ${ip}, ${port}, psk=${psk}, version=${major}${NC}"
    fi

    echo -e "\n${CYAN}版本: ${version}${NC}"
    [[ -n "$mode" ]] && echo -e "${CYAN}模式: ${mode}${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    pause
}

# ------------------------------------------------------------------------------
# 服务管理
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
        1) systemctl start snell.service && log_success "Snell 服务启动成功！" ;;
        2) systemctl stop snell.service && log_success "Snell 服务已停止！" ;;
        3) systemctl restart snell.service && log_success "Snell 服务重启成功！" ;;
        0) return ;;
        *) log_error "无效选项"; sleep 1; return ;;
    esac
    pause
}

show_status() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}                  Snell 服务运行状态                 ${NC}"
    echo -e "${CYAN}=====================================================${NC}\n"
    print_system_status
    echo
    systemctl status snell.service --no-pager || true
    echo -e "\n${CYAN}=====================================================${NC}"
    pause
}

show_logs() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}       正在查看实时日志 (按 Ctrl+C 返回菜单)        ${NC}"
    echo -e "${CYAN}=====================================================${NC}\n"
    journalctl -u snell.service -e -f -n 50 || true
}

# ------------------------------------------------------------------------------
# 卸载
# ------------------------------------------------------------------------------
uninstall_all() {
    clear
    echo -e "${RED}=====================================================${NC}"
    echo -e "${BOLD}                     卸载 Snell                     ${NC}"
    echo -e "${RED}=====================================================${NC}"
    read -rp " 确定要彻底卸载 Snell 及其配置文件吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "正在清理并卸载..."
        systemctl stop snell.service >/dev/null 2>&1 || true
        systemctl disable snell.service >/dev/null 2>&1 || true
        rm -f "$SERVICE_PATH" "$BINARY_PATH"
        rm -f /usr/local/bin/snell /usr/bin/snell
        rm -f "$CONFIG_PATH" "$INFO_PATH" "$LOCAL_SCRIPT_PATH"
        systemctl daemon-reload
        log_success "Snell 及脚本组件已彻底清理卸载完成！"
    else
        log_info "已取消卸载。"
    fi
    pause
}

# ------------------------------------------------------------------------------
# 主菜单
# ------------------------------------------------------------------------------
main_menu() {
    check_root
    force_register_shortcut

    while :; do
        clear
        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}                 Snell 管理脚本                     ${NC}"
        echo -e "         快捷指令: 在终端输入 ${YELLOW}${BOLD}snell${NC} 即可快速打开"
        print_system_status
        echo -e " ${GREEN}1.${NC} 安装 / 重构节点"
        echo -e " ${GREEN}2.${NC} 服务管理 (启动/停止/重启)"
        echo -e " ${GREEN}3.${NC} 查看节点配置"
        echo -e " ${GREEN}4.${NC} 查看运行状态"
        echo -e " ${GREEN}5.${NC} 查看实时日志"
        echo -e " ${RED}6.${NC} 卸载 Snell"
        echo -e " ${YELLOW}0.${NC} 退出脚本"
        echo -e "${CYAN}=====================================================${NC}"

        read -rp " 请输入选项 [0-6]: " opt
        case "$opt" in
            1) install_node ;;
            2) manage_service ;;
            3) show_links ;;
            4) show_status ;;
            5) show_logs ;;
            6) uninstall_all ;;
            0)
                clear
                echo -e "${GREEN}感谢使用！随时输入 'snell' 唤醒本脚本。${NC}"
                exit 0
                ;;
            *)
                log_error "请输入正确的选项 [0-6]"
                sleep 1
                ;;
        esac
    done
}

main_menu
