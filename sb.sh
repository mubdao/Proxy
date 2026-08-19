#!/usr/bin/env bash
# ============================================================
# Sing-box 精简管理脚本（sb-mini.sh）
# ============================================================

set -Eeuo pipefail

# -------------------- 路径常量 --------------------
CONFIG_FILE="/etc/sing-box/config.json"
# 安装/更新 sing-box 二进制的来源仓库：官方 SagerNet/sing-box，
# 与本脚本本身是否基于 Tangfffyx/sing-box 二次开发完全无关，
# 这样即使 Tangfffyx/sing-box 这个仓库以后不在了，也不影响装/更新 sing-box。
SINGBOX_RELEASE_REPO="SagerNet/sing-box"
SINGBOX_INSTALL_DIR="/usr/local/bin"
SINGBOX_BIN="${SINGBOX_INSTALL_DIR}/sing-box"
SINGBOX_VERSION_STAMP="/etc/sing-box/.installed_release"
SB_LOCK_FILE="/var/lock/singbox-manager.lock"
SCRIPT_VERSION="slim-1.0.0 (base: Tangfffyx/sing-box 6.1.7)"

# -------------------- 颜色 --------------------
B='\033[1;34m'; G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'
C='\033[1;36m'; NC='\033[0m'; W='\033[1;37m'

# -------------------- 日志/UI 函数（原样保留） --------------------
say()  { echo -e "${C}[INFO]${NC} $*"; }
ok()   { echo -e "${G}[ OK ]${NC} $*"; }
warn() { echo -e "${Y}[WARN]${NC} $*" >&2; }
err()  { echo -e "${R}[ERR ]${NC} $*" >&2; }
pause(){ read -r -n 1 -p "按任意键继续..." || true; echo ""; }
ui_echo(){ printf '%b\n' "$*" >&2; }

param_echo() {
  local label="$1" value="$2"
  printf '  %b%s%b: %b%s%b\n' "$W" "$label" "$NC" "$C" "$value" "$NC" >&2
}

text_display_width() {
  local s="${1:-}"
  local width=0
  local i ch ord
  for ((i=0; i<${#s}; i++)); do
    ch="${s:i:1}"
    LC_ALL=C printf -v ord '%d' "'$ch" 2>/dev/null || ord=255
    if (( ord >= 32 && ord <= 126 )); then
      width=$((width + 1))
    else
      width=$((width + 2))
    fi
  done
  echo "$width"
}

pad_display_text() {
  local text="${1:-}"
  local target_width="${2:-0}"
  local current_width pad
  current_width="$(text_display_width "$text")"
  if [ "$current_width" -ge "$target_width" ]; then
    printf "%s" "$text"
    return 0
  fi
  pad=$((target_width - current_width))
  printf "%s%*s" "$text" "$pad" ""
}

print_rect_title() {
  local title="$1"
  local inner_width=46
  local title_width pad left right line
  title_width=$(text_display_width "$title")
  pad=$(( inner_width - title_width ))
  (( pad < 0 )) && pad=0
  left=$(( pad / 2 ))
  right=$(( pad - left ))
  line=$(printf '%*s' "$inner_width" '' | tr ' ' '-')
  printf "%b+%s+%b\n" "$B" "$line" "$NC"
  printf "%b|%*s%s%*s|%b\n" "$B" "$left" "" "$title" "$right" "" "$NC"
  printf "%b+%s+%b\n" "$B" "$line" "$NC"
}

# ====================================================
# 协议注册表（精简：只保留 anytls + shadowsocks）
# ====================================================
SUPPORTED_PROTOCOLS=(anytls shadowsocks)

declare -A PROTO_PREFIX=(
  [anytls]=anytls
  [shadowsocks]=ss
)

declare -A PREFIX_TO_PROTO=(
  [anytls]=anytls
  [ss]=shadowsocks
)

JQ_DETECT_PROTOCOL='
def detect_protocol:
  if .type == "anytls" then "anytls"
  elif .type == "shadowsocks" then "shadowsocks"
  else ""
  end;
'

# >>>>>>>>>>>>>>>>>>>> 01_utils.sh（原样保留，仅裁掉了 WARP/relay 相关的工具函数） <<<<<<<<<<<<<<<<<<<<

has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "请使用 root 运行此脚本。"
    exit 1
  fi
}

make_disk_tmp_dir() {
  local prefix="${1:-sb-install}" base="/var/tmp" tmp_dir
  mkdir -p "$base" 2>/dev/null || base="/tmp"
  tmp_dir="$(mktemp -d "${base}/${prefix}.XXXXXX")" || return 1
  echo "$tmp_dir"
}

random_b64_password() {
  local bytes="${1:-16}" value
  value="$(openssl rand -base64 "$bytes" 2>/dev/null || true)"
  if [ -z "$value" ]; then
    value="$(head -c "$bytes" /dev/urandom 2>/dev/null | openssl base64 -A 2>/dev/null || true)"
  fi
  [ -n "$value" ] && echo "$value"
}

run_with_timeout() {
  local seconds="$1"
  shift
  if has_cmd timeout; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

file_size_bytes() {
  local file="$1" size
  [ -f "$file" ] || { echo 0; return 0; }
  size="$(stat -c '%s' "$file" 2>/dev/null || wc -c < "$file" 2>/dev/null || echo 0)"
  size="${size//[[:space:]]/}"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  echo "$size"
}

download_file() {
  local url="$1" output="$2" connect_timeout="${3:-20}" retry_count="${4:-3}"
  curl -fsSL --connect-timeout "$connect_timeout" --retry "$retry_count" "$url" -o "$output"
}

now_ms() {
  local value
  value="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]{13,}$ ]]; then
    echo "$value"
    return 0
  fi
  value="$(date +%s 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo $((value * 1000))
  else
    echo 0
  fi
}

# ---------- 包管理器 / init 系统检测（原样保留） ----------

detect_pkg_manager() {
  if has_cmd apt-get; then echo "apt"
  elif has_cmd apk;   then echo "apk"
  else                     echo "unknown"
  fi
}
PKG_MANAGER="$(detect_pkg_manager)"

detect_init_system() {
  if has_cmd systemctl && systemctl --version >/dev/null 2>&1; then echo "systemd"
  elif has_cmd rc-service; then echo "openrc"
  else                          echo "unknown"
  fi
}
INIT_SYSTEM="$(detect_init_system)"

pkg_installed() {
  case "$PKG_MANAGER" in
    apt) [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" = "installed" ] ;;
    apk) apk info -e "$1" >/dev/null 2>&1 ;;
    *)   return 1 ;;
  esac
}

pkg_update_once() {
  local stamp="/tmp/.sb_pkg_updated"
  [ -f "$stamp" ] && return 0
  case "$PKG_MANAGER" in
    apt) say "更新包索引..."; apt-get update -y ;;
    apk) say "更新包索引..."; apk update -q ;;
  esac
  touch "$stamp"
}

install_pkg() {
  local pkg="$1"
  pkg_installed "$pkg" && return 0
  pkg_update_once
  say "安装依赖: $pkg"
  case "$PKG_MANAGER" in
    apt) apt-get install -y "$pkg" ;;
    apk) apk add -q "$pkg" ;;
    *)   err "不支持的包管理器，请手动安装: $pkg"; return 1 ;;
  esac
}

singbox_service_active() {
  case "$INIT_SYSTEM" in
    systemd) has_cmd systemctl && systemctl is-active --quiet sing-box 2>/dev/null ;;
    openrc)  rc-service sing-box status >/dev/null 2>&1 ;;
    *)       return 1 ;;
  esac
}

get_public_ip() {
  if [ -n "${_CACHED_PUBLIC_IP:-}" ]; then
    echo "$_CACHED_PUBLIC_IP"
    return 0
  fi
  local ip=""
  ip=$(curl -s4 --max-time 3 --connect-timeout 2 ifconfig.me 2>/dev/null || true)
  [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 --connect-timeout 2 api.ipify.org 2>/dev/null || true)
  [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 --connect-timeout 2 icanhazip.com 2>/dev/null | tr -d '\n' || true)
  [ -z "$ip" ] && ip="IP"
  _CACHED_PUBLIC_IP="$ip"
  echo "$ip"
}

ask_confirm_yn() {
  local prompt="${1:-确认继续吗？(y/N): }"
  local ans
  printf '%s' "$prompt" >&2
  read -r ans || ans=""
  [[ "$ans" =~ ^[Yy]$ ]]
}

is_valid_port() {
  local v="$1"
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  [ "$v" -ge 1 ] && [ "$v" -le 65535 ]
}

ask_port_or_return() {
  local prompt="$1" default="$2" outvar="$3"
  local val __retry
  while true; do
    read -r -p "$prompt" val
    if [ -z "$val" ]; then
      val="$default"
    fi
    if is_valid_port "$val"; then
      printf -v "$outvar" '%s' "$val"
      return 0
    fi
    warn "端口输入无效：${val}。请输入 1-65535 的数字，回车使用默认值 ${default}。"
    read -r -p "输入 1 重新填写，其它任意键返回上一级: " __retry
    [ "${__retry:-}" = "1" ] || return 1
  done
}

# >>>>>>>>>>>>>>>>>>>> 10_config.sh（原样保留：写入 -> check -> 重启 -> 失败回滚） <<<<<<<<<<<<<<<<<<<<

config_min_template() {
  cat <<'JSON'
{
  "log": {"level": "info", "output": "/var/log/sing-box/access.log", "timestamp": true},
  "inbounds": [],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "reject"}
  ],
  "route": {"rules": [], "final": "reject"},
  "experimental": {"cache_file": {"enabled": true}}
}
JSON
}

config_normalize() {
  local json="$1"
  if [ -z "$json" ]; then
    config_min_template
    return 0
  fi
  echo "$json" | jq '
    if type != "object" then
      {
        "log": {"level":"info","output":"/var/log/sing-box/access.log","timestamp":true},
        "inbounds": [],
        "outbounds": [
          {"type":"direct","tag":"direct"},
          {"type":"block","tag":"reject"}
        ],
        "route": {"rules": [], "final": "reject"}
      }
    else . end
    | .log = (.log // {"level":"info","output":"/var/log/sing-box/access.log","timestamp":true})
    | .inbounds = (.inbounds // [])
    | .outbounds = (.outbounds // [])
    | .route = (.route // {"rules": [], "final": "reject"})
    | .route.rules = (.route.rules // [])
    | .route.final = "reject"
    | .experimental = (.experimental // {})
    | .experimental.cache_file = (.experimental.cache_file // {})
    | .experimental.cache_file.enabled = true
    | if (.outbounds | any((.tag // "")=="direct")) then . else .outbounds += [{"type":"direct","tag":"direct"}] end
    | if (.outbounds | any((.tag // "")=="reject")) then . else .outbounds += [{"type":"block","tag":"reject"}] end
  '
}

config_load() {
  if [ -s "$CONFIG_FILE" ] && jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    config_normalize "$(cat "$CONFIG_FILE")"
  else
    config_min_template
  fi
}

config_ensure_exists() {
  mkdir -p /etc/sing-box
  chmod 700 /etc/sing-box 2>/dev/null || true
  if [ ! -e "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
    warn "未发现配置文件，将写入最小模板：$CONFIG_FILE"
    config_min_template | jq . > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    return 0
  fi
  if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    local ts broken
    ts="$(date +%Y%m%d_%H%M%S)"
    broken="${CONFIG_FILE}.broken.${ts}"
    cp -a "$CONFIG_FILE" "$broken" 2>/dev/null || true
    warn "检测到配置文件不是合法 JSON，已备份到：$broken"
    config_min_template | jq . > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    return 0
  fi
}

check_config_or_print() {
  if ! has_cmd sing-box; then
    err "未找到 sing-box 命令。请先安装。"
    return 1
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    err "未找到配置文件：$CONFIG_FILE"
    return 1
  fi
  if sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then
    return 0
  fi
  err "配置校验失败：sing-box check -c $CONFIG_FILE"
  sing-box check -c "$CONFIG_FILE" 2>&1 | sed 's/^/  /'
  return 1
}

reload_or_restart_singbox_safe() {
  if ! check_config_or_print; then
    err "已阻止热载：请先修复配置。"
    return 1
  fi
  local quiet="${_RESTART_SINGBOX_QUIET_OK:-0}" action=""
  case "$INIT_SYSTEM" in
    systemd)
      if [ "$quiet" = "1" ]; then
        if systemctl reload sing-box >/dev/null 2>&1; then action="热载"
        elif systemctl restart sing-box >/dev/null 2>&1; then action="重启"
        else return 1; fi
      else
        if systemctl reload sing-box 2>/dev/null; then action="热载"
        elif systemctl restart sing-box; then action="重启"
        else return 1; fi
      fi
      ;;
    openrc)
      if [ "$quiet" = "1" ]; then
        if rc-service sing-box reload >/dev/null 2>&1; then action="热载"
        elif rc-service sing-box restart >/dev/null 2>&1; then action="重启"
        else return 1; fi
      else
        if rc-service sing-box reload 2>/dev/null; then action="热载"
        elif rc-service sing-box restart; then action="重启"
        else return 1; fi
      fi
      ;;
    *) err "未识别的 init 系统，无法热载 sing-box。"; return 1 ;;
  esac
  [ "$quiet" = "1" ] || ok "sing-box 已${action}。"
}

enable_now_singbox_safe() {
  if ! check_config_or_print; then
    err "已阻止启动/自启：请先修复配置。"
    return 1
  fi
  case "$INIT_SYSTEM" in
    systemd)
      systemctl enable sing-box >/dev/null 2>&1 || return 1
      systemctl start sing-box >/dev/null 2>&1 || return 1
      sleep 1
      systemctl is-active --quiet sing-box 2>/dev/null || return 1
      ;;
    openrc)
      rc-update add sing-box default >/dev/null 2>&1 || return 1
      rc-service sing-box start >/dev/null 2>&1 || return 1
      sleep 1
      rc-service sing-box status >/dev/null 2>&1 || return 1
      ;;
    *) err "未识别的 init 系统，无法启动 sing-box。"; return 1 ;;
  esac
  ok "sing-box 已启用自启并启动。"
}

with_manager_lock() {
  local _lock_fd _rc=0
  if [ "${_CONFIG_LOCK_HELD:-0}" = "1" ]; then
    if "$@"; then return 0; else return $?; fi
  fi
  if ! has_cmd flock; then
    if "$@"; then return 0; else return $?; fi
  fi
  mkdir -p "$(dirname "$SB_LOCK_FILE")" 2>/dev/null || true
  if { exec {_lock_fd}>"$SB_LOCK_FILE"; } 2>/dev/null; then
    if flock "$_lock_fd"; then
      _CONFIG_LOCK_HELD=1
      if "$@"; then _rc=0; else _rc=$?; fi
      _CONFIG_LOCK_HELD=0
      { exec {_lock_fd}>&-; } 2>/dev/null || true
    else
      { exec {_lock_fd}>&-; } 2>/dev/null || true
      if "$@"; then _rc=0; else _rc=$?; fi
    fi
  else
    if "$@"; then _rc=0; else _rc=$?; fi
  fi
  return $_rc
}

config_apply() {
  with_manager_lock _config_apply_body "$@"
}

# 【与原版的唯一差异】：原版这里会调用 sync_user_usage_counters（用户流量统计模块，
# 已删除），本版本去掉了这一行，其余"写入临时文件 -> sing-box check -> 备份旧配置
# -> mv 生效 -> 热载/重启 -> 失败回滚"流程与原版完全一致。
_config_apply_body() {
  local json="$1"
  local normalized
  normalized="$(config_normalize "$json")"

  if ! echo "$normalized" | jq -e 'type=="object"' >/dev/null 2>&1; then
    err "内部错误：即将写入的配置不是 JSON object。"
    return 1
  fi

  if ! echo "$normalized" | jq -e '
    (.route.final // "") as $final
    | ($final == "" or ([.outbounds[]? | (.tag // "")] | index($final) != null))
  ' >/dev/null 2>&1; then
    err "配置校验失败：route.final 指向的 outbound 不存在。"
    return 1
  fi

  local tmp_file
  tmp_file="$(mktemp /etc/sing-box/config.json.tmp.XXXXXX)" || {
    err "创建临时配置文件失败。"
    return 1
  }

  echo "$normalized" | jq . > "$tmp_file" || {
    err "JSON 格式化失败，未写入配置。"
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  }

  if ! has_cmd sing-box; then
    err "未找到 sing-box，无法校验配置。"
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  fi

  if ! sing-box check -c "$tmp_file" >/dev/null 2>&1; then
    err "sing-box check 校验未通过，未写入配置。"
    sing-box check -c "$tmp_file" 2>&1 | sed 's/^/  /'
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  fi

  local ts backup prev_tmp
  ts="$(date +%Y%m%d_%H%M%S)"
  backup="/etc/sing-box/config.json.bak.fail.$ts"
  prev_tmp="$(mktemp /etc/sing-box/config.json.prev.XXXXXX)" || {
    err "创建回滚临时文件失败。"
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  }
  chmod 600 "$prev_tmp" 2>/dev/null || true

  if [ -f "$CONFIG_FILE" ]; then
    if ! cp -a "$CONFIG_FILE" "$prev_tmp"; then
      err "无法备份旧配置：$CONFIG_FILE → $prev_tmp"
      rm -f "$tmp_file" "$prev_tmp" >/dev/null 2>&1 || true
      return 1
    fi
  else
    if ! : > "$prev_tmp"; then
      err "无法初始化回滚备份文件：$prev_tmp"
      rm -f "$tmp_file" "$prev_tmp" >/dev/null 2>&1 || true
      return 1
    fi
  fi

  mv -f "$tmp_file" "$CONFIG_FILE" || {
    err "配置文件写入失败：$CONFIG_FILE"
    rm -f "$tmp_file" "$prev_tmp" >/dev/null 2>&1 || true
    return 1
  }
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true

  if _RESTART_SINGBOX_QUIET_OK=1 reload_or_restart_singbox_safe; then
    case "$INIT_SYSTEM" in
      systemd) systemctl enable sing-box >/dev/null 2>&1 || true ;;
      openrc)  rc-update add sing-box default >/dev/null 2>&1 || true ;;
    esac
    rm -f "$prev_tmp" >/dev/null 2>&1 || true
    ls -1t /etc/sing-box/config.json.bak.fail.* 2>/dev/null | tail -n +2 | xargs rm -f -- 2>/dev/null || true
    [ "${_CONFIG_APPLY_QUIET_OK:-0}" = "1" ] || ok "配置已应用。"
    return 0
  fi

  err "热载/重启失败：正在回滚。"
  if [ -f "$prev_tmp" ] && [ -s "$prev_tmp" ]; then
    cp -a "$prev_tmp" "$backup" || warn "失败现场备份未能保存到 $backup"
    if ! cp -a "$prev_tmp" "$CONFIG_FILE"; then
      err "回滚 cp 失败，sing-box 可能仍运行在坏配置上。手动恢复：cp $prev_tmp $CONFIG_FILE"
      return 1
    fi
    warn "已生成失败备份：$backup"
  else
    cp -a "$CONFIG_FILE" "$backup" 2>/dev/null || true
    warn "无旧配置可回滚，已保存失败现场：$backup"
  fi
  rm -f "$prev_tmp" >/dev/null 2>&1 || true
  if ! reload_or_restart_singbox_safe; then
    err "回滚后热载/重启仍失败，sing-box 当前可能处于异常状态。"
    warn "手动恢复命令："
    case "$INIT_SYSTEM" in
      systemd) warn "  systemctl start sing-box" ;;
      openrc)  warn "  rc-service sing-box start" ;;
    esac
    warn "如需恢复到失败前的配置，请检查：$backup"
  fi
  return 1
}

init_manager_env() {
  [ "${_MANAGER_ENV_READY:-0}" = "1" ] && return 0
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "请使用 root 运行此脚本。"
    return 1
  fi
  has_cmd jq || { err "未找到 jq，请先安装 sing-box（会自动装依赖）或手动 apt/apk 装 jq。"; return 1; }
  has_cmd curl || { err "未找到 curl。"; return 1; }
  has_cmd openssl || { err "未找到 openssl。"; return 1; }
  has_cmd sing-box || { err "未找到 sing-box，请先在主菜单选择「安装/更新 sing-box」。"; return 1; }
  [ "$INIT_SYSTEM" = "unknown" ] && { err "未识别的 init 系统（需要 systemd 或 OpenRC）。"; return 1; }
  config_ensure_exists
  mkdir -p /etc/sing-box
  chmod 700 /etc/sing-box 2>/dev/null || true
  [ -e "$CONFIG_FILE" ] && chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  _MANAGER_ENV_READY=1
}

# >>>>>>>>>>>>>>>>>>>> 20_protocol.sh（AnyTLS 部分原样保留） <<<<<<<<<<<<<<<<<<<<

entry_key_prefix_by_type() {
  local proto="$1"
  local prefix="${PROTO_PREFIX[$proto]:-}"
  if [ -z "$prefix" ]; then return 1; fi
  echo "$prefix"
}

entry_key_from_parts() {
  local proto="$1" port="$2"
  local prefix
  prefix="$(entry_key_prefix_by_type "$proto")" || return 1
  echo "${prefix}-${port}"
}

entry_key_to_protocol_label() {
  local key="$1"
  local prefix
  for prefix in "${!PREFIX_TO_PROTO[@]}"; do
    if [[ "$key" == "${prefix}-"* ]]; then
      echo "${PREFIX_TO_PROTO[$prefix]}"
      return 0
    fi
  done
  echo "unknown"
}

entry_key_to_port() {
  echo "$1" | awk -F- '{print $NF}'
}

# ---------- TLS 证书（原样保留） ----------

ensure_self_signed_cert() {
  local cn="$1" crt_path="$2" key_path="$3"
  mkdir -p "$(dirname "$crt_path")" || return 1
  openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$key_path" -out "$crt_path" -days 36500 -nodes -subj "/CN=${cn}" >/dev/null 2>&1 || return 1
  [ -s "$crt_path" ] && [ -s "$key_path" ]
}

# ---------- TLS 域名选择（原样保留：AnyTLS 安装与"重新选择 SNI"都调用这一套） ----------

get_tls_domain_candidates() {
  cat <<'EOF_TLS'
assets.adobedtm.com
lpcdn.lpsnmedia.net
s.go-mpulse.net
d0.m.awsstatic.com
a0.awsstatic.com
devblogs.microsoft.com
ds-aksb-a.akamaihd.net
tag.demandbase.com
electronics.sony.com
tag-logger.demandbase.com
d3agakyjgjv5i8.cloudfront.net
ms-python.gallerycdn.vsassets.io
img-prod-cms-rt-microsoft-com.akamaized.net
cdn.bizible.com
store-images.s-microsoft.com
catalog.gamepass.com
www.nvidia.com
mscom.demdex.net
drivers.amd.com
azure.microsoft.com
downloadmirror.intel.com
prod.us-east-1.ui.gcr-chat.marketing.aws.dev
r.bing.com
www.intel.com
ms-vscode.gallerycdn.vsassets.io
rum.hlx.page
www.tesla.com
ts2.tc.mm.bing.net
res-1.cdn.office.net
cdn-dynmedia-1.microsoft.com
EOF_TLS
}

benchmark_tls_domain_ms() {
  local domain="$1" t1 t2
  t1="$(now_ms)"
  run_with_timeout 1 openssl s_client -connect "${domain}:443" -servername "$domain" </dev/null >/dev/null 2>&1 || return 1
  t2="$(now_ms)"
  if [[ "$t1" =~ ^[0-9]+$ ]] && [[ "$t2" =~ ^[0-9]+$ ]] && [ "$t2" -ge "$t1" ]; then
    echo $((t2 - t1))
  else
    echo 999
  fi
}

auto_pick_tls_domain() {
  local best_domain="" best_ms=999999 ms domain
  local -a candidates=()
  mapfile -t candidates < <(get_tls_domain_candidates)
  local total=${#candidates[@]}
  if [ "$total" -gt 10 ]; then
    local -a sampled=()
    local -a indices=()
    while [ ${#sampled[@]} -lt 10 ]; do
      local r=$((RANDOM % total))
      local dup=0 idx
      for idx in "${indices[@]}"; do
        [ "$idx" -eq "$r" ] && { dup=1; break; }
      done
      [ $dup -eq 0 ] && { sampled+=("${candidates[$r]}"); indices+=("$r"); }
    done
    candidates=("${sampled[@]}")
  fi
  for domain in "${candidates[@]}"; do
    [ -n "$domain" ] || continue
    ms="$(benchmark_tls_domain_ms "$domain" 2>/dev/null || true)"
    if [ -n "$ms" ] && [[ "$ms" =~ ^[0-9]+$ ]] && [ "$ms" -lt "$best_ms" ]; then
      best_ms="$ms"
      best_domain="$domain"
    fi
  done
  [ -n "$best_domain" ] || return 1
  printf '%s\t%s\n' "$best_domain" "$best_ms"
}

choose_tls_domain() {
  local proto_label="$1" choice manual picked picked_ms
  ui_echo "1. 手动输入"
  ui_echo "2. 自动测速选择推荐域名"
  read -r -p "请选择域名填写方式（回车默认2. 自动测速选择推荐域名）: " choice
  case "${choice:-2}" in
    1)
      read -r -p "请输入${proto_label}域名（回车返回）: " manual
      if [ -z "${manual:-}" ]; then
        warn "输入无效，已返回上一级。"
        pause >&2
        return 1
      fi
      param_echo "SNI" "$manual"
      echo "$manual"
      ;;
    *)
      picked="$(auto_pick_tls_domain 2>/dev/null || true)"
      if [ -n "$picked" ]; then
        picked_ms="${picked#*$'\t'}"
        picked="${picked%%$'\t'*}"
        param_echo "SNI" "${picked} (${picked_ms} ms)"
        echo "$picked"
      else
        warn "自动测速失败，已返回上一级。"
        pause >&2
        return 1
      fi
      ;;
  esac
}

# ---------- AnyTLS inbound 构建器（原样保留，一字未改） ----------

build_anytls_inbound() {
  local port="$1" sni="$2" pass="${3:-}"
  local entry_key crt key
  entry_key="$(entry_key_from_parts anytls "$port")"
  [ -n "$pass" ] || pass="$(random_b64_password 16)"
  crt="/etc/sing-box/anytls-${port}.crt"
  key="/etc/sing-box/anytls-${port}.key"
  ensure_self_signed_cert "$sni" "$crt" "$key" || return 1
  jq -n --arg tag "$entry_key" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" --argjson port "$port" '
    {
      "type":"anytls",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"password":$pass}],
      "padding_scheme":[],
      "tls":{
        "enabled":true,
        "server_name":$sni,
        "certificate_path":$crt,
        "key_path":$key,
        "alpn":["h2","http/1.1"]
      }
    }
  '
}

# ---------- Shadowsocks（新增：单密钥、可选 method 版本，替代原版的多用户双密钥版本） ----------

declare -A SS_METHOD_KEY_BYTES=(
  [2022-blake3-aes-128-gcm]=16
  [2022-blake3-aes-256-gcm]=32
  [2022-blake3-chacha20-poly1305]=32
  [aes-256-gcm]=0
  [aes-128-gcm]=0
  [chacha20-ietf-poly1305]=0
)
SS_METHOD_ORDER=(2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305 aes-256-gcm aes-128-gcm chacha20-ietf-poly1305)

ss_method_key_bytes() {
  echo "${SS_METHOD_KEY_BYTES[$1]:-0}"
}

# 密码是否满足该 method 的长度要求（对 2022-* 系列，密码必须是能 base64
# 解码出恰好 N 字节的字符串；legacy AEAD 系列没有固定长度要求）
ss_password_valid_for_method() {
  local method="$1" pw="$2" need bytes
  need="$(ss_method_key_bytes "$method")"
  [ "$need" -eq 0 ] && { [ -n "$pw" ]; return $?; }
  [ -n "$pw" ] || return 1
  bytes="$(printf '%s' "$pw" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" || return 1
  [ "$bytes" = "$need" ]
}

ss_gen_password_for_method() {
  local method="$1" need
  need="$(ss_method_key_bytes "$method")"
  [ "$need" -eq 0 ] && need=16
  random_b64_password "$need"
}

build_ss_inbound() {
  local port="$1" method="$2" password="$3"
  local entry_key
  entry_key="$(entry_key_from_parts shadowsocks "$port")"
  jq -n --arg tag "$entry_key" --arg method "$method" --arg pass "$password" --argjson port "$port" '
    {
      "type":"shadowsocks",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "method":$method,
      "password":$pass
    }
  '
}

cleanup_inbound_generated_cert_files() {
  local json="$1" entry_key="$2"
  local crt key
  crt="$(echo "$json" | jq -r --arg ek "$entry_key" '.inbounds[]? | select((.tag // "") == $ek) | .tls.certificate_path // empty' | head -n1)"
  key="$(echo "$json" | jq -r --arg ek "$entry_key" '.inbounds[]? | select((.tag // "") == $ek) | .tls.key_path // empty' | head -n1)"
  if [ -n "$crt" ] && [[ "$crt" == /etc/sing-box/* ]]; then
    rm -f "$crt" >/dev/null 2>&1 || true
  fi
  if [ -n "$key" ] && [[ "$key" == /etc/sing-box/* ]]; then
    rm -f "$key" >/dev/null 2>&1 || true
  fi
}

# >>>>>>>>>>>>>>>>>>>> 协议清单查询（原样保留，逻辑不变，仅协议范围收窄） <<<<<<<<<<<<<<<<<<<<

protocol_entry_inventory() {
  local json="$1"
  echo "$json" | jq -r "${JQ_DETECT_PROTOCOL}"'
    .inbounds[]?
    | (detect_protocol) as $proto
    | select($proto != "")
    | [(.tag // ""), $proto, ((.listen_port // 0) | tostring)]
    | join("\u0001")
  '
}

find_inbound_by_entry_key() {
  local json="$1" entry_key="$2"
  echo "$json" | jq -c --arg ek "$entry_key" '.inbounds[]? | select(.tag==$ek)' | head -n1
}

# 简化版删除：因为已经没有中转/多用户/WARP，不需要清理 auth_user 路由规则
# 和衍生 outbound，只需要把对应 inbound 从数组里摘掉。
remove_inbound_by_entry_key_simple() {
  local json="$1" entry_key="$2"
  echo "$json" | jq --arg ek "$entry_key" '.inbounds |= map(select((.tag // "") != $ek))'
}

# ============================================================
# Shadowsocks 节点管理（新增：编排逻辑，内部调用上面原样保留/新增的构建函数）
# ============================================================

ss_pick_free_port() {
  local json="$1" port
  while true; do
    port=$(( (RANDOM % 20001) + 20000 ))
    if ! echo "$json" | jq -e --arg p "$port" '.inbounds[]? | select((.listen_port|tostring)==$p)' >/dev/null 2>&1; then
      echo "$port"
      return 0
    fi
  done
}

ss_port_conflict() {
  local json="$1" port="$2" exclude_tag="${3:-}"
  echo "$json" | jq -e --arg p "$port" --arg ex "$exclude_tag" '
    .inbounds[]? | select((.listen_port|tostring)==$p) | select(($ex=="") or ((.tag // "")!=$ex))
  ' >/dev/null 2>&1
}

ss_choose_method() {
  local outvar="$1" choice i=1
  echo "支持的 Shadowsocks 加密方式："
  for m in "${SS_METHOD_ORDER[@]}"; do
    echo "  ${i}. ${m}"
    i=$((i+1))
  done
  read -r -p "请选择（回车默认 1. ${SS_METHOD_ORDER[0]}）: " choice
  choice="${choice:-1}"
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#SS_METHOD_ORDER[@]}" ]; then
    warn "无效选择。"
    return 1
  fi
  printf -v "$outvar" '%s' "${SS_METHOD_ORDER[$((choice-1))]}"
}

ss_link_for_inbound() {
  local inbound="$1" ip tag method password port b64
  ip="$(get_public_ip)"
  tag="$(echo "$inbound" | jq -r '.tag')"
  method="$(echo "$inbound" | jq -r '.method')"
  password="$(echo "$inbound" | jq -r '.password')"
  port="$(echo "$inbound" | jq -r '.listen_port')"
  b64="$(printf '%s:%s' "$method" "$password" | base64 -w0 2>/dev/null || printf '%s:%s' "$method" "$password" | base64)"
  echo "ss://${b64}@${ip}:${port}#${tag}"
}

ss_add() {
  init_manager_env || { pause; return 0; }
  local json port method password inbound
  json="$(config_load)"

  local default_port
  default_port="$(ss_pick_free_port "$json")"
  ask_port_or_return "请输入 Shadowsocks 端口（回车默认随机可用端口 ${default_port}）: " "$default_port" port || { pause; return 0; }
  if ss_port_conflict "$json" "$port"; then
    err "端口 ${port} 已被其它协议占用。"
    pause
    return 1
  fi

  ss_choose_method method || { pause; return 0; }

  read -r -p "请输入密码（回车自动生成符合 ${method} 长度要求的密码）: " password
  if [ -z "${password:-}" ]; then
    password="$(ss_gen_password_for_method "$method")"
  elif ! ss_password_valid_for_method "$method" "$password"; then
    warn "该密码不满足 ${method} 的密钥长度要求（需要 base64 解码后恰好 $(ss_method_key_bytes "$method") 字节），已自动改为随机生成。"
    password="$(ss_gen_password_for_method "$method")"
  fi

  inbound="$(build_ss_inbound "$port" "$method" "$password")" || { err "构建 Shadowsocks inbound 失败。"; pause; return 1; }

  json="$(echo "$json" | jq --argjson nb "$inbound" '.inbounds += [$nb]')"
  if config_apply "$json"; then
    ok "Shadowsocks 节点已添加。"
    echo
    ss_link_for_inbound "$inbound"
  else
    warn "添加失败，配置未生效。"
  fi
  pause
}

ss_list_entries() {
  local json="$1"
  protocol_entry_inventory "$json" | awk -F'\x01' -v proto="shadowsocks" '$2==proto {print $0}'
}

ss_pick_entry_or_return() {
  local json="$1" outvar="$2"
  local -a lines=()
  mapfile -t lines < <(ss_list_entries "$json")
  if [ ${#lines[@]} -eq 0 ]; then
    warn "当前没有 Shadowsocks 节点。"
    return 1
  fi
  local i=1 tag proto port
  echo "当前 Shadowsocks 节点："
  for line in "${lines[@]}"; do
    IFS=$'\x01' read -r tag proto port <<< "$line"
    echo "  [$i] ${tag}  端口:${port}"
    i=$((i+1))
  done
  local choice
  read -r -p "请选择编号（回车返回上一级）: " choice
  [ -n "${choice:-}" ] || return 1
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#lines[@]}" ]; then
    warn "无效选择。"
    return 1
  fi
  IFS=$'\x01' read -r tag proto port <<< "${lines[$((choice-1))]}"
  printf -v "$outvar" '%s' "$tag"
}

ss_modify() {
  init_manager_env || { pause; return 0; }
  local json tag inbound cur_port cur_method cur_password
  json="$(config_load)"
  ss_pick_entry_or_return "$json" tag || { pause; return 0; }
  inbound="$(find_inbound_by_entry_key "$json" "$tag")"
  cur_port="$(echo "$inbound" | jq -r '.listen_port')"
  cur_method="$(echo "$inbound" | jq -r '.method')"
  cur_password="$(echo "$inbound" | jq -r '.password')"

  clear
  print_rect_title "修改 Shadowsocks"
  echo " 当前端口：${cur_port}"
  echo " 当前密码：${cur_password}"
  echo " 当前加密：${cur_method}"
  echo
  echo " 1. 修改端口"
  echo " 2. 修改密码"
  echo " 3. 修改加密方式"
  echo " 4. 修改全部"
  echo " 0. 返回"
  local act new_port new_method new_password
  read -r -p "请选择操作: " act

  new_port="$cur_port"; new_method="$cur_method"; new_password="$cur_password"

  case "${act:-}" in
    1)
      ask_port_or_return "请输入新端口（回车不修改）: " "$cur_port" new_port || { pause; return 0; }
      if [ "$new_port" != "$cur_port" ] && ss_port_conflict "$json" "$new_port" "$tag"; then
        err "端口 ${new_port} 已被占用。"; pause; return 1
      fi
      ;;
    2)
      read -r -p "请输入新密码（回车自动生成）: " new_password
      if [ -z "${new_password:-}" ]; then
        new_password="$(ss_gen_password_for_method "$new_method")"
      elif ! ss_password_valid_for_method "$new_method" "$new_password"; then
        warn "密码长度不满足 ${new_method} 要求，已自动生成随机密码。"
        new_password="$(ss_gen_password_for_method "$new_method")"
      fi
      ;;
    3)
      ss_choose_method new_method || { pause; return 0; }
      if ! ss_password_valid_for_method "$new_method" "$new_password"; then
        warn "当前密码不满足新加密方式的长度要求，已为你重新生成密码。"
        new_password="$(ss_gen_password_for_method "$new_method")"
      fi
      ;;
    4)
      ask_port_or_return "请输入新端口（回车不修改）: " "$cur_port" new_port || { pause; return 0; }
      if [ "$new_port" != "$cur_port" ] && ss_port_conflict "$json" "$new_port" "$tag"; then
        err "端口 ${new_port} 已被占用。"; pause; return 1
      fi
      ss_choose_method new_method || { pause; return 0; }
      read -r -p "请输入新密码（回车自动生成）: " new_password
      if [ -z "${new_password:-}" ] || ! ss_password_valid_for_method "$new_method" "$new_password"; then
        new_password="$(ss_gen_password_for_method "$new_method")"
      fi
      ;;
    0|"") return 0 ;;
    *) warn "无效选择"; pause; return 0 ;;
  esac

  local new_inbound new_json
  new_inbound="$(build_ss_inbound "$new_port" "$new_method" "$new_password")"
  new_json="$(echo "$json" | jq --arg ek "$tag" --argjson nb "$new_inbound" '
    .inbounds = ((.inbounds // []) | map(select((.tag // "") != $ek))) + [$nb]
  ')"
  if config_apply "$new_json"; then
    ok "Shadowsocks 节点已更新。"
    echo
    ss_link_for_inbound "$new_inbound"
  else
    warn "更新失败，已保留原配置。"
  fi
  pause
}

ss_delete() {
  init_manager_env || { pause; return 0; }
  local json tag new_json
  json="$(config_load)"
  ss_pick_entry_or_return "$json" tag || { pause; return 0; }
  ask_confirm_yn "确认删除 Shadowsocks 节点 ${tag}？(y/N): " || { pause; return 0; }
  new_json="$(remove_inbound_by_entry_key_simple "$json" "$tag")"
  if config_apply "$new_json"; then
    ok "Shadowsocks 节点已删除：${tag}"
  else
    warn "删除失败，已保留原配置。"
  fi
  pause
}

# ============================================================
# AnyTLS 节点管理（新增：编排逻辑；安装/SNI选择/证书全部调用上面原样保留的函数）
# ============================================================

anytls_add() {
  init_manager_env || { pause; return 0; }
  local json port sni password inbound
  json="$(config_load)"

  local default_port
  default_port="$(ss_pick_free_port "$json")"
  ask_port_or_return "请输入 AnyTLS 端口（回车默认随机可用端口 ${default_port}）: " "$default_port" port || { pause; return 0; }
  if ss_port_conflict "$json" "$port"; then
    err "端口 ${port} 已被其它协议占用。"
    pause
    return 1
  fi

  sni="$(choose_tls_domain "AnyTLS")" || { pause; return 0; }

  read -r -p "请输入密码（回车自动生成）: " password

  inbound="$(build_anytls_inbound "$port" "$sni" "${password:-}")" || {
    err "构建 AnyTLS inbound 失败（证书生成失败）。"
    pause
    return 1
  }

  json="$(echo "$json" | jq --argjson nb "$inbound" '.inbounds += [$nb]')"
  if config_apply "$json"; then
    ok "AnyTLS 节点已添加。"
    echo
    anytls_show_inbound "$inbound"
  else
    cleanup_inbound_generated_cert_files "$(jq -n --argjson nb "$inbound" '{inbounds:[$nb]}')" "$(echo "$inbound" | jq -r '.tag')"
    warn "添加失败，配置未生效。"
  fi
  pause
}

anytls_list_entries() {
  local json="$1"
  protocol_entry_inventory "$json" | awk -F'\x01' -v proto="anytls" '$2==proto {print $0}'
}

anytls_pick_entry_or_return() {
  local json="$1" outvar="$2"
  local -a lines=()
  mapfile -t lines < <(anytls_list_entries "$json")
  if [ ${#lines[@]} -eq 0 ]; then
    warn "当前没有 AnyTLS 节点。"
    return 1
  fi
  local i=1 tag proto port
  echo "当前 AnyTLS 节点："
  for line in "${lines[@]}"; do
    IFS=$'\x01' read -r tag proto port <<< "$line"
    echo "  [$i] ${tag}  端口:${port}"
    i=$((i+1))
  done
  local choice
  read -r -p "请选择编号（回车返回上一级）: " choice
  [ -n "${choice:-}" ] || return 1
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#lines[@]}" ]; then
    warn "无效选择。"
    return 1
  fi
  IFS=$'\x01' read -r tag proto port <<< "${lines[$((choice-1))]}"
  printf -v "$outvar" '%s' "$tag"
}

# 显示 AnyTLS 节点参数。AnyTLS 目前没有像 ss:// 那样广泛采用的标准分享链接格式，
# 这里按大多数 sing-box 客户端要求的字段直接列出原始参数，避免自造一个可能与
# 客户端不兼容的"伪标准" URI。
anytls_show_inbound() {
  local inbound="$1" ip tag port password sni
  ip="$(get_public_ip)"
  tag="$(echo "$inbound" | jq -r '.tag')"
  port="$(echo "$inbound" | jq -r '.listen_port')"
  password="$(echo "$inbound" | jq -r '.users[0].password')"
  sni="$(echo "$inbound" | jq -r '.tls.server_name')"
  echo "节点：${tag}"
  echo "  地址: ${ip}"
  echo "  端口: ${port}"
  echo "  密码: ${password}"
  echo "  SNI : ${sni}"
  echo "  客户端 outbound JSON 片段（自签证书，需要 insecure/allow_insecure=true）："
  jq -n --arg server "$ip" --argjson port "$port" --arg pass "$password" --arg sni "$sni" '
    {type:"anytls", server:$server, server_port:$port, password:$pass,
     tls:{enabled:true, server_name:$sni, insecure:true}}
  '
}

anytls_modify() {
  init_manager_env || { pause; return 0; }
  local json tag inbound cur_port cur_password cur_sni
  json="$(config_load)"
  anytls_pick_entry_or_return "$json" tag || { pause; return 0; }
  inbound="$(find_inbound_by_entry_key "$json" "$tag")"
  cur_port="$(echo "$inbound" | jq -r '.listen_port')"
  cur_password="$(echo "$inbound" | jq -r '.users[0].password')"
  cur_sni="$(echo "$inbound" | jq -r '.tls.server_name')"

  clear
  print_rect_title "修改 AnyTLS"
  echo " 当前端口：${cur_port}"
  echo " 当前密码：${cur_password}"
  echo " 当前 SNI ：${cur_sni}"
  echo
  echo " 1. 修改端口"
  echo " 2. 修改密码"
  echo " 3. 重新选择 SNI"
  echo " 0. 返回"
  local act
  read -r -p "请选择操作: " act

  case "${act:-}" in
    1)
      local new_port new_inbound new_json
      ask_port_or_return "请输入新端口（回车不修改）: " "$cur_port" new_port || { pause; return 0; }
      if [ "$new_port" = "$cur_port" ]; then pause; return 0; fi
      if ss_port_conflict "$json" "$new_port" "$tag"; then
        err "端口 ${new_port} 已被占用。"; pause; return 1
      fi
      # 端口变化 -> entry_key（tag）和证书文件路径都要跟着变，
      # 用原版 build_anytls_inbound 在新端口下重新生成自签证书（仍是同一套证书逻辑）。
      new_inbound="$(build_anytls_inbound "$new_port" "$cur_sni" "$cur_password")" || {
        err "生成新端口证书失败。"; pause; return 1
      }
      new_json="$(echo "$json" | jq --arg ek "$tag" --argjson nb "$new_inbound" '
        .inbounds = ((.inbounds // []) | map(select((.tag // "") != $ek))) + [$nb]
      ')"
      if config_apply "$new_json"; then
        cleanup_inbound_generated_cert_files "$json" "$tag"
        ok "AnyTLS 节点端口已更新。"
        echo; anytls_show_inbound "$new_inbound"
      else
        cleanup_inbound_generated_cert_files "$(jq -n --argjson nb "$new_inbound" '{inbounds:[$nb]}')" "$(echo "$new_inbound" | jq -r '.tag')"
        warn "更新失败，已保留原配置。"
      fi
      ;;
    2)
      local new_password new_json
      read -r -p "请输入新密码（回车自动生成）: " new_password
      [ -n "${new_password:-}" ] || new_password="$(random_b64_password 16)"
      new_json="$(echo "$json" | jq --arg ek "$tag" --arg pw "$new_password" '
        .inbounds |= map(if (.tag // "")==$ek then .users[0].password = $pw else . end)
      ')"
      if config_apply "$new_json"; then
        ok "AnyTLS 密码已更新。"
        echo; anytls_show_inbound "$(find_inbound_by_entry_key "$new_json" "$tag")"
      else
        warn "更新失败，已保留原配置。"
      fi
      ;;
    3)
      anytls_reselect_sni "$json" "$tag" "$cur_port" "$cur_password"
      ;;
    0|"") return 0 ;;
    *) warn "无效选择"; ;;
  esac
  pause
}

# “重新选择 SNI”：完全复用原版 choose_tls_domain（手动/自动测速二选一，
# 逻辑与 AnyTLS 安装时用的是同一个函数），再用原版 ensure_self_signed_cert
# 针对新 SNI 重新签发自签证书（证书路径不变，仍是 /etc/sing-box/anytls-<port>.crt/.key，
# 内容用新 CN=新SNI 重新生成），最后只更新 inbound 里的 tls.server_name。
anytls_reselect_sni() {
  local json="$1" tag="$2" port="$3" password="$4"
  clear
  print_rect_title "重新选择 AnyTLS SNI"
  local inbound cur_sni
  inbound="$(find_inbound_by_entry_key "$json" "$tag")"
  cur_sni="$(echo "$inbound" | jq -r '.tls.server_name')"
  echo " 当前 SNI：${cur_sni}"
  echo
  echo " 1. 自动测速，选择最快 SNI"
  echo " 2. 手动输入 SNI"
  echo " 0. 返回"
  local act new_sni
  read -r -p "请选择操作: " act
  case "${act:-}" in
    1)
      new_sni="$(auto_pick_tls_domain 2>/dev/null | awk -F'\t' '{print $1}')"
      if [ -z "$new_sni" ]; then
        warn "自动测速失败。"
        return 1
      fi
      param_echo "SNI" "$new_sni"
      ;;
    2)
      read -r -p "请输入新的 SNI（回车返回）: " new_sni
      [ -n "${new_sni:-}" ] || { warn "已取消。"; return 1; }
      ;;
    0|"") return 0 ;;
    *) warn "无效选择"; return 1 ;;
  esac

  local crt key new_json
  crt="/etc/sing-box/anytls-${port}.crt"
  key="/etc/sing-box/anytls-${port}.key"
  ensure_self_signed_cert "$new_sni" "$crt" "$key" || {
    err "证书重新生成失败。"
    return 1
  }
  new_json="$(echo "$json" | jq --arg ek "$tag" --arg sni "$new_sni" '
    .inbounds |= map(if (.tag // "")==$ek then .tls.server_name = $sni else . end)
  ')"
  if config_apply "$new_json"; then
    ok "AnyTLS SNI 已更新为：${new_sni}"
    echo; anytls_show_inbound "$(find_inbound_by_entry_key "$new_json" "$tag")"
  else
    warn "更新失败，已保留原配置（证书文件可能已被覆盖为新 SNI，建议重新执行一次「重新选择 SNI」以保持一致）。"
  fi
}

anytls_delete() {
  init_manager_env || { pause; return 0; }
  local json tag new_json
  json="$(config_load)"
  anytls_pick_entry_or_return "$json" tag || { pause; return 0; }
  ask_confirm_yn "确认删除 AnyTLS 节点 ${tag}？(y/N): " || { pause; return 0; }
  new_json="$(remove_inbound_by_entry_key_simple "$json" "$tag")"
  if config_apply "$new_json"; then
    cleanup_inbound_generated_cert_files "$json" "$tag"
    ok "AnyTLS 节点已删除：${tag}"
  else
    warn "删除失败，已保留原配置。"
  fi
  pause
}

# ============================================================
# 查看节点
# ============================================================

view_nodes() {
  init_manager_env || { pause; return 0; }
  local json
  json="$(config_load)"
  clear
  print_rect_title "节点列表"
  local -a ss_lines=() at_lines=()
  mapfile -t ss_lines < <(ss_list_entries "$json")
  mapfile -t at_lines < <(anytls_list_entries "$json")

  if [ ${#ss_lines[@]} -eq 0 ] && [ ${#at_lines[@]} -eq 0 ]; then
    warn "当前没有任何节点。"
    pause
    return 0
  fi

  local tag proto port
  if [ ${#ss_lines[@]} -gt 0 ]; then
    echo -e "${C}--- Shadowsocks ---${NC}"
    for line in "${ss_lines[@]}"; do
      IFS=$'\x01' read -r tag proto port <<< "$line"
      echo
      ss_link_for_inbound "$(find_inbound_by_entry_key "$json" "$tag")"
    done
    echo
  fi
  if [ ${#at_lines[@]} -gt 0 ]; then
    echo -e "${C}--- AnyTLS ---${NC}"
    for line in "${at_lines[@]}"; do
      IFS=$'\x01' read -r tag proto port <<< "$line"
      echo
      anytls_show_inbound "$(find_inbound_by_entry_key "$json" "$tag")"
    done
  fi
  pause
}

# ============================================================
# 服务控制
# ============================================================

svc_start() {
  init_manager_env || { pause; return 0; }
  if enable_now_singbox_safe; then :; else warn "启动失败，请检查配置。"; fi
  pause
}

svc_stop() {
  init_manager_env || { pause; return 0; }
  case "$INIT_SYSTEM" in
    systemd) systemctl stop sing-box && ok "sing-box 已停止。" || warn "停止失败。" ;;
    openrc)  rc-service sing-box stop && ok "sing-box 已停止。" || warn "停止失败。" ;;
  esac
  pause
}

svc_restart() {
  init_manager_env || { pause; return 0; }
  if reload_or_restart_singbox_safe; then :; else warn "重启失败，请检查配置。"; fi
  pause
}

svc_status() {
  init_manager_env || { pause; return 0; }
  case "$INIT_SYSTEM" in
    systemd) systemctl status sing-box --no-pager || true ;;
    openrc)  rc-service sing-box status || true ;;
  esac
  pause
}

svc_check_config() {
  init_manager_env || { pause; return 0; }
  if check_config_or_print; then
    ok "配置检查通过：sing-box check -c $CONFIG_FILE"
  fi
  pause
}

svc_view_config() {
  init_manager_env || { pause; return 0; }
  jq . "$CONFIG_FILE" 2>/dev/null || cat "$CONFIG_FILE"
  pause
}

# ============================================================
# 安装 / 卸载
# 【说明】本次开发环境无法拉取原仓库 lib/ 目录里的安装模块源码，
# 这部分是参照原脚本里其它同类逻辑（GitHub Releases 下载 + systemd 单元 +
# 包管理器装依赖）重新实现的，并不是从原仓库逐字复制。如果你的 VPS 已经
# 用原版 sb.sh 装好了 sing-box，可以跳过安装，直接用本脚本做节点管理即可。
# ============================================================

install_singbox_deps() {
  install_pkg jq
  install_pkg curl
  install_pkg openssl
  install_pkg ca-certificates
}

install_singbox_binary() {
  local api_json tag asset_pattern download_url tmp_dir arch
  case "$(uname -m)" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) err "当前架构暂不支持自动安装：$(uname -m)"; return 1 ;;
  esac
  say "查询 ${SINGBOX_RELEASE_REPO} 最新版本..."
  api_json="$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 \
    "https://api.github.com/repos/${SINGBOX_RELEASE_REPO}/releases/latest" 2>/dev/null || true)"
  [ -n "$api_json" ] || { err "获取版本信息失败，请检查网络。"; return 1; }
  tag="$(echo "$api_json" | jq -r '.tag_name // empty')"
  [ -n "$tag" ] || { err "未获取到最新版本号。"; return 1; }
  # 官方资产命名形如 sing-box-<version>-linux-<arch>.tar.gz，
  # 排除 -legacy / android 等变体，只取标准 linux 版本。
  asset_pattern="linux-${arch}.tar.gz"
  download_url="$(echo "$api_json" | jq -r --arg p "$asset_pattern" '
    [.assets[]?.browser_download_url | select(contains($p)) | select(contains("legacy")|not) | select(contains("android")|not)] | .[0] // empty
  ')"
  if [ -z "$download_url" ]; then
    err "未找到匹配当前架构（${arch}）的安装包，请到以下页面手动下载安装："
    err "https://github.com/${SINGBOX_RELEASE_REPO}/releases/tag/${tag}"
    return 1
  fi
  tmp_dir="$(make_disk_tmp_dir sb-install)" || { err "创建临时目录失败。"; return 1; }
  say "下载 sing-box ${tag}..."
  if ! download_file "$download_url" "$tmp_dir/sing-box.tar.gz"; then
    rm -rf "$tmp_dir"
    err "下载失败。"
    return 1
  fi
  tar -xzf "$tmp_dir/sing-box.tar.gz" -C "$tmp_dir" || { rm -rf "$tmp_dir"; err "解压失败。"; return 1; }
  local bin_path
  bin_path="$(find "$tmp_dir" -type f -name 'sing-box' | head -n1)"
  [ -n "$bin_path" ] || { rm -rf "$tmp_dir"; err "安装包中未找到 sing-box 可执行文件。"; return 1; }
  install -m 755 "$bin_path" "$SINGBOX_BIN" || { rm -rf "$tmp_dir"; err "安装二进制失败。"; return 1; }
  rm -rf "$tmp_dir"
  mkdir -p /etc/sing-box
  echo "$tag" > "$SINGBOX_VERSION_STAMP" 2>/dev/null || true
  ok "sing-box ${tag} 已安装到 ${SINGBOX_BIN}"
}

install_singbox_service() {
  case "$INIT_SYSTEM" in
    systemd)
      cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      ;;
    openrc)
      warn "OpenRC 下请自行确认 /etc/init.d/sing-box 服务脚本是否已存在。"
      ;;
  esac
}

install_singbox() {
  require_root
  install_singbox_deps
  install_singbox_binary || { pause; return 1; }
  install_singbox_service
  config_ensure_exists
  if enable_now_singbox_safe; then
    ok "sing-box 已安装并启动。"
  else
    warn "sing-box 已安装，但启动失败，请检查配置或日志。"
  fi
  pause
}

uninstall_singbox() {
  require_root
  ask_confirm_yn "确认卸载 sing-box？将停止服务并删除二进制、systemd 单元（保留 /etc/sing-box 配置目录，如需一并删除请手动 rm -rf）。(y/N): " || { pause; return 0; }
  case "$INIT_SYSTEM" in
    systemd)
      systemctl stop sing-box >/dev/null 2>&1 || true
      systemctl disable sing-box >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/sing-box.service
      systemctl daemon-reload
      ;;
    openrc)
      rc-service sing-box stop >/dev/null 2>&1 || true
      rc-update del sing-box default >/dev/null 2>&1 || true
      ;;
  esac
  rm -f "$SINGBOX_BIN" "$SINGBOX_VERSION_STAMP"
  ok "sing-box 已卸载。配置目录 /etc/sing-box 已保留，如需彻底清理请手动删除。"
  pause
}

# ============================================================
# 主菜单
# ============================================================

main_menu_header() {
  local json running version ss_summary at_summary
  json="$(config_load 2>/dev/null || echo '{}')"
  if singbox_service_active; then running="${G}运行中${NC}"; else running="${R}未运行${NC}"; fi
  version="$(has_cmd sing-box && sing-box version 2>/dev/null | head -n1 || echo '未安装')"
  ss_summary="$(ss_list_entries "$json" | awk -F'\x01' '{printf "%s ", $1} END{if(NR==0) printf "无"}')"
  at_summary="$(anytls_list_entries "$json" | awk -F'\x01' '{printf "%s ", $1} END{if(NR==0) printf "无"}')"

  print_rect_title "Sing-box 精简管理脚本"
  echo -e " Sing-box：$(echo -e "$running")"
  echo -e " 版本：${version}"
  echo -e " 脚本：${SCRIPT_VERSION}"
  echo
  echo " 当前节点："
  echo "   SS     : ${ss_summary}"
  echo "   AnyTLS : ${at_summary}"
}

main_menu() {
  while true; do
    clear
    main_menu_header
    echo "----------------------------------------"
    echo " 1. 添加 Shadowsocks"
    echo " 2. 修改 Shadowsocks"
    echo " 3. 删除 Shadowsocks"
    echo
    echo " 4. 添加 AnyTLS"
    echo " 5. 修改 AnyTLS"
    echo " 6. 删除 AnyTLS"
    echo
    echo " 7. 查看节点"
    echo
    echo " 8. 启动 Sing-box"
    echo " 9. 停止 Sing-box"
    echo "10. 重启 Sing-box"
    echo "11. 查看运行状态"
    echo
    echo "12. 检查配置"
    echo "13. 查看配置"
    echo
    echo "14. 安装 / 更新 Sing-box"
    echo "15. 卸载 Sing-box"
    echo
    echo " 0. 退出"
    echo "----------------------------------------"
    local act
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) ss_add ;;
      2) ss_modify ;;
      3) ss_delete ;;
      4) anytls_add ;;
      5) anytls_modify ;;
      6) anytls_delete ;;
      7) view_nodes ;;
      8) svc_start ;;
      9) svc_stop ;;
      10) svc_restart ;;
      11) svc_status ;;
      12) svc_check_config ;;
      13) svc_view_config ;;
      14) install_singbox ;;
      15) uninstall_singbox ;;
      0|q|Q) exit 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

# ============================================================
# 入口
# ============================================================

require_root
main_menu
