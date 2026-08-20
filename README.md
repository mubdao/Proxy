这是根据 Snell 脚本目前实际逻辑写的说明，可以直接发给用户或放进 README。

---

## 📦 首次安装使用

**1. 安装脚本（需要 root 权限）**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/snell.sh)
```

**2. 首次运行后会自动进入菜单，选 `1. 安装 / 重构节点` 即可完成全部部署：**

```
1. 安装 / 重构节点   ← 选这个，按提示填端口 / PSK（可回车用默认值/自动生成），装好即用
```

装完会自动启动服务，并打印出 Surge 格式的节点信息（`snell, IP, 端口, psk=..., version=...`）。

**3. 以后想再打开脚本，直接在终端输入：**

```bash
snell
```

不用再重新下载，`snell` 命令会自动唤醒本地已保存好的脚本（`/root/snell.sh`）。

---

## 🗑️ 完全卸载（清空所有内容 + 脚本本身）

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

卸载完成后，`snell` 命令也会同步失效，等于彻底清干净，不留任何痕迹。

**方法二：一键非交互卸载（不进菜单，适合脚本化/远程执行）**

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

两种方法效果完全一致，方法一更安全（有二次确认），方法二适合不想交互、直接一条命令跑完的场景。
