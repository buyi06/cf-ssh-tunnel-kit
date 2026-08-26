# cf-ssh-tunnel-kit

> 面向**无显示器、仅命令行** Linux 主机的 Cloudflare Tunnel + Access SSH 部署工具。它将本机 SSH 安全接入 Cloudflare Access，**不开放入站 22 端口**。

`cf-ssh-tunnel-kit` 将 Cloudflare 官方 `cloudflared` 客户端托管为受限的 systemd 服务，并把 Tunnel Token 放进权限受控的文件而非命令行参数。它不修改 `sshd_config`、不修改防火墙规则、也不创建没有身份策略的公网 SSH 入口。

| 项目 | 说明 |
|---|---|
| 适用系统 | 使用 systemd 的 Debian/Ubuntu、RHEL/CentOS/Fedora、Arch 或 Alpine Linux。 |
| 安全入口 | Cloudflare Access 身份验证 + 原有 Linux SSH 认证；两层认证互不替代。 |
| 服务路由 | Cloudflare 控制台中配置 `ssh://localhost:22`。 |
| 令牌保护 | Token 存放于 `/etc/cf-ssh-tunnel/token`，权限为 `0640 root:cf-ssh-tunnel`，不会进入 shell 历史、服务参数或日志。 |
| 中国大陆兼容 | `--mainland` 固定使用 HTTP/2（TCP/7844），避免依赖 UDP/QUIC；无法保证任意网络环境均可连接。 |

## 快速开始

先在任意可以登录 Cloudflare 控制台的设备上，创建一个**远程托管 Tunnel**。在 Tunnel 中添加 Published application：使用你自己的主机名（例如 `ssh.example.com`），服务设置为 `ssh://localhost:22`。接着在 Cloudflare Access 中为该主机名创建 Self-hosted 应用，策略仅允许你的账号或所需的最小用户组。具体设置依据 Cloudflare 官方 SSH 指引。[1]

不要执行控制台中包含 Token 的完整安装命令。仅复制其中以 `eyJ` 开头的 Token；该 Token 能够运行 Tunnel，应视为密码。[2]

然后，在目标 Linux 主机执行：

```bash
git clone https://github.com/buyi06/cf-ssh-tunnel-kit.git
cd cf-ssh-tunnel-kit
sudo bash scripts/cf-ssh-tunnel.sh install --auto
```

脚本会检查本机 SSH、DNS 与 Cloudflare TCP/7844 出站连通性；安装官方 `cloudflared` 包；并要求两次以隐藏方式输入 Token。`--auto` 是默认模式：QUIC 不可用时，`cloudflared` 会回退到 HTTP/2。[3]

中国大陆或 UDP/QUIC 不稳定的网络可以使用：

```bash
sudo bash scripts/cf-ssh-tunnel.sh install --mainland
```

> `--mainland` 只是把传输协议固定为 HTTP/2（TCP/7844）。如果 DNS、TCP/7844 或 Access 登录不可达，Tunnel 不能建立。工具不会尝试绕过网络控制、切换未知中继，或降低 Access 策略。

## 客户端连接

在 SSH 客户端也安装 `cloudflared`，并生成模板：

```bash
bash scripts/cf-ssh-tunnel.sh client-config ssh.example.com
```

将模板加入客户端 `~/.ssh/config` 后，使用普通 SSH 命令连接：

```bash
ssh <你的 Linux 用户名>@ssh.example.com
```

首次连接时，`cloudflared` 会打开浏览器完成 Cloudflare Access 身份验证；之后 SSH 仍会校验主机密钥和 Linux SSH 凭据。[1]

## 常用命令

| 目标 | 命令 |
|---|---|
| 查看 Tunnel 状态 | `sudo bash scripts/cf-ssh-tunnel.sh status` |
| 检查网络、SSH 与日志 | `sudo bash scripts/cf-ssh-tunnel.sh diagnose` |
| 轮换 Tunnel Token | `sudo bash scripts/cf-ssh-tunnel.sh rotate-token` |
| 更新 `cloudflared` | `sudo bash scripts/cf-ssh-tunnel.sh update` |
| 显示客户端配置 | `bash scripts/cf-ssh-tunnel.sh client-config ssh.example.com` |
| 删除本地服务和 Token | `sudo bash scripts/cf-ssh-tunnel.sh uninstall` |

详细的控制台配置、各发行版来源说明、安全边界和排障流程见[部署指南](docs/cf-ssh-tunnel.md)。关于实现依据与引用的开源/官方项目，请见[研究记录](docs/cf-ssh-tunnel-research.md)。

## 验证

该项目附带不依赖网络、不需要 root 的回归测试：

```bash
./tests/test-cf-ssh-tunnel.sh
```

## 许可

本项目采用 [MIT License](LICENSE)。

## 参考资料

[1]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/ "Cloudflare: Connect to SSH with client-side cloudflared"
[2]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/remote-tunnel-permissions/ "Cloudflare: Tunnel permissions"
[3]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/ "Cloudflare: Tunnel run parameters"
