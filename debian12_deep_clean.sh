#!/usr/bin/env bash

set -u
set -o pipefail

# Debian 12 Deep Safe Cleanup Script
# 用法：
#   sudo bash debian12_deep_clean.sh
#   sudo bash debian12_deep_clean.sh --dry-run
#
# 默认执行真实清理。
# 加 --dry-run 只预览，不删除。

DRY_RUN=0

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "请使用 root 权限运行："
    echo "sudo bash $0"
    exit 1
fi

run_cmd() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

section() {
    echo
    echo "=================================================="
    echo "$1"
    echo "=================================================="
}

safe_find_delete() {
    local path="$1"
    local days="$2"

    if [[ ! -d "$path" ]]; then
        return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] 将删除 $path 下超过 $days 天的内容："
        find "$path" -mindepth 1 -mtime +"$days" -print 2>/dev/null | head -n 100
    else
        find "$path" -mindepth 1 -mtime +"$days" -exec rm -rf {} + 2>/dev/null || true
    fi
}

echo "Debian 12 深度清理脚本"
echo "当前模式：$([[ "$DRY_RUN" -eq 1 ]] && echo "预览模式，不删除" || echo "真实清理")"

section "清理前磁盘占用"
df -h

section "1. 更新 APT 软件源索引"
run_cmd "apt update"

section "2. 修复未完成的软件包配置"
run_cmd "dpkg --configure -a"
run_cmd "apt -f install -y"

section "3. 自动移除不再需要的软件包"
run_cmd "apt autoremove --purge -y"

section "4. 清理 APT 缓存"
run_cmd "apt clean"
run_cmd "apt autoclean -y"

section "5. 清理已卸载软件残留配置 rc 包"
RC_PACKAGES="$(dpkg -l | awk '/^rc/ {print $2}' || true)"

if [[ -n "$RC_PACKAGES" ]]; then
    echo "$RC_PACKAGES"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] 将清理以上残留配置包"
    else
        echo "$RC_PACKAGES" | xargs -r dpkg --purge
    fi
else
    echo "没有发现 rc 残留配置包"
fi

section "6. 清理 systemd journal 日志，只保留最近 7 天或最多 300M"
run_cmd "journalctl --vacuum-time=7d"
run_cmd "journalctl --vacuum-size=300M"

section "7. 清理 coredump 崩溃转储"
if command -v coredumpctl >/dev/null 2>&1; then
    run_cmd "coredumpctl purge"
else
    echo "未发现 coredumpctl，跳过"
fi

section "8. 清理 /var/crash"
if [[ -d /var/crash ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] /var/crash 内容："
        find /var/crash -mindepth 1 -print 2>/dev/null
    else
        rm -rf /var/crash/* 2>/dev/null || true
    fi
fi

section "9. 清理临时目录"
safe_find_delete "/tmp" 1
safe_find_delete "/var/tmp" 7

section "10. 使用 systemd-tmpfiles 清理系统临时文件"
if command -v systemd-tmpfiles >/dev/null 2>&1; then
    run_cmd "systemd-tmpfiles --clean"
else
    echo "未发现 systemd-tmpfiles，跳过"
fi

section "11. 清理旧日志压缩包和轮转日志"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] 将清理以下旧日志文件："
    find /var/log -type f \( \
        -name "*.gz" -o \
        -name "*.old" -o \
        -name "*.1" -o \
        -name "*.log.*" \
    \) -print 2>/dev/null | head -n 200
else
    find /var/log -type f \( \
        -name "*.gz" -o \
        -name "*.old" -o \
        -name "*.1" -o \
        -name "*.log.*" \
    \) -delete 2>/dev/null || true
fi

section "12. 截断过大的当前日志文件，超过 100M 的清空但保留文件"
while IFS= read -r logfile; do
    echo "处理大日志：$logfile"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] 将截断：$logfile"
    else
        truncate -s 0 "$logfile" 2>/dev/null || true
    fi
done < <(find /var/log -type f -size +100M 2>/dev/null)

section "13. 清理 Debian 包管理旧文件"
if [[ -d /var/cache/debconf ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] 将清理 /var/cache/debconf 下的 old 文件"
        find /var/cache/debconf -type f -name "*-old" -print 2>/dev/null
    else
        find /var/cache/debconf -type f -name "*-old" -delete 2>/dev/null || true
    fi
fi

section "14. 清理用户缓存、缩略图、回收站"
for user_home in /home/* /root; do
    [[ -d "$user_home" ]] || continue

    echo "处理用户目录：$user_home"

    # 普通缓存：只删 14 天前的内容，避免影响近期应用启动
    safe_find_delete "$user_home/.cache" 14

    # 缩略图缓存
    if [[ -d "$user_home/.thumbnails" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "[DRY-RUN] 将清理 $user_home/.thumbnails"
            find "$user_home/.thumbnails" -mindepth 1 -print 2>/dev/null | head -n 100
        else
            rm -rf "$user_home/.thumbnails"/* 2>/dev/null || true
        fi
    fi

    if [[ -d "$user_home/.cache/thumbnails" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "[DRY-RUN] 将清理 $user_home/.cache/thumbnails"
            find "$user_home/.cache/thumbnails" -mindepth 1 -print 2>/dev/null | head -n 100
        else
            rm -rf "$user_home/.cache/thumbnails"/* 2>/dev/null || true
        fi
    fi

    # 回收站：只清理 30 天前的内容
    safe_find_delete "$user_home/.local/share/Trash/files" 30
    safe_find_delete "$user_home/.local/share/Trash/info" 30

    # pip 缓存，比较安全
    if [[ -d "$user_home/.cache/pip" ]]; then
        safe_find_delete "$user_home/.cache/pip" 7
    fi

    # npm 缓存，比较安全
    if [[ -d "$user_home/.npm/_cacache" ]]; then
        safe_find_delete "$user_home/.npm/_cacache" 14
    fi
done

section "15. 清理 Flatpak 未使用运行时"
if command -v flatpak >/dev/null 2>&1; then
    run_cmd "flatpak uninstall --unused -y"
else
    echo "未安装 flatpak，跳过"
fi

section "16. 清理 Snap 旧版本缓存"
if command -v snap >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] 将尝试清理 snap disabled 旧版本"
        snap list --all | awk '/disabled/{print $1, $3}'
    else
        snap list --all | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
            [[ -n "$snapname" && -n "$revision" ]] && snap remove "$snapname" --revision="$revision" || true
        done
    fi
else
    echo "未安装 snap，跳过"
fi

section "17. Docker 清理提示"
if command -v docker >/dev/null 2>&1; then
    echo "检测到 Docker。"
    echo "本脚本默认不自动执行 docker system prune，避免误删镜像、停止容器或构建缓存。"
    echo "如需手动清理 Docker 缓存，可运行："
    echo "docker system prune -a"
    echo
    echo "注意：不要随便加 --volumes，可能删除数据库卷。"
else
    echo "未安装 Docker，跳过"
fi

section "18. 清理无效的缩略图和 gvfs 缓存"
for user_home in /home/* /root; do
    [[ -d "$user_home" ]] || continue

    safe_find_delete "$user_home/.cache/gvfs" 7
    safe_find_delete "$user_home/.cache/fontconfig" 30
done

section "19. 清理前后对比"
echo "清理后磁盘占用："
df -h

echo
echo "大目录占用概览："
du -hxd1 / 2>/dev/null | sort -h | tail -n 20

echo
echo "=================================================="
echo "深度清理完成"
echo "=================================================="

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "当前是预览模式，没有实际删除。"
    echo "确认无误后可执行："
    echo "sudo bash $0"
fi
