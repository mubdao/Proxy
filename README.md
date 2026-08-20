Sing-Box 脚本
📦 一键安装
bash <(curl -fsSL https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/sb.sh)

🗑️ 完全卸载
方法一：菜单卸载（推荐）
终端输入 sb 进入菜单，选择 7. 卸载 Sing-Box 并输入 y 确认。
方法二：一键命令卸载（无需交互）
bash -c '
systemctl stop sing-box 2>/dev/null
systemctl disable sing-box 2>/dev/null
rm -f /etc/systemd/system/sing-box.service
rm -f /usr/bin/sing-box /usr/local/bin/sing-box /usr/local/bin/sb /usr/bin/sb /root/sb.sh
rm -rf /etc/sing-box /root/.sb_info.json /root/AnyTLS
systemctl daemon-reload
echo "Sing-Box 及脚本组件已彻底卸载完成！"
'

Snell 脚本
📦 一键安装
bash <(curl -fsSL https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/snell.sh)

🗑️ 完全卸载
方法一：菜单卸载（推荐）
终端输入 snell 进入菜单，选择 6. 卸载 Snell 并输入 y 确认。
方法二：一键命令卸载（无需交互）
bash -c '
systemctl stop snell.service 2>/dev/null
systemctl disable snell.service 2>/dev/null
rm -f /etc/systemd/system/snell.service
rm -f /usr/local/bin/snell-server /usr/local/bin/snell /usr/bin/snell /root/snell.sh
rm -f /etc/snell/snell-server.conf /root/.snell_info.json
systemctl daemon-reload
echo "Snell 及脚本组件已彻底卸载完成！"
'

