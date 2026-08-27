# 无显示器 Linux 的一键 Cloudflare SSH Tunnel

> 本工具服务于没有显示器、只有命令行的 Linux 主机。它会自动检测或安装 `cloudflared`，在终端显示 Cloudflare 浏览器授权链接；授权完成后，只需要输入 SSH 域名，脚本便会自动创建 Tunnel、DNS CNAME 路由、`ssh://localhost:22` ingress 配置和 systemd 服务。

脚本位于 [`scripts/cf-ssh-tunnel.sh`](../scripts/cf-ssh-tunnel.sh)。它不会开放服务器的入站 `22` 端口，不会改动 `sshd_config`，也不会将 Tunnel 凭据写进命令行、日志或 Git 仓库。

| 项目 | 自动完成的内容 |
|---|---|
| 客户端安装 | 已检测到可用 `cloudflared` 时跳过；否则通过官方软件源或发行版软件包自动安装。 |
| 无显示器授权 | `cloudflared tunnel login` 在终端给出授权链接；可在任意手机或电脑浏览器打开完成授权。 |
| Tunnel 与 DNS | 自动创建本地管理 Tunnel，并将用户输入的域名 CNAME 到 `<UUID>.cfargotunnel.com`。[1] |
| SSH 服务路由 | 自动生成 `ssh://localhost:22` ingress 和最后的 `http_status:404` 兜底规则。[2] |
| 开机运行 | 创建受限 systemd 服务，失败自动重启，服务进程仅可读取该 Tunnel 专用 JSON 凭据。 |
| SSH 认证 | 不需要额外 Access 控制台配置；继续使用服务器原有的 SSH 密钥或密码认证。 |
| 中国大陆网络 | `--mainland` 强制 HTTP/2（TCP/7844），不依赖 UDP/QUIC；不能承诺任意网络均可用。 |

## 开始前只需确认两件事

第一，你拥有一个已经添加到 Cloudflare 且 DNS 已交由 Cloudflare 托管的域名。授权时应使用能管理该域名的 Cloudflare 账号；本地管理 Tunnel 的 DNS 路由命令需要该站点权限。[1] [3]

第二，服务器本机已经安装并运行 SSH 服务，且监听默认 `22` 端口。脚本会在修改系统前自动检查这一条件，以及 Cloudflare Tunnel 必需的出站 TCP/7844 连通性。[4]

## 小白安装步骤

在服务器上克隆项目并运行一条命令。中国大陆网络或已知 UDP 不稳定时优先用 `--mainland`：

```bash
git clone https://github.com/buyi06/cf-ssh-tunnel-kit.git
cd cf-ssh-tunnel-kit
sudo bash scripts/cf-ssh-tunnel.sh install --mainland
```

脚本会全程显示中文提示。若系统尚未安装 `cloudflared`，会自动安装；若已安装则显示版本并跳过。随后终端会出现 Cloudflare 提供的 `https://...` 授权链接。复制它并在任意可联网设备的浏览器中打开，登录 Cloudflare，并选择目标域名所在站点。不要关闭服务器终端；浏览器授权完成后，脚本会自动继续。

接下来按提示输入一个完整域名，例如：

```text
ssh.example.com
```

脚本会自动执行以下动作：创建唯一 Tunnel、创建域名 DNS 记录、生成仅指向本机 `localhost:22` 的 SSH 路由、校验配置并启动 systemd 服务。最后会显示实际使用的 SSH 域名和 Tunnel UUID。

> 授权期间产生的 `cert.pem` 具有账户级 Tunnel 管理能力。脚本仅在自动创建和 DNS 配置的短暂期间使用它，完成后立即清理；运行服务只保留此 Tunnel 的专用 JSON 凭据。[3]

## 连接与安全边界

Tunnel、DNS 和 SSH 路由在输入域名后即已完成，不需要再进行 Cloudflare Access 控制台操作。客户端仍需要安装 `cloudflared` 作为 SSH 的 Tunnel 代理，随后以服务器现有的 Linux SSH 密钥或密码完成认证。[5]

> 未创建 Cloudflare Access 应用时，该 SSH 域名会向 Internet 公开可达。[6] 这不等于免认证登录：`sshd` 仍会验证你的 Linux SSH 密钥或密码。请优先使用密钥认证，禁用不需要的 root 或密码登录，并保持系统更新。

## 中国大陆 GitHub 加速

当使用 `install --mainland` 时，脚本会自动对以下 GitHub 代理进行 Git 协议测速：`gh-proxy.org`、`v4.gh-proxy.org`、`v6.gh-proxy.org`、`cdn.gh-proxy.org` 与 `axisnow.gh-proxy.org`。只有返回正确 Git `upload-pack` 响应的代理才会参与比较，脚本将选择总耗时最低的可用项。

选中后，脚本通过 Git 全局 `url.<代理>https://github.com/.insteadOf` 规则加速当前管理员账户访问 `https://github.com/` 的 Git 克隆与拉取。它**不会**设置 `HTTP_PROXY` 或 `HTTPS_PROXY`，因此不会代理 apt 更新、Cloudflare 授权、Tunnel 连接或系统其他网络流量。

对于未安装 `cloudflared` 的 Debian amd64 主机，`install --mainland` 也会从相同候选项中测试 Cloudflare 官方 GitHub Release `.deb` 文件的下载能力，并选择最快兼容项。下载前脚本通过 GitHub 官方 Release 页面取得版本与 SHA-256；下载后会验证 SHA-256 和 Debian 包结构，校验通过才交给 APT 安装。若元数据、代理下载、校验或安装失败，脚本自动回退到 Cloudflare 官方签名 APT 软件源。代理速度会随时间和线路变化，可随时重新测速：

```bash
sudo bash scripts/cf-ssh-tunnel.sh github-proxy
sudo bash scripts/cf-ssh-tunnel.sh github-proxy --show
sudo bash scripts/cf-ssh-tunnel.sh github-proxy --disable
```

> 这些是第三方 GitHub 加速服务。脚本只验证 Git 协议响应与延迟，不能把第三方代理变成代码来源信任锚。生产环境应固定经过审核的提交或发布版本，并审阅脚本后再以 root 执行。

## 客户端连接

在你的电脑上安装 `cloudflared` 后，运行：

```bash
bash scripts/cf-ssh-tunnel.sh client-config ssh.example.com
```

将输出内容放进客户端的 `~/.ssh/config`，再执行：

```bash
ssh <你的 Linux 用户名>@ssh.example.com
```

连接会通过 cloudflared 转入 Tunnel，随后仍会进行正常的 Linux SSH 主机密钥与用户凭据校验。[5]

## 常用维护命令

| 需求 | 命令 |
|---|---|
| 查看状态、Tunnel UUID、SSH 域名 | `sudo bash scripts/cf-ssh-tunnel.sh status` |
| 检查网络、SSH 和最近日志 | `sudo bash scripts/cf-ssh-tunnel.sh diagnose` |
| 更新或安装 `cloudflared` | `sudo bash scripts/cf-ssh-tunnel.sh update` |
| 输出客户端配置 | `bash scripts/cf-ssh-tunnel.sh client-config` |
| 删除本机服务与专用凭据 | `sudo bash scripts/cf-ssh-tunnel.sh uninstall` |

卸载只会删除服务器上的服务、配置和 Tunnel 专用凭据。为避免使用账户级权限误删资源，它不会删除 Cloudflare 控制台中的 Tunnel 或 DNS 记录；脚本会打印 UUID，供你在控制台确认后手动删除。

## 常见问题

**终端没有出现授权链接，或者授权后一直不继续。** 请确认服务器能访问 Cloudflare，且不要关闭正在运行的 `install` 命令。若 `cloudflared tunnel login` 返回错误，重新运行安装命令即可；脚本不会保留失败授权期间的账户级证书。

**自动 DNS 失败。** 该域名必须已添加到 Cloudflare，DNS 必须由 Cloudflare 托管；授权时也必须选择了包含此域名的站点。[1]

**中国大陆服务器连不上。** 请使用 `--mainland`。该模式使用 TCP/7844 的 HTTP/2；若 TCP/7844、DNS 或客户端连接网络不可达，则 Cloudflare Tunnel 无法使用。脚本不会提供绕过网络控制的方案。[4]

**SSH 仍然连接失败。** 先运行 `diagnose`，确认 systemd 服务是 `active`，再确认客户端 `~/.ssh/config` 中存在 `ProxyCommand cloudflared access ssh --hostname %h`，以及服务器的 SSH 用户、密钥或密码正确。[5]

## 参考资料

[1]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/ "Cloudflare: Create a locally-managed tunnel"
[2]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/ "Cloudflare: Configuration file"
[3]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/tunnel-permissions/ "Cloudflare: Tunnel permissions"
[4]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/ "Cloudflare: Tunnel with firewall"
[5]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/ "Cloudflare: Connect to SSH with client-side cloudflared"
[6]: https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/ "Cloudflare: Publish a self-hosted application to the Internet"
