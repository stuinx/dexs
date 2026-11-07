# 验证记录

日期：2026-11-07（Asia/Taipei）。

## 本仓库已验证

- `bash -n install.sh tests/smoke.sh`：通过。
- ShellCheck 0.9.0：`shellcheck -x install.sh tests/smoke.sh`，通过。
- 在 vm1225 的 Debian 12 上，使用实际 dex 核心 Xray 26.3.27 执行 `tests/smoke.sh`：通过。
- 使用从官方 Release 下载并核对 SHA256 的 Xray 26.10.31，再次运行相同测试：通过。
- 安装器函数生成的 VLESS WS TLS 服务端 JSON 通过核心配置检查。
- 使用测试 UUID 验证 `/` 加 UUID 末六位的路径生成、输出字段、URI 的 `%2F` 编码。
- 使用真实 `qrencode` 生成终端二维码，验证输出存在；未做手机扫码或图像解码验收。
- 用合成 Cloudflare 凭据配置验证一次性签发后的凭据清理；保留其他 ACME 配置。
- 临时服务端和客户端使用 TLS 证书建立 VLESS WS 连接，测试客户端显式信任临时自签 CA，HTTPS 代理请求返回 HTTP 200。生产配置没有关闭证书验证。
- 多节点和中转共用同一份核心配置，新增、列表、详情、删除命令通过；新增节点保持 UUID 末六位路径和二维码输出。
- 实际链路 `客户端 → TCP 中转入口 → VLESS WS TLS 服务端 → HTTPS 网站` 返回 HTTP 200，中转不终止 TLS。
- 原生 UDP 中转的本地回显请求通过。
- 重复监听端口、非法目标拒绝，原配置不变；注入一次重启失败后，配置与元数据恢复至修改前的 SHA256，核心重新运行。
- 手工改动核心配置后，管理命令拒绝覆盖。
- 旧版 `node.json` 迁移为 `state.json` 的测试通过，原配置文件、UUID 保持一致；生成的独立管理命令可执行。
- 所有测试服务、配置、依赖均在临时目录或临时进程中运行，未安装或替换 vm1225 的现有服务。

管理测试仅替换了 `systemctl` 控制接口：每次重启实际运行真实 Xray 进程；未在宿主机创建管理服务。这验证了参数处理、配置生成、真实流量和回滚逻辑，不代表实际 systemd 安装/升级已验收。

复现：在 Linux 主机准备 `jq`、`qrencode`、`openssl`、`curl`、`ss`、`flock`、Python 3 和 Xray，然后以 root 执行：

```bash
XRAY_BIN=/path/to/xray bash tests/smoke.sh
```

## 本次会话的部署证据

现有 128 MiB Debian 13 LXC 的单进程 Xray WS TLS 服务端已由 dex Xray 26.3.27 客户端完成外部 HTTPS 代理请求验证，HTTP 200；其 UUID 末六位 Path 也已实测。此部署早于本安装器，不等同于运行了本安装器。

Cloudflare DNS-01 单次签发和清理 DNS 验证记录在现有 LXC 成功执行过。本安装器复用了相同流程，但未重新申请生产证书。

## 尚未验证

- 在全新 128 MiB LXC 中从零运行整个安装器，包括 APT、用户创建、systemd 和生产证书签发。
- arm64 实机安装。
- 自动续期定时器实际触发一次证书更新。
- 新版管理工具在实际安装目录中的升级和真实 systemd 重启回滚。
- 高并发和长时间内存压力测试、跨公网 UDP 中转。

安装器设计为新建独立服务，拒绝覆盖已有安装。安装中途失败时可能留下软件包、专用用户或部分 `/etc/vless-lite` 文件，应根据报错检查后清理；不要对已有安装直接删除目录重试。
