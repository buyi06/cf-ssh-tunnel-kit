# cf-ssh-tunnel-kit

> **无显示器 Linux 的全中文 Cloudflare SSH Tunnel 一键部署工具。** 执行一条命令，自动安装 `cloudflared`（已安装则跳过）、终端显示浏览器授权链接、填写域名后自动创建 Tunnel、DNS 路由、SSH 配置和 systemd 服务。

它适合家用 Linux、小主机、NAS、树莓派和没有公网入站 IP 的云服务器。脚本只把 Cloudflare Tunnel 接到本机 `ssh://localhost:22`，不会开放服务器入站 `22` 端口，不改动 `sshd_config`，也不创建裸 TCP SSH 公网转发。

## 一条命令开始

```bash
git clone https://github.com/buyi06/cf-ssh-tunnel-kit.git
cd cf-ssh-tunnel-kit
sudo bash scripts/cf-ssh-tunnel.sh install --mainland
```

执行后，脚本会按中文提示完成以下流程：

| 步骤 | 你需要做什么 | 脚本自动完成什么 |
|---|---|---|
| 1. 检查环境 | 无需操作。 | 检查本机 SSH、DNS、Cloudflare TCP/7844；检测 `cloudflared`，未安装时自动安装。 |
| 2. Cloudflare 授权 | 复制终端显示的 `https://...` 链接，在任意浏览器打开并选择站点。 | 等待授权成功，不需要服务器显示器。 |
| 3. 填写域名 | 输入完整域名，例如 `ssh.example.com`。 | 创建 Tunnel、自动写 DNS CNAME、生成 `ssh://localhost:22` ingress、校验配置、启动 systemd 服务。 |
| 4. 直接连接 | 无需额外控制台设置。 | 输出客户端 SSH 配置模板；继续使用服务器原有的 SSH 密钥或密码认证。 |

> `--mainland` 使用 HTTP/2/TCP 7844，适合 UDP/QUIC 不稳定的网络。它不保证任何网络一定可连，也不会绕过网络限制。默认 `--auto` 会优先 QUIC，失败时回退 HTTP/2。[1]

在 `--mainland` 模式下，脚本还会自动测速 `gh-proxy.org`、`v4.gh-proxy.org`、`v6.gh-proxy.org`、`cdn.gh-proxy.org` 和 `axisnow.gh-proxy.org`，选择可用且延迟最低者，并为当前管理员账户写入 Git 的 GitHub URL 重写规则。它只影响 Git 的 `https://github.com/` 克隆和拉取，不设置 `HTTP_PROXY` / `HTTPS_PROXY`，不会代理 apt、Cloudflare 授权、Tunnel 或系统其他流量。

如果 Debian amd64 主机尚未安装 `cloudflared`，同一次测速还会挑选能够透传 Cloudflare 官方 GitHub Release `.deb` 包的最快代理。脚本先从 GitHub 官方 Release 页面取得版本和 SHA-256，再下载代理文件、校验 SHA-256、校验 Debian 包结构，**全部通过才安装**；任一步失败都会改用 Cloudflare 官方签名 APT 软件源。可随时重新测速或关闭 Git 加速：

```bash
sudo bash scripts/cf-ssh-tunnel.sh github-proxy
sudo bash scripts/cf-ssh-tunnel.sh github-proxy --disable
```

## 必要前提

你的域名必须已添加到 Cloudflare，且 DNS 已交由 Cloudflare 托管。服务器上必须已有正在运行的 SSH 服务，通常监听 `22` 端口。Cloudflare 官方的本地管理 Tunnel 支持在授权后使用 CLI 自动创建 Tunnel 和 DNS 路由。[2]

## 连接与安全边界

Tunnel 和 DNS 完成后即可连接，不需要再配置 Cloudflare Access。客户端使用 `cloudflared` 作为 SSH 的 Tunnel 代理，随后继续由服务器上的 `sshd` 验证 Linux 用户、SSH 密钥或密码。[3]

> 不配置 Cloudflare Access 时，该 SSH 域名会向 Internet 公开可达。[4] 这不等于任何人都能登录，但请优先使用 SSH 密钥认证，并关闭不需要的 root 或密码登录。

## 客户端连接

在你的电脑安装 `cloudflared` 后，运行：

```bash
bash scripts/cf-ssh-tunnel.sh client-config ssh.example.com
```

把输出内容复制到 `~/.ssh/config`，然后连接：

```bash
ssh <你的 Linux 用户名>@ssh.example.com
```

## 维护命令

| 用途 | 命令 |
|---|---|
| 查看服务、Tunnel UUID 与域名 | `sudo bash scripts/cf-ssh-tunnel.sh status` |
| 检查网络、SSH 和日志 | `sudo bash scripts/cf-ssh-tunnel.sh diagnose` |
| 更新或安装 cloudflared | `sudo bash scripts/cf-ssh-tunnel.sh update` |
| 输出客户端 SSH 配置 | `bash scripts/cf-ssh-tunnel.sh client-config` |
| 删除本机服务与专用凭据 | `sudo bash scripts/cf-ssh-tunnel.sh uninstall` |

完整的步骤、故障排查、发行版说明和安全边界，请阅读[中文部署指南](docs/cf-ssh-tunnel.md)。技术实现和官方依据详见[研究记录](docs/cf-ssh-tunnel-research.md)。

## 测试

```bash
./tests/test-cf-ssh-tunnel.sh
```

## 许可

本项目采用 [MIT License](LICENSE)。

## 参考资料

[1]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/ "Cloudflare: Tunnel run parameters"
[2]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/ "Cloudflare: Create a locally-managed tunnel"
[3]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/ "Cloudflare: Connect to SSH with client-side cloudflared"
[4]: https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/ "Cloudflare: Publish a self-hosted application to the Internet"
