# Proxy 管理脚本

一键管理 **Snell v6 / SS2022 / AnyTLS** 三个代理协议的服务端脚本，适用于 Surge 客户端用户。

-----

## 支持的协议

|协议    |版本        |客户端支持              |
|------|----------|-------------------|
|Snell |v6（自动获取最新）|Surge              |
|SS2022|自动获取最新    |Surge / QuantumultX|
|AnyTLS|自动获取最新    |Surge              |

-----

## 系统要求

- **操作系统**：Debian / Ubuntu / CentOS / Arch Linux
- **权限**：root
- **架构**：x86_64 / aarch64

-----

## 安装脚本

### 方式一：下载到本地运行（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/proxy.sh -o proxy.sh
bash proxy.sh
```

以后直接运行：

```bash
bash proxy.sh
```

### 方式二：直接运行不保存

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mubdao/Proxy/refs/heads/main/proxy.sh)
```

-----

## 菜单结构

```
代理管理工具
├── 1. 协议管理        → 安装 / 卸载各协议
├── 2. 查看配置        → 查看配置文件 / 导出 Surge 节点
├── 3. 修改配置        → 修改端口、密码、TFO、SNI 等参数
├── 4. 查看状态        → 查看版本、运行状态、更新协议
├── 5. 卸载脚本        → 卸载所有协议（需输入 YES 确认）
└── 0. 退出脚本
```

-----

## 各协议说明

### Snell v6

- **安装位置**：`/usr/local/bin/snell-server`
- **配置文件**：`/etc/snell/snell-server.conf`
- **systemd 服务**：`snell.service`
- **安装时可配置**：端口（默认随机）、PSK（默认随机，至少 16 位）、TFO（默认开启）
- **修改配置支持**：端口、PSK、TFO 开关
- **Surge 节点格式**：
  
  ```
  HK = snell, 服务器IP, 端口, psk = PSK, version = 6, reuse = true, ecn = true, tfo = true
  ```

### SS2022

- **安装位置**：`/usr/local/bin/ssserver`
- **配置文件**：`/etc/ss2022/config.json`
- **systemd 服务**：`ss2022.service`
- **加密方式**：`2022-blake3-aes-128-gcm`
- **安装时可配置**：端口（默认随机）、密码（自动生成 base64，也可手动输入）、TFO（默认开启）
- **注意**：SS2022 密码必须是 base64 格式，建议使用自动生成的密码
- **修改配置支持**：端口、密码、TFO 开关
- **Surge 节点格式**：
  
  ```
  HK = ss, 服务器IP, 端口, encrypt-method = 2022-blake3-aes-128-gcm, password = 密码, tfo = true
  ```

### AnyTLS

- **安装位置**：`/usr/local/bin/anytls-server`
- **配置文件**：`/etc/anytls/anytls.conf`
- **scheme 文件**：`/etc/anytls/scheme.txt`（流量混淆规则）
- **systemd 服务**：`anytls.service`
- **安装时可配置**：端口（默认随机）、密码（默认随机）、SNI（默认 `iosapps.itunes.apple.com`）
- **注意**：AnyTLS 不支持 TFO，无需配置证书
- **修改配置支持**：端口、密码、SNI
- **Surge 节点格式**：
  
  ```
  HK = anytls, 服务器IP, 端口, password = 密码, skip-cert-verify = true, sni = iosapps.itunes.apple.com
  ```

-----

## 防火墙

脚本会自动检测并放行端口：

- 检测到 **ufw** 且处于激活状态，自动执行 `ufw allow 端口/tcp`
- 检测到 **firewalld** 且处于运行状态，自动执行 `firewall-cmd` 放行
- 防火墙未启用则静默跳过，无需手动操作

安装协议和修改端口时都会自动触发。

-----

## 文件路径汇总

|文件           |路径                                  |
|-------------|------------------------------------|
|Snell 二进制    |`/usr/local/bin/snell-server`       |
|Snell 配置     |`/etc/snell/snell-server.conf`      |
|Snell 服务     |`/etc/systemd/system/snell.service` |
|SS2022 二进制   |`/usr/local/bin/ssserver`           |
|SS2022 配置    |`/etc/ss2022/config.json`           |
|SS2022 服务    |`/etc/systemd/system/ss2022.service`|
|AnyTLS 二进制   |`/usr/local/bin/anytls-server`      |
|AnyTLS 配置    |`/etc/anytls/anytls.conf`           |
|AnyTLS scheme|`/etc/anytls/scheme.txt`            |
|AnyTLS 服务    |`/etc/systemd/system/anytls.service`|

-----

## 卸载

### 方式一：通过脚本卸载（推荐）

运行脚本，选择 `5. 卸载脚本`，输入大写 `YES` 确认，会自动卸载所有已安装的协议，并询问是否删除脚本文件本身。

### 方式二：手动完全卸载

如果脚本文件已删除或无法运行，可手动执行以下命令彻底清除所有内容：

```bash
# 停止并禁用所有服务
systemctl stop snell ss2022 anytls 2>/dev/null
systemctl disable snell ss2022 anytls 2>/dev/null

# 删除 systemd 服务文件
rm -f /etc/systemd/system/snell.service
rm -f /etc/systemd/system/ss2022.service
rm -f /etc/systemd/system/anytls.service
systemctl daemon-reload

# 删除二进制文件
rm -f /usr/local/bin/snell-server
rm -f /usr/local/bin/ssserver
rm -f /usr/local/bin/anytls-server

# 删除配置目录
rm -rf /etc/snell
rm -rf /etc/ss2022
rm -rf /etc/anytls

# 删除脚本本身（如果保存在本地）
rm -f proxy.sh
```

### 卸载单个协议

如果只想卸载某个协议，进入脚本 → `1. 协议管理` → 选择对应的卸载选项即可。

也可手动执行（以 Snell 为例）：

```bash
systemctl stop snell && systemctl disable snell
rm -f /etc/systemd/system/snell.service
systemctl daemon-reload
rm -f /usr/local/bin/snell-server
rm -rf /etc/snell
```

-----

## 常见问题

**安装后启动失败？**

查看日志定位问题：

```bash
journalctl -u snell.service -n 30 --no-pager
journalctl -u ss2022.service -n 30 --no-pager
journalctl -u anytls.service -n 30 --no-pager
```

**PSK 要求？**

Snell v6 要求 PSK 至少 16 位，脚本安装时会验证，不足会提示重新输入。

**SS2022 密码格式？**

必须是 base64 格式的 16 字节随机数，建议直接回车使用自动生成的密码，手动输入格式不对会导致启动失败。

**客户端版本要求？**

|协议      |Surge iOS|Surge Mac|
|--------|---------|---------|
|Snell v6|最新版      |最新版      |
|SS2022  |5.0+     |5.0+     |
|AnyTLS  |5.17.0+  |6.4.3+   |

-----

## 上游项目

- [Snell](https://nssurge.com) - Surge 官方出品
- [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) - SS2022 服务端
- [anytls-go](https://github.com/anytls/anytls-go) - AnyTLS 服务端
