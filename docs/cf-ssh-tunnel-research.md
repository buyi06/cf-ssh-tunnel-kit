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
| Linux 安装 | Cloudflare 为 Debian/Ubuntu 和 RHEL 系提供签名软件源，也提供其他 Linux 安装方式。[5] | 先检测现有 `cloudflared` 并跳过安装；不存在时按发行版自动安装。 |
| 运行网络 | Tunnel 需要到 Cloudflare 边缘的出站 `7844`；QUIC 使用 UDP，HTTP/2 使用 TCP。[6] | 安装前检查 DNS 与 TCP/7844；`--mainland` 固定 HTTP/2/TCP。 |

## 中国大陆网络边界

`--mainland` 是兼容性模式，而非规避网络控制的工具。它强制使用基于 TCP/7844 的 HTTP/2，避免依赖 UDP/QUIC；若服务器 DNS、TCP/7844 或客户端连接网络不可达，Cloudflare Tunnel 无法建立或使用。[6] 脚本会明确报错，不会自动转向未知第三方中继。

## GitHub 代理测速边界

大陆网络优化候选项由用户指定为 `gh-proxy.org`、`v4.gh-proxy.org`、`v6.gh-proxy.org`、`cdn.gh-proxy.org` 与 `axisnow.gh-proxy.org`。脚本不以首页能否打开作为有效性判断，而是对本项目 Git 智能 HTTP 的 `info/refs?service=git-upload-pack` 端点发起只读 GET 探测。只有 HTTP `200` 且响应类型为 `application/x-git-upload-pack-advertisement` 的候选项才参与延迟排序；探测结果仅代表执行时该主机的网络条件，不能预设长期最快项。

选中项通过 Git 的 `url.<proxy>https://github.com/.insteadOf` 规则应用到当前管理员账户的 GitHub Git 操作，并以 `url.https://github.com/.pushInsteadOf` 反向规则保证推送直连 GitHub、不被只读代理拦截。它不会写入 `HTTP_PROXY`、`HTTPS_PROXY` 或系统软件源配置；因此不会代理 Cloudflare、APT 或无关的系统流量。第三方代理不能充当代码完整性保证，生产使用仍应固定和审核提交或发布版本。

对 Cloudflare 官方 GitHub 发布包 `cloudflared-linux-amd64.deb` 的范围请求探测表明，部分候选项可返回 `206 Partial Content` 和 `application/octet-stream`，说明它们能透传 GitHub Release 二进制下载；另有候选项在探测超时内不可用。该结果只说明传输兼容性，绝不说明代理内容可信。加速路径从 GitHub 官方 Release 页面取得版本和 SHA-256，再仅在校验通过后安装；元数据、校验或下载任何一步失败时回退到 Cloudflare 官方签名软件包仓库。[5] [7]

## 自动化边界

Tunnel、DNS CNAME、SSH ingress、专用凭据和本机服务可由脚本可靠自动完成。SSH 应使用强密钥认证，并禁用 root 密码登录等常规系统加固方式。该主机名会对 Internet 公开可达，连接安全由服务器 `sshd` 的密钥或密码验证把关。[8]

## 参考资料

[1]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/ "Cloudflare: Create a locally-managed tunnel"
[2]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/ "Cloudflare: Configuration file"
[3]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/tunnel-permissions/ "Cloudflare: Tunnel permissions"
[5]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/ "Cloudflare: Downloads"
[6]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/ "Cloudflare: Tunnel with firewall"
[7]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/ "Cloudflare: Downloads"
[8]: https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/ "Cloudflare: Publish a self-hosted application to the Internet"
