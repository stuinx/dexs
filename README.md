# dexs

面向 **128 MiB LXC** 的独立 VLESS 服务端安装与命令行管理工具。多个 VLESS 节点与 TCP/UDP 中转共用一个 Xray 进程；节点直接处理 WebSocket 和 TLS，可接入 dex、v2rayN 等客户端。**不部署 DoH、Nginx、Caddy、Docker 或面板。**

核心用途只有两项：**创建兼容 dex 的服务端节点**，以及**中转其他已有服务端节点**。可以安装为节点服务器（并按需追加中转），也可以仅安装中转。

## 一条命令安装

支持 **Debian 12/13 + systemd**、**Alpine 3.x + OpenRC**，CPU 为 amd64 或 arm64。在全新 Debian 容器中，以 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/stuinx/dexs/main/install.sh)
```

Alpine 默认的 ash 不能解析 Bash 的进程替换语法，首次安装使用：

```sh
apk add --no-cache bash curl && bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/stuinx/dexs/main/install.sh)'
```

Alpine 安装器使用 `apk`、OpenRC 和专用服务用户；节点模式使用 community 仓库的 `libqrencode-tools` 输出二维码，需要启用对应 Alpine 版本的 community 仓库。要求容器正常通过 OpenRC 启动，不支持没有初始化服务的后台运行模式。

下文含 `<(...)` 的 Bash 示例，在 Alpine 的 ash 中使用前请先运行 `bash`；也可像上面一样放进 `bash -c '...'` 中。

不带参数会打开 dex 风格的彩色终端菜单：

```text
============ DEXS · SERVER =================================
  VLESS + WS + TLS                 TCP / UDP 中转
  Server 节点: 0                 中转规则: 0
================================================================

1. 安装
2. 中转
9. 查看
0. 退出

Select:
```

首次选择 `1` 进入 Server 节点安装向导，选择 `2` 进入纯中转安装向导。安装后直接运行 `dexs` 打开同样的菜单：`1` 进入节点管理，`2` 进入中转管理，子菜单支持新增、列表、详情和删除；删除需再次确认。`9` 显示节点/中转列表、首个条目的信息（节点含二维码）和服务状态，`0` 退出。原有命令行参数继续可用。

Server 向导询问域名、端口、可选 UUID、证书来源和续期选择；默认监听容器 TCP **2096** 端口，自动生成 UUID，Path 固定为 `/` 加 UUID 最后六位。域名必须解析到节点公网地址，NAT 容器还需提前配置端口转发。客户端填写的公网端口必须与脚本的端口相同；若使用不同端口的 NAT 映射，显示的链接需自行调整为公网端口。

指定端口，例如 33344：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/stuinx/dexs/main/install.sh) \
  --domain node.example.com --port 33344
```

默认 `--mode server` 创建 VLESS WS TLS 节点。纯中转安装使用 `--mode relay`，不需要本机域名、证书、Cloudflare 凭据或 UUID：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/stuinx/dexs/main/install.sh) \
  --mode relay --port 33346 --target-host node.example.com --target-port 33344
```

这表示容器的 TCP 33346 转发到已有节点 `node.example.com:33344`；可加 `--network tcp,udp`。纯中转模式跳过二维码工具和证书申请流程，完成后输出真实中转参数。运行 `dexs info` 查看默认中转；用 `relay add/list/info/del` 管理其他规则。尚未配置本地 TLS 节点的纯中转安装不能用 `node add` 创建节点。

支持 1024–65535，避免在受限 LXC 中为低端口增加权限。容器需要运行中的 systemd 或 OpenRC、可用的出站网络和可用的 TCP 入站映射。128 MiB 是运行目标，实际内存随并发和核心版本变化；建议宿主机为容器提供 swap，以应对安装和证书签发时的峰值。

## TLS 证书

默认通过 **Cloudflare DNS-01** 签发 Let's Encrypt 证书，不依赖公网 80/443。脚本隐藏输入 DNS 凭据，支持 API Token 和 Global API Key；建议使用仅限目标区域的 `Zone:DNS:Edit` 和 `Zone:Zone:Read` Token。该域名的权威 DNS 区域必须在对应 Cloudflare 账户中。

默认**仅签发一次**，清除 ACME 配置中的 Cloudflare 凭据，不启用自动续期。安装结束显示证书到期时间；到期前需更换证书。若要自动续期，安装时明确加入 `--renew`：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/stuinx/dexs/main/install.sh) \
  --domain node.example.com --port 33344 --renew
```

此模式会在 `/root/.vless-lite-acme/account.conf` 中保留 DNS 凭据（仅 root 可读）。Debian 通过 `vless-lite-renew.timer` 每天检查，Alpine 通过 `/etc/periodic/daily/vless-lite-renew` 和 `crond` 检查。证书更新后重启正在运行的服务，现有连接会短暂断开。可通过环境变量 `CF_Token`，或 `CF_Key` 与 `CF_Email` 提供凭据；不要把密钥写进公开命令、仓库或脚本。

也可使用已有证书，跳过 Cloudflare 和 ACME：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/stuinx/dexs/main/install.sh) \
  --domain node.example.com --port 33344 \
  --cert-file /path/to/fullchain.pem --key-file /path/to/privkey.pem
```

证书需为 PEM 全链，私钥需为未加密 PEM。脚本会检查域名、有效期、私钥匹配，然后复制到 `/etc/vless-lite/tls/`。这种模式的续期由证书提供方负责；更换复制后的证书并设置 `root:vless-lite`、`0640` 权限后执行 `dexs cert-reload`。

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

安装后运行 `dexs info` 可再次显示；旧命令 `dex-lite` 和 `vless-lite` 仍可使用。终端需使用等宽字体，并有足够宽度显示完整二维码；Link 含登录凭据，请妥善保存。

## 节点管理

喜欢菜单操作时直接运行 `dexs`；以下为同样功能的命令行用法。

首次安装创建名为 `main` 的节点。新增节点复用安装时的域名和证书，每个节点有独立端口、UUID 和 `/UUID末六位` 路径：

```bash
dexs node list
dexs info
dexs node add extra 33345
dexs node info extra
dexs node del extra
```

`node add NAME PORT [UUID]` 的 UUID 可省略并自动生成。新增成功会输出节点信息、二维码和 Link。名称支持 1–32 个字母、数字、下划线或连字符。不同节点/中转使用不同的监听端口，监听 IPv4 的所有接口；请按需要限制外部防火墙。

## TCP / UDP 中转

不另开 HAProxy 或第二个核心。中转采用 Xray Dokodemo-door 端口映射入站（新文档称 Tunnel），数据由 direct 出站转发：

```bash
# 本机 TCP 33346 → 最终节点 node.example.com:33344
dexs relay add transit 33346 node.example.com 33344
dexs relay list
dexs relay info transit
dexs relay del transit

# 同时转发原生 TCP 和 UDP
dexs relay add game 33347 target.example.com 12345 tcp,udp
```

语法：`relay add NAME LISTEN_PORT TARGET_HOST TARGET_PORT [tcp|udp|tcp,udp]`，默认 TCP。目标填写域名或 IP，不带 URL scheme、端口或 IPv6 方括号；目标端口支持 1–65535，监听端口支持 1024–65535。新增规则是未认证的固定目标端口转发，按需限制入口来源，尤其不要无意对公网提供开放 DNS 转发。

转发 VLESS WS TLS 时，中转端透传 TLS，不申请证书。客户端的 **Address 改成中转机地址与入口端口；TLS/SNI、WS Host、UUID、Path 仍使用最终服务端的值**。这同样能携带封装在 VLESS WS/TCP 内的 UDP 代理数据；独立 UDP 模式则是转发原生 UDP 数据报。

## 应用与恢复

节点和中转的每次增删会：检查参数、端口占用和配置 → 校验真实 Xray 配置 → 重启同一个服务。**重启会短暂中断现有连接**。失败会恢复上一份配置与元数据并尝试重新启动；若恢复启动仍失败，会输出保留的恢复目录。

元数据位于 `/etc/vless-lite/state.json`。管理命令使用文件锁串行处理修改；如果发现核心配置被手工修改，会拒绝覆盖，避免丢失自定义内容。节点增删不重新申请证书，不增加常驻服务。

## 从初版升级

已通过本项目初版安装的机器可运行：

```bash
bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/stuinx/dexs/main/install.sh) --upgrade'
```

升级管理命令为 `dexs`，旧命令 `dex-lite` / `vless-lite` 转为兼容入口，并将旧 `node.json` 迁移为管理元数据；保留已有 UUID、端口、路径、证书、核心和运行配置，不重启服务。遇到自定义配置或无关同名命令会拒绝自动迁移。该命令适用于本项目已有安装，不会接管 dex 或其他脚本创建的服务。

项目与仓库现名为 **dexs**。为兼容已部署节点及证书续期任务，配置目录 `/etc/vless-lite`、服务名/用户 `vless-lite` 和核心文件名 `vless-lite-xray` 延续原名；日常操作统一使用 `dexs`。

## 服务和客户端配置

```bash
systemctl status vless-lite
journalctl -u vless-lite -n 30 --no-pager
dexs info
```

Alpine 使用对应的 OpenRC 命令；`dexs status` 会自动选择服务管理器：

```sh
rc-service vless-lite status
rc-service vless-lite restart
tail -n 30 /var/log/vless-lite.log
dexs status
```

配置位于 `/etc/vless-lite/config.json`，服务使用专用用户 `vless-lite`。新安装程序拒绝覆盖已有安装；已有安装使用 `--upgrade` 更新管理工具。

在 dex 添加普通节点：Address 填 `域名:端口`，TLS/SNI 填域名，UUID 和 Path 按输出填写，协议为 VLESS。不要将 `DoH: Disabled` 填入客户端的 DoH 设置。

核心来自 XTLS/Xray-core 官方 Release，下载后核对官方 SHA256；可用 `--version v26.10.31` 固定版本。官方当前仍支持 WS，但已发出弃用提示；此项目按现有 dex 客户端兼容要求使用 WS。二维码由 `qrencode` 命令生成，无常驻二维码进程。

## 验证范围

现有 128 MiB LXC 上的同类单进程方案已测得约 11 MiB 空闲占用，并通过 dex Xray 26.3.27 客户端的 HTTPS 代理请求。此数字不是所有安装的内存保证。

本仓库的验证记录见 `VALIDATION.md`。Alpine 3.22 amd64 已在 128 MiB 测试容器中完成自备证书节点安装、纯中转安装和真实 OpenRC 管理验证；Alpine DNS 签发/续期、原生 LXC 引导及 arm64 仍待验收。额外节点及中转会增加连接缓冲和内存，单进程不代表零额外开销。
