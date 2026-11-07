# Dex Lite — VLESS Lite Server

面向 **128 MiB LXC** 的独立 VLESS 服务端安装与命令行管理工具。多个 VLESS 节点与 TCP/UDP 中转共用一个 Xray 进程；节点直接处理 WebSocket 和 TLS，可接入 dex、v2rayN 等客户端。**不部署 DoH、Nginx、Caddy、Docker 或面板。**

## 一条命令安装

在全新的 **Debian 12/13 amd64 或 arm64** 容器中，以 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/stuinx/vless-lite-server/main/install.sh)
```

脚本询问域名，默认监听容器 TCP **2096** 端口，自动生成 UUID；Path 固定为 `/` 加 UUID 最后六位。域名必须解析到节点公网地址，NAT 容器还需提前配置端口转发。客户端填写的公网端口必须与脚本的端口相同；若使用不同端口的 NAT 映射，显示的链接需自行调整为公网端口。

指定端口，例如 33344：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/stuinx/vless-lite-server/main/install.sh) \
  --domain node.example.com --port 33344
```

支持 1024–65535，避免在受限 LXC 中为低端口增加权限。容器需要 systemd、可用的出站网络和可用的 TCP 入站映射。128 MiB 是运行目标，实际内存随并发和核心版本变化；建议宿主机为容器提供 swap，以应对安装和证书签发时的峰值。

## TLS 证书

默认通过 **Cloudflare DNS-01** 签发 Let's Encrypt 证书，不依赖公网 80/443。脚本隐藏输入 DNS 凭据，支持 API Token 和 Global API Key；建议使用仅限目标区域的 `Zone:DNS:Edit` 和 `Zone:Zone:Read` Token。该域名的权威 DNS 区域必须在对应 Cloudflare 账户中。

默认**仅签发一次**，清除 ACME 配置中的 Cloudflare 凭据，不启用自动续期。安装结束显示证书到期时间；到期前需更换证书。若要自动续期，安装时明确加入 `--renew`：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/stuinx/vless-lite-server/main/install.sh) \
  --domain node.example.com --port 33344 --renew
```

此模式会在 `/root/.vless-lite-acme/account.conf` 中保留 DNS 凭据（仅 root 可读），通过 `vless-lite-renew.timer` 每天检查，证书更新后重启服务，现有连接会短暂断开。可通过环境变量 `CF_Token`，或 `CF_Key` 与 `CF_Email` 提供凭据；不要把密钥写进公开命令、仓库或脚本。

也可使用已有证书，跳过 Cloudflare 和 ACME：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/stuinx/vless-lite-server/main/install.sh) \
  --domain node.example.com --port 33344 \
  --cert-file /path/to/fullchain.pem --key-file /path/to/privkey.pem
```

证书需为 PEM 全链，私钥需为未加密 PEM。脚本会检查域名、有效期、私钥匹配，然后复制到 `/etc/vless-lite/tls/`。这种模式的续期由证书提供方负责；更换复制后的证书并设置 `root:vless-lite`、`0640` 权限后执行 `systemctl restart vless-lite`。

## 安装完成后的输出

以下为格式示例，每次安装显示其真实 UUID、Path、二维码和 Link：

```text
Node Information

DoH:       Disabled
Address:   node.example.com:33344
UUID:      00000000-0000-4000-8000-000000123456
Path:      /123456

QR code:
Protocol: vless
[此处由 qrencode 输出可扫描的终端二维码]

Link:      vless://00000000-0000-4000-8000-000000123456@node.example.com:33344?encryption=none&security=tls&type=ws&host=node.example.com&sni=node.example.com&path=%2F123456#node.example.com:33344
```

安装后运行 `dex-lite info` 可再次显示；旧命令 `vless-lite` 仍可使用。终端需使用等宽字体，并有足够宽度显示完整二维码；Link 含登录凭据，请妥善保存。

## 节点管理

首次安装创建名为 `main` 的节点。新增节点复用安装时的域名和证书，每个节点有独立端口、UUID 和 `/UUID末六位` 路径：

```bash
dex-lite node list
dex-lite info
dex-lite node add extra 33345
dex-lite node info extra
dex-lite node del extra
```

`node add NAME PORT [UUID]` 的 UUID 可省略并自动生成。新增成功会输出节点信息、二维码和 Link。名称支持 1–32 个字母、数字、下划线或连字符。不同节点/中转使用不同的监听端口，监听 IPv4 的所有接口；请按需要限制外部防火墙。

## TCP / UDP 中转

不另开 HAProxy 或第二个核心。中转采用 Xray Dokodemo-door 端口映射入站（新文档称 Tunnel），数据由 direct 出站转发：

```bash
# 本机 TCP 33346 → 最终节点 node.example.com:33344
dex-lite relay add transit 33346 node.example.com 33344
dex-lite relay list
dex-lite relay info transit
dex-lite relay del transit

# 同时转发原生 TCP 和 UDP
dex-lite relay add game 33347 target.example.com 12345 tcp,udp
```

语法：`relay add NAME LISTEN_PORT TARGET_HOST TARGET_PORT [tcp|udp|tcp,udp]`，默认 TCP。目标填写域名或 IP，不带 URL scheme、端口或 IPv6 方括号；目标端口支持 1–65535，监听端口支持 1024–65535。新增规则是未认证的固定目标端口转发，按需限制入口来源，尤其不要无意对公网提供开放 DNS 转发。

转发 VLESS WS TLS 时，中转端透传 TLS，不申请证书。客户端的 **Address 改成中转机地址与入口端口；TLS/SNI、WS Host、UUID、Path 仍使用最终服务端的值**。这同样能携带封装在 VLESS WS/TCP 内的 UDP 代理数据；独立 UDP 模式则是转发原生 UDP 数据报。

## 应用与恢复

节点和中转的每次增删会：检查参数、端口占用和配置 → 校验真实 Xray 配置 → 重启同一个服务。**重启会短暂中断现有连接**。失败会恢复上一份配置与元数据并尝试重新启动；若恢复启动仍失败，会输出保留的恢复目录。

元数据位于 `/etc/vless-lite/state.json`。管理命令使用文件锁串行处理修改；如果发现核心配置被手工修改，会拒绝覆盖，避免丢失自定义内容。节点增删不重新申请证书，不增加常驻服务。

## 从初版升级

已通过本项目初版安装的机器可运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/stuinx/vless-lite-server/main/install.sh) --upgrade
```

升级管理命令、增加 `dex-lite` 别名，将旧 `node.json` 迁移为管理元数据；保留已有 UUID、端口、路径、证书、核心和运行配置，不重启服务。遇到自定义配置会拒绝自动迁移。该命令适用于本项目已有安装，不会接管 dex 或其他脚本创建的服务。

## 服务和客户端配置

```bash
systemctl status vless-lite
journalctl -u vless-lite -n 30 --no-pager
dex-lite info
```

配置位于 `/etc/vless-lite/config.json`，服务使用专用用户 `vless-lite`。新安装程序拒绝覆盖已有安装；已有安装使用 `--upgrade` 更新管理工具。

在 dex 添加普通节点：Address 填 `域名:端口`，TLS/SNI 填域名，UUID 和 Path 按输出填写，协议为 VLESS。不要将 `DoH: Disabled` 填入客户端的 DoH 设置。

核心来自 XTLS/Xray-core 官方 Release，下载后核对官方 SHA256；可用 `--version v26.10.31` 固定版本。官方当前仍支持 WS，但已发出弃用提示；此项目按现有 dex 客户端兼容要求使用 WS。二维码由 Debian 的 `qrencode` 软件包生成，无常驻二维码进程。

## 验证范围

现有 128 MiB LXC 上的同类单进程方案已测得约 11 MiB 空闲占用，并通过 dex Xray 26.3.27 客户端的 HTTPS 代理请求。此数字不是所有安装的内存保证。

本仓库的验证记录见 `VALIDATION.md`。完整安装涉及包安装、证书签发和 systemd；不能把配置测试等同于所有系统和架构的完整安装验收。额外节点及中转会增加连接缓冲和内存，单进程不代表零额外开销。
