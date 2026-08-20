
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

---

## 📦 Singbox首次安装使用

**1. 安装脚本（需要 root 权限）**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/sb.sh)
```

**2. 首次运行后会自动进入菜单，按提示操作：**

```
1. SingBox管理 (安装/更新)   ← 先选这个，进子菜单选 "1. 安装 Sing-Box"，装内核
2. 重构节点配置              ← 内核装好后选这个，按提示填端口/密码/域名，生成节点
4. 查看节点链接              ← 配置完成后看 anytls:// 或 ss:// 链接、Surge 格式
```

**3. 以后想再打开脚本，直接在终端输入：**

```bash
sb
```

不用再重新下载，`sb` 命令会自动唤醒本地已保存好的脚本（`/root/sb.sh`）。

---

## 🗑️ 完全卸载（清空所有内容 + 脚本本身）

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

卸载完成后，`sb` 命令也会同步失效，等于彻底清干净，不留任何痕迹。

**方法二：一键非交互卸载（不进菜单，适合脚本化/远程执行）**

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

两种方法效果完全一致，方法一更安全（有二次确认），方法二适合不想交互、直接一条命令跑完的场景。
