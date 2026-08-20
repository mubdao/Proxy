# Proxy Scripts Collection

支持 **Sing-Box** 与 **Snell** 的轻量级 Linux 部署与管理脚本。

---

## 🚀 Sing-Box 脚本

### 安装

```bash
bash <(curl -fsSL [https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/sb.sh](https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/sb.sh))

卸载
 * 菜单卸载：运行 sb 后选择 7. 卸载 Sing-Box
 * 一键卸载：
   bash -c '
systemctl stop sing-box 2>/dev/null
systemctl disable sing-box 2>/dev/null
rm -f /etc/systemd/system/sing-box.service
rm -f /usr/bin/sing-box /usr/local/bin/sing-box /usr/local/bin/sb /usr/bin/sb /root/sb.sh
rm -rf /etc/sing-box /root/.sb_info.json /root/AnyTLS
systemctl daemon-reload
echo "Sing-Box 及脚本组件已彻底卸载完成！"
'

⚡ Snell 脚本
安装
bash <(curl -fsSL [https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/snell.sh](https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/snell.sh))

卸载
 * 菜单卸载：运行 snell 后选择 6. 卸载 Snell
 * 一键卸载：
   bash -c '
systemctl stop snell.service 2>/dev/null
systemctl disable snell.service 2>/dev/null
rm -f /etc/systemd/system/snell.service
rm -f /usr/local/bin/snell-server /usr/local/bin/snell /usr/bin/snell /root/snell.sh
rm -f /etc/snell/snell-server.conf /root/.snell_info.json
systemctl daemon-reload
echo "Snell 及脚本组件已彻底卸载完成！"
'


