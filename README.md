## 📦 Sing-Box 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/sb.sh)
```

以后想再打开脚本，直接在终端输入 `sb` 即可（自动唤醒本地已保存的脚本 `/root/sb.sh`）。

## 🗑️ Sing-Box 完全卸载

**方法一：脚本内菜单卸载（推荐）**

```bash
sb
```
进菜单后选 `7. 卸载 Sing-Box`，输入 `y` 确认。这一步会自动删除：
- Sing-Box 服务、二进制文件
- 所有节点配置（`/etc/sing-box`）
- 证书目录（`/root/AnyTLS`）
- 脚本本体（`/root/sb.sh`）
- `sb` 快捷命令（`/usr/local/bin/sb`、`/usr/bin/sb`）

**方法二：一键非交互卸载**

```bash
bash -c '
systemctl stop sing-box 2>/dev/null
systemctl disable sing-box 2>/dev/null
rm -f /etc/systemd/system/sing-box.service
rm -f /usr/bin/sing-box /usr/local/bin/sing-box /usr/local/bin/sb /usr/bin/sb /root/sb.sh
rm -rf /etc/sing-box /root/.sb_info.json /root/AnyTLS
systemctl daemon-reload
echo "Sing-Box 及脚本组件已彻底卸载完成！"
'
```

---

## 📦 Snell 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/snell.sh)
```

以后想再打开脚本，直接在终端输入 `snell` 即可（自动唤醒本地已保存的脚本 `/root/snell.sh`）。

## 🗑️ Snell 完全卸载

**方法一：脚本内菜单卸载（推荐）**

```bash
snell
```
进菜单后选 `6. 卸载 Snell`，输入 `y` 确认。这一步会自动删除：
- Snell 服务、二进制文件（`snell-server`）
- 节点配置文件（`/etc/snell/snell-server.conf`）
- 节点信息文件（`/root/.snell_info.json`）
- 脚本本体（`/root/snell.sh`）
- `snell` 快捷命令（`/usr/local/bin/snell`、`/usr/bin/snell`）

**方法二：一键非交互卸载**

```bash
bash -c '
systemctl stop snell.service 2>/dev/null
systemctl disable snell.service 2>/dev/null
rm -f /etc/systemd/system/snell.service
rm -f /usr/local/bin/snell-server /usr/local/bin/snell /usr/bin/snell /root/snell.sh
rm -f /etc/snell/snell-server.conf /root/.snell_info.json
systemctl daemon-reload
echo "Snell 及脚本组件已彻底卸载完成！"
'
```
