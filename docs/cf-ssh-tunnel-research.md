# Cloudflare SSH Tunnel 设计依据

本项目仅封装 Cloudflare 官方 `cloudflared` 客户端，不分发第三方二进制，也不提供绕过身份控制的裸 TCP/22 暴露方式。实现采用**本地管理 Tunnel**：脚本在无显示器服务器上调用 `cloudflared tunnel login`，由命令行输出浏览器授权链接；用户可在任意设备完成 Cloudflare 登录和站点选择，脚本随后自动创建 Tunnel、DNS 路由、SSH ingress 配置和 systemd 服务。

## 设计依据

| 主题 | 官方事实 | 项目实现 |
|---|---|---|
| 无显示器授权 | `cloudflared tunnel login` 为本地管理 Tunnel 生成账号授权证书，浏览器端完成登录与站点选择。[1] | 脚本在终端用中文说明授权链接；不要求服务器安装浏览器或显示器。 |
| Tunnel 创建 | `cloudflared tunnel create <name>` 建立 Tunnel，并生成该 Tunnel 的专用 JSON 凭据。[1] | 用域名派生出稳定、安全的 Tunnel 名称；服务只使用专用 JSON 凭据。 |
| 自动 DNS | `cloudflared tunnel route dns <UUID 或名称> <hostname>` 可创建指向 `<UUID>.cfargotunnel.com` 的 CNAME。[1] | 用户只填写完整 SSH 域名；脚本自动创建 DNS 路由。 |
| SSH ingress | Cloudflare 配置文件支持 `ssh://localhost:22`，且 ingress 规则必须以兜底规则结束。[2] | 自动写入单一 SSH 域名、`ssh://localhost:22` 与 `http_status:404`。 |
| 账户级证书 | `cert.pem` 可管理账户下 Tunnel；Tunnel JSON 凭据只允许运行特定 Tunnel。[3] | 账户级证书仅存在于临时目录，创建与路由完成后删除；systemd 仅保存专用 JSON。 |
| Access 身份保护 | Cloudflare SSH 指引推荐 Access 自托管应用，SSH 客户端经 `cloudflared access ssh` 完成身份验证。[4] | 脚本自动化 Tunnel 与 DNS，但不猜测用户身份提供商或访问对象；完成后明确要求管理员创建最小化 Access 策略。 |
| Linux 安装 | Cloudflare 为 Debian/Ubuntu 和 RHEL 系提供签名软件源，也提供其他 Linux 安装方式。[5] | 先检测现有 `cloudflared` 并跳过安装；不存在时按发行版自动安装。 |
| 运行网络 | Tunnel 需要到 Cloudflare 边缘的出站 `7844`；QUIC 使用 UDP，HTTP/2 使用 TCP。[6] | 安装前检查 DNS 与 TCP/7844；`--mainland` 固定 HTTP/2/TCP。 |

## 中国大陆网络边界

`--mainland` 是兼容性模式，而非规避网络控制的工具。它强制使用基于 TCP/7844 的 HTTP/2，避免依赖 UDP/QUIC；若服务器 DNS、TCP/7844 或客户端 Access 登录网络不可达，Cloudflare Tunnel 无法建立或使用。[6] 脚本会明确报错，不会自动转向未知第三方中继，也不会移除 Access 身份保护。

## 自动化边界

Tunnel、DNS CNAME、SSH ingress、专用凭据和本机服务可由脚本可靠自动完成。Cloudflare Access 策略涉及用户的身份提供商、允许邮箱或团队组；脚本没有权限也不应猜测这些安全决策。因此脚本将该步骤清楚提示为唯一需要管理员在控制台确认的安全设置，而不是默认将 SSH 暴露给未验证访问者。

## 参考资料

[1]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/ "Cloudflare: Create a locally-managed tunnel"
[2]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/ "Cloudflare: Configuration file"
[3]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/tunnel-permissions/ "Cloudflare: Tunnel permissions"
[4]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/ "Cloudflare: Connect to SSH with client-side cloudflared"
[5]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/ "Cloudflare: Downloads"
[6]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/ "Cloudflare: Tunnel with firewall"
