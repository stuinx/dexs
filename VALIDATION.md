# 验证记录

日期：2026-11-07（Asia/Taipei）。

## 本仓库已验证

- `bash -n install.sh tests/smoke.sh`：通过。
- ShellCheck 0.9.0：`shellcheck -x install.sh tests/smoke.sh`，通过。
- 在 vm1225 的 Debian 12 上，使用实际 dex 核心 Xray 26.3.27 执行 `tests/smoke.sh`：通过。
- 安装器函数生成的 VLESS WS TLS 服务端 JSON 通过核心配置检查。
- 使用测试 UUID 验证 `/` 加 UUID 末六位的路径生成、输出字段、URI 的 `%2F` 编码。
- 使用真实 `qrencode` 生成终端二维码，验证输出存在；未做手机扫码或图像解码验收。
- 用合成 Cloudflare 凭据配置验证一次性签发后的凭据清理；保留其他 ACME 配置。
- 临时服务端和客户端使用 TLS 证书建立 VLESS WS 连接，测试客户端显式信任临时自签 CA，HTTPS 代理请求返回 HTTP 200。生产配置没有关闭证书验证。
- 所有测试服务、配置、依赖均在临时目录或临时进程中运行，未安装或替换 vm1225 的现有服务。

复现：在 Linux 主机准备 `jq`、`qrencode`、`openssl`、`curl`、`ss` 和 Xray，然后执行：

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
- 高并发和长时间内存压力测试、UDP 数据面。

安装器设计为新建独立服务，拒绝覆盖已有安装。安装中途失败时可能留下软件包、专用用户或部分 `/etc/vless-lite` 文件，应根据报错检查后清理；不要对已有安装直接删除目录重试。
