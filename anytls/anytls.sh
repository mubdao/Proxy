#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
CONFIG_FILE="/etc/sing-box/config.json"
SINGBOX_RELEASE_REPO="Tangfffyx/sing-box"
SINGBOX_INSTALL_DIR="/usr/local/bin"
SINGBOX_BIN="${SINGBOX_INSTALL_DIR}/sing-box"
SINGBOX_VERSION_STAMP="/etc/sing-box/.installed_release"
INIT_SYSTEM=""

B='\033[1;34m'
G='\033[1;32m'
R='\033[1;31m'
Y='\033[1;33m'
C='\033[1;36m'
NC='\033[0m'
W='\033[1;37m'

say(){ echo -e "${C}[INFO]${NC} $*"; }
ok(){ echo -e "${G}[ OK ]${NC} $*"; }
warn(){ echo -e "${Y}[WARN]${NC} $*" >&2; }
err(){ echo -e "${R}[ERR ]${NC} $*" >&2; }
pause(){ read -r -n 1 -p "按任意键继续..." || true; echo; }

require_root(){
  [ "${EUID:-$(id -u)}" -eq 0 ] || { err "请使用 root 运行此脚本。"; exit 1; }
}

has_cmd(){ command -v "$1" >/dev/null 2>&1; }

detect_init(){
  if has_cmd systemctl && systemctl --version >/dev/null 2>&1; then
    INIT_SYSTEM="systemd"
  else
    INIT_SYSTEM="unknown"
  fi
  [ "$INIT_SYSTEM" = "systemd" ] || {
    err "仅支持使用 systemd 的 Debian / Ubuntu。"
    exit 1
  }
}

check_os(){
  [ -f /etc/os-release ] || { err "无法识别系统。"; exit 1; }
  . /etc/os-release
  case "$ID" in
    debian|ubuntu) ;;
    *) err "仅支持 Debian / Ubuntu。当前：${PRETTY_NAME:-$ID}"; exit 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|aarch64|arm64) ;;
    *) err "仅支持 amd64 / arm64。当前：$(uname -m)"; exit 1 ;;
  esac
}

install_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl jq openssl tar ca-certificates gzip coreutils procps
}

random_b64_password(){
  local bytes="${1:-16}" value
  value="$(openssl rand -base64 "$bytes" 2>/dev/null || true)"
  if [ -z "$value" ]; then
    value="$(head -c "$bytes" /dev/urandom | openssl base64 -A 2>/dev/null || true)"
  fi
  [ -n "$value" ] && printf '%s\n' "$value"
}

get_release_latest_tag(){
  curl -fsSL --connect-timeout 10 --max-time 20 \
    "https://api.github.com/repos/${SINGBOX_RELEASE_REPO}/releases/latest" |
    jq -r '.tag_name // empty'
}

normalize_release_tag(){
  local v="${1:-}"
  v="${v#v}"
  printf '%s\n' "$v"
}

get_installed_version(){
  local ver
  if [ -s "$SINGBOX_VERSION_STAMP" ]; then
    ver="$(cat "$SINGBOX_VERSION_STAMP" 2>/dev/null || true)"
    ver="${ver#v}"
    [ -n "$ver" ] && { printf '%s\n' "$ver"; return; }
  fi
  if [ -x "$SINGBOX_BIN" ]; then
    ver="$("$SINGBOX_BIN" version 2>/dev/null |
      awk '/^sing-box version / {print $3; exit}' || true)"
    ver="${ver#v}"
    [ -n "$ver" ] && printf '%s\n' "$ver"
  fi
}

version_ge(){
  local a="${1#v}" b="${2#v}"
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" = "$b" ]
}

ensure_self_signed_cert(){
  local cn="$1" crt_path="$2" key_path="$3"
  mkdir -p "$(dirname "$crt_path")"
  openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$key_path" -out "$crt_path" -days 36500 -nodes \
    -subj "/CN=${cn}" >/dev/null 2>&1 || return 1
  [ -s "$crt_path" ] && [ -s "$key_path" ]
}

get_tls_domain_candidates(){
  cat <<'EOF'
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
EOF
}

benchmark_tls_domain_ms(){
  local domain="$1" t1 t2
  t1="$(date +%s%3N)"
  timeout 1 openssl s_client -connect "${domain}:443" -servername "$domain" </dev/null \
    >/dev/null 2>&1 || return 1
  t2="$(date +%s%3N)"
  [[ "$t1" =~ ^[0-9]+$ && "$t2" =~ ^[0-9]+$ && "$t2" -ge "$t1" ]] || return 1
  echo $((t2-t1))
}

auto_pick_tls_domain(){
  local best_domain="" best_ms=999999 ms domain
  mapfile -t candidates < <(get_tls_domain_candidates)
  local total=${#candidates[@]}
  if [ "$total" -gt 10 ]; then
    local -a sampled=() indices=()
    while [ "${#sampled[@]}" -lt 10 ]; do
      local r=$((RANDOM % total)) dup=0 idx
      for idx in "${indices[@]}"; do
        [ "$idx" -eq "$r" ] && { dup=1; break; }
      done
      [ "$dup" -eq 0 ] && {
        sampled+=("${candidates[$r]}")
        indices+=("$r")
      }
    done
    candidates=("${sampled[@]}")
  fi
  for domain in "${candidates[@]}"; do
    [ -n "$domain" ] || continue
    ms="$(benchmark_tls_domain_ms "$domain" 2>/dev/null || true)"
    if [[ "$ms" =~ ^[0-9]+$ ]] && [ "$ms" -lt "$best_ms" ]; then
      best_ms="$ms"
      best_domain="$domain"
    fi
  done
  [ -n "$best_domain" ] || return 1
  printf '%s\t%s\n' "$best_domain" "$best_ms"
}

choose_tls_domain(){
  local choice manual picked picked_ms
  echo "1. 手动输入"
  echo "2. 自动测速选择推荐域名"
  read -r -p "请选择域名填写方式（回车默认 2）: " choice
  case "${choice:-2}" in
    1)
      read -r -p "请输入 AnyTLS 域名（回车返回）: " manual
      [ -n "$manual" ] || return 1
      printf '%s\n' "$manual"
      ;;
    *)
      say "正在测速 SNI..."
      picked="$(auto_pick_tls_domain 2>/dev/null || true)"
      [ -n "$picked" ] || { err "自动测速失败。"; return 1; }
      picked_ms="${picked#*$'\t'}"
      picked="${picked%%$'\t'*}"
      ok "SNI：${picked} (${picked_ms} ms)"
      printf '%s\n' "$picked"
      ;;
  esac
}

entry_key_from_port(){
  printf 'anytls-%s\n' "$1"
}

build_anytls_inbound(){
  local port="$1" sni="$2" pass="${3:-}"
  local entry_key crt key
  entry_key="$(entry_key_from_port "$port")"
  [ -n "$pass" ] || pass="$(random_b64_password 16)"
  crt="/etc/sing-box/anytls-${port}.crt"
  key="/etc/sing-box/anytls-${port}.key"
  ensure_self_signed_cert "$sni" "$crt" "$key" || return 1
  jq -n \
    --arg tag "$entry_key" \
    --arg pass "$pass" \
    --arg sni "$sni" \
    --arg crt "$crt" \
    --arg key "$key" \
    --argjson port "$port" '
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
    }'
}

config_min_template(){
  cat <<'JSON'
{
  "log":{"level":"info","output":"/var/log/sing-box/access.log","timestamp":true},
  "inbounds":[],
  "outbounds":[
    {"type":"direct","tag":"direct"},
    {"type":"block","tag":"reject"}
  ],
  "route":{"rules":[],"final":"reject"},
  "experimental":{"cache_file":{"enabled":true}}
}
JSON
}

config_load(){
  if [ -s "$CONFIG_FILE" ] && jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    jq '
      if type != "object" then
        {}
      else .
      end
      | .log = (.log // {"level":"info","output":"/var/log/sing-box/access.log","timestamp":true})
      | .inbounds = (.inbounds // [])
      | .outbounds = (.outbounds // [])
      | .route = (.route // {})
      | .route.rules = (.route.rules // [])
      | .route.final = (.route.final // "reject")
      | .experimental = (.experimental // {})
      | .experimental.cache_file = (.experimental.cache_file // {})
      | .experimental.cache_file.enabled = true
      | if (.outbounds | any((.tag // "")=="direct")) then . else .outbounds += [{"type":"direct","tag":"direct"}] end
      | if (.outbounds | any((.tag // "")=="reject")) then . else .outbounds += [{"type":"block","tag":"reject"}] end
    ' "$CONFIG_FILE"
  else
    config_min_template
  fi
}

check_config(){
  "$SINGBOX_BIN" check -c "$CONFIG_FILE"
}

write_config_atomic(){
  local json="$1" tmp
  tmp="$(mktemp /etc/sing-box/config.json.tmp.XXXXXX)"
  printf '%s\n' "$json" | jq . > "$tmp" || {
    rm -f "$tmp"; return 1;
  }
  "$SINGBOX_BIN" check -c "$tmp" >/dev/null || {
    "$SINGBOX_BIN" check -c "$tmp" 2>&1 | sed 's/^/  /'
    rm -f "$tmp"; return 1;
  }
  mkdir -p /etc/sing-box
  [ -f "$CONFIG_FILE" ] && cp -a "$CONFIG_FILE" \
    "/etc/sing-box/config.json.bak.$(date +%Y%m%d_%H%M%S)"
  mv -f "$tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

write_managed_service(){
  mkdir -p /var/lib/sing-box /etc/sing-box /etc/systemd/system
  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SINGBOX_BIN} -D /var/lib/sing-box -c ${CONFIG_FILE} run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

ensure_command_link(){
  mkdir -p /usr/bin
  ln -sf "$SINGBOX_BIN" /usr/bin/sing-box
}

reload_or_restart(){
  check_config || return 1
  if systemctl reload sing-box >/dev/null 2>&1; then
    ok "sing-box 已热载。"
  elif systemctl restart sing-box; then
    ok "sing-box 已重启。"
  else
    err "sing-box 重载/重启失败。"
    return 1
  fi
}

install_or_update_singbox(){
  local arch file tag latest current tmp base_url download_url sha_url
  case "$(uname -m)" in
    x86_64) file="sing-box-linux-amd64.tar.gz" ;;
    aarch64|arm64) file="sing-box-linux-arm64.tar.gz" ;;
    *) err "不支持的架构。"; return 1 ;;
  esac

  tag="$(get_release_latest_tag)"
  latest="$(normalize_release_tag "$tag")"
  [ -n "$latest" ] || { err "无法获取最新版本。"; return 1; }

  current="$(get_installed_version || true)"
  if [ -n "$current" ] && version_ge "$current" "$latest"; then
    ok "sing-box 已是最新版本：$current"
    return 0
  fi

  tmp="$(mktemp -d /var/tmp/sb-install.XXXXXX)"
  base_url="https://github.com/${SINGBOX_RELEASE_REPO}/releases/download/${tag}"
  download_url="${base_url}/${file}"
  sha_url="${base_url}/sha256sum.txt"

  say "下载 sing-box ${latest}..."
  curl -fsSL --connect-timeout 20 --retry 3 "$download_url" -o "$tmp/$file" || {
    rm -rf "$tmp"; err "下载失败。"; return 1;
  }

  if curl -fsSL --connect-timeout 20 --retry 3 "$sha_url" -o "$tmp/sha256sum.txt" >/dev/null 2>&1; then
    local expected actual
    expected="$(awk -v f="$file" '{n=$2; sub(/^.*\//,"",n); if(n==f){print $1;exit}}' "$tmp/sha256sum.txt")"
    actual="$(sha256sum "$tmp/$file" | awk '{print $1}')"
    [ -n "$expected" ] && [ "$expected" = "$actual" ] || {
      rm -rf "$tmp"; err "文件校验失败。"; return 1;
    }
  else
    warn "未获取到 sha256sum.txt，跳过校验。"
  fi

  tar -xzf "$tmp/$file" -C "$tmp" || {
    rm -rf "$tmp"; err "解压失败。"; return 1;
  }
  [ -x "$tmp/sing-box" ] || {
    rm -rf "$tmp"; err "安装包中没有 sing-box。"; return 1;
  }

  mkdir -p "$SINGBOX_INSTALL_DIR" /etc/sing-box
  [ -x "$SINGBOX_BIN" ] && cp -a "$SINGBOX_BIN" "${SINGBOX_BIN}.bak" || true
  install -m 755 "$tmp/sing-box" "$SINGBOX_BIN" || {
    [ -x "${SINGBOX_BIN}.bak" ] && mv -f "${SINGBOX_BIN}.bak" "$SINGBOX_BIN"
    rm -rf "$tmp"; err "安装失败。"; return 1;
  }
  rm -rf "$tmp"

  ensure_command_link
  write_managed_service
  systemctl enable sing-box >/dev/null 2>&1 || true
  printf '%s\n' "$latest" > "$SINGBOX_VERSION_STAMP"
  ok "sing-box ${latest} 安装完成。"
}

port_in_use(){
  ss -H -lnt 2>/dev/null | awk '{print $4}' |
    grep -Eq "(^|:)${1}$"
}

install_anytls(){
  require_root
  install_deps
  install_or_update_singbox

  mkdir -p /etc/sing-box /var/log/sing-box
  chmod 700 /etc/sing-box
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true

  local port password sni inbound old_json new_json
  read -r -p "AnyTLS 端口（默认 443）: " port
  port="${port:-443}"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
    err "端口无效。"; return 1;
  }

  if port_in_use "$port"; then
    err "端口 ${port} 已被占用。"; return 1;
  fi

  read -r -p "AnyTLS 密码（回车自动生成）: " password
  password="${password:-$(random_b64_password 16)}"

  sni="$(choose_tls_domain)" || return 1
  inbound="$(build_anytls_inbound "$port" "$sni" "$password")" || {
    err "生成 AnyTLS 配置失败。"; return 1;
  }

  old_json="$(config_load)"
  new_json="$(echo "$old_json" | jq --argjson in "$inbound" '
    .inbounds = [ .inbounds[]? | select((.type // "") != "anytls") ] + [$in]
    | .route.final = "direct"
    | if (.outbounds | any((.tag // "")=="direct")) then . else .outbounds += [{"type":"direct","tag":"direct"}] end
  ')"

  write_config_atomic "$new_json" || return 1
  write_managed_service
  systemctl enable sing-box >/dev/null
  systemctl restart sing-box
  sleep 1
  systemctl is-active --quiet sing-box || {
    err "AnyTLS 启动失败。"
    systemctl --no-pager -l status sing-box || true
    return 1
  }
  ok "AnyTLS 安装完成。"
}

read_anytls(){
  [ -f "$CONFIG_FILE" ] || return 1
  local line
  line="$(jq -r '
    .inbounds[]? | select(.type=="anytls") |
    [
      (.listen_port|tostring),
      (.users[0].password // ""),
      (.tls.server_name // ""),
      (.tls.certificate_path // ""),
      (.tls.key_path // "")
    ] | join("\u0001")
  ' "$CONFIG_FILE" | head -n1)"
  [ -n "$line" ] || return 1
  IFS=$'\x01' read -r PORT PASSWORD SNI CERT KEY <<< "$line"
}

get_public_ip(){
  local ip
  ip="$(curl -s4 --max-time 3 --connect-timeout 2 ifconfig.me 2>/dev/null || true)"
  [ -z "$ip" ] && ip="$(curl -s4 --max-time 3 --connect-timeout 2 api.ipify.org 2>/dev/null || true)"
  [ -z "$ip" ] && ip="IP"
  printf '%s\n' "$ip"
}

url_encode(){
  jq -nr --arg v "$1" '$v|@uri'
}

build_anytls_link(){
  local server="$1" port="$2" password="$3" sni="$4" name="$5"
  printf 'anytls://%s@%s:%s?sni=%s&fp=chrome&alpn=%s&allowInsecure=1#%s' \
    "$password" "$server" "$port" \
    "$(url_encode "$sni")" \
    "$(url_encode "h2,http/1.1")" \
    "$(url_encode "$name")"
}

show_config(){
  read_anytls || { err "未找到 AnyTLS 配置。"; return 1; }
  local ip
  ip="$(get_public_ip)"
  echo
  echo "========================================"
  echo "            AnyTLS 配置信息"
  echo "========================================"
  echo
  echo "服务器：$ip"
  echo "端口：$PORT"
  echo "密码：$PASSWORD"
  echo "SNI：$SNI"
  echo
  echo "----------------------------------------"
  echo "Surge"
  echo "----------------------------------------"
  echo
  echo "[Proxy]"
  echo "AnyTLS = anytls, ${ip}, ${PORT}, password=${PASSWORD}, skip-cert-verify=true, sni=${SNI}"
  echo
  echo "----------------------------------------"
  echo "通用连接信息"
  echo "----------------------------------------"
  echo
  echo "协议：AnyTLS"
  echo "Server：$ip"
  echo "Port：$PORT"
  echo "Password：$PASSWORD"
  echo "SNI：$SNI"
  echo "TLS：启用"
  echo "证书：自签证书"
  echo
  echo "----------------------------------------"
  echo "通用链接"
  echo "----------------------------------------"
  echo
  build_anytls_link "$ip" "$PORT" "$PASSWORD" "$SNI" "AnyTLS"
  echo
}

start_service(){
  check_config || return 1
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl start sing-box
  sleep 1
  systemctl is-active --quiet sing-box && ok "AnyTLS 服务已启动。" || {
    err "启动失败。"
    systemctl --no-pager -l status sing-box || true
    return 1
  }
}

stop_service(){
  systemctl stop sing-box
  ok "AnyTLS 服务已停止。"
}

restart_service(){
  reload_or_restart
}

show_status(){
  echo
  echo "========================================"
  echo "              服务状态"
  echo "========================================"
  echo
  echo "sing-box：$(get_installed_version || echo 未安装)"
  if systemctl is-active --quiet sing-box; then
    echo -e "服务状态：${G}运行中${NC}"
  else
    echo -e "服务状态：${R}未运行${NC}"
  fi
  if read_anytls; then
    echo "监听端口：$PORT"
    echo "SNI：$SNI"
  fi
  echo
  systemctl --no-pager -l status sing-box || true
}

show_logs(){
  echo "实时日志，按 Ctrl+C 返回。"
  echo
  journalctl -u sing-box -f
}

modify_config(){
  while true; do
    clear
    echo "========================================"
    echo "              修改 AnyTLS"
    echo "========================================"
    echo
    echo "  1) 修改密码"
    echo "  2) 修改端口"
    echo
    echo "  0) 返回"
    echo
    read -r -p "请选择: " choice
    case "$choice" in
      1)
        read_anytls || { err "未找到 AnyTLS 配置。"; pause; continue; }
        local new_password
        read -r -p "新密码（回车取消）: " new_password
        [ -n "$new_password" ] || continue
        local json
        json="$(config_load | jq --arg p "$new_password" '
          (.inbounds[] | select(.type=="anytls") | .users[0].password) = $p
        ')"
        write_config_atomic "$json" && restart_service
        pause
        ;;
      2)
        read_anytls || { err "未找到 AnyTLS 配置。"; pause; continue; }
        local new_port
        read -r -p "新端口（当前 $PORT）: " new_port
        [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ] || {
          err "端口无效。"; pause; continue;
        }
        [ "$new_port" = "$PORT" ] || port_in_use "$new_port" && {
          err "端口 ${new_port} 已被占用。"; pause; continue;
        }
        local json2
        json2="$(config_load | jq --argjson p "$new_port" '
          (.inbounds[] | select(.type=="anytls") | .listen_port) = $p
        ')"
        write_config_atomic "$json2" && restart_service
        pause
        ;;
      0|"") return ;;
      *) warn "无效选项。"; sleep 1 ;;
    esac
  done
}

check_update(){
  install_deps
  local current latest
  current="$(get_installed_version || true)"
  latest="$(normalize_release_tag "$(get_release_latest_tag)")"
  echo
  echo "当前版本：${current:-未安装}"
  echo "最新版本：${latest:-获取失败}"
  echo
  [ -n "$latest" ] || { err "无法获取最新版本。"; return 1; }
  if [ -n "$current" ] && version_ge "$current" "$latest"; then
    ok "当前已是最新版本。"
    return 0
  fi
  read -r -p "是否更新？[Y/n] " answer
  [[ "$answer" =~ ^[Nn]$ ]] && return 0
  install_or_update_singbox
  check_config && systemctl restart sing-box
}

uninstall_anytls(){
  echo
  echo "========================================"
  echo "             卸载 AnyTLS"
  echo "========================================"
  echo
  echo "将删除："
  echo "  - sing-box 服务"
  echo "  - sing-box 主程序"
  echo "  - /usr/bin/sing-box 链接"
  echo
  echo "将保留："
  echo "  - /etc/sing-box 配置"
  echo "  - /etc/sing-box/anytls-*.crt"
  echo "  - /etc/sing-box/anytls-*.key"
  echo
  read -r -p "输入 YES 确认卸载：" confirm
  [ "$confirm" = "YES" ] || { echo "已取消。"; return; }

  systemctl stop sing-box >/dev/null 2>&1 || true
  systemctl disable sing-box >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/sing-box.service /usr/bin/sing-box \
    "$SINGBOX_BIN" "$SINGBOX_VERSION_STAMP"
  systemctl daemon-reload
  ok "sing-box AnyTLS 运行组件已卸载，配置已保留。"
}

menu(){
  while true; do
    clear
    echo "========================================"
    echo "       sing-box AnyTLS 管理脚本"
    echo "========================================"
    echo
    echo "版本：$(get_installed_version || echo 未安装)"
    echo
    echo "基础管理:"
    echo
    echo "  1) 安装 AnyTLS"
    echo "  2) 启动 AnyTLS 服务"
    echo "  3) 停止 AnyTLS 服务"
    echo "  4) 重启 AnyTLS 服务"
    echo "  5) 查看服务状态"
    echo "  6) 查看实时日志"
    echo "  7) 查看配置信息"
    echo "  8) 修改配置"
    echo "  9) 检查更新"
    echo " 10) 卸载 AnyTLS"
    echo
    echo "  0) 退出"
    echo
    read -r -p "请选择: " choice
    case "$choice" in
      1) install_anytls; pause ;;
      2) start_service; pause ;;
      3) stop_service; pause ;;
      4) restart_service; pause ;;
      5) show_status; pause ;;
      6) show_logs ;;
      7) show_config; pause ;;
      8) modify_config ;;
      9) check_update; pause ;;
      10) uninstall_anytls; pause ;;
      0|"") exit 0 ;;
      *) warn "无效选项。"; sleep 1 ;;
    esac
  done
}

trap 'err "脚本执行失败，行号：$LINENO"' ERR

require_root
check_os
detect_init
menu
