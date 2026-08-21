# 极简 VPS 系统管理脚本 V2

适用于 Debian / Ubuntu 的一体化 VPS 管理工具，提供 BBR 加速、IPv4/IPv6 出入站设置、DNS 管理、Swap 配置、系统时间/NTP、安全磁盘清理等功能。

## 功能一览

| 菜单 | 功能 |
|---|---|
| 1 | BBR + FQ 网络加速 / 恢复 cubic + fq_codel |
| 2 | 修改出站 IP 优先级（IPv4/IPv6）、开关入站 IPv6 |
| 3 | 修改系统 DNS，支持锁定（chattr +i）防止被覆盖 |
| 4 | 创建/删除 Swapfile |
| 5 | 时区设置、开启 NTP 自动同步 |
| 6 | 安全磁盘清理（支持 Dry-Run 预览，不误删用户文件和 /var/log） |
| 7 | 磁盘占用分析 |

---

## 安装

**系统要求**：Debian / Ubuntu，root 权限。

```bash
# 1. 下载脚本（假设文件名为 sys.sh，可放在任意目录，这里以 /root 为例）
cd /root
# 如果是从本机上传，直接放到 /root/sys.sh 即可；
# 如果是从远程下载，用 curl/wget 替换为你的实际地址：
# curl -fsSL <你的下载地址> -o sys.sh

# 2. 赋予执行权限
chmod +x sys.sh

# 3. 以 root 身份运行
sudo ./sys.sh
# 或者直接（已是 root）：
./sys.sh
```

运行后会进入交互式菜单，根据提示输入数字选择功能即可。

> 建议：如果想在任意目录直接输入命令名启动，可以把脚本链接到 `PATH` 中：
> ```bash
> sudo ln -sf /root/sys.sh /usr/local/bin/vpsmgr
> ```
> 之后直接输入 `vpsmgr` 即可打开菜单。

---

## 完全卸载

脚本本身**不包含**自动卸载功能，因为它对系统做的改动（BBR、DNS、Swap 等）是持久化配置，删除脚本文件并不会自动撤销这些改动。如果需要把系统恢复到使用本脚本之前的状态，请按下面的步骤手动执行。

> ⚠️ 请按需选择执行，不是所有改动都是脚本造成的（比如你本来就用了 BBR），执行前先确认。

### 第一步：还原 BBR / 网络加速设置

```bash
sudo sed -i '/^net.core.default_qdisc=/d' /etc/sysctl.conf
sudo sed -i '/^net.ipv4.tcp_congestion_control=/d' /etc/sysctl.conf
sudo sed -i '/# VPS 网络优化/d;/# 恢复传统网络配置/d' /etc/sysctl.conf
```

### 第二步：还原出站 IP 优先级设置

```bash
sudo sed -i '/^[[:space:]]*precedence[[:space:]]\+::ffff:0:0\/96/d' /etc/gai.conf
```

### 第三步：还原入站 IPv6 设置

```bash
sudo sed -i '/^net.ipv6.conf.all.disable_ipv6=/d' /etc/sysctl.conf
sudo sed -i '/^net.ipv6.conf.default.disable_ipv6=/d' /etc/sysctl.conf
sudo sed -i '/# IPv4 + IPv6 双栈/d;/# 禁用 IPv6/d' /etc/sysctl.conf

# 让上面的修改立即生效
sudo sysctl -p
```

### 第四步：解锁并还原 DNS

如果之前用脚本"锁定"过 DNS（chattr +i），必须先解锁才能修改：

```bash
sudo chattr -i /etc/resolv.conf 2>/dev/null

# 如果你的系统原本用 systemd-resolved 管理 DNS（Ubuntu 默认如此），
# 恢复为系统默认的符号链接：
sudo rm -f /etc/resolv.conf
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved 2>/dev/null

# 如果你的系统不用 systemd-resolved，改成手动写回你原来的 DNS 即可：
# sudo tee /etc/resolv.conf <<'EOF'
# nameserver 你原来的DNS
# EOF
```

### 第五步：删除 Swapfile

```bash
sudo swapoff /swapfile 2>/dev/null
sudo rm -f /swapfile
sudo sed -i '\|^[[:space:]]*/swapfile[[:space:]]|d' /etc/fstab
```

### 第六步：时区（可选）

脚本修改的时区不影响系统安全和功能，如果需要改回原时区：

```bash
sudo timedatectl set-timezone Asia/Shanghai   # 改成你原来的时区
```

### 第七步：删除脚本本身

```bash
sudo rm -f /root/sys.sh
# 如果创建过软链接：
sudo rm -f /usr/local/bin/vpsmgr
```

### 一键还原（可选，谨慎使用）

如果你确认以上改动都是本脚本造成的，可以把下面的内容保存为 `uninstall.sh` 并执行，一次性完成第一到第五步：

```bash
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "请用 root 运行"; exit 1; }

# BBR
sed -i '/^net.core.default_qdisc=/d;/^net.ipv4.tcp_congestion_control=/d' /etc/sysctl.conf
sed -i '/# VPS 网络优化/d;/# 恢复传统网络配置/d' /etc/sysctl.conf

# 出站 IP 优先级
sed -i '/^[[:space:]]*precedence[[:space:]]\+::ffff:0:0\/96/d' /etc/gai.conf

# 入站 IPv6
sed -i '/^net.ipv6.conf.all.disable_ipv6=/d;/^net.ipv6.conf.default.disable_ipv6=/d' /etc/sysctl.conf
sed -i '/# IPv4 + IPv6 双栈/d;/# 禁用 IPv6/d' /etc/sysctl.conf
sysctl -p >/dev/null 2>&1 || true

# DNS 解锁并恢复默认
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
systemctl restart systemd-resolved 2>/dev/null || true

# Swap
swapoff /swapfile 2>/dev/null || true
rm -f /swapfile
sed -i '\|^[[:space:]]*/swapfile[[:space:]]|d' /etc/fstab

echo "✅ 系统配置已还原。请自行删除脚本文件（sys.sh）。"
```

```bash
chmod +x uninstall.sh
sudo ./uninstall.sh
```

---

## 安全提示

- 脚本所有真删除操作（Swapfile、系统缓存等）都提供二次确认或 Dry-Run 预览，正常使用不会误删用户数据。
- DNS 修改若选择"锁定"，会用 `chattr +i` 给 `/etc/resolv.conf` 加不可变属性，卸载或再次修改前务必先解锁（`chattr -i`），否则会报错"权限拒绝"。
- 修改网络内核参数（BBR、IPv6）后建议重启一次服务器，确认业务连通性正常。
