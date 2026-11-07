# VLESS Lite Server

面向 **128 MiB LXC** 的独立 VLESS 服务端安装脚本。仅运行一个 Xray 进程，直接处理 WebSocket 和 TLS；可接入 dex、v2rayN 等支持 VLESS WS TLS 的客户端。**不部署 DoH、Nginx、Caddy、Docker 或面板。**

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

安装后运行 `vless-lite info` 可再次显示。终端需使用等宽字体，并有足够宽度显示完整二维码；Link 含登录凭据，请妥善保存。

## 管理和客户端配置

```bash
systemctl status vless-lite
journalctl -u vless-lite -n 30 --no-pager
vless-lite info
```

配置位于 `/etc/vless-lite/config.json`，服务使用专用用户 `vless-lite`。安装程序拒绝覆盖已有安装，也不替换 dex 的现有服务；如端口已被占用，会中止安装。

在 dex 添加普通节点：Address 填 `域名:端口`，TLS/SNI 填域名，UUID 和 Path 按输出填写，协议为 VLESS。不要将 `DoH: Disabled` 填入客户端的 DoH 设置。

核心来自 XTLS/Xray-core 官方 Release，下载后核对官方 SHA256；可用 `--version v26.10.31` 固定版本。官方当前仍支持 WS，但已发出弃用提示；此项目按现有 dex 客户端兼容要求使用 WS。二维码由 Debian 的 `qrencode` 软件包生成，无常驻二维码进程。

## 验证范围

现有 128 MiB LXC 上的同类单进程方案已测得约 11 MiB 空闲占用，并通过 dex Xray 26.3.27 客户端的 HTTPS 代理请求。此数字不是所有安装的内存保证。

本仓库的验证记录见 `VALIDATION.md`。完整安装涉及包安装、证书签发和 systemd；不能把配置测试等同于所有系统和架构的完整安装验收。
