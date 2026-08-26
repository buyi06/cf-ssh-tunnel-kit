# Cloudflare SSH Tunnel 设计依据

本项目仅封装官方 `cloudflared` 客户端，不复制或分发第三方二进制，也不提供可绕过身份控制的公共 SSH 入口。脚本采用 Cloudflare 控制台创建的**远程托管隧道**与其一次性获取的隧道令牌；运行端仅保存令牌，并由 systemd 托管。

## 官方依据

| 主题 | 结论 | 设计影响 |
|---|---|---|
| SSH 发布方式 | Cloudflare 的 SSH 指引要求服务端与客户端使用 `cloudflared`，并建议为 SSH 主机名创建 Access 自托管应用。[1] | README 将 Access 身份策略设为上线前置条件；客户端使用 `ProxyCommand`，不承诺公网 IP/22 端口直连。 |
| SSH 服务路由 | 控制台的 Published application 路由可将 SSH 服务映射到 `localhost:22`。[1] | 脚本不修改 SSH 守护程序、不开放防火墙入站端口，仅连接本机 SSH。 |
| 隧道令牌 | 远程托管隧道仅凭令牌运行；任何取得该令牌的人都可以运行隧道。[2] | 令牌不进入命令行、环境变量、Git 或日志；脚本将其写入 root 专属文件（`0600`）并由 `--token-file` 读取。 |
| 运行网络 | Tunnel 需要向 Cloudflare 边缘出站连接到 TCP/UDP `7844`；`http2` 对应 TCP，`quic` 对应 UDP。[3] | 脚本在安装前对 DNS 与 TCP/7844 进行预检，提供 `mainland` 配置为 HTTP/2/TCP 优先，并把失败提示为网络限制而非静默重试。 |
| 当前运行参数 | 远程托管 Tunnel 支持 `cloudflared tunnel --protocol <auto|http2|quic> run --token-file <PATH>`；`token-file` 要求 2025.4.0 或更新版本，`auto` 会在 UDP 不可用时回落 HTTP/2。[6] | 脚本固定使用 `tunnel --protocol ... run --token-file ...` 的受支持语法，并在安装后校验版本是否至少为 2025.4.0。 |
| Linux 安装 | 官方提供签名的软件包仓库支持 Debian/Ubuntu、RHEL 系发行版。[4] | 首选官方签名软件包仓库；其他发行版使用官方 GitHub 发布的单文件二进制，但需要显式确认下载与版本检查。 |
| 维护状态 | `cloudflare/cloudflared` 是 Cloudflare 维护的开源 Tunnel 客户端，采用 Apache-2.0 许可证，维护活跃。[5] | 只借鉴官方服务与预检模式；本项目 shell 脚本独立实现，避免引入难以审计的面板或容器管理层。 |

## 中国大陆网络环境边界

`mainland` 模式不是规避网络限制的承诺，也不提供规避方案。它仅强制使用基于 TCP/7844 的 HTTP/2，避免依赖常见受限的 UDP/QUIC 路径。若 DNS、TCP/7844 或 Access 登录所在网络不可达，Cloudflare Tunnel 无法建立连接；脚本会明确报告失败并建议使用用户所在网络和合规要求允许的其他远程管理通道。系统不会自动切换到未知第三方中继，也不会降低身份验证要求。

## 参考资料

[1]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/ "Cloudflare: Connect to SSH with client-side cloudflared"
[2]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/remote-tunnel-permissions/ "Cloudflare: Tunnel permissions"
[3]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/ "Cloudflare: Tunnel with firewall"
[4]: https://pkg.cloudflare.com/ "Cloudflare Packages"
[5]: https://github.com/cloudflare/cloudflared "cloudflare/cloudflared"
[6]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/ "Cloudflare: Tunnel run parameters"
